// Compare actual old/new cache headers against an independent identity-set oracle.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <fstream>
#include <stdexcept>
#ifndef BASELINE_HEADER
#define BASELINE_HEADER "controls/descriptor_pre_interior_filter.h"
#endif
#define MVKDescriptorUseCache BaselineDescriptorUseCache
#include BASELINE_HEADER
#undef MVKDescriptorUseCache
#include "MVKDescriptorUseCache.h"
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
template<class Cache> static double run(unsigned n,unsigned pattern,unsigned strideWords,
 const std::vector<id<MTLResource>>&pool,unsigned&checks){
 std::vector<id<MTLResource>> slots(size_t(n)*strideWords,nil);Cache cache;
 for(unsigned i=0;i<n;++i)slots[size_t(i)*strideWords]=pool[i%pool.size()];
 auto snap=cache.resources((const char*)slots.data(),n,sizeof(id)*strideWords);
 double cost=0;
 for(unsigned pass=0;pass<80;++pass){
  {auto g=cache.beginWrite((const char*)slots.data(),slots.size()*sizeof(id));
   if(pattern==0){slots[0]=pool[pass%pool.size()];slots[size_t(n-1)*strideWords]=pool[(pass+3)%pool.size()];}
   if(pattern==1)for(unsigned i=0;i<n;++i)slots[size_t(i)*strideWords]=pool[(i+pass+1)%pool.size()];
   if(pattern==2){for(unsigned i:{0u,31u,32u,n/2,n-3,n-1})slots[size_t(i)*strideWords]=(pass%3)?pool[(pass+i)%pool.size()]:nil;}
   if(pattern==3)for(unsigned i=0;i<n;i+=64)slots[size_t(i)*strideWords]=(pass%3)?pool[(pass+i)%pool.size()]:nil;
  }
  auto start=std::chrono::steady_clock::now();snap=cache.resources((const char*)slots.data(),n,sizeof(id)*strideWords);
  cost+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  std::unordered_set<id<MTLResource>> set;
  for(unsigned i=0;i<n;++i)if(auto r=slots[size_t(i)*strideWords])set.insert(r);
  std::vector<id<MTLResource>> oracle(set.begin(),set.end());
  auto less=[](id<MTLResource>a,id<MTLResource>b){return (uintptr_t)a<(uintptr_t)b;};
  std::sort(oracle.begin(),oracle.end(),less);need(oracle.size()==snap->size()&&std::equal(oracle.begin(),oracle.end(),snap->begin()),"set oracle mismatch");++checks;
 }
 return cost;
}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report path required");id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");
 std::vector<id<MTLResource>>pool;for(unsigned i=0;i<64;++i){auto b=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];need(b!=nil,"buffer failed");pool.push_back(b);}
 std::ofstream out(argv[1]);out<<"{\"cases\":[";unsigned row=0,checks=0;
 bool fragmentedOnly=getenv("INTERIOR_FRAGMENTED_ONLY")!=nullptr;
 for(unsigned n:{4099u,65539u,500003u})for(unsigned pattern=0;pattern<4;++pattern)for(unsigned stride:{1u,4u}){
  if(fragmentedOnly ? pattern!=3 : pattern==3)continue;
  double oldMS=run<BaselineDescriptorUseCache>(n,pattern,stride,pool,checks);
  double newMS=run<MVKDescriptorUseCache>(n,pattern,stride,pool,checks);
  out<<(row++?",":"")<<"{\"slots\":"<<n<<",\"pattern\":"<<pattern<<",\"strideWords\":"<<stride<<",\"baselineMS\":"<<oldMS<<",\"candidateMS\":"<<newMS<<"}";
 }
 out<<"],\"identitySetChecks\":"<<checks<<",\"mismatches\":0,\"passed\":true}\n";for(auto r:pool)[r release];return 0;
 }catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
