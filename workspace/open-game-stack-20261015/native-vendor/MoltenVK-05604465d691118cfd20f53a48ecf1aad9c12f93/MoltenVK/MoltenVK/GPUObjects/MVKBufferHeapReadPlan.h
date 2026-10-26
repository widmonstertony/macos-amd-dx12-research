// Immutable read-residency plan for an owned, validated resource lease.
// Texture mode additionally requires pipeline-proven sample-only image access;
// resource-level exclusions remain precise. Encoder/stage/write coverage and
// strong child ownership are independent of this immutable grouping.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <atomic>
#include <algorithm>

class BufferHeapReadPlan {
public:
    struct Group {
        id<MTLHeap> heap = nil;
        // Non-owning children. The corresponding immutable lease owns them.
        std::vector<id<MTLResource>> resources;
    };
    std::vector<Group> groups;
    // Historical name: also includes texture exceptions that have a heap but
    // require precise preparation (views, writable/attachment/unknown usage).
    std::vector<id<MTLResource>> nilHeapResources;
    static bool canPrepareSampledTexture(id<MTLResource> resource) {
        if (![resource conformsToProtocol:@protocol(MTLTexture)]) return false;
        id<MTLTexture> texture = static_cast<id<MTLTexture>>(resource);
        const MTLTextureUsage allowed = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        if (!(texture.usage & MTLTextureUsageShaderRead) || (texture.usage & ~allowed)) return false;
        if (texture.textureType != MTLTextureType2D && texture.textureType != MTLTextureType2DArray) return false;
        if (texture.sampleCount != 1 || texture.storageMode != MTLStorageModePrivate) return false;
        if (texture.parentTexture || texture.buffer) return false;
        // Placed resources permit explicit aliasing even at distinct offsets;
        // isAliasable alone does not establish overlap. Automatic heaps can
        // reuse aliasable memory, so they keep the precise fallback.
        id<MTLHeap> heap = texture.heap;
        if (texture.isAliasable && (!heap || heap.type != MTLHeapTypePlacement)) return false;
        return true;
    }
    // Input identities are valid known buffers, normally unique after liveness
    // filtering. Resource identity/heap assignment must remain fixed while the
    // lease is owned. The default mode is unchanged and accepts known buffers;
    // texture mode never treats a registry/type hint alone as access proof.
    explicit BufferHeapReadPlan(const std::vector<id<MTLResource>>& knownBuffers,
                                bool sampleOnlyTextures = false) {
        std::unordered_map<id<MTLHeap>, size_t> groupIndex;
        for (id<MTLResource> resource : knownBuffers) {
            if (sampleOnlyTextures && !canPrepareSampledTexture(resource)) {
                nilHeapResources.push_back(resource); continue;
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
                bool valid = true;
                for (id<MTLResource> resource : group.resources) {
                    NSUInteger offset = resource.heapOffset, size = resource.allocatedSize;
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
        size_t n=0;for(const auto&group:groups)n+=group.resources.size()>=threshold;return n;
    }
    size_t eligibleResourceCount(size_t threshold) const {
        size_t n=0;for(const auto&group:groups)if(group.resources.size()>=threshold)n+=group.resources.size();return n;
    }
    size_t preciseResourceCount(size_t threshold) const {
        return resourceCount()-eligibleResourceCount(threshold);
    }
};

