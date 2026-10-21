// Paired CPU comparison. Both exact headers run in one process, alternating
// order to reduce thermal/scheduling drift. No GPU work or Objective-C sends.
#import <Metal/Metal.h>
#define MVKDescriptorUseCache BaselineDescriptorUseCache
#include MVK_BASELINE_DESCRIPTOR_HEADER
#undef MVKDescriptorUseCache
#include "MVKDescriptorUseCache.h"
#include <chrono>
#include <cstdio>
#include <set>
#include <stdexcept>
static id<MTLResource> key(unsigned n){return n?(id<MTLResource>)(uintptr_t(0x100000)+64*n):nil;}
static volatile size_t consumed;
template<class Cache> double run(unsigned count,size_t stride,unsigned mode){
 Cache cache;std::vector<char>bytes(size_t(count)*stride);auto slot=[&](unsigned i)->id<MTLResource>&{return *reinterpret_cast<id<MTLResource>*>(bytes.data()+i*stride);};for(unsigned i=0;i<count;i++)slot(i)=key(i%2048);auto snapshot=cache.resources(bytes.data(),count,stride);
 unsigned passes=count>=500000?16:count>=65536?64:256;auto start=std::chrono::steady_clock::now();
 for(unsigned p=0;p<passes;p++){
  auto old=snapshot;
  {auto guard=cache.beginWrite(bytes.data(),bytes.size());
   if(mode==1)slot(count/2)=key(2049+(p&1));
   if(mode==2)for(unsigned i=0;i<count;i++)slot(i)=key((i+p)%4096);
   if(stride>8)bytes[8]^=1;
  }
  snapshot=cache.resources(bytes.data(),count,stride);consumed=snapshot->size();
  if(mode==0&&snapshot!=old)throw std::runtime_error("unchanged membership lost snapshot identity");
 }
 double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();std::set<id<MTLResource>>truth;for(unsigned i=0;i<count;i++)if(slot(i))truth.insert(slot(i));if(std::set<id<MTLResource>>(snapshot->begin(),snapshot->end())!=truth)throw std::runtime_error("slot oracle mismatch");return ms;
}
int main(){try{unsigned row=0;puts("{\"GPUWorkSubmitted\":false,\"pairedSameProcess\":true,\"cases\":[");
 for(size_t stride:{8,16,24})for(unsigned count:{4096,65536,500000})for(unsigned mode:{0,1,2}){
  double before[5],after[5];for(unsigned pair=0;pair<5;pair++){if(pair&1){after[pair]=run<MVKDescriptorUseCache>(count,stride,mode);before[pair]=run<BaselineDescriptorUseCache>(count,stride,mode);}else{before[pair]=run<BaselineDescriptorUseCache>(count,stride,mode);after[pair]=run<MVKDescriptorUseCache>(count,stride,mode);}}
  auto a=std::vector<double>(before,before+5),z=std::vector<double>(after,after+5);std::sort(a.begin(),a.end());std::sort(z.begin(),z.end());printf("%s{\"stride\":%zu,\"slots\":%u,\"mode\":%u,\"beforeMedianMS\":%.6f,\"afterMedianMS\":%.6f,\"speedup\":%.6f}",row++?",":"",stride,count,mode,a[2],z[2],a[2]/z[2]);fflush(stdout);
 }
 puts("],\"passed\":true,\"oracleMismatches\":0}");return 0;
}catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}
