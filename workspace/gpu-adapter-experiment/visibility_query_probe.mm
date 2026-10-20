#import "software_residency_adapter.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <signal.h>
#include <unistd.h>
static void timedOut(int){_exit(124);}
int main(int argc,char **argv){@autoreleasepool{
 signal(SIGALRM,timedOut);alarm(45);
 id<MTLDevice> native=nil;for(id<MTLDevice>d in MTLCopyAllDevices())if([d.name containsString:@"AMD"])native=d;if(!native)return 2;
 bool wrapped=argc>1&&!strcmp(argv[1],"wrapped");id<MTLDevice>d=wrapped?SRWrapMetalDeviceForSoftwareResidency(native):native;
 unsigned liveCount=getenv("GPU_VIS_LIVE_BUFFERS")?(unsigned)strtoul(getenv("GPU_VIS_LIVE_BUFFERS"),nullptr,10):0;if(liveCount>20000)return 7;
 bool noResult=getenv("GPU_VIS_NO_RESULT_BUFFER")!=nullptr,beforePipeline=getenv("GPU_VIS_BEFORE_PIPELINE")!=nullptr;
 bool nativeDeclare=getenv("GPU_VIS_NATIVE_DECLARATIONS")!=nullptr;NSMutableArray *live=[NSMutableArray array];for(unsigned i=0;i<liveCount;i++){id<MTLBuffer>b=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];if(!b)return 8;[live addObject:b];}
 NSError *error=nil;NSString *source=@"#include <metal_stdlib>\nusing namespace metal;vertex float4 v(uint i[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}fragment float4 f(){return float4(0.25,0.5,0.75,1);}";
 id<MTLLibrary>lib=[d newLibraryWithSource:source options:nil error:&error];MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=[lib newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
 id<MTLRenderPipelineState>pso=[d newRenderPipelineStateWithDescriptor:pd error:&error];if(!pso){fprintf(stderr,"Pipeline error %s\n",error.localizedDescription.UTF8String);return 3;}
 const unsigned queries=1024;const NSUInteger bytes=queries*8;
 auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
 id<MTLTexture>color=[d newTextureWithDescriptor:td];id<MTLCommandQueue>queue=[d newCommandQueue];bool all=true;
 for(unsigned heapMode=0;heapMode<2;heapMode++)for(unsigned accumulate=0;accumulate<2;accumulate++){
  @autoreleasepool{
   id<MTLHeap>heap=nil;id<MTLBuffer>results=nil;
   if(heapMode){auto hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;auto sz=[d heapBufferSizeAndAlignWithLength:bytes options:MTLResourceStorageModePrivate];hd.size=sz.size+sz.align;heap=[d newHeapWithDescriptor:hd];results=[heap newBufferWithLength:bytes options:MTLResourceStorageModePrivate];}
   else results=[d newBufferWithLength:bytes options:MTLResourceStorageModeShared];
   id<MTLBuffer>readback=[d newBufferWithLength:bytes options:MTLResourceStorageModeShared];if(!results||!readback)return 4;
   id<MTLCommandBuffer>cb=[queue commandBufferWithUnretainedReferences];id<MTLBlitCommandEncoder>b=[cb blitCommandEncoder];[b fillBuffer:results range:NSMakeRange(0,bytes) value:0];[b endEncoding];b=nil;
   unsigned passes=accumulate?2:1;
   for(unsigned passIndex=0;passIndex<passes;passIndex++){
    auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.visibilityResultBuffer=noResult?nil:results;pass.visibilityResultType=accumulate?MTLVisibilityResultTypeAccumulate:MTLVisibilityResultTypeReset;
    fprintf(stderr,"VISIBILITY beforeEncoder wrapped=%d heapPrivate=%u accumulate=%u pass=%u queries=%u bytes=%lu\n",wrapped,heapMode,accumulate,passIndex,queries,(unsigned long)results.length);fflush(stderr);
    id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:pass];if(beforePipeline)[e setVisibilityResultMode:noResult?MTLVisibilityResultModeDisabled:MTLVisibilityResultModeCounting offset:0];[e setRenderPipelineState:pso];[e setViewport:MTLViewport{0,0,8,8,0,1}];[e setCullMode:MTLCullModeNone];
    for(unsigned q=0;q<queries;q++){[e setVisibilityResultMode:noResult?MTLVisibilityResultModeDisabled:MTLVisibilityResultModeCounting offset:noResult?0:q*8];if(q==0&&nativeDeclare){if(heap)[e useHeap:heap];NSMutableArray *all=[live mutableCopy];[all addObject:results];[all addObject:readback];[all addObject:color];std::vector<id<MTLResource>> raw;for(id a in all)raw.push_back(a);[e useResources:raw.data() count:raw.size() usage:MTLResourceUsageRead|MTLResourceUsageWrite stages:MTLRenderStageVertex|MTLRenderStageFragment];}[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];}
    [e endEncoding];e=nil;
   }
   b=[cb blitCommandEncoder];[b copyFromBuffer:results sourceOffset:0 toBuffer:readback destinationOffset:0 size:bytes];[b endEncoding];b=nil;
   [cb commit];[cb waitUntilCompleted];unsigned mismatch=0;uint64_t expected=noResult?0:64*passes;for(unsigned i=0;i<queries;i++)if(((uint64_t*)readback.contents)[i]!=expected)mismatch++;
   bool ok=cb.status==MTLCommandBufferStatusCompleted&&!mismatch;all&=ok;
   printf("VISIBILITY wrapped=%d heapPrivate=%u accumulate=%u queries=%u expected=%llu actualFirst=%llu mismatches=%u commandStatus=%lu result=%s\n",wrapped,heapMode,accumulate,queries,(unsigned long long)expected,(unsigned long long)((uint64_t*)readback.contents)[0],mismatch,(unsigned long)cb.status,ok?"PASS":"FAIL");fflush(stdout);
  }
 }
 puts("SCOPE real occlusion query counts/encoder splits/accumulation GPU readback; native control vs own proxy; not game compatibility");return all?0:5;
}}
