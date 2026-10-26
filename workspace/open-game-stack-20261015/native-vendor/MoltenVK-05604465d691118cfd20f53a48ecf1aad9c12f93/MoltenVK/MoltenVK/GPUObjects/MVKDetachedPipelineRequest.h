// Optional archive rehydration. The original pipeline remains the fallback.
// This request never captures a compiler/owner or changes its configuration.
#pragma once
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>

enum class MVKDetachedPipelineStatus { Success, Failure, TimedOut, AlreadyConsumed };

template<class Result> struct MVKDetachedPipelineResult {
    Result state{}; // One retained ownership reference, transferred to the caller.
    int64_t errorCode = 0;
    bool timedOut = false;
    bool submitted = false;
    MVKDetachedPipelineStatus status = MVKDetachedPipelineStatus::Failure;
};

// Callbacks must be process-lifetime functions. Arguments are immutable scalar
// identities only; a late callback must never dereference an original owner.
struct MVKDetachedPipelineTrace {
    uint64_t ownerIdentity = 0;
    uint64_t requestIdentity = 0;
    uint64_t ownerSession = 0; // Capture once; never retarget a late event to a current arm.
    void (*monitorAcquired)(uint64_t owner, uint64_t request, uint64_t session, uint64_t waitNS) = nullptr;
    void (*completed)(uint64_t owner, uint64_t request, uint64_t session, bool accepted,
                      bool succeeded, int64_t errorCode) = nullptr;
};

// Traits supplies Device/Descriptor/Result/Error and explicit retain/release
// operations. This core has no Metal, dispatch, compiler or owner dependency.
template<class Traits> class MVKDetachedPipelineRequest {
public:
    using Device = typename Traits::Device;
    using Descriptor = typename Traits::Descriptor;
    using Result = typename Traits::Result;
    using Error = typename Traits::Error;
    using Clock = std::chrono::steady_clock;
    using Output = MVKDetachedPipelineResult<Result>;

    // Preserve the configured compile timeout; saturate safely at the largest
    // representable steady deadline instead of overflowing now + duration.
    static Clock::time_point deadlineFrom(Clock::time_point now, uint64_t timeoutNS) {
        const uint64_t signedMax = static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
        const uint64_t bounded = timeoutNS < signedMax ? timeoutNS : signedMax;
        const auto room = Clock::time_point::max() - now;
        const long double roomNS = std::chrono::duration<long double, std::nano>(room).count();
        if (static_cast<long double>(bounded) >= roomNS) return Clock::time_point::max();
        return now + std::chrono::duration_cast<Clock::duration>(
            std::chrono::nanoseconds(static_cast<int64_t>(bounded)));
    }

    MVKDetachedPipelineRequest(Device device, Descriptor descriptor, uint64_t timeoutNS)
        : _deadline(deadlineFrom(Clock::now(), timeoutNS)),
          _device(Traits::retainDevice(device)),
          _descriptor(Traits::retainDescriptor(descriptor)) {}
    ~MVKDetachedPipelineRequest() {
        Traits::releaseResult(_result);
        Traits::releaseError(_error);
        Traits::releaseDescriptor(_descriptor);
        Traits::releaseDevice(_device);
    }
    MVKDetachedPipelineRequest(const MVKDetachedPipelineRequest&) = delete;
    MVKDetachedPipelineRequest& operator=(const MVKDetachedPipelineRequest&) = delete;

    Device device() const { return _device; }
    Descriptor descriptor() const { return _descriptor; }
    Clock::time_point deadline() const { return _deadline; }

    // Check once before acquiring the device monitor and again after acquiring
    // it. A request that times out while queued must not start optional work.
    bool canAttemptSubmission() {
        std::lock_guard<std::mutex> lock(_mutex);
        return canSubmitLocked();
    }
    bool tryBeginSubmission() {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!canSubmitLocked()) return false;
        _submitted = true;
        return true;
    }

    // Metal callback arguments are borrowed. Retain only an accepted result;
    // a late/duplicate result remains Metal's responsibility and is not adopted.
    // The mutex is released before this returns, including inline completions.
    bool complete(Result result, Error error) {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_submitted || _completionSeen) return false;
        _completionSeen = true;
        if (_abandoned || Clock::now() >= _deadline) {
            _abandoned = true;
            _ready.notify_all();
            return false;
        }
        _result = Traits::retainResult(result);
        _error = Traits::retainError(error);
        _done = true;
        _ready.notify_all();
        return true;
    }

    // Called by the requesting thread, outside every device monitor. The
    // request has its own mutex: callbacks never lock a parent compiler mutex.
    Output wait() {
        std::unique_lock<std::mutex> lock(_mutex);
        Output out;
        out.submitted = _submitted;
        if (_consumed) {
            out.status = MVKDetachedPipelineStatus::AlreadyConsumed;
            return out;
        }
        _ready.wait_until(lock, _deadline, [this] { return _done || _abandoned; });
        _consumed = true;
        out.submitted = _submitted;
        if (!_done) {
            _abandoned = true;
            out.timedOut = true;
            out.errorCode = 1; // Existing Metal compiler timeout convention.
            out.status = MVKDetachedPipelineStatus::TimedOut;
            return out;
        }
        out.state = _result;
        _result = Result{}; // Transfer the accepted +1 reference exactly once.
        out.errorCode = Traits::errorCode(_error);
        out.status = out.state != Result{} ? MVKDetachedPipelineStatus::Success
                                          : MVKDetachedPipelineStatus::Failure;
        return out;
    }

