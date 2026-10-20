// Opt-in, once-per-process diagnosis of a native mesh link error. Native
// failures remain failures. These diagnostic PSOs are never used by Vulkan.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <atomic>
#include <mutex>
#include <time.h>
#include <cstring>
#include <cstdlib>
#include <initializer_list>
#include <dispatch/dispatch.h>

inline bool mvkMeshDifferentialEnabled() {
    const char* value=getenv("MVK_AMD_LINK_DIFFERENTIAL_CAPTURE");
    return value && !strcmp(value,"1");
}
inline const void* mvkMeshContextKey() { return sel_registerName("mvkMeshFullCompileContextV1"); }
inline NSDictionary* mvkMeshCompileContext(NSString* source,MTLCompileOptions* options,bool selected) {
    if (!selected || !mvkMeshDifferentialEnabled()) return nil;
    static std::atomic<unsigned> captured{0};
    static std::atomic<uint64_t> retainedSourceBytes{0};
    if (captured.fetch_add(1)>=512 || source.length>1024*1024) return nil;
    uint64_t bytes=source.length*2;
    if (retainedSourceBytes.fetch_add(bytes)+bytes>64*1024*1024) return nil;
    // Keep immutable source and the full native options copy, not just the
    // public properties in a JSON log. Do not retain the native library here.
    return @{@"source":[[source copy] autorelease],@"options":[[options copy] autorelease]};
}
struct MVKLinkOperationState {
    std::mutex mutex;
    uint64_t sequence=0;
    NSMutableDictionary* active=[[NSMutableDictionary alloc] init];
};
// External inline linkage deliberately shares this state across translation
// units; file-local inline storage would miss archive operations in headers.
inline MVKLinkOperationState& mvkLinkOperationState() { static MVKLinkOperationState state;return state; }
inline uint64_t mvkLinkOperationBegin(NSString* kind,NSString* label) {
    if (!mvkMeshDifferentialEnabled()) return 0;
    auto& state=mvkLinkOperationState();std::lock_guard<std::mutex> lock(state.mutex);
    uint64_t id=++state.sequence;
    state.active[@(id)]=@{@"kind":kind,@"label":label ?: @"",@"startNS":@(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))};
    return id;
}
inline void mvkLinkOperationEnd(uint64_t id) {
    if (!id) return;
    auto& state=mvkLinkOperationState();std::lock_guard<std::mutex> lock(state.mutex);[state.active removeObjectForKey:@(id)];
}
inline NSArray* mvkLinkOperationSnapshot() {
    auto& state=mvkLinkOperationState();std::lock_guard<std::mutex> lock(state.mutex);
    return [[state.active.allValues copy] autorelease];
}
inline NSString* mvkMeshIdentity(id object) { return [NSString stringWithFormat:@"%p",object]; }

