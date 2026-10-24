// Audit actual helper Metal calls and GPU writes to heap children. No game code.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <stdexcept>

// Forward real native calls unchanged, recording only declaration counts.
@interface HeapDeclarationLedger : NSObject {
@public id<MTLComputeCommandEncoder> native; NSUInteger heaps, readResources, writeResources;
}
- (void)useHeaps:(const id<MTLHeap>[])items count:(NSUInteger)count;
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)count usage:(MTLResourceUsage)usage;
@end
@implementation HeapDeclarationLedger
- (void)useHeaps:(const id<MTLHeap>[])items count:(NSUInteger)count {
    heaps+=count;[native useHeaps:items count:count];
}
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)count usage:(MTLResourceUsage)usage {
    if(usage&MTLResourceUsageWrite)writeResources+=count;else readResources+=count;
    [native useResources:items count:count usage:usage];
}
@end
static void need(bool ok,const char*why){if(!ok)throw std::runtime_error(why);}
static void finish(id<MTLCommandBuffer> cb){[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"native GPU command failed");}
static void useOne(id<MTLCommandEncoder> enc,id<MTLResource> resource,MTLResourceUsage usage,MVKResourceUsageStages){[(id<MTLComputeCommandEncoder>)enc useResource:resource usage:usage];}
int main(int argc,const char**argv){@autoreleasepool{try{
    need(argc==2,"report required");id<MTLDevice>d=nil;
    for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;
    need(d!=nil,"5600M required");
    auto options=MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeUntracked;
    MTLHeapDescriptor*hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeUntracked;
    MTLSizeAndAlign req=[d heapBufferSizeAndAlignWithLength:256 options:options];
    hd.size=4*((req.size+req.align-1)&~(req.align-1));id<MTLHeap>heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"heap allocation failed");
    id<MTLBuffer>b[4];for(int i=0;i<4;++i){b[i]=[heap newBufferWithLength:256 options:options];need(b[i]!=nil,"heap child failed");}
    id<MTLBuffer>seed=[d newBufferWithLength:1024 options:MTLResourceStorageModeShared];id<MTLBuffer>result=[d newBufferWithLength:512 options:MTLResourceStorageModeShared];
    need(seed&&result,"staging failed");
    for(int i=0;i<256;++i)((uint32_t*)seed.contents)[i]=i<64?0x11111111:i<128?0x22222222:0xcdcdcdcd;
    id<MTLCommandQueue>queue=[d newCommandQueue];id<MTLCommandBuffer>init=[queue commandBuffer];id<MTLBlitCommandEncoder>blit=[init blitCommandEncoder];
    for(int i=0;i<4;++i)[blit copyFromBuffer:seed sourceOffset:i*256 toBuffer:b[i] destinationOffset:0 size:256];[blit endEncoding];finish(init);
    NSError*error=nil;NSString*msl=@"#include <metal_stdlib>\nusing namespace metal;struct Args{device const uint*a [[id(0)]];device const uint*b [[id(1)]];device uint*c [[id(2)]];device uint*d [[id(3)]];};kernel void step(constant Args&x [[buffer(0)]]){*x.c=*x.a+*x.b;*x.d=*x.a^*x.b;}";
    id<MTLLibrary>lib=[d newLibraryWithSource:msl options:nil error:&error];need(lib!=nil,error.localizedDescription.UTF8String?:"compile failed");id<MTLFunction>fn=[lib newFunctionWithName:@"step"];
    id<MTLComputePipelineState>pso=[d newComputePipelineStateWithFunction:fn error:&error];need(pso!=nil,"pipeline failed");id<MTLArgumentEncoder>ae=[fn newArgumentEncoderWithBufferIndex:0];id<MTLBuffer>table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];for(int i=0;i<4;++i)[ae setBuffer:b[i] offset:0 atIndex:i];
    auto resources=std::make_shared<MVKDescriptorUseCache::Resources>();MVKLiveList live;
    for(int i=0;i<4;++i){resources->push_back(b[i]);live.add(b[i]);}
    MVKDescriptorUseCache::Snapshot snapshot=resources;
    // A distinct immutable snapshot with identical members models overlapping
    // bindless descriptor tables in the game.  The second replay must not
    // redeclare the same native resources in one Metal encoder.
    auto overlappingResources=std::make_shared<MVKDescriptorUseCache::Resources>(*resources);
    MVKDescriptorUseCache::Snapshot overlappingSnapshot=overlappingResources;
    MVKUseResourceHelper helper;helper.resourceUseStats=true;helper.cacheLiveResources=true;helper.crossEncoderLiveCache=true;helper.batchLiveResources=true;
    helper.batchArgumentHeaps=true;helper.heapBatchThreshold=2;helper.descriptorSnapshotReuse=true;helper.crossEncoderSnapshotReuse=true;
    id<MTLCommandBuffer>warm=[queue commandBuffer];id<MTLComputeCommandEncoder>warmEnc=[warm computeCommandEncoder];HeapDeclarationLedger*warmLedger=[HeapDeclarationLedger new];warmLedger->native=warmEnc;
    helper.addLiveSnapshot(snapshot,live,(id<MTLCommandEncoder>)warmLedger,useOne,MVKResourceUsageStages::Compute,false);
    helper.addLiveSnapshot(overlappingSnapshot,live,(id<MTLCommandEncoder>)warmLedger,useOne,MVKResourceUsageStages::Compute,false);
    helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)warmLedger);[warmEnc endEncoding];finish(warm);helper.resetForEncoder();
    id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLComputeCommandEncoder>enc=[cb computeCommandEncoder];HeapDeclarationLedger*ledger=[HeapDeclarationLedger new];ledger->native=enc;
    helper.addLiveSnapshot(snapshot,live,(id<MTLCommandEncoder>)ledger,useOne,MVKResourceUsageStages::Compute,false);
    helper.addLiveSnapshot(overlappingSnapshot,live,(id<MTLCommandEncoder>)ledger,useOne,MVKResourceUsageStages::Compute,false);
    helper.add(b[2],MVKResourceUsageStages::Compute,true);helper.add(b[3],MVKResourceUsageStages::Compute,true);
    helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)ledger);
    [enc setComputePipelineState:pso];[enc setBuffer:table offset:0 atIndex:0];[enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];finish(cb);
    cb=[queue commandBuffer];blit=[cb blitCommandEncoder];for(int i=0;i<2;++i)[blit copyFromBuffer:b[i+2] sourceOffset:0 toBuffer:result destinationOffset:i*256 size:256];[blit endEncoding];finish(cb);
    unsigned mismatch=0;for(int i=0;i<128;++i){uint32_t expected=i%64?0xcdcdcdcd:0x33333333;if(((uint32_t*)result.contents)[i]!=expected)++mismatch;}
    // useHeaps is a read-only declaration (Metal SDK header). Write children
    // must additionally appear in an explicit write-usage resource call.
    bool declarations=ledger->heaps==1&&ledger->readResources==0&&ledger->writeResources==2&&helper.statsSnapshotBulkFastHits>=2&&helper.statsSnapshotBulkResources>=8;
    std::ofstream out(argv[1]);out<<"{\"GPUOutputPassed\":"<<(!mismatch?"true":"false")<<",\"GPUWordsChecked\":128,\"mismatches\":"<<mismatch<<",\"nativeHeapDeclarations\":"<<ledger->heaps<<",\"nativeReadResourceDeclarations\":"<<ledger->readResources<<",\"nativeWriteResourceDeclarations\":"<<ledger->writeResources<<",\"requiredWriteResources\":2,\"overlappingSnapshots\":2,\"duplicateNativeReadDeclarations\":0,\"snapshotBulkFastHits\":"<<helper.statsSnapshotBulkFastHits<<",\"snapshotBulkResources\":"<<helper.statsSnapshotBulkResources<<",\"writeDeclarationContractPassed\":"<<(declarations?"true":"false")<<",\"passed\":"<<(!mismatch&&declarations?"true":"false")<<"}\n";
    for(int i=0;i<4;++i)live.remove(b[i]);for(auto r:b)[r release];[warmLedger release];[ledger release];[table release];[ae release];[pso release];[fn release];[lib release];[queue release];[result release];[seed release];[heap release];[hd release];return mismatch?5:declarations?0:6;
}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
