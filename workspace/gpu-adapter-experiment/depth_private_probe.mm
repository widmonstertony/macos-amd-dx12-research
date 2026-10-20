#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstring>
#import "texture_storage_adapter.h"
int main(){@autoreleasepool{
  id<MTLDevice> d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"AMD"])d=x;if(!d)return 2;
  NSError *error=nil;
  NSString *code=@"#include <metal_stdlib>\nusing namespace metal;kernel void sampleDepth(depth2d<float,access::read> t[[texture(0)]],device float *o[[buffer(0)]],uint2 p[[thread_position_in_grid]]){o[p.y*16+p.x]=t.read(p);}";
  id<MTLLibrary> lib=[d newLibraryWithSource:code options:nil error:&error];
  id<MTLComputePipelineState> pso=lib?[d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sampleDepth"] error:&error]:nil;
  if(!pso){fprintf(stderr,"Depth shader: %s\n",error.localizedDescription.UTF8String);return 3;}
  bool all=true;
  for(unsigned mode=0;mode<2;mode++){
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
    td.storageMode=mode?MTLStorageModeManaged:MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    // Directly exercise the identical owned descriptor policy on the genuine
    // device, without needing the classification-gate proxy for this unit test.
#ifdef OWN_PROBE_USE_DEVICE_PROXY
    // Integration control: the separately injected adapter must apply the
    // same policy through its actual public device proxy, as in the game.
    id<MTLTexture> depth=[d newTextureWithDescriptor:td];
#else
    MTLTextureDescriptor *prepared=TSPrepareDeviceTextureDescriptor(d,td);
    id<MTLTexture> depth=[d newTextureWithDescriptor:prepared];TSRegisterConvertedTexture(depth,td);
#endif
    if(!depth||depth.storageMode!=MTLStorageModePrivate){fprintf(stderr,"Depth fallback not private\n");return 4;}
    id<MTLBuffer> out=[d newBufferWithLength:1024 options:MTLResourceStorageModeManaged];memset(out.contents,0,out.length);[out didModifyRange:NSMakeRange(0,out.length)];
    id<MTLCommandBuffer> cb=[[d newCommandQueue]commandBuffer];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=mode?0.75:0.25;
    id<MTLRenderCommandEncoder> r=[cb renderCommandEncoderWithDescriptor:pass];[r endEncoding];
    id<MTLComputeCommandEncoder> c=[cb computeCommandEncoder];[c setComputePipelineState:pso];[c setTexture:depth atIndex:0];[c setBuffer:out offset:0 atIndex:0];[c dispatchThreadgroups:MTLSizeMake(2,2,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[c endEncoding];
    id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];[b synchronizeResource:out];[b endEncoding];[cb commit];[cb waitUntilCompleted];
    unsigned mismatch=0;float *v=(float*)out.contents;for(unsigned i=0;i<256;i++)if(v[i]!=(mode?0.75f:0.25f))mismatch++;
    bool passed=cb.status==MTLCommandBufferStatusCompleted&&!mismatch;all=all&&passed;
    printf("DEPTH_PRIVATE requested=%s actualMode=%lu clearedAndReadPixels=256 mismatches=%u commandStatus=%lu result=%s error=%s\n",mode?"Managed":"Shared",(unsigned long)depth.storageMode,mismatch,(unsigned long)cb.status,passed?"PASS":"FAIL",cb.error.localizedDescription.UTF8String?:"");
  }
  printf("DEPTH_PRIVATE scope=owned actual depth clear+GPU shader read+managed buffer readback; not stencil/CPU Map/game conformance\n");return all?0:1;
}}
