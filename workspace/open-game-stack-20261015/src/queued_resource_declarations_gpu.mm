// Acyclic copy -> graphics -> compute -> graphics chain with indirect writes.
// Uses the actual MoltenVK declaration helper and reads back GPU results.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <stdexcept>
#include <vector>
static void need(bool b,const char* m){if(!b)throw std::runtime_error(m);}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report required");id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");
 NSString*source=@"#include <metal_stdlib>\nusing namespace metal;struct A{device atomic_uint*value [[id(0)]];};struct V{float4 p [[position]];};vertex V vs(uint id [[vertex_id]],constant A&a [[buffer(0)]]){if(id==0)atomic_fetch_add_explicit(a.value,1u,memory_order_relaxed);float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return{float4(p[id],0,1)};}fragment float4 fs(constant A&a [[buffer(0)]]){atomic_fetch_add_explicit(a.value,1u,memory_order_relaxed);return float4(0,1,0,1);}kernel void cs(constant A&a [[buffer(0)]]){atomic_fetch_add_explicit(a.value,1u,memory_order_relaxed);}";
 NSError*err=nil;id<MTLLibrary>lib=[d newLibraryWithSource:source options:nil error:&err];need(lib!=nil,err.localizedDescription.UTF8String?:"compile failed");
 id<MTLFunction>vs=[lib newFunctionWithName:@"vs"],fs=[lib newFunctionWithName:@"fs"],cs=[lib newFunctionWithName:@"cs"];
 MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=vs;pd.fragmentFunction=fs;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;id<MTLRenderPipelineState>rp=[d newRenderPipelineStateWithDescriptor:pd error:&err];id<MTLComputePipelineState>cp=[d newComputePipelineStateWithFunction:cs error:&err];need(rp&&cp,"pipeline failed");
 id<MTLCommandQueue>g=[d newCommandQueue],c=[d newCommandQueue],t=[d newCommandQueue];need(g&&c&&t&&g!=c&&c!=t&&t!=g,"three independent queues required");
 id<MTLSharedEvent>copyEvent=[d newSharedEvent],graphicsEvent=[d newSharedEvent],computeEvent=[d newSharedEvent];
 MTLHeapDescriptor*hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;hd.size=4*1024*1024;id<MTLHeap>heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"tracked heap failed");
 constexpr unsigned frames=16,passes=33;std::vector<id<MTLCommandBuffer>>buffers;std::vector<id<MTLBuffer>>owned;std::vector<id<MTLTexture>>textures;std::vector<id<MTLBuffer>>results;
 id<MTLArgumentEncoder>ae=[vs newArgumentEncoderWithBufferIndex:0];
 for(unsigned frame=0;frame<frames;frame++){
  id<MTLBuffer>value=[heap newBufferWithLength:256 options:MTLResourceStorageModePrivate],other=[heap newBufferWithLength:256 options:MTLResourceStorageModePrivate],result=[d newBufferWithLength:2304 options:MTLResourceStorageModeShared];need(value&&other&&result,"allocation failed");owned.push_back(value);owned.push_back(other);owned.push_back(result);results.push_back(result);
  id<MTLBuffer>table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared],otherTable=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];owned.push_back(table);owned.push_back(otherTable);[ae setArgumentBuffer:table offset:0];[ae setBuffer:value offset:0 atIndex:0];[ae setArgumentBuffer:otherTable offset:0];[ae setBuffer:other offset:0 atIndex:0];
  MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture>target=[d newTextureWithDescriptor:td],otherTarget=[d newTextureWithDescriptor:td];textures.push_back(target);textures.push_back(otherTarget);
  auto submit=[&](id<MTLCommandBuffer>b){need(b!=nil,"command buffer failed");[b retain];buffers.push_back(b);[b commit];};
  id<MTLCommandBuffer>init=[t commandBuffer];id<MTLBlitCommandEncoder>blit=[init blitCommandEncoder];[blit fillBuffer:value range:NSMakeRange(0,256) value:0];[blit fillBuffer:other range:NSMakeRange(0,256) value:0];[blit endEncoding];[init encodeSignalEvent:copyEvent value:frame+1];submit(init);
  id<MTLCommandBuffer>draw=[g commandBuffer];[draw enqueue];[draw encodeWaitForEvent:copyEvent value:frame+1];MVKUseResourceHelper graphicsHelper;
  auto render=[&](id<MTLCommandBuffer>b,id<MTLBuffer>v,id<MTLBuffer>tab,id<MTLTexture>targetTexture,MVKUseResourceHelper&h){
   MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=targetTexture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLRenderCommandEncoder>enc=[b renderCommandEncoderWithDescriptor:pass];need(enc!=nil,"render encoder failed");h.resetForEncoder();h.add(v,MVKResourceUsageStages::Vertex,false);h.add(v,MVKResourceUsageStages::Fragment,false);h.add(v,MVKResourceUsageStages::Vertex,true);h.add(v,MVKResourceUsageStages::Fragment,true);h.bindAndResetGraphics(enc);[enc setRenderPipelineState:rp];[enc setVertexBuffer:tab offset:0 atIndex:0];[enc setFragmentBuffer:tab offset:0 atIndex:0];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];
  };
  for(unsigned pass=0;pass<passes;pass++)render(draw,value,table,target,graphicsHelper);[draw encodeSignalEvent:graphicsEvent value:frame*3+1];submit(draw);
  // The compute consumer is committed before an independent later graphics batch.
  // There is no forward wait or cycle in this schedule.
  id<MTLCommandBuffer>compute=[c commandBuffer];[compute enqueue];[compute encodeWaitForEvent:graphicsEvent value:frame*3+1];id<MTLComputeCommandEncoder>ce=[compute computeCommandEncoder];MVKUseResourceHelper computeHelper;computeHelper.add(value,MVKResourceUsageStages::Compute,false);computeHelper.add(value,MVKResourceUsageStages::Compute,true);computeHelper.bindAndResetCompute(ce);[ce setComputePipelineState:cp];[ce setBuffer:table offset:0 atIndex:0];[ce dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[ce endEncoding];[compute encodeSignalEvent:computeEvent value:frame+1];submit(compute);
  id<MTLCommandBuffer>independent=[g commandBuffer];[independent enqueue];MVKUseResourceHelper independentHelper;render(independent,other,otherTable,otherTarget,independentHelper);[independent encodeSignalEvent:graphicsEvent value:frame*3+2];submit(independent);
  id<MTLCommandBuffer>read=[g commandBuffer];[read enqueue];[read encodeWaitForEvent:computeEvent value:frame+1];blit=[read blitCommandEncoder];[blit copyFromBuffer:value sourceOffset:0 toBuffer:result destinationOffset:2048 size:4];[blit copyFromBuffer:other sourceOffset:0 toBuffer:result destinationOffset:2052 size:4];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:result destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];[blit endEncoding];[read encodeSignalEvent:graphicsEvent value:frame*3+3];submit(read);
 }
 // A failing test must not queue additional work after a driver timeout.
 unsigned failures=0,mismatches=0;for(id<MTLCommandBuffer>b:buffers){[b waitUntilCompleted];if(b.status!=MTLCommandBufferStatusCompleted){++failures;fprintf(stderr,"GPU error: %s\n",b.error.localizedDescription.UTF8String);}}
 for(id<MTLBuffer>result:results){const char*p=(const char*)result.contents;if(*(const uint32_t*)(p+2048)!=passes*65+1)++mismatches;if(*(const uint32_t*)(p+2052)!=65)++mismatches;for(unsigned y=0;y<8;y++)for(unsigned x=0;x<8;x++)if(((const uint32_t*)(p+y*256))[x]!=0xff00ff00u)++mismatches;}
 std::ofstream out(argv[1]);out<<"{\"passed\":"<<(!failures&&!mismatches?"true":"false")<<",\"independentQueues\":3,\"frames\":"<<frames<<",\"renderEncoders\":"<<frames*(passes+1)<<",\"commandBuffers\":"<<buffers.size()<<",\"GPUValuesChecked\":"<<frames*66<<",\"mismatches\":"<<mismatches<<",\"commandBufferFailures\":"<<failures<<",\"trackedHeap\":true,\"acyclicTimelineChain\":true}\n";
 for(auto b:buffers)[b release];for(auto b:owned)[b release];for(auto tex:textures)[tex release];[ae release];[heap release];[hd release];[copyEvent release];[graphicsEvent release];[computeEvent release];[g release];[c release];[t release];[rp release];[cp release];[pd release];[vs release];[fs release];[cs release];[lib release];return failures||mismatches?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
