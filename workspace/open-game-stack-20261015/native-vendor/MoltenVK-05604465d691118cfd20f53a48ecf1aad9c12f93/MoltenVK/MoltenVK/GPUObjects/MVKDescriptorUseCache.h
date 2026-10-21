// Opt-in CPU bookkeeping for unchanged partially-bound descriptor tables.
// Stores raw identities only: the encoder must still validate/retain each one.
#pragma once
#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <tuple>
#include <unordered_set>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>

class MVKDescriptorUseCache {
public:
    struct Resources : std::vector<id<MTLResource>> {
        using std::vector<id<MTLResource>>::vector;
        // Raw identities only. Weak ancestry cannot retain an unbounded chain
        // of old descriptor tables, and never owns any Metal resource.
        std::weak_ptr<const Resources> previous;
        std::vector<id<MTLResource>> added, removed;
    };
    using Snapshot = std::shared_ptr<const Resources>;
    std::unique_lock<std::mutex> beginWrite(const char* first = nullptr, size_t bytes = 0) {
        std::unique_lock<std::mutex> lock(_lock);
        for (auto& item : _snapshots) {
            const char* src = std::get<0>(item.first);
            uint32_t count = std::get<1>(item.first);
            size_t stride = std::get<2>(item.first);
            uint32_t begin = 0, end = count;
            if (first) {
                // Compare integer addresses: source and destination need not
                // denote subobjects of the same C++ allocation in the fixture.
                uintptr_t s = reinterpret_cast<uintptr_t>(src), w = reinterpret_cast<uintptr_t>(first);
                uintptr_t spanEnd = s + (count ? (count-1)*stride + sizeof(id) : 0);
                if (!bytes || w >= spanEnd || w + bytes <= s) continue;
                begin = w > s ? std::min<size_t>(count, (w-s)/stride) : 0;
                end = std::min<size_t>(count, (w+bytes-s + stride-1)/stride);
            }
            auto& dirty = item.second.dirty;
            if (!dirty.empty() && begin <= dirty.back().second && end >= dirty.back().first) {
                dirty.back() = {std::min(begin,dirty.back().first),std::max(end,dirty.back().second)};
            } else {
                dirty.emplace_back(begin,end);
            }
            if (dirty.size() > 32) {
                for (auto range : dirty) { begin=std::min(begin,range.first); end=std::max(end,range.second); }
                dirty.assign(1,{begin,end});
            }
        }
        ++_invalidations;
        return lock;
    }
    Snapshot resources(const char* src, uint32_t count, size_t stride) {
        return stride == sizeof(id) ? resourcesImpl<true>(src,count,stride)
                                    : resourcesImpl<false>(src,count,stride);
    }
    // Keep strided layouts in a separate specialization with the original
    // scalar loop. Optimizing OneID tables must not change that loop's codegen.
    template<bool Contiguous> [[gnu::noinline]]
    Snapshot resourcesImpl(const char* src, uint32_t count, size_t stride) {
        std::lock_guard<std::mutex> lock(_lock);
        if (count > 2*1024*1024) {
            auto result = std::make_shared<Resources>();
            std::unordered_set<id<MTLResource>> seen;
            for (uint32_t i=0;i<count;++i) {
                id<MTLResource> resource=*reinterpret_cast<const id<MTLResource>*>(src+i*stride);
                if (resource && seen.insert(resource).second) result->push_back(resource);
            }
            _scanned += count; _emitted += result->size(); ++_rebuilds;
            return result;
        }
        auto key = std::make_tuple(src, count, stride);
        auto found = _snapshots.find(key);
        if (found == _snapshots.end()) {
            // At most two million retained slot identities per set. Admission
            // evicts CPU cache entries only; in-flight immutable lists survive.
            if (_snapshots.size() >= 64 || _storedSlots + count > 2*1024*1024) {
                _snapshots.clear(); _storedSlots = 0;
            }
            found = _snapshots.emplace(key, Entry{}).first;
            found->second.slots.resize(count, nil);
            found->second.dirty.emplace_back(0,count);
            _storedSlots += count;
        }
        Entry& entry = found->second;
        if (entry.dirty.empty()) {
            ++_hits;
            return entry.snapshot;
        }
        bool changed = !entry.snapshot;
        size_t dirtySlots = 0;
        for (auto range : entry.dirty) dirtySlots += range.second-range.first;
        bool trackDelta = entry.snapshot && dirtySlots <= 4096;
        std::unordered_set<id<MTLResource>> added, removed;
        for (auto range : entry.dirty) {
            uint32_t originalCount = range.second-range.first;
            if constexpr (Contiguous) {
                // Trim only byte-identical identity blocks at large dirty
                // range edges; all possibly changed slots use the normal path.
                if (originalCount >= 256) {
                    while (range.second-range.first >= 32 && !memcmp(src + range.first*stride,
                            entry.slots.data() + range.first, 32*sizeof(id))) range.first += 32;
                    while (range.second-range.first >= 32 && !memcmp(src + (range.second-32)*stride,
                            entry.slots.data() + range.second-32, 32*sizeof(id))) range.second -= 32;
                }
            }
            for (uint32_t i = range.first; i < range.second; ++i) {
                id<MTLResource> resource = *reinterpret_cast<const id<MTLResource>*>(src + i * stride);
                id<MTLResource> old = entry.slots[i];
                if (old == resource) continue;
                if (old) {
                    auto it = entry.counts.find(old);
                    if (--it->second == 0) {
                        entry.counts.erase(it);
                        if (trackDelta && !added.erase(old)) removed.insert(old);
                    }
                }
                if (resource && ++entry.counts[resource] == 1 && trackDelta && !removed.erase(resource))
                    added.insert(resource);
                entry.slots[i] = resource;
                changed = true;
            }
            _scanned += originalCount;
        }
        entry.dirty.clear();
        // The snapshot describes a set, not slot order or multiplicity. A
        // shuffle or duplicate-count change must preserve its cache identity.
        if (trackDelta && added.empty() && removed.empty()) changed = false;
        if (changed) {
            auto result = std::make_shared<Resources>();
            result->reserve(entry.counts.size());
            for (auto item : entry.counts) result->push_back(item.first);
            if (trackDelta) {
                result->previous = entry.snapshot;
                result->added.assign(added.begin(), added.end());
                result->removed.assign(removed.begin(), removed.end());
            }
            entry.snapshot = result;
            _emitted += result->size(); ++_rebuilds;
        } else ++_hits;
        return entry.snapshot;
    }
    ~MVKDescriptorUseCache() {
        const char* trace = getenv("MVK_AMD_TRACE_DESCRIPTOR_CACHE");
        if (trace && !strcmp(trace, "1"))
            fprintf(stderr, "MVK_DESCRIPTOR_CACHE hits=%llu rebuilds=%llu invalidations=%llu scanned=%llu emitted=%llu\n",
                (unsigned long long)_hits, (unsigned long long)_rebuilds, (unsigned long long)_invalidations,
                (unsigned long long)_scanned, (unsigned long long)_emitted);
    }
private:
    struct Entry {
        Resources slots;
        std::unordered_map<id<MTLResource>,uint32_t> counts;
        std::vector<std::pair<uint32_t,uint32_t>> dirty;
        Snapshot snapshot;
    };
    std::mutex _lock;
    std::map<std::tuple<const char*, uint32_t, size_t>, Entry> _snapshots;
    size_t _storedSlots = 0;
    uint64_t _hits = 0, _rebuilds = 0, _invalidations = 0, _scanned = 0, _emitted = 0;
};
