// Owned real-helper GPU oracle: readonly image views reuse existing baseline heaps.
// Does not launch, attach to, or operate any game.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <unistd.h>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>

constexpr unsigned N=256, BASE=128, T=N+1, H=4;
static void need(bool ok,const char*why){if(!ok)throw std::runtime_error(why);}
static void finish(id<MTLCommandBuffer>cb){[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"native GPU command failed");}
static uint32_t color(unsigned i){return ((i*29+7)%256)|(((i*47+19)%256)<<8)|(((i*61+31)%256)<<16)|0xff000000u;}
static constexpr uint32_t changed=0xff895925u;

// Forward every declaration to the actual native encoder. No simulated API.
@interface TextureExceptionLedger:NSObject {
@public id<MTLCommandEncoder> native; unsigned heaps,reads,writes,writeCalls;
}
- (void)useHeaps:(const id<MTLHeap>[])items count:(NSUInteger)count stages:(MTLRenderStages)stages;
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)count usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages;
- (void)useHeaps:(const id<MTLHeap>[])items count:(NSUInteger)count;
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)count usage:(MTLResourceUsage)usage;
@end
@implementation TextureExceptionLedger
- (void)useHeaps:(const id<MTLHeap>[])items count:(NSUInteger)count stages:(MTLRenderStages)stages {heaps+=count;[(id<MTLRenderCommandEncoder>)native useHeaps:items count:count stages:stages];}
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)count usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {if(usage&MTLResourceUsageWrite){writes+=count;++writeCalls;}else reads+=count;[(id<MTLRenderCommandEncoder>)native useResources:items count:count usage:usage stages:stages];}
- (void)useHeaps:(const id<MTLHeap>[])items count:(NSUInteger)count {heaps+=count;[(id<MTLComputeCommandEncoder>)native useHeaps:items count:count];}
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)count usage:(MTLResourceUsage)usage {if(usage&MTLResourceUsageWrite){writes+=count;++writeCalls;}else reads+=count;[(id<MTLComputeCommandEncoder>)native useResources:items count:count usage:usage];}
@end
static void useOne(id<MTLCommandEncoder>enc,id<MTLResource>r,MTLResourceUsage u,MVKResourceUsageStages stage){
 [(id<MTLRenderCommandEncoder>)enc useResource:r usage:u stages:stage==MVKResourceUsageStages::Vertex?MTLRenderStageVertex:MTLRenderStageFragment];
}

