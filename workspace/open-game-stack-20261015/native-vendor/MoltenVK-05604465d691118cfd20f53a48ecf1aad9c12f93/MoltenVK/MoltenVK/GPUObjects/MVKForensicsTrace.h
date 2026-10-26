// Armable, bounded causal records. Diagnostics must never change API results.
#pragma once
#include "MVKStutterCoverage.h"
#include <CoreFoundation/CoreFoundation.h>
#include <QuartzCore/CAMediaTiming.h>
#include <array>
#include <atomic>
#include <initializer_list>
#include <utility>
#include <mutex>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>
#include <sys/statvfs.h>
#if defined(__OBJC__)
#import <Foundation/Foundation.h>
#endif

namespace MVKForensics {
struct ErrnoGuard { int saved=errno; ~ErrnoGuard(){errno=saved;} };
inline bool identifier(const char*text,size_t maximum,bool dots=false) noexcept {
    if(!text)return false;size_t length=strnlen(text,maximum+1);if(!length||length>maximum)return false;
    for(size_t i=0;i<length;i++){unsigned char c=text[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||(dots&&c=='.')))return false;}
    return true;
}
struct State {
    std::atomic<uint64_t> nextRefreshNS{0},session{0};
    std::mutex lock;
    FILE*file=nullptr;
    uint64_t runID=MVKCPUDefaultClock::unixNS(),generation=0,sequence=0,lastArm=0;
    uint64_t bytes=0,written=0,dropped=0,ioFailures=0;
    std::atomic<uint64_t> serializationFailures{0},rejectedBeforeRecord{0};
    uint64_t writerHostNS=0,flushNS=0,second=0,secondRows=0;
    uint64_t lowDiskDrops=0,nextDiskCheckNS=0;
    bool lowDisk=false;
    const char*dir=getenv("MVK_CONFIG_SHADER_DUMP_DIR");
    const char*arm=getenv("MVK_AMD_FORENSICS_ARM_PATH");
    // Qualification may scale only the segment threshold; production stays 8MiB.
#if defined(MVK_FORENSICS_TEST_SEGMENT_BYTES)
    static_assert(MVK_FORENSICS_TEST_SEGMENT_BYTES>=2048&&MVK_FORENSICS_TEST_SEGMENT_BYTES<=8*1024*1024,"test-only bounded segment size");
    static constexpr uint64_t segmentBytes=MVK_FORENSICS_TEST_SEGMENT_BYTES;
#else
    static constexpr uint64_t segmentBytes=8*1024*1024;
#endif
    static constexpr uint64_t maxRowBytes=96*1024;
    static constexpr size_t maxKindBytes=96,maxFieldNameBytes=64,maxNumericFields=128;
    static constexpr unsigned segmentSlots=4,rowsPerSecond=4096;
    ~State(){if(file)fclose(file);}
    uint64_t active() noexcept {
        if(!arm||!dir)return 0;
        uint64_t now=mvkStutterMonotonicNS();
        if(now>=nextRefreshNS.load(std::memory_order_relaxed)){
            uint64_t expected=nextRefreshNS.load(std::memory_order_relaxed);
            if(now>=expected&&nextRefreshNS.compare_exchange_strong(expected,now+250000000ULL)){
                ErrnoGuard preserve;struct stat st{};uint64_t value=0;
                auto wall=MVKCPUDefaultClock::unixNS()/1000000000ULL;
                if(stat(arm,&st)==0&&S_ISREG(st.st_mode)&&st.st_mtime<=wall&&wall-st.st_mtime<120)
                    value=uint64_t(st.st_mtimespec.tv_sec)*1000000000ULL+st.st_mtimespec.tv_nsec;
                session.store(value,std::memory_order_release);
            }
        }
        return session.load(std::memory_order_acquire);
    }
    void currentLocked(uint64_t now){
        char path[4096],temp[4096];
        if(snprintf(path,sizeof(path),"%s/forensics-current-%d.json",dir,getpid())>=int(sizeof(path)))return;
        if(snprintf(temp,sizeof(temp),"%s.next",path)>=int(sizeof(temp)))return;
        FILE*f=fopen(temp,"w");if(!f){++ioFailures;return;}
        fprintf(f,"{\"schema\":1,\"pid\":%d,\"runID\":%llu,\"session\":%llu,\"segmentGeneration\":%llu,\"segmentSlots\":%u,\"segmentByteLimit\":%llu,\"segmentBytes\":%llu,\"written\":%llu,\"dropped\":%llu,\"IOFailures\":%llu,\"serializationFailures\":%llu,\"lowDiskDrops\":%llu,\"writerHostNS\":%llu,\"machNS\":%llu,\"clockDomain\":\"mach-absolute-nanoseconds\",\"rollingMayReplaceUncollectedRows\":true,\"observerOverheadNotSubtracted\":true,\"writerHostNSIsCallerWallSum\":true,\"writerHostNSIncludesMutexWaitAndFlush\":true,\"writerHostNSSnapshotMayLagCurrentIO\":true,\"rowsPerSecond\":%u,\"maxPayloadBytes\":%llu,\"maxKindBytes\":%zu,\"maxNumericFields\":%zu}\n",
            getpid(),(unsigned long long)runID,(unsigned long long)session.load(),(unsigned long long)generation,segmentSlots,(unsigned long long)segmentBytes,(unsigned long long)bytes,(unsigned long long)written,(unsigned long long)(dropped+rejectedBeforeRecord.load()),(unsigned long long)ioFailures,(unsigned long long)serializationFailures.load(),(unsigned long long)lowDiskDrops,(unsigned long long)writerHostNS,(unsigned long long)now,rowsPerSecond,(unsigned long long)maxRowBytes,maxKindBytes,maxNumericFields);
        bool ok=!ferror(f)&&fflush(f)==0;ok=fclose(f)==0&&ok;
        if(ok){if(rename(temp,path))++ioFailures;}else{++ioFailures;unlink(temp);}
    }
    bool openLocked(uint64_t armID){
        if(file){if(fclose(file))++ioFailures;file=nullptr;}
        ++generation;bytes=0;char path[4096];
        if(snprintf(path,sizeof(path),"%s/forensics-%d-%llu-%u.jsonl",dir,getpid(),(unsigned long long)runID,unsigned((generation-1)%segmentSlots))>=int(sizeof(path))){++ioFailures;return false;}
        // Only this process-run's explicitly rotating slots are replaced.
        file=fopen(path,"w");if(!file){++ioFailures;return false;}
        uint64_t before=mvkStutterMonotonicNS();double cf=CFAbsoluteTimeGetCurrent();double ca=CACurrentMediaTime();uint64_t after=mvkStutterMonotonicNS();
        int n=fprintf(file,"{\"schema\":1,\"type\":\"clockCalibration\",\"pid\":%d,\"runID\":%llu,\"streamGeneration\":%llu,\"session\":%llu,\"machBeforeNS\":%llu,\"machAfterNS\":%llu,\"timeCF\":%.9f,\"timeCA\":%.9f,\"clockDomain\":\"mach-absolute-nanoseconds\",\"rollingSegmentSlots\":%u}\n",getpid(),(unsigned long long)runID,(unsigned long long)generation,(unsigned long long)armID,(unsigned long long)before,(unsigned long long)after,cf,ca,segmentSlots);
        if(n<0||fflush(file)){++ioFailures;fclose(file);file=nullptr;return false;}bytes+=uint64_t(n);return true;
    }
    void record(const char*kind,const char*body,size_t bodyBytes,bool jsonPayload,uint64_t ownerSession=0) noexcept {
        uint64_t armID=ownerSession?ownerSession:active();if(!armID||!dir)return;
        ErrnoGuard preserve;uint64_t start=mvkStutterMonotonicNS();
        try{
            std::lock_guard<std::mutex> guard(lock);
            // Sum caller wall latency through synchronous flush/current-file IO,
            // including mutex wait. This is not thread CPU time and may overlap
            // across callers. The published snapshot can lag its own last IO.
            struct Accounting {State&state;uint64_t start;~Accounting(){state.writerHostNS+=mvkStutterMonotonicNS()-start;}} accounting{*this,start};
            uint64_t now=mvkStutterMonotonicNS();
            if(!identifier(kind,maxKindBytes,true)||(!body&&bodyBytes)||bodyBytes>maxRowBytes||bodyBytes+1024>segmentBytes){++dropped;return;}
            if(now>=nextDiskCheckNS){struct statvfs s{};lowDisk=statvfs(dir,&s)==0&&uint64_t(s.f_bavail)*s.f_frsize<512ULL*1024*1024;nextDiskCheckNS=now+10000000000ULL;}
            uint64_t sec=now/1000000000ULL;if(sec!=second){second=sec;secondRows=0;}
            if(lowDisk||++secondRows>rowsPerSecond){++dropped;if(lowDisk)++lowDiskDrops;if(now-flushNS>250000000ULL){currentLocked(now);flushNS=now;}return;}
            if(!file||lastArm!=armID||bytes+bodyBytes+1024>segmentBytes){if(!openLocked(armID))return;lastArm=armID;}
            auto c=mvkStutterContext();uint64_t thread=0;pthread_threadid_np(nullptr,&thread);
            int n=fprintf(file,"{\"schema\":1,\"type\":\"forensics\",\"kind\":\"%s\",\"pid\":%d,\"runID\":%llu,\"streamGeneration\":%llu,\"seq\":%llu,\"session\":%llu,\"machNS\":%llu,\"threadMachID\":%llu,\"context\":{\"domain\":%u,\"queueFamily\":%u,\"queueIndex\":%u,\"logicalSubmit\":%llu,\"nativeCB\":%llu,\"frame\":%llu,\"shader\":%llu},\"%s\":",
                kind,getpid(),(unsigned long long)runID,(unsigned long long)generation,(unsigned long long)++sequence,(unsigned long long)armID,(unsigned long long)now,(unsigned long long)thread,c.domain,c.queueFamily,c.queueIndex,(unsigned long long)c.submission,(unsigned long long)c.nativeCB,(unsigned long long)c.frame,(unsigned long long)c.shader,jsonPayload?"payload":"fields");
            if(n<0||fwrite(body,1,bodyBytes,file)!=bodyBytes||fwrite("}\n",1,2,file)!=2){++ioFailures;return;}
            bytes+=uint64_t(n)+bodyBytes+2;++written;
            if(written%64==0||now-flushNS>250000000ULL){if(fflush(file))++ioFailures;currentLocked(now);flushNS=now;}
        }catch(...){++rejectedBeforeRecord;}
    }
};
inline State& state(){static State s;return s;}
}
inline uint64_t mvkForensicsSessionID() noexcept {return MVKForensics::state().active();}
inline bool mvkForensicsArmed() noexcept {return mvkForensicsSessionID()!=0;}
inline void mvkForensicsRecordArray(uint64_t ownerSession,const char*kind,const std::pair<const char*,uint64_t>*fields,size_t count) noexcept {
    if(!ownerSession&&!mvkForensicsArmed())return;
    MVKForensics::ErrnoGuard preserve;
    if(count>MVKForensics::State::maxNumericFields||(count&&!fields)){++MVKForensics::state().rejectedBeforeRecord;return;}
    char body[8192];size_t offset=0;body[offset++]='{';bool comma=false;
    for(size_t i=0;i<count;++i){const auto&item=fields[i];if(!MVKForensics::identifier(item.first,MVKForensics::State::maxFieldNameBytes)){++MVKForensics::state().rejectedBeforeRecord;return;}for(size_t j=0;j<i;j++)if(!strcmp(item.first,fields[j].first)){++MVKForensics::state().rejectedBeforeRecord;return;}int n=snprintf(body+offset,sizeof(body)-offset,"%s\"%s\":%llu",comma?",":"",item.first,(unsigned long long)item.second);if(n<0||size_t(n)>=sizeof(body)-offset){++MVKForensics::state().rejectedBeforeRecord;return;}offset+=size_t(n);comma=true;}
    if(offset+1>=sizeof(body)){++MVKForensics::state().rejectedBeforeRecord;return;}body[offset++]='}';MVKForensics::state().record(kind,body,offset,false,ownerSession);
}
inline void mvkForensicsRecordForSession(uint64_t session,const char*kind,std::initializer_list<std::pair<const char*,uint64_t>>fields) noexcept {mvkForensicsRecordArray(session,kind,fields.begin(),fields.size());}
inline void mvkForensicsRecord(const char*kind,std::initializer_list<std::pair<const char*,uint64_t>>fields) noexcept {mvkForensicsRecordForSession(0,kind,fields);}
// A paired coarse scope retains its session and owner when an arm closes or TLS
// changes. The logger's own budgets still apply and remain explicit.
class MVKForensicsScope {
    const char*_kind; uint64_t _session=0,_start=0,_id=0; MVKCPUContext _owner{};
    inline static std::atomic<uint64_t> sequence{0};
    std::array<std::pair<const char*,uint64_t>,24> _fields{};size_t _count=0;bool _fieldCap=false;
    void emit(uint64_t phase) noexcept {
        _fields[0]={"phase",phase};_fields[1]={"spanID",_id};_fields[2]={"startMachNS",_start};
        _fields[3]={"elapsedWallNS",phase?mvkStutterMonotonicNS()-_start:0};_fields[4]={"ownerSubmission",_owner.submission};
        _fields[5]={"ownerNativeCB",_owner.nativeCB};_fields[6]={"ownerQueueFamily",_owner.queueFamily};_fields[7]={"ownerQueueIndex",_owner.queueIndex};
        _fields[8]={"ownerFrame",_owner.frame};_fields[9]={"ownerShader",_owner.shader};_fields[10]={"scopeFieldCap",_fieldCap};
        mvkForensicsRecordArray(_session,_kind,_fields.data(),_count);
    }
public:
    MVKForensicsScope(const char*kind,std::initializer_list<std::pair<const char*,uint64_t>> fields={}):_kind(kind){
        _session=mvkForensicsSessionID();if(!_session)return;_start=mvkStutterMonotonicNS();_owner=mvkStutterContext();_id=++sequence;_count=11;
        for(auto f:fields){if(_count==_fields.size()){_fieldCap=true;break;}_fields[_count++]=f;}emit(0);
    }
    ~MVKForensicsScope(){if(_session)emit(1);}
    MVKForensicsScope(const MVKForensicsScope&)=delete;
};
#if defined(__OBJC__)
inline void mvkForensicsJSON(const char*kind,NSDictionary*payload) noexcept {
    if(!mvkForensicsArmed())return;
    MVKForensics::ErrnoGuard preserve;
    @try {NSError*error=nil;NSData*data=[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:&error];if(data)MVKForensics::state().record(kind,(const char*)data.bytes,data.length,true);else ++MVKForensics::state().serializationFailures;}
    @catch(NSException*){++MVKForensics::state().serializationFailures;}
}
#endif
