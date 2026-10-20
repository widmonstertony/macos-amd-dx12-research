// Diagnostic counts only; never replaces a native presentation timestamp.
#pragma once
#include "MVKRuntimeTrace.h"
#include <map>
#include <mutex>
struct MVKPresentedFrameWindow {
    uint64_t callbacks=0, valid=0, invalid=0, first=0, last=0, largestGap=0;
    double published=0;
};
inline void mvkTracePresentedFrame(const MVKConfiguration& config, const void* swapchain,
                                   uint64_t nativeTimestamp) {
    const char* timing = getenv("MVK_AMD_QUEUE_TIMING");
    if (!mvkGPUTimeoutTraceEnabled() && !(timing && !strcmp(timing, "1"))) return;
    static std::mutex mutex;
    static std::map<const void*,MVKPresentedFrameWindow> windows;
    std::lock_guard<std::mutex> guard(mutex);
    if (!windows.count(swapchain) && windows.size() >= 32) windows.clear();
    auto& w=windows[swapchain]; ++w.callbacks;
    if (nativeTimestamp) {
        ++w.valid;
        if (!w.first) w.first=nativeTimestamp;
        if (w.last && nativeTimestamp>w.last) w.largestGap=std::max(w.largestGap,nativeTimestamp-w.last);
        w.last=std::max(w.last,nativeTimestamp);
    } else ++w.invalid;
    double now=[NSDate timeIntervalSinceReferenceDate];
    if (w.published && now-w.published < 5.0) return;
    double seconds=w.last>w.first ? (w.last-w.first)/1e9 : 0.0;
    mvkWriteRuntimeTrace(config,@"present-progress",@{
        @"swapchain":[NSString stringWithFormat:@"%p",swapchain],
        @"time":@(now), @"callbacks":@(w.callbacks), @"nativeTimestampCallbacks":@(w.valid),
        @"callbacksWithoutNativeTimestamp":@(w.invalid), @"nativeIntervalSeconds":@(seconds),
        @"nativePresentationFPS":seconds>0 && w.valid>1 ? (id)@((w.valid-1)/seconds) : (id)[NSNull null],
        @"largestNativeGapMilliseconds":@(w.largestGap/1e6),
        @"sceneAndVisibilityVerified":@NO});
    w=MVKPresentedFrameWindow{};w.published=now;
}
