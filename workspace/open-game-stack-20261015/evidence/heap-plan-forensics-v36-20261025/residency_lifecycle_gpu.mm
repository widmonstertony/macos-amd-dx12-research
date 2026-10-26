// Actual v30 helper, real GPU output, and an independent draw-boundary oracle.
// The optional repair ledger changes only declaration order/replay for control.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <map>
#include <stdexcept>
#include <vector>
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
struct Decl { MTLResourceUsage usage=0;MTLRenderStages stages=0; };
struct Oracle {
 std::vector<id<MTLResource>> resources;
 std::map<id<MTLResource>,Decl> last,writes;
 std::map<id<MTLHeap>,MTLRenderStages> heapStages,preciseReadStages;
 uint64_t heaps=0,precise=0,replayed=0,checks=0,violations=0,readChecks=0,readViolations=0;
};
@interface ResidencyOracleLedger:NSObject {
@public id<MTLRenderCommandEncoder> native;id<MTLComputeCommandEncoder> computeNative;Oracle* state;bool repair;
}
- (void)useResources:(const id<MTLResource>[])rs count:(NSUInteger)n usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages;
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages;
- (void)useHeaps:(const id<MTLHeap>[])hs count:(NSUInteger)n stages:(MTLRenderStages)stages;
- (void)useResources:(const id<MTLResource>[])rs count:(NSUInteger)n usage:(MTLResourceUsage)usage;
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)usage;
- (void)useHeaps:(const id<MTLHeap>[])hs count:(NSUInteger)n;
@end
@implementation ResidencyOracleLedger
- (void)useResources:(const id<MTLResource>[])rs count:(NSUInteger)n usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {
 state->precise+=n;
 for(NSUInteger i=0;i<n;++i){auto s=stages;
  if(repair)s|=state->heapStages[rs[i].heap];if((usage&MTLResourceUsageRead)&&rs[i].heap)state->preciseReadStages[rs[i].heap]|=s;
  state->last[rs[i]]={usage,s};if(usage&MTLResourceUsageWrite)state->writes[rs[i]]={usage,s};
  if(repair&&s!=stages)[native useResource:rs[i] usage:usage stages:s];
  else [native useResource:rs[i] usage:usage stages:stages];
 }
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {
 const id<MTLResource> one[]={r};[self useResources:one count:1 usage:usage stages:stages];
}
- (void)useHeaps:(const id<MTLHeap>[])hs count:(NSUInteger)n stages:(MTLRenderStages)stages {
 state->heaps+=n;
 for(NSUInteger i=0;i<n;++i){auto effective=stages;if(repair)effective|=state->heapStages[hs[i]]|state->preciseReadStages[hs[i]];const id<MTLHeap> one[]={hs[i]};[native useHeaps:one count:1 stages:effective];state->heapStages[hs[i]]|=effective;
  for(auto r:state->resources)if(r.heap==hs[i])state->last[r]={MTLResourceUsageRead,effective};
  // A deliberately conservative repair oracle: every old writable exception
  // survives a new heap declaration, even if the actual helper suppressed it.
  if(repair)for(auto& e:state->writes)if(e.first.heap==hs[i]){
   e.second.stages|=state->heapStages[hs[i]];
   [native useResource:e.first usage:e.second.usage stages:e.second.stages];
   state->last[e.first]=e.second;++state->replayed;
  }
 }
}
- (void)useResources:(const id<MTLResource>[])rs count:(NSUInteger)n usage:(MTLResourceUsage)usage {
 state->precise+=n;for(NSUInteger i=0;i<n;++i){state->last[rs[i]]={usage,MTLRenderStageVertex};if(usage&MTLResourceUsageWrite)state->writes[rs[i]]={usage,MTLRenderStageVertex};}
 [computeNative useResources:rs count:n usage:usage];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)usage {const id<MTLResource> one[]={r};[self useResources:one count:1 usage:usage];}
- (void)useHeaps:(const id<MTLHeap>[])hs count:(NSUInteger)n {
 state->heaps+=n;[computeNative useHeaps:hs count:n];for(NSUInteger i=0;i<n;++i){
  for(auto r:state->resources)if(r.heap==hs[i])state->last[r]={MTLResourceUsageRead,MTLRenderStageVertex};
  if(repair)for(auto&e:state->writes)if(e.first.heap==hs[i]){[computeNative useResource:e.first usage:e.second.usage];state->last[e.first]=e.second;++state->replayed;}
 }
}
@end
static void checkWrite(Oracle&s,id<MTLResource>r,MTLRenderStages stages){
 ++s.checks;auto it=s.last.find(r);if(it==s.last.end()||!(it->second.usage&MTLResourceUsageWrite)||(it->second.stages&stages)!=stages)++s.violations;
}
static void checkRead(Oracle&s,id<MTLResource>r,MTLRenderStages stages){++s.readChecks;auto it=s.last.find(r);if(it==s.last.end()||!(it->second.usage&MTLResourceUsageRead)||(it->second.stages&stages)!=stages)++s.readViolations;}
// Explicit owner boundaries only because this direct-helper fixture bypasses
// MVKResourceBinder. Does not alter residency declarations, oracle, or GPU work.
struct FixtureResourceForensics {
 MVKUseResourceHelper& helper;bool enabled;
 explicit FixtureResourceForensics(MVKUseResourceHelper&h):helper(h),enabled(getenv("MVK_FIXTURE_FORENSICS")&&!strcmp(getenv("MVK_FIXTURE_FORENSICS"),"1")){
  if(enabled)helper.resourceForensics.reset(mvkStutterContext());
 }
 void observe(id<MTLCommandEncoder>encoder,uint64_t kind){if(enabled)helper.resourceForensics.observe(reinterpret_cast<uintptr_t>((__bridge void*)encoder),0,0,mvkStutterContext(),kind);}
 ~FixtureResourceForensics(){if(enabled)helper.finishResourceForensics(99);}
};
static void immediate(id<MTLCommandEncoder>e,id<MTLResource>r,MTLResourceUsage usage,MVKResourceUsageStages stage){
 MTLRenderStages s=stage==MVKResourceUsageStages::Vertex?MTLRenderStageVertex:stage==MVKResourceUsageStages::Fragment?MTLRenderStageFragment:MTLRenderStageVertex|MTLRenderStageFragment;
 [(id<MTLRenderCommandEncoder>)e useResource:r usage:usage stages:s];
}
static void finish(id<MTLCommandBuffer>b){[b commit];[b waitUntilCompleted];need(b.status==MTLCommandBufferStatusCompleted,b.error.localizedDescription.UTF8String?:"GPU command failed");}
static void immediateCompute(id<MTLCommandEncoder>e,id<MTLResource>r,MTLResourceUsage usage,MVKResourceUsageStages){[(id<MTLComputeCommandEncoder>)e useResource:r usage:usage];}
static MVKDescriptorUseCache::Snapshot snap(std::initializer_list<id<MTLResource>> rs){auto s=std::make_shared<MVKDescriptorUseCache::Resources>();for(auto r:rs)s->push_back(r);return s;}
static void addSnapshot(MVKUseResourceHelper&h,MVKDescriptorUseCache::Snapshot snapshot,
 MVKLiveList&list,id<MTLCommandEncoder>e,MVKResourceBinder::UseResource f,
 MVKResourceUsageStages stage,bool write){
#ifdef MVK_NEW_BUFFER_SNAPSHOT_HINT
 h.addLiveSnapshot(snapshot,list,e,f,stage,write,true);
#else
 h.addLiveSnapshot(snapshot,list,e,f,stage,write);
#endif
}
#ifdef MVK_NEW_BUFFER_SNAPSHOT_HINT
static constexpr unsigned controlModes=1;
#else
static constexpr unsigned controlModes=2;
#endif
struct NativePlanProof{uint64_t covered=0,calls=0,skips=0,writeReplays=0;};
static NativePlanProof planProof(MVKUseResourceHelper&h,Oracle&oracle){
 need(oracle.heaps>0,"large known-buffer fixture used no native heap declarations");
#ifdef MVK_NEW_BUFFER_SNAPSHOT_HINT
 need(h.statsHeapPlanResources>0,"native fast plan did not bulk-cover any buffer children");
 return {h.statsHeapPlanResources,h.statsHeapPlanCalls,h.statsHeapPlanSkips,h.heapLedger.stats().writeExceptionsReplayed};
#else
 return {};
#endif
}
#include "lifecycle_cases.inc"
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report path required");
 need(access(argv[1],F_OK)!=0,"report path must not already exist");
 const char* loadedHelperImage=strictHelperImage();
#ifdef MVK_NEW_BUFFER_SNAPSHOT_HINT
 need(getenv("MVK_AMD_ENCODER_HEAP_PLANS")&&!strcmp(getenv("MVK_AMD_ENCODER_HEAP_PLANS"),"1"),"new buffer heap-plan mode must be enabled");
#endif
id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");
 NSString*msl=@"#include <metal_stdlib>\nusing namespace metal;struct A{device atomic_uint*dst [[id(0)]];device const uint*src [[id(1)]];};struct V{float4 p [[position]];};V v(uint id){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return {float4(p[id],0,1)};}vertex V vw(uint id [[vertex_id]],constant A&a [[buffer(0)]]){if(id==0)atomic_fetch_add_explicit(a.dst,1u,memory_order_relaxed);return v(id);}vertex V vr(uint id [[vertex_id]],constant A&a [[buffer(0)]],constant uint&expected [[buffer(1)]]){uint x=*a.src;V o=v(id);if(x!=expected)o.p=float4(5,5,0,1);return o;}fragment float4 fr(constant A&a [[buffer(0)]],constant uint&expected [[buffer(1)]]){return *a.src==expected?float4(0,1,0,1):float4(1,0,0,1);}fragment float4 fw(constant A&a [[buffer(0)]],constant uint&expected [[buffer(1)]]){atomic_fetch_add_explicit(a.dst,1u,memory_order_relaxed);return *a.src==expected?float4(0,1,0,1):float4(1,0,0,1);}fragment float4 fwo(constant A&a [[buffer(0)]]){atomic_fetch_add_explicit(a.dst,1u,memory_order_relaxed);return float4(0,1,0,1);}fragment float4 solid(){return float4(0,1,0,1);}kernel void c1(constant A&a [[buffer(0)]]){atomic_fetch_add_explicit(a.dst,1u,memory_order_relaxed);}kernel void c2(constant A&a [[buffer(0)]],device uint*out [[buffer(1)]]){atomic_fetch_add_explicit(a.dst,1u,memory_order_relaxed);out[0]=*a.src;}";
 NSError*err=nil;id<MTLLibrary>lib=[d newLibraryWithSource:msl options:nil error:&err];need(lib!=nil,err.localizedDescription.UTF8String?:"compile failed");
 id<MTLFunction>vw=[lib newFunctionWithName:@"vw"],vr=[lib newFunctionWithName:@"vr"],fr=[lib newFunctionWithName:@"fr"],fw=[lib newFunctionWithName:@"fw"],fwo=[lib newFunctionWithName:@"fwo"],solid=[lib newFunctionWithName:@"solid"];
 bool wantSV=getenv("MTL_SHADER_VALIDATION")&&!strcmp(getenv("MTL_SHADER_VALIDATION"),"1");
 auto pipeline=[&](id<MTLFunction>v,id<MTLFunction>f){MTLRenderPipelineDescriptor*p=[MTLRenderPipelineDescriptor new];p.vertexFunction=v;p.fragmentFunction=f;p.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;if(wantSV)p.shaderValidation=MTLShaderValidationEnabled;auto q=[d newRenderPipelineStateWithDescriptor:p error:&err];[p release];need(q!=nil,err.localizedDescription.UTF8String?:"pipeline failed");return q;};
 auto pVS=pipeline(vw,solid),pV=pipeline(vw,fr),pF=pipeline(vr,fw),pFO=pipeline(vr,fwo),pR=pipeline(vr,fr),pRS=pipeline(vr,solid);
 bool actualSV=pV.shaderValidation==MTLShaderValidationEnabled&&pF.shaderValidation==MTLShaderValidationEnabled&&pFO.shaderValidation==MTLShaderValidationEnabled&&pR.shaderValidation==MTLShaderValidationEnabled&&pRS.shaderValidation==MTLShaderValidationEnabled;
 id<MTLArgumentEncoder>ae=[vw newArgumentEncoderWithBufferIndex:0];id<MTLCommandQueue>q=[d newCommandQueue];
 std::ofstream report(argv[1]);report<<"{\"strictNativeOnly\":true,\"nativeOnly\":true,\"nativeHelperImage\":"<<std::quoted(loadedHelperImage)<<",";report<<"\"device\":\"AMD Radeon Pro 5600M\",\"actualHelper\":true,\"nativeCandidateOnly\":"<<(controlModes==1?"true":"false")<<",\"repairInterpositionEnabled\":"<<(controlModes==2?"true":"false")<<",\"shaderValidationRequested\":"<<(wantSV?"true":"false")<<",\"renderShaderValidationActuallyEnabled\":"<<(actualSV?"true":"false")<<",\"renderPipelineShaderValidationStates\":["<<(long)pVS.shaderValidation<<","<<(long)pV.shaderValidation<<","<<(long)pF.shaderValidation<<","<<(long)pFO.shaderValidation<<"]"<<",\"cases\":[";
 uint64_t totalMismatches=0,totalChecks=0,totalViolations=0,repairViolations=0,totalReadViolations=0,repairReadViolations=0,gpuChecked=0,row=0,aliasCases=0;
 for(unsigned mode=0;mode<controlModes;++mode)for(unsigned test:{0u,1u,2u,3u,5u}){
  MTLResourceOptions opts=MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeTracked;
  MTLHeapDescriptor*hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;auto req=[d heapBufferSizeAndAlignWithLength:256 options:opts];hd.size=133*((req.size+req.align-1)&~(req.align-1));id<MTLHeap>heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"heap failed");
  std::vector<id<MTLBuffer>>owned;for(unsigned k=0;k<5;++k){auto b=[heap newBufferWithLength:256 options:opts];need(b!=nil,"heap child failed");owned.push_back(b);}
  std::vector<id<MTLResource>> padding;for(unsigned i=0;i<128;++i){auto r=[heap newBufferWithLength:256 options:opts];need(r!=nil,"padding allocation failed");owned.push_back(r);padding.push_back(r);}
  auto A=owned[0],B=owned[1],C=owned[2],D=owned[3],E=owned[4];id<MTLBuffer>L1=nil,L2=nil;bool aliased=false;
  if(test==3){NSUInteger co=C.heapOffset,doff=D.heapOffset;[C makeAliasable];[D makeAliasable];L1=[heap newBufferWithLength:256 options:opts];L2=[heap newBufferWithLength:256 options:opts];need(L1&&L2,"alias allocation failed");owned.push_back(L1);owned.push_back(L2);aliased=(L1.heapOffset==co||L1.heapOffset==doff)&&(L2.heapOffset==co||L2.heapOffset==doff);need(aliased,"alias offsets not reused");++aliasCases;}
  auto seed=[d newBufferWithLength:owned.size()*256 options:MTLResourceStorageModeShared];for(unsigned i=0;i<owned.size()*64;++i)((uint32_t*)seed.contents)[i]=i/64==0?(test==5?11:0):11+i/64;
  auto init=[q commandBuffer];auto blit=[init blitCommandEncoder];for(unsigned i=0;i<owned.size();++i)if(!aliased||i!=2&&i!=3)[blit copyFromBuffer:seed sourceOffset:i*256 toBuffer:owned[i] destinationOffset:0 size:256];[blit endEncoding];finish(init);
  auto readback=[d newBufferWithLength:2304 options:MTLResourceStorageModeShared];memset(readback.contents,0xcd,2304);
  auto table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];[ae setBuffer:A offset:0 atIndex:0];[ae setBuffer:test==5?A:B offset:0 atIndex:1];id<MTLResource>activeSource=test==5?A:B;id<MTLBuffer>lateTable=nil;id<MTLBuffer>activeTable=table;if(test==3){lateTable=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:lateTable offset:0];[ae setBuffer:A offset:0 atIndex:0];[ae setBuffer:L1 offset:0 atIndex:1];}
  MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;auto target=[d newTextureWithDescriptor:td];
  MVKLiveList live;live.add(B);live.add(E);if(test!=3)live.add(C);
  auto readValues=std::make_shared<MVKDescriptorUseCache::Resources>();for(auto r:padding){readValues->push_back(r);live.add(r);}if(test==3){for(id<MTLResource>r:{B,E,L1,L2})readValues->push_back(r);}else{readValues->push_back(B);readValues->push_back(C);}MVKDescriptorUseCache::Snapshot reads=readValues;
  MVKUseResourceHelper h;h.cacheLiveResources=h.crossEncoderLiveCache=h.batchLiveResources=h.batchArgumentHeaps=h.descriptorSnapshotReuse=h.crossEncoderSnapshotReuse=true;h.heapBatchThreshold=2;h.resourceUseStats=true;FixtureResourceForensics forensic(h);
  auto cb=[q commandBuffer];MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;auto enc=[cb renderCommandEncoderWithDescriptor:pass];ResidencyOracleLedger*ledger=[ResidencyOracleLedger new];Oracle oracle;for(auto r:owned)if(!aliased||r!=C&&r!=D)oracle.resources.push_back(r);ledger->native=enc;ledger->state=&oracle;ledger->repair=mode;forensic.observe((id<MTLCommandEncoder>)enc,ledger->computeNative?2:1);
  auto draw=[&](id<MTLRenderPipelineState>p,MTLRenderStages writeStage){if(writeStage)checkWrite(oracle,A,writeStage);if(p==pV)checkRead(oracle,activeSource,MTLRenderStageFragment);if(p==pF||p==pR)checkRead(oracle,activeSource,MTLRenderStageVertex|MTLRenderStageFragment);if(p==pFO||p==pRS)checkRead(oracle,activeSource,MTLRenderStageVertex);NSUInteger sourceIndex=std::find(owned.begin(),owned.end(),activeSource)-owned.begin();uint32_t expectedSource=((uint32_t*)seed.contents)[sourceIndex*64];[enc setVertexBytes:&expectedSource length:4 atIndex:1];[enc setFragmentBytes:&expectedSource length:4 atIndex:1];[enc setRenderPipelineState:p];[enc setVertexBuffer:activeTable offset:0 atIndex:0];[enc setFragmentBuffer:activeTable offset:0 atIndex:0];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];};
  auto flush=[&]{h.bindAndResetGraphics((id<MTLRenderCommandEncoder>)ledger);};
  unsigned expected=0;
  if(test==0){h.add(A,MVKResourceUsageStages::Vertex,true);addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediate,MVKResourceUsageStages::Fragment,false);flush();draw(pV,MTLRenderStageVertex);expected=1;}
  if(test==1){h.add(A,MVKResourceUsageStages::Vertex,true);flush();draw(pVS,MTLRenderStageVertex);h.add(A,MVKResourceUsageStages::Vertex,true);addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediate,MVKResourceUsageStages::Fragment,false);flush();draw(pV,MTLRenderStageVertex);expected=2;}
  if(test==2){addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediate,MVKResourceUsageStages::Vertex,false);h.add(A,MVKResourceUsageStages::Fragment,true);flush();draw(pFO,MTLRenderStageFragment);h.add(A,MVKResourceUsageStages::Fragment,true);addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediate,MVKResourceUsageStages::Fragment,false);flush();draw(pF,MTLRenderStageFragment);expected=128;}
  if(test==3){addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediate,MVKResourceUsageStages::Vertex,false);h.add(A,MVKResourceUsageStages::Fragment,true);flush();draw(pFO,MTLRenderStageFragment);live.add(L1);live.add(L2);activeTable=lateTable;activeSource=L1;h.add(A,MVKResourceUsageStages::Fragment,true);addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediate,MVKResourceUsageStages::Vertex,false);flush();draw(pFO,MTLRenderStageFragment);expected=128;}
  if(test==5){h.add(A,MVKResourceUsageStages::Vertex,false);flush();draw(pRS,MTLRenderStages(0));h.add(A,MVKResourceUsageStages::Vertex,false);addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediate,MVKResourceUsageStages::Fragment,false);flush();draw(pR,MTLRenderStages(0));expected=11;}
  need(oracle.heaps>0,"large known-buffer plan never emitted a heap declaration");
  [enc endEncoding];blit=[cb blitCommandEncoder];[blit copyFromBuffer:A sourceOffset:0 toBuffer:readback destinationOffset:2048 size:4];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];[blit endEncoding];finish(cb);
  auto nativeProof=planProof(h,oracle);uint64_t bad=*(uint32_t*)((char*)readback.contents+2048)!=expected;for(unsigned y=0;y<8;++y)for(unsigned x=0;x<8;++x)bad+=((uint32_t*)((char*)readback.contents+y*256))[x]!=0xff00ff00u;
  totalMismatches+=bad;gpuChecked+=65;totalChecks+=oracle.checks;if(mode){repairViolations+=oracle.violations;repairReadViolations+=oracle.readViolations;}else{totalViolations+=oracle.violations;totalReadViolations+=oracle.readViolations;}
  report<<(row++?",":"")<<"{\"case\":"<<test<<",\"repairLedger\":"<<(mode?"true":"false")<<",\"GPUOutputPassed\":"<<(bad?"false":"true")<<",\"mismatches\":"<<bad<<",\"drawBoundaryChecks\":"<<oracle.checks<<",\"writeContractViolations\":"<<oracle.violations<<",\"readStageChecks\":"<<oracle.readChecks<<",\"conservativeReadStageViolations\":"<<oracle.readViolations<<",\"heapCalls\":"<<oracle.heaps<<",\"writeExceptionReplays\":"<<oracle.replayed<<",\"nativeHeapPlanCoveredResources\":"<<nativeProof.covered<<",\"nativeHeapPlanCalls\":"<<nativeProof.calls<<",\"nativeHeapPlanSkips\":"<<nativeProof.skips<<",\"nativeWriteExceptionReplays\":"<<nativeProof.writeReplays<<",\"heapAliasOffsetsReused\":"<<(aliased?"true":"false")<<",\"lateRegistration\":"<<(test==3?"true":"false")<<"}";
  if(test==3){live.remove(L1);live.remove(L2);}live.remove(B);live.remove(E);if(test!=3)live.remove(C);for(auto r:padding)live.remove(r);[ledger release];[target release];[lateTable release];[table release];[readback release];[seed release];for(auto r:owned)[r release];[heap release];[hd release];
 }

 for(unsigned mode=0;mode<controlModes;++mode){
  auto fn1=[lib newFunctionWithName:@"c1"],fn2=[lib newFunctionWithName:@"c2"];
  auto computePipeline=[&](id<MTLFunction>fn){MTLComputePipelineDescriptor*pd=[MTLComputePipelineDescriptor new];pd.computeFunction=fn;if(wantSV)pd.shaderValidation=MTLShaderValidationEnabled;auto ps=[d newComputePipelineStateWithDescriptor:pd options:MTLPipelineOptionNone reflection:nil error:&err];[pd release];need(ps!=nil,err.localizedDescription.UTF8String?:"compute pipeline failed");return ps;};
  auto ps1=computePipeline(fn1),ps2=computePipeline(fn2);actualSV=actualSV&&ps1.shaderValidation==MTLShaderValidationEnabled&&ps2.shaderValidation==MTLShaderValidationEnabled;
  MTLResourceOptions opts=MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeTracked;MTLHeapDescriptor*hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;auto req=[d heapBufferSizeAndAlignWithLength:256 options:opts];hd.size=131*((req.size+req.align-1)&~(req.align-1));auto heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"compute heap failed");auto A=[heap newBufferWithLength:256 options:opts],B=[heap newBufferWithLength:256 options:opts],C=[heap newBufferWithLength:256 options:opts];need(A&&B&&C,"compute children failed");std::vector<id<MTLResource>>padding;for(unsigned i=0;i<128;++i){auto r=[heap newBufferWithLength:256 options:opts];need(r!=nil,"compute padding failed");padding.push_back(r);}
  auto seed=[d newBufferWithLength:768 options:MTLResourceStorageModeShared];for(unsigned i=0;i<192;++i)((uint32_t*)seed.contents)[i]=i<64?0:i<128?11:13;auto result=[d newBufferWithLength:512 options:MTLResourceStorageModeShared];memset(result.contents,0xcd,512);auto init=[q commandBuffer];auto blit=[init blitCommandEncoder];[blit copyFromBuffer:seed sourceOffset:0 toBuffer:A destinationOffset:0 size:256];[blit copyFromBuffer:seed sourceOffset:256 toBuffer:B destinationOffset:0 size:256];[blit copyFromBuffer:seed sourceOffset:512 toBuffer:C destinationOffset:0 size:256];[blit endEncoding];finish(init);
  auto cae=[fn2 newArgumentEncoderWithBufferIndex:0];auto table=[d newBufferWithLength:cae.encodedLength options:MTLResourceStorageModeShared];[cae setArgumentBuffer:table offset:0];[cae setBuffer:A offset:0 atIndex:0];[cae setBuffer:B offset:0 atIndex:1];MVKLiveList live;live.add(B);live.add(C);auto readValues=std::make_shared<MVKDescriptorUseCache::Resources>();readValues->push_back(B);readValues->push_back(C);for(auto r:padding){live.add(r);readValues->push_back(r);}MVKDescriptorUseCache::Snapshot reads=readValues;MVKUseResourceHelper h;h.cacheLiveResources=h.crossEncoderLiveCache=h.batchLiveResources=h.batchArgumentHeaps=h.descriptorSnapshotReuse=h.crossEncoderSnapshotReuse=true;h.heapBatchThreshold=2;h.resourceUseStats=true;FixtureResourceForensics forensic(h);
  auto cb=[q commandBuffer];auto enc=[cb computeCommandEncoder];ResidencyOracleLedger*ledger=[ResidencyOracleLedger new];Oracle oracle;oracle.resources={A,B,C};oracle.resources.insert(oracle.resources.end(),padding.begin(),padding.end());ledger->computeNative=enc;ledger->state=&oracle;ledger->repair=mode;forensic.observe((id<MTLCommandEncoder>)enc,ledger->computeNative?2:1);
  h.add(A,MVKResourceUsageStages::Compute,true);h.bindAndResetCompute((id<MTLComputeCommandEncoder>)ledger);checkWrite(oracle,A,MTLRenderStageVertex);[enc setComputePipelineState:ps1];[enc setBuffer:table offset:0 atIndex:0];[enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
  h.add(A,MVKResourceUsageStages::Compute,true);addSnapshot(h,reads,live,(id<MTLCommandEncoder>)ledger,immediateCompute,MVKResourceUsageStages::Compute,false);h.bindAndResetCompute((id<MTLComputeCommandEncoder>)ledger);checkWrite(oracle,A,MTLRenderStageVertex);[enc setComputePipelineState:ps2];[enc setBuffer:result offset:0 atIndex:1];[enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];blit=[cb blitCommandEncoder];[blit copyFromBuffer:A sourceOffset:0 toBuffer:result destinationOffset:256 size:4];[blit endEncoding];finish(cb);
  auto nativeProof=planProof(h,oracle);uint64_t bad=0;for(unsigned i=0;i<128;++i){uint32_t expected=i==0?11:i==64?2:0xcdcdcdcd;bad+=((uint32_t*)result.contents)[i]!=expected;}need(oracle.heaps>0,"large compute buffer plan never emitted a heap declaration");totalMismatches+=bad;gpuChecked+=128;totalChecks+=oracle.checks;if(mode){repairViolations+=oracle.violations;repairReadViolations+=oracle.readViolations;}else{totalViolations+=oracle.violations;totalReadViolations+=oracle.readViolations;}
  report<<(row++?",":"")<<"{\"case\":4,\"compute\":true,\"pipelineShaderValidationStates\":["<<(long)ps1.shaderValidation<<","<<(long)ps2.shaderValidation<<"],\"repairLedger\":"<<(mode?"true":"false")<<",\"GPUOutputPassed\":"<<(bad?"false":"true")<<",\"mismatches\":"<<bad<<",\"drawBoundaryChecks\":"<<oracle.checks<<",\"writeContractViolations\":"<<oracle.violations<<",\"readStageChecks\":"<<oracle.readChecks<<",\"conservativeReadStageViolations\":"<<oracle.readViolations<<",\"heapCalls\":"<<oracle.heaps<<",\"writeExceptionReplays\":"<<oracle.replayed<<",\"nativeHeapPlanCoveredResources\":"<<nativeProof.covered<<",\"nativeHeapPlanCalls\":"<<nativeProof.calls<<",\"nativeHeapPlanSkips\":"<<nativeProof.skips<<",\"nativeWriteExceptionReplays\":"<<nativeProof.writeReplays<<"}";
  live.remove(B);live.remove(C);for(auto r:padding){live.remove(r);[r release];}[ledger release];[table release];[cae release];[A release];[B release];[C release];[heap release];[hd release];[seed release];[result release];[ps1 release];[ps2 release];[fn1 release];[fn2 release];
 }
 auto added=lifecycleCases(d,lib,q,pRS,pR,report,row);gpuChecked+=added.checked;totalMismatches+=added.bad;totalViolations+=added.writeBad;totalReadViolations+=added.readBad;
 report<<"],\"GPUValuesChecked\":"<<gpuChecked<<",\"mismatches\":"<<totalMismatches<<",\"baselineWriteContractViolations\":"<<totalViolations<<",\"repairWriteContractViolations\":"<<repairViolations<<",\"aliasAllocationCases\":"<<aliasCases<<",\"aliasGPUHazardLifetimeTested\":false,\"readStageReplacementIsConservativeOracleAssumption\":true,\"baselineConservativeReadStageViolations\":"<<totalReadViolations<<",\"repairConservativeReadStageViolations\":"<<repairReadViolations<<",\"allPipelineShaderValidationActuallyEnabled\":"<<(actualSV?"true":"false")<<",\"GPUOutputPassed\":"<<(totalMismatches?"false":"true")<<",\"baselineContractPassed\":"<<((totalViolations||totalReadViolations)?"false":"true")<<",\"repairContractPassed\":"<<(repairViolations?"false":"true")<<",\"executed\":true}\n";
 [q release];[ae release];[pVS release];[pV release];[pF release];[pFO release];[pR release];[pRS release];[vw release];[vr release];[fr release];[fw release];[fwo release];[solid release];[lib release];return totalMismatches||totalViolations||totalReadViolations||repairViolations||repairReadViolations?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
