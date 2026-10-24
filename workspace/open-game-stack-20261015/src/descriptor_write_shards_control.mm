// CPU concurrency oracle for address-striped descriptor write protection.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKDescriptorUseCache.h"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <set>
#include <stdexcept>
#include <thread>

static void need(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static id<MTLResource> key(unsigned writer, unsigned version) {
    return (id<MTLResource>)(uintptr_t(0x1000000 + writer * 0x10000 + version * 0x100));
}

struct Result { double milliseconds; unsigned snapshots; };

static double runWideGateControl() {
    setenv("MVK_AMD_DESCRIPTOR_WRITE_SHARDS", "1", 1);
    std::vector<id<MTLResource>> slots(1024, nil);
    MVKDescriptorUseCache cache;
    cache.resources((const char*)slots.data(), slots.size(), sizeof(id));
    std::atomic<bool> wideLocked{false};
    std::thread wide([&] {
        auto guard = cache.beginWrite((const char*)slots.data(), slots.size() * sizeof(id));
        wideLocked.store(true, std::memory_order_release);
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
        slots[0] = key(0, 1);
    });
    while (!wideLocked.load(std::memory_order_acquire)) {}
    auto before = std::chrono::steady_clock::now();
    {
        auto guard = cache.beginWrite((const char*)&slots[1], sizeof(id));
        slots[1] = key(1, 1);
    }
    double blockedMS = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - before).count();
    wide.join();
    auto snapshot = cache.resources((const char*)slots.data(), slots.size(), sizeof(id));
    need(blockedMS >= 25.0, "narrow write did not wait for overlapping wide gate");
    need(snapshot->size() == 2 && snapshot->contains(key(0, 1)) && snapshot->contains(key(1, 1)),
         "wide gate produced an incomplete snapshot");
    return blockedMS;
}

static double runSameStripeScope(bool narrow) {
    setenv("MVK_AMD_DESCRIPTOR_WRITE_SHARDS", "1", 1);
    constexpr unsigned writers = 8, iterations = 1200;
    std::vector<id<MTLResource>> slots(writers, nil);
    MVKDescriptorUseCache cache;
    cache.resources((const char*)slots.data(), writers, sizeof(id));
    std::atomic<bool> start{false};
    std::vector<std::thread> threads;
    auto before = std::chrono::steady_clock::now();
    for (unsigned writer = 0; writer < writers; ++writer) threads.emplace_back([&, writer] {
        while (!start.load(std::memory_order_acquire)) {}
        for (unsigned iteration = 0; iteration < iterations; ++iteration) {
            if (narrow) {
                {
                    auto guard = cache.beginWrite((const char*)&slots[writer], sizeof(id));
                    slots[writer] = key(writer, iteration & 15);
                }
                // Model Metal argument-buffer encoding after the CPU-table
                // guard has been released by writeDescriptorSetBinding().
                auto until = std::chrono::steady_clock::now() + std::chrono::microseconds(25);
                while (std::chrono::steady_clock::now() < until) {}
            } else {
                auto guard = cache.beginWrite((const char*)&slots[writer], sizeof(id));
                slots[writer] = key(writer, iteration & 15);
                auto until = std::chrono::steady_clock::now() + std::chrono::microseconds(25);
                while (std::chrono::steady_clock::now() < until) {}
            }
        }
    });
    start.store(true, std::memory_order_release);
    for (auto& thread : threads) thread.join();
    auto final = cache.resources((const char*)slots.data(), writers, sizeof(id));
    std::set<id<MTLResource>> expected;
    for (unsigned writer = 0; writer < writers; ++writer) expected.insert(key(writer, (iterations - 1) & 15));
    need(std::set<id<MTLResource>>(final->begin(), final->end()) == expected,
         "same-stripe scope oracle differs");
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - before).count();
}

