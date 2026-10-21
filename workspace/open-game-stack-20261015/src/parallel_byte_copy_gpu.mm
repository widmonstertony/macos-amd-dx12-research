// Exact old/new open-source helper kernels, full-byte CPU oracle and paired timing.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <vector>
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
struct CopyInfo{uint32_t srcOffset,dstOffset,size;};
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==3,"kernel JSON and result required");NSDictionary*source=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");NSError*error=nil;id<MTLComputePipelineState>pipelines[2];
 for(unsigned i=0;i<2;++i){auto lib=[d newLibraryWithSource:source[i?@"after":@"before"] options:nil error:&error];need(lib!=nil,error.localizedDescription.UTF8String?:"library failed");auto fn=[lib newFunctionWithName:@"cmdCopyBufferBytes"];pipelines[i]=[d newComputePipelineStateWithFunction:fn error:&error];need(pipelines[i]!=nil,"pipeline failed");[fn release];[lib release];}
 auto q=[d newCommandQueue];uint64_t checked=0,bad=0;unsigned cases=0;NSMutableArray*timings=[NSMutableArray array];
 auto run=[&](unsigned which,unsigned count,unsigned so,unsigned to,bool same,bool base)->double{@autoreleasepool{
  NSUInteger srcBase=base?256:0,dstBase=same?((count+1027)&~NSUInteger(3)):base?512:0;NSUInteger length=count+srcBase+dstBase+64;
  auto src=[d newBufferWithLength:length options:MTLResourceStorageModeShared];auto dst=same?[src retain]:[d newBufferWithLength:length options:MTLResourceStorageModeShared];need(src&&dst,"allocation failed");for(NSUInteger i=0;i<length;++i)((uint8_t*)src.contents)[i]=(i*31+i/7+19)&255;if(!same)memset(dst.contents,0xcd,length);
  std::vector<uint8_t>oracle((uint8_t*)dst.contents,(uint8_t*)dst.contents+length);memcpy(oracle.data()+dstBase+to,(uint8_t*)src.contents+srcBase+so,count);
  CopyInfo info={so,to,count};auto cb=[q commandBuffer];auto enc=[cb computeCommandEncoder];[enc setComputePipelineState:pipelines[which]];[enc setBuffer:src offset:srcBase atIndex:0];[enc setBuffer:dst offset:dstBase atIndex:1];[enc setBytes:&info length:sizeof(info) atIndex:2];NSUInteger width=which?std::min<NSUInteger>(256,pipelines[which].maxTotalThreadsPerThreadgroup):1;NSUInteger groups=which?(uint64_t(count)+width-1)/width:1;if(count)[enc dispatchThreadgroups:MTLSizeMake(groups,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"stop after GPU failure");double ms=(cb.GPUEndTime-cb.GPUStartTime)*1000;
  for(NSUInteger i=0;i<length;++i)if(((uint8_t*)dst.contents)[i]!=oracle[i])++bad;checked+=length;++cases;[src release];[dst release];return ms;
 }};
 // Every alignment pair, tails around threadgroup boundaries, offsets in a
 // larger allocation, and disjoint aliases of one actual MTLBuffer.
 for(unsigned n:{1u,2u,3u,4u,7u,31u,255u,256u,257u,4095u,4096u,4097u})for(unsigned so=0;so<4;++so)for(unsigned to=0;to<4;++to)run(1,n,so,to,false,false);
 for(unsigned n:{1u,3u,255u,256u,257u,65539u})for(unsigned so=0;so<4;++so){run(1,n,so,3-so,true,false);run(1,n,so,3-so,false,true);}
 for(unsigned n:{65539u,1048579u}){std::vector<double>before,after;for(unsigned pair=0;pair<3;++pair){double a,b;if(pair&1){b=run(1,n,1,3,false,false);a=run(0,n,1,3,false,false);}else{a=run(0,n,1,3,false,false);b=run(1,n,1,3,false,false);}before.push_back(a);after.push_back(b);need(a<2000,"stop serial stress before long GPU workloads");}std::sort(before.begin(),before.end());std::sort(after.begin(),after.end());[timings addObject:@{@"bytes":@(n),@"beforeMedianGPUMS":@(before[1]),@"afterMedianGPUMS":@(after[1]),@"speedup":@(before[1]/after[1])}];}
 NSDictionary*report=@{@"passed":@(!bad),@"GPUCopyCases":@(cases),@"GPUBytesChecked":@(checked),@"byteMismatches":@(bad),@"allFourByteAlignmentPairs":@YES,@"sameBufferNonOverlappingAliases":@YES,@"boundBufferBaseOffsets":@YES,@"tailAndSentinelChecked":@YES,@"pairedSameProcessGPUTime":timings,@"actualGameImprovementProven":@NO,@"GPUTimeoutFixProven":@NO};auto data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];need([data writeToFile:@(argv[2]) atomically:YES],"report write");printf("cases=%u checked=%llu bad=%llu\n",cases,(unsigned long long)checked,(unsigned long long)bad);[pipelines[0]release];[pipelines[1]release];[q release];return bad?5:0;
}catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
