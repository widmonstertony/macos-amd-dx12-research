// Bounded CPU diagnostics only. No GPU commands, resources, or semaphore changes.
#pragma once
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <new>
#include <type_traits>
#include <cassert>

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
    MVKEncodedWorkEvent events[64];
};

inline size_t mvkEncodedWorkSlot(uint64_t index) {
    return index < 16 ? size_t(index) : 16 + size_t((index - 16) % 48);
}
inline NSMutableData* mvkNewEncodedWorkRing() {
    static_assert(std::is_trivially_destructible<MVKEncodedWorkRing>::value, "Data owner must not need a C++ destructor");
    NSMutableData* data = [NSMutableData dataWithLength:sizeof(MVKEncodedWorkRing)];
    assert(reinterpret_cast<uintptr_t>(data.mutableBytes) % alignof(MVKEncodedWorkRing) == 0);
    auto* ring = new (data.mutableBytes) MVKEncodedWorkRing;
    ring->lock = OS_UNFAIR_LOCK_INIT;
    ring->count = 0;
    return data;
}
inline void mvkAppendEncodedWork(NSMutableData* data, const void* encoder, NSString* kind, NSString* label) {
    auto* ring = static_cast<MVKEncodedWorkRing*>(data.mutableBytes);
    // Prepare string bytes before locking; snapshotting never needs the encoder.
    const char* kindText = kind.UTF8String ?: "";
    const char* labelText = label.UTF8String ?: "";
    os_unfair_lock_lock(&ring->lock);
    uint64_t index = ring->count++;
    auto& event = ring->events[mvkEncodedWorkSlot(index)];
    event.index = index;
    event.time = CFAbsoluteTimeGetCurrent();
    event.encoder = reinterpret_cast<uintptr_t>(encoder);
    strlcpy(event.kind, kindText, sizeof(event.kind));
    strlcpy(event.label, labelText, sizeof(event.label));
    os_unfair_lock_unlock(&ring->lock);
}
inline NSDictionary* mvkSnapshotEncodedWork(NSMutableData* data) {
    if (!data) return @{@"workEvents":@[], @"workCount":@0, @"truncatedWorkEvents":@0};
    auto* ring = static_cast<MVKEncodedWorkRing*>(data.mutableBytes);
    // Copy bounded bytes under the ring lock. Foundation allocations happen
    // afterwards, only when an actual failure snapshot is requested.
    MVKEncodedWorkEvent copy[64];
    os_unfair_lock_lock(&ring->lock);
    uint64_t count = ring->count;
    size_t size = size_t(std::min<uint64_t>(count, 64));
    for (size_t i = 0; i < size; ++i) {
        uint64_t index = i < 16 || count <= 64 ? i : count - 48 + i - 16;
        copy[i] = ring->events[mvkEncodedWorkSlot(index)];
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
    return @{@"workEvents":events, @"workCount":@(count), @"truncatedWorkEvents":@(count > 64 ? count - 64 : 0)};
}
