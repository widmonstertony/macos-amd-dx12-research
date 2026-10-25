// Opt-in, timed public Metal counter diagnostics. No new waits or fences.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include "MVKTimedTraceArm.h"
inline bool mvkGPUTimestampArmed() {
    static const MVKTimedTraceArm arm(getenv("MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH"));
    return arm.enabled();
}
inline const char* mvkGPUCounterPipelineLabel() {
    const char* selected=getenv("MVK_AMD_GPU_COUNTER_PIPELINE_LABEL");
    if(selected&&selected[0])return selected;
    return getenv("MVK_AMD_GEOMETRY_DRAW_TRACE_LABEL");
}
inline bool mvkGPUCounterAllDraws() {
    const char* enabled = getenv("MVK_AMD_GPU_COUNTER_ALL_DRAWS");
    return enabled && enabled[0] && strcmp(enabled, "0");
}
inline std::atomic<unsigned>& mvkGPUTimestampInFlight() { static std::atomic<unsigned> n{0}; return n; }
inline bool mvkAllocateGPUTimestampBuffer(NSMutableDictionary* record, id<MTLDevice> device) {
    if (record[@"gpuCounterBuffer"] || !device || !mvkGPUTimestampArmed()) return record[@"gpuCounterBuffer"] != nil;
    auto& n=mvkGPUTimestampInFlight();
    // A full draw/batch trace is intentionally much larger than the ordinary
    // pipeline trace.  Keep only one such command buffer instrumented at a
    // time so the diagnostic cannot multiply its shared-memory and Objective-C
    // event-array cost across the game's deep queue backlog.
    const unsigned inFlightLimit = mvkGPUCounterAllDraws() ? 1 : 64;
    if(n.fetch_add(1)>=inFlightLimit) { n.fetch_sub(1); return false; }
    if (![device supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary] ||
        ![device supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary]) { n.fetch_sub(1);return false; }
    id<MTLCounterSet>set=nil;
    for(id<MTLCounterSet>s in device.counterSets)if([s.name isEqualToString:MTLCommonCounterSetTimestamp]){set=s;break;}
    if(!set){n.fetch_sub(1);return false;}
    // The first internal geometry-batch capture filled 512 samples after only
    // 22.9 ms of a command buffer that ultimately ran for about seven seconds.
    // 16K samples keep the capture bounded while covering the complete failing
    // buffer in one run instead of repeatedly guessing a later pipeline hash.
    const NSUInteger sampleCapacity = mvkGPUCounterAllDraws() ? 16384 : 128;
    auto desc=[MTLCounterSampleBufferDescriptor new];desc.counterSet=set;desc.storageMode=MTLStorageModeShared;desc.sampleCount=sampleCapacity;
    NSError* error=nil;auto buffer=[device newCounterSampleBufferWithDescriptor:desc error:&error];[desc release];
    if(!buffer){n.fetch_sub(1);return false;}
    record[@"gpuCounterBuffer"]=buffer;[buffer release];record[@"gpuCounterEvents"]=[NSMutableArray array];
    record[@"gpuCounterCapacity"]=@(sampleCapacity);
    record[@"gpuCounterAllDraws"]=@(mvkGPUCounterAllDraws());
    return true;
}
inline void mvkBeginGPUTimestamps(NSMutableDictionary* record, id<MTLCommandBuffer> cb, uint32_t family) {
    if (family != 0 || !mvkGPUTimestampArmed()) return;
    const char* selected=mvkGPUCounterPipelineLabel();
    if(selected&&selected[0]) {
        // A busy game can have more than 64 ordinary command buffers in flight
        // before the selected mesh pipeline is reached. Reserve the bounded
        // counter budget for the command buffer that actually contains it.
        record[@"gpuCounterLazyGeometryLabel"]=@(selected);
        return;
    }
    mvkAllocateGPUTimestampBuffer(record, cb.commandQueue.device);
}
inline void mvkSampleGPUTimestamp(NSMutableDictionary* record, id<MTLCommandEncoder> encoder, NSString* kind, NSString* label) {
    if(!record[@"gpuCounterBuffer"]){
        NSString* selected=record[@"gpuCounterLazyGeometryLabel"];
        if(!selected||![kind containsString:@"pipeline"]||
           (! [selected isEqualToString:@"*"] && ![label containsString:selected]))return;
        if(!mvkAllocateGPUTimestampBuffer(record,encoder.device))return;
        record[@"gpuCounterSelectedAt"] = label ?: @"";
    }
    bool render=[encoder respondsToSelector:@selector(setRenderPipelineState:)];
    bool compute=[encoder respondsToSelector:@selector(setComputePipelineState:)];
    if(!render&&!compute)return;
    const bool selectedDraw = mvkGPUCounterAllDraws() &&
        ([kind isEqualToString:@"draw"] || [kind isEqualToString:@"geometry-batch"]);
    if(![kind containsString:@"pipeline"]&&![kind isEqualToString:@"encoder-end"]&&
       ![kind isEqualToString:@"geometry-tail"]&&!selectedDraw)return;
    @synchronized(record){
        NSMutableArray* rows=record[@"gpuCounterEvents"];
        const NSUInteger capacity=[record[@"gpuCounterCapacity"] unsignedIntegerValue];
        if(rows.count>=capacity){record[@"gpuCountersTruncated"]=@YES;return;}
        NSUInteger index=rows.count;
        // Both public render/compute protocols have this identical selector.
        [(id<MTLComputeCommandEncoder>)encoder sampleCountersInBuffer:record[@"gpuCounterBuffer"] atSampleIndex:index withBarrier:NO];
        [rows addObject:@{@"index":@(index),@"encoder":[NSString stringWithFormat:@"%p",encoder],@"kind":kind?:@"",@"label":label?:@""}];
    }
}
inline NSDictionary* mvkSnapshotGPUTimestamps(NSDictionary* record) {
    if(!record[@"gpuCounterBuffer"])return @{@"enabled":@NO};
    @synchronized(record){
        NSArray* events=record[@"gpuCounterEvents"];bool completed=[record[@"nativeCompleted"]boolValue];
        NSMutableArray* rows=[NSMutableArray array];NSData* data=nil;
        // Never resolve data from an executing command buffer, nor submit any
        // resolve commands to a lost device. Shared counters resolve on CPU.
        if(completed&&events.count)data=[(id<MTLCounterSampleBuffer>)record[@"gpuCounterBuffer"] resolveCounterRange:NSMakeRange(0,events.count)];
        bool resolved=data.length==events.count*sizeof(MTLCounterResultTimestamp)&&data!=nil;
        auto values=(const MTLCounterResultTimestamp*)data.bytes;
        for(NSUInteger i=0;i<events.count;++i){auto row=[events[i]mutableCopy];if(resolved){row[@"timestamp"]=@(values[i].timestamp);row[@"valid"]=@(values[i].timestamp!=MTLCounterErrorValue);}else row[@"valid"]=(id)[NSNull null];[rows addObject:row];[row release];}
        return @{@"enabled":@YES,@"nativeCompleted":@(completed),@"CPUResolveSucceeded":@(resolved),@"truncated":record[@"gpuCountersTruncated"]?:@NO,@"withBarrier":@NO,@"allDraws":record[@"gpuCounterAllDraws"]?:@NO,@"capacity":record[@"gpuCounterCapacity"]?:@0,@"samples":rows};
    }
}
inline void mvkEndGPUTimestamps(NSDictionary* record){if(record[@"gpuCounterBuffer"])mvkGPUTimestampInFlight().fetch_sub(1);}
