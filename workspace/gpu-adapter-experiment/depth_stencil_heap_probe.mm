#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstring>

// Owned reproduction of the observed game's 1x1 format260/usage0x15
// descriptor. Exercise creation AND the public heap size query separately.
int main(){@autoreleasepool{
  id<MTLDevice> device=nil;
  for(id<MTLDevice> d in MTLCopyAllDevices())if([d.name containsString:@"AMD"])device=d;
  if(!device)return 2;
  NSError *error=nil;
  NSString *source=@"#include <metal_stdlib>\nusing namespace metal;struct Out{float depth;uint stencil;};kernel void readBoth(depth2d<float,access::read> d[[texture(0)]],texture2d<uint,access::read> s[[texture(1)]],device Out* o[[buffer(0)]],uint2 p[[thread_position_in_grid]]){o[0].depth=d.read(p);o[0].stencil=s.read(p).r;}";
  id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];
  id<MTLComputePipelineState> pipeline=lib?[device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readBoth"] error:&error]:nil;
  if(!pipeline){fprintf(stderr,"Shader failed: %s\n",error.localizedDescription.UTF8String);return 3;}
  bool all=true;
  for(unsigned mode=0;mode<2;mode++){
    MTLTextureDescriptor *requested=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:1 height:1 mipmapped:NO];
    requested.storageMode=mode?MTLStorageModeManaged:MTLStorageModeShared;
    requested.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture=[device newTextureWithDescriptor:requested];
    if(!texture||texture.storageMode!=MTLStorageModePrivate)return 4;
    fprintf(stderr,"HEAP_QUERY before originalDescriptor requestedMode=%u actualTextureMode=%lu format=%lu usage=0x%lx\n",mode,(unsigned long)texture.storageMode,(unsigned long)requested.pixelFormat,(unsigned long)requested.usage);
    MTLSizeAndAlign size=[device heapTextureSizeAndAlignWithDescriptor:requested];
    fprintf(stderr,"HEAP_QUERY returned size=%lu align=%lu\n",(unsigned long)size.size,(unsigned long)size.align);
    if(!size.size||!size.align)return 5;
    id<MTLTexture> stencil=[texture newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
    if(!stencil)return 6;
    id<MTLBuffer> output=[device newBufferWithLength:8 options:MTLResourceStorageModeManaged];
    memset(output.contents,0,8);[output didModifyRange:NSMakeRange(0,8)];
    id<MTLCommandBuffer> cb=[[device newCommandQueue]commandBuffer];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture=texture;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=mode?0.75:0.25;
    pass.stencilAttachment.texture=texture;pass.stencilAttachment.loadAction=MTLLoadActionClear;pass.stencilAttachment.storeAction=MTLStoreActionStore;pass.stencilAttachment.clearStencil=mode?173:37;
    id<MTLRenderCommandEncoder> render=[cb renderCommandEncoderWithDescriptor:pass];[render endEncoding];
    id<MTLComputeCommandEncoder> compute=[cb computeCommandEncoder];
    [compute setComputePipelineState:pipeline];[compute setTexture:texture atIndex:0];[compute setTexture:stencil atIndex:1];[compute setBuffer:output offset:0 atIndex:0];
    [compute dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[compute endEncoding];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];[blit synchronizeResource:output];[blit endEncoding];
    [cb commit];[cb waitUntilCompleted];
    struct Values{float depth;unsigned stencil;};Values v=*(Values*)output.contents;
    bool passResult=cb.status==MTLCommandBufferStatusCompleted&&v.depth==(mode?0.75f:0.25f)&&v.stencil==(mode?173u:37u);
    all=all&&passResult;
    printf("DEPTH_STENCIL requestedMode=%u actualPrivate depth=%g stencil=%u commandStatus=%lu result=%s error=%s\n",mode,v.depth,v.stencil,(unsigned long)cb.status,passResult?"PASS":"FAIL",cb.error.localizedDescription.UTF8String?:"");
  }
  printf("SCOPE own 1x1 combined depth-stencil/view/heap-size-query real GPU readback only; not game conformance or CPU Map\n");
  return all?0:1;
}}
