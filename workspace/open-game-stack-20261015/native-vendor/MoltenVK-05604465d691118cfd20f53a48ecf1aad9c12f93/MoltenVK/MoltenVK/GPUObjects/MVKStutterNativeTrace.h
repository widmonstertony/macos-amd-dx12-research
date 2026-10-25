// Opt-in bounded native submission/presentation provenance. No GPU commands.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <map>
#include <mutex>
#include <new>
#include <os/lock.h>
#include <sys/stat.h>
#include <unistd.h>
#include "MVKCPUTimingTrace.h"
#include "MVKStutterCoverage.h"
inline uint64_t mvkStutterNativeMonotonicNS(){return MVKCPUDefaultClock::toNS(MVKCPUDefaultClock::ticks());}

struct MVKStutterErrnoGuard {int saved=errno;~MVKStutterErrnoGuard(){errno=saved;}};
inline bool mvkStutterNativeEnabled() {
    static const bool enabled=[] {const char*v=getenv("MVK_AMD_STUTTER_COVERAGE");return v&&!strcmp(v,"1");}();
    return enabled;
}
inline uint64_t mvkStutterNextLogicalID() {
    static std::atomic<uint64_t> serial{1};
    return mvkStutterNativeEnabled()?serial.fetch_add(1,std::memory_order_relaxed):0;
}
struct MVKStutterArmInfo {uint64_t session=0;double startedCF=0;bool active=false;};
inline MVKStutterArmInfo mvkStutterNativeArm() {
    if(!mvkStutterNativeEnabled())return {};
    MVKStutterErrnoGuard preserveErrno;
    static const char* path=[] {const char*p=getenv("MVK_AMD_STUTTER_ARM_PATH");return p?p:getenv("MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH");}();
    if(!path||!*path)return {};
    struct Cache {std::chrono::steady_clock::time_point next{};MVKStutterArmInfo info;};
    static thread_local Cache cache;
    auto now=std::chrono::steady_clock::now();
    if(now>=cache.next){
        cache.next=now+std::chrono::milliseconds(100);cache.info={};struct stat s{};
        if(!stat(path,&s)&&S_ISREG(s.st_mode)){
#if defined(__APPLE__)
            uint64_t ns=uint64_t(s.st_mtimespec.tv_sec)*1000000000+uint64_t(s.st_mtimespec.tv_nsec);
#else
            uint64_t ns=uint64_t(s.st_mtim.tv_sec)*1000000000+uint64_t(s.st_mtim.tv_nsec);
#endif
            double cf=double(ns)/1e9-978307200.0,age=CFAbsoluteTimeGetCurrent()-cf;
            if(age>=0&&age<30)cache.info={ns,cf,true};
        }
    }
    return cache.info;
}
inline bool mvkStutterNativeArmed(){return mvkStutterNativeArm().active;}
struct MVKStutterNativeSnapshot {
    uint64_t nativeID=0,logical=0,frame=0,session=0;
    uint32_t family=0,index=0,split=0;
    double createdCA=0,createdCF=0,committedCA=0,scheduledCA=0;
    bool partialPrefix=false;
 };
