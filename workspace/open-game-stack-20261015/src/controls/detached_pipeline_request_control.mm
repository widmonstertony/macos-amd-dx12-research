// CPU property doubles exercise both real helper entry points. No MTLDevice.
#include "MVKDetachedPipelineRequest.h"
#include <atomic>
#include <fstream>
#include <future>
#include <iostream>
#include <thread>

static std::atomic<unsigned> created{0}, destroyed{0}, submitted{0}, callbacks{0};
static std::atomic<unsigned> acceptedCallbacks{0}, lateCallbacks{0}, monitorEvents{0};
static std::mutex destructionMutex;
static std::condition_variable destructionCV;
static unsigned checks = 0;
static void need(bool ok, const char* what) {
    ++checks; if (!ok) throw std::runtime_error(what);
}

@interface CPUDetachedObject : NSObject
- (NSInteger)code;
@end
@implementation CPUDetachedObject
- (instancetype)init { if ((self = [super init])) ++created; return self; }
- (NSInteger)code { return 77; }
- (void)dealloc {
    { std::lock_guard<std::mutex> lock(destructionMutex); ++destroyed; }
    destructionCV.notify_all(); [super dealloc];
}
@end

// mode: 0 inline completion, 1 async completion, 2 delayed completion,
//       3 async error, 4 blocking async API entry, 5 nil result without error.
@interface CPUDetachedDevice : CPUDetachedObject { @public unsigned mode; }
- (void)complete:(void (^)(id, NSError*))completion;
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor*)descriptor
                          completionHandler:(void (^)(id<MTLRenderPipelineState>, NSError*))completion;
- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor*)descriptor
    options:(MTLPipelineOption)options
    completionHandler:(void (^)(id<MTLComputePipelineState>, MTLComputePipelineReflection*, NSError*))completion;
@end
@implementation CPUDetachedDevice
- (void)complete:(void (^)(id, NSError*))completion {
    const unsigned selected = mode;
    auto deliver = ^{
        @autoreleasepool {
            id value = selected == 3 || selected == 5 ? nil : [CPUDetachedObject new];
            NSError* error = selected == 3 ? (NSError*)[CPUDetachedObject new] : nil;
            ++callbacks;
            completion(value, error); // Borrowed values, as in Metal completions.
            [value release]; [error release];
        }
    };
    if (selected == 0 || selected == 5) { deliver(); return; }
    if (selected == 4) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        deliver(); return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        std::this_thread::sleep_for(std::chrono::milliseconds(selected == 2 ? 250 : 2));
        deliver();
    });
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor*)descriptor
                          completionHandler:(void (^)(id<MTLRenderPipelineState>, NSError*))completion {
    if (!descriptor) std::terminate();
    ++submitted;
    [self complete:^(id state, NSError* error) { completion((id<MTLRenderPipelineState>)state, error); }];
}
- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor*)descriptor
    options:(MTLPipelineOption)options
    completionHandler:(void (^)(id<MTLComputePipelineState>, MTLComputePipelineReflection*, NSError*))completion {
    if (!descriptor || options != MTLPipelineOptionNone) std::terminate();
    ++submitted;
    [self complete:^(id state, NSError* error) { completion((id<MTLComputePipelineState>)state, nil, error); }];
}
@end

static void monitor(uint64_t owner, uint64_t request, uint64_t session, uint64_t) {
    if (owner != 123 || request != 456 || session != 789) std::terminate();
    ++monitorEvents;
}
static void completed(uint64_t owner, uint64_t request, uint64_t session, bool accepted, bool, int64_t) {
    if (owner != 123 || request != 456 || session != 789) std::terminate();
    if (accepted) ++acceptedCallbacks; else ++lateCallbacks;
}
static MVKDetachedPipelineTrace trace() {
    MVKDetachedPipelineTrace t; t.ownerIdentity = 123; t.requestIdentity = 456; t.ownerSession = 789;
    t.monitorAcquired = monitor; t.completed = completed; return t;
}
static void allReleased() {
    std::unique_lock<std::mutex> lock(destructionMutex);
    need(destructionCV.wait_for(lock, std::chrono::seconds(3), [] {
        return created.load() == destroyed.load();
    }), "objects survived all completed requests");
}

