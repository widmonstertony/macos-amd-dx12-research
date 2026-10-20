#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Owned, bounded compiler-only reproducer. Never dispatches captured game code.
int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 4) return 2;
    id<MTLDevice> device = nil;
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = d;
    if (!device) return 3;
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion4_0;
    bool fast = !strcmp(argv[3], "fast");
    options.mathMode = fast ? MTLMathModeFast : MTLMathModeSafe;
    options.mathFloatingPointFunctions = fast ? MTLMathFloatingPointFunctionsFast : MTLMathFloatingPointFunctionsPrecise;
    fprintf(stderr, "PHASE library\n"); fflush(stderr);
    id<MTLLibrary> library = source ? [device newLibraryWithSource:source options:options error:&error] : nil;
    id<MTLFunction> function = [library newFunctionWithName:@"main0"];
    __block id<MTLComputePipelineState> pipeline = nil;
    __block NSError* pipelineError = nil;
    bool timedOut = false;
    if (function) {
        MTLComputePipelineDescriptor* descriptor = [MTLComputePipelineDescriptor new];
        descriptor.computeFunction = function;
        descriptor.maxTotalThreadsPerThreadgroup = strtoul(argv[2], nullptr, 10);
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = NO;
        fprintf(stderr, "PHASE compute-pipeline\n"); fflush(stderr);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone
            completionHandler:^(id<MTLComputePipelineState> state, MTLComputePipelineReflection*, NSError* e) {
                pipeline = state; pipelineError = e; dispatch_semaphore_signal(done);
            }];
        timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0;
    }
    NSDictionary* result = @{
        @"device":device.name, @"libraryCreated":@(library != nil),
        @"functionCreated":@(function != nil), @"pipelineCreated":@(pipeline != nil),
        @"timedOut":@(timedOut), @"mathMode":@(argv[3]),
        @"maxThreads":@(strtoul(argv[2], nullptr, 10)),
        @"error":pipelineError.localizedDescription ?: error.localizedDescription ?: @"",
        @"errorCode":@(pipelineError ? pipelineError.code : error.code),
        @"GPUCommandsSubmitted":@NO
    };
    NSData* json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes, 1, json.length, stdout); puts(""); fflush(stdout);
    return pipeline ? 0 : timedOut ? 9 : 5;
}}
