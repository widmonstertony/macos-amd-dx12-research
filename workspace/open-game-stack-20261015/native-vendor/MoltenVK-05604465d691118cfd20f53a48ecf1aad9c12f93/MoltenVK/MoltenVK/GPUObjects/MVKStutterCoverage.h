// Opt-in CPU-only stutter coverage. Does not change graphics/synchronization.
#pragma once
#include "MVKCPUTimingTrace.h"
#include <condition_variable>
#include <cstdlib>
#include <cerrno>
#include <unistd.h>
#include <sys/stat.h>

#define MVK_CPU_PHASE_LIST(X) \
 X(QueueDispatchDelay,Async) X(QueueExecute,Work) X(QueueSubmitWork,Work) \
 X(HostEncode,Work) X(EncodeCommands,Work) X(FinalizeDraw,Work) X(PrepareDraw,Work) X(BindMetalResources,Work) \
 X(RenderPassBegin,Work) X(RenderPassEnd,Work) X(NativeEncoderCreate,Work) X(EncodeBarrier,Work) \
 X(DescriptorSnapshot,Work) X(DescriptorCacheRead,Work) X(DescriptorCacheRebuild,Work) X(DescriptorCacheScan,Work) X(DescriptorCacheLock,Wait) X(DescriptorWriteCommit,Work) X(DescriptorWrites,Work) \
 X(LeaseLookup,Work) X(LeaseFullBuild,Work) X(LeaseDeltaBuild,Work) \
 X(LeaseRegistryValidate,Work) X(LeaseReverseIndex,Work) X(LeaseEviction,Work) X(LeaseLockWait,Wait) X(LeaseRegistryLockWait,Wait) \
 X(ResourceReplay,Work) X(ResourceGroup,Work) X(HeapPlanBuild,Work) X(HeapPlanReuse,Work) \
 X(NativeHeap,Work) X(NativeRead,Work) X(NativeWrite,Work) X(ResourceReset,Work) \
 X(CommandAllocation,Work) X(WorkTrace,Work) X(ShaderGetFunction,Work) \
 X(ShaderCacheLock,Wait) X(ShaderLibraryLookup,Work) X(ShaderLibraryGet,Work) X(NativeFunctionSpecialize,Work) X(ShaderConvert,Work) \
 X(NativeLibraryCompile,Work) X(ShaderSourceDump,Work) X(PipelineLookup,Work) X(PipelineShaderLookup,Work) \
 X(PipelineCacheLock,Wait) X(PipelineBuild,Work) X(PipelineLinkLock,Wait) X(NativeMonitorLock,Wait) X(CompilerCompletionLock,Wait) X(NativePipelineCompile,Work) \
 X(ShaderCacheHit,Work) X(ShaderCacheMiss,Work) X(ShaderCacheCompileRequired,Work) X(ShaderLibraryBuild,Work) X(ShaderLibraryInvalidated,Work) \
 X(ArchiveFileHit,Work) X(ArchiveFileMiss,Work) X(ArchiveNativeHit,Work) X(ArchiveNativeMiss,Work) X(ArchiveFallback,Work) X(ArchiveRehydrate,Work) \
 X(BinaryArchiveLookup,Work) X(BinaryArchiveLoad,Work) X(BinaryArchivePublish,Work) \
 X(HostSemaphoreWait,Wait) X(HostFenceWait,Wait) X(NativeCommit,Work) \
 X(DrawableAcquire,Wait) X(NativePresent,Work) X(CallbackCompletion,Work) X(GPUCounterCalibration,Work) X(DiagnosticPublish,Work)

enum class MVKCPUPhase:size_t {
#define MVK_CPU_ENUM(name,kind) name,
    MVK_CPU_PHASE_LIST(MVK_CPU_ENUM)
#undef MVK_CPU_ENUM
    Count
};
using MVKStutterCPUTrace=MVKCPUTimingTrace<static_cast<size_t>(MVKCPUPhase::Count),8>;
using MVKCPUContext=MVKStutterCPUTrace::Context;
using MVKCPUContextGuard=MVKStutterCPUTrace::ContextGuard;
inline uint64_t mvkStutterMonotonicNS(){return MVKCPUDefaultClock::toNS(MVKCPUDefaultClock::ticks());}
inline MVKCPUContext mvkStutterContext(){return MVKStutterCPUTrace::currentContext;}
inline bool mvkStutterCoverageEnabled(){static const bool enabled=[] {const char*v=getenv("MVK_AMD_STUTTER_COVERAGE");return v&&!strcmp(v,"1");}();return enabled;}
inline std::array<MVKCPUStageInfo,static_cast<size_t>(MVKCPUPhase::Count)> mvkStutterStageInfo(){return {{
#define MVK_CPU_FALLBACK_INFO(name,kind) {#name,MVKCPUTimingKind::kind},
    MVK_CPU_PHASE_LIST(MVK_CPU_FALLBACK_INFO)
#undef MVK_CPU_FALLBACK_INFO
}};}

