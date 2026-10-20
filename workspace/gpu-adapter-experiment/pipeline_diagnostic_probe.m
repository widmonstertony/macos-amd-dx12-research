#import "software_residency_adapter.h"
#include <unistd.h>
int main(){@autoreleasepool{
 id<MTLDevice> n=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"AMD"])n=x;if(!n)return 2;
 id<MTLDevice>d=SRWrapMetalDeviceForSoftwareResidency(n);NSError *error=nil;
 id<MTLLibrary> l=[d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;kernel void stamp(device uint* out[[buffer(0)]],uint i[[thread_position_in_grid]]){out[i]=i+19;}vertex float4 vertexOnly(uint i[[vertex_id]]){return float4(0,0,0,1);}" options:nil error:&error];
 if(!l)return 3;
 id<MTLComputePipelineState> good=[d newComputePipelineStateWithFunction:[l newFunctionWithName:@"stamp"] error:&error];if(!good)return 4;
 MTLRenderPipelineDescriptor *bad=[MTLRenderPipelineDescriptor new];bad.vertexFunction=[l newFunctionWithName:@"vertexOnly"];bad.rasterSampleCount=3;bad.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
 error=nil;id<MTLRenderPipelineState> rejected=[d newRenderPipelineStateWithDescriptor:bad error:&error];BOOL nativeError=(!rejected&&error!=nil);
 id<MTLBuffer>b=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];id<MTLCommandBuffer>cb=[[d newCommandQueue]commandBuffer];id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];[e setComputePipelineState:good];[e setBuffer:b offset:0 atIndex:0];[e dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];unsigned mismatches=0;for(unsigned i=0;i<64;i++)if(((unsigned*)b.contents)[i]!=i+19)mismatches++;
 usleep(1200000);BOOL ok=nativeError&&!mismatches&&cb.status==MTLCommandBufferStatusCompleted;
 NSDictionary*j=@{@"passed":@(ok),@"nativeInvalidSampleCountRejected":@(nativeError),@"nativeErrorDomain":error.domain?:@"",@"nativeErrorCode":@(error.code),@"GPUWordsChecked":@64,@"mismatches":@(mismatches),@"commandStatus":@(cb.status),@"scope":@"Diagnostic preserves real rejection and subsequent GPU compute; not actual game shader verification"};NSData*a=[NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:nil];fwrite(a.bytes,1,a.length,stdout);puts("");return ok?0:5;
}}
