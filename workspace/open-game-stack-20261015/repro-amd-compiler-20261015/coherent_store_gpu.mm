#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>

int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 3) return 2;
    id<MTLDevice> device = nil;
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = d;
    if (!device) return 3;
    const uint32_t n = 65536, guard = 0xa53c79e1;
    NSMutableArray* results = [NSMutableArray array];
    bool allPassed = true;
    for (bool signedType : {false, true}) for (bool fast : {false, true}) {
        NSString* type = signedType ? @"int" : @"uint";
        NSString* source = [NSString stringWithFormat:
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void store0(coherent device %@* out [[buffer(0)]], const device uint* input [[buffer(1)]], uint gid [[thread_position_in_grid]]) {"
             "if(gid < 65536u) atomic_store_explicit((coherent device atomic_%@*)&out[gid], as_type<%@>(input[gid]), memory_order_relaxed); }\n"
             "kernel void read0(const coherent device %@* out [[buffer(0)]], device uint* readback [[buffer(1)]], uint gid [[thread_position_in_grid]]) {"
             "if(gid < 65536u) readback[gid] = as_type<uint>(out[(gid * 40503u) & 65535u]); }\n",
            type, type, type, type];
        if (!strcmp(argv[2], "atomic-read")) source = [source stringByReplacingOccurrencesOfString:@"as_type<uint>(out[(gid * 40503u) & 65535u])" withString:[NSString stringWithFormat:@"as_type<uint>(atomic_load_explicit((const coherent device atomic_%@*)&out[(gid * 40503u) & 65535u], memory_order_relaxed))",type]];
        NSArray<NSString*>* parts = [source componentsSeparatedByString:@"kernel void read0"];
        NSString* readSource = [@"#include <metal_stdlib>\nusing namespace metal;\nkernel void read0" stringByAppendingString:parts[1]];
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion4_0;
        options.mathMode = fast ? MTLMathModeFast : MTLMathModeSafe;
        options.mathFloatingPointFunctions = fast ? MTLMathFloatingPointFunctionsFast : MTLMathFloatingPointFunctionsPrecise;
        NSError* error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:parts[0] options:options error:&error];
        MTLComputePipelineDescriptor* descriptor=[MTLComputePipelineDescriptor new];
        descriptor.maxTotalThreadsPerThreadgroup=64;
        descriptor.computeFunction=[library newFunctionWithName:@"store0"];
        id<MTLComputePipelineState> store=descriptor.computeFunction?[device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error]:nil;
        NSString* storeError=error.localizedDescription?:@"";
        error=nil; id<MTLLibrary> readLibrary=[device newLibraryWithSource:readSource options:options error:&error];
        descriptor.computeFunction=[readLibrary newFunctionWithName:@"read0"];
        id<MTLComputePipelineState> read=descriptor.computeFunction?[device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error]:nil;
        NSString* readError=error.localizedDescription?:@"";
        uint64_t mismatches = 0, guardMismatches = 0;
        bool submitted = false, completed = false;
        if (store && read) {
            id<MTLBuffer> input = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> output = [device newBufferWithLength:(n+8)*4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> readback = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
            auto* in = (uint32_t*)input.contents;
            auto* out = (uint32_t*)output.contents;
            uint32_t state = 0x9328a731;
            for (uint32_t i=0;i<n;i++) { state ^= state<<13; state ^= state>>17; state ^= state<<5; in[i] = i<4 ? uint32_t(0u-i) : state; }
            for (uint32_t i=0;i<n+8;i++) out[i]=guard;
            memset(readback.contents,0,n*4);
            id<MTLCommandQueue> queue = [device newCommandQueue];
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:store]; [encoder setBuffer:output offset:16 atIndex:0]; [encoder setBuffer:input offset:0 atIndex:1];
            [encoder dispatchThreads:MTLSizeMake(n+3,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)]; [encoder endEncoding];
            encoder = [command computeCommandEncoder]; [encoder setComputePipelineState:read];
            [encoder setBuffer:output offset:16 atIndex:0]; [encoder setBuffer:readback offset:0 atIndex:1];
            [encoder dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)]; [encoder endEncoding];
            [command commit]; submitted=true; [command waitUntilCompleted]; completed=command.status==MTLCommandBufferStatusCompleted; error=command.error;
            auto* rb=(uint32_t*)readback.contents;
            for(uint32_t i=0;i<n;i++) { mismatches += out[i+4]!=in[i]; mismatches += rb[i]!=in[(i*40503u)&65535u]; }
            for(uint32_t i=0;i<4;i++) { guardMismatches += out[i]!=guard; guardMismatches += out[n+4+i]!=guard; }
        }
        bool passed = submitted && completed && !mismatches && !guardMismatches;
        allPassed &= passed;
        [results addObject:@{@"signed":@(signedType),@"fastMath":@(fast),@"passed":@(passed),@"storePipelineCreated":@(store!=nil),@"readPipelineCreated":@(read!=nil),@"storeError":storeError,@"readError":readError,@"GPUCommandsSubmitted":@(submitted),@"GPUCompleted":@(completed),@"wordsVerified":@(submitted ? n*2 : 0),@"mismatches":@(mismatches),@"guardMismatches":@(guardMismatches),@"error":error.localizedDescription?:@""}];
        if(!store || !read) goto finish;
    }
finish:
    NSDictionary* result=@{@"device":device.name,@"passed":@(allPassed),@"cases":results,@"readMode":@(argv[2]),@"scope":@"32-bit coherent signed/unsigned scalar atomic store, followed by coherent GPU read in a separate encoder; host input oracle and guard words. Not full Vulkan memory-model conformance."};
    NSData* data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@(argv[1]) atomically:YES]; fwrite(data.bytes,1,data.length,stdout);puts("");
    return allPassed ? 0 : 5;
}}
