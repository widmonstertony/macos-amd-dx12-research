#import "software_residency_adapter.h"
#include <cstdlib>
#include <unistd.h>

// New registration after the first encoder, indirect heap-child access, and
// completion-time cache release must work before a cached snapshot is usable.
int main(){@autoreleasepool{
  id<MTLDevice> native=nil;for(id<MTLDevice>d in MTLCopyAllDevices())if([d.name containsString:@"AMD"])native=d;
  if(!native)return 2;id<MTLDevice>d=SRWrapMetalDeviceForSoftwareResidency(native);
  NSError *error=nil;
  NSString *code=@"#include <metal_stdlib>\nusing namespace metal;struct Args{device uint* out;};kernel void stamp(constant Args& a[[buffer(0)]],uint tid[[thread_position_in_grid]]){a.out[tid]=tid*3+7;}";
  id<MTLLibrary> lib=[d newLibraryWithSource:code options:nil error:&error];
  id<MTLComputePipelineState> pipeline=lib?[d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"stamp"] error:&error]:nil;
  if(!pipeline){fprintf(stderr,"Pipeline failed %s\n",error.localizedDescription.UTF8String);return 3;}
  id<MTLBuffer> read1=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared],read2=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> cb=[[d newCommandQueue]commandBufferWithUnretainedReferences];
  __block BOOL freed=NO,reentered=NO;dispatch_semaphore_t releaseSignal=dispatch_semaphore_create(0);
  __weak id<MTLBuffer> weakUnused=nil;
  @autoreleasepool{
    void *memory=nullptr;size_t bytes=(size_t)getpagesize();if(posix_memalign(&memory,bytes,bytes))return 4;
    id<MTLBuffer> unused=[d newBufferWithBytesNoCopy:memory length:bytes options:MTLResourceStorageModeShared deallocator:^(void*p,NSUInteger){
      reentered=[SRSoftwareResidencyStatistics(native)[@"completedNativeCommandBuffers"] unsignedLongLongValue]>=1;
      freed=YES;free(p);dispatch_semaphore_signal(releaseSignal);
    }];weakUnused=unused;
    MTLHeapDescriptor *hd=[MTLHeapDescriptor new];hd.size=65536;hd.storageMode=MTLStorageModePrivate;
    id<MTLHeap> heap1=[d newHeapWithDescriptor:hd];id<MTLBuffer> out1=[heap1 newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> aliasUnused=[heap1 newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> args1=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];*(uint64_t*)args1.contents=out1.gpuAddress;
    id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:pipeline];[e setBuffer:args1 offset:0 atIndex:0];
    [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[e endEncoding];e=nil;
    [aliasUnused makeAliasable];
    if(!aliasUnused.isAliasable)return 6;
    // Its cached class must not cache the mutable aliasability state. The
    // next native declaration must exclude this now-aliasable, unused object.
    id<MTLBuffer> newHeapChild=[heap1 newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    if(!newHeapChild)return 7;
    // These genuine objects did not exist in the first cached snapshot.
    id<MTLHeap> heap2=[native newHeapWithDescriptor:hd];id<MTLBuffer> out2=[heap2 newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    SRRegisterMetalAllocation(native,out2);
    id<MTLBuffer> args2=[native newBufferWithLength:4096 options:MTLResourceStorageModeShared];*(uint64_t*)args2.contents=out2.gpuAddress;
    e=[cb computeCommandEncoder];[e setComputePipelineState:pipeline];[e setBuffer:args2 offset:0 atIndex:0];
    [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[e endEncoding];e=nil;
    id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];
    [b copyFromBuffer:out1 sourceOffset:0 toBuffer:read1 destinationOffset:0 size:256];
    [b copyFromBuffer:out2 sourceOffset:0 toBuffer:read2 destinationOffset:0 size:256];[b endEncoding];b=nil;
  }
  BOOL retained=weakUnused!=nil;
  [cb commit];[cb waitUntilCompleted];
  BOOL releaseObserved=dispatch_semaphore_wait(releaseSignal,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0;
  unsigned mismatch1=0,mismatch2=0;for(unsigned i=0;i<64;i++){if(((unsigned*)read1.contents)[i]!=i*3+7)mismatch1++;if(((unsigned*)read2.contents)[i]!=i*3+7)mismatch2++;}
  NSDictionary *stats=SRSoftwareResidencyStatistics(native);
  BOOL ok=cb.status==MTLCommandBufferStatusCompleted&&!mismatch1&&!mismatch2&&retained&&releaseObserved&&freed&&reentered&&weakUnused==nil&&[stats[@"snapshotCacheHits"] unsignedLongLongValue]>0&&[stats[@"snapshotCacheMisses"] unsignedLongLongValue]>=2;
  NSDictionary *result=@{@"passed":@(ok),@"firstWordsChecked":@64,@"firstMismatches":@(mismatch1),@"newIndirectHeapChildWordsChecked":@64,@"newIndirectHeapChildMismatches":@(mismatch2),@"unretainedLifetimeBeforeSubmit":@(retained),@"cacheAndResourceReleasedAtGPUCompletion":@(releaseObserved&&freed&&weakUnused==nil),@"deallocatorReenteredStatistics":@(reentered),@"commandStatus":@(cb.status),@"statistics":stats,@"scope":@"Owned true GPU outputs and changed registry after first encoder; no game conformance or FPS claim"};
  NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
  return ok?0:5;
}}
