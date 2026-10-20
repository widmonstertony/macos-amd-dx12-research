#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <cstdio>
#include <mutex>

// Compile/link control only. Reads explicitly supplied local sources. The
// fixture must be a depth-only, single-sample mesh pipeline. No game launch,
// GPU shader dispatch, retries, or proprietary driver modifications.
int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 4) return 2;
    NSError* error = nil;
    NSDictionary* input = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:@(argv[1])] options:0 error:&error];
    if (!input) return 3;
    NSString* mode = @(argv[2]);
    bool mixed = ![mode isEqualToString:@"mesh-only"];
    bool allGate = [mode isEqualToString:@"all-gated"];
    bool synchronous = [mode isEqualToString:@"synchronous"];
    id<MTLDevice> device = nil;
    NSArray* devices = MTLCopyAllDevices();
    for (id<MTLDevice> d in devices)
        if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = d;
    if (!device) return 4;
    NSString* text = input[@"descriptorText"];
    if (![text containsString:@"depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm"] ||
        ![text containsString:@"stencilAttachmentPixelFormat = MTLPixelFormatInvalid"]) return 5;
    NSMutableArray* meshFunctions = [NSMutableArray array];
    for (NSString* stage in @[@"object", @"mesh", @"fragment"]) {
        NSDictionary* item = input[@"functions"][stage];
        NSString* source = [NSString stringWithContentsOfFile:item[@"source"]
            encoding:NSUTF8StringEncoding error:&error];
        if (!source) return 6;
        NSDictionary* provenance = item[@"compileProvenance"];
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.languageVersion = (MTLLanguageVersion)[provenance[@"languageVersion"] unsignedIntegerValue];
        options.mathMode = (MTLMathMode)[provenance[@"mathMode"] unsignedIntegerValue];
        options.mathFloatingPointFunctions = (MTLMathFloatingPointFunctions)[provenance[@"mathFloatingPointFunctions"] unsignedIntegerValue];
        options.preserveInvariance = [provenance[@"preserveInvariance"] boolValue];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        id<MTLFunction> f = [library newFunctionWithName:item[@"entry"]];
        if ([mode isEqualToString:@"constant-reflection"] && f)
            fprintf(stderr,"constant-count=%lu\n",(unsigned long)f.functionConstantsDictionary.count);
        [library release]; [options release];
        if (!f) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 7; }
        [meshFunctions addObject:f]; [f release];
    }
    NSMutableArray* vertexFunctions = [NSMutableArray array];
    if (mixed) for (unsigned i = 0; i < 8; ++i) {
        // Same common generated type/entry names, different valid interfaces.
        NSString* vertex = [NSString stringWithFormat:
            @"#include <metal_stdlib>\nusing namespace metal;\nstruct main0_out { float4 p [[position]]; float4 c [[user(locn%u)]]; };\nvertex main0_out main0(uint id [[vertex_id]]) { main0_out o; o.p=float4(float(id),0,0,1); o.c=float4(%u.0); return o; }",i,i];
        NSString* fragment = [NSString stringWithFormat:
            @"#include <metal_stdlib>\nusing namespace metal;\nstruct main0_in { float4 c [[user(locn%u)]]; };\nfragment float4 main0(main0_in in [[stage_in]]) { return in.c; }",i];
        NSMutableArray* pair = [NSMutableArray array];
        for (NSString* source in @[vertex,fragment]) {
            MTLCompileOptions* options = [MTLCompileOptions new];
            options.languageVersion = MTLLanguageVersion4_0;
            id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
            id<MTLFunction> f = [library newFunctionWithName:@"main0"];
            [library release]; [options release];
            if (!f) return 8;
            [pair addObject:f]; [f release];
        }
        [vertexFunctions addObject:pair];
    }
    dispatch_semaphore_t meshGate = dispatch_semaphore_create(1);
    dispatch_semaphore_t slots = dispatch_semaphore_create(8);
    NSMutableArray* rows = [NSMutableArray array];
    unsigned requests = mixed ? 128 : 32;
    dispatch_apply(requests, dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^(size_t i) { @autoreleasepool {
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        bool mesh = !mixed || i % 2 == 0;
        bool gated = mesh || allGate;
        if (gated) dispatch_semaphore_wait(meshGate,DISPATCH_TIME_FOREVER);
        __block id<MTLRenderPipelineState> pipeline = nil;
        __block NSError* failure = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        if (mesh) {
            MTLMeshRenderPipelineDescriptor* descriptor = [MTLMeshRenderPipelineDescriptor new];
            descriptor.objectFunction = meshFunctions[0]; descriptor.meshFunction = meshFunctions[1];
            descriptor.fragmentFunction = meshFunctions[2];
            descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;
            descriptor.rasterSampleCount = 1;
            if (synchronous) pipeline = [device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&failure];
            else [device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone
                completionHandler:^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection* reflection, NSError* e) {
                    pipeline = [p retain]; failure = [e retain]; dispatch_semaphore_signal(done);
                }];
            [descriptor release];
        } else {
            NSArray* pair = vertexFunctions[(i / 2) % vertexFunctions.count];
            MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = pair[0]; descriptor.fragmentFunction = pair[1];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            if (synchronous) pipeline = [device newRenderPipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&failure];
            else [device newRenderPipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone
                completionHandler:^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection* reflection, NSError* e) {
                    pipeline = [p retain]; failure = [e retain]; dispatch_semaphore_signal(done);
                }];
            [descriptor release];
        }
        if (!synchronous) dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
        if (gated) dispatch_semaphore_signal(meshGate);
        NSDictionary* row = @{@"request":@(i),@"mesh":@(mesh),@"created":@(pipeline != nil),
            @"error":failure.localizedDescription ?: @""};
        @synchronized(rows) { [rows addObject:row]; }
        [pipeline release]; if (!synchronous) [failure release];
        dispatch_release(done); dispatch_semaphore_signal(slots);
    }});
    unsigned failures = 0;
    for (NSDictionary* row in rows) if (![row[@"created"] boolValue]) ++failures;
    NSDictionary* report = @{@"mode":mode,@"device":device.name,@"requests":@(requests),
        @"failures":@(failures),@"rows":rows,@"GPUWorkDispatched":@NO,
        @"descriptorStateApproximate":@YES,@"runtimeFailureEquivalenceProven":@NO};
    NSData* output = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    bool saved = [output writeToFile:@(argv[3]) options:NSDataWritingAtomic error:&error];
    printf("requests=%u failures=%u\n",requests,failures);
    dispatch_release(meshGate); dispatch_release(slots); [devices release];
    return saved ? 0 : 9;
} }