class MVKStutterCPURuntime {
    static std::array<MVKCPUStageInfo,static_cast<size_t>(MVKCPUPhase::Count)> stageInfo(){return {{
#define MVK_CPU_INFO(name,kind) {#name,MVKCPUTimingKind::kind},
        MVK_CPU_PHASE_LIST(MVK_CPU_INFO)
#undef MVK_CPU_INFO
    }};}
    std::mutex _stopLock,_publishLock;
    std::condition_variable _stopCV;
    std::thread _reporter;
    bool _stop=false;
    std::atomic<bool> _reporterUnavailable{false};
    uint64_t _lastPublishNS=0,_historyRecords=0;
    char _history[4096]{},_current[4096]{},_temporary[4096]{};
    const char*_detailArmPath=nullptr;
    const char*_cpuArmPath=nullptr;
    bool _detailEnvironment=false;
    std::unique_ptr<MVKStutterCPUTrace::Report> _pending;
    bool writeCurrent(const MVKStutterCPUTrace::Report& report){
        FILE*f=fopen(_temporary,"w");if(!f)return false;trace.writeJSON(f,report);bool ok=!ferror(f)&&fflush(f)==0;int closed=fclose(f);ok=ok&&closed==0;
        if(ok)ok=rename(_temporary,_current)==0;if(!ok)unlink(_temporary);return ok;
    }
    void writeUnavailable(const char*reason) noexcept {
        if(!_current[0])return;FILE*f=fopen(_temporary,"w");if(!f)return;
        fprintf(f,"{\"schema\":1,\"coverageUnavailable\":true,\"reason\":\"%s\",\"time\":%.9f}\n",reason,double(MVKCPUDefaultClock::unixNS())/1e9-978307200.0);bool good=!ferror(f);int closed=fclose(f);good=good&&closed==0;if(good)rename(_temporary,_current);else unlink(_temporary);
    }
    static bool freshMarker(const char*path){if(!path)return false;struct stat state{};if(stat(path,&state))return false;uint64_t now=MVKCPUDefaultClock::unixNS()/1000000000ULL;return now>=uint64_t(state.st_mtime)&&now-uint64_t(state.st_mtime)<=90;}
    void refreshDetailedArm(){
        bool cpu=!_cpuArmPath||freshMarker(_cpuArmPath);trace.setEnabled(cpu);
        trace.setDetailedEnabled(cpu&&(_detailEnvironment||freshMarker(_detailArmPath)));
    }
public:
    MVKStutterCPUTrace trace;
    MVKStutterCPURuntime():trace(stageInfo()){
        if(!mvkStutterCoverageEnabled())return;
        const char*dir=getenv("MVK_CONFIG_SHADER_DUMP_DIR");if(!dir||!dir[0])return;
        int a=snprintf(_history,sizeof(_history),"%s/cpu-stutter-%d.jsonl",dir,getpid());
        int b=snprintf(_current,sizeof(_current),"%s/cpu-stutter-current-%d.json",dir,getpid());
        int c=snprintf(_temporary,sizeof(_temporary),"%s/cpu-stutter-current-%d.next",dir,getpid());
        if(a<=0||size_t(a)>=sizeof(_history)||b<=0||size_t(b)>=sizeof(_current)||c<=0||size_t(c)>=sizeof(_temporary))return;
        _lastPublishNS=mvkStutterMonotonicNS();trace.setEnabled(true);
        const char*detail=getenv("MVK_AMD_STUTTER_DETAIL");_detailEnvironment=detail&&!strcmp(detail,"1");_detailArmPath=getenv("MVK_AMD_STUTTER_DETAIL_ARM_PATH");_cpuArmPath=getenv("MVK_AMD_STUTTER_CPU_ARM_PATH");refreshDetailedArm();
        try{_reporter=std::thread([this]{try{
#if defined(__APPLE__)
            pthread_setname_np("MVKCPUStutterReport");
#endif
            MVKCPUContext ctx;ctx.domain=7;MVKCPUContextGuard context(ctx);
            std::unique_lock<std::mutex> lock(_stopLock);
            while(!_stop){if(_stopCV.wait_for(lock,std::chrono::seconds(5),[&]{return _stop;}))break;lock.unlock();publish();lock.lock();}
        }catch(...){_reporterUnavailable.store(true);trace.markDiagnosticUnavailable();trace.setEnabled(false);writeUnavailable("reporter-loop-exception");}});}catch(...){_reporterUnavailable.store(true);trace.markDiagnosticUnavailable();trace.setEnabled(false);writeUnavailable("reporter-thread-start-failed");}
    }
    ~MVKStutterCPURuntime(){
        {std::lock_guard<std::mutex> lock(_stopLock);_stop=true;}_stopCV.notify_all();
        if(_reporter.joinable())_reporter.join();if(_history[0])publish(true);trace.setEnabled(false);
    }
    void publish(bool force=false) noexcept {
        try{publishImpl(force);}catch(...){_reporterUnavailable.store(true);trace.markDiagnosticUnavailable();trace.setEnabled(false);writeUnavailable("diagnostic-publication-exception");}
    }
private:
    void publishImpl(bool force){
        if(!_history[0])return;
        if(_reporterUnavailable.load()){writeUnavailable("reporter-unavailable");return;}
        std::unique_lock<std::mutex> guard(_publishLock,std::try_to_lock);if(!guard.owns_lock())return;
        uint64_t now=mvkStutterMonotonicNS();if(!force&&now-_lastPublishNS<5000000000ULL)return;_lastPublishNS=now;refreshDetailedArm();
        MVKStutterCPUTrace::Scope timing(trace,static_cast<size_t>(MVKCPUPhase::DiagnosticPublish));
        if(!_pending)_pending=trace.snapshot();
        if(!writeCurrent(*_pending)){trace.recordPublicationFailure();trace.recordFailure(static_cast<size_t>(MVKCPUPhase::DiagnosticPublish),errno);return;}
        // Preserve a bounded history, always refresh the separate current file.
        if(_historyRecords<1024){FILE*f=fopen(_history,"a");if(f){fputc('\n',f);trace.writeJSON(f,*_pending);bool ok=!ferror(f)&&fflush(f)==0;int closed=fclose(f);if(ok&&closed==0)++_historyRecords;else {trace.recordPublicationFailure();trace.recordFailure(static_cast<size_t>(MVKCPUPhase::DiagnosticPublish),errno);}}else {trace.recordPublicationFailure();trace.recordFailure(static_cast<size_t>(MVKCPUPhase::DiagnosticPublish),errno);}}
        _pending.reset();
    }
};
inline MVKStutterCPURuntime& mvkStutterRuntime(){static MVKStutterCPURuntime runtime;return runtime;}
inline MVKStutterCPUTrace& mvkStutterCPU() noexcept {
    static std::atomic<bool> failed{false};
    if(!failed.load(std::memory_order_relaxed)){try{return mvkStutterRuntime().trace;}catch(...){failed.store(true,std::memory_order_relaxed);}}
    static MVKStutterCPUTrace unavailable(mvkStutterStageInfo());
    unavailable.setEnabled(false);return unavailable;
}
// Compatibility entry point only initializes; publication stays on the reporter thread.
inline void mvkStutterMaybePublish() noexcept {if(mvkStutterCoverageEnabled()) (void)mvkStutterCPU();}
inline void mvkStutterAsync(MVKCPUPhase phase,uint64_t elapsedNS,uint64_t tag=0){if(mvkStutterCoverageEnabled())mvkStutterCPU().recordAsync(static_cast<size_t>(phase),elapsedNS,tag);}
inline void mvkStutterFailure(MVKCPUPhase phase,int64_t code,uint64_t tag=0){if(mvkStutterCoverageEnabled())mvkStutterCPU().recordFailure(static_cast<size_t>(phase),code,tag);}
#define MVK_CPU_JOIN_INNER(a,b) a##b
#define MVK_CPU_JOIN(a,b) MVK_CPU_JOIN_INNER(a,b)
#define MVK_CPU_SCOPE(phase) MVKStutterCPUTrace::Scope MVK_CPU_JOIN(mvkCPUTime_,__COUNTER__)(mvkStutterCPU(),static_cast<size_t>(MVKCPUPhase::phase))
#define MVK_CPU_SCOPE_TAG(phase,tag) MVKStutterCPUTrace::Scope MVK_CPU_JOIN(mvkCPUTime_,__COUNTER__)(mvkStutterCPU(),static_cast<size_t>(MVKCPUPhase::phase),(tag))
#define MVK_CPU_SCOPE_CPU(phase) MVKStutterCPUTrace::Scope MVK_CPU_JOIN(mvkCPUTime_,__COUNTER__)(mvkStutterCPU(),static_cast<size_t>(MVKCPUPhase::phase),0,true)

#define MVK_CPU_SCOPE_CPU_TAG(phase,tag) MVKStutterCPUTrace::Scope MVK_CPU_JOIN(mvkCPUTime_,__COUNTER__)(mvkStutterCPU(),static_cast<size_t>(MVKCPUPhase::phase),(tag),true)
inline uint64_t mvkStutterStableTag(const char* text) { if (!mvkStutterCPU().enabled() || !text) return 0; uint64_t value=UINT64_C(1469598103934665603); while (*text) { value^=static_cast<unsigned char>(*text++); value*=UINT64_C(1099511628211); } return value; }
