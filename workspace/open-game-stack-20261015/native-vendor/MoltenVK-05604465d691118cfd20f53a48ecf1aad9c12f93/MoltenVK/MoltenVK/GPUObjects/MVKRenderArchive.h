// Opt-in bounded native vertex/fragment archives. Metal validates the complete
// descriptor on every warm load; a stale/incomplete archive falls back to normal
// compilation. No mesh archive support is implied by this path.
#pragma once
#include <CommonCrypto/CommonDigest.h>
#include <objc/runtime.h>
#include "MVKComputeArchive.h"

static const void* mvkFunctionRecipeAssociation() {
    return sel_registerName("mvkNativeFunctionRecipeV1");
}
static void mvkSetFunctionRecipe(id<MTLFunction> function, NSString* recipe) {
    objc_setAssociatedObject(function, mvkFunctionRecipeAssociation(), recipe, OBJC_ASSOCIATION_COPY);
}
static NSString* mvkFunctionRecipe(id<MTLFunction> function) {
    return objc_getAssociatedObject(function, mvkFunctionRecipeAssociation());
}
static bool mvkHasLinkedFunctions(MTLLinkedFunctions* linked) {
    return linked.functions.count || linked.binaryFunctions.count || linked.groups.count;
}

static NSString* mvkRenderShardPath(id<MTLDevice> device, MTLRenderPipelineDescriptor* d) {
    const char* rootC = getenv("MVK_AMD_RENDER_ARCHIVE_DIR");
    if (!rootC || rootC[0] != '/') return nil;
    NSString* vertex = mvkFunctionRecipe(d.vertexFunction);
    NSString* fragment = d.fragmentFunction ? mvkFunctionRecipe(d.fragmentFunction) : @"none";
    if (!vertex || !fragment) return nil;
    // Dynamic/linked libraries need their own reproducible compilation recipe.
    // Refuse this cache subset rather than keying opaque object addresses.
    if (d.vertexPreloadedLibraries.count || d.fragmentPreloadedLibraries.count ||
        mvkHasLinkedFunctions(d.vertexLinkedFunctions) || mvkHasLinkedFunctions(d.fragmentLinkedFunctions)) return nil;
    BOOL directory = NO;
    NSString* root = @(rootC);
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&directory] || !directory) return nil;
    NSMutableString* recipe = [NSMutableString stringWithFormat:@"rs1|%@|%llu|%@|%@|",
        NSProcessInfo.processInfo.operatingSystemVersionString,
        (unsigned long long)device.registryID, vertex, fragment];
    auto add = [&](uint64_t value) { [recipe appendFormat:@"%llu,", (unsigned long long)value]; };
    add(d.rasterSampleCount); add(d.alphaToCoverageEnabled); add(d.alphaToOneEnabled);
    add(d.rasterizationEnabled); add(d.maxVertexAmplificationCount);
    add(d.depthAttachmentPixelFormat); add(d.stencilAttachmentPixelFormat);
    add(d.inputPrimitiveTopology); add(d.supportIndirectCommandBuffers);
    add(d.tessellationPartitionMode); add(d.maxTessellationFactor);
    add(d.tessellationFactorScaleEnabled); add(d.tessellationFactorFormat);
    add(d.tessellationControlPointIndexType); add(d.tessellationFactorStepFunction);
    add(d.tessellationOutputWindingOrder);
    add(d.supportAddingVertexBinaryFunctions); add(d.supportAddingFragmentBinaryFunctions);
    add(d.maxVertexCallStackDepth); add(d.maxFragmentCallStackDepth);
    if (@available(macOS 15.0, iOS 18.0, *)) add(d.shaderValidation);
    for (NSUInteger i = 0; i < 8; ++i) {
        auto a = d.colorAttachments[i];
        add(a.pixelFormat); add(a.blendingEnabled); add(a.writeMask);
        add(a.sourceRGBBlendFactor); add(a.destinationRGBBlendFactor); add(a.rgbBlendOperation);
        add(a.sourceAlphaBlendFactor); add(a.destinationAlphaBlendFactor); add(a.alphaBlendOperation);
    }
    for (NSUInteger i = 0; i < 31; ++i) {
        auto a = d.vertexDescriptor.attributes[i];
        auto l = d.vertexDescriptor.layouts[i];
        add(a.format); add(a.offset); add(a.bufferIndex);
        add(l.stride); add(l.stepFunction); add(l.stepRate);
        add(d.vertexBuffers[i].mutability); add(d.fragmentBuffers[i].mutability);
    }
    NSData* bytes = [recipe dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return [root stringByAppendingPathComponent:[NSString stringWithFormat:@"rs1-%s.metalar", hex]];
}

static bool mvkLoadRenderShard(id<MTLDevice> device, MTLRenderPipelineDescriptor* descriptor, NSString* path) {
    if (!path) return false;
    struct stat info {};
    uint64_t limit = mvkComputeArchiveLimit("MVK_AMD_RENDER_ARCHIVE_MAX_SHARD_BYTES", 16ull << 20);
    if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || (uint64_t)info.st_size >= limit) return false;
    MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
    ad.url = [NSURL fileURLWithPath:path];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:ad error:&error];
    [ad release];
    if (!archive) return false;
    mvkSetBinaryArchive(descriptor, archive);
    [archive release];
    return true;
}

// Called only after normal compilation succeeds, outside the Metal-device
// monitor. Each archive holds one complete descriptor, never a growing global
// collection. Existing files are immutable, including stale/invalid ones.
static bool mvkStoreRenderShard(id<MTLDevice> device, MTLRenderPipelineDescriptor* descriptor, NSString* path) {
    if (!path || [[NSFileManager defaultManager] fileExistsAtPath:path]) return false;
    MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:ad error:&error];
    [ad release];
    if (!archive) return false;
    // A private copy leaves the successful compiler's original descriptor intact.
    MTLRenderPipelineDescriptor* writer = [descriptor copy];
    mvkSetBinaryArchive(writer, archive);
    uint64_t operation=mvkLinkOperationBegin(@"render-archive-add",writer.label);
    bool added = [archive addRenderPipelineFunctionsWithDescriptor:writer error:&error];
    mvkLinkOperationEnd(operation);
    NSString* temporary = [path stringByAppendingFormat:@".tmp.%@", NSUUID.UUID.UUIDString];
    bool serialized = added && [archive serializeToURL:[NSURL fileURLWithPath:temporary] error:&error];
    bool published = false;
    if (serialized) {
        struct stat info {};
        uint64_t limit = mvkComputeArchiveLimit("MVK_AMD_RENDER_ARCHIVE_MAX_SHARD_BYTES", 16ull << 20);
        if (!lstat(temporary.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) &&
            info.st_size > 0 && (uint64_t)info.st_size < limit)
            published = mvkPublishComputeShard(temporary, path, (uint64_t)info.st_size,
                @"rs1-", "MVK_AMD_RENDER_ARCHIVE_MAX_TOTAL_BYTES");
    }
    unlink(temporary.fileSystemRepresentation);
    [writer release]; [archive release];
    return published;
}
