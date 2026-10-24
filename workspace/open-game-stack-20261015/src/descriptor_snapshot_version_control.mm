#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "MVKDescriptorUseCache.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;

static id<MTLResource> fakeResource(uintptr_t value) {
    return reinterpret_cast<id<MTLResource>>(value << 4);
}

struct StridedDescriptor {
    id<MTLResource> resource;
    uint64_t offset;
    uint64_t size;
};

struct TwoIDStridedDescriptor {
    id<MTLResource> texture;
    id<MTLResource> buffer;
    uint64_t offset;
    uint64_t size;
};

int main() {
    constexpr uint32_t count = 4096;
    constexpr uint32_t iterations = 100000;
    std::vector<id<MTLResource>> slots(count);
    for (uint32_t i = 0; i < count; ++i) slots[i] = fakeResource(i + 1);

    MVKDescriptorUseCache cache;
    uint64_t version = 0;
    auto snapshot = cache.resources(reinterpret_cast<const char*>(slots.data()), count, sizeof(id), &version);
    bool initialCorrect = snapshot && snapshot->size() == count;

    auto baselineStart = Clock::now();
    for (uint32_t i = 0; i < iterations; ++i)
        snapshot = cache.resources(reinterpret_cast<const char*>(slots.data()), count, sizeof(id));
    auto baselineEnd = Clock::now();

    auto fastStart = Clock::now();
    uint64_t fastHits = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        if (cache.canReuseSnapshot(version)) ++fastHits;
        else snapshot = cache.resources(reinterpret_cast<const char*>(slots.data()), count, sizeof(id), &version);
    }
    auto fastEnd = Clock::now();

    bool blockedDuringWrite = false;
    uint64_t versionBeforeWrite = version;
    {
        auto guard = cache.beginWrite(reinterpret_cast<const char*>(&slots[17]), sizeof(id));
        blockedDuringWrite = !cache.canReuseSnapshot(versionBeforeWrite);
        slots[17] = fakeResource(count + 17);
    }
    bool invalidatedAfterWrite = !cache.canReuseSnapshot(versionBeforeWrite);
    snapshot = cache.resources(reinterpret_cast<const char*>(slots.data()), count, sizeof(id), &version);
    bool changedVisible = std::find(snapshot->begin(), snapshot->end(), fakeResource(count + 17)) != snapshot->end();

    // A write to one descriptor range must not invalidate a cached snapshot
    // for a disjoint range in the same descriptor set backing allocation.
    MVKDescriptorUseCache rangeCache;
    constexpr uint32_t rangeCount = 256;
    std::vector<id<MTLResource>> rangeSlots(rangeCount * 2);
    for (uint32_t i = 0; i < rangeSlots.size(); ++i)
        rangeSlots[i] = fakeResource(count * 2 + i + 1);
    auto rangeA = rangeCache.versionedResources(reinterpret_cast<const char*>(rangeSlots.data()),
                                                 rangeCount, sizeof(id));
    auto rangeB = rangeCache.versionedResources(reinterpret_cast<const char*>(rangeSlots.data() + rangeCount),
                                                 rangeCount, sizeof(id));
    MVKDescriptorUseCache::takeWriteStats();
    auto rangeBIdentity = rangeB.snapshot;
    bool noOpBlockedDuringWrite = false;
    {
        auto guard = rangeCache.beginWrite(reinterpret_cast<const char*>(&rangeSlots[rangeCount + 9]), sizeof(id));
        noOpBlockedDuringWrite = !rangeB.reuse.canReuse();
        rangeSlots[rangeCount + 9] = rangeSlots[rangeCount + 9];
    }
    bool noOpReusableAfterWrite = rangeB.reuse.canReuse();
    auto noOpRefresh = rangeCache.versionedResources(reinterpret_cast<const char*>(rangeSlots.data() + rangeCount),
                                                      rangeCount, sizeof(id));
    bool noOpSnapshotIdentityPreserved = noOpRefresh.snapshot == rangeBIdentity;
    auto noOpStats = MVKDescriptorUseCache::takeWriteStats();
    bool noOpClassified = noOpStats.ranges == 1 && noOpStats.unchangedRanges == 1 &&
                          noOpStats.changedRanges == 0;
    bool disjointReusableDuringWrite = false;
    bool overlappingBlockedDuringWrite = false;
    {
        auto guard = rangeCache.beginWrite(reinterpret_cast<const char*>(&rangeSlots[7]), sizeof(id));
        overlappingBlockedDuringWrite = !rangeA.reuse.canReuse();
        disjointReusableDuringWrite = rangeB.reuse.canReuse();
        rangeSlots[7] = fakeResource(count * 4 + 7);
    }
    bool overlappingInvalidated = !rangeA.reuse.canReuse();
    bool disjointStillReusable = rangeB.reuse.canReuse();
    rangeA = rangeCache.versionedResources(reinterpret_cast<const char*>(rangeSlots.data()),
                                            rangeCount, sizeof(id));
    bool rangeWriteVisible = std::find(rangeA.snapshot->begin(), rangeA.snapshot->end(),
                                       fakeResource(count * 4 + 7)) != rangeA.snapshot->end();

    // Real buffer descriptors are strided: resource identity is followed by
    // offset/size metadata. Metadata-only updates must not invalidate the
    // resource snapshot, while replacing the resource still must.
    MVKDescriptorUseCache stridedCache;
    std::vector<StridedDescriptor> strided(rangeCount);
    for (uint32_t i = 0; i < rangeCount; ++i)
        strided[i] = {fakeResource(count * 6 + i + 1), i * 256, 4096};
    auto stridedSnapshot = stridedCache.versionedResources(
        reinterpret_cast<const char*>(&strided[0].resource), rangeCount, sizeof(StridedDescriptor));
    auto stridedIdentity = stridedSnapshot.snapshot;
    MVKDescriptorUseCache::takeWriteStats();
    {
        auto guard = stridedCache.beginWrite(reinterpret_cast<const char*>(&strided[19]), sizeof(StridedDescriptor));
        strided[19].offset += 128;
        strided[19].size -= 128;
    }
    bool stridedMetadataReuse = stridedSnapshot.reuse.canReuse();
    auto stridedMetadataRefresh = stridedCache.versionedResources(
        reinterpret_cast<const char*>(&strided[0].resource), rangeCount, sizeof(StridedDescriptor));
    auto stridedMetadataStats = MVKDescriptorUseCache::takeWriteStats();
    bool stridedMetadataClassified = stridedMetadataStats.ranges == 1 &&
                                     stridedMetadataStats.unchangedRanges == 1 &&
                                     stridedMetadataStats.changedRanges == 0;
    bool stridedSnapshotIdentityPreserved = stridedMetadataRefresh.snapshot == stridedIdentity;
    id<MTLResource> stridedReplacement = fakeResource(count * 8 + 19);
    {
        auto guard = stridedCache.beginWrite(reinterpret_cast<const char*>(&strided[19]), sizeof(StridedDescriptor));
        strided[19].resource = stridedReplacement;
    }
    bool stridedResourceInvalidated = !stridedMetadataRefresh.reuse.canReuse();
    auto stridedResourceRefresh = stridedCache.versionedResources(
        reinterpret_cast<const char*>(&strided[0].resource), rangeCount, sizeof(StridedDescriptor));
    auto stridedResourceStats = MVKDescriptorUseCache::takeWriteStats();
    bool stridedResourceClassified = stridedResourceStats.ranges == 1 &&
                                     stridedResourceStats.unchangedRanges == 0 &&
                                     stridedResourceStats.changedRanges == 1;
    bool stridedResourceVisible = std::find(stridedResourceRefresh.snapshot->begin(),
                                            stridedResourceRefresh.snapshot->end(),
                                            stridedReplacement) != stridedResourceRefresh.snapshot->end();

    MVKDescriptorUseCache twoIDCache;
    std::vector<TwoIDStridedDescriptor> twoID(rangeCount);
    for (uint32_t i = 0; i < rangeCount; ++i)
        twoID[i] = {fakeResource(count * 10 + i + 1), fakeResource(count * 12 + i + 1), i * 64, 2048};
    auto textureSnapshot = twoIDCache.versionedResources(
        reinterpret_cast<const char*>(&twoID[0].texture), rangeCount, sizeof(TwoIDStridedDescriptor));
    auto bufferSnapshot = twoIDCache.versionedResources(
        reinterpret_cast<const char*>(&twoID[0].buffer), rangeCount, sizeof(TwoIDStridedDescriptor));
    MVKDescriptorUseCache::takeWriteStats();
    {
        auto guard = twoIDCache.beginWrite(reinterpret_cast<const char*>(&twoID[23]), sizeof(TwoIDStridedDescriptor));
        twoID[23].offset += 32;
    }
    bool twoIDMetadataReuse = textureSnapshot.reuse.canReuse() && bufferSnapshot.reuse.canReuse();
    id<MTLResource> bufferReplacement = fakeResource(count * 14 + 23);
    {
        auto guard = twoIDCache.beginWrite(reinterpret_cast<const char*>(&twoID[23]), sizeof(TwoIDStridedDescriptor));
        twoID[23].buffer = bufferReplacement;
    }
    bool twoIDOnlyChangedIdentityInvalidated = textureSnapshot.reuse.canReuse() && !bufferSnapshot.reuse.canReuse();
    auto bufferRefresh = twoIDCache.versionedResources(
        reinterpret_cast<const char*>(&twoID[0].buffer), rangeCount, sizeof(TwoIDStridedDescriptor));
    bool twoIDReplacementVisible = std::find(bufferRefresh.snapshot->begin(), bufferRefresh.snapshot->end(),
                                             bufferReplacement) != bufferRefresh.snapshot->end();

    constexpr uint32_t stridedIterations = 50000;
    auto stridedNoOpStart = Clock::now();
    for (uint32_t i = 0; i < stridedIterations; ++i) {
        auto guard = stridedCache.beginWrite(reinterpret_cast<const char*>(&strided[31]), sizeof(StridedDescriptor));
        strided[31].offset += 16;
        guard = {};
        stridedResourceRefresh = stridedCache.versionedResources(
            reinterpret_cast<const char*>(&strided[0].resource), rangeCount, sizeof(StridedDescriptor));
    }
    auto stridedNoOpEnd = Clock::now();

    std::atomic<bool> start{false}, done{false};
    std::thread writer([&] {
        while (!start.load(std::memory_order_acquire)) {}
        for (uint32_t i = 0; i < 2000; ++i) {
            auto guard = cache.beginWrite(reinterpret_cast<const char*>(&slots[31]), sizeof(id));
            slots[31] = fakeResource(count + 100 + i);
            if ((i & 31) == 0) std::this_thread::yield();
        }
        done.store(true, std::memory_order_release);
    });
    start.store(true, std::memory_order_release);
    uint64_t concurrentRefreshes = 0;
    while (!done.load(std::memory_order_acquire)) {
        if (!cache.canReuseSnapshot(version)) {
            snapshot = cache.resources(reinterpret_cast<const char*>(slots.data()), count, sizeof(id), &version);
            ++concurrentRefreshes;
        }
        std::this_thread::yield();
    }
    writer.join();
    if (!cache.canReuseSnapshot(version)) {
        snapshot = cache.resources(reinterpret_cast<const char*>(slots.data()), count, sizeof(id), &version);
        ++concurrentRefreshes;
    }
    bool finalVisible = std::find(snapshot->begin(), snapshot->end(), fakeResource(count + 100 + 1999)) != snapshot->end();
    bool finalSizeCorrect = snapshot->size() == count;

    double baselineMS = std::chrono::duration<double, std::milli>(baselineEnd - baselineStart).count();
    double fastMS = std::chrono::duration<double, std::milli>(fastEnd - fastStart).count();
    bool passed = initialCorrect && fastHits == iterations && blockedDuringWrite &&
                  invalidatedAfterWrite && changedVisible && overlappingBlockedDuringWrite &&
                  disjointReusableDuringWrite && overlappingInvalidated && disjointStillReusable &&
                  rangeWriteVisible && noOpBlockedDuringWrite && noOpReusableAfterWrite &&
                  noOpSnapshotIdentityPreserved && noOpClassified && stridedMetadataReuse &&
                  stridedMetadataClassified && stridedSnapshotIdentityPreserved &&
                  stridedResourceInvalidated && stridedResourceClassified && stridedResourceVisible &&
                  twoIDMetadataReuse && twoIDOnlyChangedIdentityInvalidated && twoIDReplacementVisible &&
                  concurrentRefreshes > 0 &&
                  finalVisible && finalSizeCorrect;
    std::printf("{\"passed\":%s,\"entries\":%u,\"iterations\":%u,"
                "\"baselineMilliseconds\":%.6f,\"fastMilliseconds\":%.6f,\"speedup\":%.6f,"
                "\"fastHits\":%llu,\"blockedDuringWrite\":%s,\"invalidatedAfterWrite\":%s,"
                "\"overlappingBlockedDuringWrite\":%s,\"disjointReusableDuringWrite\":%s,"
                "\"overlappingInvalidated\":%s,\"disjointStillReusable\":%s,\"rangeWriteVisible\":%s,"
                "\"noOpBlockedDuringWrite\":%s,\"noOpReusableAfterWrite\":%s,"
                "\"noOpSnapshotIdentityPreserved\":%s,\"noOpClassified\":%s,"
                "\"stridedMetadataReuse\":%s,\"stridedMetadataClassified\":%s,"
                "\"stridedSnapshotIdentityPreserved\":%s,\"stridedResourceInvalidated\":%s,"
                "\"stridedResourceClassified\":%s,\"stridedResourceVisible\":%s,"
                "\"twoIDMetadataReuse\":%s,\"twoIDOnlyChangedIdentityInvalidated\":%s,"
                "\"twoIDReplacementVisible\":%s,"
                "\"stridedNoOpIterations\":%u,\"stridedNoOpMilliseconds\":%.6f,"
                "\"concurrentRefreshes\":%llu,\"finalSnapshotCorrect\":%s}\n",
                passed ? "true" : "false", count, iterations, baselineMS, fastMS,
                fastMS > 0.0 ? baselineMS / fastMS : 0.0,
                static_cast<unsigned long long>(fastHits), blockedDuringWrite ? "true" : "false",
                invalidatedAfterWrite ? "true" : "false",
                overlappingBlockedDuringWrite ? "true" : "false",
                disjointReusableDuringWrite ? "true" : "false",
                overlappingInvalidated ? "true" : "false",
                disjointStillReusable ? "true" : "false",
                rangeWriteVisible ? "true" : "false",
                noOpBlockedDuringWrite ? "true" : "false",
                noOpReusableAfterWrite ? "true" : "false",
                noOpSnapshotIdentityPreserved ? "true" : "false",
                noOpClassified ? "true" : "false",
                stridedMetadataReuse ? "true" : "false",
                stridedMetadataClassified ? "true" : "false",
                stridedSnapshotIdentityPreserved ? "true" : "false",
                stridedResourceInvalidated ? "true" : "false",
                stridedResourceClassified ? "true" : "false",
                stridedResourceVisible ? "true" : "false",
                twoIDMetadataReuse ? "true" : "false",
                twoIDOnlyChangedIdentityInvalidated ? "true" : "false",
                twoIDReplacementVisible ? "true" : "false",
                stridedIterations,
                std::chrono::duration<double, std::milli>(stridedNoOpEnd - stridedNoOpStart).count(),
                static_cast<unsigned long long>(concurrentRefreshes),
                (finalVisible && finalSizeCorrect) ? "true" : "false");
    return passed ? 0 : 1;
}
