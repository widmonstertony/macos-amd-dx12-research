#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>

// Recreate the observed order of complete mesh shader triples in one process.
// This is a linkage control: no GPU commands; non-depth descriptor state is
// approximate and results must not be presented as full game reproduction.
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    NSArray *items = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
    id<MTLDevice> device = nil;
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = d;
    if (!device || !items) return 3;
    NSMutableDictionary *functions = [NSMutableDictionary dictionary];
    NSMutableArray *results = [NSMutableArray array];
    void (^process)(NSDictionary *) = ^(NSDictionary *item) { @autoreleasepool {
        NSArray *files = item[@"files"];
        NSMutableArray *stages = [NSMutableArray array];
        NSError *error = nil;
        for (unsigned stage = 0; stage < 3; ++stage) {
            NSString *path = files[stage];
            id<MTLFunction> function = nil;
            @synchronized (functions) { function = functions[path]; }
            if (!function) {
                NSString *source = [NSString stringWithContentsOfFile:path
                    encoding:NSUTF8StringEncoding error:&error];
                MTLCompileOptions *options = [MTLCompileOptions new];
                options.languageVersion = MTLLanguageVersion4_0;
                options.mathMode = MTLMathModeSafe;
                options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
                options.preserveInvariance = stage < 2;
                id<MTLLibrary> library = [device newLibraryWithSource:source
                    options:options error:&error];
                function = [library newFunctionWithName:@"main0"];
                if (function) { @synchronized (functions) { functions[path] = function; } }
            }
            if (!function) break;
            [stages addObject:function];
        }
        id<MTLRenderPipelineState> pipeline = nil;
        if (stages.count == 3) {
            MTLMeshRenderPipelineDescriptor *descriptor = [MTLMeshRenderPipelineDescriptor new];
            descriptor.objectFunction = stages[0];
            descriptor.meshFunction = stages[1];
            descriptor.fragmentFunction = stages[2];
            descriptor.rasterSampleCount = 1;
            descriptor.depthAttachmentPixelFormat = [item[@"depth16"] boolValue]
                ? MTLPixelFormatDepth16Unorm : MTLPixelFormatDepth32Float;
            pipeline = [device newRenderPipelineStateWithMeshDescriptor:descriptor
                options:MTLPipelineOptionNone reflection:nil error:&error];
        }
        NSDictionary *result = @{@"sequence":item[@"sequence"],
            @"created":@(pipeline != nil), @"runtimeCreated":item[@"runtimeCreated"],
            @"error":error.localizedDescription ?: @""};
        @synchronized (results) { [results addObject:result]; }
        fprintf(stderr,"sequence %u created=%d %s\n",
            [item[@"sequence"] unsignedIntValue],pipeline != nil,
            error.localizedDescription.UTF8String ?: "");
        fflush(stderr);
    }};
    bool concurrent = getenv("REPRO_MESH_CONCURRENT") != nullptr;
    if (concurrent) {
        dispatch_semaphore_t slots = dispatch_semaphore_create(4);
        dispatch_apply(items.count, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
            dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
            process(items[i]);
            dispatch_semaphore_signal(slots);
        });
    } else { for (NSDictionary *item in items) process(item); }
    NSDictionary *output = @{@"results":results, @"GPUCommandsSubmitted":@NO,
        @"descriptorStateApproximate":@YES, @"concurrent":@(concurrent), @"device":device.name};
    NSData *data = [NSJSONSerialization dataWithJSONObject:output
        options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes,1,data.length,stdout); puts("");
    return 0;
}}
