// Reproduces MTLBinaryArchive lifetime growth on a long-lived worker thread.
// "literal" intentionally uses an autoreleased NSArray; "owned" balances the
// temporary array explicitly. Both modes create the same real Metal pipelines
// and finish with a GPU draw/readback check.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <chrono>

struct StressContext {
    id<MTLDevice> device;
    id<MTLFunction> vertex;
    id<MTLFunction> fragment;
    NSString* archivePath;
    const char* mode;
    unsigned iterations;
    uint64_t before;
    uint64_t after;
    unsigned created;
    double archivedMilliseconds;
    double rehydratedMilliseconds;
};

static uint64_t footprint() {
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

static void bindArchive(id descriptor, id<MTLBinaryArchive> archive, bool owned) {
    if (owned) {
        NSArray* archives = [[NSArray alloc] initWithObjects:archive, nil];
        [descriptor setBinaryArchives:archives];
        [archives release];
    } else {
        [descriptor setBinaryArchives:@[archive]];
    }
}

static MTLRenderPipelineDescriptor* makeDescriptor(StressContext* c) {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = c->vertex;
    d.fragmentFunction = c->fragment;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    return d;
}

static void* runStress(void* opaque) {
    StressContext* c = (StressContext*)opaque;
    bool owned = strcmp(c->mode, "literal");
    bool persistent = !strcmp(c->mode, "persistent") || !strcmp(c->mode, "cleared") ||
                      !strcmp(c->mode, "rehydrated");
    bool cleared = !strcmp(c->mode, "cleared");
    bool rehydrated = !strcmp(c->mode, "rehydrated");
    NSMutableArray* retainedDescriptors = persistent ? [[NSMutableArray alloc] init] : nil;
    NSMutableArray* retainedPipelines = persistent ? [[NSMutableArray alloc] init] : nil;
    c->before = footprint();
    for (unsigned i = 0; i < c->iterations; ++i) {
        MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
        ad.url = [NSURL fileURLWithPath:c->archivePath];
        NSError* error = nil;
        id<MTLBinaryArchive> archive = [c->device newBinaryArchiveWithDescriptor:ad error:&error];
        [ad release];
        if (!archive) continue;
        MTLRenderPipelineDescriptor* d = makeDescriptor(c);
        bindArchive(d, archive, owned);
        auto archivedStart = std::chrono::steady_clock::now();
        id<MTLRenderPipelineState> pso = [c->device newRenderPipelineStateWithDescriptor:d
            options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
        c->archivedMilliseconds += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - archivedStart).count();
        if (rehydrated && pso) {
            // The archive hit warms the driver's native pipeline cache. Build
            // the retained state from the same descriptor without an archive,
            // then discard the archive-backed temporary state.
            d.binaryArchives = nil;
            auto rehydrateStart = std::chrono::steady_clock::now();
            id<MTLRenderPipelineState> detached = [c->device newRenderPipelineStateWithDescriptor:d error:&error];
            c->rehydratedMilliseconds += std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - rehydrateStart).count();
            [pso release];
            pso = detached;
        }
        if (pso) c->created++;
        // MoltenVK keeps pipeline descriptors and pipeline states alive as part
        // of the Vulkan pipeline. Model that lifetime explicitly. Once Metal
        // has created the immutable pipeline state, the descriptor no longer
        // needs to retain the archive used to create it.
        if (cleared) d.binaryArchives = nil;
        if (persistent) {
            [retainedDescriptors addObject:d];
            if (pso) [retainedPipelines addObject:pso];
        }
        [pso release];
        [d release];
        [archive release];
    }
    c->after = footprint();
    const char* hold = getenv("MVK_ARCHIVE_STRESS_HOLD_SECONDS");
    if (hold && strtoul(hold, nullptr, 10)) {
        printf("hold_pid=%d\n", getpid());
        fflush(stdout);
        sleep((unsigned)strtoul(hold, nullptr, 10));
    }
    [retainedPipelines release];
    [retainedDescriptors release];
    return nullptr;
}

