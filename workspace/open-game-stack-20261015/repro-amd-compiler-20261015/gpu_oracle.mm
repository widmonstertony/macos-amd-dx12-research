#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

struct alignas(8) Root { uint64_t address[5]; uint32_t index[5]; uint32_t padding; };
static_assert(sizeof(Root) == 64 && offsetof(Root, index) == 40, "Original uint2 and typed-pointer ABI");
static void set4(id<MTLBuffer> b, size_t offset, unsigned i, float x, float y, float z, float w) {
    float f[4] = {x,y,z,w}; memcpy((char*)b.contents + offset + i*16, f, 16);
}
static void setU(id<MTLBuffer> b, size_t offset, unsigned word, uint32_t value) {
    memcpy((char*)b.contents+offset+word*4, &value, 4);
}
static float halfToFloat(uint16_t h) {
    unsigned s=h>>15, e=(h>>10)&31, m=h&1023;
    if(e==31) return m ? NAN : (s ? -INFINITY : INFINITY);
    float v=e ? std::ldexp(1.0f+m/1024.0f,int(e)-15) : std::ldexp(float(m),-24);
    return s ? -v : v;
}
static id<MTLTexture> uniformTexture(id<MTLDevice> d, bool volume, const float value[4]) {
    MTLTextureDescriptor* td=[MTLTextureDescriptor new];
    td.textureType=volume?MTLTextureType3D:MTLTextureType2D;
    td.width=td.height=2; td.depth=volume?2:1; td.pixelFormat=MTLPixelFormatRGBA32Float;
    td.storageMode=MTLStorageModeManaged; td.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> tex=[d newTextureWithDescriptor:td];
    float data[32]; for(unsigned i=0;i<8;i++) memcpy(data+i*4,value,16);
    [tex replaceRegion:MTLRegionMake3D(0,0,0,2,2,volume?2:1) mipmapLevel:0 slice:0
             withBytes:data bytesPerRow:32 bytesPerImage:volume?64:0];
    return tex;
}
int main(int argc,const char** argv) { @autoreleasepool {
    if(argc!=3) return 2;
    id<MTLDevice> d=nil; for(id<MTLDevice> x in MTLCopyAllDevices())
        if([x.name isEqualToString:@"AMD Radeon Pro 5600M"]) d=x;
    if(!d) return 3;
    printf("DEVICE %s\n",d.name.UTF8String); fflush(stdout);
    NSError* err=nil; MTLCompileOptions* opts=[MTLCompileOptions new];
    opts.languageVersion=MTLLanguageVersion4_0; opts.mathMode=MTLMathModeSafe;
    opts.mathFloatingPointFunctions=MTLMathFloatingPointFunctionsPrecise; opts.preserveInvariance=YES;
    id<MTLLibrary> vl=[d newLibraryWithSource:[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err] options:opts error:&err];
    opts.preserveInvariance=NO;
    id<MTLLibrary> fl=[d newLibraryWithSource:[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&err] options:opts error:&err];
    if(!vl||!fl) { fprintf(stderr,"library: %s\n",err.localizedDescription.UTF8String); return 4; }
    MTLRenderPipelineDescriptor* pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[vl newFunctionWithName:@"main0"]; pd.fragmentFunction=[fl newFunctionWithName:@"main0"];
    pd.inputPrimitiveTopology=MTLPrimitiveTopologyClassTriangle; pd.rasterSampleCount=1;
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
    pd.colorAttachments[0].writeMask=MTLColorWriteMaskRed|MTLColorWriteMaskGreen|MTLColorWriteMaskBlue;
    pd.colorAttachments[0].blendingEnabled=YES;
    pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOne;
    pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
    pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
    id<MTLRenderPipelineState> ps=[d newRenderPipelineStateWithDescriptor:pd error:&err];
    if(!ps) { fprintf(stderr,"pipeline: %s\n",err.localizedDescription.UTF8String); return 5; }
    id<MTLBuffer> cbv[5]; const size_t offsets[5]={256,512,768,1024,1280};
    for(unsigned i=0;i<5;i++) cbv[i]=[d newBufferWithLength:65536+2048 options:MTLResourceStorageModeShared];
    id<MTLBuffer> roots=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> textures=[d newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> samplers=[d newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> read=[d newBufferWithLength:2048 options:MTLResourceStorageModeShared];
    const float dep[4]={1,0,0,1}, at[4]={0.125,0.25,0.5,1}, sky[4]={0.25,0.5,0.75,1}, vol[4]={0.125,0.25,0.5,0.75};
    id<MTLTexture> tex[4]={uniformTexture(d,false,dep),uniformTexture(d,false,at),uniformTexture(d,false,sky),uniformTexture(d,true,vol)};
    MTLSamplerDescriptor* sd=[MTLSamplerDescriptor new]; sd.supportArgumentBuffers=YES;
    sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterNearest;
    sd.sAddressMode=sd.tAddressMode=sd.rAddressMode=MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler=[d newSamplerStateWithDescriptor:sd];
    for(unsigned i=0;i<4;i++) ((MTLResourceID*)samplers.contents)[i]=sampler.gpuResourceID;
    MTLTextureDescriptor* rt=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:8 height:8 mipmapped:NO];
    rt.storageMode=MTLStorageModePrivate; rt.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> target=[d newTextureWithDescriptor:rt];
    rt.pixelFormat=MTLPixelFormatDepth32Float_Stencil8; id<MTLTexture> depth=[d newTextureWithDescriptor:rt];
    id<MTLCommandQueue> queue=[d newCommandQueue]; NSMutableArray* results=[NSMutableArray array];
    // Expected RGB is independent of texture coordinates because inputs are uniform.
    // Atmosphere branch: LUT(.125,.25,.5)*sun(1,.5,.25)*gain2 = (.25,.25,.25).
    // Sky branch: LUT(.25,.5,.75)*transmittance(.5,.25,1)*gain6 = (.75,.75,4.5).
    const char* names[]={"volume","sky","atmosphere-and-sky","null-sky","null-atmosphere","null-volume","null-depth","discard"};
    const float expected[8][4]={{.75,1.5,3,.25},{.75,.75,4.5,.25},{1,1,4.75,.25},{0,0,0,.25},{.75,.75,4.5,.25},{0,0,0,.25},{.75,.75,4.5,.25},{0,0,0,.25}};
    unsigned totalBad=0;
    for(unsigned test=0;test<8;test++) {
        printf("DRAW %s\n",names[test]); fflush(stdout);
        for(unsigned i=0;i<5;i++) memset(cbv[i].contents,0,cbv[i].length);
        Root root={}; for(unsigned i=0;i<5;i++) root.address[i]=cbv[i].gpuAddress+offsets[i];
        memcpy(roots.contents,&root,sizeof(root));
        set4(cbv[4],offsets[4],0,0,0,0,.5); // unchanged game VS uses uint2->pointer path
        set4(cbv[1],offsets[1],50,1e-6,2e-6,3e-6,0);
        set4(cbv[1],offsets[1],172,200000,0,0,0); // atmosphere-relative camera distance=2
        set4(cbv[1],offsets[1],174,1,0,0,0); set4(cbv[1],offsets[1],175,0,1,0,0); set4(cbv[1],offsets[1],176,0,0,1,0);
        set4(cbv[1],offsets[1],135,0,2,3,0); set4(cbv[1],offsets[1],184,1,2,0,0);
        set4(cbv[1],offsets[1],161,0,0,1,0); set4(cbv[1],offsets[1],169,.1,0,0,0); set4(cbv[1],offsets[1],167,1,.5,.25,0);
        set4(cbv[2],offsets[2],0,0,1,3,0);
        set4(cbv[3],offsets[3],3,1,1,0,1); set4(cbv[3],offsets[3],8,0,0,0,1);
        set4(cbv[3],offsets[3],9,.5,.25,1,0);
        set4(cbv[1],offsets[1],44,1,0,0,0); set4(cbv[1],offsets[1],45,0,1,0,0);
        set4(cbv[1],offsets[1],46,0,0,1,0); set4(cbv[1],offsets[1],47,0,0,0,1);
        set4(cbv[1],offsets[1],7,0,0,0,1);
        bool skyPath=test!=0&&test!=5&&test!=7;
        if(skyPath && test!=6) setU(cbv[0],offsets[0],5,1); // uint CBV depth override, actual 32-bit bits
        if(test==2||test==4) setU(cbv[0],offsets[0],3,1); // enable complete atmosphere computation
        if(test==7) set4(cbv[3],offsets[3],8,0,0,0,0);
        for(unsigned i=0;i<4;i++) ((MTLResourceID*)textures.contents)[i]=tex[i].gpuResourceID;
        if(test==3) ((MTLResourceID*)textures.contents)[2]={0};
        if(test==4) ((MTLResourceID*)textures.contents)[1]={0};
        if(test==5) ((MTLResourceID*)textures.contents)[3]={0};
        if(test==6) ((MTLResourceID*)textures.contents)[0]={0};
        memset(read.contents,0xa5,read.length);
        MTLRenderPassDescriptor* rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture=target; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
        rp.colorAttachments[0].storeAction=MTLStoreActionStore; rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,.25);
        rp.depthAttachment.texture=depth; rp.depthAttachment.loadAction=MTLLoadActionClear; rp.depthAttachment.clearDepth=1;
        rp.stencilAttachment.texture=depth; rp.stencilAttachment.loadAction=MTLLoadActionClear;
        id<MTLCommandBuffer> cb=[queue commandBuffer]; id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:ps]; [e setCullMode:MTLCullModeNone];
        [e setVertexBuffer:roots offset:0 atIndex:8]; [e setFragmentBuffer:roots offset:0 atIndex:8];
        [e setFragmentBuffer:samplers offset:0 atIndex:0]; [e setFragmentBuffer:textures offset:0 atIndex:3];
        for(unsigned i=0;i<5;i++) [e useResource:cbv[i] usage:MTLResourceUsageRead stages:MTLRenderStageVertex|MTLRenderStageFragment];
        for(unsigned i=0;i<4;i++) [e useResource:tex[i] usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
        id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];
        [b copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1)
                  toBuffer:read destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        unsigned bad=0; float maxError=0; float first[4]={};
        for(unsigned y=0;y<8;y++) for(unsigned x=0;x<8;x++) for(unsigned c=0;c<4;c++) {
            uint16_t h; memcpy(&h,(char*)read.contents+y*256+x*8+c*2,2); float actual=halfToFloat(h);
            if(x==0&&y==0) first[c]=actual;
            float delta=std::abs(actual-expected[test][c]); if(!std::isfinite(actual)||delta>.002) bad++;
            maxError=std::max(maxError,delta);
        }
        if(cb.status!=MTLCommandBufferStatusCompleted) bad++;
        totalBad+=bad;
        [results addObject:@{@"case":@(names[test]),@"badComponents":@(bad),@"componentsChecked":@256,@"maxAbsError":@(maxError),
            @"firstPixel":@[@(first[0]),@(first[1]),@(first[2]),@(first[3])],
            @"expected":@[@(expected[test][0]),@(expected[test][1]),@(expected[test][2]),@(expected[test][3])],
            @"commandStatus":@(cb.status),@"error":cb.error.localizedDescription?:@""}];
    }
    NSDictionary* result=@{@"passed":@(totalBad==0),@"device":d.name,@"actualGPUDraws":@8,@"componentsChecked":@2048,
        @"typedPointerABIBytes":@64,@"dynamicCBVOffsets":@[@256,@512,@768,@1024,@1280],@"badComponents":@(totalBad),
        @"gameStarted":@NO,@"closedBinariesModified":@NO,@"cases":results};
    NSData* json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes,1,json.length,stdout); puts(""); return totalBad?6:0;
}}
