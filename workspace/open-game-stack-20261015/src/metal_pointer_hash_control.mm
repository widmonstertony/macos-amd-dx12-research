// CPU lookup control with real, owned Metal resource identities. No GPU work.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "MVKPointerHash.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <numeric>
#include <random>
#include <stdexcept>
#include <unordered_map>
#include <vector>
using Key = id<MTLResource>;
static volatile uint64_t consumed = 0;
template<class Hash> static double measure(const std::vector<Key>& keys, uint64_t& checksum,
                                          size_t& buckets, size_t& longest, size_t& occupied) {
    std::unordered_map<Key, uint32_t, Hash> map;
    map.reserve(1024); // Exact active helper reservation policy.
    for (size_t i=0;i<keys.size();++i) map.emplace(keys[i], uint32_t(i+1));
    buckets=map.bucket_count(); longest=0; occupied=0;
    for(size_t i=0;i<buckets;++i) {
        auto size=map.bucket_size(i); longest=std::max(longest,size);occupied+=bool(size);
    }
    auto started=std::chrono::steady_clock::now();checksum=0;
    for(unsigned pass=0;pass<256;++pass) {
        for(size_t i=0;i<keys.size();++i) {
            auto it=map.find(keys[i]);
            if(it==map.end() || it->second!=i+1)throw std::runtime_error("identity lookup mismatch");
            checksum+=it->second;
        }
    }
    consumed=checksum;
    return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
}
int main() { @autoreleasepool { try {
    id<MTLDevice> dev=nil;
    for(id<MTLDevice> d in MTLCopyAllDevices()) if([d.name containsString:@"5600M"])dev=d;
    if(!dev) throw std::runtime_error("5600M not found");
    std::vector<Key> resources;
    for(unsigned i=0;i<4096;++i) {
        auto b=[dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        if(!b) throw std::runtime_error("owned Metal allocation failed");
        resources.push_back(b);
    }
    std::mt19937 rng(3489700);
    std::printf("{\"passed\":true,\"GPUWorkSubmitted\":false,\"cases\":[");unsigned row=0;
    for(size_t size:{512,1024,2048,4096})for(bool shuffle:{false,true}) {
        std::vector<Key> keys(resources.begin(),resources.begin()+size);
        if(shuffle)std::shuffle(keys.begin(),keys.end(),rng);
        uint64_t oldSum,newSum;size_t ob,ol,oo,nb,nl,no;
        double oldMS=measure<std::hash<Key>>(keys,oldSum,ob,ol,oo);
        double newMS=measure<MVKPointerHash<Key>>(keys,newSum,nb,nl,no);
        if(oldSum!=newSum)throw std::runtime_error("checksum mismatch");
        std::printf("%s{\"resources\":%zu,\"shuffled\":%s,\"oldBuckets\":%zu,\"oldOccupied\":%zu,\"oldLongestChain\":%zu,\"newBuckets\":%zu,\"newOccupied\":%zu,\"newLongestChain\":%zu,\"oldMS\":%.3f,\"newMS\":%.3f}",row++?",":"",size,shuffle?"true":"false",ob,oo,ol,nb,no,nl,oldMS,newMS);
    }
    for(Key r:resources)[r release];
    std::puts("]}");return 0;
 }catch(const std::exception& e){fprintf(stderr,"%s\n",e.what());return 1;} } }
