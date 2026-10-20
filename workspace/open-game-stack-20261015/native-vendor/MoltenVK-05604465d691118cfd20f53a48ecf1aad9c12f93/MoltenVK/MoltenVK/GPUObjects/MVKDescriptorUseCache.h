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
    using Resources = std::vector<id<MTLResource>>;
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
        for (auto range : entry.dirty) {
            for (uint32_t i = range.first; i < range.second; ++i) {
                id<MTLResource> resource = *reinterpret_cast<const id<MTLResource>*>(src + i * stride);
                id<MTLResource> old = entry.slots[i];
                if (old == resource) continue;
                if (old) {
                    auto it = entry.counts.find(old);
                    if (--it->second == 0) entry.counts.erase(it);
                }
                if (resource) ++entry.counts[resource];
                entry.slots[i] = resource;
                changed = true;
            }
            _scanned += range.second-range.first;
        }
        entry.dirty.clear();
        if (changed) {
            auto result = std::make_shared<Resources>();
            result->reserve(entry.counts.size());
            for (auto item : entry.counts) result->push_back(item.first);
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