private:
    bool canSubmitLocked() {
        if (_submitted || _completionSeen || _abandoned || _consumed) return false;
        if (Clock::now() >= _deadline) {
            _abandoned = true;
            _ready.notify_all();
            return false;
        }
        return true;
    }
    const Clock::time_point _deadline;
    Device _device{};
    Descriptor _descriptor{};
    Result _result{};
    Error _error{};
    std::mutex _mutex;
    std::condition_variable _ready;
    bool _submitted = false, _completionSeen = false;
    bool _done = false, _abandoned = false, _consumed = false;
};

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dispatch/dispatch.h>

template<class PipelineState, class PipelineDescriptor>
struct MVKDetachedPipelineMetalTraits {
    using Device = id<MTLDevice>;
    using Descriptor = PipelineDescriptor*;
    using Result = PipelineState;
    using Error = NSError*;
    static Device retainDevice(Device v) { return [v retain]; }
    static Descriptor retainDescriptor(Descriptor v) { return [v retain]; }
    static Result retainResult(Result v) { return [v retain]; }
    static Error retainError(Error v) { return [v retain]; }
    static void releaseDevice(Device v) { [v release]; }
    static void releaseDescriptor(Descriptor v) { [v release]; }
    static void releaseResult(Result v) { [v release]; }
    static void releaseError(Error v) { [v release]; }
    static int64_t errorCode(Error v) { return v ? static_cast<int64_t>(v.code) : 0; }
};

// Submitter and completion blocks capture only shared request state and scalar
// trace data. Async Metal entry can itself block; dispatch keeps the caller's
// timeout enforceable even during queueing, monitor admission or driver entry.
template<class Request, class Submitter>
inline typename Request::Output mvkRunDetachedPipelineRequest(
    typename Request::Device device, typename Request::Descriptor descriptor,
    uint64_t timeoutNS, MVKDetachedPipelineTrace trace, Submitter submitter) {
    using Clock = typename Request::Clock;
    auto request = std::make_shared<Request>(device, descriptor, timeoutNS);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            if (!request->canAttemptSubmission()) return;
            const auto monitorStart = Clock::now();
            @synchronized (request->device()) {
                if (!request->tryBeginSubmission()) return;
                if (trace.monitorAcquired) {
                    const auto elapsed = Clock::now() - monitorStart;
                    trace.monitorAcquired(trace.ownerIdentity, trace.requestIdentity, trace.ownerSession,
                        static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count()));
                }
                // No request mutex is held across the API or an inline callback.
                submitter(request, trace);
            }
        }
    });
    return request->wait();
}

inline MVKDetachedPipelineResult<id<MTLRenderPipelineState>>
mvkNewDetachedRenderPipelineState(id<MTLDevice> device,
    MTLRenderPipelineDescriptor* descriptor, uint64_t timeoutNS,
    MVKDetachedPipelineTrace trace = {}) {
    using Traits = MVKDetachedPipelineMetalTraits<id<MTLRenderPipelineState>, MTLRenderPipelineDescriptor>;
    using Request = MVKDetachedPipelineRequest<Traits>;
    return mvkRunDetachedPipelineRequest<Request>(device, descriptor, timeoutNS, trace,
        [](std::shared_ptr<Request> request, MVKDetachedPipelineTrace callbackTrace) {
            [request->device() newRenderPipelineStateWithDescriptor:request->descriptor()
                completionHandler:^(id<MTLRenderPipelineState> state, NSError* error) {
                    const bool accepted = request->complete(state, error);
                    if (callbackTrace.completed)
                        callbackTrace.completed(callbackTrace.ownerIdentity, callbackTrace.requestIdentity,
                            callbackTrace.ownerSession,
                            accepted, state != nil, Traits::errorCode(error));
                }];
        });
}

inline MVKDetachedPipelineResult<id<MTLComputePipelineState>>
mvkNewDetachedComputePipelineState(id<MTLDevice> device,
    MTLComputePipelineDescriptor* descriptor, uint64_t timeoutNS,
    MVKDetachedPipelineTrace trace = {}) {
    using Traits = MVKDetachedPipelineMetalTraits<id<MTLComputePipelineState>, MTLComputePipelineDescriptor>;
    using Request = MVKDetachedPipelineRequest<Traits>;
    return mvkRunDetachedPipelineRequest<Request>(device, descriptor, timeoutNS, trace,
        [](std::shared_ptr<Request> request, MVKDetachedPipelineTrace callbackTrace) {
            [request->device() newComputePipelineStateWithDescriptor:request->descriptor()
                options:MTLPipelineOptionNone
                completionHandler:^(id<MTLComputePipelineState> state, MTLComputePipelineReflection*, NSError* error) {
                    const bool accepted = request->complete(state, error);
                    if (callbackTrace.completed)
                        callbackTrace.completed(callbackTrace.ownerIdentity, callbackTrace.requestIdentity,
                            callbackTrace.ownerSession,
                            accepted, state != nil, Traits::errorCode(error));
                }];
        });
}
#endif
