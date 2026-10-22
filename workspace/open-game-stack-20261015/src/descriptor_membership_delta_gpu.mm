// Exercise the actual MoltenVK helper, including absent -> registered resources,
// access upgrades, and declarations in every encoder, with native GPU readback.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <chrono>
#include <stdexcept>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
static void need(bool ok,const char* why) {if(!ok)throw std::runtime_error(why);}
static void immediate(id<MTLCommandEncoder> e,id<MTLResource> r,MTLResourceUsage usage,MVKResourceUsageStages) {
 [(id<MTLComputeCommandEncoder>)e useResource:r usage:usage];
}
int main(int argc,const char**argv) { @autoreleasepool { try {
 need(argc==2,"report path required");
 id<MTLDevice> device=nil;for(id<MTLDevice>d in MTLCopyAllDevices())if([d.name containsString:@"5600M"]){device=[d retain];break;}need(device!=nil,"5600M required");
 NSError* error=nil;NSString* source=@"#include <metal_stdlib>\nusing namespace metal;struct Args{device uint* value [[id(0)]];};kernel void step(constant Args& a [[buffer(0)]],device uint* out [[buffer(1)]],constant uint& index [[buffer(2)]]){out[index]=*a.value;*a.value+=1;}";
 id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];need(library!=nil,"library failed");
 id<MTLFunction> fn=[library newFunctionWithName:@"step"];id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:fn error:&error];need(pipeline!=nil,"pipeline failed");
 id<MTLArgumentEncoder> args=[fn newArgumentEncoderWithBufferIndex:0];id<MTLBuffer> table=[device newBufferWithLength:args.encodedLength options:MTLResourceStorageModeShared];[args setArgumentBuffer:table offset:0];
 id<MTLBuffer> input=[device newBufferWithLength:256 options:MTLResourceStorageModeShared],next=[device newBufferWithLength:256 options:MTLResourceStorageModeShared],late=[device newBufferWithLength:256 options:MTLResourceStorageModeShared],unrelated=[device newBufferWithLength:256 options:MTLResourceStorageModeShared],output=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
 *(uint32_t*)input.contents=100;*(uint32_t*)next.contents=200;*(uint32_t*)late.contents=300;memset(output.contents,0xcd,256);
 MVKLiveList list;list.add(input);list.add(next);MVKDescriptorUseCache cache;std::vector<id<MTLResource>> slots;
 for(uintptr_t i=0;i<4096;++i)slots.push_back((id<MTLResource>)(0x100000+i*64));slots[0]=input;slots[1]=input;slots[2]=late;
 auto snapshot=[&]{return cache.resources((const char*)slots.data(),slots.size(),sizeof(id));};
 id<MTLCommandQueue> queue=[device newCommandQueue];uint64_t oneSlotLookups=0,registrationFallbackLookups=0,unrelatedDeltaLookups=0,deltaHits=0;
 {
 MVKUseResourceHelper h;need(h.crossEncoderSnapshotReuse,"qualified snapshot retention required");
 for(uint32_t pass=0;pass<6;++pass){
  if(pass==1){auto w=cache.beginWrite((const char*)&slots.back(),sizeof(id));slots.back()=(id<MTLResource>)0xdead1000;}
  if(pass==2){auto w=cache.beginWrite((const char*)&slots[0],sizeof(id));slots[0]=next;}
  if(pass==3){list.add(late);auto w=cache.beginWrite((const char*)&slots[1],sizeof(id));slots[1]=nil;}
  if(pass==5){list.add(unrelated);auto w=cache.beginWrite((const char*)&slots.back(),sizeof(id));slots.back()=(id<MTLResource>)0xdead2000;}
  auto current=snapshot();h.resetForEncoder();id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> enc=[cb computeCommandEncoder];
  uint64_t before=h.statsLookups,hits=h.statsSnapshotDeltaHits,builds=list.snapshotCacheBuilds.load();h.addLiveSnapshot(current,list,enc,immediate,MVKResourceUsageStages::Compute,true);
  if(pass==1){oneSlotLookups=h.statsLookups-before;need(oneSlotLookups==1&&h.statsSnapshotDeltaHits==hits+1,"single edit scanned unchanged descriptors");}
  if(pass==3){registrationFallbackLookups=h.statsLookups-before;need(h.statsSnapshotDeltaHits==hits&&(registrationFallbackLookups>4000||list.snapshotCacheBuilds.load()>builds),"newly registered unchanged identity escaped full validation");}
  if(pass==5){unrelatedDeltaLookups=h.statsLookups-before;need(unrelatedDeltaLookups==1&&h.statsSnapshotDeltaHits==hits+1,"unrelated registration disabled safe delta reuse");}
  deltaHits += h.statsSnapshotDeltaHits-hits;
  id<MTLBuffer> active=pass<2?input:pass==2?next:late;
  need(h.used.find(active)!=h.used.end()&&h.used.find(active)->second.generation==h.encoderGeneration&&h.used.find(active)->second.write,"encoder write declaration missing");
  if(pass>=3){auto declared=h.declaredSnapshots.back().liveSnapshot;need(std::find_if(declared->begin(),declared->end(),[&](const auto& record){return record.resource==input;})==declared->end(),"removed input remained in filtered successor");}
  h.bindAndResetCompute(enc);[args setBuffer:active offset:0 atIndex:0];[enc setComputePipelineState:pipeline];[enc setBuffer:table offset:0 atIndex:0];[enc setBuffer:output offset:0 atIndex:1];[enc setBytes:&pass length:4 atIndex:2];[enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"GPU command failed");
 }
 list.remove(input);list.remove(next);list.remove(late);list.remove(unrelated);
 }
 uint32_t expected[]={100,101,200,300,301,302};uint64_t mismatch=0;for(unsigned i=0;i<6;++i)if(((uint32_t*)output.contents)[i]!=expected[i])++mismatch;
 if(*(uint32_t*)input.contents!=102||*(uint32_t*)next.contents!=201||*(uint32_t*)late.contents!=303)++mismatch;
 std::ofstream report(argv[1]);report<<"{\"passed\":"<<(mismatch?"false":"true")<<",\"GPUWordsChecked\":9,\"mismatches\":"<<mismatch<<",\"descriptorSlots\":4096,\"oneSlotEditLiveLookups\":"<<oneSlotLookups<<",\"registrationFallbackLiveLookups\":"<<registrationFallbackLookups<<",\"unrelatedRegistrationLiveLookups\":"<<unrelatedDeltaLookups<<",\"deltaHits\":"<<deltaHits<<",\"encoderWriteDeclarationsChecked\":true,\"removedIdentityChecked\":true}\n";
 [queue release];[output release];[input release];[next release];[late release];[unrelated release];[table release];[args release];[pipeline release];[fn release];[library release];[device release];return mismatch?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}
}}
