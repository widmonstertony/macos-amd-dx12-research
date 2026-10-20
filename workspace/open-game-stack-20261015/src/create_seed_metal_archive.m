/* Create and execute one real compute shader in a private archive fixture. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    @autoreleasepool {
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        id<MTLDevice> selected = nil;
        for (id<MTLDevice> device in devices)
            if ([device.name containsString:@"AMD Radeon Pro 5600M"]) selected = device;
        if (!selected) return 3;
        MTLBinaryArchiveDescriptor *descriptor = [MTLBinaryArchiveDescriptor new];
        NSError *error = nil;
        id<MTLBinaryArchive> archive = [selected newBinaryArchiveWithDescriptor:descriptor error:&error];
        id<MTLLibrary> library = [selected newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void archive_seed(device uint* output [[buffer(0)]], uint tid [[thread_position_in_grid]]) { output[tid] = tid + 1; }" options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"archive_seed"];
        MTLComputePipelineDescriptor *pipelineDescriptor = [MTLComputePipelineDescriptor new];
        pipelineDescriptor.computeFunction = function;
        BOOL added = archive && function && [archive addComputePipelineFunctionsWithDescriptor:pipelineDescriptor error:&error];
        pipelineDescriptor.binaryArchives = archive ? @[archive] : @[];
        id<MTLComputePipelineState> pipeline = added ? [selected newComputePipelineStateWithDescriptor:pipelineDescriptor options:MTLPipelineOptionNone reflection:nil error:&error] : nil;
        id<MTLBuffer> output = [selected newBufferWithLength:16 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [selected newCommandQueue];
        BOOL pixels = pipeline && output && queue;
        if (pixels) {
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:output offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(16,1,1) threadsPerThreadgroup:MTLSizeMake(16,1,1)];
            [encoder endEncoding]; [commands commit]; [commands waitUntilCompleted];
            pixels = commands.status == MTLCommandBufferStatusCompleted;
            uint32_t *values = output.contents;
            for (unsigned i=0; i<16; ++i) if (values[i] != i+1) pixels = NO;
        }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        BOOL ok = pixels && ![[NSFileManager defaultManager] fileExistsAtPath:url.path] && [archive serializeToURL:url error:&error];
        printf("seed_archive.gpu_output=%s created=%s\n", pixels ? "PASS" : "FAIL", ok ? "PASS" : "FAIL");
        if (!ok) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String ?: "archive unavailable");
        [queue release]; [output release]; [pipeline release]; [pipelineDescriptor release]; [function release]; [library release];
        [archive release]; [descriptor release]; [devices release];
        return ok ? 0 : 4;
    }
}
