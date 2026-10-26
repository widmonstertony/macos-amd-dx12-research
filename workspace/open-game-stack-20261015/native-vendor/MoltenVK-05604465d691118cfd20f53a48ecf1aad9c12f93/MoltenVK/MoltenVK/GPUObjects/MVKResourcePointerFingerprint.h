// Diagnostic address-sequence fingerprints only. No stable lifetime, alias,
// resource contents, allocation backing or access-equivalence claim is made.
// Pure C++: the getter reads an array element, never an Objective-C property.
#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

enum class MVKResourceBatchSource : uint32_t {
    RetainedSnapshot=1, PreciseRead=2, PreciseReadWrite=3, CollapsedHeaps=4,
    HeapPlanRead=5, HeapPlanWrite=6, HeapPlanHeaps=7, Immediate=8
};
struct MVKResourcePointerFingerprint {
    static constexpr size_t MaxHashedPointers=32768, SamplePointers=4;
    static constexpr uint32_t AlgorithmVersion=1;
    uint64_t first=0,second=0,totalCount=0,hashedCount=0,sampleCount=0;
    std::array<uint64_t,SamplePointers> samples{};
    bool inputAvailable=false,complete=false;
    static uint64_t mix(uint64_t x) noexcept {
        x^=x>>30;x*=UINT64_C(0xbf58476d1ce4e5b9);x^=x>>27;
        x*=UINT64_C(0x94d049bb133111eb);return x^(x>>31);
    }
    template<class AddressAt> static MVKResourcePointerFingerprint compute(size_t count,bool available,AddressAt&& addressAt) {
        MVKResourcePointerFingerprint value;value.totalCount=count;value.inputAvailable=available||count==0;
        value.first=UINT64_C(1469598103934665603)^mix(count);
        value.second=UINT64_C(0x6a09e667f3bcc909)^mix(count);
        if(value.inputAvailable)for(size_t i=0;i<std::min(count,MaxHashedPointers);++i){
            uint64_t address=uint64_t(addressAt(i));
            if(i<SamplePointers){value.samples[i]=address;++value.sampleCount;}
            value.first=(value.first^mix(address+uint64_t(i)))*UINT64_C(1099511628211);
            value.second=mix(value.second^mix(address)^mix(uint64_t(i)+UINT64_C(0x9e3779b97f4a7c15)));
            ++value.hashedCount;
        }
        value.complete=value.inputAvailable&&value.hashedCount==count;return value;
    }
};
