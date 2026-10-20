#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>
#include <initializer_list>
int main(){@autoreleasepool{
 id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name isEqualToString:@"AMD Radeon Pro 5600M"])d=x;if(!d)return 2;
 NSMutableArray*results=[NSMutableArray array];unsigned failures=0;
 for(unsigned loc: {0u,3u})for(unsigned layered: {0u,1u}){
  NSString*source=[NSString stringWithFormat:@"#include <metal_stdlib>\n#include <metal_mesh>\nusing namespace metal;struct V{float4 p[[position]];float4 c[[user(locn%u)]];};struct P{%s};using M=metal::mesh<V,P,3,1,topology::triangle>;[[mesh]] void m(M out){float2 xy[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};for(uint i=0;i<3;i++){V v;v.p=float4(xy[i],0,1);v.c=float4(.25,.5,.75,1);out.set_vertex(i,v);out.set_index(i,i);}P p={};%s out.set_primitive(0,p);out.set_primitive_count(1);}fragment float4 f(V in[[stage_in]]){return in.c;}",loc,layered?"uint layer[[render_target_array_index]];":"",layered?"p.layer=0;":""];
  NSError*error=nil;MTLCompileOptions*o=[MTLCompileOptions new];o.languageVersion=MTLLanguageVersion4_0;o.mathMode=MTLMathModeSafe;
  id<MTLLibrary>l=[d newLibraryWithSource:source options:o error:&error];
  if(!l){[results addObject:@{@"location":@(loc),@"layered":@(layered),@"phase":@"library",@"error":error.localizedDescription?:@""}];failures++;continue;}
  MTLMeshRenderPipelineDescriptor*pd=[MTLMeshRenderPipelineDescriptor new];pd.meshFunction=[l newFunctionWithName:@"m"];pd.fragmentFunction=[l newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;pd.maxTotalThreadsPerMeshThreadgroup=1;
  id<MTLRenderPipelineState>ps=[d newRenderPipelineStateWithMeshDescriptor:pd options:MTLPipelineOptionNone reflection:nil error:&error];
  if(!ps){[results addObject:@{@"location":@(loc),@"layered":@(layered),@"phase":@"pipeline",@"error":error.localizedDescription?:@""}];failures++;continue;}
  MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.textureType=MTLTextureType2DArray;td.arrayLength=2;td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
  id<MTLTexture>target=[d newTextureWithDescriptor:td];id<MTLBuffer>read=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];memset(read.contents,0xa5,4096);
  MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=target;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);rp.renderTargetArrayLength=2;
  id<MTLCommandBuffer>cb=[[d newCommandQueue]commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:rp];[e setRenderPipelineState:ps];[e drawMeshThreadgroups:MTLSizeMake(1,1,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];
  id<MTLBlitCommandEncoder>b=[cb blitCommandEncoder];for(unsigned z=0;z<2;z++)[b copyFromTexture:target sourceSlice:z sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:read destinationOffset:z*2048 destinationBytesPerRow:256 destinationBytesPerImage:2048];[b endEncoding];[cb commit];[cb waitUntilCompleted];
  unsigned bad=0;unsigned char expected[2][4]={{64,128,191,255},{0,0,0,255}};for(unsigned z=0;z<2;z++)for(unsigned y=0;y<8;y++)for(unsigned x=0;x<8;x++)if(memcmp((char*)read.contents+z*2048+y*256+x*4,expected[z],4))bad++;
  if(cb.status!=MTLCommandBufferStatusCompleted)bad++;failures+=bad!=0;
  [results addObject:@{@"location":@(loc),@"layered":@(layered),@"phase":@"GPU-readback",@"pixelsChecked":@128,@"badPixels":@(bad),@"commandStatus":@(cb.status),@"error":cb.error.localizedDescription?:@""}];
 }
 NSDictionary*j=@{@"passed":@(failures==0),@"device":d.name,@"results":results,@"gameStarted":@NO};NSData*json=[NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");return failures?3:0;
}}
