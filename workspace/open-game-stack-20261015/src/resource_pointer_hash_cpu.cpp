// Owned CPU control for aligned resource identities; no GPU or game inputs.
#include "../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/Commands/MVKStableUseMap.h"
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <random>
#include <unordered_map>
#include <numeric>
#include <fstream>
#include <set>
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    std::ofstream out(argv[1]);
    if (!out) return 3;
    out << "{\"cases\":[";
    bool passed = true; unsigned test = 0; volatile uint64_t sum = 0;
    for (bool synthetic : {false, true}) for (size_t alignment : {16u, 64u, 256u}) {
        constexpr size_t n = 1588, rounds = 2048;
        std::vector<void*> keys;
        for (size_t i = 0; i < n; ++i) {
            void* p = nullptr;
            if (synthetic) p = reinterpret_cast<void*>(uintptr_t(0x100000000) + i * alignment);
            else if (posix_memalign(&p, alignment, alignment) != 0) return 4;
            keys.push_back(p);
        }
        std::set<size_t> initialBuckets; size_t identityHashes = 0;
        for (void* k : keys) { auto h = std::hash<void*>{}(k); initialBuckets.insert(h & 4095); identityHashes += h == reinterpret_cast<uintptr_t>(k); }
        std::mt19937 rng(37); std::shuffle(keys.begin(), keys.end(), rng);
        MVKStableUseMap<void*, uint64_t> map;
        map.reserve(n);
        std::vector<uint64_t*> refs;
        for (size_t i = 0; i < n; ++i) {
            auto [it, inserted] = map.emplace(keys[i], i + 7);
            passed &= inserted && it->second == i + 7;
            refs.push_back(&it->second);
        }
        for (size_t i = 0; i < n; ++i) {
            auto [it, inserted] = map.emplace(keys[i], 0);
            passed &= !inserted && &it->second == refs[i];
        }
        // Measure at the natural capacity before the reference-stability grow.
        auto start = std::chrono::steady_clock::now();
        for (size_t r = 0; r < rounds; ++r) for (void* k : keys) sum += map.find(k)->second;
        double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        map.reserve(n * 4);
        for (size_t i = 0; i < n; ++i) passed &= &map.find(keys[i])->second == refs[i] && *refs[i] == i + 7;
        // Exercise growing from empty, clear/reuse, misses, and non-pointer keys.
        map.clear(); passed &= map.size() == 0;
        for (void* k : keys) passed &= map.find(k) == map.end();
        for (size_t i = 0; i < n; ++i) map.emplace(keys[i], i + 13);
        for (size_t i = 0; i < n; ++i) passed &= map.find(keys[i])->second == i + 13;
        MVKStableUseMap<uint64_t, uint64_t> integers;
        for (size_t i = 0; i < n; ++i) integers.emplace(i * 4096, i);
        for (size_t i = 0; i < n; ++i) passed &= integers.find(i * 4096)->second == i;
        passed &= integers.find(1) == integers.end();
        if (!synthetic) for (void* k : keys) free(k);
        out << (test++ ? "," : "") << "{\"synthetic\":" << (synthetic ? "true" : "false")
            << ",\"identityHashes\":" << identityHashes << ",\"initialBuckets\":" << initialBuckets.size() << ",\"alignment\":" << alignment << ",\"keys\":" << n << ",\"lookups\":" << n * rounds
            << ",\"seconds\":" << seconds << "}";
    }
    out << "],\"passed\":" << (passed ? "true" : "false") << ",\"checksum\":" << sum << "}\n";
    return passed ? 0 : 5;
}
