// Immutable read-residency plan for an owned, validated resource lease.
// Texture mode admits readonly native resources for both sample and read;
// writes and resource-level exclusions remain precise. Encoder/stage/write coverage and
// strong child ownership are independent of this immutable grouping.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <memory>
#include <mutex>
#include <atomic>
#include <algorithm>

class BufferHeapReadPlan {
    // Diagnostics only. The resource plan and its eligibility stay immutable.
    mutable std::atomic<uint64_t> _diagnosticSession{0};
public:
    bool claimDiagnosticSession(uint64_t session) const {
        return session && _diagnosticSession.exchange(session, std::memory_order_relaxed) != session;
    }
    struct Group {
        id<MTLHeap> heap = nil;
        // Non-owning children. The corresponding immutable lease owns them.
        std::vector<id<MTLResource>> resources;
        size_t baselineResources = 0;
        bool eligible(size_t threshold) const { return baselineResources >= threshold; }
    };
    std::vector<Group> groups;
    // Historical name: also includes texture exceptions that have a heap but
    // require precise preparation (views, writable/attachment/unknown usage).
    std::vector<id<MTLResource>> nilHeapResources;
    static bool canPrepareSampledTexture(id<MTLResource> resource) {
        if (![resource conformsToProtocol:@protocol(MTLTexture)]) return false;
        id<MTLTexture> texture = static_cast<id<MTLTexture>>(resource);
        const bool texelBuffer = texture.textureType == MTLTextureTypeTextureBuffer;
        MTLTextureUsage allowed = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        // ShaderWrite is a capability, not the access of this binding. Only
        // readonly callers reach this plan; actual writes remain precise and
        // are replayed after useHeap by the encoder ledger. Do not extend this
        // permission to render attachments, arbitrary image views or atomics.
        if (texelBuffer) allowed |= MTLTextureUsageShaderWrite;
        if (!(texture.usage & MTLTextureUsageShaderRead) || (texture.usage & ~allowed)) return false;
        if (!texelBuffer && texture.textureType != MTLTextureType2D && texture.textureType != MTLTextureType2DArray) return false;
        if (texture.sampleCount != 1 || texture.storageMode != MTLStorageModePrivate) return false;
        if (texture.parentTexture) return false;
        id<MTLBuffer> backing = texture.buffer;
        if (texelBuffer) {
            if (!backing || backing.storageMode != MTLStorageModePrivate ||
                !texture.heap || texture.heap != backing.heap) return false;
            if (backing.isAliasable && backing.heap.type != MTLHeapTypePlacement) return false;
        } else if (backing) return false;
        // Placed resources permit explicit aliasing even at distinct offsets;
        // isAliasable alone does not establish overlap. Automatic heaps can
        // reuse aliasable memory, so they keep the precise fallback.
        id<MTLHeap> heap = texture.heap;
        if (texture.isAliasable && (!heap || heap.type != MTLHeapTypePlacement)) return false;
        return true;
    }
    // Additional readonly images may share an ALREADY selected heap. They
    // never introduce a heap declaration or relax the original admission gate.
    static id<MTLResource> additionalImageOwner(id<MTLResource> resource) {
        if (![resource conformsToProtocol:@protocol(MTLTexture)]) return nil;
        auto t = static_cast<id<MTLTexture>>(resource);
        const MTLTextureUsage allowed = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
            MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
        auto valid = [&](id<MTLTexture> x) {
            return x && (x.textureType == MTLTextureType2D || x.textureType == MTLTextureType2DArray) &&
                x.sampleCount == 1 && x.storageMode == MTLStorageModePrivate && !x.buffer &&
                (x.usage & MTLTextureUsageShaderRead) && !(x.usage & ~allowed) && x.heap;
        };
        if (!valid(t)) return nil;
        id<MTLTexture> owner = t.parentTexture ?: t;
        if (!valid(owner) || owner.parentTexture || owner.heap != t.heap) return nil;
        if ((t.isAliasable || owner.isAliasable) && t.heap.type != MTLHeapTypePlacement) return nil;
        return owner;
    }
    static id<MTLResource> baselineOwner(id<MTLResource> resource) {
        auto t = static_cast<id<MTLTexture>>(resource);
        return t.textureType == MTLTextureTypeTextureBuffer ? static_cast<id<MTLResource>>(t.buffer) : resource;
    }
    // Input identities are valid known buffers, normally unique after liveness
    // filtering. Resource identity/heap assignment must remain fixed while the
    // lease is owned. The default mode is unchanged and accepts known buffers;
    // texture mode additionally checks native usage, storage, views and overlap.
    // Caller must use a read-only binding; sampleOnlyTextures is a legacy name.
    explicit BufferHeapReadPlan(const std::vector<id<MTLResource>>& knownBuffers,
                                bool sampleOnlyTextures = false) {
        std::unordered_map<id<MTLHeap>, size_t> groupIndex;
        std::vector<id<MTLResource>> additionalImages;
        for (id<MTLResource> resource : knownBuffers) {
            if (sampleOnlyTextures && !canPrepareSampledTexture(resource)) {
                if (additionalImageOwner(resource)) additionalImages.push_back(resource);
                else nilHeapResources.push_back(resource);
                continue;
            }
            id<MTLHeap> heap = resource.heap;
            if (!heap) { nilHeapResources.push_back(resource); continue; }
            auto found = groupIndex.find(heap);
            if (found == groupIndex.end()) {
                size_t index = groups.size();
                groups.push_back({heap,{}});
                groupIndex.emplace(heap,index);
                found = groupIndex.find(heap);
            }
            groups[found->second].resources.push_back(resource);
        }
        if (sampleOnlyTextures) {
            // Prove non-overlap among the lease's sampled children. Unknown
            // sizes/ranges and overlapping placement aliases remain precise.
            // This is not a replacement for Vulkan alias memory barriers.
            for (auto& group : groups) {
                if (group.heap.type != MTLHeapTypePlacement) continue;
                std::vector<std::pair<NSUInteger,NSUInteger>> ranges;
                std::unordered_set<id<MTLResource>> physicalOwners;
                bool valid = true;
                for (id<MTLResource> resource : group.resources) {
                    // Texel views of one MTLBuffer intentionally share storage.
                    // Validate that retained physical allocation exactly once.
                    // Different overlapping allocations still reject the group.
                    id<MTLResource> owner = baselineOwner(resource);
                    if (!physicalOwners.insert(owner).second) continue;
                    NSUInteger offset = owner.heapOffset, size = owner.allocatedSize;
                    if (!size || offset > group.heap.size || size > group.heap.size - offset) {
                        valid = false; break;
                    }
                    ranges.push_back({offset,offset+size});
                }
                std::sort(ranges.begin(),ranges.end());
                for (size_t index=1;valid && index<ranges.size();++index)
                    valid = ranges[index-1].second <= ranges[index].first;
                if (!valid) {
                    nilHeapResources.insert(nilHeapResources.end(),group.resources.begin(),group.resources.end());
                    group.resources.clear();
                }
            }
            groups.erase(std::remove_if(groups.begin(),groups.end(),[](const Group& g){return g.resources.empty();}),groups.end());
        }
        // Freeze baseline group sizes BEFORE extending coverage. Both group
        // thresholds and the helper's 128-child gate use these original sizes.
        // Thus this optimization cannot add useHeaps calls or broaden which
        // heaps undergo native attachment decompression.
        for (auto& group : groups) group.baselineResources = group.resources.size();
        if (sampleOnlyTextures) {
            groupIndex.clear();
            for (size_t i=0;i<groups.size();++i) groupIndex.emplace(groups[i].heap,i);
            struct Range { NSUInteger begin, end; id<MTLResource> owner; };
            std::vector<std::vector<Range>> ranges(groups.size());
            for (size_t i=0;i<groups.size();++i) {
                auto& group = groups[i];
                if (group.heap.type != MTLHeapTypePlacement) continue;
                std::unordered_set<id<MTLResource>> owners;
                for (id<MTLResource> resource : group.resources) {
                    auto owner = baselineOwner(resource);
                    if (owners.insert(owner).second)
                        ranges[i].push_back({owner.heapOffset,owner.heapOffset+owner.allocatedSize,owner});
                }
            }
            for (id<MTLResource> resource : additionalImages) {
                auto found = groupIndex.find(resource.heap);
                bool accepted = found != groupIndex.end();
                if (accepted) {
                    auto& group = groups[found->second];
                    if (group.heap.type == MTLHeapTypePlacement) {
                        auto owner = additionalImageOwner(resource);
                        NSUInteger begin = owner.heapOffset, size = owner.allocatedSize;
                        accepted = size && begin <= group.heap.size && size <= group.heap.size-begin;
                        bool existing = false;
                        for (const auto& range : ranges[found->second]) {
                            if (range.owner == owner) { existing = true; continue; }
                            if (accepted && begin < range.end && range.begin < begin+size) accepted = false;
                        }
                        if (accepted && !existing) ranges[found->second].push_back({begin,begin+size,owner});
                    }
                    if (accepted) group.resources.push_back(resource);
                }
                if (!accepted) nilHeapResources.push_back(resource);
            }
        }
        // No C++ allocation can fail after explicit ownership is acquired.
        // Children remain non-owning. Exactly one retain per distinct heap.
        for (const auto& group : groups) [group.heap retain];
    }
    BufferHeapReadPlan(const BufferHeapReadPlan&) = delete;
    BufferHeapReadPlan& operator=(const BufferHeapReadPlan&) = delete;
    BufferHeapReadPlan(BufferHeapReadPlan&&) = delete;
    BufferHeapReadPlan& operator=(BufferHeapReadPlan&&) = delete;
    ~BufferHeapReadPlan() { for (const auto& group : groups) [group.heap release]; }
    size_t resourceCount() const {
        size_t n=nilHeapResources.size();for(const auto&group:groups)n+=group.resources.size();return n;
    }
    size_t eligibleGroupCount(size_t threshold) const {
        size_t n=0;for(const auto&group:groups)n+=group.eligible(threshold);return n;
    }
    size_t eligibleResourceCount(size_t threshold) const {
        size_t n=0;for(const auto&group:groups)if(group.eligible(threshold))n+=group.resources.size();return n;
    }
    size_t baselineEligibleResourceCount(size_t threshold) const {
        size_t n=0;for(const auto&group:groups)if(group.eligible(threshold))n+=group.baselineResources;return n;
    }
    size_t preciseResourceCount(size_t threshold) const {
        return resourceCount()-eligibleResourceCount(threshold);
    }
};

