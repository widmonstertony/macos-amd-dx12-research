// Opt-in CPU bookkeeping for unchanged partially-bound descriptor tables.
// Stores raw identities only: the encoder must still validate/retain each one.
#pragma once
#include <algorithm>
#include <atomic>
#include <array>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <shared_mutex>
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
        bool sortedIdentities = false;
        bool contains(id<MTLResource> resource) const {
            if (!sortedIdentities) return std::find(begin(), end(), resource) != end();
            uintptr_t needle = reinterpret_cast<uintptr_t>(resource);
            auto found = std::lower_bound(begin(), end(), needle,
                [](id<MTLResource> lhs, uintptr_t rhs) {
                    return reinterpret_cast<uintptr_t>(lhs) < rhs;
                });
            return found != end() && reinterpret_cast<uintptr_t>(*found) == needle;
        }
    };
    using Snapshot = std::shared_ptr<const Resources>;
    struct SnapshotReuseState {
        std::atomic<uint64_t> completedVersion{0};
        std::atomic<uint32_t> activeWrites{0};
        bool canReuse(uint64_t version) const {
            if (activeWrites.load(std::memory_order_acquire)) return false;
            uint64_t current = completedVersion.load(std::memory_order_acquire);
            return !activeWrites.load(std::memory_order_acquire) && current == version;
        }
    };
    struct SnapshotReuseToken {
        std::shared_ptr<SnapshotReuseState> state;
        uint64_t completedVersion = 0;
        bool canReuse() const { return state && state->canReuse(completedVersion); }
    };
    struct VersionedSnapshot {
        Snapshot snapshot;
        SnapshotReuseToken reuse;
    };
    struct WriteStats {
        uint64_t ranges = 0;
        uint64_t unchangedRanges = 0;
        uint64_t changedRanges = 0;
    };
    static WriteStats takeWriteStats() {
        return {
            _completedWriteRanges.exchange(0, std::memory_order_acq_rel),
            _unchangedWriteRanges.exchange(0, std::memory_order_acq_rel),
            _changedWriteRanges.exchange(0, std::memory_order_acq_rel),
        };
    }
    struct RangeLocks {
        std::shared_lock<std::shared_mutex> narrowGate;
        std::unique_lock<std::shared_mutex> wideGate;
        std::array<std::unique_lock<std::mutex>, 64> stripes;
        uint32_t stripeCount = 0;
    };
    class WriteGuard {
    public:
        WriteGuard() = default;
        WriteGuard(WriteGuard&&) = default;
        WriteGuard& operator=(WriteGuard&&) = default;
        WriteGuard(const WriteGuard&) = delete;
        WriteGuard& operator=(const WriteGuard&) = delete;
    private:
        friend MVKDescriptorUseCache;
        class Completion {
        public:
            Completion() = default;
            Completion(std::atomic<uint64_t>* invalidations, std::atomic<uint32_t>* activeWrites)
                : _invalidations(invalidations), _activeWrites(activeWrites) {}
            Completion(const Completion&) = delete;
            Completion& operator=(const Completion&) = delete;
            Completion(Completion&& other) noexcept
                : _invalidations(other._invalidations), _activeWrites(other._activeWrites),
                  _ranges(std::move(other._ranges)) {
                other._invalidations = nullptr;
                other._activeWrites = nullptr;
            }
            Completion& operator=(Completion&& other) noexcept {
                finish();
                _invalidations = other._invalidations;
                _activeWrites = other._activeWrites;
                _ranges = std::move(other._ranges);
                other._invalidations = nullptr;
                other._activeWrites = nullptr;
                return *this;
            }
            ~Completion() { finish(); }
            void add(const std::shared_ptr<SnapshotReuseState>& state,
                     const std::shared_ptr<void>& keepAlive,
                     const char* src, Resources* slots, size_t stride,
                     uint32_t begin, uint32_t end,
                     std::mutex* dirtyLock,
                     std::vector<std::pair<uint32_t,uint32_t>>* dirty,
                     std::atomic<uint64_t>* dirtyStripeMask) {
                state->activeWrites.fetch_add(1, std::memory_order_acq_rel);
                _ranges.push_back({state, keepAlive, src, slots, stride, begin, end,
                                   dirtyLock, dirty, dirtyStripeMask});
            }
            void reserve(size_t count) { _ranges.reserve(count); }
        private:
            struct Range {
                std::shared_ptr<SnapshotReuseState> state;
                std::shared_ptr<void> keepAlive;
                const char* src;
                Resources* slots;
                size_t stride;
                uint32_t begin, end;
                std::mutex* dirtyLock;
                std::vector<std::pair<uint32_t,uint32_t>>* dirty;
                std::atomic<uint64_t>* dirtyStripeMask;
            };
            void finish() {
                if (!_activeWrites) return;
                bool anyChanged = false;
                for (const auto& range : _ranges) {
                    bool changed = false;
                    for (uint32_t index = range.begin; index < range.end; ++index) {
                        id<MTLResource> resource = *reinterpret_cast<const id<MTLResource>*>(range.src + index * range.stride);
                        if ((*range.slots)[index] != resource) { changed = true; break; }
                    }
                    _completedWriteRanges.fetch_add(1, std::memory_order_relaxed);
                    if (changed) {
                        anyChanged = true;
                        _changedWriteRanges.fetch_add(1, std::memory_order_relaxed);
                        std::lock_guard<std::mutex> dirtyGuard(*range.dirtyLock);
                        auto& dirty = *range.dirty;
                        uint32_t begin = range.begin, end = range.end;
                        if (!dirty.empty() && begin <= dirty.back().second && end >= dirty.back().first) {
                            dirty.back() = {std::min(begin, dirty.back().first), std::max(end, dirty.back().second)};
                        } else {
                            dirty.emplace_back(begin, end);
                        }
                        if (dirty.size() > 32) {
                            for (auto item : dirty) {
                                begin = std::min(begin, item.first);
                                end = std::max(end, item.second);
                            }
                            dirty.assign(1, {begin, end});
                        }
                        range.dirtyStripeMask->fetch_or(stripeMask(range.src, range.stride,
                                                                  range.begin, range.end),
                                                        std::memory_order_release);
                        range.state->completedVersion.fetch_add(1, std::memory_order_release);
                    } else {
                        _unchangedWriteRanges.fetch_add(1, std::memory_order_relaxed);
                    }
                    range.state->activeWrites.fetch_sub(1, std::memory_order_release);
                }
                if (anyChanged) _invalidations->fetch_add(1, std::memory_order_release);
                _activeWrites->fetch_sub(1, std::memory_order_release);
                _invalidations = nullptr;
                _activeWrites = nullptr;
            }
            std::atomic<uint64_t>* _invalidations = nullptr;
            std::atomic<uint32_t>* _activeWrites = nullptr;
            std::vector<Range> _ranges;

            static uint64_t stripeMask(const char* src, size_t stride,
                                       uint32_t begin, uint32_t end) {
                if (begin >= end) return 0;
                uintptr_t first = reinterpret_cast<uintptr_t>(src + size_t(begin) * stride);
                uintptr_t last = reinterpret_cast<uintptr_t>(src + size_t(end - 1) * stride)
                               + sizeof(id) - 1;
                uintptr_t firstBlock = first / kWriteStripeGranule;
                uintptr_t lastBlock = last / kWriteStripeGranule;
                if (lastBlock - firstBlock + 1 >= kWriteStripeCount) return ~uint64_t(0);
                uint64_t mask = 0;
                for (uintptr_t block = firstBlock; block <= lastBlock; ++block)
                    mask |= uint64_t(1) << (block % kWriteStripeCount);
                return mask;
            }
        };
        std::unique_lock<std::mutex> global;
        RangeLocks rangeLocks;
        // Destroyed first, while the range/global locks are still held, so it
        // can compare the completed descriptor bytes to the cached identities.
        Completion completion;
    };
    WriteGuard beginWrite(const char* first = nullptr, size_t bytes = 0) {
        WriteGuard guard;
        _activeWrites.fetch_add(1, std::memory_order_acq_rel);
        guard.completion = WriteGuard::Completion(&_invalidations, &_activeWrites);
        if (usesWriteShards()) {
            guard.rangeLocks = lockRange(first, bytes);
            guard.global = std::unique_lock<std::mutex>(_lock);
        } else {
            guard.global = std::unique_lock<std::mutex>(_lock);
        }
        // A descriptor set normally has several cached layout projections.
        // Each Vulkan write intersects most or all of them, so growing this
        // temporary vector one element at a time showed up in the game's
        // vkUpdateDescriptorSets hot path.  Its exact upper bound is already
        // known while the cache lock is held.
        guard.completion.reserve(_snapshots.size());
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
            Entry& entry = *item.second;
            guard.completion.add(entry.reuseState, item.second, src, &entry.slots, stride,
                                 begin, end, &entry.dirtyLock, &entry.dirty,
                                 &entry.dirtyStripeMask);
        }
        // The metadata mutation is complete before descriptor bytes change.
        // In sharded mode, retain only the intersecting data stripes across
        // the actual CPU/Metal descriptor write. A reader takes the same
        // stripes before consuming dirty metadata, so it cannot observe a
        // partially written table. Independent bindings no longer contend on
        // one per-set mutex for the duration of argument-buffer encoding.
        if (usesWriteShards()) guard.global.unlock();
        return guard;
    }
    Snapshot resources(const char* src, uint32_t count, size_t stride) {
        return resources(src, count, stride, nullptr);
    }
    Snapshot resources(const char* src, uint32_t count, size_t stride, uint64_t* completedVersion) {
        return stride == sizeof(id) ? resourcesImpl<true>(src,count,stride,completedVersion)
                                    : resourcesImpl<false>(src,count,stride,completedVersion);
    }
    VersionedSnapshot versionedResources(const char* src, uint32_t count, size_t stride) {
        VersionedSnapshot result;
        result.snapshot = stride == sizeof(id) ? resourcesImpl<true>(src,count,stride,nullptr,&result.reuse)
                                               : resourcesImpl<false>(src,count,stride,nullptr,&result.reuse);
        return result;
    }
    bool canReuseSnapshot(uint64_t completedVersion) const {
        // A writer announces itself before acquiring any data stripe. The
        // second active-writer read closes the race with a writer starting
        // between the first read and the version comparison.
        if (_activeWrites.load(std::memory_order_acquire)) return false;
        uint64_t current = _invalidations.load(std::memory_order_acquire);
        return !_activeWrites.load(std::memory_order_acquire) && current == completedVersion;
    }
    // Keep strided layouts in a separate specialization with the original
    // scalar loop. Optimizing OneID tables must not change that loop's codegen.
    template<bool Contiguous> [[gnu::noinline]]
    Snapshot resourcesImpl(const char* src, uint32_t count, size_t stride, uint64_t* completedVersion,
                           SnapshotReuseToken* reuseToken = nullptr) {
        const size_t sourceBytes = count ? (count - 1) * stride + sizeof(id) : 0;
        auto key = std::make_tuple(src, count, stride);
        RangeLocks rangeLocks;
        std::unique_lock<std::mutex> lock;
        std::shared_ptr<Entry> hintedEntry;
        uint64_t hintedDirtyMask = 0;
        if (usesWriteShards()) {
            // Do not take an exclusive whole-table range lock merely to
            // discover that an immutable snapshot is already clean.  When a
            // rebuild is needed, lock only the address stripes named by the
            // completed dirty ranges.  A writer announces itself while
            // holding _lock and before it modifies bytes, so the second check
            // below safely falls back to the full range if a write is active.
            {
                std::unique_lock<std::mutex> probe(_lock);
                auto hinted = _snapshots.find(key);
                if (hinted != _snapshots.end() &&
                    !hinted->second->reuseState->activeWrites.load(std::memory_order_acquire)) {
                    uint64_t dirtyMask = hinted->second->dirtyStripeMask.load(std::memory_order_acquire);
                    if (!dirtyMask) {
                        ++_hits;
                        if (completedVersion) *completedVersion = _invalidations.load(std::memory_order_acquire);
                        if (reuseToken) *reuseToken = {hinted->second->reuseState,
                            hinted->second->reuseState->completedVersion.load(std::memory_order_acquire)};
                        return hinted->second->snapshot;
                    }
                    hintedEntry = hinted->second;
                    hintedDirtyMask = dirtyMask;
                }
            }
            if (hintedEntry) rangeLocks = lockStripeMask(hintedDirtyMask);
            else rangeLocks = lockRange(src, sourceBytes);
            lock = std::unique_lock<std::mutex>(_lock);
            if (hintedEntry) {
                auto current = _snapshots.find(key);
                if (current == _snapshots.end() || current->second != hintedEntry ||
                    hintedEntry->reuseState->activeWrites.load(std::memory_order_acquire)) {
                    lock.unlock();
                    rangeLocks = RangeLocks{};
                    rangeLocks = lockRange(src, sourceBytes);
                    lock.lock();
                }
            }
        } else {
            lock = std::unique_lock<std::mutex>(_lock);
        }
        if (count > 2*1024*1024) {
            auto result = std::make_shared<Resources>();
            std::unordered_set<id<MTLResource>> seen;
            for (uint32_t i=0;i<count;++i) {
                id<MTLResource> resource=*reinterpret_cast<const id<MTLResource>*>(src+i*stride);
                if (resource && seen.insert(resource).second) result->push_back(resource);
            }
            std::sort(result->begin(), result->end(), [](id<MTLResource> lhs, id<MTLResource> rhs) {
                return reinterpret_cast<uintptr_t>(lhs) < reinterpret_cast<uintptr_t>(rhs);
            });
            result->sortedIdentities = true;
            _scanned += count; _emitted += result->size(); ++_rebuilds;
            if (completedVersion) *completedVersion = _invalidations.load(std::memory_order_acquire);
            if (reuseToken) *reuseToken = {};
            return result;
        }
        auto found = _snapshots.find(key);
        if (found == _snapshots.end()) {
            // At most two million retained slot identities per set. Admission
            // evicts CPU cache entries only; in-flight immutable lists survive.
            if (_snapshots.size() >= 64 || _storedSlots + count > 2*1024*1024) {
                invalidateAllEntryTokens();
                _snapshots.clear(); _storedSlots = 0;
            }
            found = _snapshots.emplace(key, std::make_shared<Entry>()).first;
            found->second->slots.resize(count, nil);
            found->second->dirty.emplace_back(0,count);
            found->second->dirtyStripeMask.store(~uint64_t(0), std::memory_order_release);
            _storedSlots += count;
        }
        Entry& entry = *found->second;
        if (entry.dirty.empty()) {
            ++_hits;
            if (completedVersion) *completedVersion = _invalidations.load(std::memory_order_acquire);
            if (reuseToken) *reuseToken = {entry.reuseState, entry.reuseState->completedVersion.load(std::memory_order_acquire)};
            return entry.snapshot;
        }
        bool changed = !entry.snapshot;
        size_t dirtySlots = 0;
        for (auto range : entry.dirty) dirtySlots += range.second-range.first;
        bool trackDelta = entry.snapshot && dirtySlots <= 4096;
        std::unordered_set<id<MTLResource>> added, removed;
        if constexpr (Contiguous) {
            // Keep the original scalar updater/codegen for dense and strided
            // tables. A separate bounded pre-pass only removes proven-identical
            // interior blocks from coalesced sparse dirty ranges.
            trimUnchangedInterior(src,entry.slots,entry.dirty);
        }
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
        entry.dirtyStripeMask.store(0, std::memory_order_release);
        // The snapshot describes a set, not slot order or multiplicity. A
        // shuffle or duplicate-count change must preserve its cache identity.
        if (trackDelta && added.empty() && removed.empty()) changed = false;
        if (changed) {
            auto result = std::make_shared<Resources>();
            result->reserve(entry.counts.size());
            for (auto item : entry.counts) result->push_back(item.first);
            auto identityLess = [](id<MTLResource> lhs, id<MTLResource> rhs) {
                return reinterpret_cast<uintptr_t>(lhs) < reinterpret_cast<uintptr_t>(rhs);
            };
            std::sort(result->begin(), result->end(), identityLess);
            result->sortedIdentities = true;
            if (trackDelta) {
                result->previous = entry.snapshot;
                result->added.assign(added.begin(), added.end());
                result->removed.assign(removed.begin(), removed.end());
            } else if (entry.snapshot) {
                // Large dirty ranges already pay the cost of rebuilding the
                // sorted identity set.  Compare that set with the preceding
                // immutable snapshot once, instead of dropping ancestry and
                // forcing every live-list consumer to validate the full set.
                // This also recognizes large slot shuffles and multiplicity
                // changes whose final identity set is unchanged.
                std::set_difference(result->begin(), result->end(),
                                    entry.snapshot->begin(), entry.snapshot->end(),
                                    std::back_inserter(result->added), identityLess);
                std::set_difference(entry.snapshot->begin(), entry.snapshot->end(),
                                    result->begin(), result->end(),
                                    std::back_inserter(result->removed), identityLess);
                if (result->added.empty() && result->removed.empty()) {
                    changed = false;
                } else {
                    result->previous = entry.snapshot;
                }
            }
            if (changed) {
                entry.snapshot = result;
                _emitted += result->size(); ++_rebuilds;
            } else {
                ++_hits;
            }
        } else ++_hits;
        if (completedVersion) *completedVersion = _invalidations.load(std::memory_order_acquire);
        if (reuseToken) *reuseToken = {entry.reuseState, entry.reuseState->completedVersion.load(std::memory_order_acquire)};
        return entry.snapshot;
    }
    ~MVKDescriptorUseCache() {
        const char* trace = getenv("MVK_AMD_TRACE_DESCRIPTOR_CACHE");
        if (trace && !strcmp(trace, "1"))
            fprintf(stderr, "MVK_DESCRIPTOR_CACHE hits=%llu rebuilds=%llu invalidations=%llu scanned=%llu emitted=%llu\n",
                (unsigned long long)_hits, (unsigned long long)_rebuilds, (unsigned long long)_invalidations.load(std::memory_order_relaxed),
                (unsigned long long)_scanned, (unsigned long long)_emitted);
    }
