// Opt-in research diagnostics only. No capability or pipeline behavior changes.
#pragma once
#include <atomic>
#include <unistd.h>
#include <sys/stat.h>
#include <objc/runtime.h>
#include <CommonCrypto/CommonDigest.h>
#include "MVKMeshLinkDifferential.h"
static inline bool mvkGPUTimeoutTraceEnabled() {
    static const bool enabled = [] { const char* v = getenv("MVK_AMD_GPU_TIMEOUT_TRACE"); return v && !strcmp(v, "1"); }();
    return enabled;
}
static inline bool mvkWorkTraceConfigured() {
    static const bool armed = [] { const char* v=getenv("MVK_AMD_GPU_WORK_TRACE_ARM_PATH"); return v && v[0]; }();
    return mvkGPUTimeoutTraceEnabled() || armed;
}
static inline bool mvkGPUFailureTraceEnabled() {
    static const bool enabled = [] { const char* v=getenv("MVK_AMD_QUEUE_FAILURE_CONTEXT"); return v && !strcmp(v,"1"); }();
    return enabled;
}
static inline bool mvkRuntimeTraceEnabled(const MVKConfiguration& config) {
    const char* value = getenv("MVK_AMD_RUNTIME_TRACE");
    return value && !strcmp(value, "1") && config.shaderDumpDir[0];
}
static inline bool mvkRuntimeReplayOnly() {
    const char* value = getenv("MVK_AMD_RUNTIME_REPLAY_ONLY");
    return value && !strcmp(value, "1");
}
static inline bool mvkRuntimeReplayEnabled(const MVKConfiguration& config) {
    const char* value = getenv("MVK_AMD_REPLAY_FAILED_MESH");
    return value && !strcmp(value, "1") && mvkRuntimeTraceEnabled(config);
}
// Opt-in timing of the complete compute construction path, including shader
// conversion/library creation and the final Metal pipeline link. A high default
// threshold avoids per-PSO files in normal runs; 0 is useful for probe validation.
static inline uint64_t mvkSlowComputeTraceThresholdNS(const MVKConfiguration& config) {
    const char* enabled = getenv("MVK_AMD_TRACE_SLOW_COMPUTE");
    if (!enabled || strcmp(enabled, "1") || !mvkRuntimeTraceEnabled(config)) return UINT64_MAX;
    const char* value = getenv("MVK_AMD_SLOW_COMPUTE_MS");
    if (!value) return 5000000000ull;
    char* end = nullptr;
    unsigned long long ms = strtoull(value, &end, 10);
    if (!value[0] || *end || value[0] == '-' || ms > UINT64_MAX / 1000000ull) return 5000000000ull;
    return ms * 1000000ull;
}
static inline void mvkWriteRuntimeTrace(const MVKConfiguration& config, NSString* kind, NSDictionary* record) {
    if (!mvkRuntimeTraceEnabled(config)) return;
    // Playable runs retain only the bounded mesh-replay result. Creating a
    // separate JSON file for every function and pipeline can dominate startup
    // on games with tens of thousands of PSOs.
    if (mvkRuntimeReplayOnly() && ![kind isEqualToString:@"mesh-replay"] &&
        ![kind isEqualToString:@"pipeline-failure"] &&
        ![kind isEqualToString:@"fresh-mesh-function"] &&
        ![kind isEqualToString:@"mesh-link-differential"] &&
        ![kind isEqualToString:@"compute-failure"] &&
        ![kind isEqualToString:@"slow-compute"] &&
        !([kind isEqualToString:@"gpu-timestamps"] && getenv("MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH")) &&
        !([kind isEqualToString:@"render-archive"] && getenv("MVK_AMD_RENDER_ARCHIVE_TRACE")) &&
        !([kind isEqualToString:@"compute-archive"] && getenv("MVK_AMD_COMPUTE_ARCHIVE_TRACE")) &&
        !([kind isEqualToString:@"present-progress"] && getenv("MVK_AMD_QUEUE_TIMING") && !strcmp(getenv("MVK_AMD_QUEUE_TIMING"), "1")) &&
        !(mvkGPUFailureTraceEnabled() && ([kind isEqualToString:@"gpu-timeout"] || [kind isEqualToString:@"queue-config"])) &&
        !(mvkGPUTimeoutTraceEnabled() && ([kind isEqualToString:@"gpu-timeout"] || [kind isEqualToString:@"present-progress"] || [kind isEqualToString:@"compute-map"] || [kind isEqualToString:@"queue-config"] ||
          ([kind isEqualToString:@"queue-dependencies"] && getenv("MVK_AMD_QUEUE_DEPENDENCY_DUMP_ALL"))))) return;
    static std::atomic<uint64_t> sequence{0};
    NSString* dir = @(config.shaderDumpDir);
    mkdir(dir.UTF8String, 0755);
    NSString* path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"trace-%@-%d-%llu.json",kind,getpid(),(unsigned long long)sequence.fetch_add(1)]];
    NSData* data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
}
// Diagnostic provenance travels with the actual library/function object. It
// is not a shader cache key and never changes compilation options or results.
static inline const void* mvkCompileProvenanceKey() {
    return sel_registerName("mvkActualCompileProvenanceV1");
}
static inline NSDictionary* mvkCompileProvenance(NSString* source, MTLCompileOptions* options) {
    if (!mvkGPUTimeoutTraceEnabled()) return nil;
    NSData* bytes = [source dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2*i, 3, "%02x", digest[i]);
    NSMutableDictionary* info = [@{@"sourceSHA256":@(hex), @"sourceBytes":@(bytes.length),
        @"languageVersion":@(options.languageVersion), @"fastMathEnabled":@(options.fastMathEnabled),
        @"preserveInvariance":@(options.preserveInvariance),
        @"preprocessorMacros":options.preprocessorMacros ?: @{}} mutableCopy];
    if ([options respondsToSelector:@selector(optimizationLevel)]) info[@"optimizationLevel"]=@(options.optimizationLevel);
#if MVK_XCODE_16
    if ([options respondsToSelector:@selector(mathMode)]) {
        info[@"mathMode"]=@(options.mathMode);
        info[@"mathFloatingPointFunctions"]=@(options.mathFloatingPointFunctions);
    }
#endif
    return [info autorelease];
}
static inline NSDictionary* mvkTraceFunction(id<MTLFunction> function) {
    if (!function) return @{};
    return @{@"label":function.label ?: @"", @"name":function.name ?: @"", @"type":@(function.functionType), @"identity":[NSString stringWithFormat:@"%p",function], @"deviceIdentity":[NSString stringWithFormat:@"%p",function.device], @"deviceRegistryID":@(function.device.registryID), @"fullCompileContextCaptured":@(objc_getAssociatedObject(function,mvkMeshContextKey())!=nil), @"compileProvenance":objc_getAssociatedObject(function, mvkCompileProvenanceKey()) ?: @{}};
}
static inline NSDictionary* mvkTraceConfig(const mvk::SPIRVToMSLConversionConfiguration& c) {
    NSMutableArray* inputs = [NSMutableArray array];
    NSMutableArray* outputs = [NSMutableArray array];
    NSMutableArray* resources = [NSMutableArray array];
    for (auto& s : c.shaderInputs) [inputs addObject:@{@"location":@(s.shaderVar.location),@"used":@(s.outIsUsedByShader),@"raw":[[NSData dataWithBytes:&s.shaderVar length:sizeof(s.shaderVar)] base64EncodedStringWithOptions:0]}];
    for (auto& s : c.shaderOutputs) [outputs addObject:@{@"location":@(s.shaderVar.location),@"used":@(s.outIsUsedByShader),@"raw":[[NSData dataWithBytes:&s.shaderVar length:sizeof(s.shaderVar)] base64EncodedStringWithOptions:0]}];
    for (auto& r : c.resourceBindings) if (r.resourceBinding.stage == c.options.entryPointStage) [resources addObject:@{@"set":@(r.resourceBinding.desc_set),@"binding":@(r.resourceBinding.binding),@"count":@(r.resourceBinding.count),@"buffer":@(r.resourceBinding.msl_buffer),@"used":@(r.outIsUsedByShader)}];
    return @{@"stage":@(c.options.entryPointStage),@"entryPoint":@(c.options.entryPointName.c_str()),@"mesh":@(c.options.mslOptions.for_mesh_pipeline),@"flipY":@(c.options.shouldFlipVertexY),@"mslOptionsRaw":[[NSData dataWithBytes:&c.options.mslOptions length:sizeof(c.options.mslOptions)] base64EncodedStringWithOptions:0],@"inputs":inputs,@"outputs":outputs,@"resources":resources};
}
