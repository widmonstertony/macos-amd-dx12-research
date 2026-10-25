// Bounded CPU diagnostics only. No GPU commands, resources, or semaphore changes.
#pragma once
#import <Foundation/Foundation.h>
#include "MVKStutterCoverage.h"
#include <os/lock.h>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <new>
#include <type_traits>
#include <cassert>
#include <vector>
#include <objc/runtime.h>

struct MVKEncodedWorkEvent {
    uint64_t index;
    double time;
    uintptr_t encoder;
    char kind[40];
    char label[512];
};
struct MVKEncodedWorkRing {
    os_unfair_lock lock;
    uint64_t count;
    // Most native command buffers contain far fewer than 64 work records.
    // Do not zero 580 KiB for every one of hundreds of submissions per second.
    // The associated overflow data is allocated only at event 65, and retained
    // by this ring's NSMutableData owner until both encoders and snapshots finish.
    MVKEncodedWorkEvent events[64];
    MVKEncodedWorkEvent* overflow;
};

inline size_t mvkEncodedWorkSlot(uint64_t index) {
    return index < 64 ? size_t(index) : 64 + size_t((index - 64) % 960);
}
inline NSMutableData* mvkNewEncodedWorkRing() {
    MVK_CPU_SCOPE(WorkTrace);
    static_assert(std::is_trivially_destructible<MVKEncodedWorkRing>::value, "Data owner must not need a C++ destructor");
    NSMutableData* data = [NSMutableData dataWithLength:sizeof(MVKEncodedWorkRing)];
    assert(reinterpret_cast<uintptr_t>(data.mutableBytes) % alignof(MVKEncodedWorkRing) == 0);
    auto* ring = new (data.mutableBytes) MVKEncodedWorkRing;
    ring->lock = OS_UNFAIR_LOCK_INIT;
    ring->count = 0;
    ring->overflow = nullptr;
    return data;
}
inline void mvkAppendEncodedWorkBytes(NSMutableData* data, const void* encoder,
                                     const char* kindText, const char* labelText) {
    MVK_CPU_SCOPE(WorkTrace);
    auto* ring = static_cast<MVKEncodedWorkRing*>(data.mutableBytes);
    os_unfair_lock_lock(&ring->lock);
    uint64_t index = ring->count++;
    size_t slot = mvkEncodedWorkSlot(index);
    if (slot >= 64 && !ring->overflow) {
        NSMutableData* overflow = [NSMutableData dataWithLength:960*sizeof(MVKEncodedWorkEvent)];
        objc_setAssociatedObject(data, sel_registerName("mvkEncodedWorkOverflowV1"), overflow,
                                 OBJC_ASSOCIATION_RETAIN);
        ring->overflow = static_cast<MVKEncodedWorkEvent*>(overflow.mutableBytes);
    }
    auto& event = slot < 64 ? ring->events[slot] : ring->overflow[slot-64];
    event.index = index;
    event.time = CFAbsoluteTimeGetCurrent();
    event.encoder = reinterpret_cast<uintptr_t>(encoder);
    strlcpy(event.kind, kindText, sizeof(event.kind));
    strlcpy(event.label, labelText, sizeof(event.label));
    os_unfair_lock_unlock(&ring->lock);
}
inline void mvkAppendEncodedWork(NSMutableData* data, const void* encoder, NSString* kind, NSString* label) {
    // Existing callers and the armed GPU-counter route keep their exact labels.
    mvkAppendEncodedWorkBytes(data,encoder,kind.UTF8String ?: "",label.UTF8String ?: "");
}
inline NSDictionary* mvkSnapshotEncodedWork(NSMutableData* data) {
    MVK_CPU_SCOPE(WorkTrace);
    if (!data) return @{@"workEvents":@[], @"workCount":@0, @"truncatedWorkEvents":@0};
    auto* ring = static_cast<MVKEncodedWorkRing*>(data.mutableBytes);
    // Copy bounded bytes under the ring lock. Foundation allocations happen
    // afterwards, only when an actual failure snapshot is requested.
    // Metal completion queues have a small worker stack (520 KiB on the
    // affected Intel macOS host). Each event is more than 560 bytes, so the
    // full diagnostic ring must never be copied to that stack.
    std::vector<MVKEncodedWorkEvent> copy;
    os_unfair_lock_lock(&ring->lock);
    uint64_t count = ring->count;
    size_t size = size_t(std::min<uint64_t>(count, 1024));
    copy.resize(size);
    for (size_t i = 0; i < size; ++i) {
        uint64_t index = i < 64 || count <= 1024 ? i : count - 960 + i - 64;
        size_t slot = mvkEncodedWorkSlot(index);
        copy[i] = slot < 64 ? ring->events[slot] : ring->overflow[slot-64];
    }
    os_unfair_lock_unlock(&ring->lock);
    NSMutableArray* events = [NSMutableArray arrayWithCapacity:size];
    for (size_t i = 0; i < size; ++i) {
        const auto& event = copy[i];
        // A byte cap can split a UTF-8 code point; preserve diagnostic validity.
        NSString* label = [NSString stringWithUTF8String:event.label] ?: @"<truncated UTF-8 label>";
        [events addObject:@{@"index":@(event.index), @"time":@(event.time),
            @"encoder":[NSString stringWithFormat:@"%p",reinterpret_cast<void*>(event.encoder)],
            @"kind":[NSString stringWithUTF8String:event.kind] ?: @"", @"label":label}];
    }
    return @{@"workEvents":events, @"workCount":@(count), @"truncatedWorkEvents":@(count > 1024 ? count - 1024 : 0)};
}
