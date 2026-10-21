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
 signal(SIGSEGV, +[](int sig){void* frames[64];int n=backtrace(frames,64);backtrace_symbols_fd(frames,n,2);_exit(128+sig);});
 fprintf(stderr,"stage=entry\n");
 need(argc==2,"report path required");
 id<MTLDevice> device=nil;
 for(id<MTLDevice> d in MTLCopyAllDevices())if([d.name containsString:@"AMD"]) {device=[d retain];break;}
 need(device!=nil,"AMD Metal device required");
 NSError* error=nil;
 NSString* source=@"#include <metal_stdlib>\nusing namespace metal;struct Args{device uint* value [[id(0)]];};kernel void step(constant Args& a [[buffer(0)]],device uint* out [[buffer(1)]],constant uint& index [[buffer(2)]]){out[index]=*a.value;*a.value+=1;}";
 id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
 need(library!=nil,error.localizedDescription.UTF8String?:"library failed");
 fprintf(stderr,"stage=library\n");
 id<MTLFunction> fn=[library newFunctionWithName:@"step"];
 id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:fn error:&error];need(pipeline!=nil,"pipeline failed");
 id<MTLArgumentEncoder> args=[fn newArgumentEncoderWithBufferIndex:0];
 id<MTLBuffer> input=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
 id<MTLBuffer> next=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
 id<MTLBuffer> output=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
 id<MTLBuffer> table=[device newBufferWithLength:args.encodedLength options:MTLResourceStorageModeShared];
 *(uint32_t*)input.contents=0x12345678;*(uint32_t*)next.contents=0xface0000;memset(output.contents,0xcd,256);
 [args setArgumentBuffer:table offset:0];[args setBuffer:input offset:0 atIndex:0];
 id<MTLCommandQueue> queue=[device newCommandQueue];
 MVKLiveList list;
 uint64_t initialLookups=0, duplicateLookups=0, skips=0;bool crossObserved=false,negativeObserved=false;
 struct Bench {double ms;uint64_t lookups=0,hits=0;};Bench benches[4];
 for(unsigned mode=0;mode<4;++mode) {
  fprintf(stderr,"stage=bench-%u\n",mode);
  MVKUseResourceHelper h;h.descriptorSnapshotReuse=(mode&1);h.negativeLiveCache=(mode&2);h.crossEncoderSnapshotReuse=h.crossEncoderSnapshotReuse&&h.descriptorSnapshotReuse;
  auto stale=std::make_shared<MVKDescriptorUseCache::Resources>();
  for(uintptr_t i=1;i<=4096;++i)stale->push_back((id<MTLResource>)(0x100000+i*64));
  MVKLiveList empty;
  auto start=std::chrono::steady_clock::now();
  for(unsigned encoder=0;encoder<32;++encoder) {
   h.resetForEncoder();
   for(unsigned rebind=0;rebind<16;++rebind)h.addLiveSnapshot(stale,empty,nil,immediate,MVKResourceUsageStages::Compute,false);
   benches[mode].lookups+=h.statsLookups;benches[mode].hits+=h.statsAbsentHits;
  }
  benches[mode].ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
 }

 {
  fprintf(stderr,"stage=gpu-helper\n");
  MVKUseResourceHelper helper;crossObserved=helper.crossEncoderSnapshotReuse;negativeObserved=helper.negativeLiveCache;
  auto values=std::make_shared<MVKDescriptorUseCache::Resources>();
  for(uintptr_t i=1;i<=4096;++i)values->push_back((id<MTLResource>)(0x100000+i*64));
  values->push_back(input);values->push_back(next);
  MVKDescriptorUseCache::Snapshot snapshot=values;
  for(uint32_t pass=0;pass<4;++pass) {
   fprintf(stderr,"stage=gpu-pass-%u\n",pass);
   id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> enc=[cb computeCommandEncoder];helper.resetForEncoder();
   if(!pass) {
    helper.addLiveSnapshot(snapshot,list,enc,immediate,MVKResourceUsageStages::Compute,false);
    initialLookups=helper.statsLookups;
    helper.addLiveSnapshot(snapshot,list,enc,immediate,MVKResourceUsageStages::Compute,false);
    duplicateLookups=helper.statsLookups;
    need(helper.used.find(input)==helper.used.end(),"unregistered resource was declared");
    list.add(input);
    helper.addLiveSnapshot(snapshot,list,enc,immediate,MVKResourceUsageStages::Compute,false);
    need(helper.used.find(input)!=helper.used.end()&&helper.used.find(input)->second.liveRetained,"registration did not invalidate absence");
   }
   if(pass==2) {list.add(next);[args setBuffer:next offset:0 atIndex:0];}
   helper.addLiveSnapshot(snapshot,list,enc,immediate,MVKResourceUsageStages::Compute,true);
   id<MTLBuffer> active=pass<2?input:next;
   need(helper.used.find(active)!=helper.used.end()&&helper.used.find(active)->second.generation==helper.encoderGeneration,"new encoder missed resource declaration");
   need(helper.used.find(active)->second.write,"write upgrade missing");
   auto before=helper.statsCalls;
   helper.addLiveSnapshot(snapshot,list,enc,immediate,MVKResourceUsageStages::Compute,true);
   if(helper.descriptorSnapshotReuse)need(before==helper.statsCalls,"identical snapshot was rescanned");
   helper.bindAndResetCompute(enc);
   [enc setComputePipelineState:pipeline];[enc setBuffer:table offset:0 atIndex:0];[enc setBuffer:output offset:0 atIndex:1];[enc setBytes:&pass length:4 atIndex:2];
   [enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"GPU command failed");
  }
  skips=helper.statsSnapshotSkips;
  list.remove(input);list.remove(next);
 }
 uint32_t expected[]={0x12345678,0x12345679,0xface0000,0xface0001};uint64_t mismatch=0;
 for(int i=0;i<4;++i)if(((uint32_t*)output.contents)[i]!=expected[i])++mismatch;
 if(*(uint32_t*)input.contents!=0x1234567a||*(uint32_t*)next.contents!=0xface0002)++mismatch;
 std::ofstream out(argv[1]);out<<"{\"passed\":"<<(mismatch?"false":"true")<<",\"GPUWordsChecked\":6,\"mismatches\":"<<mismatch<<",\"absentIdentities\":4096,\"initialLookups\":"<<initialLookups<<",\"lookupsAfterDuplicate\":"<<duplicateLookups<<",\"crossEncoderSnapshotReuse\":"<<(crossObserved?"true":"false")<<",\"negativeLiveCache\":"<<(negativeObserved?"true":"false")<<",\"lastEncoderSnapshotSkips\":"<<skips<<",\"CPUControls\":[";
 for(unsigned i=0;i<4;++i) {if(i)out<<",";out<<"{\"snapshotReuse\":"<<(i&1?"true":"false")<<",\"negativeCache\":"<<(i&2?"true":"false")<<",\"CPUms\":"<<benches[i].ms<<",\"liveLookups\":"<<benches[i].lookups<<",\"absenceHits\":"<<benches[i].hits<<"}";}
 out<<"]}\n";
 printf("RESOURCE_EPOCH_GPU mismatches=%llu initialLookups=%llu duplicateLookups=%llu\n",(unsigned long long)mismatch,(unsigned long long)initialLookups,(unsigned long long)duplicateLookups);
 [queue release];[table release];[output release];[next release];[input release];[args release];[pipeline release];[fn release];[library release];[device release];return mismatch?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}
}}