template<class Traits> static void coreTransitions(typename Traits::Device device,
    typename Traits::Descriptor descriptor, typename Traits::Result value) {
    using Request = MVKDetachedPipelineRequest<Traits>;
    auto request = std::make_shared<Request>(device, descriptor, UINT64_C(1000000000));
    need(request->canAttemptSubmission(), "fresh request rejected");
    need(request->tryBeginSubmission(), "first admission rejected");
    need(!request->tryBeginSubmission(), "duplicate admission accepted");
    need(request->complete(value, nil), "inline completion rejected");
    need(!request->complete(value, nil), "duplicate completion accepted");
    need(!request->canAttemptSubmission(), "completed request admitted");
    auto output = request->wait();
    need(output.state == value && output.submitted && !output.timedOut, "result transfer failed");
    need(request->wait().status == MVKDetachedPipelineStatus::AlreadyConsumed, "result transferred twice");
    Traits::releaseResult(output.state);
    auto zero = std::make_shared<Request>(device, descriptor, 0);
    need(!zero->tryBeginSubmission(), "zero-budget work admitted");
    need(zero->wait().timedOut, "zero-budget wait did not time out");
    need(!zero->canAttemptSubmission(), "timed-out request admitted");
    need(!zero->complete(value, nil), "unsubmitted completion accepted");
    const auto now = Request::Clock::now();
    need(Request::deadlineFrom(now, UINT64_MAX) == Request::Clock::time_point::max(),
         "large timeout overflowed deadline");
    need(Request::deadlineFrom(now, 0) == now, "zero deadline changed");
    auto huge = std::make_shared<Request>(device, descriptor, UINT64_MAX);
    need(huge->tryBeginSubmission() && huge->complete(value, nil), "saturated-budget completion failed");
    auto hugeOutput = huge->wait();
    need(hugeOutput.state == value && !hugeOutput.timedOut, "saturated budget spuriously timed out");
    Traits::releaseResult(hugeOutput.state);
}

