// Scratch heap counts for resource-use batching. Small groups avoid one hash
// allocation per heap per draw; larger groups retain linear expected work.
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <utility>

template<class Heap> class MVKHeapUseCounter {
    static constexpr std::size_t inlineCapacity = 8;
    std::array<std::pair<Heap, uint32_t>, inlineCapacity> small{};
    std::size_t size = 0;
    bool spilled = false;
    std::unordered_map<Heap, uint32_t> large;
public:
    void add(Heap heap) {
        if (spilled) { ++large[heap]; return; }
        for (std::size_t i = 0; i < size; ++i) {
            if (small[i].first == heap) { ++small[i].second; return; }
        }
        if (size < inlineCapacity) { small[size++] = {heap, 1}; return; }
        large.reserve(inlineCapacity * 2);
        for (std::size_t i = 0; i < size; ++i) large.emplace(small[i]);
        spilled = true;
        ++large[heap];
    }
    uint32_t count(Heap heap) const {
        if (spilled) {
            auto it = large.find(heap);
            return it == large.end() ? 0 : it->second;
        }
        for (std::size_t i = 0; i < size; ++i) if (small[i].first == heap) return small[i].second;
        return 0;
    }
    template<class F> void each(F&& fn) const {
        if (spilled) { for (const auto& pair : large) fn(pair.first, pair.second); }
        else { for (std::size_t i = 0; i < size; ++i) fn(small[i].first, small[i].second); }
    }
};
