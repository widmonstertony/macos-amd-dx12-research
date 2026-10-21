// Reusable CPU scratch table. Never owns or dereferences heap identities.
#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

template<class Heap> class MVKHeapUseTable {
    struct Slot { Heap heap{}; uint32_t count = 0; };
    std::vector<Slot> slots;
    std::size_t used = 0;
    static std::size_t hash(Heap heap) {
        // Mix aligned Metal pointers before applying a power-of-two mask.
        uint64_t x = std::hash<Heap>{}(heap);
        x ^= x >> 30; x *= UINT64_C(0xbf58476d1ce4e5b9);
        x ^= x >> 27; x *= UINT64_C(0x94d049bb133111eb);
        return x ^ (x >> 31);
    }
    void grow() {
        std::vector<Slot> old;
        old.swap(slots);
        slots.resize(old.empty() ? 16 : old.size() * 2);
        used = 0;
        for (auto& s : old) if (s.count) insert(s.heap, s.count);
    }
    void insert(Heap heap, uint32_t count) {
        auto i = hash(heap) & (slots.size() - 1);
        while (slots[i].count && slots[i].heap != heap) i = (i + 1) & (slots.size() - 1);
        if (!slots[i].count) { slots[i].heap = heap; ++used; }
        slots[i].count += count;
    }
public:
    void reset() {
        // Resource declarations never survive this reset, only scratch capacity.
        for (auto& s : slots) s.count = 0;
        used = 0;
    }
    void add(Heap heap) {
        if (slots.empty() || (used + 1) * 2 > slots.size()) grow();
        insert(heap, 1);
    }
    uint32_t count(Heap heap) const {
        if (slots.empty()) return 0;
        auto i = hash(heap) & (slots.size() - 1);
        while (slots[i].count) {
            if (slots[i].heap == heap) return slots[i].count;
            i = (i + 1) & (slots.size() - 1);
        }
        return 0;
    }
    template<class F> void each(F&& fn) const {
        for (auto& s : slots) if (s.count) fn(s.heap, s.count);
    }
};
