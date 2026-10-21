// CPU control for the exact heap grouping helper used by native encoders.
// Integer identities are never dereferenced. GPU correctness is tested separately.
#include "MVKHeapUseTable.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <random>
#include <stdexcept>
#include <vector>

using Clock = std::chrono::steady_clock;
static volatile uint64_t consumed;
template<class Counter> static double measure(const std::vector<uintptr_t>& input) {
    auto start = Clock::now();
    uint64_t checksum = 0;
    Counter counter;
    for (unsigned pass = 0; pass < 2000; ++pass) {
        counter.reset();
        for (auto heap : input) if (heap) counter.add(heap);
        counter.each([&](uintptr_t heap, uint32_t count) { checksum += heap * count; });
        // Exercise the same second pass as the native precise-resource filter.
        for (auto heap : input) if (heap && counter.count(heap) < 2) checksum += heap;
    }
    consumed = checksum;
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
struct Original {
    std::unordered_map<uintptr_t, uint32_t> counts;
    void reset() { counts.clear(); }
    void add(uintptr_t h) { ++counts[h]; }
    uint32_t count(uintptr_t h) const { auto it=counts.find(h); return it==counts.end()?0:it->second; }
    template<class F> void each(F&& f) const { for (const auto& pair:counts) f(pair.first,pair.second); }
};
int main() {
    std::mt19937 random(3489700);
    std::printf("{\"passed\":true,\"iterationsPerCase\":2000,\"cases\":[");
    unsigned row=0;
    for (unsigned heaps : {1,2,4,8,9,64,512}) for (bool shuffled : {false,true}) {
        std::vector<uintptr_t> input;
        for (unsigned i=0;i<512;++i) input.push_back(1+i%heaps);
        input.push_back(0); // Non-heap resources stay on the precise path.
        if (shuffled) std::shuffle(input.begin(),input.end(),random);
        Original reference;MVKHeapUseTable<uintptr_t> candidate;
        for(auto h:input) if(h) {reference.add(h);candidate.add(h);}
        for(auto h:input) if(reference.count(h)!=candidate.count(h)) throw std::runtime_error("heap count mismatch");
        for(unsigned threshold:{1,2,16,512,513}) {
            std::vector<uintptr_t> before,after;
            reference.each([&](uintptr_t h,uint32_t c){if(c>=threshold)before.push_back(h);});
            candidate.each([&](uintptr_t h,uint32_t c){if(c>=threshold)after.push_back(h);});
            std::sort(before.begin(),before.end());std::sort(after.begin(),after.end());
            if(before!=after)throw std::runtime_error("heap membership mismatch");
        }
        double oldMS=measure<Original>(input);auto oldSum=consumed;
        double newMS=measure<MVKHeapUseTable<uintptr_t>>(input);
        if(oldSum!=consumed)throw std::runtime_error("checksum mismatch");
        std::printf("%s{\"heaps\":%u,\"shuffled\":%s,\"originalMS\":%.3f,\"candidateMS\":%.3f}",row++?",":"",heaps,shuffled?"true":"false",oldMS,newMS);
    }
    std::puts("]}");
}
