// Real GPU writes through actual MoltenVK cache/helper after 500,000-slot
// invalidations, including changed edges, duplicate removal and registration.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKCommandEncoderState.h"
#include <fstream>
#include <stdexcept>
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
static void immediate(id<MTLCommandEncoder>e,id<MTLResource>r,MTLResourceUsage u,MVKResourceUsageStages){[(id<MTLComputeCommandEncoder>)e useResource:r usage:u];}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==2,"report path required");id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");
 NSError*err=nil;NSString*source=@"#include <metal_stdlib>\nusing namespace metal;struct A{device uint*value [[id(0)]];};kernel void cs(constant A&a [[buffer(0)]],device uint*out [[buffer(1)]],constant uint&i [[buffer(2)]]){out[i]=*a.value;*a.value+=1;}";id<MTLLibrary>lib=[d newLibraryWithSource:source options:nil error:&err];need(lib!=nil,"library failed");id<MTLFunction>fn=[lib newFunctionWithName:@"cs"];id<MTLComputePipelineState>pipeline=[d newComputePipelineStateWithFunction:fn error:&err];need(pipeline!=nil,"pipeline failed");id<MTLArgumentEncoder>ae=[fn newArgumentEncoderWithBufferIndex:0];id<MTLBuffer>table=[d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:table offset:0];
 id<MTLBuffer>input=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],next=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],late=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],other=[d newBufferWithLength:256 options:MTLResourceStorageModeShared],output=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];need(input&&next&&late&&other&&output,"allocation failed");*(uint32_t*)input.contents=100;*(uint32_t*)next.contents=200;*(uint32_t*)late.contents=300;*(uint32_t*)other.contents=400;memset(output.contents,0xcd,256);
 MVKLiveList list;list.add(input);list.add(next);list.add(other);std::vector<id<MTLResource>>slots(500000,nil);slots[17]=slots[64]=input;slots[250000]=late;slots.back()=other;MVKDescriptorUseCache cache;MVKDescriptorUseCache::Snapshot previous;id<MTLCommandQueue>queue=[d newCommandQueue];MVKUseResourceHelper h;need(h.crossEncoderSnapshotReuse,"qualified snapshot reuse required");
 for(uint32_t pass=0;pass<8;pass++){
  if(pass==3)list.add(late);
  {auto guard=cache.beginWrite((const char*)slots.data(),slots.size()*sizeof(id));
   if(pass==2)slots[17]=slots[64]=next;
   if(pass==4)slots[17]=slots[64]=nil;
   if(pass==5)slots.back()=next;
   if(pass==6)slots[0]=input;
   if(pass==7)std::swap(slots[0],slots.back());
  }
  auto snapshot=cache.resources((const char*)slots.data(),slots.size(),sizeof(id));
  if(pass==1||pass==3||pass==7)need(snapshot==previous,"unchanged large identity set lost snapshot identity");
  if(pass==2){auto parent=snapshot->previous.lock();need(parent==previous,"large changed range lost predecessor");need(snapshot->added.size()==1&&snapshot->added[0]==next,"large changed range lost added identity");need(snapshot->removed.size()==1&&snapshot->removed[0]==input,"large changed range lost removed identity");}
  previous=snapshot;
  h.resetForEncoder();id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLComputeCommandEncoder>enc=[cb computeCommandEncoder];h.addLiveSnapshot(snapshot,list,enc,immediate,MVKResourceUsageStages::Compute,true);
  id<MTLBuffer>active=pass<2?input:pass==2?next:pass==3?late:pass==4?other:pass==5?next:input;auto found=h.used.find(active);need(found!=h.used.end()&&found->second.generation==h.encoderGeneration&&found->second.write,"required encoder-local write declaration missing");
  if(pass==4){auto old=h.used.find(next);need(old==h.used.end()||old->second.generation!=h.encoderGeneration,"removed identity declared in new encoder");}
  h.bindAndResetCompute(enc);[ae setBuffer:active offset:0 atIndex:0];[enc setComputePipelineState:pipeline];[enc setBuffer:table offset:0 atIndex:0];[enc setBuffer:output offset:0 atIndex:1];[enc setBytes:&pass length:4 atIndex:2];[enc dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];need(cb.status==MTLCommandBufferStatusCompleted,"GPU command failed");
 }
 unsigned mismatches=0;uint32_t expected[]={100,101,200,300,400,201,102,103};for(unsigned i=0;i<8;i++)if(((uint32_t*)output.contents)[i]!=expected[i])++mismatches;if(*(uint32_t*)input.contents!=104)++mismatches;if(*(uint32_t*)next.contents!=202)++mismatches;if(*(uint32_t*)late.contents!=301)++mismatches;if(*(uint32_t*)other.contents!=401)++mismatches;
 std::ofstream report(argv[1]);report<<"{\"passed\":"<<(mismatches?"false":"true")<<",\"descriptorSlots\":500000,\"GPUWordsChecked\":12,\"mismatches\":"<<mismatches<<",\"fullRangeInvalidations\":8,\"largeRangeDeltaChecked\":true,\"largeRangeSetStableReuseChecked\":true,\"changedEdgesAndMiddleChecked\":true,\"lateRegistrationChecked\":true,\"removedIdentityChecked\":true,\"encoderWriteDeclarationsChecked\":true}\n";
 list.remove(input);list.remove(next);list.remove(late);list.remove(other);[queue release];[input release];[next release];[late release];[other release];[output release];[table release];[ae release];[pipeline release];[fn release];[lib release];return mismatches?5:0;
 }catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
