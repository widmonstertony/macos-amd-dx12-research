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
inline std::atomic<unsigned>& mvkGPUTimestampInFlight() { static std::atomic<unsigned> n{0}; return n; }
inline void mvkBeginGPUTimestamps(NSMutableDictionary* record, id<MTLCommandBuffer> cb, uint32_t family) {
    if (family != 0 || !mvkGPUTimestampArmed()) return;
    auto& n=mvkGPUTimestampInFlight();
    if(n.fetch_add(1)>=64) { n.fetch_sub(1); return; }
    id<MTLDevice>d=cb.commandQueue.device;
    if (![d supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary] ||
        ![d supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary]) { n.fetch_sub(1);return; }
    id<MTLCounterSet>set=nil;
    for(id<MTLCounterSet>s in d.counterSets)if([s.name isEqualToString:MTLCommonCounterSetTimestamp]){set=s;break;}
    if(!set){n.fetch_sub(1);return;}
    auto desc=[MTLCounterSampleBufferDescriptor new];desc.counterSet=set;desc.storageMode=MTLStorageModeShared;desc.sampleCount=128;
    NSError* error=nil;auto buffer=[d newCounterSampleBufferWithDescriptor:desc error:&error];[desc release];
    if(!buffer){n.fetch_sub(1);return;}
    record[@"gpuCounterBuffer"]=buffer;[buffer release];record[@"gpuCounterEvents"]=[NSMutableArray array];
}
inline void mvkSampleGPUTimestamp(NSMutableDictionary* record, id<MTLCommandEncoder> encoder, NSString* kind, NSString* label) {
    if(!record[@"gpuCounterBuffer"])return;
    bool render=[encoder respondsToSelector:@selector(setRenderPipelineState:)];
    bool compute=[encoder respondsToSelector:@selector(setComputePipelineState:)];
    if(!render&&!compute)return;
    if(![kind containsString:@"pipeline"]&&![kind isEqualToString:@"encoder-end"])return;
    @synchronized(record){
        NSMutableArray* rows=record[@"gpuCounterEvents"];
        if(rows.count>=128){record[@"gpuCountersTruncated"]=@YES;return;}
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
        return @{@"enabled":@YES,@"nativeCompleted":@(completed),@"CPUResolveSucceeded":@(resolved),@"truncated":record[@"gpuCountersTruncated"]?:@NO,@"withBarrier":@NO,@"samples":rows};
    }
}
inline void mvkEndGPUTimestamps(NSDictionary* record){if(record[@"gpuCounterBuffer"])mvkGPUTimestampInFlight().fetch_sub(1);}
