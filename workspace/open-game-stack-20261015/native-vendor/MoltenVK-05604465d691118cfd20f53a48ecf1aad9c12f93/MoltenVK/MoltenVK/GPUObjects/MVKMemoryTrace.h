// Opt-in read-only allocation/device-memory observations. No allocation flags,
// resource lifetimes, return values, or exception handling are changed.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <cerrno>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <unistd.h>
#include <fcntl.h>
#include <os/lock.h>

// Requested sizes are cumulative API requests, NOT live bytes or free VRAM.
// Heap capacity plus placed children double-count common backing storage.
enum class MVKStutterMemoryKind : uint32_t { Buffer=0, Heap=1, Texture=2, Host=3 };
struct MVKStutterMemoryAllocationToken {
    bool active=false, bytesKnown=false;
    MVKStutterMemoryKind kind=MVKStutterMemoryKind::Buffer;
    uint32_t storageMode=0;
    uint64_t requestedBytes=0, beginNS=0;
    const char* site=nullptr; // static literal until AllocationEnd()
};
namespace mvkStutterMemoryDetail {
struct ErrnoScope { int saved=errno; ~ErrnoScope(){errno=saved;} };
inline bool enabled() {
    static const bool value=[] {const char*p=getenv("MVK_AMD_STUTTER_COVERAGE");return p&&!strcmp(p,"1");}();
    return value;
}
inline uint64_t monotonicNS(){timespec t{};clock_gettime(CLOCK_MONOTONIC,&t);return uint64_t(t.tv_sec)*1000000000ULL+t.tv_nsec;}
inline double cfTime(){timespec t{};clock_gettime(CLOCK_REALTIME,&t);return double(t.tv_sec)-978307200.0+double(t.tv_nsec)*1e-9;}
inline const char* kindName(uint32_t k){static const char*names[]={"buffer","heap","texture","host"};return k<4?names[k]:"unknown";}
inline const char* modeName(uint32_t m){static const char*names[]={"shared","managed","private","memoryless","other"};return names[m<4?m:4];}
struct Counters {
    std::atomic<uint64_t> attempts{0},completed{0},succeeded{0},nilResults{0},rejectedBeforeCall{0};
    std::atomic<uint64_t> knownByteRequests{0},unknownByteRequests{0},attemptedRequestedBytes{0},successfulRequestedBytes{0};
    std::atomic<uint64_t> hostCallTotalNS{0},hostCallMaxNS{0};
};
struct Event {
    uint64_t sequence=0,requestedBytes=0,hostNS=0,limitBytes=0;
    double time=0;
    uint32_t kind=0,storage=0;
    int64_t resultCode=0;
    bool bytesKnown=false,returnedNil=false,rejected=false,siteTruncated=false,reasonTruncated=false,labelSanitized=false;
    char site[112]{},reason[72]{};
};
struct State {
    Counters counters[4][5];
    std::atomic<uint64_t> lastReportNS{0},reports{0},writerErrors{0},eventWriteErrors{0},metadataTruncations{0},failureEvents{0},slowEvents{0};
    os_unfair_lock eventsLock=OS_UNFAIR_LOCK_INIT;
    Event failures[32],slow[32];
};
inline State state;
inline Counters& counter(MVKStutterMemoryKind k,uint32_t mode){return state.counters[static_cast<uint32_t>(k)<4?static_cast<uint32_t>(k):0][mode<4?mode:4];}
inline void jsonString(FILE*f,const char*s){
    fputc('"',f);if(s)for(unsigned n=0;s[n]&&n<1024;++n){unsigned char c=s[n];if(c=='"'||c=='\\'){fputc('\\',f);fputc(c,f);}else if(c<32)fprintf(f,"\\u%04x",c);else fputc(c,f);}fputc('"',f);
}
inline void writeEvent(FILE*f,const Event&e){
    fprintf(f,"{\"sequence\":%llu,\"time\":%.6f,\"kind\":",(unsigned long long)e.sequence,e.time);jsonString(f,kindName(e.kind));
    fprintf(f,",\"storageMode\":%u,\"storageName\":",e.storage);jsonString(f,modeName(e.storage));
    fprintf(f,",\"requestedBytes\":%llu,\"requestedBytesKnown\":%s,\"hostCallNS\":%llu,\"returnedNil\":%s,\"rejectedBeforeMetalCall\":%s,\"resultCode\":%lld,\"limitBytes\":%llu,\"site\":",(unsigned long long)e.requestedBytes,e.bytesKnown?"true":"false",(unsigned long long)e.hostNS,e.returnedNil?"true":"false",e.rejected?"true":"false",(long long)e.resultCode,(unsigned long long)e.limitBytes);jsonString(f,e.site);fputs(",\"reason\":",f);jsonString(f,e.reason);fprintf(f,",\"siteTruncated\":%s,\"reasonTruncated\":%s,\"labelSanitized\":%s}",e.siteTruncated?"true":"false",e.reasonTruncated?"true":"false",e.labelSanitized?"true":"false");
}
inline void escapeJSON(char*output,size_t capacity,const char*source){
    static const char hex[]="0123456789abcdef";size_t n=0;
    for(size_t i=0;source[i]&&n+7<capacity;++i){unsigned char c=source[i];
        if(c=='"'||c=='\\'){output[n++]='\\';output[n++]=c;}
        else if(c<32){output[n++]='\\';output[n++]='u';output[n++]='0';output[n++]='0';output[n++]=hex[c>>4];output[n++]=hex[c&15];}
        else output[n++]=c;
    }output[n]=0;
}
inline void persistEvent(const Event&e,bool failure){
    // Allocation-failure/slow-path journal uses stack bytes + open/write only,
    // not FILE/NSString/NSDictionary allocations during an OOM observation.
    if(e.sequence>128)return;const char*dir=getenv("MVK_CONFIG_SHADER_DUMP_DIR");if(!dir)return;
    char path[4096];int n=snprintf(path,sizeof(path),"%s/memory-%s-%d.jsonl",dir,failure?"failures":"slow-allocations",getpid());
    if(n<0||size_t(n)>=sizeof(path))return;
    char site[sizeof(e.site)*6+1],reason[sizeof(e.reason)*6+1],line[2048];escapeJSON(site,sizeof(site),e.site);escapeJSON(reason,sizeof(reason),e.reason);
    n=snprintf(line,sizeof(line),"{\"sequence\":%llu,\"time\":%.6f,\"kind\":\"%s\",\"storageMode\":%u,\"storageName\":\"%s\",\"requestedBytes\":%llu,\"requestedBytesKnown\":%s,\"hostCallNS\":%llu,\"returnedNil\":%s,\"rejectedBeforeMetalCall\":%s,\"resultCode\":%lld,\"limitBytes\":%llu,\"site\":\"%s\",\"reason\":\"%s\",\"siteTruncated\":%s,\"reasonTruncated\":%s,\"labelSanitized\":%s}\n",(unsigned long long)e.sequence,e.time,kindName(e.kind),e.storage,modeName(e.storage),(unsigned long long)e.requestedBytes,e.bytesKnown?"true":"false",(unsigned long long)e.hostNS,e.returnedNil?"true":"false",e.rejected?"true":"false",(long long)e.resultCode,(unsigned long long)e.limitBytes,site,reason,e.siteTruncated?"true":"false",e.reasonTruncated?"true":"false",e.labelSanitized?"true":"false");
    if(n<0||size_t(n)>=sizeof(line)){state.writerErrors.fetch_add(1,std::memory_order_relaxed);state.eventWriteErrors.fetch_add(1,std::memory_order_relaxed);return;}
    int fd=open(path,O_WRONLY|O_CREAT|O_APPEND,0600);if(fd<0){state.writerErrors.fetch_add(1,std::memory_order_relaxed);state.eventWriteErrors.fetch_add(1,std::memory_order_relaxed);return;}
    if(write(fd,line,size_t(n))!=n){state.writerErrors.fetch_add(1,std::memory_order_relaxed);state.eventWriteErrors.fetch_add(1,std::memory_order_relaxed);}close(fd);
}
inline bool copyLabel(char*destination,size_t capacity,const char*source,bool&sanitized){
    if(!source){destination[0]=0;return false;}size_t n=0;
    while(source[n]&&n+1<capacity){unsigned char c=source[n];destination[n]=c<128?char(c):'?';if(c>=128)sanitized=true;++n;}
    destination[n]=0;return source[n]!=0;
}
inline void recordEvent(MVKStutterMemoryAllocationToken token,bool nilResult,bool rejected,uint64_t duration,const char*reason,int64_t resultCode,uint64_t limitBytes,bool failure){
    Event event{};event.sequence=(failure?state.failureEvents:state.slowEvents).fetch_add(1,std::memory_order_relaxed)+1;
    event.time=cfTime();event.kind=static_cast<uint32_t>(token.kind);event.storage=token.storageMode;event.requestedBytes=token.requestedBytes;event.bytesKnown=token.bytesKnown;event.returnedNil=nilResult;event.rejected=rejected;event.hostNS=duration;event.resultCode=resultCode;event.limitBytes=limitBytes;
    event.siteTruncated=copyLabel(event.site,sizeof(event.site),token.site,event.labelSanitized);event.reasonTruncated=copyLabel(event.reason,sizeof(event.reason),reason,event.labelSanitized);if(event.siteTruncated||event.reasonTruncated||event.labelSanitized)state.metadataTruncations.fetch_add(1,std::memory_order_relaxed);
    os_unfair_lock_lock(&state.eventsLock);auto&slot=(failure?state.failures:state.slow)[(event.sequence-1)%32];if(slot.sequence<event.sequence)slot=event;os_unfair_lock_unlock(&state.eventsLock);
    persistEvent(event,failure);
}
inline void maximum(std::atomic<uint64_t>&value,uint64_t incoming){uint64_t old=value.load(std::memory_order_relaxed);while(old<incoming&&!value.compare_exchange_weak(old,incoming,std::memory_order_relaxed)){};}
}

