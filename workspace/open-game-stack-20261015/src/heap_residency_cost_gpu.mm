// Measure native residency declarations, with identical real GPU work/readback.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <fstream>
#include <stdexcept>
#include <vector>
static void need(bool x,const char*s){if(!x)throw std::runtime_error(s);}
static void finish(id<MTLCommandBuffer>b){[b commit];[b waitUntilCompleted];need(b.status==MTLCommandBufferStatusCompleted,"GPU command failed");}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report path required");id<MTLDevice>d=nil;
 for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;
 need(d!=nil,"Radeon Pro 5600M required");constexpr unsigned N=2048,B=8,G=N/B;
 MTLResourceOptions opts=MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeTracked;
 MTLHeapDescriptor*hd=[MTLHeapDescriptor new];hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeTracked;
 auto req=[d heapBufferSizeAndAlignWithLength:256 options:opts];hd.size=N*((req.size+req.align-1)&~(req.align-1));
 id<MTLHeap>heap=[d newHeapWithDescriptor:hd];need(heap!=nil,"heap failed");
 std::vector<id<MTLResource>>rs;for(unsigned i=0;i<N;++i){auto b=[heap newBufferWithLength:256 options:opts];need(b!=nil,"child failed");rs.push_back(b);}
 id<MTLBuffer>seed=[d newBufferWithLength:N*256 options:MTLResourceStorageModeShared];
 for(unsigned i=0;i<N*64;++i)((uint32_t*)seed.contents)[i]=i/64+1;
 id<MTLCommandQueue>q=[d newCommandQueue];auto init=[q commandBuffer];auto blit=[init blitCommandEncoder];
 for(unsigned i=0;i<N;++i)[blit copyFromBuffer:seed sourceOffset:i*256 toBuffer:(id<MTLBuffer>)rs[i] destinationOffset:0 size:256];[blit endEncoding];finish(init);
 NSString*msl=@"#include <metal_stdlib>\nusing namespace metal;struct A{array<device const uint*,2048> r [[id(0)]];};kernel void k(constant A&a [[buffer(0)]],device uint*out [[buffer(1)]],constant uint&base [[buffer(2)]],uint i [[thread_position_in_grid]]){out[base+i]=*a.r[base+i];}";
 NSError*err=nil;auto lib=[d newLibraryWithSource:msl options:nil error:&err];need(lib!=nil,err.localizedDescription.UTF8String?:"compile failed");auto fn=[lib newFunctionWithName:@"k"];
 auto ps=[d newComputePipelineStateWithFunction:fn error:&err];need(ps!=nil,"pipeline failed");auto ae=[fn newArgumentEncoderWithBufferIndex:0];auto table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];
 for(unsigned i=0;i<N;++i)[ae setBuffer:(id<MTLBuffer>)rs[i] offset:0 atIndex:i];auto out=[d newBufferWithLength:N*4 options:MTLResourceStorageModeShared];
 std::ofstream report(argv[1]);report<<"{\"device\":\""<<d.name.UTF8String<<"\",\"heapChildren\":"<<N<<",\"groups\":"<<G<<",\"cases\":[";
 unsigned row=0,mismatch=0;
 for(unsigned round=0;round<6;++round)for(unsigned mode=0;mode<3;++mode){
  memset(out.contents,0,N*4);auto cb=[q commandBuffer];auto enc=[cb computeCommandEncoder];[enc setComputePipelineState:ps];[enc setBuffer:table offset:0 atIndex:0];[enc setBuffer:out offset:0 atIndex:1];
  double declMS=0;auto start=std::chrono::steady_clock::now();
  for(unsigned g=0;g<G;++g){unsigned base=g*B;auto ds=std::chrono::steady_clock::now();
   if(mode==0 || (mode==1&&g==0))[enc useHeap:heap];else [enc useResources:rs.data()+base count:B usage:MTLResourceUsageRead];
   declMS+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-ds).count();
   [enc setBytes:&base length:4 atIndex:2];[enc dispatchThreads:MTLSizeMake(B,1,1) threadsPerThreadgroup:MTLSizeMake(B,1,1)];
  }
  [enc endEncoding];double hostMS=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();finish(cb);
  for(unsigned i=0;i<N;++i)if(((uint32_t*)out.contents)[i]!=i+1)++mismatch;
  report<<(row++?",":"")<<"{\"round\":"<<round<<",\"mode\":\""<<(mode==0?"repeated-heap":mode==1?"first-heap-then-precise":"all-precise")<<"\",\"declarationMS\":"<<declMS<<",\"hostEncodeMS\":"<<hostMS<<",\"gpuMS\":"<<(cb.GPUEndTime-cb.GPUStartTime)*1000<<"}";
 }
 report<<"],\"wordsChecked\":"<<N*row<<",\"mismatches\":"<<mismatch<<",\"passed\":"<<(mismatch?"false":"true")<<"}\n";
 for(auto r:rs)[r release];[out release];[table release];[ae release];[ps release];[fn release];[lib release];[q release];[seed release];[heap release];[hd release];return mismatch?3:0;
 }catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
