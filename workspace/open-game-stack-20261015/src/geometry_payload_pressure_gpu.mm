// Owned converted-shader control: matched compact versus fixed-size payloads.
// Inputs are generated from the owned Vulkan oracle, not a game capture.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
int main(int argc,const char**argv){@autoreleasepool{
 if(argc<4 || argc>8)return 2;NSError*err=nil;id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name isEqualToString:@"AMD Radeon Pro 5600M"])d=x;if(!d)return 3;

 const unsigned payloadBytes=argc>=5?unsigned(strtoul(argv[4],nullptr,10)):0; if(payloadBytes>16384)return 10;
 const unsigned objectThreads=argc>=6?unsigned(strtoul(argv[5],nullptr,10)):1;
 const unsigned meshThreads=argc>=7?unsigned(strtoul(argv[6],nullptr,10)):1;
 auto validThreads=[](unsigned n){return n==1||n==32||n==64;};if(!validThreads(objectThreads)||!validThreads(meshThreads))return 11;
 const bool shaderBounds=argc>=8 && strtoul(argv[7],nullptr,10)==1;
 const unsigned slots=unsigned(strtoul(argv[2],nullptr,10));if(slots!=1&&slots!=32)return 8;
 const char* files[]={"shader-vs-c445f9cfe4f15fef.metal","shader-gs-9f2b074ce2181182.metal","shader-fs-6fac72f34abb099c.metal"};
 const char* names[]={"mvk_mesh_724564715ec25dab_0","mvk_mesh_7ae6cae994a2cef6_3","mvk_mesh_b3ce58dac264c8e6_4"};
 id<MTLFunction> functions[3];
 for(unsigned i=0;i<3;++i){NSString*src=[NSString stringWithContentsOfFile:[@(argv[1]) stringByAppendingPathComponent:@(files[i])] encoding:NSUTF8StringEncoding error:&err];if(!src)return 9;
 if(slots==1)src=[src stringByReplacingOccurrencesOfString:@"uint4 locations[32]" withString:@"uint4 locations[1]"];
 if(i==0 && objectThreads>1){
 src=[src stringByReplacingOccurrencesOfString:@"uint3 positionInGrid [[thread_position_in_grid]]," withString:@"uint3 positionInGrid [[threadgroup_position_in_grid]], uint ownedLane [[thread_index_in_threadgroup]],"];
 src=[src stringByReplacingOccurrencesOfString:@"{\n    uint primitiveIndex" withString:@"{\n    if(ownedLane != 0) return;\n    uint primitiveIndex"];
 }
 if(i==1 && meshThreads>1)src=[src stringByReplacingOccurrencesOfString:@"{\n    main0_in in;" withString:@"{\n    if(lid != 0) return;\n    main0_in in;"];
 if(shaderBounds && i==0)src=[src stringByReplacingOccurrencesOfString:@"[[object]]" withString:[NSString stringWithFormat:@"[[object, max_total_threads_per_threadgroup(%u), max_total_threadgroups_per_mesh_grid(1)]]",objectThreads]];
 if(shaderBounds && i==1)src=[src stringByReplacingOccurrencesOfString:@"[[mesh]]" withString:[NSString stringWithFormat:@"[[mesh, max_total_threads_per_threadgroup(%u)]]",meshThreads]];
 MTLCompileOptions*options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion3_0;options.mathMode=MTLMathModeSafe;
 id<MTLLibrary>l=[d newLibraryWithSource:src options:options error:&err];functions[i]=[l newFunctionWithName:@(names[i])];if(!functions[i]){fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 4;}}
 MTLMeshRenderPipelineDescriptor*p=[MTLMeshRenderPipelineDescriptor new];p.objectFunction=functions[0];p.meshFunction=functions[1];p.fragmentFunction=functions[2];p.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Uint;p.payloadMemoryLength=payloadBytes;p.maxTotalThreadgroupsPerMeshGrid=1;p.maxTotalThreadsPerObjectThreadgroup=objectThreads;p.maxTotalThreadsPerMeshThreadgroup=meshThreads;
 id<MTLRenderPipelineState>ps=[d newRenderPipelineStateWithMeshDescriptor:p options:MTLPipelineOptionNone reflection:nil error:&err];if(!ps){fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 5;}
 struct DrawInfo {int32_t indexed,indexSize;uint64_t indexBuffer;int32_t baseVertex;uint32_t baseInstance,strides[31],divisors[31];uint8_t topology;uint32_t primitiveBase,primitiveCount,instanceBase;};static_assert(sizeof(DrawInfo)==288);
 DrawInfo info={};info.baseVertex=7;info.baseInstance=5;info.primitiveCount=1031;uint32_t params[]={1031,5};
 MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:1031 height:3 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture>t=[d newTextureWithDescriptor:td];
 constexpr unsigned pitch=16640;id<MTLBuffer>b=[d newBufferWithLength:pitch*3 options:MTLResourceStorageModeShared],args=[d newBufferWithLength:12 options:MTLResourceStorageModeShared];uint32_t dimensions[]={1031,3,1};memcpy(args.contents,dimensions,12);
 id<MTLCommandQueue>q=[d newCommandQueue];NSMutableArray*rows=[NSMutableArray array];unsigned total=0;
 for(unsigned indirect=0;indirect<2;++indirect){MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=t;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:rp];[e setRenderPipelineState:ps];[e setCullMode:MTLCullModeNone];[e setObjectBytes:&info length:sizeof(info) atIndex:27];[e setMeshBytes:params length:sizeof(params) atIndex:0];
 if(indirect)[e drawMeshThreadgroupsWithIndirectBuffer:args indirectBufferOffset:0 threadsPerObjectThreadgroup:MTLSizeMake(objectThreads,1,1) threadsPerMeshThreadgroup:MTLSizeMake(meshThreads,1,1)];else [e drawMeshThreadgroups:MTLSizeMake(1031,3,1) threadsPerObjectThreadgroup:MTLSizeMake(objectThreads,1,1) threadsPerMeshThreadgroup:MTLSizeMake(meshThreads,1,1)];[e endEncoding];id<MTLBlitCommandEncoder>blit=[cb blitCommandEncoder];[blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1031,3,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch*3];[blit endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted){NSDictionary*failure=@{@"passed":@NO,@"failedModeIndirect":@(indirect),@"error":cb.error.localizedDescription?:@"",@"errorCode":@(cb.error.code),@"cases":rows};NSData*data=[NSJSONSerialization dataWithJSONObject:failure options:NSJSONWritingPrettyPrinted error:&err];[data writeToFile:@(argv[3]) atomically:YES];fprintf(stderr,"GPU error: %s\n",cb.error.localizedDescription.UTF8String);return 6;}
 unsigned bad=0;for(unsigned y=0;y<3;++y)for(unsigned x=0;x<1031;++x){uint32_t*v=(uint32_t*)((uint8_t*)b.contents+y*pitch+x*16);uint32_t expected[]={(3*x+7)+7*(3*x+8)+49*(3*x+9),x+1,y+6,0x531b};for(unsigned c=0;c<4;++c)if(v[c]!=expected[c]){if(bad<3)fprintf(stderr,"mode=%u x=%u y=%u c=%u actual=%u expected=%u\n",indirect,x,y,c,v[c],expected[c]);++bad;}}
 total+=bad;[rows addObject:@{@"indirect":@(indirect),@"mismatches":@(bad),@"GPUSeconds":@(cb.GPUEndTime-cb.GPUStartTime)}];}
 NSData*data=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(total==0),@"payloadLocations":@(slots),@"shaderBounds":@(shaderBounds),@"payloadBytes":@(payloadBytes),@"objectThreads":@(objectThreads),@"meshThreads":@(meshThreads),@"objectExecutionWidth":@(ps.objectThreadExecutionWidth),@"meshExecutionWidth":@(ps.meshThreadExecutionWidth),@"checkedComponents":@24744,@"cases":rows,@"device":d.name} options:NSJSONWritingPrettyPrinted error:&err];[data writeToFile:@(argv[3]) atomically:YES];return total?7:0;
}}
