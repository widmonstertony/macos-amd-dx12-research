#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>

// Fixed owned workload: registered but unbound live allocations plus many
// separate encoders, retaining the adapter's conservative resource coverage.
// CPU encode time is measured; this is not the game's FPS or a GPU benchmark.
int main(){@autoreleasepool{
  id<MTLDevice> device=nil;
  for(id<MTLDevice> d in MTLCopyAllDevices())if([d.name containsString:@"AMD"])device=d;
  if(!device)return 2;
  NSError *error=nil;
  NSString *source=@"#include <metal_stdlib>\nusing namespace metal;kernel void stamp(device uint* out[[buffer(0)]],uint tid[[thread_position_in_grid]]){out[tid]=tid*7+11;}";
  id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
  id<MTLComputePipelineState> pipeline=library?[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"stamp"] error:&error]:nil;
  if(!pipeline){fprintf(stderr,"Shader: %s\n",error.localizedDescription.UTF8String);return 3;}
  unsigned dummyCount=2048;
  if(const char *n=getenv("GPU_ADAPTER_COST_BUFFERS")){dummyCount=(unsigned)strtoul(n,nullptr,10);if(!dummyCount||dummyCount>20000)return 8;}
  bool churn=getenv("GPU_ADAPTER_COST_CHURN")&&strcmp(getenv("GPU_ADAPTER_COST_CHURN"),"0");
  NSMutableArray *live=[NSMutableArray array];
  for(unsigned i=0;i<dummyCount;i++){
    id<MTLBuffer> b=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    if(!b)return 4;[live addObject:b];
  }
  id<MTLBuffer> output=[device newBufferWithLength:256 options:MTLResourceStorageModeManaged];
  id<MTLCommandQueue> queue=[device newCommandQueue];
  bool all=true;
  for(unsigned iteration=0;iteration<4;iteration++){
    @autoreleasepool{
      memset(output.contents,0,256);[output didModifyRange:NSMakeRange(0,256)];
      auto begin=std::chrono::steady_clock::now();
      id<MTLCommandBuffer> cb=[queue commandBufferWithUnretainedReferences];
      for(unsigned e=0;e<32;e++){
        if(churn){id<MTLBuffer> added=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];if(!added)return 9;[live addObject:added];}

        id<MTLComputeCommandEncoder> encoder=[cb computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];[encoder setBuffer:output offset:0 atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[encoder endEncoding];
      }
      id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];[blit synchronizeResource:output];[blit endEncoding];
      [cb commit];
      auto encoded=std::chrono::steady_clock::now();
      [cb waitUntilCompleted];
      unsigned mismatches=0;for(unsigned i=0;i<64;i++)if(((unsigned*)output.contents)[i]!=i*7+11)mismatches++;
      bool ok=cb.status==MTLCommandBufferStatusCompleted&&!mismatches;all=all&&ok;
      double ms=std::chrono::duration<double,std::milli>(encoded-begin).count();
      printf("RESIDENCY_COST iteration=%u warmup=%u liveDummyBuffers=%u churn=%u encoders=32 cpuEncodeMs=%.3f wordsChecked=64 mismatches=%u commandStatus=%lu result=%s\n",iteration,iteration==0,dummyCount,churn,ms,mismatches,(unsigned long)cb.status,ok?"PASS":"FAIL");
    }
  }
  printf("SCOPE fixed owned conservative-residency CPU workload; not measured game FPS; liveBuffers=%lu\n",(unsigned long)live.count);
  auto stats=(NSDictionary*(*)(id<MTLDevice>))dlsym(RTLD_DEFAULT,"SRSoftwareResidencyStatistics");
  if(stats){NSData *json=[NSJSONSerialization dataWithJSONObject:stats(device) options:0 error:nil];printf("RESIDENCY_STATS %.*s\n",(int)json.length,(const char*)json.bytes);}
  return all?0:1;
}}
