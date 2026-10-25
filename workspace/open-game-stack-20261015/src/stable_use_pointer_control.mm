// Stable value pointers avoid deque-iterator return ABI in the sampled encoder map.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <fstream>
#include <stdexcept>
#include <unordered_map>
#ifndef BASELINE_HEADER
#define BASELINE_HEADER "controls/stable_use_before_pointer_return.h"
#endif
#define MVKStableUseMap BaselineStableUseMap
#include BASELINE_HEADER
#undef MVKStableUseMap
#include "MVKStableUseMap.h"
template<class K,class V> class BaselineValueMap : public BaselineStableUseMap<K,V> {
public: std::pair<V*,bool> emplaceValue(K key,const V& value){auto e=this->emplace(key,value);return {&e.first->second,e.second};}
};
struct State { uint64_t value=0, generation=0, mask=0; void* held=nullptr; };
static void need(bool b,const char* s){if(!b)throw std::runtime_error(s);}
static size_t mixed(size_t h){h^=h>>33;h*=UINT64_C(0xff51afd7ed558ccd);h^=h>>33;h*=UINT64_C(0xc4ceb9fe1a85ec53);return h^(h>>33);}
struct Distribution { uint64_t probes=0,maxProbe=0,usedBuckets=0; };
static Distribution distribution(const std::vector<id<MTLResource>>& pool,unsigned n,bool mix){
 size_t cap=16;while(cap/2<n)cap*=2;std::vector<bool> table(cap),buckets(cap);Distribution d;
 for(unsigned k=0;k<n;++k){size_t h=std::hash<id<MTLResource>>{}(pool[k]);size_t i=(mix?mixed(h):h)&(cap-1);buckets[i]=true;uint64_t p=1;while(table[i]){++p;i=(i+1)&(cap-1);}table[i]=true;d.probes+=p;d.maxProbe=std::max(d.maxProbe,p);}
 for(bool b:buckets)d.usedBuckets+=b;return d;
}
struct Timing {double existingMS=0,findMS=0;uint64_t checksum=0;};
template<class Map> Timing bench(const std::vector<id<MTLResource>>&pool,unsigned n){
 Map map;map.reserve(n);for(unsigned i=0;i<n;++i)map.emplaceValue(pool[i],State{i,9,13,nullptr});
 Timing result;constexpr unsigned rounds=200;auto start=std::chrono::steady_clock::now();
 for(unsigned r=0;r<rounds;++r)for(unsigned i=0;i<n;++i){auto e=map.emplaceValue(pool[(i*997+r)%n],State{});result.checksum+=e.first->value;need(!e.second,"existing identity inserted twice");}
 result.existingMS=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();start=std::chrono::steady_clock::now();
 for(unsigned r=0;r<rounds;++r)for(unsigned i=0;i<n;++i){auto s=map.findValue(pool[(i*997+r)%n]);need(s!=nullptr,"existing identity absent");result.checksum+=s->value;}
 result.findMS=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();return result;
}
template<class Map> void oracle(const std::vector<id<MTLResource>>&pool,uint64_t&checks){
 Map map;std::unordered_map<id<MTLResource>,State*> held;
 for(unsigned i=0;i<pool.size();++i){auto e=map.emplaceValue(pool[i],State{i,17,23,nullptr});need(e.second,"new insertion failed");held[pool[i]]=e.first;}
 // Stable ResourceInfo pointers must survive index growth and deque appends.
 map.reserve(pool.size()*4);
 for(unsigned i=0;i<pool.size();++i){auto s=map.findValue(pool[i]);need(s==held.at(pool[i])&&s->value==i&&s->generation==17&&s->mask==23,"value or pointer changed after rehash");++checks;auto again=map.emplaceValue(pool[i],State{});need(!again.second&& again.first==s,"duplicate insertion changed state");++checks;}
 need(map.findValue(nil)==nullptr,"absent identity unexpectedly found");++checks;
 map.clear();need(map.size()==0&&map.findValue(pool[0])==nullptr,"clear retained stale entry");++checks;
 for(unsigned i=0;i<pool.size();++i)map.emplaceValue(pool[i],State{i+100,31,37,nullptr});
 for(unsigned i=0;i<pool.size();++i){need(map.findValue(pool[i])->value==i+100,"clear/reinsert mismatch");++checks;}
}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"output path required");id<MTLDevice> device=nil;for(id<MTLDevice> d in MTLCopyAllDevices())if([d.name containsString:@"5600M"])device=d;need(device!=nil,"5600M required");
 std::vector<id<MTLResource>> pool;for(unsigned i=0;i<4096;++i){auto b=[device newBufferWithLength:64 options:MTLResourceStorageModeShared];need(b!=nil,"buffer allocation failed");pool.push_back(b);}
 uint64_t checks=0;oracle<BaselineValueMap<id<MTLResource>,State>>(pool,checks);oracle<MVKStableUseMap<id<MTLResource>,State>>(pool,checks);
 std::ofstream out(argv[1]);out<<"{\"device\":\"AMD Radeon Pro 5600M\",\"realMetalIdentities\":4096,\"cases\":[";unsigned row=0;
 for(unsigned n:{256u,2048u,4096u}){auto a=bench<BaselineValueMap<id<MTLResource>,State>>(pool,n);auto b=bench<MVKStableUseMap<id<MTLResource>,State>>(pool,n);need(a.checksum==b.checksum,"lookup checksum mismatch");auto old=distribution(pool,n,false),next=distribution(pool,n,false);
  out<<(row++?",":"")<<"{\"resources\":"<<n<<",\"baselineExistingMS\":"<<a.existingMS<<",\"candidateExistingMS\":"<<b.existingMS<<",\"baselineFindMS\":"<<a.findMS<<",\"candidateFindMS\":"<<b.findMS<<",\"baselineInsertionProbes\":"<<old.probes<<",\"candidateInsertionProbes\":"<<next.probes<<",\"baselineMaxProbe\":"<<old.maxProbe<<",\"candidateMaxProbe\":"<<next.maxProbe<<",\"baselineBuckets\":"<<old.usedBuckets<<",\"candidateBuckets\":"<<next.usedBuckets<<"}";
 }
 out<<"],\"valueAndStablePointerChecks\":"<<checks<<",\"mismatches\":0,\"passed\":true}\n";for(auto b:pool)[b release];return 0;
 }catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