inline void mvkDiagnoseMeshLink(id<MTLDevice> device,MTLMeshRenderPipelineDescriptor* original,
        dispatch_semaphore_t gate,void (^write)(NSDictionary*)) {
    if (!mvkMeshDifferentialEnabled()) return;
    static std::atomic<bool> once{false};if (once.exchange(true)) return;
    NSArray* old=@[original.objectFunction ?: (id)[NSNull null],original.meshFunction ?: (id)[NSNull null],original.fragmentFunction ?: (id)[NSNull null]];
    for (id value in old) {
        if (value==[NSNull null]) { write(@{@"case":@"unsupported",@"reason":@"missing stage"});return; }
        id<MTLFunction> f=value;
        if (f.functionConstantsDictionary.count || !objc_getAssociatedObject(f,mvkMeshContextKey())) {
            write(@{@"case":@"unsupported",@"reason":@"specialization or full compile context unavailable"});return;
        }
    }
    auto attempt = [&](NSString* name,NSArray* chosen) {
        MTLMeshRenderPipelineDescriptor* d=[original copy];
        d.objectFunction=chosen[0];d.meshFunction=chosen[1];d.fragmentFunction=chosen[2];
        if (gate) dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);
        NSArray* overlap=mvkLinkOperationSnapshot();uint64_t started=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        NSError* error=nil;id<MTLRenderPipelineState> p=[device newRenderPipelineStateWithMeshDescriptor:d options:MTLPipelineOptionNone reflection:nil error:&error];
        uint64_t ended=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (gate) dispatch_semaphore_signal(gate);
        NSMutableArray* functions=[NSMutableArray array];
        for (id<MTLFunction> f in chosen) [functions addObject:@{@"identity":mvkMeshIdentity(f),@"deviceIdentity":mvkMeshIdentity(f.device),@"name":f.name ?: @"",@"label":f.label ?: @"",@"type":@(f.functionType)}];
        write(@{@"case":name,@"created":@(p!=nil),@"error":error.localizedDescription ?: @"",@"errorCode":@(error.code),
            @"pipelineDeviceIdentity":mvkMeshIdentity(device),@"functions":functions,@"activeAtStart":overlap,
            @"startNS":@(started),@"endNS":@(ended),@"GPUWorkDispatched":@NO,@"usedByGame":@NO});
        [p release];[d release];
    };
    // This control precedes every rebuild: if it succeeds, no function
    // replacement was necessary to change the result.
    attempt(@"unchanged-before-rebuild",old);
    NSMutableArray* fresh=[NSMutableArray array];
    for (id<MTLFunction> f in old) {
        NSDictionary* context=objc_getAssociatedObject(f,mvkMeshContextKey());NSError* error=nil;
        id<MTLLibrary> library=[device newLibraryWithSource:context[@"source"] options:context[@"options"] error:&error];
        id<MTLFunction> function=library ? [library newFunctionWithName:f.name] : nil;
        if (!function) { write(@{@"case":@"rebuild-failed",@"error":error.localizedDescription ?: @""});[library release];return; }
        (void)function.functionConstantsDictionary.allValues;
        function.label=f.label; // Preserve labels too, unlike historical replay.
        [fresh addObject:function];[function release];[library release];
    }
    attempt(@"unchanged-after-rebuild",old);
    for (unsigned mask : {1u,2u,4u,3u,5u,6u,7u}) {
        NSArray* functions=@[(mask&1)?fresh[0]:old[0],(mask&2)?fresh[1]:old[1],(mask&4)?fresh[2]:old[2]];
        attempt([NSString stringWithFormat:@"replace-mask-%u",mask],functions);
    }

    // The historical source replay changed function labels even when it kept
    // the original entry-point name.  Test that variable independently of
    // source, compile options, function identity, and the pipeline descriptor.
    // These freshly rebuilt functions are diagnostic-only, so relabeling them
    // cannot alter the Vulkan pipeline that already failed.
    NSMutableArray* originalFreshLabels=[NSMutableArray array];
    for (id<MTLFunction> f in fresh) [originalFreshLabels addObject:f.label ?: @""];
    for (unsigned mask : {1u,2u,4u,3u,5u,6u,7u}) {
        for (NSUInteger i=0;i<3;i++) {
            id<MTLFunction> f=fresh[i];
            NSString* base=originalFreshLabels[i];
            f.label=(mask&(1u<<i)) ? [base stringByAppendingFormat:@":diagnostic-label-%u",mask] : base;
        }
        attempt([NSString stringWithFormat:@"relabel-mask-%u",mask],fresh);
    }

    // If labels alone are insufficient, isolate the remaining historical
    // difference: a fresh, unique Metal entry-point namespace.  Keep the exact
    // retained source and MTLCompileOptions, changing only the declaration and
    // lookup name of each stage entry point.
    NSMutableArray* renamed=[NSMutableArray array];
    for (NSUInteger i=0;i<3;i++) {
        id<MTLFunction> oldFunction=old[i];
        NSDictionary* context=objc_getAssociatedObject(oldFunction,mvkMeshContextKey());
        NSString* replacement=[NSString stringWithFormat:@"mvk_link_differential_%@_%lu",
            [[oldFunction.label componentsSeparatedByString:@":"] firstObject],(unsigned long)i];
        NSString* pattern=[NSString stringWithFormat:@"\\b%@\\b",
            [NSRegularExpression escapedPatternForString:oldFunction.name]];
        NSString* source=[context[@"source"] stringByReplacingOccurrencesOfString:pattern
            withString:replacement options:NSRegularExpressionSearch
            range:NSMakeRange(0,[context[@"source"] length])];
        NSError* error=nil;
        id<MTLLibrary> library=[device newLibraryWithSource:source options:context[@"options"] error:&error];
        id<MTLFunction> function=library ? [library newFunctionWithName:replacement] : nil;
        if (!function) {
            write(@{@"case":@"rename-rebuild-failed",@"stage":@(i),
                @"error":error.localizedDescription ?: @""});
            [library release];
            return;
        }
        (void)function.functionConstantsDictionary.allValues;
        function.label=[oldFunction.label stringByAppendingString:@":diagnostic-entry-renamed"];
        [renamed addObject:function];
        [function release];
        [library release];
    }
    attempt(@"renamed-entry-all",renamed);
}
