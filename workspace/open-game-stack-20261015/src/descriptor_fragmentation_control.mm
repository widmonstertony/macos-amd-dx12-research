// Many separate descriptor writes, with independent set oracles for two views.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <fstream>
#include <stdexcept>
#include <thread>
#include <atomic>
#ifndef BASELINE_HEADER
#define BASELINE_HEADER "controls/descriptor_before_dirty_bitmap.h"
#endif
#define MVKDescriptorUseCache BaselineDescriptorUseCache
#include BASELINE_HEADER
#undef MVKDescriptorUseCache
#include "MVKDescriptorUseCache.h"
static void need(bool b,const char*s){if(!b)throw std::runtime_error(s);}
struct Times{double sparse=0,dense=0,write=0;};
template<class Cache> Times run(unsigned n,unsigned stride,unsigned writes,
 const std::vector<id<MTLResource>>&pool,unsigned&checks){
 std::vector<id<MTLResource>>slots(size_t(n)*stride,nil);for(unsigned i=0;i<64;++i)slots[size_t(i)*stride]=pool[i];Cache c;
 auto primary=c.resources((const char*)slots.data(),n,stride*sizeof(id));
 auto offset=c.resources((const char*)(slots.data()+17*stride),n-17,stride*sizeof(id));Times times;
 auto verify=[&](const auto&snap,unsigned first){std::unordered_set<id<MTLResource>>set;
  for(unsigned i=first;i<n;++i)if(auto x=slots[size_t(i)*stride])set.insert(x);
  std::vector<id<MTLResource>>oracle(set.begin(),set.end());std::sort(oracle.begin(),oracle.end(),[](id<MTLResource>a,id<MTLResource>b){return (uintptr_t)a<(uintptr_t)b;});
  need(oracle.size()==snap->size()&&std::equal(oracle.begin(),oracle.end(),snap->begin()),"fragmented set oracle mismatch");++checks;};
 for(unsigned pass=0;pass<40;++pass){auto start=std::chrono::steady_clock::now();
  for(unsigned j=0;j<writes;++j){unsigned index=(uint64_t(j)*9973+uint64_t(pass)*7919)%n;
   auto guard=c.beginWrite((const char*)(slots.data()+size_t(index)*stride),sizeof(id));slots[size_t(index)*stride]=pass%5?pool[(j+pass)%pool.size()]:nil;}
  // Exercise full coverage arriving after fragmentation and a partial last block.
  bool dense=pass==13||pass==29||pass==39;
  if(dense){auto guard=c.beginWrite((const char*)slots.data(),slots.size()*sizeof(id));for(unsigned i=0;i<n;++i)slots[size_t(i)*stride]=pass==39?nil:pool[(i+pass)%pool.size()];}
  {auto guard=c.beginWrite((const char*)(slots.data()+size_t(n-1)*stride),sizeof(id));slots[size_t(n-1)*stride]=pass==39?nil:pool[pass%pool.size()];}
  times.write+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  start=std::chrono::steady_clock::now();primary=c.resources((const char*)slots.data(),n,stride*sizeof(id));offset=c.resources((const char*)(slots.data()+17*stride),n-17,stride*sizeof(id));
  double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();if(dense)times.dense+=ms;else times.sparse+=ms;
  verify(primary,0);verify(offset,17);
 }
 return times;
}
template<class Cache> void concurrentPhases(const std::vector<id<MTLResource>>&pool,
 unsigned stride,unsigned&checks){
 constexpr unsigned n=8195,phases=40;std::vector<id<MTLResource>>slots(size_t(n)*stride,nil);Cache cache;
 cache.resources((const char*)slots.data(),n,stride*sizeof(id));
 cache.resources((const char*)(slots.data()+17*stride),n-17,stride*sizeof(id));
 std::atomic<int> command{-1};std::atomic<unsigned>done{0};
 auto worker=[&](unsigned lane){for(unsigned p=0;p<phases;++p){
  while(command.load(std::memory_order_acquire)<int(p))std::this_thread::yield();
  for(unsigned j=0;j<64;++j){unsigned i=lane*3000+j*32;auto guard=cache.beginWrite((const char*)(slots.data()+size_t(i)*stride),sizeof(id));slots[size_t(i)*stride]=pool[lane*32+p%32];}
  if(lane){auto guard=cache.beginWrite((const char*)(slots.data()+size_t(n-1)*stride),sizeof(id));slots[size_t(n-1)*stride]=pool[32+p%32];}
  done.fetch_add(1,std::memory_order_release);
 }};
 std::thread a(worker,0),b(worker,1);
 bool ok=true;
 for(unsigned p=0;p<phases;++p){command.store(int(p),std::memory_order_release);while(done.load(std::memory_order_acquire)<2*(p+1))std::this_thread::yield();
  for(unsigned first:{0u,17u}){auto snap=cache.resources((const char*)(slots.data()+size_t(first)*stride),n-first,stride*sizeof(id));
   ok &= snap->size()==2&&snap->contains(pool[p%32])&&snap->contains(pool[32+p%32]);++checks;}
 }
 a.join();b.join();need(ok,"concurrent fragmented writes lost an identity");
}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report path required");id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");
 std::vector<id<MTLResource>>pool;for(unsigned i=0;i<64;++i){auto b=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];need(b!=nil,"buffer failed");pool.push_back(b);}
 std::ofstream out(argv[1]);out<<"{\"cases\":[";unsigned row=0,checks=0;
 for(unsigned n:{65539u,500003u})for(unsigned stride:{1u,4u})for(unsigned writes:{48u,128u,512u}){
  auto old=run<BaselineDescriptorUseCache>(n,stride,writes,pool,checks);auto next=run<MVKDescriptorUseCache>(n,stride,writes,pool,checks);
  out<<(row++?",":"")<<"{\"slots\":"<<n<<",\"strideWords\":"<<stride<<",\"separateWrites\":"<<writes<<",\"baselineSparseMS\":"<<old.sparse<<",\"candidateSparseMS\":"<<next.sparse<<",\"baselineDenseMS\":"<<old.dense<<",\"candidateDenseMS\":"<<next.dense<<",\"baselineWriteMS\":"<<old.write<<",\"candidateWriteMS\":"<<next.write<<"}";
 }
 concurrentPhases<MVKDescriptorUseCache>(pool,1,checks);concurrentPhases<MVKDescriptorUseCache>(pool,4,checks);
 auto stats=MVKDescriptorUseCache::takeWriteStats();need(stats.bitmapBuilds>0&&stats.bitmapReadSlots>0,"bitmap path was not exercised");
 out<<"],\"identitySetChecks\":"<<checks<<",\"viewsPerTable\":2,\"concurrentWriters\":2,\"concurrentPhases\":80,\"bitmapBuilds\":"<<stats.bitmapBuilds<<",\"bitmapReadSlots\":"<<stats.bitmapReadSlots<<",\"bitmapEnvelopeSlots\":"<<stats.bitmapEnvelopeSlots<<",\"mismatches\":0,\"passed\":true}\n";for(auto b:pool)[b release];return 0;
 }catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