private:
    using DirtyRange = std::pair<uint32_t,uint32_t>;
    [[gnu::noinline]] static void trimUnchangedInterior(const char* src, const Resources& slots,
                                                       std::vector<DirtyRange>& dirty) {
        bool sparse = false;
        for (auto range : dirty) {
            uint32_t length=range.second-range.first;
            if (length < 4096) continue;
            uint32_t sample=range.first+length/4;
            if (!memcmp(src+size_t(sample)*sizeof(id),slots.data()+sample,32*sizeof(id))) {
                sparse=true;
                break;
            }
        }
        if (!sparse) return;
        std::vector<DirtyRange> filtered;
        filtered.reserve(dirty.size()+8);
        for (auto range : dirty) {
            if (range.second-range.first < 256) {
                filtered.push_back(range);
                continue;
            }
            for (uint32_t i=range.first; i<range.second;) {
                uint32_t end=i+std::min<uint32_t>(32,range.second-i);
                if (memcmp(src+size_t(i)*sizeof(id),slots.data()+i,size_t(end-i)*sizeof(id))) {
                    if (!filtered.empty() && filtered.back().second==i) filtered.back().second=end;
                    else filtered.emplace_back(i,end);
                    // Metadata remains bounded. Abort without mutating the
                    // original ranges if a table is more fragmented than this.
                    if (filtered.size() > 256) return;
                }
                i=end;
            }
        }
        dirty.swap(filtered);
    }
    static constexpr size_t kWriteStripeCount = 64;
    static constexpr uintptr_t kWriteStripeGranule = 64;
    bool usesWriteShards() const {
        return _usesWriteShards;
    }
    RangeLocks lockRange(const char* first, size_t bytes) {
        RangeLocks locks;
        std::array<bool, kWriteStripeCount> selected{};
        bool wide = !first || !bytes;
        if (!wide) {
            uintptr_t start = reinterpret_cast<uintptr_t>(first) / kWriteStripeGranule;
            uintptr_t end = (reinterpret_cast<uintptr_t>(first) + bytes - 1) / kWriteStripeGranule;
            if (end - start + 1 >= kWriteStripeCount) {
                wide = true;
            } else {
                for (uintptr_t block = start; block <= end; ++block)
                    selected[block % kWriteStripeCount] = true;
            }
        }
        if (wide) {
            locks.wideGate = std::unique_lock<std::shared_mutex>(_writeRangeGate);
            return locks;
        }
        locks.narrowGate = std::shared_lock<std::shared_mutex>(_writeRangeGate);
        for (size_t index = 0; index < kWriteStripeCount; ++index) {
            if (!selected[index]) continue;
            locks.stripes[locks.stripeCount++] = std::unique_lock<std::mutex>(_writeStripes[index]);
        }
        return locks;
    }
    RangeLocks lockStripeMask(uint64_t mask) {
        RangeLocks locks;
        if (mask == ~uint64_t(0)) {
            locks.wideGate = std::unique_lock<std::shared_mutex>(_writeRangeGate);
            return locks;
        }
        locks.narrowGate = std::shared_lock<std::shared_mutex>(_writeRangeGate);
        for (size_t index = 0; index < kWriteStripeCount; ++index) {
            if (!(mask & (uint64_t(1) << index))) continue;
            locks.stripes[locks.stripeCount++] = std::unique_lock<std::mutex>(_writeStripes[index]);
        }
        return locks;
    }
    struct Entry {
        Resources slots;
        std::unordered_map<id<MTLResource>,uint32_t> counts;
        std::mutex dirtyLock;
        std::vector<std::pair<uint32_t,uint32_t>> dirty;
        std::atomic<uint64_t> dirtyStripeMask{~uint64_t(0)};
        Snapshot snapshot;
        std::shared_ptr<SnapshotReuseState> reuseState = std::make_shared<SnapshotReuseState>();
    };
    void invalidateAllEntryTokens() {
        for (auto& item : _snapshots)
            item.second->reuseState->completedVersion.fetch_add(1, std::memory_order_release);
    }
    std::mutex _lock;
    std::shared_mutex _writeRangeGate;
    std::array<std::mutex, kWriteStripeCount> _writeStripes;
    std::map<std::tuple<const char*, uint32_t, size_t>, std::shared_ptr<Entry>> _snapshots;
    size_t _storedSlots = 0;
    std::atomic<uint64_t> _invalidations{0};
    std::atomic<uint32_t> _activeWrites{0};
    // Process environment is immutable for a running game.  getenv() takes a
    // libc environment lock and was responsible for measurable contention in
    // every descriptor read and write; resolve the opt-in once per cache.
    const bool _usesWriteShards = [] {
        const char* option = getenv("MVK_AMD_DESCRIPTOR_WRITE_SHARDS");
        return option && !strcmp(option, "1");
    }();
    uint64_t _hits = 0, _rebuilds = 0, _scanned = 0, _emitted = 0;
    inline static std::atomic<uint64_t> _completedWriteRanges{0};
    inline static std::atomic<uint64_t> _unchangedWriteRanges{0};
    inline static std::atomic<uint64_t> _changedWriteRanges{0};
};
