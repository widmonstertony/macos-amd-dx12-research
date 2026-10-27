// Owned Metal oracle: argument-buffer texel views of actual heap-backed buffers.
// Compares precise declarations with heap-only readonly declarations, including
// writes through alias views. Does not attach to or operate a game.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <vector>
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
static void finish(id<MTLCommandBuffer> c){[c commit];[c waitUntilCompleted];need(c.status==MTLCommandBufferStatusCompleted,"GPU command failed");}
static uint32_t value(unsigned i){return i*2654435761u+101;}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"output required");constexpr unsigned N=128;
 const bool placement=getenv("TEXEL_FIXTURE_PLACEMENT"),shared=getenv("TEXEL_FIXTURE_SHARED"),cross=getenv("TEXEL_FIXTURE_CROSSFORMAT");
 const bool parentWrite=getenv("TEXEL_FIXTURE_PARENT_WRITE");
 id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;
 need(d!=nil,"Radeon Pro 5600M required");auto q=[d newCommandQueue];
 NSUInteger length=std::max(NSUInteger(256),[d minimumTextureBufferAlignmentForPixelFormat:MTLPixelFormatR32Uint]);
 MTLResourceOptions opts=MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeTracked;
 NSUInteger backingLength=shared?length*N:length;auto req=[d heapBufferSizeAndAlignWithLength:backingLength options:opts];auto hd=[MTLHeapDescriptor new];
 hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;
 hd.type=placement?MTLHeapTypePlacement:MTLHeapTypeAutomatic;NSUInteger step=(req.size+req.align-1)&~(req.align-1);hd.size=(shared?2:N+2)*step;auto heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"heap failed");
 std::vector<id<MTLBuffer>>buffers;std::vector<id<MTLTexture>>textures;std::vector<NSUInteger> offsets;
 auto td=[MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:64 resourceOptions:opts usage:MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite];
 for(unsigned i=0;i<N;++i){id<MTLBuffer>b=shared&&i?buffers[0]:placement?[heap newBufferWithLength:backingLength options:opts offset:i*step]:[heap newBufferWithLength:backingLength options:opts];need(b!=nil,"buffer failed");NSUInteger offset=shared?i*length:0;offsets.push_back(offset);auto t=[b newTextureWithDescriptor:td offset:offset bytesPerRow:length];need(t!=nil,"texel view failed");need(t.buffer==b&&t.textureType==MTLTextureTypeTextureBuffer,"actual buffer texture required");need(t.heap==heap&&t.buffer.heap==heap,"texture and parent heap identity must agree");buffers.push_back(b);textures.push_back(t);}
 if(cross)td.pixelFormat=MTLPixelFormatR32Float;std::vector<id<MTLTexture>>writeViews;std::vector<id<MTLBuffer>>parents;for(unsigned i=0;i<N;++i){auto v=[buffers[i] newTextureWithDescriptor:td offset:offsets[i] bytesPerRow:length];need(v&&v!=textures[i]&&v.buffer==buffers[i],"distinct same-storage write view required");writeViews.push_back(v);if(std::find(parents.begin(),parents.end(),buffers[i])==parents.end())parents.push_back(buffers[i]);}
 auto seed=[d newBufferWithLength:length*N options:MTLResourceStorageModeShared];
 for(unsigned i=0;i<N;++i)for(unsigned j=0;j<length/4;++j)((uint32_t*)((char*)seed.contents+i*length))[j]=value(i);
 auto reset=[&]{auto cb=[q commandBuffer];auto e=[cb blitCommandEncoder];for(unsigned i=0;i<N;++i)[e copyFromBuffer:seed sourceOffset:i*length toBuffer:buffers[i] destinationOffset:offsets[i] size:length];[e endEncoding];finish(cb);};
 NSString*src=@"#include <metal_stdlib>\nusing namespace metal;struct A{array<texture_buffer<uint,access::read>,128> t [[id(0)]];};kernel void kr(constant A&a [[buffer(0)]],device uint*o [[buffer(1)]],uint i [[thread_position_in_grid]]){o[i]=a.t[i].read(0u).x;}struct W{array<texture_buffer<uint,access::write>,128>t [[id(0)]];};kernel void kw(constant W&a [[buffer(0)]],constant uint&v [[buffer(1)]],uint i [[thread_position_in_grid]]){a.t[i].write(uint4(v+i,0,0,0),0u);}struct V{float4 p [[position]];uint v [[flat]];};vertex V vs(uint i [[vertex_id]],constant A&a [[buffer(0)]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return{float4(p[i],0,1),a.t[0].read(0u).x};}fragment uint fs(V v [[stage_in]],constant A&a [[buffer(0)]]){return a.t[uint(v.p.x)].read(0u).x^v.v;}";
 if(cross){src=[src stringByReplacingOccurrencesOfString:@"texture_buffer<uint,access::write>" withString:@"texture_buffer<float,access::write>"];src=[src stringByReplacingOccurrencesOfString:@"t[i].write(uint4(v+i,0,0,0),0u)" withString:@"t[i].write(float4(as_type<float>(v+i),0,0,0),0u)"];}
 NSError*error=nil;auto lib=[d newLibraryWithSource:src options:nil error:&error];need(lib!=nil,error.localizedDescription.UTF8String?:"MSL compile failed");
 auto kr=[lib newFunctionWithName:@"kr"],kw=[lib newFunctionWithName:@"kw"],vs=[lib newFunctionWithName:@"vs"],fs=[lib newFunctionWithName:@"fs"];
 auto readPSO=[d newComputePipelineStateWithFunction:kr error:&error],writePSO=[d newComputePipelineStateWithFunction:kw error:&error];need(readPSO&&writePSO,"compute PSO failed");
 auto pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=vs;pd.fragmentFunction=fs;pd.colorAttachments[0].pixelFormat=MTLPixelFormatR32Uint;auto renderPSO=[d newRenderPipelineStateWithDescriptor:pd error:&error];need(renderPSO!=nil,error.localizedDescription.UTF8String?:"render PSO failed");
 auto ae=[kr newArgumentEncoderWithBufferIndex:0];auto table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];for(unsigned i=0;i<N;++i)[ae setTexture:textures[i] atIndex:i];
 auto wae=[kw newArgumentEncoderWithBufferIndex:0];auto wtable=[d newBufferWithLength:wae.encodedLength options:MTLResourceStorageModeShared];[wae setArgumentBuffer:wtable offset:0];for(unsigned i=0;i<N;++i)[wae setTexture:writeViews[i] atIndex:i];
 auto output=[d newBufferWithLength:N*4 options:MTLResourceStorageModeShared];auto pixels=[d newBufferWithLength:N*4 options:MTLResourceStorageModeShared];
 auto targetDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:N height:1 mipmapped:NO];targetDesc.storageMode=MTLStorageModePrivate;targetDesc.usage=MTLTextureUsageRenderTarget;auto target=[d newTextureWithDescriptor:targetDesc];need(target!=nil,"target failed");
 unsigned checked=0,mismatch=0;std::ofstream report(argv[1]);report<<"{\"placement\":"<<(placement?"true":"false")<<",\"sharedParent\":"<<(shared?"true":"false")<<",\"crossFormatAlias\":"<<(cross?"true":"false")<<",\"cases\":[";unsigned cases=0;
 for(unsigned mode=0;mode<2;++mode)for(unsigned write=0;write<2;++write){
  reset();memset(output.contents,0,N*4);uint32_t changed=0x319b72e5;
  auto cb=[q commandBuffer];auto e=[cb computeCommandEncoder];
  if(write){[e useResources:parentWrite?(const id<MTLResource>*)parents.data():(const id<MTLResource>*)writeViews.data() count:parentWrite?parents.size():writeViews.size() usage:MTLResourceUsageRead|MTLResourceUsageWrite];[e setComputePipelineState:writePSO];[e setBuffer:wtable offset:0 atIndex:0];[e setBytes:&changed length:4 atIndex:1];[e dispatchThreads:MTLSizeMake(N,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];[e memoryBarrierWithScope:MTLBarrierScopeBuffers|MTLBarrierScopeTextures];}
  auto start=std::chrono::steady_clock::now();
  if(mode)[e useHeap:heap];else [e useResources:parentWrite?(const id<MTLResource>*)parents.data():(const id<MTLResource>*)textures.data() count:parentWrite?parents.size():N usage:MTLResourceUsageRead];
  // Preserve prior write usage across a heap readonly declaration. This tests
  // writes through a different view of the same physical allocation.
  if(write)[e useResources:parentWrite?(const id<MTLResource>*)parents.data():(const id<MTLResource>*)writeViews.data() count:parentWrite?parents.size():writeViews.size() usage:MTLResourceUsageRead|MTLResourceUsageWrite];
  double decl=std::chrono::duration<double,std::micro>(std::chrono::steady_clock::now()-start).count();
  [e setComputePipelineState:readPSO];[e setBuffer:table offset:0 atIndex:0];[e setBuffer:output offset:0 atIndex:1];[e dispatchThreads:MTLSizeMake(N,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];[e endEncoding];finish(cb);
  unsigned before=mismatch;for(unsigned i=0;i<N;++i){if(((uint32_t*)output.contents)[i]!=(write?changed+i:value(i)))++mismatch;++checked;}
  cb=[q commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;auto re=[cb renderCommandEncoderWithDescriptor:pass];
  if(mode)[re useHeap:heap stages:MTLRenderStageVertex|MTLRenderStageFragment];else [re useResources:parentWrite?(const id<MTLResource>*)parents.data():(const id<MTLResource>*)textures.data() count:parentWrite?parents.size():N usage:MTLResourceUsageRead stages:MTLRenderStageVertex|MTLRenderStageFragment];
  [re setRenderPipelineState:renderPSO];[re setVertexBuffer:table offset:0 atIndex:0];[re setFragmentBuffer:table offset:0 atIndex:0];[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[re endEncoding];auto blit=[cb blitCommandEncoder];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(N,1,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:N*4 destinationBytesPerImage:N*4];[blit endEncoding];finish(cb);
  for(unsigned i=0;i<N;++i){uint32_t v=write?changed+i:value(i),v0=write?changed:value(0);if(((uint32_t*)pixels.contents)[i]!=(v^v0))++mismatch;++checked;}
  report<<(cases++?",":"")<<"{\"mode\":\""<<(mode?"heap-only":"precise")<<"\",\"aliasWrite\":"<<(write?"true":"false")<<",\"computeDeclarationUS\":"<<decl<<",\"checkedWords\":256,\"mismatches\":"<<mismatch-before<<"}";
 }
 report<<"],\"parentBufferWriteDeclaration\":"<<(parentWrite?"true":"false")<<",\"indirectWritableViews\":128,\"uniqueParentBuffers\":"<<parents.size()<<",\"passed\":"<<(mismatch?"false":"true")<<",\"totalCheckedWords\":"<<checked<<",\"mismatches\":"<<mismatch<<",\"actualBufferViews\":128,\"textureHeapMatchesParent\":true,\"gameOperated\":false}\n";return mismatch?3:0;
}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