int main(int argc,const char**argv){@autoreleasepool{
 std::string error;unsigned checked=0,mismatches=0,renderHeaps=0,renderReads=0,computeHeaps=0,computeWrites=0,computeWriteCalls=0;
 uint64_t applied=0,precise=0;bool setup=false,metadata=false,excluded=false,renderDone=false,writeDone=false,resetDone=false;
 id<MTLRenderCommandEncoder>activeRender=nil;id<MTLComputeCommandEncoder>activeCompute=nil;
 const bool gateTest=getenv("IMAGE_HEAP_BASELINE_GATE")!=nullptr;
 const bool allWrite=getenv("TEXEL_FIXTURE_ALL_WRITE_TABLE")!=nullptr;
 const char*report=argc>1?argv[1]:"/dev/null";std::ofstream raw(std::string(report)+".readback.jsonl");bool fetchFirst=argc<3||std::string(argv[2])=="fetch-first";
 try{
  need(argc==3,"output.json fetch-first|sample-first required");
  id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"Radeon Pro 5600M required");
  id<MTLCommandQueue>q=[d newCommandQueue];
  auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.hazardTrackingMode=MTLHazardTrackingModeTracked;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView;
  auto requirement=[d heapTextureSizeAndAlignWithDescriptor:td];NSUInteger step=(requirement.size+requirement.align-1)&~(requirement.align-1);
  auto hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;hd.type=MTLHeapTypePlacement;hd.size=(N+1)*step;
  id<MTLHeap>heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"private image heap failed");
  std::vector<id<MTLTexture>>textures,roots;
  for(unsigned i=0;i<T;++i){td.usage=i<BASE?MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView:i==N?MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite:MTLTextureUsageShaderRead;auto root=i<N?[heap newTextureWithDescriptor:td offset:i*step]:[d newTextureWithDescriptor:td];need(root!=nil,"image allocation failed");roots.push_back(root);auto t=i<BASE?[root newTextureViewWithPixelFormat:td.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)]:root;need(t!=nil,"native image view failed");textures.push_back(t);}
  need(textures[0].parentTexture==roots[0]&&textures[0].heap==heap,"actual native parent view absent");
  need(textures.back().heap==nil,"heapless precise exception required");
  need(!BufferHeapReadPlan::canPrepareSampledTexture(textures[0]),"additional image must not independently select a heap");
  need(!BufferHeapReadPlan::canPrepareSampledTexture(textures.back()),"heapless write-capable image stays precise");excluded=true;
  auto members=std::make_shared<MVKDescriptorUseCache::Resources>();MVKLiveList live;for(auto t:textures){if(gateTest&&t==textures[N-1])continue;members->push_back(t);live.add(t);}MVKDescriptorUseCache::Snapshot snapshot=members;
  auto lease=live.retainedSnapshot(snapshot);need(bool(lease),"owned shared-live snapshot lease unavailable");const auto&plan=lease->sampledTextureReadPlan();
  need(plan.baselineEligibleResourceCount(2)==BASE-(gateTest?1:0)&&plan.eligibleResourceCount(2)==N-(gateTest?1:0)&&plan.preciseResourceCount(2)==1,"fixture must produce 128 bulk children plus one precise heap-backed exception");
  need(plan.nilHeapResources.size()==1&&plan.nilHeapResources[0]==textures.back(),"precise exception bucket not exercised");
  id<MTLBuffer>upload=[d newBufferWithLength:T*256 options:MTLResourceStorageModeShared];
  for(unsigned i=0;i<T;++i)*reinterpret_cast<uint32_t*>(static_cast<char*>(upload.contents)+i*256)=color(i);
  auto cb=[q commandBuffer];auto blit=[cb blitCommandEncoder];for(unsigned i=0;i<T;++i)[blit copyFromBuffer:upload sourceOffset:i*256 sourceBytesPerRow:256 sourceBytesPerImage:256 sourceSize:MTLSizeMake(1,1,1) toTexture:roots[i] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[blit endEncoding];finish(cb);
  NSString*source=@"#include <metal_stdlib>\nusing namespace metal;struct A{array<texture2d<float>,257> t [[id(0)]];};struct V{float4 p [[position]];float4 c;};constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest);vertex V vp(uint i [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return{float4(p[i],0,1),float4(0)};}vertex V vs(uint i [[vertex_id]],constant A&a [[buffer(0)]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return{float4(p[i],0,1),a.t[0].read(uint2(0u))};}fragment float4 ff(V v [[stage_in]],constant A&a [[buffer(0)]]){return a.t[uint(v.p.x)].read(uint2(0u));}fragment float4 fs(V v [[stage_in]],constant A&a [[buffer(0)]]){return a.t[uint(v.p.x)].read(uint2(0u));}fragment float4 fm(V v [[stage_in]],constant A&a [[buffer(0)]]){return (a.t[uint(v.p.x)].read(uint2(0u))+v.c)*.5;}kernel void kw(texture2d<float,access::write>t [[texture(0)]]){t.write(float4(37.,89.,137.,255.)/255.,uint2(0u));}kernel void kr(constant A&a [[buffer(0)]],device uint*out [[buffer(1)]],uint i [[thread_position_in_grid]]){if(i<257){uint4 c=uint4(round(a.t[i].read(uint2(0u))*255.));out[i]=c.x|(c.y<<8)|(c.z<<16)|(c.w<<24);}}";
  NSError*err=nil;auto lib=[d newLibraryWithSource:source options:nil error:&err];need(lib!=nil,err.localizedDescription.UTF8String?:"MSL compile failed");
  auto ff=[lib newFunctionWithName:@"ff"],fs=[lib newFunctionWithName:@"fs"],fm=[lib newFunctionWithName:@"fm"],vp=[lib newFunctionWithName:@"vp"],vs=[lib newFunctionWithName:@"vs"],kw=[lib newFunctionWithName:@"kw"],kr=[lib newFunctionWithName:@"kr"];
  auto ae=[fs newArgumentEncoderWithBufferIndex:0];auto table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];for(unsigned i=0;i<T;++i)[ae setTexture:gateTest&&i==N-1?textures[N-2]:textures[i] atIndex:i];
  id<MTLRenderPipelineState>pso[3];for(unsigned i=0;i<3;++i){auto desc=[MTLRenderPipelineDescriptor new];desc.vertexFunction=i==2?vs:vp;desc.fragmentFunction=i==0?ff:i==1?fs:fm;desc.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;pso[i]=[d newRenderPipelineStateWithDescriptor:desc error:&err];need(pso[i]!=nil,err.localizedDescription.UTF8String?:"render PSO failed");[desc release];}
  auto wpso=[d newComputePipelineStateWithFunction:kw error:&err],rpso=[d newComputePipelineStateWithFunction:kr error:&err];need(wpso&&rpso,"compute PSO failed");
  auto outputDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:T height:H mipmapped:NO];outputDesc.storageMode=MTLStorageModePrivate;outputDesc.usage=MTLTextureUsageRenderTarget;auto target=[d newTextureWithDescriptor:outputDesc];need(target!=nil,"render target failed");auto pixels=[d newBufferWithLength:2048*H options:MTLResourceStorageModeShared];auto result=[d newBufferWithLength:T*4 options:MTLResourceStorageModeShared];auto result2=[d newBufferWithLength:T*4 options:MTLResourceStorageModeShared];
  MVKUseResourceHelper helper;helper.cacheLiveResources=true;helper.crossEncoderLiveCache=true;helper.batchLiveResources=true;helper.batchArgumentHeaps=true;helper.encoderHeapPlans=true;helper.encoderSampledHeapPlans=true;helper.resourceUseStats=true;helper.heapBatchThreshold=2;helper.descriptorSnapshotReuse=true;helper.crossEncoderSnapshotReuse=true;setup=true;helper.resetForEncoder();
  cb=[q commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;auto enc=[cb renderCommandEncoderWithDescriptor:pass];activeRender=enc;auto ledger=[TextureExceptionLedger new];ledger->native=enc;
  for(unsigned row=0;row<H;++row){bool sampled=row==2||((row==0)==!fetchFirst)||row==3;unsigned pipeline=row==2?2:sampled?1:0;
   if(row==2)helper.addLiveSnapshot(snapshot,live,(id<MTLCommandEncoder>)ledger,useOne,MVKResourceUsageStages::Vertex,false,false,true);
   helper.addLiveSnapshot(snapshot,live,(id<MTLCommandEncoder>)ledger,useOne,MVKResourceUsageStages::Fragment,false,false,true);
   applied=helper.statsHeapPlanResources;precise=helper.statsHeapPlanPreciseResources;
   helper.bindAndResetGraphics((id<MTLRenderCommandEncoder>)ledger);
   [enc setRenderPipelineState:pso[pipeline]];[enc setVertexBuffer:table offset:0 atIndex:0];[enc setFragmentBuffer:table offset:0 atIndex:0];[enc setScissorRect:MTLScissorRect{0,row,T,1}];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }
  auto*info=helper.used.findValue(textures.back());metadata=info&&info->heapKnown&&info->heap==textures.back().heap;
  [enc endEncoding];activeRender=nil;finish(cb);renderDone=true;renderHeaps=ledger->heaps;renderReads=ledger->reads;helper.resetForEncoder();
  cb=[q commandBuffer];blit=[cb blitCommandEncoder];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(T,H,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:2048 destinationBytesPerImage:2048*H];[blit endEncoding];finish(cb);
  for(unsigned row=0;row<H;++row)for(unsigned i=0;i<T;++i){uint32_t got=reinterpret_cast<uint32_t*>(static_cast<char*>(pixels.contents)+row*2048)[i],expected=color(gateTest&&i==N-1?N-2:i),other=color(0);for(unsigned c=0;c<4;++c){int exp=(expected>>(8*c))&255;if(row==2)exp=(exp+int((other>>(8*c))&255))/2;int delta=int((got>>(8*c))&255)-exp;if(delta<-1||delta>1){++mismatches;raw<<"{\"phase\":\"render\",\"row\":"<<row<<",\"index\":"<<i<<",\"component\":"<<c<<",\"gotPacked\":"<<got<<",\"expectedComponent\":"<<exp<<"}\n";}}++checked;}
  // New native encoder: write the precise heap-backed exception, then issue
  // an actual bulk heap read in the SAME compute encoder. Ledger must replay
  // that write after useHeaps, and the following GPU sample must see the write.
  cb=[q commandBuffer];auto ce=[cb computeCommandEncoder];activeCompute=ce;auto cl=[TextureExceptionLedger new];cl->native=ce;
  if(allWrite){helper.addLiveSnapshot(snapshot,live,(id<MTLCommandEncoder>)cl,useOne,MVKResourceUsageStages::Compute,true,false,true);helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)cl);need(cl->heaps==0,"write table must never become a readonly heap plan");}
  helper.add(textures.back(),MVKResourceUsageStages::Compute,true);helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)cl);[ce setComputePipelineState:wpso];[ce setTexture:textures.back() atIndex:0];[ce dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
  helper.add(textures[0],MVKResourceUsageStages::Compute,true);helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)cl);[ce setComputePipelineState:wpso];[ce setTexture:textures[0] atIndex:0];[ce dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
  id<MTLResource> firstWrite=textures[0];[ce memoryBarrierWithResources:&firstWrite count:1];
  id<MTLResource>barrierResource=textures.back();[ce memoryBarrierWithResources:&barrierResource count:1];
  helper.addLiveSnapshot(snapshot,live,(id<MTLCommandEncoder>)cl,useOne,MVKResourceUsageStages::Compute,false,false,true);helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)cl);
  [ce setComputePipelineState:rpso];[ce setBuffer:table offset:0 atIndex:0];[ce setBuffer:result offset:0 atIndex:1];[ce dispatchThreads:MTLSizeMake(T,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
  id<MTLResource> beforeSecondWrite=textures[1];[ce memoryBarrierWithResources:&beforeSecondWrite count:1];
  helper.add(textures[1],MVKResourceUsageStages::Compute,true);helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)cl);[ce setComputePipelineState:wpso];[ce setTexture:textures[1] atIndex:0];[ce dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];id<MTLResource> secondWrite=textures[1];[ce memoryBarrierWithResources:&secondWrite count:1];
  helper.addLiveSnapshot(snapshot,live,(id<MTLCommandEncoder>)cl,useOne,MVKResourceUsageStages::Compute,false,false,true);helper.bindAndResetCompute((id<MTLComputeCommandEncoder>)cl);[ce setComputePipelineState:rpso];[ce setBuffer:table offset:0 atIndex:0];[ce setBuffer:result2 offset:0 atIndex:1];[ce dispatchThreads:MTLSizeMake(T,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[ce endEncoding];activeCompute=nil;finish(cb);writeDone=true;
  computeHeaps=cl->heaps;computeWrites=cl->writes;computeWriteCalls=cl->writeCalls;applied+=helper.statsHeapPlanResources;precise+=helper.statsHeapPlanPreciseResources;helper.resetForEncoder();resetDone=true;
  for(unsigned i=0;i<T;++i){if(reinterpret_cast<uint32_t*>(result.contents)[i]!=(i==N||i==0?changed:color(gateTest&&i==N-1?N-2:i))){++mismatches;raw<<"{\"phase\":\"compute1\",\"index\":"<<i<<",\"got\":"<<reinterpret_cast<uint32_t*>(result.contents)[i]<<",\"expected\":"<<(i==N||i==0?changed:color(gateTest&&i==N-1?N-2:i))<<"}\n";}++checked;}
  for(unsigned i=0;i<T;++i){if(reinterpret_cast<uint32_t*>(result2.contents)[i]!=(i==N||i<2?changed:color(gateTest&&i==N-1?N-2:i))){++mismatches;raw<<"{\"phase\":\"compute2\",\"index\":"<<i<<",\"got\":"<<reinterpret_cast<uint32_t*>(result2.contents)[i]<<",\"expected\":"<<(i==N||i<2?changed:color(gateTest&&i==N-1?N-2:i))<<"}\n";}++checked;}
  need(metadata,"precise exception stored heap metadata does not match retained native resource");if(gateTest){need(renderHeaps==0&&computeHeaps==0&&applied==0,"additional images crossed the original 128-child admission gate");need(renderReads>=T-1,"gate rejection did not retain precise reads");need(computeWriteCalls>=3&&computeWrites>=3,"precise-only writes missing");}else{need(renderReads<=4,"eligible image views unexpectedly declared precisely");need(renderHeaps==2&&computeHeaps==1,"additional images changed the baseline heap declaration count");need(computeWriteCalls>=(allWrite?2u:4u)&&computeWrites>=(allWrite?T+N:4u),"write exception was not replayed after actual heap declaration");need(applied>=N*3,"sample plan/stage/reset applications missing");}need(!mismatches,"actual GPU readback mismatch");
  helper.resetForEncoder();
  for(auto t:textures)if(!gateTest||t!=textures[N-1])live.remove(t);
 }catch(const std::exception&e){error=e.what();if(activeRender)[activeRender endEncoding];if(activeCompute)[activeCompute endEncoding];}
 bool passed=error.empty()&&setup&&excluded&&metadata&&renderDone&&writeDone&&resetDone&&!mismatches;
 std::ofstream out(report);out<<"{\"passed\":"<<(passed?"true":"false")<<",\"order\":\""<<(fetchFirst?"fetch-first":"sample-first")<<"\",\"error\":\""<<error<<"\",\"requiredGPU\":\"Radeon Pro 5600M\",\"bulkEligibleTextureChildren\":"<<(N-(gateTest?1:0))<<",\"baselineEligibleTextureChildren\":"<<(BASE-(gateTest?1:0))<<",\"additionalImagesShareExistingHeap\":true,\"excludedSharedTextureChildren\":1,\"fixturePlanVerified\":"<<(setup?"true":"false")<<",\"excludedResourceVerified\":"<<(excluded?"true":"false")<<",\"exceptionHeapMetadataCorrect\":"<<(metadata?"true":"false")<<",\"renderGPUCompleted\":"<<(renderDone?"true":"false")<<",\"writeSampleGPUCompleted\":"<<(writeDone?"true":"false")<<",\"encoderResetExercised\":"<<(resetDone?"true":"false")<<",\"pixelsOrWordsChecked\":"<<checked<<",\"mismatches\":"<<mismatches<<",\"actualRenderHeapDeclarations\":"<<renderHeaps<<",\"actualRenderPreciseReadDeclarations\":"<<renderReads<<",\"actualComputeHeapDeclarations\":"<<computeHeaps<<",\"actualComputeWriteResources\":"<<computeWrites<<",\"actualComputeWriteCalls\":"<<computeWriteCalls<<",\"planAppliedChildren\":"<<applied<<",\"planPreciseChildren\":"<<precise<<",\"gameOperated\":false}\n";
 return passed?0:2;
}}
