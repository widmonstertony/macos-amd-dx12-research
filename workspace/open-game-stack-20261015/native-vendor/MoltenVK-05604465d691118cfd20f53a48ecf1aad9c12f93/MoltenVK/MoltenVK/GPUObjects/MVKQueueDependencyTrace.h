// Public Metal event observations only. Never modifies semaphore values, waits,
// completion results, watchdogs, or hardware feature reports.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <atomic>
#include <mutex>

inline bool mvkDependencyTraceEnabled() {
    static const bool enabled = [] { const char* v = getenv("MVK_AMD_GPU_TIMEOUT_TRACE"); return v && !strcmp(v, "1"); }();
    return enabled;
}
inline const void* mvkDependencyKey() { return sel_registerName("mvkQueueDependenciesV1"); }
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
inline void mvkBeginDependencyTrace(id<MTLCommandBuffer> cb, uint32_t family, uint32_t index) {
    if (!cb || !mvkDependencyTraceEnabled()) return;
    auto& state = mvkPendingDependencies();
    NSNumber* serial = @(state.sequence.fetch_add(1));
    NSMutableDictionary* record = [@{@"submission":serial, @"queueFamily":@(family),
        @"queueIndex":@(index), @"createdTime":@([NSDate timeIntervalSinceReferenceDate]),
        @"events":[NSMutableArray array], @"truncatedEvents":@0} mutableCopy];
    objc_setAssociatedObject(cb, mvkDependencyKey(), record, OBJC_ASSOCIATION_RETAIN);
    {
        std::lock_guard<std::mutex> lock(state.lock);
        // Bound global snapshots. A command buffer's own event record is still
        // available even if the pending registry is full.
        if (state.records.count < 256) state.records[serial] = record;
    }
    [record release];
}
inline void mvkRecordEventDependency(id<MTLCommandBuffer> cb, id<MTLEvent> event,
                                     uint64_t value, NSString* operation, NSString* kind) {
    if (!cb || !event || !mvkDependencyTraceEnabled()) return;
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
        NSMutableArray* events = [NSMutableArray array];
        for (NSDictionary* raw in record[@"events"]) {
            id<MTLEvent> event = raw[@"eventObject"];
            [events addObject:@{@"event":[NSString stringWithFormat:@"%p",event],
                @"operation":raw[@"operation"], @"kind":raw[@"kind"],
                @"requestedValue":raw[@"requestedValue"], @"valueAtEncode":raw[@"valueAtEncode"],
                @"valueAtObservation":mvkObservedEventValue(event), @"encodeTime":raw[@"encodeTime"]}];
        }
        return @{@"submission":record[@"submission"], @"queueFamily":record[@"queueFamily"],
            @"queueIndex":record[@"queueIndex"], @"createdTime":record[@"createdTime"],
            @"events":events, @"truncatedEvents":record[@"truncatedEvents"]};
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
inline void mvkEndDependencyTrace(id<MTLCommandBuffer> cb) {
    if (!mvkDependencyTraceEnabled()) return;
    NSDictionary* record = objc_getAssociatedObject(cb, mvkDependencyKey());
    if (!record) return;
    auto& state = mvkPendingDependencies();
    {
        std::lock_guard<std::mutex> lock(state.lock);
        [state.records removeObjectForKey:record[@"submission"]];
    }
    // Releasing native event objects must not hold the registry mutex.
    objc_setAssociatedObject(cb, mvkDependencyKey(), nil, OBJC_ASSOCIATION_RETAIN);
}
