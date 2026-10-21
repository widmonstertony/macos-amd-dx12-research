// Opt-in, bounded aggregate measurements using public Metal timestamps.
// Timing never changes resource declarations, fences, or submission results.
#pragma once
#import <QuartzCore/QuartzCore.h>
#include <map>
#include <mutex>
#include <cstdio>

inline bool mvkQueueTimingEnabled() {
    static const bool enabled = [] { const char* v = getenv("MVK_AMD_QUEUE_TIMING"); return v && !strcmp(v, "1"); }();
    return enabled;
}

@interface MVKQueueTimingRecord : NSObject {
@public
    double created;
    double committed;
}
@end
@implementation MVKQueueTimingRecord
@end

inline const void* mvkQueueTimingKey() { return sel_registerName("mvkQueueTimingV1"); }
inline void mvkQueueTimingCommit(id<MTLCommandBuffer> cb) {
    if (!mvkQueueTimingEnabled() || !cb) return;
    MVKQueueTimingRecord* record = objc_getAssociatedObject(cb, mvkQueueTimingKey());
    if (record) record->committed = CACurrentMediaTime();
}

inline void mvkQueueTimingBegin(id<MTLCommandBuffer> cb, uint32_t family, uint32_t index,
                                const char* directory) {
    if (!mvkQueueTimingEnabled() || !cb || !directory[0]) return;
    MVKQueueTimingRecord* record = [MVKQueueTimingRecord new];
    record->created = CACurrentMediaTime();
    record->committed = 0;
    objc_setAssociatedObject(cb, mvkQueueTimingKey(), record, OBJC_ASSOCIATION_RETAIN);
    NSString* path = [NSString stringWithFormat:@"%s/queue-timing-%d.jsonl", directory, getpid()];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        struct Window {
            double start = 0, host = 0, gpu = 0, wait = 0, maxHost = 0, maxGPU = 0;
            uint64_t count = 0, valid = 0, errors = 0;
            bool published = false;
        };
        static std::mutex lock;
        static std::map<uint64_t, Window> windows;
        static unsigned records = 0;
        std::lock_guard<std::mutex> guard(lock);
        double now = CACurrentMediaTime();
        auto& w = windows[(uint64_t(family) << 32) | index];
        if (!w.start) w.start = record->created;
        ++w.count;
        if (completed.status == MTLCommandBufferStatusError) ++w.errors;
        if (record->committed >= record->created) {
            double host = record->committed - record->created;
            w.host += host; w.maxHost = std::max(w.maxHost, host);
        }
        double begin = completed.GPUStartTime, end = completed.GPUEndTime;
        if (begin > 0 && end >= begin) {
            ++w.valid; w.gpu += end - begin;
            w.maxGPU = std::max(w.maxGPU, end - begin);
            if (record->committed > 0 && begin > record->committed) w.wait += begin - record->committed;
        }
        if ((now - w.start < 5.0 && w.published) || records >= 2048) return;
        FILE* file = fopen(path.fileSystemRepresentation, "a");
        if (file) {
            fprintf(file, "{\"queueFamily\":%u,\"queueIndex\":%u,\"time\":%.6f,\"wallSeconds\":%.6f,\"completed\":%llu,\"validGPUTimestamps\":%llu,\"errors\":%llu,\"hostPrecommitTotalMS\":%.3f,\"hostPrecommitMaxMS\":%.3f,\"GPUExecutionTotalMS\":%.3f,\"GPUExecutionMaxMS\":%.3f,\"commitToGPUStartTotalMS\":%.3f}\n",
                    family,index,[NSDate timeIntervalSinceReferenceDate],now-w.start,(unsigned long long)w.count,(unsigned long long)w.valid,(unsigned long long)w.errors,
                    w.host*1000,w.maxHost*1000,w.gpu*1000,w.maxGPU*1000,w.wait*1000);
            fclose(file); ++records;
        }
        w = Window{}; w.start = now; w.published = true;
    }];
    [record release];
}