inline MVKStutterMemoryAllocationToken mvkStutterMemoryAllocationBegin(MVKStutterMemoryKind kind,uint64_t bytes,uint32_t storageMode,const char*site,bool bytesKnown=true){
    mvkStutterMemoryDetail::ErrnoScope errnoScope;MVKStutterMemoryAllocationToken token{};if(!mvkStutterMemoryDetail::enabled())return token;
    token.active=true;token.kind=kind;token.requestedBytes=bytes;token.storageMode=storageMode;token.site=site;token.bytesKnown=bytesKnown;token.beginNS=mvkStutterMemoryDetail::monotonicNS();
    auto&c=mvkStutterMemoryDetail::counter(kind,storageMode);c.attempts.fetch_add(1,std::memory_order_relaxed);
    (bytesKnown?c.knownByteRequests:c.unknownByteRequests).fetch_add(1,std::memory_order_relaxed);if(bytesKnown)c.attemptedRequestedBytes.fetch_add(bytes,std::memory_order_relaxed);return token;
}
inline void mvkStutterMemoryAllocationEnd(const MVKStutterMemoryAllocationToken&token,bool succeeded,int64_t resultCode=0){
    if(!token.active)return;using namespace mvkStutterMemoryDetail;ErrnoScope errnoScope;
    uint64_t duration=monotonicNS()-token.beginNS;auto&c=counter(token.kind,token.storageMode);c.completed.fetch_add(1,std::memory_order_relaxed);c.hostCallTotalNS.fetch_add(duration,std::memory_order_relaxed);maximum(c.hostCallMaxNS,duration);
    if(succeeded){c.succeeded.fetch_add(1,std::memory_order_relaxed);if(token.bytesKnown)c.successfulRequestedBytes.fetch_add(token.requestedBytes,std::memory_order_relaxed);}else c.nilResults.fetch_add(1,std::memory_order_relaxed);
    if(!succeeded)recordEvent(token,true,false,duration,"nil-or-unsuccessful-result",resultCode,0,true);
    else if(duration>=2000000ULL)recordEvent(token,false,false,duration,"host-allocation-call-at-least-2ms",resultCode,0,false);
}
inline void mvkStutterMemoryAllocationRejected(MVKStutterMemoryKind kind,uint64_t bytes,uint32_t storageMode,const char*site,const char*reason,uint64_t limitBytes=0){
    mvkStutterMemoryDetail::ErrnoScope errnoScope;if(!mvkStutterMemoryDetail::enabled())return;
    mvkStutterMemoryDetail::counter(kind,storageMode).rejectedBeforeCall.fetch_add(1,std::memory_order_relaxed);
    MVKStutterMemoryAllocationToken t{};t.active=true;t.kind=kind;t.requestedBytes=bytes;t.storageMode=storageMode;t.site=site;t.bytesKnown=true;
    mvkStutterMemoryDetail::recordEvent(t,false,true,0,reason,0,limitBytes,true);
}

