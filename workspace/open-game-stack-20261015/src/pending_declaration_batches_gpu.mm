// Real GPU regression: a previous flush must not invalidate a new batch's slot.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <stdexcept>
static void need(bool b,const char* m){if(!b)throw std::runtime_error(m);}
@interface BatchLedger:NSObject {
@public id<MTLRenderCommandEncoder> native;id<MTLResource> expectedRead,expectedWrite;bool sawRead,sawWrite;NSUInteger count;
}
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)n usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages;
@end
@implementation BatchLedger
- (void)useResources:(const id<MTLResource>[])items count:(NSUInteger)n usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {
 count+=n;for(NSUInteger i=0;i<n;i++){if(items[i]==expectedRead&&(usage&MTLResourceUsageRead)&&(stages&MTLRenderStageVertex))sawRead=true;if(items[i]==expectedWrite&&(usage&MTLResourceUsageWrite)&&(stages&MTLRenderStageFragment))sawWrite=true;}
 [native useResources:items count:n usage:usage stages:stages];
}
@end
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report required");id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");
 NSString*msl=@"#include <metal_stdlib>\nusing namespace metal;struct A{device uint*value [[id(0)]];};struct V{float4 p [[position]];uint v [[flat]];};vertex V vs(uint id [[vertex_id]],constant A&a [[buffer(0)]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return{float4(p[id],0,1),*a.value};}fragment float4 first(V in [[stage_in]]){return in.v==1?float4(0,1,0,1):float4(1,0,0,1);}fragment float4 second(V in [[stage_in]],constant A&a [[buffer(0)]]){atomic_fetch_add_explicit((device atomic_uint*)a.value,1u,memory_order_relaxed);return in.v==2?float4(0,1,0,1):float4(1,0,0,1);}";
 NSError*err=nil;id<MTLLibrary>lib=[d newLibraryWithSource:msl options:nil error:&err];need(lib!=nil,err.localizedDescription.UTF8String?:"compile failed");id<MTLFunction>vs=[lib newFunctionWithName:@"vs"],first=[lib newFunctionWithName:@"first"],second=[lib newFunctionWithName:@"second"];
 MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=vs;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;pd.fragmentFunction=first;id<MTLRenderPipelineState>p1=[d newRenderPipelineStateWithDescriptor:pd error:&err];pd.fragmentFunction=second;id<MTLRenderPipelineState>p2=[d newRenderPipelineStateWithDescriptor:pd error:&err];need(p1&&p2,"pipeline failed");
 id<MTLBuffer>a=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],b=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],out=[d newBufferWithLength:2048 options:MTLResourceStorageModeShared];id<MTLArgumentEncoder>ae=[vs newArgumentEncoderWithBufferIndex:0];id<MTLBuffer>ta=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared],tb=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:ta offset:0];[ae setBuffer:a offset:0 atIndex:0];[ae setArgumentBuffer:tb offset:0];[ae setBuffer:b offset:0 atIndex:0];
 MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture>target=[d newTextureWithDescriptor:td];id<MTLCommandQueue>queue=[d newCommandQueue];unsigned cases=1;
#ifdef MVK_PENDING_BATCH_CONTROL
 cases=2;
#endif
 unsigned mismatches=0;uint64_t declarations=0;
 for(unsigned mode=0;mode<cases;mode++){
  *(uint32_t*)a.contents=1;*(uint32_t*)b.contents=2;id<MTLCommandBuffer>cb=[queue commandBuffer];MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=target;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLRenderCommandEncoder>enc=[cb renderCommandEncoderWithDescriptor:rp];BatchLedger*ledger=[BatchLedger new];ledger->native=enc;
  {MVKUseResourceHelper h;h.batchArgumentHeaps=false;
#ifdef MVK_PENDING_BATCH_CONTROL
   if(mode)h.pendingBatchGeneration=UINT64_MAX;
#endif
   h.add(a,MVKResourceUsageStages::Vertex,false);h.bindAndResetGraphics((id<MTLRenderCommandEncoder>)ledger);[enc setRenderPipelineState:p1];[enc setVertexBuffer:ta offset:0 atIndex:0];[enc setScissorRect:MTLScissorRect{0,0,4,8}];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];id<MTLResource>barrier[]={a};[enc memoryBarrierWithResources:barrier count:1 afterStages:MTLRenderStageVertex beforeStages:MTLRenderStageFragment];
   // B reuses slot zero after flush. Upgrading A must not tombstone B.
   ledger->expectedRead=b;ledger->expectedWrite=a;h.add(b,MVKResourceUsageStages::Vertex,false);h.add(a,MVKResourceUsageStages::Fragment,true);h.bindAndResetGraphics((id<MTLRenderCommandEncoder>)ledger);need(ledger->sawRead&&ledger->sawWrite,"stale pending index discarded a current-batch declaration");[enc setRenderPipelineState:p2];[enc setVertexBuffer:tb offset:0 atIndex:0];[enc setFragmentBuffer:ta offset:0 atIndex:0];[enc setScissorRect:MTLScissorRect{4,0,4,8}];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];declarations+=ledger->count;
  }
  [enc endEncoding];id<MTLBlitCommandEncoder>blit=[cb blitCommandEncoder];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];[blit endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"GPU failed");if(*(uint32_t*)a.contents!=33)++mismatches;if(*(uint32_t*)b.contents!=2)++mismatches;for(unsigned y=0;y<8;y++)for(unsigned x=0;x<8;x++)if(((uint32_t*)((char*)out.contents+y*256))[x]!=0xff00ff00u)++mismatches;[ledger release];
 }
 std::ofstream report(argv[1]);report<<"{\"passed\":"<<(mismatches?"false":"true")<<",\"GPUValuesChecked\":"<<cases*66<<",\"mismatches\":"<<mismatches<<",\"sameEncoderFlushes\":"<<cases*2<<",\"batchSerialWrapChecked\":"<<(cases==2?"true":"false")<<",\"actualNativeDeclarations\":"<<declarations<<",\"requiredReadAndWriteIdentitiesVerified\":true}\n";
 [queue release];[target release];[ta release];[tb release];[ae release];[out release];[a release];[b release];[p1 release];[p2 release];[pd release];[vs release];[first release];[second release];[lib release];return mismatches?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
