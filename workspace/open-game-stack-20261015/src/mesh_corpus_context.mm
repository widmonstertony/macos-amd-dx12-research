#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>

// Source-order context control. All source paths are supplied explicitly and
// remain local. No game, shader dispatch, retries, or driver binary changes.
#include "metal_link_repro_common.h"
int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 6) return 2;
    NSError* error = nil;
    NSDictionary* input = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:&error];
    NSArray* supplied = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[2])] options:0 error:&error];
    NSString* mode = @(argv[3]); unsigned workers = (unsigned)strtoul(argv[4],nullptr,10);
    if (!input || !supplied || workers < 1 || workers > 8) return 3;
    bool targetFirst = [mode containsString:@"target-first"];
    bool exactOnly = [mode containsString:@"exact-only"];
    bool reverse = [mode containsString:@"reverse"];
    NSArray* devices = MTLCopyAllDevices(); id<MTLDevice> device = nil;
    for (id<MTLDevice> d in devices) if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device=d;
    if (!device) return 4;
    NSString* description = input[@"descriptorText"];
    if (![description containsString:@"depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm"] ||
        ![description containsString:@"stencilAttachmentPixelFormat = MTLPixelFormatInvalid"]) return 5;
    NSMutableArray* libraries = [NSMutableArray array];
    NSMutableArray* heldFunctions = [NSMutableArray array];
    NSArray* target = nil;
    if (targetFirst) target = targetFunctions(device,input,libraries,&error);
    if (targetFirst && !target) return 6;
    NSMutableArray* items = [NSMutableArray array];
    for (NSDictionary* item in supplied) if (!exactOnly || [item[@"exactOptionsKnown"] boolValue]) [items addObject:item];
    if (reverse) items = [[[items reverseObjectEnumerator] allObjects] mutableCopy];
    NSMutableArray* rows = [NSMutableArray array];
    dispatch_semaphore_t slots = dispatch_semaphore_create(workers);
    dispatch_apply(items.count,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t i) { @autoreleasepool {
        dispatch_semaphore_wait(slots,DISPATCH_TIME_FOREVER);
        NSDictionary* item = items[i]; NSError* failure = nil;
        NSString* source = [NSString stringWithContentsOfFile:item[@"source"] encoding:NSUTF8StringEncoding error:&failure];
        id<MTLLibrary> library = source ? [device newLibraryWithSource:source options:compileOptions(item[@"compileProvenance"]) error:&failure] : nil;
        id<MTLFunction> function = library ? [library newFunctionWithName:item[@"entry"]] : nil;
        if (function) (void)function.functionConstantsDictionary.allValues;
        NSDictionary* row = @{@"index":@(i),@"sourceSHA256":item[@"sourceSHA256"],@"libraryCreated":@(library != nil),
            @"functionCreated":@(function != nil),@"error":failure.localizedDescription ?: @"",@"exactOptionsKnown":item[@"exactOptionsKnown"]};
        @synchronized(libraries) {
            if (library) [libraries addObject:library];
            if (function) [heldFunctions addObject:function];
            [rows addObject:row];
            if (rows.count%64==0) { fprintf(stderr,"compiled %lu/%lu\n",(unsigned long)rows.count,(unsigned long)items.count); fflush(stderr); }
        }
        [library release]; [function release]; dispatch_semaphore_signal(slots);
    }});
    if (!targetFirst) target = targetFunctions(device,input,libraries,&error);
    id<MTLRenderPipelineState> pipeline = nil;
    if (target.count==3) {
        MTLMeshRenderPipelineDescriptor* descriptor = [MTLMeshRenderPipelineDescriptor new];
        descriptor.objectFunction=target[0]; descriptor.meshFunction=target[1]; descriptor.fragmentFunction=target[2];
        descriptor.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;descriptor.rasterSampleCount=1;
        pipeline=[device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
        [descriptor release];
    }
    unsigned libraryFailures=0;
    for (NSDictionary* row in rows) if (![row[@"libraryCreated"] boolValue]) ++libraryFailures;
    NSDictionary* report=@{@"mode":mode,@"workers":@(workers),@"device":device.name,@"preludeSources":@(items.count),
        @"preludeLibraryFailures":@(libraryFailures),@"prelude":rows,@"targetFunctionCount":@(target.count),
        @"pipelineCreated":@(pipeline != nil),@"error":error.localizedDescription ?: @"",@"errorCode":@(error.code),
        @"GPUWorkDispatched":@NO,@"descriptorStateApproximate":@YES,@"actualGameCompatibilityProven":@NO};
    NSData* output=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    bool saved=[output writeToFile:@(argv[5]) options:NSDataWritingAtomic error:nil];
    printf("prelude=%lu libraryFailures=%u targetCreated=%d error=%s\n",(unsigned long)items.count,libraryFailures,pipeline!=nil,error.localizedDescription.UTF8String ?: "");
    [pipeline release];dispatch_release(slots);[devices release]; return saved ? 0 : 7;
} }
