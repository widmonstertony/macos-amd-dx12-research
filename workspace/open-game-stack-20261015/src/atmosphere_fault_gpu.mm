// Execute two exact captured MSL kernels with bounded, analytically known inputs.
// This is an exclusion control, not a game-state replay or compatibility claim.
#include "metal_link_repro_common.h"
#include <cmath>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <vector>
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
static id<MTLBuffer> buffer(id<MTLDevice>d,NSUInteger n){auto b=[d newBufferWithLength:n options:MTLResourceStorageModeShared];need(b!=nil,"buffer allocation");memset(b.contents,0,n);return [b autorelease];}
static id<MTLBuffer> args(id<MTLDevice>d,MTLDataType type,MTLTextureType textureType,NSArray*objects,MTLBindingAccess access=MTLBindingAccessReadOnly){
 auto a=[MTLArgumentDescriptor argumentDescriptor];a.dataType=type;a.index=0;a.arrayLength=objects.count;a.access=access;if(type==MTLDataTypeTexture)a.textureType=textureType;
 auto e=[d newArgumentEncoderWithArguments:@[a]];auto b=buffer(d,e.encodedLength);[e setArgumentBuffer:b offset:0];
 for(NSUInteger i=0;i<objects.count;++i){id x=objects[i];if(x==[NSNull null])x=nil;if(type==MTLDataTypeTexture)[e setTexture:x atIndex:i];else if(type==MTLDataTypePointer)[e setBuffer:x offset:0 atIndex:i];else [e setSamplerState:x atIndex:i];}[e release];return b;
}
int main(int argc,const char**argv){@autoreleasepool{try{
 need(argc==6,"source mapping, captured-source directory, report, loop pipeline key, reduction pipeline key required");NSArray*maps=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];need(maps.count==5,"five source records expected");id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600M"])d=x;need(d!=nil,"5600M required");
 id<MTLCommandQueue>graphics=[d newCommandQueue],compute=[d newCommandQueue],copy=[d newCommandQueue];auto ge=[d newSharedEvent];auto ce=[d newSharedEvent];need(graphics&&compute&&copy&&ge&&ce,"three queues/events required");
 unsigned cases=0,checked=0,bad=0,failures=0;double totalGPU=0,maxGPU=0;NSMutableArray*rows=[NSMutableArray array];
 for(bool reduction:{false,true}){
  NSString*key=@(argv[reduction?5:4]);NSDictionary*record=nil;for(NSDictionary*r in maps)if([r[@"pipelineKey"] isEqualToString:key])record=r;need(record!=nil,"source record missing");
  NSString*label=record[@"function"][@"label"];NSArray*parts=[label componentsSeparatedByString:@":"];NSString*file=[@(argv[2]) stringByAppendingPathComponent:[NSString stringWithFormat:@"source-%@.metal",parts[1]]];NSError*error=nil;NSString*source=[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:&error];need(source!=nil,"captured source missing");auto library=[d newLibraryWithSource:source options:compileOptions(record[@"function"][@"compileProvenance"]) error:&error];need(library!=nil,error.localizedDescription.UTF8String?:"library failed");auto function=[library newFunctionWithName:@"main0"];MTLComputePipelineDescriptor*pd=[MTLComputePipelineDescriptor new];pd.label=key;pd.computeFunction=function;if(getenv("MTL_SHADER_VALIDATION")&&!strcmp(getenv("MTL_SHADER_VALIDATION"),"1"))pd.shaderValidation=MTLShaderValidationEnabled;pd.maxTotalThreadsPerThreadgroup=64;pd.threadGroupSizeIsMultipleOfThreadExecutionWidth=NO;auto pipeline=[d newComputePipelineStateWithDescriptor:pd options:MTLPipelineOptionNone reflection:nil error:&error];need(pipeline!=nil,error.localizedDescription.UTF8String?:"pipeline failed");bool validationExpected=getenv("MTL_SHADER_VALIDATION")&&!strcmp(getenv("MTL_SHADER_VALIDATION"),"1");fprintf(stderr,"pipeline_validation label=%s requested=%ld reported=%ld\n",key.UTF8String,(long)pd.shaderValidation,(long)pipeline.shaderValidation);need(!validationExpected||pipeline.shaderValidation==MTLShaderValidationEnabled,"requested shader validation not actually enabled");
  for(unsigned variant=0;variant<(reduction?4:7);++variant){@autoreleasepool{
   auto view=buffer(d,65536),coeff=buffer(d,65536),unused=buffer(d,65536);float*v=(float*)view.contents,*a=(float*)coeff.contents;
   a[1]=1;a[2]=2; // Inner/outer radius. Strictly positive finite geometry.
   a[4]=a[5]=a[6]=reduction?0.1f:0.f;a[8]=a[9]=a[10]=reduction?0.1f:0.f; // Avoid zero extinction denominators.
   a[32]=float(1u<<variant);v[22]=1.f/16;v[23]=1.f/8;
   if(reduction){v[8+2]=1;v[16]=v[17]=v[18]=1;v[24]=variant&1?0.1f:-0.5f;a[36]=a[37]=a[38]=1;}
   auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:16 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;auto target=[d newTextureWithDescriptor:td];need(target!=nil,"target allocation");auto table5=args(d,MTLDataTypeTexture,MTLTextureType2D,@[target],MTLBindingAccessReadWrite);auto result=buffer(d,16*8*16);id<MTLBuffer>table0=nil,table1=nil,table2=nil,table3=nil,sizeConstants=nil,directions=nil,offsets=nil;id<MTLTexture>directionTexture=nil,black=nil;id<MTLSamplerState>sampler=nil;
   if(reduction){
    sizeConstants=buffer(d,12);((uint32_t*)sizeConstants.contents)[2]=48;offsets=buffer(d,48);((uint32_t*)offsets.contents)[10]=0;((uint32_t*)offsets.contents)[11]=64;
    directions=buffer(d,64*16);for(unsigned i=0;i<64;++i){float*p=(float*)directions.contents+i*4;p[2]=(variant&2)&&(i&1)?-1.f:1.f;}
    auto dt=[MTLTextureDescriptor new];dt.textureType=MTLTextureTypeTextureBuffer;dt.storageMode=MTLStorageModeShared;dt.pixelFormat=MTLPixelFormatRGBA32Float;dt.width=64;dt.usage=MTLTextureUsageShaderRead;directionTexture=[directions newTextureWithDescriptor:dt offset:0 bytesPerRow:1024];[dt release];need(directionTexture!=nil,"direction texture");
    auto bt=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:2 height:2 mipmapped:NO];bt.storageMode=MTLStorageModeManaged;bt.usage=MTLTextureUsageShaderRead;black=[d newTextureWithDescriptor:bt];float zeros[16]={};[black replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:zeros bytesPerRow:32];
    auto sd=[MTLSamplerDescriptor new];sd.supportArgumentBuffers=YES;sampler=[d newSamplerStateWithDescriptor:sd];[sd release];
    table0=args(d,MTLDataTypeSampler,MTLTextureType2D,@[sampler,sampler]);table1=args(d,MTLDataTypePointer,MTLTextureType2D,@[sizeConstants,[NSNull null],offsets]);table2=args(d,MTLDataTypeTexture,MTLTextureTypeTextureBuffer,@[directionTexture,directionTexture,directionTexture]);table3=args(d,MTLDataTypeTexture,MTLTextureType2D,@[black,black]);
   }
   // Initialize all texels to a sentinel; reduction writes only (0,0).
   auto init=[graphics commandBuffer];auto blit=[init blitCommandEncoder];auto sentinel=buffer(d,16*8*16);for(unsigned i=0;i<16*8*4;++i)((float*)sentinel.contents)[i]=0.25f;[blit copyFromBuffer:sentinel sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:2048 sourceSize:MTLSizeMake(16,8,1) toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[blit endEncoding];[init encodeSignalEvent:ge value:cases+1];[init commit];
   auto cb=[compute commandBuffer];[cb encodeWaitForEvent:ge value:cases+1];auto enc=[cb computeCommandEncoder];[enc setComputePipelineState:pipeline];[enc setBuffer:table5 offset:0 atIndex:5];
   [enc useResource:target usage:MTLResourceUsageWrite];[enc useResource:view usage:MTLResourceUsageRead];[enc useResource:coeff usage:MTLResourceUsageRead];
   if(reduction){struct{uint64_t x,y,z;uint32_t m,n,o;}root={view.gpuAddress,coeff.gpuAddress,unused.gpuAddress,0,0,0};[enc setBytes:&root length:sizeof(root) atIndex:8];[enc setBuffer:table0 offset:0 atIndex:0];[enc setBuffer:table1 offset:0 atIndex:1];[enc setBuffer:table2 offset:0 atIndex:2];[enc setBuffer:table3 offset:0 atIndex:3];auto sizes=buffer(d,128);[enc setBuffer:sizes offset:0 atIndex:28];for(id<MTLResource>r in @[sizeConstants,offsets,directionTexture,black,unused])[enc useResource:r usage:MTLResourceUsageRead];[enc dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];}
   else{struct{uint64_t x,y;uint32_t m,n,o;}root={coeff.gpuAddress,view.gpuAddress,0,0,0};[enc setBytes:&root length:sizeof(root) atIndex:8];[enc dispatchThreadgroups:MTLSizeMake(2,1,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];}
   [enc endEncoding];[cb encodeSignalEvent:ce value:cases+1];[cb commit];auto read=[copy commandBuffer];[read encodeWaitForEvent:ce value:cases+1];blit=[read blitCommandEncoder];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,8,1) toBuffer:result destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];[blit endEncoding];[read commit];[read waitUntilCompleted];[cb waitUntilCompleted];[init waitUntilCompleted];bool ok=read.status==MTLCommandBufferStatusCompleted&&cb.status==MTLCommandBufferStatusCompleted&&init.status==MTLCommandBufferStatusCompleted;
   if(!ok){++failures;fprintf(stderr,"GPU error: %s\n",cb.error.localizedDescription.UTF8String);}
   double gpu=cb.GPUEndTime-cb.GPUStartTime;totalGPU+=gpu;maxGPU=fmax(maxGPU,gpu);unsigned mismatch=0;float*data=(float*)result.contents;
   // Zero sampled radiance produces zero reduction; zero extinction
   // gives unit transmittance, independently of sample count and ray length.
   if(reduction){for(unsigned i=0;i<16*8*4;++i){float expected=i<4?0.f:0.25f;if(!std::isfinite(data[i])||fabsf(data[i]-expected)>1e-5f)++mismatch;}}
   else{for(unsigned i=0;i<16*8*4;++i)if(!std::isfinite(data[i])||fabsf(data[i]-1.f)>1e-5f)++mismatch;}
   checked+=16*8*4;bad+=mismatch;++cases;[rows addObject:@{@"pipeline":key,@"variant":@(variant),@"GPUSeconds":@(gpu),@"shaderValidationState":@(pipeline.shaderValidation),@"completed":@(ok),@"mismatches":@(mismatch)}];
   [target release];[directionTexture release];[black release];[sampler release];if(!ok)throw std::runtime_error("stop after first GPU failure");
  }}[pipeline release];[pd release];[function release];[library release];
 }
 NSDictionary*report=@{@"passed":@(!bad&&!failures),@"exactCapturedShaders":@2,@"cases":@(cases),@"GPUValuesChecked":@(checked),@"mismatches":@(bad),@"commandBufferFailures":@(failures),@"independentQueues":@3,@"maximumComputeGPUSeconds":@(maxGPU),@"totalComputeGPUSeconds":@(totalGPU),@"originalGameInputsReplayed":@NO,@"gameTimeoutReproduced":@NO,@"gamePlayableProven":@NO,@"rows":rows};auto data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];need([data writeToFile:@(argv[3]) atomically:YES],"report write failed");printf("cases=%u checked=%u mismatches=%u failures=%u\n",cases,checked,bad,failures);[ge release];[ce release];[graphics release];[compute release];[copy release];return bad||failures?5:0;
}catch(const std::exception&e){fprintf(stderr,"ERROR %s\n",e.what());return 2;}}}
