#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>

static void phase(const char* p) { printf("PHASE %s\n", p); fflush(stdout); }
int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 4) { fprintf(stderr, "usage: pipeline_repro vertex.metal fragment.metal safe|fast\n"); return 2; }
    id<MTLDevice> dev = nil;
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) dev = d;
    if (!dev) { fprintf(stderr, "Required actual AMD Radeon Pro 5600M missing\n"); return 3; }
    printf("DEVICE %s registryID=%llu\n", dev.name.UTF8String, dev.registryID); fflush(stdout);
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion4_0;
    options.mathMode = !strcmp(argv[3], "fast") ? MTLMathModeFast : MTLMathModeSafe;
    options.mathFloatingPointFunctions = !strcmp(argv[3], "fast") ? MTLMathFloatingPointFunctionsFast : MTLMathFloatingPointFunctionsPrecise;
    options.preserveInvariance = YES;
    NSError* error = nil;
    phase("vertex-library");
    NSString* vsSource = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    if (!vsSource) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 4; }
    id<MTLLibrary> vs = [dev newLibraryWithSource:vsSource options:options error:&error];
    if (!vs) { fprintf(stderr, "vertex library: %s\n", error.localizedDescription.UTF8String); return 5; }
    phase("fragment-library");
    options.preserveInvariance = NO;
    NSString* fsSource = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&error];
    if (!fsSource) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 6; }
    id<MTLLibrary> fs = [dev newLibraryWithSource:fsSource options:options error:&error];
    if (!fs) { fprintf(stderr, "fragment library: %s\n", error.localizedDescription.UTF8String); return 7; }
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [vs newFunctionWithName:@"main0"];
    desc.fragmentFunction = [fs newFunctionWithName:@"main0"];
    desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    desc.rasterSampleCount = 1;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    desc.colorAttachments[0].writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    desc.colorAttachments[0].blendingEnabled = YES;
    // Original log records blending on, but not factors; explicitly record this approximation.
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    phase("render-pipeline");
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:desc error:&error];
    NSDictionary* result = @{
        @"pipelineCreated": @(pso != nil), @"device": dev.name,
        @"MSLVersion": @"4.0", @"mathMode": @(argv[3]),
        @"colorFormat": @"RGBA16Float", @"writeMask": @"RGB",
        @"depthStencilFormat": @"Depth32Float_Stencil8", @"sampleCount": @1,
        @"blendFactorsApproximate": @YES, @"GPUCommandsSubmitted": @NO,
        @"error": error.localizedDescription ?: @""
    };
    NSData* data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes, 1, data.length, stdout); puts(""); fflush(stdout);
    return pso ? 0 : 8;
}}
