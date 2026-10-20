// Opt-in per-source native compute archives. Cold compilation remains normal;
// publication follows successful compilation and never holds the device monitor.
#pragma once
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <mutex>

static uint64_t mvkComputeArchiveLimit(const char* name, uint64_t fallback) {
    const char* value = getenv(name);
    if (!value) return fallback;
    char* end = nullptr;
    uint64_t parsed = strtoull(value, &end, 10);
    return end && !*end && parsed ? parsed : fallback;
}

static NSString* mvkComputeShardPath(MTLComputePipelineDescriptor* descriptor) {
    const char* rootC = getenv("MVK_AMD_COMPUTE_ARCHIVE_DIR");
    if (!rootC || rootC[0] != '/') return nil;
    NSString* label = descriptor.label;
    if (![label hasPrefix:@"mvk-cs2-"] || label.length != 72) return nil;
    NSString* key = [label substringFromIndex:8];
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    if ([key rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    NSString* root = [NSString stringWithUTF8String:rootC];
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&directory] || !directory)
        return nil;
    NSString* name = [NSString stringWithFormat:@"cs2-%@-%lu-%u.metalar", key,
        (unsigned long)descriptor.maxTotalThreadsPerThreadgroup,
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth ? 1 : 0];
    return [root stringByAppendingPathComponent:name];
}

static bool mvkLoadComputeShard(id<MTLDevice> device,
                               MTLComputePipelineDescriptor* descriptor, NSString* path) {
    if (!path) return false;
    struct stat info {};
    uint64_t limit = mvkComputeArchiveLimit("MVK_AMD_COMPUTE_ARCHIVE_MAX_SHARD_BYTES", 16ull << 20);
    if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || (uint64_t)info.st_size >= limit) return false;
    MTLBinaryArchiveDescriptor* archiveDescriptor = [MTLBinaryArchiveDescriptor new];
    archiveDescriptor.url = [NSURL fileURLWithPath:path];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
    [archiveDescriptor release];
    if (!archive) return false;
    descriptor.binaryArchives = @[archive]; // The descriptor retains this request's archive.
    [archive release];
    return true;
}

// A process-local admission budget includes existing owned shard files. No cache
// eviction or deletion is performed. Separate processes sharing one directory
// can exceed this admission budget, so callers should use a per-game directory.
static bool mvkPublishComputeShard(NSString* temporary, NSString* path, uint64_t bytes,
                                  NSString* prefix = @"cs2-",
                                  const char* budgetName = "MVK_AMD_COMPUTE_ARCHIVE_MAX_TOTAL_BYTES") {
    static std::mutex budgetLock;
    static std::unordered_map<std::string, uint64_t> usage;
    std::lock_guard<std::mutex> lock(budgetLock);
    NSString* root = path.stringByDeletingLastPathComponent;
    std::string rootKey = std::string(root.fileSystemRepresentation) + ":" + prefix.UTF8String;
    auto entry = usage.find(rootKey);
    if (entry == usage.end()) {
        uint64_t existing = 0;
        for (NSString* name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
            if (![name hasPrefix:prefix] || ![name hasSuffix:@".metalar"]) continue;
            struct stat info {};
            NSString* file = [root stringByAppendingPathComponent:name];
            if (!lstat(file.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) && info.st_size > 0)
                existing += (uint64_t)info.st_size;
        }
        entry = usage.emplace(rootKey, existing).first;
    }
    uint64_t maximum = mvkComputeArchiveLimit(budgetName, 2ull << 30);
    if (entry->second > maximum || bytes > maximum - entry->second) return false;
    // Atomic create-only publication. Concurrent writers never overwrite an
    // existing archive, including an incompatible one retained for diagnosis.
    if (link(temporary.fileSystemRepresentation, path.fileSystemRepresentation)) return false;
    entry->second += bytes;
    return true;
}

static bool mvkStoreComputeShard(id<MTLDevice> device,
                                MTLComputePipelineDescriptor* descriptor, NSString* path) {
    if (!path || [[NSFileManager defaultManager] fileExistsAtPath:path]) return false;
    MTLBinaryArchiveDescriptor* archiveDescriptor = [MTLBinaryArchiveDescriptor new];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
    [archiveDescriptor release];
    if (!archive) return false;
    descriptor.binaryArchives = @[archive];
    bool added = [archive addComputePipelineFunctionsWithDescriptor:descriptor error:&error];
    NSString* temporary = [path stringByAppendingFormat:@".tmp.%@", [NSUUID UUID].UUIDString];
    bool serialized = added && [archive serializeToURL:[NSURL fileURLWithPath:temporary] error:&error];
    bool published = false;
    if (serialized) {
        struct stat info {};
        uint64_t limit = mvkComputeArchiveLimit("MVK_AMD_COMPUTE_ARCHIVE_MAX_SHARD_BYTES", 16ull << 20);
        if (!lstat(temporary.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) &&
            info.st_size > 0 && (uint64_t)info.st_size < limit)
            published = mvkPublishComputeShard(temporary, path, (uint64_t)info.st_size);
    }
    // Only this call's unique unpublished temporary is removed. Existing cache
    // files and all user assets are preserved, even when admission is refused.
    unlink(temporary.fileSystemRepresentation);
    [archive release];
    return published;
}
