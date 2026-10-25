// Three additions to the existing native-only, real-GPU residency fixture.
#include <atomic>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <iomanip>
#include <limits.h>
#include <unistd.h>
static std::atomic<uint64_t> lifecycleDestroyed{0};
@interface HeapLeaseDeathWatch:NSObject @end
@implementation HeapLeaseDeathWatch
- (void)dealloc { lifecycleDestroyed.fetch_add(1); [super dealloc]; }
@end
static char lifecycleAssociationKey;
struct LifecycleTotals { uint64_t checked=0,bad=0,writeBad=0,readBad=0; };
static const char* strictHelperImage() {
 auto method=&MVKUseResourceHelper::bindAndResetGraphics;void* address=nullptr;
 static_assert(sizeof(method)>=sizeof(address));memcpy(&address,&method,sizeof(address));
 Dl_info info{};need(dladdr(address,&info)&&info.dli_fname,"native helper dladdr failed");
 const char* expected=getenv("MVK_FIXTURE_EXPECTED_LIBRARY");need(expected&&*expected,"exact expected native image is required");
 char actualPath[PATH_MAX]{},expectedPath[PATH_MAX]{};
 need(realpath(info.dli_fname,actualPath)&&realpath(expected,expectedPath),"native helper image realpath failed");
 need(!strcmp(actualPath,expectedPath),"native helper resolved to a different image");
 return info.dli_fname;
}
static void configureLifecycleHelper(MVKUseResourceHelper&h) {
 h.cacheLiveResources=h.crossEncoderLiveCache=h.batchLiveResources=h.batchArgumentHeaps=h.descriptorSnapshotReuse=h.crossEncoderSnapshotReuse=true;
 h.heapBatchThreshold=2;h.resourceUseStats=true;
 need(h.encoderHeapPlans,"native encoder heap-plan path is not enabled");
}
static uint64_t checkGreen(id<MTLBuffer> b,size_t offset) {
 uint64_t bad=0;for(unsigned y=0;y<8;++y)for(unsigned x=0;x<8;++x)
  bad+=((uint32_t*)((char*)b.contents+offset+y*256))[x]!=0xff00ff00u;
 return bad;
}
static void copyGreen(id<MTLBlitCommandEncoder>b,id<MTLTexture>t,id<MTLBuffer>out,size_t offset) {
 [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
  sourceSize:MTLSizeMake(8,8,1) toBuffer:out destinationOffset:offset destinationBytesPerRow:256 destinationBytesPerImage:2048];
}
static LifecycleTotals lifecycleCases(id<MTLDevice>d,id<MTLLibrary>lib,id<MTLCommandQueue>q,
 id<MTLRenderPipelineState>pRS,id<MTLRenderPipelineState>pR,std::ofstream&report,uint64_t&row) {
 need(controlModes==1,"lifecycle fixture must be strict native-only");strictHelperImage();
 NSError*error=nil;
 auto plainLib=[d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; struct V{float4 p [[position]];}; vertex V plain(uint i [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return {float4(p[i],0,1)};}" options:nil error:&error];
 need(plainLib!=nil,error.localizedDescription.UTF8String?:"plain shader failed");
 auto plain=[plainLib newFunctionWithName:@"plain"],fr=[lib newFunctionWithName:@"fr"],fwo=[lib newFunctionWithName:@"fwo"],vr=[lib newFunctionWithName:@"vr"];
 auto makePipeline=[&](id<MTLFunction>f){auto pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=plain;pd.fragmentFunction=f;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
  auto ps=[d newRenderPipelineStateWithDescriptor:pd error:&error];[pd release];need(ps!=nil,error.localizedDescription.UTF8String?:"extra pipeline failed");return ps;};
 auto pFragment=makePipeline(fr),pWrite=makePipeline(fwo);
 LifecycleTotals totals;
 for(unsigned test:{6u,7u,8u}) {
  MTLResourceOptions options=MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeTracked;
  auto hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;
  auto size=[d heapBufferSizeAndAlignWithLength:256 options:options];hd.size=130*((size.size+size.align-1)&~(size.align-1));
  auto heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"extra heap failed");
  std::vector<id<MTLBuffer>> inputs;for(unsigned i=0;i<130;++i){auto b=[heap newBufferWithLength:256 options:options];need(b!=nil,"extra buffer failed");inputs.push_back(b);}
  id<MTLBuffer> B=inputs[0],C=inputs[1];
  // Drain initialization command-buffer/encoder owners before the lifetime case.
  @autoreleasepool {
   auto seed=[d newBufferWithLength:130*256 options:MTLResourceStorageModeShared];
   for(unsigned i=0;i<130*64;++i)((uint32_t*)seed.contents)[i]=11+i/64;
   auto cb=[q commandBuffer];auto blit=[cb blitCommandEncoder];
   for(unsigned i=0;i<130;++i)[blit copyFromBuffer:seed sourceOffset:i*256 toBuffer:inputs[i] destinationOffset:0 size:256];
   [blit endEncoding];finish(cb);[seed release];
  }
  auto localAE=[vr newArgumentEncoderWithBufferIndex:0];
  auto readTable=[d newBufferWithLength:localAE.encodedLength options:MTLResourceStorageModeShared];
  auto writeTable=[d newBufferWithLength:localAE.encodedLength options:MTLResourceStorageModeShared];
  if(test!=8){
   [localAE setArgumentBuffer:readTable offset:0];[localAE setBuffer:nil offset:0 atIndex:0];[localAE setBuffer:B offset:0 atIndex:1];
   [localAE setArgumentBuffer:writeTable offset:0];[localAE setBuffer:B offset:0 atIndex:0];[localAE setBuffer:C offset:0 atIndex:1];
   [localAE release];localAE=nil;
  }
  auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
  auto target=[d newTextureWithDescriptor:td];need(target!=nil,"extra render target failed");
  auto result=[d newBufferWithLength:test==6?6400:2304 options:MTLResourceStorageModeShared];memset(result.contents,0xcd,result.length);
  MVKLiveList live;auto values=std::make_shared<MVKDescriptorUseCache::Resources>();
  for(auto b:inputs){live.add(b);values->push_back(b);}MVKDescriptorUseCache::Snapshot reads=values;
  MVKUseResourceHelper helper;configureLifecycleHelper(helper);
  Oracle oracle;for(auto b:inputs)oracle.resources.push_back(b);
  ResidencyOracleLedger* ledger=[ResidencyOracleLedger new];ledger->state=&oracle;ledger->repair=false;
  uint64_t bad=0,checked=0,hits=0,covered=0,resets=0,beforeBindDestroyed=0,afterGPUDestroyed=0,afterReleaseDestroyed=0;
  bool externalReleased=false,registryEvicted=false,unretained=false;uint64_t leaseChildren=0;
  auto cb=[(test==8?[q commandBufferWithUnretainedReferences]:[q commandBuffer]) retain];
  if(test==8){unretained=!cb.retainedReferences;need(unretained,"lifetime CB retainedReferences must be false");lifecycleDestroyed=0;
   for(auto b:inputs){auto watch=[HeapLeaseDeathWatch new];objc_setAssociatedObject(b,&lifecycleAssociationKey,watch,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[watch release];}}
  unsigned passes=test==6?3:1;
  for(unsigned passIndex=0;passIndex<passes;++passIndex) {
   if(passIndex){helper.resetForEncoder();++resets;oracle.last.clear();oracle.writes.clear();oracle.heapStages.clear();oracle.preciseReadStages.clear();}
   auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
   auto enc=[cb renderCommandEncoderWithDescriptor:pass];ledger->native=enc;
   MVKResourceUsageStages stage=test==6?(passIndex==0?MVKResourceUsageStages::Vertex:passIndex==1?MVKResourceUsageStages::Fragment:MVKResourceUsageStages::All):test==7?MVKResourceUsageStages::Vertex:MVKResourceUsageStages::All;
   MTLRenderStages expectedStages=stage==MVKResourceUsageStages::Vertex?MTLRenderStageVertex:stage==MVKResourceUsageStages::Fragment?MTLRenderStageFragment:MTLRenderStageVertex|MTLRenderStageFragment;
   auto callsBefore=helper.statsHeapPlanCalls,resourcesBefore=helper.statsHeapPlanResources,heapsBefore=oracle.heaps;
   addSnapshot(helper,reads,live,(id<MTLCommandEncoder>)ledger,immediate,stage,false);
   need(helper.statsHeapPlanCalls>callsBefore&&helper.statsHeapPlanResources>=resourcesBefore+130,"extra case did not hit actual buffer heap plan");
   ++hits;covered+=helper.statsHeapPlanResources-resourcesBefore;
   if(test==8){
    need(oracle.heaps==0&&oracle.precise==0,"lifetime release occurred after Metal residency emission");
    for(auto&lease:helper.retainedSnapshotLeases)leaseChildren+=lease->size();need(leaseChildren>=130,"helper owns no qualifying buffer lease");
    // Evict the registry's strong snapshot owner, leaving the helper's leases.
    for(auto b:inputs)live.remove(b);registryEvicted=true;
    reads.reset();values.reset();for(auto b:inputs)[b release];externalReleased=true;
    [heap release];heap=nil;
    beforeBindDestroyed=lifecycleDestroyed.load();need(beforeBindDestroyed==0,"lease lost a child before any Metal declaration/binding");
    // Encode indirect addresses only after the pre-bind ownership assertion.
    [localAE setArgumentBuffer:readTable offset:0];[localAE setBuffer:nil offset:0 atIndex:0];[localAE setBuffer:B offset:0 atIndex:1];
    [localAE release];localAE=nil;
   }
   helper.bindAndResetGraphics((id<MTLRenderCommandEncoder>)ledger);
   need(oracle.heaps>heapsBefore,"new encoder did not receive a native heap declaration");checkRead(oracle,B,expectedStages);
   uint32_t expected=11;[enc setVertexBytes:&expected length:4 atIndex:1];[enc setFragmentBytes:&expected length:4 atIndex:1];
   [enc setVertexBuffer:readTable offset:0 atIndex:0];[enc setFragmentBuffer:readTable offset:0 atIndex:0];
   if(test==7)[enc setViewport:MTLViewport{0,0,4,8,0,1}];
   auto pipeline=test==6?(passIndex==0?pRS:passIndex==1?pFragment:pR):test==7?pRS:pR;
   [enc setRenderPipelineState:pipeline];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
   if(test==7){
    // Same buffer B: heap-read first, then precise read/write upgrade, same encoder.
    [enc memoryBarrierWithScope:MTLBarrierScopeBuffers afterStages:MTLRenderStageVertex beforeStages:MTLRenderStageFragment];
    helper.add(B,MVKResourceUsageStages::Fragment,true);helper.bindAndResetGraphics((id<MTLRenderCommandEncoder>)ledger);
    checkWrite(oracle,B,MTLRenderStageFragment);checkRead(oracle,B,MTLRenderStageVertex);
    [enc setViewport:MTLViewport{4,0,4,8,0,1}];[enc setRenderPipelineState:pWrite];[enc setFragmentBuffer:writeTable offset:0 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
   }
   [enc endEncoding];auto blit=[cb blitCommandEncoder];copyGreen(blit,target,result,passIndex*2048);
   if(passIndex+1==passes)[blit copyFromBuffer:B sourceOffset:0 toBuffer:result destinationOffset:test==6?6144:2048 size:4];[blit endEncoding];
  }
  finish(cb);
  for(unsigned i=0;i<passes;++i){bad+=checkGreen(result,i*2048);checked+=64;}
  bad+=*(uint32_t*)((char*)result.contents+(test==6?6144:2048))!=(test==7?43:11);++checked;
  if(test==8){afterGPUDestroyed=lifecycleDestroyed.load();need(afterGPUDestroyed==0,"helper lease failed before GPU completion");
   helper.releaseLiveResources();afterReleaseDestroyed=lifecycleDestroyed.load();need(afterReleaseDestroyed==130,"buffer release after helper ownership ended is inconclusive");}
  totals.checked+=checked;totals.bad+=bad;totals.writeBad+=oracle.violations;totals.readBad+=oracle.readViolations;
  report<<(row++?",":"")<<"{\"case\":"<<test<<",\"name\":"<<std::quoted(test==6?"same-helper-two-resets-stage-change":test==7?"same-buffer-heap-read-to-write":"lease-prebind-external-release")
   <<",\"strictNativeOnly\":true,\"repairLedger\":false,\"GPUValuesChecked\":"<<checked<<",\"mismatches\":"<<bad<<",\"GPUOutputPassed\":"<<(bad?"false":"true")
   <<",\"nativeHeapPlanHits\":"<<hits<<",\"nativeHeapPlanCoveredResources\":"<<covered<<",\"heapCalls\":"<<oracle.heaps<<",\"encoderResets\":"<<resets
   <<",\"writeContractViolations\":"<<oracle.violations<<",\"readStageViolations\":"<<oracle.readViolations
   <<",\"externalReferencesReleasedBeforeBind\":"<<(externalReleased?"true":"false")<<",\"registrySnapshotEvictedBeforeBind\":"<<(registryEvicted?"true":"false")
   <<",\"commandBufferUnretainedReferences\":"<<(unretained?"true":"false")<<",\"leaseChildrenBeforeBind\":"<<leaseChildren
   <<",\"destroyedBeforeBind\":"<<beforeBindDestroyed<<",\"destroyedAtGPUCompletion\":"<<afterGPUDestroyed<<",\"destroyedAfterHelperRelease\":"<<afterReleaseDestroyed
   <<",\"helperHeldUntilGPUCompletion\":true,\"realRuntimeHelperLifetimeValidated\":false}";
  if(test!=8){for(auto b:inputs)live.remove(b);for(auto b:inputs)[b release];}
  [cb release];[ledger release];[readTable release];[writeTable release];[target release];[result release];[heap release];[hd release];
 }
 [pFragment release];[pWrite release];[plain release];[plainLib release];[fr release];[fwo release];[vr release];
 return totals;
}
