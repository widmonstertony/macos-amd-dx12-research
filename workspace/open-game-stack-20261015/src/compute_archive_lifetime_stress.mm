// Reproduces archive-backed compute-pipeline lifetime on Intel macOS AMD.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <chrono>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t footprint() {
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? info.phys_footprint : 0;
}

static MTLComputePipelineDescriptor* makeDescriptor(id<MTLFunction> function) {
    MTLComputePipelineDescriptor* d = [MTLComputePipelineDescriptor new];
    d.computeFunction = function;
    d.maxTotalThreadsPerThreadgroup = 64;
    return d;
}

static void bindArchive(id descriptor, id<MTLBinaryArchive> archive) {
    NSArray* archives = [[NSArray alloc] initWithObjects:archive, nil];
    [descriptor setBinaryArchives:archives];
    [archives release];
}

static bool executeAndCheck(id<MTLDevice> device, id<MTLComputePipelineState> pso) {
    id<MTLBuffer> buffer = [device newBufferWithLength:64 * sizeof(uint32_t)
        options:device.hasUnifiedMemory ? MTLResourceStorageModeShared : MTLResourceStorageModeManaged];
    memset(buffer.contents, 0, buffer.length);
    if (!device.hasUnifiedMemory) [buffer didModifyRange:NSMakeRange(0, buffer.length)];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBuffer:buffer offset:0 atIndex:0];
    [enc dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [enc endEncoding];
    if (!device.hasUnifiedMemory) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:buffer];
        [blit endEncoding];
    }
    [cb commit]; [cb waitUntilCompleted];
    uint32_t* words = (uint32_t*)buffer.contents;
    bool pass = cb.status == MTLCommandBufferStatusCompleted;
    for (uint32_t i = 0; i < 64 && pass; ++i) pass = words[i] == i * 3 + 7;
    [buffer release]; [queue release];
    return pass;
}

int main(int argc, char** argv) {
    if (argc != 4 || (strcmp(argv[1], "persistent") && strcmp(argv[1], "rehydrated"))) {
        fprintf(stderr, "usage: %s persistent|rehydrated iterations archive-path\n", argv[0]);
        return 2;
    }
    @autoreleasepool {
        NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
        id<MTLDevice> device = nil;
        for (id<MTLDevice> d in devices) if ([d.name containsString:@"AMD Radeon Pro 5600M"]) device = d;
        if (!device) return 3;
        [device retain]; [devices release];
        NSError* error = nil;
        NSString* source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void lifetime_cs(device uint* out [[buffer(0)]], uint tid [[thread_position_in_grid]]) { if (tid < 64) out[tid] = tid * 3 + 7; }\n";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"lifetime_cs"];
        NSString* path = [NSString stringWithUTF8String:argv[3]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
            id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:ad error:&error];
            [ad release];
            MTLComputePipelineDescriptor* d = makeDescriptor(function);
            bindArchive(d, archive);
            bool added = [archive addComputePipelineFunctionsWithDescriptor:d error:&error];
            bool saved = added && [archive serializeToURL:[NSURL fileURLWithPath:path] error:&error];
            [d release]; [archive release];
            if (!saved) return 4;
        }
        unsigned iterations = (unsigned)strtoul(argv[2], nullptr, 10);
        bool rehydrated = !strcmp(argv[1], "rehydrated");
        NSMutableArray* descriptors = [[NSMutableArray alloc] init];
        NSMutableArray* pipelines = [[NSMutableArray alloc] init];
        uint64_t before = footprint(); unsigned created = 0; double hitMS = 0, rehydrateMS = 0;
        for (unsigned i = 0; i < iterations; ++i) {
            MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new]; ad.url = [NSURL fileURLWithPath:path];
            id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:ad error:&error]; [ad release];
            MTLComputePipelineDescriptor* d = makeDescriptor(function); bindArchive(d, archive);
            auto start = std::chrono::steady_clock::now();
            id<MTLComputePipelineState> pso = [device newComputePipelineStateWithDescriptor:d
                options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
            hitMS += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
            if (rehydrated && pso) {
                d.binaryArchives = nil; start = std::chrono::steady_clock::now();
                id<MTLComputePipelineState> detached = [device newComputePipelineStateWithDescriptor:d
                    options:MTLPipelineOptionNone reflection:nil error:&error];
                rehydrateMS += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
                [pso release]; pso = detached;
            }
            if (pso) { created++; [pipelines addObject:pso]; }
            [descriptors addObject:d]; [pso release]; [d release]; [archive release];
        }
        uint64_t after = footprint();
        const char* hold = getenv("MVK_ARCHIVE_STRESS_HOLD_SECONDS");
        if (hold && strtoul(hold, nullptr, 10)) { printf("hold_pid=%d\n", getpid()); fflush(stdout); sleep((unsigned)strtoul(hold, nullptr, 10)); }
        bool gpu = pipelines.count && executeAndCheck(device, pipelines.lastObject);
        printf("mode=%s iterations=%u created=%u delta=%lld hit_avg_ms=%.3f rehydrate_avg_ms=%.3f gpu=%s\n",
            argv[1], iterations, created, (long long)(after-before), hitMS/iterations, rehydrateMS/iterations, gpu?"PASS":"FAIL");
        [pipelines release]; [descriptors release]; [function release]; [library release]; [device release];
        return created == iterations && gpu ? 0 : 5;
    }
}
