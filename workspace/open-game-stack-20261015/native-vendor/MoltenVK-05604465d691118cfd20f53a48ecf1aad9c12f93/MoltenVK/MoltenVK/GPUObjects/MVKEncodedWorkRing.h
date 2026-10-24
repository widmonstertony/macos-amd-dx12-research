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
#include <vector>

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
    // Timed diagnostics only. A UE menu transition can encode more than one
    // hundred pipeline and encoder boundaries into the command buffer that
    // later trips the GPU watchdog. Keep that complete frame locally so a
    // failure snapshot does not discard the expensive middle encoder.
    MVKEncodedWorkEvent events[1024];
};

inline size_t mvkEncodedWorkSlot(uint64_t index) {
    return index < 64 ? size_t(index) : 64 + size_t((index - 64) % 960);
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
    return @{@"workEvents":events, @"workCount":@(count), @"truncatedWorkEvents":@(count > 1024 ? count - 1024 : 0)};
}
