// CPU-only descriptor identity oracle and throughput control; no GPU work.
#import <Metal/Metal.h>
#include "MVKDescriptorUseCache.h"
#include <chrono>
#include <cstdio>
#include <random>
#include <set>
#include <stdexcept>
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
static id<MTLResource> key(unsigned n){return n?(id<MTLResource>)(uintptr_t(0x100000)+64*n):nil;}
static volatile size_t consumed;
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==1 || (argc==2&&!strcmp(argv[1],"--oracle-only")),"optional --oracle-only required");
 std::mt19937 rng(3489700);unsigned edits=0,rows=0;puts("{\"GPUWorkSubmitted\":false,\"cases\":[");
 if(argc==1)for(size_t stride:{8,16,24})for(unsigned count:{16,4096,65536})for(unsigned mode:{0,1,2}){
  MVKDescriptorUseCache cache;std::vector<char>bytes(size_t(count)*stride);auto slot=[&](unsigned i)->id<MTLResource>&{return *reinterpret_cast<id<MTLResource>*>(bytes.data()+size_t(i)*stride);};
  for(unsigned i=0;i<count;i++)slot(i)=key(i%2048);auto now=cache.resources(bytes.data(),count,stride);
  auto start=std::chrono::steady_clock::now();unsigned passes=count==65536?512:2048;
  for(unsigned pass=0;pass<passes;pass++){
   auto old=now;
   {auto guard=cache.beginWrite(bytes.data(),bytes.size());
    if(mode==1)slot(rng()%count)=key(rng()%4096);
    if(mode==2)for(unsigned i=0;i<count;i++)slot(i)=key(rng()%4096);
    // Metadata is deliberately changed without changing resource identities.
    if(stride>8)bytes[(rng()%count)*stride+8]^=1;
   }
   now=cache.resources(bytes.data(),count,stride);consumed=now->size();
   if(mode==0)need(now==old,"unchanged identities lost snapshot identity");
  }
  double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  std::set<id<MTLResource>>truth;for(unsigned i=0;i<count;i++)if(slot(i))truth.insert(slot(i));need(std::set<id<MTLResource>>(now->begin(),now->end())==truth,"bulk result differs from slot oracle");
  printf("%s{\"stride\":%zu,\"slots\":%u,\"mode\":%u,\"passes\":%u,\"milliseconds\":%.6f}",rows++?",":"",stride,count,mode,passes,ms);
 }
 // Short, overlapping and disjoint writes exercise dirty-range boundaries and
 // duplicate membership counts. Check every intermediate immutable snapshot.
 for(size_t stride:{8,16,24}){
  MVKDescriptorUseCache cache;std::vector<char>bytes(257*stride);auto slot=[&](unsigned i)->id<MTLResource>&{return *reinterpret_cast<id<MTLResource>*>(bytes.data()+i*stride);};
  auto old=cache.resources(bytes.data(),257,stride);
  for(unsigned pass=0;pass<2000;pass++){
   for(unsigned write=0;write<3;write++){unsigned begin=rng()%257,n=std::min(257-begin,1+rng()%70);auto guard=cache.beginWrite(bytes.data()+begin*stride,n*stride);for(unsigned i=begin;i<begin+n;i++)slot(i)=key(rng()%64);}
   auto now=cache.resources(bytes.data(),257,stride);std::set<id<MTLResource>>truth;for(unsigned i=0;i<257;i++)if(slot(i))truth.insert(slot(i));need(std::set<id<MTLResource>>(now->begin(),now->end())==truth,"random result differs from oracle");
   if(now!=old&&!now->previous.expired()){
    std::set<id<MTLResource>>prior(old->begin(),old->end()),actualAdded(now->added.begin(),now->added.end()),actualRemoved(now->removed.begin(),now->removed.end()),expectedAdded,expectedRemoved;
    std::set_difference(truth.begin(),truth.end(),prior.begin(),prior.end(),std::inserter(expectedAdded,expectedAdded.end()));std::set_difference(prior.begin(),prior.end(),truth.begin(),truth.end(),std::inserter(expectedRemoved,expectedRemoved.end()));need(actualAdded==expectedAdded&&actualRemoved==expectedRemoved,"net membership delta differs from oracle");
   }
   old=now;++edits;
  }
 }
 printf("],\"passed\":true,\"randomOracleEdits\":%u,\"oracleMismatches\":0}\n",edits);return 0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
