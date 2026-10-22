// Owned parameter-buffer oracle for the native open-source converter.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdint>
#include <cstring>
struct Params {uint64_t indexBuffer;uint32_t indexed,indexSize,vertsPerPrim,topology,strides[31],divisors[31];};
struct Info {int32_t indexed,indexSize;uint64_t indexBuffer;int32_t baseVertex;uint32_t baseInstance,strides[31],divisors[31];uint8_t topology;uint32_t primitiveBase,primitiveCount,instanceBase;};
static_assert(sizeof(Info)==288 && sizeof(Params)==272);
int main(int argc,const char**argv){@autoreleasepool{
 if(argc!=3)return 2;NSError*error=nil;NSString*header=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
 NSRange structs=[header rangeOfString:@"typedef struct {\n\tuint64_t indexBuffer;"];
 NSRange structsEnd=[header rangeOfString:@"} MVKGeometryDrawInfo;" options:0 range:NSMakeRange(structs.location,header.length-structs.location)];
 NSRange kernel=[header rangeOfString:@"kernel void cmdDrawIndirectGeometryConvertBuffers("];
 NSRange kernelEnd=[header rangeOfString:@"kernel void cmdDrawIndirectConvertBuffers(" options:0 range:NSMakeRange(kernel.location,header.length-kernel.location)];
 NSString*source=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n%@",[header substringWithRange:NSMakeRange(structs.location,NSMaxRange(structsEnd)-structs.location)],[header substringWithRange:NSMakeRange(kernel.location,kernelEnd.location-kernel.location)]];
 id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name isEqualToString:@"AMD Radeon Pro 5600M"])d=x;if(!d)return 3;
 id<MTLLibrary>lib=[d newLibraryWithSource:source options:nil error:&error];id<MTLFunction>f=[lib newFunctionWithName:@"cmdDrawIndirectGeometryConvertBuffers"];id<MTLComputePipelineState>ps=[d newComputePipelineStateWithFunction:f error:&error];if(!ps){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 4;}
 auto buffer=[&](NSUInteger n){return [d newBufferWithLength:n options:MTLResourceStorageModeShared];};
 id<MTLBuffer>src=buffer(60),dst=buffer(256+3*sizeof(Info));uint32_t*args=(uint32_t*)src.contents;
 for(unsigned i=0;i<3;++i){uint32_t a[]={i==0?3093u:1033u,3,4,uint32_t(-2),5};memcpy(args+i*5,a,20);}memset(dst.contents,0xcd,dst.length);
 Params p={};p.indexBuffer=0x1234567800;p.indexed=1;p.indexSize=4;p.vertsPerPrim=3;
 id<MTLCommandQueue>q=[d newCommandQueue];id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];[e setComputePipelineState:ps];
 uint32_t stride=20,count=1,infoStride=sizeof(Info);
 for(unsigned i=0;i<3;++i){p.topology=i;[e setBuffer:src offset:i*20 atIndex:0];[e setBuffer:dst offset:i*12 atIndex:1];[e setBuffer:dst offset:256+i*sizeof(Info) atIndex:2];[e setBytes:&stride length:4 atIndex:3];[e setBytes:&count length:4 atIndex:4];[e setBytes:&p length:sizeof(p) atIndex:5];[e setBytes:&infoStride length:4 atIndex:6];[e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(ps.threadExecutionWidth,1,1)];}
 [e endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted)return 5;
 NSMutableArray*rows=[NSMutableArray array];bool passed=true;
 for(unsigned i=0;i<3;++i){auto dims=(uint32_t*)dst.contents+i*3;auto info=(Info*)((uint8_t*)dst.contents+256+i*sizeof(Info));bool ok=dims[0]==1031&&dims[1]==3&&dims[2]==1&&info->primitiveCount==1031&&info->baseVertex==-2&&info->baseInstance==5&&info->indexBuffer==p.indexBuffer+16&&info->primitiveBase==0&&info->instanceBase==0;passed&=ok;[rows addObject:@{@"topology":@(i),@"grid":@[@(dims[0]),@(dims[1]),@(dims[2])],@"primitiveCount":@(info->primitiveCount),@"baseVertex":@(info->baseVertex),@"firstInstance":@(info->baseInstance),@"passed":@(ok)}];}
 NSData*out=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(passed),@"cases":rows,@"device":d.name} options:NSJSONWritingPrettyPrinted error:&error];[out writeToFile:@(argv[2]) atomically:YES];return passed?0:6;
}}
