// Standalone, owned mesh-archive capability test. Never starts or injects a game.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <cstdio>
#include <cstring>

int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 3 || (strcmp(argv[2], "seed") && strcmp(argv[2], "load") && strcmp(argv[2], "plain"))) return 2;
    bool load = !strcmp(argv[2], "load");
    bool plain = !strcmp(argv[2], "plain");
    id<MTLDevice> device = nil;
    for (id<MTLDevice> candidate in MTLCopyAllDevices())
        if ([candidate.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = candidate;
    if (!device) return 3;
    MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
    NSURL* url = [NSURL fileURLWithPath:@(argv[1])];
    if (load) ad.url = url;
    NSError* error = nil;
    id<MTLBinaryArchive> archive = plain ? nil : [device newBinaryArchiveWithDescriptor:ad error:&error];
    if (!plain && (!archive || ![archive respondsToSelector:@selector(addMeshRenderPipelineFunctionsWithDescriptor:error:)])) {
        fprintf(stderr, "mesh_archive.support=FAIL error=%s\n", error.localizedDescription.UTF8String ?: "mesh archive selector absent");
        return 4;
    }
    NSString* head = @"#include <metal_stdlib>\n#include <metal_mesh>\nusing namespace metal;struct Payload{float4 color;};struct V{float4 p[[position]];float4 c[[user(locn3)]];};struct P{};using M=metal::mesh<V,P,3,1,topology::triangle>;\n";
    NSArray* sources = @[
        [head stringByAppendingString:@"[[object]]void obj(object_data Payload&payload[[payload]],mesh_grid_properties grid){payload.color=float4(.25,.5,.75,1);grid.set_threadgroups_per_grid(uint3(1));}"],
        [head stringByAppendingString:@"[[mesh]]void msh(M out,const object_data Payload&payload[[payload]]){float2 xy[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};for(uint i=0;i<3;i++){V v;v.p=float4(xy[i],0,1);v.c=payload.color;out.set_vertex(i,v);out.set_index(i,i);}P p={};out.set_primitive(0,p);out.set_primitive_count(1);}"],
        [head stringByAppendingString:@"fragment float4 frag(V in[[stage_in]]){return in.c;}"]];
    NSArray* names = @[@"obj", @"msh", @"frag"];
    id<MTLFunction> functions[3];
    for (unsigned i = 0; i < 3; ++i) {
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion4_0;
        options.mathMode = MTLMathModeSafe;
        options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
        options.preserveInvariance = i < 2;
        id<MTLLibrary> library = [device newLibraryWithSource:sources[i] options:options error:&error];
        functions[i] = [library newFunctionWithName:names[i]];
        if (!functions[i]) { fprintf(stderr, "mesh_archive.function=FAIL %s\n", error.localizedDescription.UTF8String); return 5; }
        [library release]; [options release];
    }
    MTLMeshRenderPipelineDescriptor* pd = [MTLMeshRenderPipelineDescriptor new];
    pd.objectFunction = functions[0]; pd.meshFunction = functions[1]; pd.fragmentFunction = functions[2];
    pd.maxTotalThreadsPerObjectThreadgroup = 1; pd.maxTotalThreadsPerMeshThreadgroup = 1;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    if (archive) pd.binaryArchives = @[archive];
    auto start = std::chrono::steady_clock::now();
    if (!plain && !load && ![archive addMeshRenderPipelineFunctionsWithDescriptor:pd error:&error]) {
        fprintf(stderr, "mesh_archive.add=FAIL domain=%s code=%ld error=%s\n", error.domain.UTF8String, (long)error.code, error.localizedDescription.UTF8String);
        return 6;
    }
    // A load is accepted only if Metal confirms the exact pipeline is archived.
    MTLPipelineOption option = load ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone;
    id<MTLRenderPipelineState> ps = [device newRenderPipelineStateWithMeshDescriptor:pd options:option reflection:nil error:&error];
    double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    if (!ps) { fprintf(stderr, "mesh_archive.pipeline=FAIL %s\n", error.localizedDescription.UTF8String); return 7; }
    if (!plain && !load && ![archive serializeToURL:url error:&error]) {
        fprintf(stderr, "mesh_archive.serialize=FAIL %s\n", error.localizedDescription.UTF8String); return 8;
    }
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    id<MTLBuffer> read = [device newBufferWithLength:2048 options:MTLResourceStorageModeShared];
    memset(read.contents, 0xcd, 2048);
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [[device newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:rp];
    [encoder setRenderPipelineState:ps];
    [encoder drawMeshThreadgroups:MTLSizeMake(1,1,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];
    [encoder endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    unsigned mismatches = 0; unsigned char expected[] = {64,128,191,255};
    for (unsigned y=0; y<8; ++y) for (unsigned x=0; x<8; ++x)
        if (memcmp((char*)read.contents+y*256+x*4, expected, 4)) ++mismatches;
    bool passed = !mismatches && cb.status == MTLCommandBufferStatusCompleted;
    printf("{\"passed\":%s,\"mode\":\"%s\",\"strictArchiveHitRequired\":%s,\"checkedPixels\":64,\"badPixels\":%u,\"pipelineMilliseconds\":%.3f,\"gameCompatibilityProven\":false}\n", passed?"true":"false", argv[2], load?"true":"false", mismatches, milliseconds);
    return passed ? 0 : 9;
} }
