// Owned GPU oracle: registry changes, independent helpers and bounded leases.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <stdexcept>
#include <thread>
#include <atomic>
#include <chrono>
static void need(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
static void use(id<MTLCommandEncoder> e,id<MTLResource> r,MTLResourceUsage u,MVKResourceUsageStages){[(id<MTLComputeCommandEncoder>)e useResource:r usage:u];}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report required");id<MTLDevice>d=nil;
 for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"]){d=[x retain];break;}
 need(d!=nil,"5600M required");NSError*error=nil;
 NSString*source=@"#include <metal_stdlib>\nusing namespace metal;struct Args{device uint* value [[id(0)]];};kernel void step(constant Args& a [[buffer(0)]],device uint* out [[buffer(1)]],constant uint& index [[buffer(2)]]){out[index]=*a.value;*a.value+=1;}";
 id<MTLLibrary>lib=[d newLibraryWithSource:source options:nil error:&error];need(lib!=nil,"library failed");
 id<MTLFunction>fn=[lib newFunctionWithName:@"step"];id<MTLComputePipelineState>pipe=[d newComputePipelineStateWithFunction:fn error:&error];need(pipe!=nil,"pipeline failed");
 id<MTLArgumentEncoder>ae=[fn newArgumentEncoderWithBufferIndex:0];id<MTLBuffer>table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];
 id<MTLBuffer>input=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],next=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],unrelated=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],out=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];
 *(uint32_t*)input.contents=100;*(uint32_t*)next.contents=200;
 auto values=std::make_shared<MVKDescriptorUseCache::Resources>();
 for(uintptr_t i=1;i<=4096;i++)values->push_back((id<MTLResource>)(0x100000+i*64));values->push_back(input);values->push_back(next);
 MVKDescriptorUseCache::Snapshot snapshot=values;MVKLiveList registry;registry.add(input);
 need(registry.retainedSnapshot(snapshot)!=nullptr,"shared snapshot option required");
 id<MTLCommandQueue>queue=[d newCommandQueue];
 for(uint32_t pass=0;pass<6;pass++){
  if(pass==2){registry.remove(input);registry.add(next);}
  if(pass==4)registry.add(input);
  if(pass==5){registry.add(next);registry.remove(next);} // Reference count remains one.
  MVKUseResourceHelper helper;helper.resetForEncoder();
  id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLComputeCommandEncoder>enc=[cb computeCommandEncoder];
  helper.addLiveSnapshot(snapshot,registry,enc,use,MVKResourceUsageStages::Compute,false);
  helper.addLiveSnapshot(snapshot,registry,enc,use,MVKResourceUsageStages::Compute,true);
  id<MTLBuffer>active=(pass<2||pass==4)?input:next;
  need(helper.used.find(active)!=helper.used.end(),"registered resource missing");
  if(pass==2||pass==3)need(helper.used.find(input)==helper.used.end(),"removed identity survived into a fresh helper");
  helper.bindAndResetCompute(enc);[ae setBuffer:active offset:0 atIndex:0];[enc setComputePipelineState:pipe];[enc setBuffer:table offset:0 atIndex:0];[enc setBuffer:out offset:0 atIndex:1];[enc setBytes:&pass length:4 atIndex:2];[enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"GPU failed");
 }
 uint32_t expected[]={100,101,200,201,102,202};uint64_t mismatches=0;
 for(unsigned i=0;i<6;i++)mismatches+=((uint32_t*)out.contents)[i]!=expected[i];
 mismatches+=*(uint32_t*)input.contents!=103;mismatches+=*(uint32_t*)next.contents!=203;
 need(registry.snapshotCacheHits.load()>=2,"separate helpers did not share validation");
 // Removing the last registration must evict cache-owned references promptly.
 // A borrowed lease must nevertheless stay alive until its reader releases it.
 auto borrowed=registry.retainedSnapshot(snapshot);std::weak_ptr<const MVKLiveList::RetainedSnapshot>weak=borrowed;
 registry.remove(input);need(!weak.expired(),"removal destroyed a borrowed lease");borrowed.reset();need(weak.expired(),"removed object remained pinned by cache");
 auto fresh=registry.retainedSnapshot(snapshot);need(std::find(fresh->begin(),fresh->end(),input)==fresh->end(),"removed identity reappeared");fresh.reset();
 // Unrelated streaming churn must preserve the exact shared validation, while
 // a registration whose identity occurs in the snapshot must rebuild it.
 auto stable=registry.retainedSnapshot(snapshot);uint64_t buildsBeforeUnrelated=registry.snapshotCacheBuilds.load(),hitsBeforeUnrelated=registry.snapshotCacheHits.load();
 registry.add(unrelated);registry.remove(unrelated);auto afterUnrelated=registry.retainedSnapshot(snapshot);
 need(afterUnrelated==stable,"unrelated mutation evicted shared validation");
 need(registry.snapshotCacheBuilds.load()==buildsBeforeUnrelated&&registry.snapshotCacheHits.load()==hitsBeforeUnrelated+1,"unrelated mutation missed exact reuse");
 // A successor whose set membership changes by a small immutable delta must
 // derive a new owned lease without rescanning every raw identity.
 registry.add(unrelated);auto parent=registry.retainedSnapshot(snapshot);auto successor=std::make_shared<MVKDescriptorUseCache::Resources>();
 successor->push_back(next);successor->push_back(unrelated);successor->previous=snapshot;successor->added.push_back(unrelated);successor->removed.push_back(input);
 uint64_t buildsBeforeDelta=registry.snapshotCacheBuilds.load(),deltaBefore=registry.snapshotDeltaBuilds.load();auto derived=registry.retainedSnapshot(successor);
 need(derived->size()==2&&std::find(derived->begin(),derived->end(),next)!=derived->end()&&std::find(derived->begin(),derived->end(),unrelated)!=derived->end(),"successor delta produced wrong lease");
 need(registry.snapshotCacheBuilds.load()==buildsBeforeDelta&&registry.snapshotDeltaBuilds.load()==deltaBefore+1,"successor delta fell back to full scan");
 parent.reset();derived.reset();registry.remove(unrelated);
 registry.add(input);auto afterRelated=registry.retainedSnapshot(snapshot);
 need(afterRelated!=stable&&std::find(afterRelated->begin(),afterRelated->end(),input)!=afterRelated->end(),"related addition reused stale validation");
 stable.reset();afterUnrelated.reset();afterRelated.reset();registry.remove(input);
 // The game needs more than 64 immutable tables per frame.  Populate a
 // larger working set, then remove one identity and prove the reverse index
 // invalidates only its owning lease while an unrelated late entry remains
 // an exact shared-cache hit.
 std::vector<id<MTLBuffer>> reverseBuffers;std::vector<MVKDescriptorUseCache::Snapshot> reverseSnapshots;std::vector<MVKLiveList::SnapshotLease> reverseLeases;
 for(unsigned i=0;i<96;i++){id<MTLBuffer>b=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];need(b!=nil,"reverse-index allocation failed");reverseBuffers.push_back(b);registry.add(b);auto s=std::make_shared<MVKDescriptorUseCache::Resources>();s->push_back(next);s->push_back(b);reverseSnapshots.push_back(s);reverseLeases.push_back(registry.retainedSnapshot(s));}
 auto unaffected=reverseLeases.back();uint64_t reverseHits=registry.snapshotCacheHits.load();registry.remove(reverseBuffers.front());auto invalidated=registry.retainedSnapshot(reverseSnapshots.front());auto unaffectedAgain=registry.retainedSnapshot(reverseSnapshots.back());
 need(invalidated->size()==1&&invalidated->front()==next,"reverse index retained removed resource");
 need(unaffectedAgain==unaffected&&registry.snapshotCacheHits.load()==reverseHits+1,"reverse index evicted unrelated large-working-set lease");
 for(unsigned i=1;i<reverseBuffers.size();i++)registry.remove(reverseBuffers[i]);for(auto b:reverseBuffers)[b release];
 // Concurrent unrelated registry mutation must not corrupt immutable results.
 std::atomic<bool>start{false};std::thread writer([&]{while(!start.load()){} for(unsigned i=0;i<1000;i++){registry.add(unrelated);registry.remove(unrelated);}});
 start.store(true);bool concurrentOK=true;
 for(unsigned i=0;i<1000;i++){auto lease=registry.retainedSnapshot(snapshot);concurrentOK &= lease->size()==1&&lease->front()==next;}
 writer.join();need(concurrentOK,"concurrent registry corrupted a snapshot");
 uint64_t hits=registry.snapshotCacheHits.load(),builds=registry.snapshotCacheBuilds.load();registry.remove(next);
 // Same Metal identities and helper count, with and without shared validation.
 std::vector<id<MTLBuffer>> pool;auto poolSnapshot=std::make_shared<MVKDescriptorUseCache::Resources>();
 for(unsigned i=0;i<1588;i++){auto b=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];need(b!=nil,"CPU control allocation failed");pool.push_back(b);poolSnapshot->push_back(b);}
 struct Timing{bool shared;double ms;uint64_t hits,builds;};std::vector<Timing> timings;
 for(bool enabled:{false,true,true,false,false,true}){
  setenv("MVK_AMD_SHARED_LIVE_SNAPSHOTS",enabled?"1":"0",1);MVKLiveList common;for(auto b:pool)common.add(b);
  auto start=std::chrono::steady_clock::now();
  for(unsigned submission=0;submission<128;submission++){
   MVKUseResourceHelper h;
   for(unsigned encoder=0;encoder<4;encoder++){
    h.resetForEncoder();h.addLiveSnapshot(poolSnapshot,common,nil,use,MVKResourceUsageStages::Compute,false);
    h.addLiveSnapshot(poolSnapshot,common,nil,use,MVKResourceUsageStages::Compute,true);h.bindAndResetCompute(nil);
   }
  }
  double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  timings.push_back({enabled,ms,common.snapshotCacheHits.load(),common.snapshotCacheBuilds.load()});
  for(auto b:pool)common.remove(b);
 }
 setenv("MVK_AMD_SHARED_LIVE_SNAPSHOTS","1",1);for(auto b:pool)[b release];
 std::ofstream report(argv[1]);report<<"{\"passed\":"<<(mismatches?"false":"true")<<",\"GPUWordsChecked\":8,\"mismatches\":"<<mismatches<<",\"independentHelpers\":6,\"cacheHits\":"<<hits<<",\"cacheBuilds\":"<<builds<<",\"submissionCPUControls\":[";for(size_t i=0;i<timings.size();i++){auto t=timings[i];if(i)report<<",";report<<"{\"shared\":"<<(t.shared?"true":"false")<<",\"milliseconds\":"<<t.ms<<",\"hits\":"<<t.hits<<",\"builds\":"<<t.builds<<"}";}report<<"],\"mutationIterations\":1000,\"reverseIndexWorkingSetEntries\":96,\"reverseIndexExactInvalidation\":true,\"removedIdentityExcluded\":true,\"borrowedLeaseSurvivesEviction\":true,\"cacheOwnershipReleasedOnRemoval\":true}\n";
 [queue release];[out release];[unrelated release];[input release];[next release];[table release];[ae release];[pipe release];[fn release];[lib release];[d release];return mismatches?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
