// Owned Metal control: CPU-encoded mesh indirect-command-buffer execution.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
int main(int argc,const char**argv){@autoreleasepool{
 if(argc!=2)return 2;NSError*err=nil;id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name isEqualToString:@"AMD Radeon Pro 5600M"])d=x;if(!d)return 3;
 NSString*src=@R"(
#include <metal_stdlib>
#include <metal_mesh>
using namespace metal;
struct P {uint2 xy;};
struct V {float4 pos [[position]];uint4 value [[flat]];};
[[object]] void obj(object_data P& p [[payload]],mesh_grid_properties grid,uint3 id [[thread_position_in_grid]]){p.xy=id.xy;grid.set_threadgroups_per_grid(uint3(1));}
[[mesh]] void meshMain(metal::mesh<V,void,4,2,topology::triangle> out,const object_data P&p [[payload]]){
 float2 lo=float2(p.xy)/float2(64,3)*2-1,hi=float2(p.xy+1)/float2(64,3)*2-1;
 float2 v[4]={lo,float2(hi.x,lo.y),float2(lo.x,hi.y),hi};
 for(uint i=0;i<4;++i){V x;x.pos=float4(v[i],.5,1);x.value=uint4(p.xy+1,0x531b,1);out.set_vertex(i,x);}uint ix[6]={0,1,2,2,1,3};for(uint i=0;i<6;++i)out.set_index(i,ix[i]);out.set_primitive_count(2);
}
fragment uint4 frag(V v [[stage_in]]){return v.value;}
)";
 id<MTLLibrary>l=[d newLibraryWithSource:src options:nil error:&err];if(!l){fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 4;}
 MTLMeshRenderPipelineDescriptor*p=[MTLMeshRenderPipelineDescriptor new];p.objectFunction=[l newFunctionWithName:@"obj"];p.meshFunction=[l newFunctionWithName:@"meshMain"];p.fragmentFunction=[l newFunctionWithName:@"frag"];p.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Uint;p.supportIndirectCommandBuffers=YES;p.maxTotalThreadgroupsPerMeshGrid=1;p.maxTotalThreadsPerObjectThreadgroup=1;p.maxTotalThreadsPerMeshThreadgroup=1;
 id<MTLRenderPipelineState>ps=[d newRenderPipelineStateWithMeshDescriptor:p options:MTLPipelineOptionNone reflection:nil error:&err];if(!ps){NSDictionary*row=@{@"passed":@NO,@"pipelineRejected":@YES,@"error":err.localizedDescription?:@""};[[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingPrettyPrinted error:nil] writeToFile:@(argv[1]) atomically:YES];fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 5;}
 MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:64 height:3 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture>t=[d newTextureWithDescriptor:td];
 constexpr unsigned pitch=1024;id<MTLBuffer>b=[d newBufferWithLength:pitch*3 options:MTLResourceStorageModeShared],args=[d newBufferWithLength:12 options:MTLResourceStorageModeShared];uint32_t dimensions[]={64,3,1};memcpy(args.contents,dimensions,12);
 id<MTLCommandQueue>q=[d newCommandQueue];NSMutableArray*rows=[NSMutableArray array];unsigned total=0;
 MTLIndirectCommandBufferDescriptor*icd=[MTLIndirectCommandBufferDescriptor new];icd.commandTypes=MTLIndirectCommandTypeDrawMeshThreadgroups;icd.inheritPipelineState=YES;icd.inheritBuffers=YES;
 id<MTLIndirectCommandBuffer>icb=[d newIndirectCommandBufferWithDescriptor:icd maxCommandCount:1 options:MTLResourceStorageModeShared];
 if(!icb){NSDictionary*row=@{@"passed":@NO,@"indirectCommandBufferUnavailable":@YES};[[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingPrettyPrinted error:nil] writeToFile:@(argv[1]) atomically:YES];return 8;}
 [[icb indirectRenderCommandAtIndex:0] drawMeshThreadgroups:MTLSizeMake(64,3,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];
 for(unsigned indirect=0;indirect<3;++indirect){MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=t;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:rp];[e setRenderPipelineState:ps];[e setCullMode:MTLCullModeNone];
 if(indirect==2)[e executeCommandsInBuffer:icb withRange:NSMakeRange(0,1)];else if(indirect)[e drawMeshThreadgroupsWithIndirectBuffer:args indirectBufferOffset:0 threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];else [e drawMeshThreadgroups:MTLSizeMake(64,3,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];id<MTLBlitCommandEncoder>blit=[cb blitCommandEncoder];[blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,3,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch*3];[blit endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted){NSDictionary*failure=@{@"passed":@NO,@"failedModeIndirect":@(indirect),@"error":cb.error.localizedDescription?:@"",@"errorCode":@(cb.error.code),@"cases":rows};NSData*data=[NSJSONSerialization dataWithJSONObject:failure options:NSJSONWritingPrettyPrinted error:&err];[data writeToFile:@(argv[1]) atomically:YES];fprintf(stderr,"GPU error: %s\n",cb.error.localizedDescription.UTF8String);return 6;}
 unsigned bad=0;for(unsigned y=0;y<3;++y)for(unsigned x=0;x<64;++x){uint32_t*v=(uint32_t*)((uint8_t*)b.contents+y*pitch+x*16);uint32_t expected[]={x+1,3-y,0x531b,1};for(unsigned c=0;c<4;++c)if(v[c]!=expected[c]){if(bad<3)fprintf(stderr,"mode=%u x=%u y=%u c=%u actual=%u expected=%u\n",indirect,x,y,c,v[c],expected[c]);++bad;}}
 total+=bad;[rows addObject:@{@"mode":@(indirect),@"mismatches":@(bad),@"GPUSeconds":@(cb.GPUEndTime-cb.GPUStartTime)}];}
 NSData*data=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(total==0),@"checkedComponents":@2304,@"cases":rows,@"device":d.name} options:NSJSONWritingPrettyPrinted error:&err];[data writeToFile:@(argv[1]) atomically:YES];return total?7:0;
}}