static Result run(bool sharded) {
    if (sharded) setenv("MVK_AMD_DESCRIPTOR_WRITE_SHARDS", "1", 1);
    else unsetenv("MVK_AMD_DESCRIPTOR_WRITE_SHARDS");
    constexpr unsigned writers = 8, iterations = 1200, slotsPerWriter = 16;
    constexpr unsigned slotCount = writers * slotsPerWriter;
    std::vector<id<MTLResource>> slots(slotCount, nil);
    MVKDescriptorUseCache cache;
    cache.resources((const char*)slots.data(), slotCount, sizeof(id));
    std::atomic<bool> start{false}, done{false};
    std::atomic<unsigned> snapshots{0};
    std::thread reader([&] {
        while (!start.load(std::memory_order_acquire)) {}
        while (!done.load(std::memory_order_acquire)) {
            auto snapshot = cache.resources((const char*)slots.data(), slotCount, sizeof(id));
            for (id<MTLResource> item : *snapshot) {
                uintptr_t value = (uintptr_t)item;
                need(value >= 0x1000000 && value < 0x1080000, "snapshot contains invalid identity");
            }
            ++snapshots;
        }
    });
    std::vector<std::thread> threads;
    auto before = std::chrono::steady_clock::now();
    for (unsigned writer = 0; writer < writers; ++writer) threads.emplace_back([&, writer] {
        while (!start.load(std::memory_order_acquire)) {}
        unsigned slot = writer * slotsPerWriter;
        for (unsigned iteration = 0; iteration < iterations; ++iteration) {
            auto guard = cache.beginWrite((const char*)&slots[slot], sizeof(id));
            slots[slot] = key(writer, iteration & 15);
            // Model the real argument-buffer encoding that currently occurs
            // while the cache write guard is alive.
            auto until = std::chrono::steady_clock::now() + std::chrono::microseconds(25);
            while (std::chrono::steady_clock::now() < until) {}
        }
    });
    start.store(true, std::memory_order_release);
    for (auto& thread : threads) thread.join();
    done.store(true, std::memory_order_release);
    reader.join();
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - before).count();
    auto final = cache.resources((const char*)slots.data(), slotCount, sizeof(id));
    std::set<id<MTLResource>> expected;
    for (unsigned writer = 0; writer < writers; ++writer) expected.insert(key(writer, (iterations - 1) & 15));
    need(std::set<id<MTLResource>>(final->begin(), final->end()) == expected,
         "final snapshot differs from disjoint writer oracle");
    return {ms, snapshots.load()};
}

int main() { @autoreleasepool { try {
    auto global = run(false);
    auto sharded = run(true);
    auto extendedSameStripe = runSameStripeScope(false);
    auto scopedSameStripe = runSameStripeScope(true);
    auto wideGateBlockedMS = runWideGateControl();
    need(sharded.snapshots > 0 && global.snapshots > 0, "reader made no progress");
    need(scopedSameStripe < extendedSameStripe, "narrow guard did not improve same-stripe updates");
    printf("{\"passed\":true,\"writers\":8,\"iterationsPerWriter\":1200,"
           "\"globalMilliseconds\":%.3f,\"shardedMilliseconds\":%.3f,"
           "\"speedup\":%.3f,\"globalSnapshots\":%u,\"shardedSnapshots\":%u,"
           "\"extendedSameStripeMilliseconds\":%.3f,\"scopedSameStripeMilliseconds\":%.3f,"
           "\"scopeSpeedup\":%.3f,\"wideGateBlockedMilliseconds\":%.3f,"
           "\"wideNarrowCoordination\":true}\n",
           global.milliseconds, sharded.milliseconds, global.milliseconds / sharded.milliseconds,
           global.snapshots, sharded.snapshots, extendedSameStripe, scopedSameStripe,
           extendedSameStripe / scopedSameStripe, wideGateBlockedMS);
    return 0;
} catch (const std::exception& error) {
    fprintf(stderr, "ERROR %s\n", error.what());
    return 2;
} } }