inline void mvkStutterReportMetalMemory(id<MTLDevice>device){
    using namespace mvkStutterMemoryDetail;ErrnoScope errnoScope;if(!enabled())return;
    uint64_t now=monotonicNS(),last=state.lastReportNS.load(std::memory_order_relaxed);
    if(last&&now-last<5000000000ULL)return;
    if(!state.lastReportNS.compare_exchange_strong(last,now,std::memory_order_relaxed))return;
    bool allocatedAvailable=false,recommendedAvailable=false,unifiedAvailable=false,maximumAvailable=false;
    uint64_t allocated=0,recommended=0,maxBuffer=0;bool unified=false;
    if(device){
        if(@available(macOS 10.13,iOS 11.0,tvOS 11.0,*)){
            allocatedAvailable=[device respondsToSelector:@selector(currentAllocatedSize)];if(allocatedAvailable)allocated=device.currentAllocatedSize;
        }
        if(@available(macOS 10.12,iOS 16.0,tvOS 16.0,*)){
            recommendedAvailable=[device respondsToSelector:@selector(recommendedMaxWorkingSetSize)];if(recommendedAvailable)recommended=device.recommendedMaxWorkingSetSize;
        }
        if(@available(macOS 10.15,iOS 13.0,tvOS 13.0,*)){
            unifiedAvailable=[device respondsToSelector:@selector(hasUnifiedMemory)];if(unifiedAvailable)unified=device.hasUnifiedMemory;
        }
        if(@available(macOS 10.14,iOS 12.0,tvOS 12.0,*)){
            maximumAvailable=[device respondsToSelector:@selector(maxBufferLength)];if(maximumAvailable)maxBuffer=device.maxBufferLength;
        }
    }
    struct Row {uint64_t a=0,c=0,s=0,n=0,r=0,k=0,u=0,b=0,bs=0,ns=0,max=0;};Row rows[4][5];Row total{};
    for(unsigned kind=0;kind<4;++kind)for(unsigned mode=0;mode<5;++mode){auto&c=state.counters[kind][mode];Row&r=rows[kind][mode];
        r.a=c.attempts.load(std::memory_order_relaxed);r.c=c.completed.load(std::memory_order_relaxed);r.s=c.succeeded.load(std::memory_order_relaxed);r.n=c.nilResults.load(std::memory_order_relaxed);r.r=c.rejectedBeforeCall.load(std::memory_order_relaxed);r.k=c.knownByteRequests.load(std::memory_order_relaxed);r.u=c.unknownByteRequests.load(std::memory_order_relaxed);r.b=c.attemptedRequestedBytes.load(std::memory_order_relaxed);r.bs=c.successfulRequestedBytes.load(std::memory_order_relaxed);r.ns=c.hostCallTotalNS.load(std::memory_order_relaxed);r.max=c.hostCallMaxNS.load(std::memory_order_relaxed);
        total.a+=r.a;total.c+=r.c;total.s+=r.s;total.n+=r.n;total.r+=r.r;total.k+=r.k;total.u+=r.u;total.b+=r.b;total.bs+=r.bs;total.ns+=r.ns;total.max=std::max(total.max,r.max);
    }
    Event failures[32],slow[32];os_unfair_lock_lock(&state.eventsLock);memcpy(failures,state.failures,sizeof(failures));memcpy(slow,state.slow,sizeof(slow));os_unfair_lock_unlock(&state.eventsLock);
    uint64_t failuresTotal=state.failureEvents.load(std::memory_order_relaxed),slowTotal=state.slowEvents.load(std::memory_order_relaxed),report=state.reports.fetch_add(1,std::memory_order_relaxed);
    const char*dir=getenv("MVK_CONFIG_SHADER_DUMP_DIR");if(!dir)return;char path[4096],temporary[4096],history[4096];
    int n=snprintf(path,sizeof(path),"%s/memory-current-%d.json",dir,getpid());int t=snprintf(temporary,sizeof(temporary),"%s/memory-current-%d.json.next",dir,getpid());int h=snprintf(history,sizeof(history),"%s/memory-stats-%d.jsonl",dir,getpid());if(n<0||t<0||h<0||size_t(n)>=sizeof(path)||size_t(t)>=sizeof(temporary)||size_t(h)>=sizeof(history))return;
    auto writeSnapshot=[&](FILE*f){
        fprintf(f,"{\"time\":%.6f,\"monotonicNS\":%llu,\"pid\":%d,\"reportIndex\":%llu,\"historyCapped\":%s,\"deviceAvailable\":%s,\"currentAllocatedSizeAvailable\":%s,\"currentAllocatedSizeBytes\":",cfTime(),(unsigned long long)now,getpid(),(unsigned long long)report,report>=1024?"true":"false",device?"true":"false",allocatedAvailable?"true":"false");if(allocatedAvailable)fprintf(f,"%llu",(unsigned long long)allocated);else fputs("null",f);
        fprintf(f,",\"recommendedMaxWorkingSetSizeAvailable\":%s,\"recommendedMaxWorkingSetSizeBytes\":",recommendedAvailable?"true":"false");if(recommendedAvailable)fprintf(f,"%llu",(unsigned long long)recommended);else fputs("null",f);
        fprintf(f,",\"hasUnifiedMemoryAvailable\":%s,\"hasUnifiedMemory\":",unifiedAvailable?"true":"false");if(unifiedAvailable)fputs(unified?"true":"false",f);else fputs("null",f);
        fprintf(f,",\"maxBufferLengthAvailable\":%s,\"maxBufferLengthBytes\":",maximumAvailable?"true":"false");if(maximumAvailable)fprintf(f,"%llu",(unsigned long long)maxBuffer);else fputs("null",f);
        fprintf(f,",\"allocationAttempts\":%llu,\"allocationCallsCompleted\":%llu,\"allocationCallsSucceeded\":%llu,\"nilOrUnsuccessfulResults\":%llu,\"rejectedBeforeCall\":%llu,\"knownByteRequests\":%llu,\"unknownByteRequests\":%llu,\"cumulativeAttemptedRequestedBytes\":%llu,\"cumulativeSuccessfulRequestedBytes\":%llu,\"cumulativeHostAllocationCallNS\":%llu,\"largestHostAllocationCallNS\":%llu,\"failureEventsTotal\":%llu,\"slowEventsTotal\":%llu,\"writerErrorsTotal\":%llu,\"semantics\":\"currentAllocatedSize is Metal API allocated resources for this MTLDevice, not free or physically resident VRAM; recommendedMaxWorkingSetSize is an approximate good-performance threshold, not free capacity; request counters are process-wide cumulative instrumented calls and heap+child requests may share backing; attempts not yet completed can be in-flight or unwound exceptions; no exceptions are intercepted\",\"allocations\":[",(unsigned long long)total.a,(unsigned long long)total.c,(unsigned long long)total.s,(unsigned long long)total.n,(unsigned long long)total.r,(unsigned long long)total.k,(unsigned long long)total.u,(unsigned long long)total.b,(unsigned long long)total.bs,(unsigned long long)total.ns,(unsigned long long)total.max,(unsigned long long)failuresTotal,(unsigned long long)slowTotal,(unsigned long long)state.writerErrors.load(std::memory_order_relaxed));
        bool comma=false;for(unsigned kind=0;kind<4;++kind)for(unsigned mode=0;mode<5;++mode){const Row&r=rows[kind][mode];if(!r.a&&!r.r)continue;if(comma)fputc(',',f);comma=true;fputs("{\"kind\":",f);jsonString(f,kindName(kind));fputs(",\"storageName\":",f);jsonString(f,modeName(mode));fprintf(f,",\"storageBucket\":%u,\"attempts\":%llu,\"completed\":%llu,\"succeeded\":%llu,\"nilOrUnsuccessfulResults\":%llu,\"rejectedBeforeCall\":%llu,\"knownByteRequests\":%llu,\"unknownByteRequests\":%llu,\"cumulativeAttemptedRequestedBytes\":%llu,\"cumulativeSuccessfulRequestedBytes\":%llu,\"hostCallTotalNS\":%llu,\"hostCallMaxNS\":%llu}",mode,(unsigned long long)r.a,(unsigned long long)r.c,(unsigned long long)r.s,(unsigned long long)r.n,(unsigned long long)r.r,(unsigned long long)r.k,(unsigned long long)r.u,(unsigned long long)r.b,(unsigned long long)r.bs,(unsigned long long)r.ns,(unsigned long long)r.max);}
        fprintf(f,"],\"diagnosticWriterErrors\":%llu,\"eventJournalWriteErrors\":%llu,\"diagnosticOutputAvailableWithoutObservedWriteError\":%s,\"metadataLabelsTruncatedOrSanitized\":%llu,\"failureJournalCapped\":%s,\"failureJournalOmittedEvents\":%llu,\"slowJournalCapped\":%s,\"slowJournalOmittedEvents\":%llu,\"eventDetailsTruncated\":%s,\"recentFailures\":[",(unsigned long long)state.writerErrors.load(std::memory_order_relaxed),(unsigned long long)state.eventWriteErrors.load(std::memory_order_relaxed),state.writerErrors.load(std::memory_order_relaxed)?"false":"true",(unsigned long long)state.metadataTruncations.load(std::memory_order_relaxed),failuresTotal>128?"true":"false",(unsigned long long)(failuresTotal>128?failuresTotal-128:0),slowTotal>128?"true":"false",(unsigned long long)(slowTotal>128?slowTotal-128:0),(failuresTotal>32||slowTotal>32||state.metadataTruncations.load(std::memory_order_relaxed)||state.eventWriteErrors.load(std::memory_order_relaxed))?"true":"false");comma=false;for(uint64_t i=failuresTotal>32?failuresTotal-32:0;i<failuresTotal;++i){const auto&e=failures[i%32];if(e.sequence!=i+1)continue;if(comma)fputc(',',f);comma=true;writeEvent(f,e);}fputs("],\"recentSlowAllocationCalls\":[",f);comma=false;for(uint64_t i=slowTotal>32?slowTotal-32:0;i<slowTotal;++i){const auto&e=slow[i%32];if(e.sequence!=i+1)continue;if(comma)fputc(',',f);comma=true;writeEvent(f,e);}fputs("]}",f);
    };
    if(FILE*f=fopen(temporary,"w")){writeSnapshot(f);fputc('\n',f);bool bad=ferror(f)!=0;int closed=fclose(f);if(bad||closed!=0)state.writerErrors.fetch_add(1,std::memory_order_relaxed);else if(rename(temporary,path)!=0)state.writerErrors.fetch_add(1,std::memory_order_relaxed);}else state.writerErrors.fetch_add(1,std::memory_order_relaxed);
    if(report<1024){if(FILE*f=fopen(history,"a")){writeSnapshot(f);fputc('\n',f);bool bad=ferror(f)!=0;int closed=fclose(f);if(bad||closed!=0)state.writerErrors.fetch_add(1,std::memory_order_relaxed);}else state.writerErrors.fetch_add(1,std::memory_order_relaxed);}
}

inline uint64_t mvkStutterMemoryWriterErrorCount(){return mvkStutterMemoryDetail::state.writerErrors.load(std::memory_order_relaxed);}