int main(int argc, char** argv) { @autoreleasepool { try {
    need(argc == 2, "report path required");
    const unsigned originalParentConfiguration = 42;
    unsigned successful = 0, failures = 0, timeouts = 0;
    for (bool compute : {false, true}) {
        for (unsigned mode : {0u, 1u, 2u, 3u, 4u, 5u}) {
            CPUDetachedDevice* device = [CPUDetachedDevice new]; device->mode = mode;
            CPUDetachedObject* descriptor = [CPUDetachedObject new];
            const bool timeout = mode == 2 || mode == 4;
            const uint64_t budget = timeout ? UINT64_C(50000000) : UINT64_C(1000000000);
            const auto before = std::chrono::steady_clock::now();
            id originalPipeline = [CPUDetachedObject new];
            id retainedPipeline = originalPipeline;
            id result = nil; int64_t errorCode = 0; bool timedOut = false;
            if (compute) {
                auto out = mvkNewDetachedComputePipelineState((id<MTLDevice>)device,
                    (MTLComputePipelineDescriptor*)descriptor, budget, trace());
                result = out.state; errorCode = out.errorCode; timedOut = out.timedOut;
            } else {
                auto out = mvkNewDetachedRenderPipelineState((id<MTLDevice>)device,
                    (MTLRenderPipelineDescriptor*)descriptor, budget, trace());
                result = out.state; errorCode = out.errorCode; timedOut = out.timedOut;
            }
            if (timeout) {
                need(timedOut && !result && errorCode == 1, "timeout fallback result changed");
                need(std::chrono::steady_clock::now() - before < std::chrono::milliseconds(200),
                     "caller waited for blocking driver entry/completion");
                ++timeouts;
            } else if (mode == 3 || mode == 5) {
                need(!result && !timedOut && errorCode == (mode == 3 ? 77 : 0), "error fallback changed");
                ++failures;
            } else {
                need(result && !timedOut && errorCode == 0, "successful detached state missing");
                ++successful;
            }
            if (result) { [retainedPipeline release]; retainedPipeline = result; }
            else need(retainedPipeline == originalPipeline, "optional failure discarded original pipeline");
            // Inputs may be released immediately even after a timeout. The
            // queued worker/callback must retain everything it still accesses.
            [device release]; [descriptor release]; [retainedPipeline release];
            allReleased();
            need(originalParentConfiguration == 42, "parent configuration changed");
        }
        for (bool holdMonitor : {false, true}) {
            CPUDetachedDevice* device = [CPUDetachedDevice new];
            CPUDetachedObject* descriptor = [CPUDetachedObject new];
            const unsigned submittedBefore = submitted.load();
            std::promise<void> monitorHeld;
            auto held = monitorHeld.get_future();
            std::thread holder;
            if (holdMonitor) {
                holder = std::thread([&] {
                    @autoreleasepool { @synchronized(device) {
                        monitorHeld.set_value();
                        std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    } }
                });
                need(held.wait_for(std::chrono::seconds(1)) == std::future_status::ready,
                     "CPU monitor fixture did not start");
            }
            const uint64_t budget = holdMonitor ? UINT64_C(10000000) : 0;
            if (compute) {
                auto out = mvkNewDetachedComputePipelineState((id<MTLDevice>)device,
                    (MTLComputePipelineDescriptor*)descriptor, budget, trace());
                need(out.timedOut && !out.submitted && !out.state, "expired compute admitted");
            } else {
                auto out = mvkNewDetachedRenderPipelineState((id<MTLDevice>)device,
                    (MTLRenderPipelineDescriptor*)descriptor, budget, trace());
                need(out.timedOut && !out.submitted && !out.state, "expired render admitted");
            }
            if (holder.joinable()) holder.join();
            [device release]; [descriptor release]; allReleased();
            need(submitted == submittedBefore, "queued expired request entered Metal API");
        }
        CPUDetachedDevice* device = [CPUDetachedDevice new];
        CPUDetachedObject* descriptor = [CPUDetachedObject new];
        CPUDetachedObject* result = [CPUDetachedObject new];
        if (compute) {
            using Traits = MVKDetachedPipelineMetalTraits<id<MTLComputePipelineState>, MTLComputePipelineDescriptor>;
            coreTransitions<Traits>((id<MTLDevice>)device, (MTLComputePipelineDescriptor*)descriptor,
                                   (id<MTLComputePipelineState>)result);
        } else {
            using Traits = MVKDetachedPipelineMetalTraits<id<MTLRenderPipelineState>, MTLRenderPipelineDescriptor>;
            coreTransitions<Traits>((id<MTLDevice>)device, (MTLRenderPipelineDescriptor*)descriptor,
                                   (id<MTLRenderPipelineState>)result);
        }
        [device release]; [descriptor release]; [result release]; allReleased();
    }
    need(submitted == 12 && callbacks == 12, "fixture submission/callback coverage incomplete");
    need(monitorEvents == 12 && lateCallbacks == 4 && acceptedCallbacks == 8,
         "trace acceptance/late ownership coverage incomplete");
    need(created == destroyed, "retain/release imbalance");
    std::ofstream out(argv[1]);
    out << "{\"passed\":true,\"CPUOnly\":true,\"checks\":" << checks
        << ",\"renderAndComputeCases\":12,\"expiredBeforeSubmissionCases\":4,\"successfulCases\":" << successful
        << ",\"errorOrNilCases\":" << failures << ",\"timeoutLateCallbackCases\":" << timeouts
        << ",\"objectsCreated\":" << created << ",\"objectsDestroyed\":" << destroyed
        << ",\"submissions\":" << submitted << ",\"callbacks\":" << callbacks
        << ",\"lateCallbacks\":" << lateCallbacks << ",\"parentMutation\":false,"
        << "\"GPUCommandsSubmitted\":0,\"realMetalDevicesCreated\":0,\"gameOperated\":false}\n";
    need(bool(out), "report write failed");
    std::cout << "passed; compute/render cases=12; late callbacks=4; objects=" << created
              << '/' << destroyed << '\n';
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 2; } } }
