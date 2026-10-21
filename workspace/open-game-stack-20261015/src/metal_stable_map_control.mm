// Exercise exact encoder map API with owned real Metal identities; no GPU work.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "MVKStableUseMap.h"
#include <chrono>
#include <cstdio>
#include <random>
#include <stdexcept>
#include <unordered_map>
using Key=id<MTLResource>;
struct Info { uint64_t generation; uint32_t value; bool write; bool retained; };
using Original=std::unordered_map<Key,Info>;
using Candidate=MVKStableUseMap<Key,Info>;
static volatile uint64_t consumed;
template<class Map> double measure(const std::vector<Key>& keys,uint64_t& checksum) {
    auto started=std::chrono::steady_clock::now();checksum=0;
    for(unsigned pass=0;pass<32;++pass) {
        Map map;map.reserve(1024);
        std::vector<Info*> stable;
        for(size_t i=0;i<keys.size();++i) {
            auto pair=map.emplace(keys[i],Info{pass,uint32_t(i+1),false,true});
            if(!pair.second)throw std::runtime_error("duplicate insertion");
            stable.push_back(&pair.first->second);
        }
        for(unsigned use=0;use<16;++use)for(size_t i=0;i<keys.size();++i) {
            auto it=map.find(keys[i]);
            if(it==map.end()||&it->second!=stable[i]||it->second.value!=i+1)
                throw std::runtime_error("lookup/address stability mismatch");
            it->second.write=true;it->second.generation=use;
            checksum+=it->second.value;
        }
        // Growth must preserve every Value address. Duplicate insertion must
        // retain previous state; clear starts a fresh lookup lifetime.
        for(size_t i=0;i<keys.size();++i) {
            auto pair=map.emplace(keys[i],Info{999,0,false,false});
            if(pair.second||!pair.first->second.write||pair.first->second.generation!=15)
                throw std::runtime_error("duplicate destroyed encoder state");
        }
        map.clear();
        if(map.size()||map.find(keys[0])!=map.end())throw std::runtime_error("clear retained identity");
        for(auto key:keys)map.emplace(key,Info{123,7,false,true});
        for(auto key:keys)if(map.find(key)->second.value!=7)throw std::runtime_error("reinsertion mismatch");
    }
    consumed=checksum;
    return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
}
int main(){@autoreleasepool{try{
    id<MTLDevice> dev=nil;
    for(id<MTLDevice>d in MTLCopyAllDevices())if([d.name containsString:@"5600M"])dev=d;
    if(!dev)throw std::runtime_error("5600M not found");
    std::vector<Key> resources;
    for(unsigned i=0;i<8192;++i){auto b=[dev newBufferWithLength:256 options:MTLResourceStorageModeShared];if(!b)throw std::runtime_error("allocation failed");resources.push_back(b);}
    printf("{\"passed\":true,\"GPUWorkSubmitted\":false,\"stableValueAddressesChecked\":true,\"cases\":[");unsigned row=0;
    std::mt19937 rng(3489700);
    for(size_t size:{64,512,1024,2048,4096,8192})for(bool shuffle:{false,true}){
        std::vector<Key>keys(resources.begin(),resources.begin()+size);if(shuffle)std::shuffle(keys.begin(),keys.end(),rng);
        uint64_t a,b;double oldMS=measure<Original>(keys,a);double newMS=measure<Candidate>(keys,b);
        if(a!=b)throw std::runtime_error("checksum mismatch");
        printf("%s{\"resources\":%zu,\"shuffled\":%s,\"oldMS\":%.3f,\"newMS\":%.3f}",row++?",":"",size,shuffle?"true":"false",oldMS,newMS);
    }
    for(Key r:resources)[r release];puts("]}");return 0;
}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 1;}}}
