// Owned parameter-buffer oracle for the native open-source converter.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdint>
#include <cstring>
#include <vector>
struct Params {uint64_t indexBuffer;uint32_t indexed,indexSize,vertsPerPrim,topology,batchCount,strides[31],divisors[31];};
struct Info {int32_t indexed,indexSize;uint64_t indexBuffer;int32_t baseVertex;uint32_t baseInstance,strides[31],divisors[31];uint8_t topology;uint32_t primitiveBase,primitiveCount,instanceBase;};
static_assert(sizeof(Info)==288 && sizeof(Params)==280);
int main(int argc,const char**argv){@autoreleasepool{
 if(argc!=3)return 2;NSError*error=nil;NSString*header=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
 NSRange structs=[header rangeOfString:@"typedef struct {\n\tuint64_t indexBuffer;"];
 NSRange structsEnd=[header rangeOfString:@"} MVKGeometryDrawInfo;" options:0 range:NSMakeRange(structs.location,header.length-structs.location)];
 NSRange kernel=[header rangeOfString:@"kernel void cmdDrawIndirectGeometryConvertBuffers("];
 NSRange kernelEnd=[header rangeOfString:@"kernel void cmdDrawIndirectConvertBuffers(" options:0 range:NSMakeRange(kernel.location,header.length-kernel.location)];
 NSString*source=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n%@",[header substringWithRange:NSMakeRange(structs.location,NSMaxRange(structsEnd)-structs.location)],[header substringWithRange:NSMakeRange(kernel.location,kernelEnd.location-kernel.location)]];
 id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name isEqualToString:@"AMD Radeon Pro 5600M"])d=x;if(!d)return 3;
 id<MTLLibrary>lib=[d newLibraryWithSource:source options:nil error:&error];id<MTLFunction>f=[lib newFunctionWithName:@"cmdDrawIndirectGeometryConvertBuffers"];id<MTLComputePipelineState>ps=[d newComputePipelineStateWithFunction:f error:&error];if(!ps){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 4;}

 struct Case {uint32_t primitives,instances,batches,topology;NSUInteger offset;};
 std::vector<Case> cases;NSUInteger bytes=0;
 for(uint32_t topology: {0u,1u,2u})for(uint32_t primitives:{0u,1u,2u,255u,256u,257u,1031u,20000u,1431655765u})for(uint32_t instances:{0u,1u,3u,70u,0xffffffffu})for(uint32_t batches:{1u,2u,3u,4u,64u}){
 cases.push_back({primitives,instances,batches,topology,bytes});bytes+=256+batches*(sizeof(Info)+12);bytes=(bytes+255)&~NSUInteger(255);}
 id<MTLBuffer>src=[d newBufferWithLength:cases.size()*20 options:MTLResourceStorageModeShared],dst=[d newBufferWithLength:bytes options:MTLResourceStorageModeShared];memset(dst.contents,0xcd,bytes);
 auto args=(uint32_t*)src.contents;
 for(unsigned i=0;i<cases.size();++i){auto c=cases[i];uint32_t count=c.topology==0?c.primitives*3:c.primitives?c.primitives+2:0;uint32_t words[]={count,c.instances,4,uint32_t(-2),5};memcpy(args+5*i,words,20);}
 Params p={};p.indexBuffer=0x1234567800;p.indexed=1;p.indexSize=4;p.vertsPerPrim=3;
 for(unsigned i=0;i<31;++i){p.strides[i]=i*11+7;p.divisors[i]=i*3+1;}
 id<MTLCommandQueue>q=[d newCommandQueue];id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];[e setComputePipelineState:ps];
 uint32_t stride=20,count=1,infoStride=sizeof(Info);
 for(unsigned i=0;i<cases.size();++i){auto c=cases[i];p.topology=c.topology;p.batchCount=c.batches;[e setBuffer:src offset:i*20 atIndex:0];[e setBuffer:dst offset:c.offset atIndex:1];[e setBuffer:dst offset:c.offset+256+c.batches*12 atIndex:2];[e setBytes:&stride length:4 atIndex:3];[e setBytes:&count length:4 atIndex:4];[e setBytes:&p length:sizeof(p) atIndex:5];[e setBytes:&infoStride length:4 atIndex:6];[e dispatchThreadgroups:MTLSizeMake((c.batches+ps.threadExecutionWidth-1)/ps.threadExecutionWidth,1,1) threadsPerThreadgroup:MTLSizeMake(ps.threadExecutionWidth,1,1)];}
 [e endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.localizedDescription.UTF8String);return 5;}
 unsigned bad=0;uint64_t commands=0,fields=0;bool sawTailOver256=false;
 for(auto c:cases){uint64_t cursor=0,total=uint64_t(c.primitives)*c.instances;
  for(unsigned batch=0;batch<c.batches;++batch){++commands;auto grid=(uint32_t*)((uint8_t*)dst.contents+c.offset+batch*12);auto info=(Info*)((uint8_t*)dst.contents+c.offset+256+c.batches*12+batch*sizeof(Info));
   auto check=[&](bool ok){++fields;if(!ok)++bad;};uint64_t span=uint64_t(grid[0])*grid[1];
   check(grid[2]==1);check(info->indexed==1);check(info->indexSize==4);check(info->indexBuffer==p.indexBuffer+16);check(info->baseVertex==-2);check(info->baseInstance==5);check(info->topology==c.topology);check(info->primitiveCount==c.primitives);
   for(unsigned k=0;k<31;++k){check(info->strides[k]==p.strides[k]);check(info->divisors[k]==p.divisors[k]);}
   if(span){uint64_t first=uint64_t(info->instanceBase)*c.primitives+info->primitiveBase;check(first==cursor);check(cursor<=total&&span<=total-cursor);check(info->primitiveBase<c.primitives);if(grid[1]>1){check(grid[0]==c.primitives);check(info->primitiveBase==0);}cursor+=span;if(grid[0]>256)sawTailOver256=true;}
  }
  ++fields;if(cursor!=total)++bad;
 }
 NSDictionary*row=@{@"passed":@(bad==0),@"device":d.name,@"cases":@(cases.size()),@"commandsChecked":@(commands),@"fieldsChecked":@(fields),@"mismatches":@(bad),@"instanceMajorOrderChecked":@YES,@"largeRemainderRetained":@(sawTailOver256),@"rendersLargeRemainder":@NO};
 [[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingPrettyPrinted error:&error]writeToFile:@(argv[2]) atomically:YES];return bad?6:0;
}}
