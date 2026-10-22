// Owned-input morphing/skinning six-layer shadow GPU execution control for an explicitly supplied captured pipeline.
// Sources remain external/private. This is not a replay of game buffer contents.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <array>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <map>

struct DrawInfo {
    int32_t indexed, indexSize;
    uint64_t indexBuffer;
    int32_t baseVertex;
    uint32_t baseInstance, strides[31], divisors[31];
    uint8_t topoStrip;
    uint32_t primitiveBase, primitiveCount, instanceBase;
};
struct Roots { uint64_t address[6]; uint32_t words[7]; };
static_assert(offsetof(DrawInfo, strides)==24 && offsetof(DrawInfo, topoStrip)==272 && offsetof(DrawInfo, primitiveBase)==276 && offsetof(DrawInfo, primitiveCount)==280 && offsetof(DrawInfo, instanceBase)==284 && sizeof(DrawInfo)==288);
static_assert(offsetof(Roots, words)==48);

int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 3) return 2;
    NSError* error=nil;
    NSDictionary* input=[NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:@(argv[1])] options:0 error:&error];
    if (!input) return 3;
    id<MTLDevice> device=nil;
    NSArray* devices=MTLCopyAllDevices();
    for(id<MTLDevice> d in devices) if([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device=d;
    if(!device) return 4;
    id<MTLFunction> functions[3];id<MTLFunction> vertexControl=nil;
    bool computeVertexOnly=[input[@"computeVertexOnly"]boolValue];
    unsigned stageIndex=0;
    for(NSString* stage in @[@"object",@"mesh",@"fragment"]) {
        NSDictionary* item=input[stage];
        NSString* source=[NSString stringWithContentsOfFile:item[@"source"] encoding:NSUTF8StringEncoding error:&error];
        if(!source) return 5;
        // Refuse a different interface; these are owned analytical fixtures,
        // not guesses about arbitrary captured resource layouts.
        NSString* required=stageIndex==0?@"vertexStrides[31]":stageIndex==1?@"VERTEX_COUNT = 18":@"fragment void";
        if(![source containsString:required]) return 6;
        NSDictionary* provenance=item[@"compileProvenance"];
        MTLCompileOptions* options=[MTLCompileOptions new];
        options.languageVersion=(MTLLanguageVersion)[provenance[@"languageVersion"] unsignedIntegerValue];
        options.mathMode=(MTLMathMode)[provenance[@"mathMode"] unsignedIntegerValue];
        options.mathFloatingPointFunctions=(MTLMathFloatingPointFunctions)[provenance[@"mathFloatingPointFunctions"] unsignedIntegerValue];
        options.preserveInvariance=[provenance[@"preserveInvariance"] boolValue];
        id<MTLLibrary> library=[device newLibraryWithSource:source options:options error:&error];
        functions[stageIndex]=[library newFunctionWithName:item[@"entry"]];
        if(stageIndex==0 && computeVertexOnly)vertexControl=[library newFunctionWithName:@"owned_vertex_fetch"];
        [library release];[options release];
        if(!functions[stageIndex++]) {fprintf(stderr,"compile: %s\n",error.localizedDescription.UTF8String);return 7;}
    }
    MTLMeshRenderPipelineDescriptor* pd=[MTLMeshRenderPipelineDescriptor new];
    bool fragmentEnabled=input[@"fragmentEnabled"]?[input[@"fragmentEnabled"] boolValue]:true;
    pd.objectFunction=functions[0];pd.meshFunction=functions[1];pd.fragmentFunction=fragmentEnabled?functions[2]:nil;
    pd.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;
    bool explicitSingleThreadLimits=input[@"explicitSingleThreadLimits"]?[input[@"explicitSingleThreadLimits"]boolValue]:true;
    if(explicitSingleThreadLimits){pd.maxTotalThreadsPerObjectThreadgroup=1;pd.maxTotalThreadsPerMeshThreadgroup=1;}
    bool exactMeshGridBound=[input[@"exactMeshGridBound"]boolValue];
    bool indirectDispatch=[input[@"indirectDispatch"]boolValue];
    if(exactMeshGridBound)pd.maxTotalThreadgroupsPerMeshGrid=1;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithMeshDescriptor:pd
        options:MTLPipelineOptionNone reflection:nil error:&error];
    if(!pipeline){fprintf(stderr,"pipeline: %s\n",error.localizedDescription.UTF8String);return 8;}
    MTLDepthStencilDescriptor* dd=[MTLDepthStencilDescriptor new];
    dd.depthCompareFunction=MTLCompareFunctionLess;dd.depthWriteEnabled=YES;
    id<MTLDepthStencilState> depthState=[device newDepthStencilStateWithDescriptor:dd];
    NSMutableArray* keep=[NSMutableArray array];
    auto buffer=[&](NSUInteger length) -> id<MTLBuffer> {
        id<MTLBuffer> b=[device newBufferWithLength:length options:MTLResourceStorageModeShared];
        if(!b) return nil;
        memset(b.contents,0,length);[keep addObject:b];[b release];return b;
    };
    // All physical address arrays are complete, owned 64-KiB constant buffers.
    id<MTLBuffer> constants[6];Roots roots={};
    for(unsigned i=0;i<6;++i){constants[i]=buffer(65536);roots.address[i]=constants[i].gpuAddress;}
    // This captured variant has four 64-bit roots and four words at byte 32.
    roots.address[4]=roots.address[5]=0;
    auto transform=(simd_float4*)constants[2].contents;
    transform[0]={1,0,0,0};transform[1]={0,1,0,0};transform[2]={0,0,1,0};transform[4]={1,1,1,1};
    auto shadow=(simd_float4*)constants[3].contents;
    for(unsigned face=0;face<6;++face){unsigned b=29+face*4;shadow[b]={1,0,0,0};shadow[b+1]={0,1,0,0};shadow[b+2]={0,0,1,0};shadow[b+3]={0,0,0,1};}
    auto fragment=(simd_float4*)constants[1].contents;
    for(unsigned index: {25u,52u,79u,106u}) fragment[index]={-1,-1,-1,0};
    id<MTLBuffer> sizes=buffer(256), offsets=buffer(256);
    ((uint32_t*)sizes.contents)[2]=256;((uint32_t*)offsets.contents)[3]=3;
    id<MTLArgumentEncoder> ae1=[functions[0] newArgumentEncoderWithBufferIndex:1];
    id<MTLArgumentEncoder> ae2=[functions[0] newArgumentEncoderWithBufferIndex:2];
    if(!ae1 || !ae2 || !ae1.encodedLength || !ae2.encodedLength){fprintf(stderr,"Fixture interface lacks expected argument buffers\n");return 9;}
    id<MTLBuffer> set1=buffer(ae1.encodedLength),set2=buffer(ae2.encodedLength);
    [ae1 setArgumentBuffer:set1 offset:0];[ae1 setBuffer:sizes offset:0 atIndex:0];[ae1 setBuffer:offsets offset:0 atIndex:2];
    id<MTLBuffer> bones=buffer(256);
    auto bone=(simd_float4*)bones.contents;bone[0]={1,0,0,0};bone[1]={0,1,0,0};bone[2]={0,0,1,0};
    MTLTextureDescriptor* bd=[MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:3 resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
    id<MTLTexture> boneTexture=[bones newTextureWithDescriptor:bd offset:0 bytesPerRow:256];
    if(!boneTexture) return 9;
    [ae2 setArgumentBuffer:set2 offset:0];[ae2 setTexture:boneTexture atIndex:0];
    id<MTLBuffer> positions=buffer(256),normals=buffer(256),skin=buffer(256),uv=buffer(256),morph=buffer(256),unused=buffer(256);
    float xy[3][3]={{-1,-1,.5},{3,-1,.5},{-1,3,.5}};
    memcpy(positions.contents,xy,sizeof(xy));
    for(unsigned v=0;v<3;++v){auto n=(int8_t*)normals.contents+v*8;n[6]=127;n[7]=127;((uint8_t*)skin.contents)[v*8+4]=255;}
    DrawInfo draw={};draw.indexed=1;draw.indexSize=2;
    for(auto& d:draw.divisors)d=0xffffffffu;
    draw.strides[24]=24;draw.strides[25]=24;draw.strides[26]=8;draw.strides[27]=4;draw.strides[28]=4;draw.strides[29]=8;draw.strides[30]=12;
    unsigned width=input[@"imageWidth"]?[input[@"imageWidth"] unsignedIntValue]:32;
    unsigned batch=input[@"batchTriangles"]?[input[@"batchTriangles"] unsignedIntValue]:16384;
    bool tiledGrid=[input[@"tiledGrid"] boolValue];
    unsigned tileWidth=input[@"tileWidth"]?[input[@"tileWidth"]unsignedIntValue]:4096;
    if(tileWidth<1||tileWidth>4096)return 13;
    bool drawInfoBuffer=[input[@"drawInfoBuffer"] boolValue];
    bool originalBindingOrder=[input[@"originalBindingOrder"] boolValue];
    NSArray* counts=input[@"triangleCounts"]?:@[@1,@16,@256,@4096,@16384];
    if((width!=1 && width!=32) || batch<1 || batch>16384 || counts.count<1 || counts.count>5)return 13;
    for(NSNumber* count in counts)if(count.unsignedIntValue<1 || count.unsignedIntValue>32768)return 13;
    const unsigned height=width,layers=6,rowBytes=256,sliceBytes=rowBytes*height;
    MTLTextureDescriptor* td=[MTLTextureDescriptor new];td.textureType=MTLTextureType2DArray;td.pixelFormat=MTLPixelFormatDepth16Unorm;
    td.width=width;td.height=height;td.arrayLength=layers;td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> target=[device newTextureWithDescriptor:td];id<MTLBuffer> readback=buffer(sliceBytes*layers);
    id<MTLCommandQueue> queue=[device newCommandQueue];NSMutableArray* results=[NSMutableArray array];
    id<MTLComputePipelineState> vertexPipeline=computeVertexOnly?[device newComputePipelineStateWithFunction:vertexControl error:&error]:nil;
    if(computeVertexOnly&&!vertexPipeline){fprintf(stderr,"vertex control: %s\n",error.localizedDescription.UTF8String);return 14;}
    uint64_t checked=0,mismatches=0;bool performanceBudgetReached=false,gpuFailed=false;
    // Scale overlapping, valid indexed geometry while keeping an exact oracle.
    for(NSNumber* count in counts) { @autoreleasepool {
        unsigned triangles=count.unsignedIntValue;
        draw.primitiveCount=triangles;
        id<MTLBuffer> indices=buffer(triangles*3*2);
        for(unsigned i=0;i<triangles*3;++i)((uint16_t*)indices.contents)[i]=i%3;
        draw.indexBuffer=indices.gpuAddress;memset(readback.contents,0xcd,readback.length);
        if(computeVertexOnly){
            id<MTLBuffer> info=buffer(sizeof(draw)),rootBuffer=buffer(sizeof(roots)),output=buffer(uint64_t(triangles)*3*16);
            memcpy(info.contents,&draw,sizeof(draw));memcpy(rootBuffer.contents,&roots,sizeof(roots));
            id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> enc=[cb computeCommandEncoder];
            [enc setComputePipelineState:vertexPipeline];
            [enc setBuffer:info offset:0 atIndex:17];[enc setBuffer:rootBuffer offset:0 atIndex:8];
            [enc setBuffer:set1 offset:0 atIndex:1];[enc setBuffer:set2 offset:0 atIndex:2];[enc setBuffer:sizes offset:0 atIndex:18];[enc setBuffer:output offset:0 atIndex:19];
            id<MTLBuffer> vb[]={morph,skin,unused,uv,normals,positions};for(unsigned i=0;i<6;++i)[enc setBuffer:vb[i] offset:0 atIndex:25+i];
            for(id<MTLBuffer> b in keep)[enc useResource:b usage:MTLResourceUsageRead];[enc useResource:boneTexture usage:MTLResourceUsageRead];
            [enc dispatchThreads:MTLSizeMake(triangles*3,1,1) threadsPerThreadgroup:MTLSizeMake(vertexPipeline.threadExecutionWidth,1,1)];
            [enc endEncoding];[cb commit];[cb waitUntilCompleted];
            if(cb.status!=MTLCommandBufferStatusCompleted){gpuFailed=true;[results addObject:@{@"triangles":@(triangles),@"GPUFailed":@YES,@"error":cb.error.localizedDescription?:@""}];break;}
            unsigned bad=0;auto values=(simd_float4*)output.contents;
            for(unsigned i=0;i<triangles*3;++i)for(unsigned j=0;j<4;++j){float expected=j<3?xy[i%3][j]:1;float value=values[i][j];++checked;if(!std::isfinite(value)||fabs(value-expected)>1e-6)++bad;}
            mismatches+=bad;[results addObject:@{@"triangles":@(triangles),@"badValues":@(bad),@"GPUSeconds":@(cb.GPUEndTime-cb.GPUStartTime)}];
            fprintf(stderr,"vertex triangles=%u mismatches=%u\n",triangles,bad);if(bad)break;continue;
        }
        MTLRenderPassDescriptor* rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.renderTargetArrayLength=layers;rp.depthAttachment.texture=target;rp.depthAttachment.loadAction=MTLLoadActionClear;
        rp.depthAttachment.storeAction=MTLStoreActionStore;rp.depthAttachment.clearDepth=1.0;
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipeline];[enc setDepthStencilState:depthState];[enc setCullMode:MTLCullModeNone];
        if(originalBindingOrder)[enc setObjectBytes:&draw length:sizeof(draw) atIndex:16];
        [enc setObjectBytes:&roots length:sizeof(roots) atIndex:8];
        [enc setMeshBytes:&roots length:sizeof(roots) atIndex:8];[enc setFragmentBytes:&roots length:sizeof(roots) atIndex:8];
        [enc setObjectBuffer:set1 offset:0 atIndex:1];[enc setObjectBuffer:set2 offset:0 atIndex:2];
        [enc setObjectBuffer:sizes offset:0 atIndex:17];
        id<MTLBuffer> vb[]={morph,morph,skin,unused,uv,normals,positions};
        for(unsigned i=0;i<7;++i)[enc setObjectBuffer:vb[i] offset:0 atIndex:24+i];
        // Explicitly declare all indirectly referenced owned resources.
        for(id<MTLBuffer> b in keep)[enc useResource:b usage:MTLResourceUsageRead stages:MTLRenderStageObject|MTLRenderStageMesh|MTLRenderStageFragment];
        [enc useResource:boneTexture usage:MTLResourceUsageRead stages:MTLRenderStageObject];
        for(unsigned first=0;first<triangles;first+=tiledGrid?triangles:batch){
            // The owned triangles all use identical indices/attributes, and
            // this supplied geometry entry does not consume primitive IDs.
            // This control is NOT a general draw-splitting implementation.
            draw.indexBuffer=indices.gpuAddress;draw.primitiveBase=first;
            if(drawInfoBuffer){id<MTLBuffer> info=buffer(sizeof(draw));memcpy(info.contents,&draw,sizeof(draw));[enc setObjectBuffer:info offset:0 atIndex:16];}
            else if(!originalBindingOrder)[enc setObjectBytes:&draw length:sizeof(draw) atIndex:16];
            unsigned groups=tiledGrid?std::min(tileWidth,triangles):std::min(batch,triangles-first);
            if(indirectDispatch){
                id<MTLBuffer> arguments=buffer(sizeof(MTLDispatchThreadgroupsIndirectArguments));
                auto args=(MTLDispatchThreadgroupsIndirectArguments*)arguments.contents;
                args->threadgroupsPerGrid[0]=groups;args->threadgroupsPerGrid[1]=1;args->threadgroupsPerGrid[2]=tiledGrid?(triangles+groups-1)/groups:1;
                [enc drawMeshThreadgroupsWithIndirectBuffer:arguments indirectBufferOffset:0 threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];
            }else [enc drawMeshThreadgroups:MTLSizeMake(groups,1,tiledGrid?(triangles+groups-1)/groups:1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];
        }
        [enc endEncoding];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        for(unsigned layer=0;layer<layers;++layer)[blit copyFromTexture:target sourceSlice:layer sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1)
            toBuffer:readback destinationOffset:layer*sliceBytes destinationBytesPerRow:rowBytes destinationBytesPerImage:sliceBytes];
        [blit endEncoding];[cb commit];[cb waitUntilCompleted];
        if(cb.status!=MTLCommandBufferStatusCompleted){
            fprintf(stderr,"GPU failure: %s\n",cb.error.localizedDescription.UTF8String);
            [results addObject:@{@"triangles":@(triangles),@"GPUFailed":@YES,@"GPUSeconds":@(cb.GPUEndTime-cb.GPUStartTime),@"error":cb.error.localizedDescription?:@"",@"errorCode":@(cb.error.code)}];
            gpuFailed=true;break;
        }
        unsigned bad=0;std::map<uint16_t,unsigned> histogram;
        for(unsigned layer=0;layer<layers;++layer)for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){
            uint16_t value;memcpy(&value,(uint8_t*)readback.contents+layer*sliceBytes+y*rowBytes+x*2,2);
            ++histogram[value];++checked;if(std::abs(int(value)-32768)>1)++bad;
        }
        for(unsigned layer=0;layer<layers;++layer)for(unsigned y=0;y<height;++y)for(unsigned x=width*2;x<rowBytes;++x){++checked;if(((uint8_t*)readback.contents)[layer*sliceBytes+y*rowBytes+x]!=0xcd)++bad;}
        mismatches+=bad;
        NSMutableDictionary* values=[NSMutableDictionary dictionary];for(auto pair:histogram)values[[@(pair.first)stringValue]]=@(pair.second);
        NSDictionary* row=@{@"triangles":@(triangles),@"layers":@(layers),@"badValues":@(bad),@"depthHistogram":values,@"GPUSeconds":@(cb.GPUEndTime-cb.GPUStartTime)};
        [results addObject:row];fprintf(stderr,"triangles=%u mismatches=%u GPU-ms=%.3f\n",triangles,bad,(cb.GPUEndTime-cb.GPUStartTime)*1000);
        if(bad)break;
        // Do not extrapolate a slow fixture into another GPU watchdog event.
        if(cb.GPUEndTime-cb.GPUStartTime>.25){performanceBudgetReached=true;break;}
    }}
    NSDictionary* report=@{@"passed":@(mismatches==0&&!gpuFailed),@"device":device.name,@"cases":results,@"checkedValuesIncludingPadding":@(checked),@"mismatches":@(mismatches),
        @"GPUFailed":@(gpuFailed),@"imageWidth":@(width),@"batchTriangles":@(batch),@"fragmentEnabled":@(fragmentEnabled),
        @"tiledGrid":@(tiledGrid),
        @"tileWidth":@(tileWidth),
        @"drawInfoBuffer":@(drawInfoBuffer),@"originalBindingOrder":@(originalBindingOrder),
        @"computeVertexOnly":@(computeVertexOnly),
        @"explicitSingleThreadLimits":@(explicitSingleThreadLimits),
        @"exactMeshGridBound":@(exactMeshGridBound),
        @"indirectDispatch":@(indirectDispatch),
        @"performanceBudgetReached":@(performanceBudgetReached),@"originalRuntimeInputsReplayed":@NO,@"runtimeFailureReproduced":@NO,@"gameCompatibilityProven":@NO};
    NSData* data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    if(![data writeToFile:@(argv[2]) options:NSDataWritingAtomic error:&error])return 11;
    return gpuFailed?10:mismatches?12:0;
} }
