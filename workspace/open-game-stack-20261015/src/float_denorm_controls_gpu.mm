// Public Metal-only control: measure, never advertise new Vulkan capabilities.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

struct Input { uint32_t a, b, op, unused; };
static float value(uint32_t bits) { float f; memcpy(&f, &bits, 4); return f; }
static uint32_t bits(float f) { uint32_t n; memcpy(&n, &f, 4); return n; }
static uint32_t flush(uint32_t n) { return (n & 0x7f800000u) == 0 ? n & 0x80000000u : n; }
static uint32_t reference(Input x, bool ftz) {
    volatile float a = value(ftz ? flush(x.a) : x.a), b = value(ftz ? flush(x.b) : x.b);
    float result;
    switch (x.op) { case 0: result = a * b; break; case 1: result = a + b; break;
                   case 2: result = a - b; break; default: result = a / b; break; }
    return ftz ? flush(bits(result)) : bits(result);
}
int main() { @autoreleasepool {
    id<MTLDevice> gpu = nil;
    for (id<MTLDevice> device in MTLCopyAllDevices())
        if ([device.name containsString:@"AMD Radeon Pro 5600M"]) gpu = device;
    if (!gpu) return 2;
    printf("GPU=%s\n", gpu.name.UTF8String);
    Input input[] = {
        {0x00800000,0x3f000000,0,0}, {0x80800000,0x3f000000,0,0},
        {0x00000001,0x3f800000,0,0}, {0x80000001,0x3f800000,0,0},
        {0x00000001,0x00000001,1,0}, {0x80000001,0x80000001,1,0},
        {0x00800001,0x00800000,2,0}, {0x80800001,0x80800000,2,0},
        {0x00800000,0x40000000,3,0}, {0x80800000,0x40000000,3,0},
        {0x007fffff,0x3f800000,0,0}, {0x807fffff,0x3f800000,0,0},
        {0x00400000,0x40000000,0,0}, {0x80400000,0x40000000,0,0},
        {0x3f800000,0x40000000,0,0}, {0xbf800000,0x40000000,0,0}
    };
    constexpr size_t count = sizeof(input)/sizeof(input[0]);
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { uint a,b,op,unused; };\n"
        "kernel void measure(const device I* in [[buffer(0)]], device uint* out [[buffer(1)]], uint i [[thread_position_in_grid]]) {"
        "float a=as_type<float>(in[i].a), b=as_type<float>(in[i].b), r;"
        "switch(in[i].op) { case 0:r=a*b;break;case 1:r=a+b;break;case 2:r=a-b;break;default:r=a/b;break;}"
        "out[i]=as_type<uint>(r); }";
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    // 0/1: legacy fastMath off/on. 2: current public Safe + Precise modes.
    for (int fast = 0; fast < 3; ++fast) {
        MTLCompileOptions *options = [MTLCompileOptions new];
        if (fast < 2) options.fastMathEnabled = fast;
        else {
            options.mathMode = MTLMathModeSafe;
            options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
            options.preserveInvariance = YES;
        }
        NSError *error = nil;
        id<MTLLibrary> library = [gpu newLibraryWithSource:source options:options error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 3; }
        id<MTLComputePipelineState> pipeline = [gpu newComputePipelineStateWithFunction:[library newFunctionWithName:@"measure"] error:&error];
        if (!pipeline) return 4;
        id<MTLBuffer> in = [gpu newBufferWithBytes:input length:sizeof(input) options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [gpu newBufferWithLength:count*4 options:MTLResourceStorageModeShared];
        memset(out.contents,0xcd,count*4);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline]; [encoder setBuffer:in offset:0 atIndex:0];
        [encoder setBuffer:out offset:0 atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(count,1,1)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) return 5;
        unsigned preserveMismatch=0, flushMismatch=0;
        auto actual=(const uint32_t*)out.contents;
        for(size_t i=0;i<count;++i) {
            uint32_t preserve=reference(input[i],false), ftz=reference(input[i],true);
            preserveMismatch += actual[i]!=preserve; flushMismatch += actual[i]!=ftz;
            printf("fast=%d case=%zu actual=%08x preserve=%08x ftz=%08x\n",fast,i,actual[i],preserve,ftz);
        }
        printf("SUMMARY fast=%d cases=%zu preserveMismatches=%u flushMismatches=%u\n",fast,count,preserveMismatch,flushMismatch);
    }
    puts("Measured selected cases only; not float-controls conformance or a game-compatibility claim.");
    return 0;
}}
