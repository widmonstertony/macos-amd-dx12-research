// Immutable CPU read-residency plan for a validated BUFFER-only lease.
// Production integration must exclude texture snapshots, preserve per-encoder
// stage/write coverage, and keep a strong lease owner for every use of this plan.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <atomic>

class BufferHeapReadPlan {
public:
    struct Group {
        id<MTLHeap> heap = nil;
        // Non-owning children. The corresponding immutable lease owns them.
        std::vector<id<MTLResource>> resources;
    };
    std::vector<Group> groups;
    std::vector<id<MTLResource>> nilHeapResources;
    // Input identities are valid known buffers, normally unique after liveness
    // filtering. Resource identity/heap assignment must remain fixed while the
    // lease is owned. This constructor deliberately performs no texture checks.
    explicit BufferHeapReadPlan(const std::vector<id<MTLResource>>& knownBuffers) {
        std::unordered_map<id<MTLHeap>, size_t> groupIndex;
        for (id<MTLResource> resource : knownBuffers) {
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

