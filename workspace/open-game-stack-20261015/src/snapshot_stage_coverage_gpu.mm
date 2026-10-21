// Real AMD indirect graphics writes plus per-stage/access cache coverage.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <chrono>
#include <fstream>
#include <stdexcept>
#include <cstring>
static void need(bool b,const char* m){if(!b)throw std::runtime_error(m);}
static void immediate(id<MTLCommandEncoder> e,id<MTLResource> r,MTLResourceUsage u,MVKResourceUsageStages s){
 MTLRenderStages stages=s==MVKResourceUsageStages::Vertex?MTLRenderStageVertex:s==MVKResourceUsageStages::Fragment?MTLRenderStageFragment:MTLRenderStageVertex|MTLRenderStageFragment;
 [(id<MTLRenderCommandEncoder>)e useResource:r usage:u stages:stages];
}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2 || argc==3,"report path and optional baseline required");bool baseline=argc==3;
 id<MTLDevice> device=nil;for(id<MTLDevice>d in MTLCopyAllDevices())if([d.name containsString:@"5600M"]){device=[d retain];break;}need(device!=nil,"5600M required");
 NSError* error=nil;NSString* source=@"#include <metal_stdlib>\nusing namespace metal;struct Args{device atomic_uint* value [[id(0)]];};struct V{float4 p [[position]];};vertex V vs(uint id [[vertex_id]],constant Args& a [[buffer(0)]]){if(id==0)atomic_fetch_add_explicit(a.value,1u,memory_order_relaxed);float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return{float4(p[id],0,1)};}fragment float4 fs(constant Args& a [[buffer(0)]]){atomic_fetch_add_explicit(a.value,1u,memory_order_relaxed);return float4(0,1,0,1);}";
 id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];need(lib!=nil,error.localizedDescription.UTF8String?:"library failed");
 id<MTLFunction> vs=[lib newFunctionWithName:@"vs"],fs=[lib newFunctionWithName:@"fs"];
 MTLRenderPipelineDescriptor* pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=vs;pd.fragmentFunction=fs;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
 id<MTLRenderPipelineState> pipe=[device newRenderPipelineStateWithDescriptor:pd error:&error];need(pipe!=nil,error.localizedDescription.UTF8String?:"pipeline failed");
 id<MTLBuffer> input=[device newBufferWithLength:256 options:MTLResourceStorageModeShared],next=[device newBufferWithLength:256 options:MTLResourceStorageModeShared],readback=[device newBufferWithLength:2048 options:MTLResourceStorageModeShared];*(uint32_t*)input.contents=0;*(uint32_t*)next.contents=0;
 id<MTLArgumentEncoder> ae=[vs newArgumentEncoderWithBufferIndex:0];id<MTLBuffer> table=[device newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];
 MTLTextureDescriptor* td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture> target=[device newTextureWithDescriptor:td];need(target!=nil,"texture failed");
 id<MTLCommandQueue> queue=[device newCommandQueue];MVKLiveList live;live.add(input);
 auto values=std::make_shared<MVKDescriptorUseCache::Resources>();for(uintptr_t i=1;i<=4096;i++)values->push_back((id<MTLResource>)(0x100000+i*64));values->push_back(input);values->push_back(next);MVKDescriptorUseCache::Snapshot snapshot=values;
 uint64_t coldWords=0,lookups=0,mismatches=0,registrationLookups=0;MVKUseResourceHelper h;need(h.crossEncoderSnapshotReuse,"qualified reuse required");
 for(unsigned pass=0;pass<4;pass++){
  id<MTLCommandBuffer> cb=[queue commandBuffer];MTLRenderPassDescriptor* rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=target;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];h.resetForEncoder();
  h.addLiveSnapshot(snapshot,live,enc,immediate,MVKResourceUsageStages::Vertex,false);
  if(pass==2)live.add(next); // Must invalidate a previous absent identity mid-encoder.
  uint64_t before=h.statsLookups;
  h.addLiveSnapshot(snapshot,live,enc,immediate,MVKResourceUsageStages::Fragment,false);
  if(pass==2){registrationLookups=h.statsLookups-before;need(registrationLookups>4000,"late registration did not force full validation");}
  h.addLiveSnapshot(snapshot,live,enc,immediate,MVKResourceUsageStages::Vertex,true);
  h.addLiveSnapshot(snapshot,live,enc,immediate,MVKResourceUsageStages::Fragment,true);
  id<MTLBuffer> active=pass<2?input:next;auto it=h.used.find(active);need(it!=h.used.end()&&it->second.generation==h.encoderGeneration&&it->second.write&&it->second.stages==MVKResourceUsageStages::All,"per-encoder stage/write upgrade missing");
  auto repeatBefore=h.statsCalls;for(unsigned k=0;k<8;k++){h.addLiveSnapshot(snapshot,live,enc,immediate,MVKResourceUsageStages::Vertex,false);h.addLiveSnapshot(snapshot,live,enc,immediate,MVKResourceUsageStages::Fragment,true);}if(!baseline)need(h.statsCalls==repeatBefore,"covered access rescanned table");
  coldWords+=h.statsSnapshotColdWords;lookups+=h.statsLookups;h.bindAndResetGraphics(enc);[ae setBuffer:active offset:0 atIndex:0];[enc setRenderPipelineState:pipe];[enc setVertexBuffer:table offset:0 atIndex:0];[enc setFragmentBuffer:table offset:0 atIndex:0];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];
  id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];[blit endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"GPU failed");
  if(*(uint32_t*)active.contents!=(pass%2+1)*65)++mismatches;for(unsigned y=0;y<8;y++)for(unsigned x=0;x<8;x++)if(((uint32_t*)((char*)readback.contents+y*256))[x]!=0xff00ff00u)++mismatches;
 }
 uint64_t benchCold=0;double benchMS=0;{MVKUseResourceHelper bench;MVKLiveList empty;auto start=std::chrono::steady_clock::now();for(unsigned iteration=0;iteration<32;iteration++){auto tableCopy=std::make_shared<MVKDescriptorUseCache::Resources>(*values);bench.resetForEncoder();for(auto stage:{MVKResourceUsageStages::Vertex,MVKResourceUsageStages::Fragment})for(bool write:{false,true})bench.addLiveSnapshot(tableCopy,empty,nil,immediate,stage,write);benchCold+=bench.statsSnapshotColdWords;}benchMS=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();}
 std::ofstream out(argv[1]);out<<"{\"passed\":"<<(mismatches?"false":"true")<<",\"baseline\":"<<(baseline?"true":"false")<<",\"GPUValuesChecked\":260,\"mismatches\":"<<mismatches<<",\"coldWords\":"<<coldWords<<",\"liveLookups\":"<<lookups<<",\"registrationFallbackLiveLookups\":"<<registrationLookups<<",\"CPUControlColdWords\":"<<benchCold<<",\"CPUControlMilliseconds\":"<<benchMS<<",\"newEncoderAndStageAndWriteDeclarationsChecked\":true}\n";
 live.remove(input);live.remove(next);[queue release];[target release];[table release];[ae release];[readback release];[input release];[next release];[pipe release];[pd release];[vs release];[fs release];[lib release];[device release];return mismatches?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