static bool drawAndCheck(StressContext* c) {
    NSError* error = nil;
    MTLRenderPipelineDescriptor* d = makeDescriptor(c);
    id<MTLRenderPipelineState> pso = [c->device newRenderPipelineStateWithDescriptor:d error:&error];
    [d release];
    if (!pso) return false;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:8 height:8 mipmapped:NO];
    td.storageMode = c->device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [c->device newTextureWithDescriptor:td];
    id<MTLCommandQueue> queue = [c->device newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:pso];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    if (!c->device.hasUnifiedMemory) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:texture];
        [blit endEncoding];
    }
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t pixels[8 * 8 * 4] = {};
    [texture getBytes:pixels bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    unsigned red = 0;
    for (unsigned i = 0; i < 64; ++i) if (pixels[i * 4 + 2] > 200 && pixels[i * 4 + 1] < 20) red++;
    bool passed = cb.status == MTLCommandBufferStatusCompleted && red >= 20;
    if (!passed) fprintf(stderr, "draw status=%lu red=%u firstBGRA=%u,%u,%u,%u error=%s\n",
        (unsigned long)cb.status, red, pixels[0], pixels[1], pixels[2], pixels[3],
        cb.error.localizedDescription.UTF8String ?: "");
    [texture release]; [queue release]; [pso release];
    return passed;
}

int main(int argc, char** argv) {
    if (argc != 4 || (strcmp(argv[1], "literal") && strcmp(argv[1], "owned") &&
                      strcmp(argv[1], "persistent") && strcmp(argv[1], "cleared") &&
                      strcmp(argv[1], "rehydrated"))) {
        fprintf(stderr, "usage: %s literal|owned|persistent|cleared|rehydrated iterations archive-path\n", argv[0]);
        return 2;
    }
    @autoreleasepool {
        NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
        id<MTLDevice> device = nil;
        for (id<MTLDevice> d in devices) if ([d.name containsString:@"AMD Radeon Pro 5600M"]) device = d;
        if (!device) { fprintf(stderr, "AMD Radeon Pro 5600M not found\n"); return 3; }
        [device retain]; [devices release];
        NSError* error = nil;
        NSString* source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 lifetime_vs(uint vid [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[vid],0,1);}\n"
            "fragment float4 lifetime_fs() { return float4(1,0,0,1);}\n";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr, "library: %s\n", error.localizedDescription.UTF8String); return 4; }
        StressContext c = {device, [library newFunctionWithName:@"lifetime_vs"],
            [library newFunctionWithName:@"lifetime_fs"], [NSString stringWithUTF8String:argv[3]], argv[1],
            (unsigned)strtoul(argv[2], nullptr, 10), 0, 0, 0, 0, 0};
        if (!c.vertex || !c.fragment || !c.iterations) return 5;

        if (![[NSFileManager defaultManager] fileExistsAtPath:c.archivePath]) {
            MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
            id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:ad error:&error];
            [ad release];
            MTLRenderPipelineDescriptor* d = makeDescriptor(&c);
            bindArchive(d, archive, true);
            bool added = [archive addRenderPipelineFunctionsWithDescriptor:d error:&error];
            [d release];
            bool saved = added && [archive serializeToURL:[NSURL fileURLWithPath:c.archivePath] error:&error];
            [archive release];
            if (!saved) { fprintf(stderr, "archive: %s\n", error.localizedDescription.UTF8String); return 6; }
        }

        pthread_t worker;
        if (pthread_create(&worker, nullptr, runStress, &c) || pthread_join(worker, nullptr)) return 7;
        bool gpu = drawAndCheck(&c);
        printf("mode=%s iterations=%u created=%u before=%llu after=%llu delta=%lld archived_avg_ms=%.3f rehydrated_avg_ms=%.3f gpu=%s\n",
            c.mode, c.iterations, c.created, (unsigned long long)c.before, (unsigned long long)c.after,
            (long long)(c.after - c.before), c.archivedMilliseconds / c.iterations,
            c.rehydratedMilliseconds / c.iterations, gpu ? "PASS" : "FAIL");
        [c.vertex release]; [c.fragment release]; [library release]; [device release];
        return c.created == c.iterations && gpu ? 0 : 8;
    }
}
