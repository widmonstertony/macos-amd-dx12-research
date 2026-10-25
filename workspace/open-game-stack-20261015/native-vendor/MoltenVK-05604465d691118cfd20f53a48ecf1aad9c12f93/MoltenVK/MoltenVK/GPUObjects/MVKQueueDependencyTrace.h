// Public Metal event observations only. Never modifies semaphore values, waits,
// completion results, watchdogs, or hardware feature reports.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <atomic>
#include <mutex>
#include "MVKTimedTraceArm.h"
#include "MVKEncodedWorkRing.h"
#include "MVKGPUTimestampTrace.h"
#include "MVKStutterNativeTrace.h"

inline bool mvkEncoderWorkTraceEnabled() {
    static const bool enabled = [] { const char* v=getenv("MVK_AMD_GPU_TIMEOUT_TRACE"); return v && !strcmp(v,"1"); }();
    if (enabled) return true;
    // Geometry/GPU-counter diagnostics are timed by the same external arm.
    // Keeping the work ring inactive before arming avoids changing normal game
    // CPU load and prevents menu/preload traffic from obscuring the target.
    if (mvkGPUTimestampArmed()) return true;
    static const MVKTimedTraceArm arm(getenv("MVK_AMD_GPU_WORK_TRACE_ARM_PATH"));
    return arm.enabled();
}
inline bool mvkDependencyTraceEnabled() {
    static const bool failure = [] { const char* v=getenv("MVK_AMD_QUEUE_FAILURE_CONTEXT"); return v && !strcmp(v,"1"); }();
    return mvkStutterNativeEnabled() || failure || mvkEncoderWorkTraceEnabled();
}
inline const void* mvkDependencyKey() { return sel_registerName("mvkQueueDependenciesV1"); }
inline const void* mvkEncodedWorkKey() { return sel_registerName("mvkEncodedWorkRingV1"); }
inline const void* mvkPipelineTraceLabelKey() { return sel_registerName("mvkPipelineTraceLabelV1"); }
inline NSString* mvkPipelineTraceLabel(id pipeline) {
    if (!pipeline) return @"";
    NSString* label = objc_getAssociatedObject(pipeline, mvkPipelineTraceLabelKey());
    if (!label && [pipeline respondsToSelector:@selector(label)]) label = [pipeline label];
    return label ?: @"";
}
struct MVKPendingDependencyRecords {
    std::mutex lock;
    NSMutableDictionary* records = [NSMutableDictionary new];
    std::atomic<uint64_t> sequence{0};
};
inline MVKPendingDependencyRecords& mvkPendingDependencies() {
    static MVKPendingDependencyRecords state;
    return state;
}
inline id mvkObservedEventValue(id<MTLEvent> event) {
    return [event respondsToSelector:@selector(signaledValue)]
        ? @(((id<MTLSharedEvent>)event).signaledValue) : (id)[NSNull null];
}
inline void mvkBeginDependencyTrace(id<MTLCommandBuffer> cb, uint32_t family, uint32_t index, const void* device, const void* queue) {
    if (!cb || !mvkDependencyTraceEnabled()) return;
    auto& state = mvkPendingDependencies();
    NSNumber* serial = @(state.sequence.fetch_add(1));
    NSMutableDictionary* record = [@{@"submission":serial, @"queueFamily":@(family),
        @"queueIndex":@(index), @"createdTime":@([NSDate timeIntervalSinceReferenceDate]),
        @"nativeCommandBufferLabel":cb.label ?: @"",
        @"logicalDevice":[NSString stringWithFormat:@"%p",device],
        @"logicalQueue":[NSString stringWithFormat:@"%p",queue],
        @"nativeQueue":[NSString stringWithFormat:@"%p",cb.commandQueue],
        @"phases":[NSMutableArray array],
        @"workEvents":[NSMutableArray array], @"workCount":@0, @"truncatedWorkEvents":@0,
        @"events":[NSMutableArray array], @"truncatedEvents":@0} mutableCopy];
    if(mvkStutterNativeEnabled()) {
        record[@"nativeCBID"]=@(mvkStutterNativeID(cb));
        record[@"nativeCommandBuffer"]=[NSString stringWithFormat:@"%p",cb];
        record[@"logicalSubmissionID"]=@0;record[@"nativeSplitIndex"]=@0;record[@"presentFrameID"]=@0;
    }
    mvkBeginGPUTimestamps(record, cb, family);
    objc_setAssociatedObject(cb, mvkDependencyKey(), record, OBJC_ASSOCIATION_RETAIN);
    {
        std::lock_guard<std::mutex> lock(state.lock);
        // Bound global snapshots. A command buffer's own event record is still
        // available even if the pending registry is full.
        if (state.records.count < 256) state.records[serial] = record;
    }
    [record release];
}
// The encoder retains only bounded CPU metadata, never a command buffer or a
// Vulkan/GPU resource. This also covers helper pipelines without a Vulkan owner.
inline void mvkAssociateEncoderTrace(id<MTLCommandBuffer> cb, id<MTLCommandEncoder> encoder) {
    if (!encoder) return;
    bool workTrace=mvkEncoderWorkTraceEnabled();
    if(!workTrace&&!mvkGPUCounterBurstEnabled())return;
    NSMutableDictionary* record = objc_getAssociatedObject(cb, mvkDependencyKey());
    if (!record) return;
    @synchronized (record) {
        if(workTrace) {
            NSMutableData* data = record[@"workBuffer"];
            if (!data) { data = mvkNewEncodedWorkRing(); record[@"workBuffer"] = data; }
            objc_setAssociatedObject(encoder, mvkEncodedWorkKey(), data, OBJC_ASSOCIATION_RETAIN);
        }
        // Keep the lightweight record association even before a counter buffer
        // exists.  Selected-pipeline tracing allocates lazily from the first
        // matching pipeline event; requiring a buffer here made that event
        // unreachable for encoders created before the match.
        if(mvkGPUTimestampArmed()||mvkGPUCounterBurstEnabled())objc_setAssociatedObject(encoder, sel_registerName("mvkGPUCounterRecordV1"), record, OBJC_ASSOCIATION_RETAIN);
    }
}
inline void mvkRecordEncoderWorkImpl(id<MTLCommandEncoder> encoder, NSString* kind, NSString* label) {
    if (!encoder || !mvkEncoderWorkTraceEnabled()) return;
    NSMutableData* data = objc_getAssociatedObject(encoder, mvkEncodedWorkKey());
    if (data) mvkAppendEncodedWork(data, encoder, kind, label);
    NSMutableDictionary* counterRecord=objc_getAssociatedObject(encoder,sel_registerName("mvkGPUCounterRecordV1"));
    if(counterRecord)mvkSampleGPUTimestamp(counterRecord,encoder,kind,label);
}
// Lazy arguments matter: disabled diagnostics must not allocate NSString
// labels for every fence, draw or dispatch before the helper can return.
#define mvkRecordEncoderWork(...) do { if (mvkEncoderWorkTraceEnabled()) mvkRecordEncoderWorkImpl(__VA_ARGS__); } while (false)
inline void mvkRecordDependencyPhase(id<MTLCommandBuffer> cb, NSString* phase) {
    if (!cb) return;
    NSMutableDictionary* record = objc_getAssociatedObject(cb, mvkDependencyKey());
    if (!record) return;
    // An arm controls creation, not the lifetime of an existing observation.
    // Completion must remain resolvable after the marker expires or is removed.
    if (![phase isEqualToString:@"completed"] && !mvkDependencyTraceEnabled()) return;
    @synchronized (record) {
        if([phase isEqualToString:@"completed"])record[@"nativeCompleted"]=@YES;
        NSMutableArray* phases = record[@"phases"];
        if (phases.count < 8) [phases addObject:@{
            @"phase":phase, @"order":@(mvkPendingDependencies().sequence.fetch_add(1)),
            @"time":@([NSDate timeIntervalSinceReferenceDate]), @"nativeStatus":@(cb.status)}];
    }
}
inline void mvkRecordEventDependency(id<MTLCommandBuffer> cb, id<MTLEvent> event,
                                     uint64_t value, NSString* operation, NSString* kind) {
    if (!cb || !event || !mvkDependencyTraceEnabled()) return;
    mvkStutterNativeEvent(cb,(__bridge const void*)event,value,
        [operation isEqualToString:@"signal"]?"signal":"wait",0,
        [event respondsToSelector:@selector(signaledValue)]?((id<MTLSharedEvent>)event).signaledValue:0,false);
    NSMutableDictionary* record = objc_getAssociatedObject(cb, mvkDependencyKey());
    if (!record) return;
    @synchronized (record) {
        NSMutableArray* events = record[@"events"];
        if (events.count >= 64) {
            record[@"truncatedEvents"] = @([record[@"truncatedEvents"] unsignedLongLongValue] + 1);
            return;
        }
        // Keep only the native event alive until this command buffer completes.
        // No Vulkan wrapper, buffer, texture or application data is retained.
        [events addObject:@{@"eventObject":event, @"operation":operation, @"kind":kind,
            @"requestedValue":@(value), @"valueAtEncode":mvkObservedEventValue(event),
            @"encodeTime":@([NSDate timeIntervalSinceReferenceDate])}];
    }
}
inline NSDictionary* mvkSnapshotDependencyRecord(NSDictionary* record) {
    if (!record) return @{};
    @synchronized (record) {
        NSDictionary* work = mvkSnapshotEncodedWork(record[@"workBuffer"]);
        NSMutableArray* events = [NSMutableArray array];
        for (NSDictionary* raw in record[@"events"]) {
            id<MTLEvent> event = raw[@"eventObject"];
            [events addObject:@{@"event":[NSString stringWithFormat:@"%p",event],
                @"operation":raw[@"operation"], @"kind":raw[@"kind"],
                @"requestedValue":raw[@"requestedValue"], @"valueAtEncode":raw[@"valueAtEncode"],
                @"valueAtObservation":mvkObservedEventValue(event), @"encodeTime":raw[@"encodeTime"]}];
        }
        return @{@"logicalDevice":record[@"logicalDevice"], @"logicalQueue":record[@"logicalQueue"],
            @"nativeQueue":record[@"nativeQueue"], @"phases":[NSArray arrayWithArray:record[@"phases"]],
            @"nativeCommandBufferLabel":record[@"nativeCommandBufferLabel"] ?: @"",
            @"nativeCBID":record[@"nativeCBID"]?:@0,
            @"logicalSubmissionID":record[@"logicalSubmissionID"]?:@0,
            @"nativeSplitIndex":record[@"nativeSplitIndex"]?:@0,
            @"presentFrameID":record[@"presentFrameID"]?:@0,
            @"nativeCommandBuffer":record[@"nativeCommandBuffer"]?:@"",
            @"submission":record[@"submission"], @"queueFamily":record[@"queueFamily"],
            @"queueIndex":record[@"queueIndex"], @"createdTime":record[@"createdTime"],
            @"events":events, @"truncatedEvents":record[@"truncatedEvents"],
            @"gpuTimestamps":mvkSnapshotGPUTimestamps(record),
            @"workEvents":work[@"workEvents"],
            @"workCount":work[@"workCount"], @"truncatedWorkEvents":work[@"truncatedWorkEvents"]};
    }
}
inline NSDictionary* mvkCommandBufferDependencies(id<MTLCommandBuffer> cb) {
    return mvkSnapshotDependencyRecord(objc_getAssociatedObject(cb, mvkDependencyKey()));
}
inline NSArray* mvkSnapshotPendingDependencies() {
    auto& state = mvkPendingDependencies();
    NSArray* records;
    {
        std::lock_guard<std::mutex> lock(state.lock);
        records = [state.records.allValues retain];
    }
    NSMutableArray* result = [NSMutableArray array];
    for (NSDictionary* record in records) [result addObject:mvkSnapshotDependencyRecord(record)];
    [records release];
    return result;
}
inline void mvkMarkDependencyCounterCommit(id<MTLCommandBuffer> cb) {
    if (!cb) return;
    NSDictionary* record=objc_getAssociatedObject(cb,mvkDependencyKey());
    if(record)mvkMarkGPUCounterCommit(record);
}
inline void mvkEndDependencyTrace(id<MTLCommandBuffer> cb) {
    // Always release an existing record's counter budgets and registry entry,
    // including when timed capture was disabled before this CB completed.
    if (!cb) return;
    NSDictionary* record = objc_getAssociatedObject(cb, mvkDependencyKey());
    if (!record) return;
    auto& state = mvkPendingDependencies();
    {
        std::lock_guard<std::mutex> lock(state.lock);
        [state.records removeObjectForKey:record[@"submission"]];
    }
    mvkEndGPUTimestamps(record);
    // Releasing native event objects must not hold the registry mutex.
    objc_setAssociatedObject(cb, mvkDependencyKey(), nil, OBJC_ASSOCIATION_RETAIN);
}
