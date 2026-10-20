#import "software_residency_adapter.h"
#include <cstdio>
#include <cstring>
#include <vector>

// ShaderRead describes shader access, not immutability: a blit can still
// change this texture. Its real CPU readback must remain correct afterward.
int main(){@autoreleasepool{
 id<MTLDevice> native=nil;for(id<MTLDevice>d in MTLCopyAllDevices())if([d.name containsString:@"AMD"])native=d;if(!native)return 2;
 id<MTLDevice>d=SRWrapMetalDeviceForSoftwareResidency(native);NSError *err=nil;
 auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
 id<MTLTexture>input=[d newTextureWithDescriptor:td];td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;id<MTLTexture>output=[d newTextureWithDescriptor:td];if(!input||!output)return 3;
 std::vector<uint8_t> initial(16*16*4),upload(4096),cpuInput(16*16*4),cpuOutput(16*16*4);
 for(unsigned y=0;y<16;y++)for(unsigned x=0;x<16;x++){unsigned i=(y*16+x)*4;uint8_t a[]={17,51,99,255},b[]={201,73,41,255};memcpy(initial.data()+i,a,4);memcpy(upload.data()+y*256+x*4,b,4);}
 [input replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:initial.data() bytesPerRow:64];
 id<MTLBuffer>src=[d newBufferWithBytes:upload.data() length:upload.size() options:MTLResourceStorageModeShared];
 NSString *msl=@"#include <metal_stdlib>\nusing namespace metal;kernel void copyPixel(texture2d<float,access::read>a[[texture(0)]],texture2d<float,access::write>b[[texture(1)]],uint2 p[[thread_position_in_grid]]){b.write(a.read(p).bgra,p);}";
 id<MTLLibrary>lib=[d newLibraryWithSource:msl options:nil error:&err];id<MTLComputePipelineState>pso=lib?[d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copyPixel"] error:&err]:nil;if(!pso){fprintf(stderr,"Native pipeline %s\n",err.localizedDescription.UTF8String);return 4;}
 id<MTLCommandBuffer>cb=[[d newCommandQueue]commandBufferWithUnretainedReferences];id<MTLBlitCommandEncoder>blit=[cb blitCommandEncoder];
 [blit copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:4096 sourceSize:MTLSizeMake(16,16,1) toTexture:input destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[blit endEncoding];blit=nil;
 id<MTLComputeCommandEncoder>e=[cb computeCommandEncoder];[e setComputePipelineState:pso];[e setTexture:input atIndex:0];[e setTexture:output atIndex:1];[e dispatchThreads:MTLSizeMake(16,16,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];e=nil;
 [cb commit];[cb waitUntilCompleted];
 [input getBytes:cpuInput.data() bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];[output getBytes:cpuOutput.data() bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
 unsigned inBad=0,outBad=0;uint8_t expectedInput[]={201,73,41,255},expectedOutput[]={41,73,201,255};for(unsigned i=0;i<256;i++){inBad+=memcmp(cpuInput.data()+4*i,expectedInput,4)!=0;outBad+=memcmp(cpuOutput.data()+4*i,expectedOutput,4)!=0;}
 bool pass=cb.status==MTLCommandBufferStatusCompleted&&!inBad&&!outBad;
 NSDictionary*r=@{@"passed":@(pass),@"genuineDevice":native.name,@"classificationOverrides":@NO,@"commandStatus":@(cb.status),@"pixelsCheckedPerTexture":@256,@"shaderReadInputChangedByRealGPUBlit":@YES,@"inputCPUReadbackMismatches":@(inBad),@"outputGPUReadThenWriteMismatches":@(outBad),@"inputNativeUsage":@(input.usage),@"inputNativeStorage":@(input.storageMode),@"scope":@"Owned real ShaderRead texture GPU blit mutation then shader read and CPU readback, not game compatibility",@"error":cb.error.localizedDescription?:@""};NSData*j=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];fwrite(j.bytes,1,j.length,stdout);puts("");return pass?0:5;
}}