struct MVKStutterNativeRecord { os_unfair_lock lock=OS_UNFAIR_LOCK_INIT; MVKStutterNativeSnapshot value; };
inline const void* mvkStutterNativeKey(){return sel_registerName("mvkStutterNativeRecordV1");}
inline MVKStutterNativeRecord* mvkStutterNativeRecord(id<MTLCommandBuffer> cb){
    NSMutableData* d=cb?objc_getAssociatedObject(cb,mvkStutterNativeKey()):nil;
    return d?static_cast<MVKStutterNativeRecord*>(d.mutableBytes):nullptr;
}
inline MVKStutterNativeSnapshot mvkStutterNativeSnapshot(id<MTLCommandBuffer> cb){
    auto*r=mvkStutterNativeRecord(cb);if(!r)return {};
    os_unfair_lock_lock(&r->lock);auto value=r->value;os_unfair_lock_unlock(&r->lock);return value;
}
inline uint64_t mvkStutterNativeID(id<MTLCommandBuffer> cb){return mvkStutterNativeSnapshot(cb).nativeID;}
struct MVKStutterNativeWriter {
    struct Budget {uint64_t rows=0,dropped=0;};
    std::mutex lock;std::map<uint64_t,Budget> sessions;FILE* file=nullptr;
    uint64_t evictedThrough=0,lateSessionDrops=0;
    ~MVKStutterNativeWriter(){if(file)fclose(file);}
    FILE* output(){
        if(file)return file;const char*dir=getenv("MVK_CONFIG_SHADER_DUMP_DIR");if(!dir||!*dir)return nullptr;
        char path[4096];int n=snprintf(path,sizeof(path),"%s/stutter-native-%d.jsonl",dir,getpid());
        if(n<=0||size_t(n)>=sizeof(path))return nullptr;
        file=fopen(path,"a");if(file)setvbuf(file,nullptr,_IOFBF,16384);return file;
    }
    bool admit(uint64_t session){
        if(!session)return false;
        if(session<=evictedThrough&&sessions.find(session)==sessions.end()){
            ++lateSessionDrops;
            if(file&&(lateSessionDrops==1||lateSessionDrops%1024==0)){
                fprintf(file,"{\"type\":\"coverageLoss\",\"session\":%llu,\"reason\":\"late-evicted-session\",\"droppedRowsLowerBound\":%llu,\"complete\":false}\n",(unsigned long long)session,(unsigned long long)lateSessionDrops);fflush(file);
            }
            return false;
        }
        auto&b=sessions[session];
        if(!b.rows&&!b.dropped&&file){
            fprintf(file,"{\"type\":\"clockCalibration\",\"session\":%llu,\"timeCF\":%.9f,\"timeCA\":%.9f,\"monotonicNS\":%llu,\"rowCap\":200000,\"armMaxSeconds\":30}\n",
                (unsigned long long)session,CFAbsoluteTimeGetCurrent(),CACurrentMediaTime(),
                (unsigned long long)mvkStutterNativeMonotonicNS());fflush(file);
        }
        if(sessions.size()>32){auto old=sessions.begin();if(old->first==session)++old;if(old!=sessions.end()){evictedThrough=std::max(evictedThrough,old->first);sessions.erase(old);}}
        if(b.rows>=200000){
            ++b.dropped;
            if(file&&(b.dropped==1||b.dropped%1024==0)) {
                fprintf(file,"{\"type\":\"coverageLoss\",\"session\":%llu,\"timeCF\":%.9f,\"timeCA\":%.9f,\"monotonicNS\":%llu,\"reason\":\"native-row-cap\",\"rowCap\":200000,\"emittedRows\":%llu,\"droppedRowsLowerBound\":%llu,\"complete\":false}\n",
                    (unsigned long long)session,CFAbsoluteTimeGetCurrent(),CACurrentMediaTime(),
                    (unsigned long long)mvkStutterNativeMonotonicNS(),(unsigned long long)b.rows,
                    (unsigned long long)b.dropped);fflush(file);
            }
            return false;
        }++b.rows;return true;
    }
};
inline MVKStutterNativeWriter& mvkStutterNativeWriter(){static MVKStutterNativeWriter writer;return writer;}
// Set the real pre-commit timestamp without logger locks, allocation or I/O.
// The request row is flushed earlier; scheduled/completed rows expose this value.
inline void mvkStutterMarkNativeCommit(id<MTLCommandBuffer> cb){
    if(!mvkStutterNativeEnabled())return;
    auto*r=mvkStutterNativeRecord(cb);if(!r)return;
    double now=CACurrentMediaTime();
    os_unfair_lock_lock(&r->lock);r->value.committedCA=now;os_unfair_lock_unlock(&r->lock);
}
inline void mvkStutterNativePhase(id<MTLCommandBuffer> cb,const char* phase,
    uint64_t counterSession=0,int counterSkip=-1,bool counterAllocated=false,bool counterMid=false){
    if(!mvkStutterNativeEnabled()||!cb)return;MVKStutterErrnoGuard preserveErrno;auto*r=mvkStutterNativeRecord(cb);if(!r)return;
    auto arm=mvkStutterNativeArm();double ca=CACurrentMediaTime(),cf=CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&r->lock);auto& live=r->value;
    if(!live.session&&arm.active){live.session=arm.session;live.partialPrefix=live.createdCF<arm.startedCF;}
    if(!strcmp(phase,"commit"))live.committedCA=ca;
    if(!strcmp(phase,"scheduled"))live.scheduledCA=ca;
    auto copy=live;os_unfair_lock_unlock(&r->lock);auto*v=&copy;
    if(!v->session)return;
    MVK_CPU_SCOPE(DiagnosticPublish);
    auto&w=mvkStutterNativeWriter();std::lock_guard<std::mutex>g(w.lock);FILE*f=w.output();
    if(!f||!w.admit(v->session))return;
    fprintf(f,"{\"type\":\"nativeCB\",\"phase\":\"%s\",\"session\":%llu,\"timeCF\":%.9f,\"timeCA\":%.9f,\"nativeCB\":%llu,\"logicalSubmit\":%llu,\"split\":%u,\"presentFrame\":%llu,\"family\":%u,\"index\":%u,\"createdCA\":%.9f,\"committedCA\":%.9f,\"scheduledCA\":%.9f,\"gpuStartCA\":%.9f,\"gpuEndCA\":%.9f,\"nativeStatus\":%ld,\"partialPrefix\":%s,\"counterSession\":%llu,\"counterSkip\":%d,\"counterAllocated\":%s,\"counterMidCB\":%s,\"droppedRows\":%llu}\n",
        phase,(unsigned long long)v->session,cf,ca,(unsigned long long)v->nativeID,
        (unsigned long long)v->logical,v->split,(unsigned long long)v->frame,v->family,v->index,
        v->createdCA,v->committedCA,v->scheduledCA,cb.GPUStartTime,cb.GPUEndTime,(long)cb.status,
        v->partialPrefix?"true":"false",(unsigned long long)counterSession,counterSkip,
        counterAllocated?"true":"false",counterMid?"true":"false",(unsigned long long)w.sessions[v->session].dropped);
    // Flush user-space buffers, not fsync. A later GPU fault must not erase the
    // only commit record. Normal unarmed operation performs no file writes.
    fflush(f);
}
inline void mvkStutterBeginNativeCB(id<MTLCommandBuffer> cb,uint32_t family,uint32_t index){
    if(!mvkStutterNativeEnabled()||!cb)return;MVKStutterErrnoGuard preserveErrno;static std::atomic<uint64_t> serial{1};
    NSMutableData*d=[NSMutableData dataWithLength:sizeof(MVKStutterNativeRecord)];
    if(!d)return;
    auto*owner=new(d.mutableBytes)MVKStutterNativeRecord;auto*r=&owner->value;
    r->nativeID=serial.fetch_add(1,std::memory_order_relaxed);r->family=family;r->index=index;
    r->createdCA=CACurrentMediaTime();r->createdCF=CFAbsoluteTimeGetCurrent();
    objc_setAssociatedObject(cb,mvkStutterNativeKey(),d,OBJC_ASSOCIATION_RETAIN);
    mvkStutterNativePhase(cb,"created");
}
inline void mvkStutterTagNativeCB(id<MTLCommandBuffer> cb,uint64_t logical,uint32_t split,uint64_t frame=0){
    auto*r=mvkStutterNativeRecord(cb);if(!r)return;
    os_unfair_lock_lock(&r->lock);r->value.logical=logical;r->value.split=split;r->value.frame=frame;os_unfair_lock_unlock(&r->lock);
    mvkStutterNativePhase(cb,"associated");
}
inline void mvkStutterNativeEvent(id<MTLCommandBuffer> cb,const void* event,uint64_t requested,
    const char* phase,uint64_t logical=0,uint64_t observed=0,bool satisfied=false,
    uint64_t fixedSession=0,bool sessionFixed=false,bool partialPrefix=false){
    if(!mvkStutterNativeEnabled())return;MVKStutterErrnoGuard preserveErrno;auto*r=mvkStutterNativeRecord(cb);auto arm=mvkStutterNativeArm();
    MVKStutterNativeSnapshot copy;
    if(r){os_unfair_lock_lock(&r->lock);if(!r->value.session&&arm.active){r->value.session=arm.session;r->value.partialPrefix=r->value.createdCF<arm.startedCF;}copy=r->value;os_unfair_lock_unlock(&r->lock);}
    uint64_t session=sessionFixed?fixedSession:(copy.session?copy.session:arm.session);if(!session)return;
    MVK_CPU_SCOPE(DiagnosticPublish);
    auto&w=mvkStutterNativeWriter();std::lock_guard<std::mutex>g(w.lock);FILE*f=w.output();if(!f||!w.admit(session))return;
    fprintf(f,"{\"type\":\"event\",\"phase\":\"%s\",\"session\":%llu,\"timeCF\":%.9f,\"timeCA\":%.9f,\"nativeCB\":%llu,\"logicalSubmit\":%llu,\"event\":%llu,\"requested\":%llu,\"observed\":%llu,\"satisfied\":%s,\"outsideArm\":%s,\"partialPrefix\":%s,\"droppedRows\":%llu}\n",
        phase,(unsigned long long)session,CFAbsoluteTimeGetCurrent(),CACurrentMediaTime(),
        (unsigned long long)copy.nativeID,(unsigned long long)(copy.logical?copy.logical:logical),
        (unsigned long long)(uintptr_t)event,(unsigned long long)requested,(unsigned long long)observed,
        satisfied?"true":"false",(!arm.active||arm.session!=session)?"true":"false",(partialPrefix||copy.partialPrefix)?"true":"false",(unsigned long long)w.sessions[session].dropped);fflush(f);
}
inline void mvkStutterSubmissionPhase(uint64_t logical,uint32_t family,uint32_t index,const char*phase,uint64_t createdNS){
    MVKStutterErrnoGuard preserveErrno;auto arm=mvkStutterNativeArm();if(!arm.active)return;
    MVK_CPU_SCOPE(DiagnosticPublish);
    auto&w=mvkStutterNativeWriter();std::lock_guard<std::mutex>g(w.lock);FILE*f=w.output();if(!f||!w.admit(arm.session))return;
    fprintf(f,"{\"type\":\"submission\",\"phase\":\"%s\",\"session\":%llu,\"timeCF\":%.9f,\"timeCA\":%.9f,\"logicalSubmit\":%llu,\"family\":%u,\"index\":%u,\"createdMonotonicNS\":%llu,\"droppedRows\":%llu}\n",
        phase,(unsigned long long)arm.session,CFAbsoluteTimeGetCurrent(),CACurrentMediaTime(),
        (unsigned long long)logical,family,index,(unsigned long long)createdNS,
        (unsigned long long)w.sessions[arm.session].dropped);fflush(f);
}
inline void mvkStutterPresentedFrame(uint64_t frame,const void*swapchain,uint64_t nativeTimestamp,
    uint64_t presentId,uint64_t session,uint64_t nativeCB=0,bool partialPrefix=false){
    if(!mvkStutterNativeEnabled())return;MVKStutterErrnoGuard preserveErrno;
    if(!session){auto arm=mvkStutterNativeArm();if(!arm.active)return;session=arm.session;partialPrefix=true;}
    MVK_CPU_SCOPE(DiagnosticPublish);
    auto&w=mvkStutterNativeWriter();std::lock_guard<std::mutex>g(w.lock);FILE*f=w.output();if(!f||!w.admit(session))return;
    fprintf(f,"{\"type\":\"present\",\"session\":%llu,\"timeCF\":%.9f,\"timeCA\":%.9f,\"presentFrame\":%llu,\"swapchain\":%llu,\"appPresentId\":%llu,\"nativeTimestampCA\":%.9f,\"nativeTimestampValid\":%s,\"nativeCB\":%llu,\"partialPrefix\":%s,\"droppedRows\":%llu}\n",
        (unsigned long long)session,CFAbsoluteTimeGetCurrent(),CACurrentMediaTime(),(unsigned long long)frame,
        (unsigned long long)(uintptr_t)swapchain,(unsigned long long)presentId,nativeTimestamp/1e9,
        nativeTimestamp?"true":"false",(unsigned long long)nativeCB,partialPrefix?"true":"false",(unsigned long long)w.sessions[session].dropped);fflush(f);
}
