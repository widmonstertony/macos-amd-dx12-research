// Opt-in CPU wall-time attribution. No Foundation, Metal calls or GPU commands.
#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>
#include <time.h>
#if defined(__APPLE__)
#include <mach/mach_time.h>
#include <pthread.h>
#endif

struct MVKCPUDefaultClock {
    static uint64_t ticks() {
#if defined(__APPLE__)
        return mach_absolute_time();
#else
        return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
#endif
    }
    static uint64_t toNS(uint64_t value) {
#if defined(__APPLE__)
        static const auto scale=[] {int priorErrno=errno;mach_timebase_info_data_t t{1,1};mach_timebase_info(&t);errno=priorErrno;return t;}();
        return static_cast<uint64_t>((static_cast<unsigned __int128>(value)*scale.numer)/scale.denom);
#else
        return value;
#endif
    }
    static uint64_t threadNS() {
        int priorErrno=errno;
#if defined(CLOCK_THREAD_CPUTIME_ID)
        timespec t{};if(!clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t)){uint64_t result=uint64_t(t.tv_sec)*1000000000+uint64_t(t.tv_nsec);errno=priorErrno;return result;}
#endif
        errno=priorErrno;return 0;
    }
    static uint64_t unixNS() {return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();}
};
enum class MVKCPUTimingKind : uint8_t { Work, Wait, Async };
struct MVKCPUStageInfo {const char* name;MVKCPUTimingKind kind=MVKCPUTimingKind::Work;};

template<size_t StageCount,size_t DomainCount=8,class Clock=MVKCPUDefaultClock>
class MVKCPUTimingTrace {
    static_assert(StageCount&&DomainCount,"nonempty timing configuration required");
public:
    using Kind=MVKCPUTimingKind;
    using StageInfo=MVKCPUStageInfo;
    static constexpr size_t HistogramBins=65, SlowCapacity=32, ActiveCapacity=64;
    static constexpr size_t DetailedCapacity=1024,DetailedSlots=2048;
    static constexpr size_t MaxDetailedShards=16;
    struct Context {
        uint32_t domain=0,queueFamily=UINT32_MAX,queueIndex=UINT32_MAX;
        uint64_t submission=0,nativeCB=0,frame=0,shader=0;
    };
    inline static thread_local Context currentContext{};
    struct ContextGuard {
        Context prior;
        explicit ContextGuard(Context next):prior(currentContext){currentContext=next;}
        ~ContextGuard(){currentContext=prior;}
        ContextGuard(const ContextGuard&)=delete;
    };
    struct Metric {
        uint64_t count=0,inclusiveNS=0,selfNS=0,maxInclusiveNS=0,maxSelfNS=0;
        uint64_t threadCPUCount=0,inclusiveThreadCPUNS=0,failures=0;
        int64_t lastFailureCode=0;
        std::array<uint64_t,HistogramBins> inclusiveHistogram{},selfHistogram{};
    };
    struct Span {
        Context context{};
        uint64_t thread=0,tag=0,startNS=0,endNS=0,inclusiveNS=0,selfNS=0,threadCPUNS=0;
        uint32_t stage=0,depth=0;
        int64_t failureCode=0;
        bool active=false,async=false;
    };
    struct DetailCell {
        uint64_t count=0,inclusiveNS=0,selfNS=0,maxInclusiveNS=0,maxSelfNS=0,failures=0;
    };
    struct SubmissionDetail {
        Context context{};
        uint64_t thread=0,startNS=0,endNS=0,firstNativeCB=0,lastNativeCB=0,firstFrame=0,lastFrame=0,armEpoch=0;
        bool mixedNativeCB=false,mixedFrame=false,mixedArm=false,beganBeforeArm=false,openAtReport=false;
        std::array<DetailCell,StageCount> phases{};
    };
    struct Report {
        uint64_t windowStartNS=0,windowEndNS=0,unixTimeNS=0,slowSpansDropped=0;
        uint64_t invalidIDs=0,badNesting=0,depthOverflow=0,publicationFailures=0;
        uint64_t detailedOverflowEvents=0,detailedUnattributedEvents=0,detailedUnattributedSelfNS=0;
        uint64_t detailedColdAllocations=0,detailedColdAllocationNS=0,detailedUnpreparedEvents=0;
        uint64_t diagnosticAllocationDrops=0,diagnosticSuppressedEvents=0,diagnosticUnavailableThreads=0;
        uint64_t detailedThreadBudgetDropEvents=0,registeredThreads=0,aggregateReservedBytes=0,detailedReservedBytes=0,threadShardReservedBytes=0;
        uint64_t detailedArmEpoch=0,detailedArmStartNS=0;
        bool detailedEnabled=false,captureEnabled=false;
        std::array<Metric,StageCount*DomainCount> rows{};
        std::vector<Span> slowSpans,inFlight;
        std::vector<SubmissionDetail> submissions;
    };
private:
    struct Block {std::array<Metric,StageCount> stages{};};
    struct DetailTable {
        std::array<uint16_t,DetailedSlots> slots{};
        std::array<SubmissionDetail,DetailedCapacity> entries{};
        size_t count=0;
        void clear(){slots.fill(0);count=0;}
    };
    struct Shard {
        std::mutex lock;
        uint64_t thread=0,slowCount=0;
        std::array<std::unique_ptr<Block>,DomainCount> domains{};
        std::array<Span,SlowCapacity> slow{};
        std::array<Span,ActiveCapacity> active{};
        std::unique_ptr<DetailTable> detailed;
        uint64_t detailedOverflowEvents=0,detailedUnattributedEvents=0,detailedUnattributedSelfNS=0;
        uint64_t detailedColdAllocations=0,detailedColdAllocationNS=0,detailedUnpreparedEvents=0;
        uint64_t detailedThreadBudgetDropEvents=0;
        bool detailedBudgetRejected=false;
    };
    struct Registration {uint64_t uid=0;Shard* shard=nullptr;std::array<Block*,DomainCount> domains{};};
    std::array<StageInfo,StageCount> _info;
    std::atomic<bool> _enabled{false};
    std::atomic<bool> _detailedEnabled{false};
    std::atomic<uint64_t> _detailArmStartNS{0},_detailArmEpoch{0};
    uint64_t _uid,_intervalNS,_slowNS,_windowStartNS;
    std::atomic<uint64_t> _nextReportNS;
    std::atomic<uint64_t> _invalidIDs{0},_badNesting{0},_depthOverflow{0},_publicationFailures{0};
    std::atomic<uint64_t> _diagnosticAllocationDrops{0},_diagnosticSuppressedEvents{0},_diagnosticUnavailableThreads{0};
    std::atomic<uint64_t> _aggregateBlockCount{0},_detailedShardCount{0};
    std::mutex _registryLock,_publishLock;
    std::vector<std::unique_ptr<Shard>> _shards;
    std::unique_ptr<Report> _pending;
    inline static std::atomic<uint64_t> nextUID{1};
    inline static thread_local std::vector<Registration> registrations{};
    inline static thread_local uint64_t unavailableUID=0;
#if defined(MVK_CPU_TIMING_TEST_FAILURE)
    inline static std::atomic<int> allocationFailureCountdown{-1};
#endif
    static void beforeAllocation(){
#if defined(MVK_CPU_TIMING_TEST_FAILURE)
        int value=allocationFailureCountdown.load();if(value>=0&&allocationFailureCountdown.fetch_sub(1)==0)throw std::bad_alloc();
#endif
    }
    void disableCurrentThread(){if(unavailableUID!=_uid){unavailableUID=_uid;++_diagnosticUnavailableThreads;}++_diagnosticAllocationDrops;}

    static bool sameSubmission(const Context&a,const Context&b){return a.domain==b.domain&&a.queueFamily==b.queueFamily&&a.queueIndex==b.queueIndex&&a.submission==b.submission;}
    static size_t detailHash(const Context&context){uint64_t h=context.submission^(uint64_t(context.domain)<<48)^(uint64_t(context.queueFamily)<<16)^context.queueIndex;h^=h>>30;h*=UINT64_C(0xbf58476d1ce4e5b9);h^=h>>27;h*=UINT64_C(0x94d049bb133111eb);return size_t(h^(h>>31));}
    SubmissionDetail* findDetail(DetailTable&table,const Context&context,bool create){
        size_t slot=detailHash(context)&(DetailedSlots-1);
        while(table.slots[slot]){auto&entry=table.entries[table.slots[slot]-1];if(sameSubmission(entry.context,context))return &entry;slot=(slot+1)&(DetailedSlots-1);}
        if(!create||table.count==DetailedCapacity)return nullptr;
        size_t index=table.count++;auto&entry=table.entries[index];entry=SubmissionDetail{};entry.context=context;table.slots[slot]=uint16_t(index+1);return &entry;
    }
    void prepareDetail(Shard&shard,const Context&context){
        if(!_detailedEnabled.load(std::memory_order_relaxed)||!context.submission)return;
        // Only the owning event thread creates this once; reporting never
        // replaces/frees it, so steady-state events avoid an extra shard lock.
        if(shard.detailed||shard.detailedBudgetRejected)return;
        std::lock_guard<std::mutex> guard(shard.lock);
        if(!shard.detailed){if(_detailedShardCount.fetch_add(1)>=MaxDetailedShards){_detailedShardCount.fetch_sub(1);shard.detailedBudgetRejected=true;return;}uint64_t begin=Clock::ticks();try{beforeAllocation();shard.detailed.reset(new DetailTable);}catch(...){_detailedShardCount.fetch_sub(1);throw;}shard.detailedColdAllocationNS+=Clock::toNS(Clock::ticks()-begin);++shard.detailedColdAllocations;}
    }
    void recordDetail(Shard&shard,const Span&span,bool failure=false){
        if(!_detailedEnabled.load(std::memory_order_relaxed))return;
        if(!span.context.submission){++shard.detailedUnattributedEvents;shard.detailedUnattributedSelfNS+=span.selfNS;return;}
        if(!shard.detailed){if(shard.detailedBudgetRejected)++shard.detailedThreadBudgetDropEvents;else ++shard.detailedUnpreparedEvents;return;}
        auto*entry=findDetail(*shard.detailed,span.context,true);if(!entry){++shard.detailedOverflowEvents;return;}
        uint64_t armEpoch=_detailArmEpoch.load(std::memory_order_relaxed);
        if(!entry->thread){entry->thread=shard.thread;entry->startNS=span.startNS;entry->armEpoch=armEpoch;}
        entry->startNS=std::min(entry->startNS,span.startNS);entry->endNS=std::max(entry->endNS,span.endNS);
        entry->beganBeforeArm|=span.startNS<_detailArmStartNS.load(std::memory_order_relaxed);entry->mixedArm|=entry->armEpoch!=armEpoch;
        if(span.context.nativeCB){if(!entry->firstNativeCB)entry->firstNativeCB=span.context.nativeCB;else entry->mixedNativeCB|=entry->firstNativeCB!=span.context.nativeCB;entry->lastNativeCB=span.context.nativeCB;}
        if(span.context.frame){if(!entry->firstFrame)entry->firstFrame=span.context.frame;else entry->mixedFrame|=entry->firstFrame!=span.context.frame;entry->lastFrame=span.context.frame;}
        auto&phase=entry->phases[span.stage];if(failure){++phase.failures;return;}++phase.count;phase.inclusiveNS+=span.inclusiveNS;phase.selfNS+=span.selfNS;phase.maxInclusiveNS=std::max(phase.maxInclusiveNS,span.inclusiveNS);phase.maxSelfNS=std::max(phase.maxSelfNS,span.selfNS);
    }

    static uint64_t threadIdentity(){
#if defined(__APPLE__)
        int priorErrno=errno;uint64_t value=0;int result=pthread_threadid_np(nullptr,&value);errno=priorErrno;if(!result)return value;
#endif
        return std::hash<std::thread::id>{}(std::this_thread::get_id());
    }

    std::pair<Shard*,Block*> local(uint32_t domain) {
        for(auto& r:registrations)if(r.uid==_uid){
            if(!r.domains[domain]){std::lock_guard<std::mutex> g(r.shard->lock);beforeAllocation();r.shard->domains[domain].reset(new Block);++_aggregateBlockCount;r.domains[domain]=r.shard->domains[domain].get();}
            return {r.shard,r.domains[domain]};
        }
        beforeAllocation();registrations.reserve(registrations.size()+1);
        beforeAllocation();auto shard=std::make_unique<Shard>();Shard* p=shard.get();
        beforeAllocation();shard->domains[domain].reset(new Block);Block* b=shard->domains[domain].get();
        {std::lock_guard<std::mutex> g(_registryLock);beforeAllocation();_shards.reserve(_shards.size()+1);p->thread=threadIdentity();_shards.push_back(std::move(shard));++_aggregateBlockCount;}
        Registration r;r.uid=_uid;r.shard=p;r.domains[domain]=b;registrations.push_back(r);return {p,b};
    }
    uint32_t checkedDomain(uint32_t domain){if(domain<DomainCount)return domain;++_invalidIDs;return 0;}
    static void add(Metric&to,const Metric&from){
        to.count+=from.count;to.inclusiveNS+=from.inclusiveNS;to.selfNS+=from.selfNS;
        to.maxInclusiveNS=std::max(to.maxInclusiveNS,from.maxInclusiveNS);to.maxSelfNS=std::max(to.maxSelfNS,from.maxSelfNS);
        to.threadCPUCount+=from.threadCPUCount;to.inclusiveThreadCPUNS+=from.inclusiveThreadCPUNS;to.failures+=from.failures;
        if(from.failures)to.lastFailureCode=from.lastFailureCode;
        for(size_t i=0;i<HistogramBins;++i){to.inclusiveHistogram[i]+=from.inclusiveHistogram[i];to.selfHistogram[i]+=from.selfHistogram[i];}
    }
    static void update(Metric&m,uint64_t inclusive,uint64_t self,uint64_t cpu,bool hasCPU){
        ++m.count;m.inclusiveNS+=inclusive;m.selfNS+=self;m.maxInclusiveNS=std::max(m.maxInclusiveNS,inclusive);m.maxSelfNS=std::max(m.maxSelfNS,self);
        ++m.inclusiveHistogram[bucket(inclusive)];++m.selfHistogram[bucket(self)];
        if(hasCPU){++m.threadCPUCount;m.inclusiveThreadCPUNS+=cpu;}
    }
    void remember(Shard&shard,const Span&span){shard.slow[shard.slowCount%SlowCapacity]=span;++shard.slowCount;}
    std::unique_ptr<Report> snapshotLocked(uint64_t now) {
        auto out=std::make_unique<Report>();out->windowStartNS=_windowStartNS;out->windowEndNS=now;out->unixTimeNS=Clock::unixNS();_windowStartNS=now;out->captureEnabled=enabled();out->detailedEnabled=_detailedEnabled.load(std::memory_order_relaxed);out->detailedArmEpoch=_detailArmEpoch.load(std::memory_order_relaxed);out->detailedArmStartNS=_detailArmStartNS.load(std::memory_order_relaxed);
        std::vector<Shard*> shards;{std::lock_guard<std::mutex> g(_registryLock);for(auto&x:_shards)shards.push_back(x.get());}out->registeredThreads=shards.size();out->aggregateReservedBytes=_aggregateBlockCount.load()*sizeof(Block);out->detailedReservedBytes=_detailedShardCount.load()*sizeof(DetailTable);out->threadShardReservedBytes=shards.size()*sizeof(Shard);
        for(Shard*shard:shards){std::lock_guard<std::mutex> g(shard->lock);
            for(size_t domain=0;domain<DomainCount;++domain)if(shard->domains[domain])for(size_t stage=0;stage<StageCount;++stage){auto&m=shard->domains[domain]->stages[stage];add(out->rows[domain*StageCount+stage],m);m=Metric{};}
            uint64_t first=shard->slowCount>SlowCapacity?shard->slowCount-SlowCapacity:0;out->slowSpansDropped+=first;
            for(uint64_t i=first;i<shard->slowCount;++i)out->slowSpans.push_back(shard->slow[i%SlowCapacity]);shard->slowCount=0;
            for(auto active:shard->active)if(active.active){active.endNS=now;active.inclusiveNS=now>=active.startNS?now-active.startNS:0;out->inFlight.push_back(active);}
            if(shard->detailed){for(const auto&active:shard->active)if(active.active&&active.context.submission)if(auto*entry=findDetail(*shard->detailed,active.context,false))entry->openAtReport=true;for(size_t i=0;i<shard->detailed->count;++i)out->submissions.push_back(shard->detailed->entries[i]);shard->detailed->clear();}
            out->detailedOverflowEvents+=shard->detailedOverflowEvents;shard->detailedOverflowEvents=0;
            out->detailedUnattributedEvents+=shard->detailedUnattributedEvents;shard->detailedUnattributedEvents=0;
            out->detailedUnattributedSelfNS+=shard->detailedUnattributedSelfNS;shard->detailedUnattributedSelfNS=0;
            out->detailedColdAllocations+=shard->detailedColdAllocations;shard->detailedColdAllocations=0;
            out->detailedColdAllocationNS+=shard->detailedColdAllocationNS;shard->detailedColdAllocationNS=0;
            out->detailedUnpreparedEvents+=shard->detailedUnpreparedEvents;shard->detailedUnpreparedEvents=0;
            out->detailedThreadBudgetDropEvents+=shard->detailedThreadBudgetDropEvents;shard->detailedThreadBudgetDropEvents=0;
        }
        out->invalidIDs=_invalidIDs.exchange(0);out->badNesting=_badNesting.exchange(0);out->depthOverflow=_depthOverflow.exchange(0);out->publicationFailures=_publicationFailures.exchange(0);out->diagnosticAllocationDrops=_diagnosticAllocationDrops.exchange(0);out->diagnosticSuppressedEvents=_diagnosticSuppressedEvents.exchange(0);out->diagnosticUnavailableThreads=_diagnosticUnavailableThreads.load();return out;
    }
    static void printString(FILE*f,const char*s){fputc('"',f);for(const unsigned char*p=reinterpret_cast<const unsigned char*>(s?s:"");*p;++p){if(*p=='"'||*p=='\\'){fputc('\\',f);fputc(*p,f);}else if(*p<32)fprintf(f,"\\u%04x",*p);else fputc(*p,f);}fputc('"',f);}
    static void printSpan(FILE*f,const Span&s){
        fprintf(f,"{\"domain\":%u,\"stage\":%u,\"thread\":%llu,\"queueFamily\":%u,\"queueIndex\":%u,\"submission\":%llu,\"nativeCB\":%llu,\"frame\":%llu,\"tag\":%llu,\"startNS\":%llu,\"endNS\":%llu,\"inclusiveNS\":%llu,\"selfNS\":%llu,\"threadCPUNS\":%llu,\"depth\":%u,\"failureCode\":%lld,\"active\":%s,\"async\":%s}",s.context.domain,s.stage,(unsigned long long)s.thread,s.context.queueFamily,s.context.queueIndex,(unsigned long long)s.context.submission,(unsigned long long)s.context.nativeCB,(unsigned long long)s.context.frame,(unsigned long long)s.tag,(unsigned long long)s.startNS,(unsigned long long)s.endNS,(unsigned long long)s.inclusiveNS,(unsigned long long)s.selfNS,(unsigned long long)s.threadCPUNS,s.depth,(long long)s.failureCode,s.active?"true":"false",s.async?"true":"false");
    }
public:
    explicit MVKCPUTimingTrace(std::array<StageInfo,StageCount> info,uint64_t intervalNS=5000000000ULL,uint64_t slowNS=5000000ULL):
        _info(info),_uid(nextUID.fetch_add(1)),_intervalNS(intervalNS),_slowNS(slowNS),_windowStartNS(Clock::toNS(Clock::ticks())),_nextReportNS(_windowStartNS+intervalNS){}
    MVKCPUTimingTrace(const MVKCPUTimingTrace&)=delete;
    void setEnabled(bool enabled){_enabled.store(enabled,std::memory_order_relaxed);}
    bool enabled()const{return _enabled.load(std::memory_order_relaxed);}
    void setDetailedEnabled(bool enabled){if(enabled&&!_detailedEnabled.load(std::memory_order_relaxed)){_detailArmStartNS.store(Clock::toNS(Clock::ticks()),std::memory_order_relaxed);_detailArmEpoch.fetch_add(1,std::memory_order_relaxed);}_detailedEnabled.store(enabled,std::memory_order_relaxed);}
    bool detailedEnabled()const{return _detailedEnabled.load(std::memory_order_relaxed);}
    static size_t detailedBytesPerShard(){return sizeof(DetailTable);}
    static size_t aggregateBytesPerDomain(){return sizeof(Block);}
    void recordPublicationFailure(){_publicationFailures.fetch_add(1,std::memory_order_relaxed);}
    void markDiagnosticUnavailable(){disableCurrentThread();}
#if defined(MVK_CPU_TIMING_TEST_FAILURE)
    static void failNextDiagnosticAllocationForTest(){allocationFailureCountdown.store(0);}
#endif
    static unsigned bucket(uint64_t ns){return ns?64u-unsigned(__builtin_clzll(ns)):0u;}
    static uint64_t bucketUpper(unsigned b){return b==0?0:(b>=64?UINT64_MAX:(uint64_t(1)<<b)-1);}
    static uint64_t quantileUpper(const std::array<uint64_t,HistogramBins>&hist,unsigned numerator,unsigned denominator=100){
        uint64_t count=0;for(auto n:hist)count+=n;if(!count||!denominator)return 0;uint64_t target=(count*numerator+denominator-1)/denominator,seen=0;
        for(unsigned i=0;i<HistogramBins;++i){seen+=hist[i];if(seen>=target)return bucketUpper(i);}return UINT64_MAX;
    }
    class Scope {
        MVKCPUTimingTrace*_trace=nullptr;Shard*_shard=nullptr;Block*_block=nullptr;Scope*_parent=nullptr;
        uint64_t _start=0,_child=0,_cpuStart=0,_tag=0;
        uint32_t _stage=0,_depth=0;
        Context _context{};
        bool _captureCPU=false;
        inline static thread_local Scope*top=nullptr;
    public:
        Scope(MVKCPUTimingTrace&trace,size_t stage,uint64_t tag=0,bool captureThreadCPU=false) noexcept {
            if(!trace.enabled())return;
            if(unavailableUID==trace._uid){++trace._diagnosticSuppressedEvents;return;}
            int priorErrno=errno;
            try {
            if(stage>=StageCount||trace._info[stage].kind==Kind::Async){++trace._invalidIDs;return;}
            _trace=&trace;_stage=uint32_t(stage);_tag=tag ? tag : currentContext.shader;_captureCPU=captureThreadCPU;_context=currentContext;_context.domain=trace.checkedDomain(_context.domain);
            auto local=trace.local(_context.domain);_shard=local.first;_block=local.second;_parent=top;_depth=_parent?_parent->_depth+1:0;top=this;
            trace.prepareDetail(*_shard,_context);
            if(_captureCPU)_cpuStart=Clock::threadNS();_start=Clock::ticks();
            std::lock_guard<std::mutex> g(_shard->lock);
            if(_depth<ActiveCapacity){auto&s=_shard->active[_depth];s={};s.context=_context;s.thread=_shard->thread;s.tag=_tag;s.stage=_stage;s.depth=_depth;s.startNS=Clock::toNS(_start);s.active=true;}
            else ++trace._depthOverflow;
            }catch(...){if(top==this)top=_parent;_trace=nullptr;trace.disableCurrentThread();}
            errno=priorErrno;
        }
        Scope(const Scope&)=delete;
        Scope&operator=(const Scope&)=delete;
        ~Scope(){finish();}
        uint64_t finish() noexcept {
            if(!_trace)return 0;auto*trace=_trace;uint64_t end=Clock::ticks(),elapsed=end>=_start?end-_start:0;uint64_t cpuEnd=_captureCPU?Clock::threadNS():0;
            int priorErrno=errno;
            if(top!=this)++trace->_badNesting;top=_parent;
            if(_parent)_parent->_child+=elapsed;
            if(_child>elapsed)++trace->_badNesting;
            uint64_t inclusive=Clock::toNS(elapsed),self=Clock::toNS(elapsed>=_child?elapsed-_child:0),cpu=cpuEnd>=_cpuStart?cpuEnd-_cpuStart:0;
            try{std::lock_guard<std::mutex> g(_shard->lock);if(unavailableUID!=trace->_uid)update(_block->stages[_stage],inclusive,self,cpu,_captureCPU&&_cpuStart&&cpuEnd);else ++trace->_diagnosticSuppressedEvents;
                if(_depth<ActiveCapacity)_shard->active[_depth].active=false;
                if(unavailableUID!=trace->_uid){Span s;s.context=_context;s.thread=_shard->thread;s.tag=_tag;s.stage=_stage;s.depth=_depth;s.startNS=Clock::toNS(_start);s.endNS=Clock::toNS(end);s.inclusiveNS=inclusive;s.selfNS=self;s.threadCPUNS=cpu;trace->recordDetail(*_shard,s);if(inclusive>=trace->_slowNS)trace->remember(*_shard,s);}}
            catch(...){trace->disableCurrentThread();}
            _trace=nullptr;errno=priorErrno;return inclusive;
        }
    };
    void recordAsync(size_t stage,uint64_t elapsedNS,uint64_t tag=0) noexcept {
        if(!enabled())return;if(stage>=StageCount||_info[stage].kind!=Kind::Async){++_invalidIDs;return;}
        if(unavailableUID==_uid){++_diagnosticSuppressedEvents;return;}int priorErrno=errno;try{
        Context context=currentContext;context.domain=checkedDomain(context.domain);auto localPair=local(context.domain);auto*shard=localPair.first;prepareDetail(*shard,context);uint64_t end=Clock::toNS(Clock::ticks());
        std::lock_guard<std::mutex> g(shard->lock);update(localPair.second->stages[stage],elapsedNS,0,0,false);
        Span s;s.context=context;s.thread=shard->thread;s.tag=tag;s.stage=stage;s.startNS=end>=elapsedNS?end-elapsedNS:0;s.endNS=end;s.inclusiveNS=elapsedNS;s.async=true;recordDetail(*shard,s);if(elapsedNS>=_slowNS)remember(*shard,s);
        }catch(...){disableCurrentThread();}errno=priorErrno;
    }
    void recordFailure(size_t stage,int64_t code,uint64_t tag=0) noexcept {
        if(!enabled())return;if(stage>=StageCount){++_invalidIDs;return;}if(unavailableUID==_uid){++_diagnosticSuppressedEvents;return;}int priorErrno=errno;try{Context context=currentContext;context.domain=checkedDomain(context.domain);auto localPair=local(context.domain);auto*shard=localPair.first;prepareDetail(*shard,context);
        std::lock_guard<std::mutex> g(shard->lock);auto&m=localPair.second->stages[stage];++m.failures;m.lastFailureCode=code;Span s;s.context=context;s.thread=shard->thread;s.tag=tag;s.stage=stage;s.startNS=s.endNS=Clock::toNS(Clock::ticks());s.failureCode=code;recordDetail(*shard,s,true);remember(*shard,s);
        }catch(...){disableCurrentThread();}errno=priorErrno;
    }
    std::unique_ptr<Report> snapshot(){std::lock_guard<std::mutex> g(_publishLock);return snapshotLocked(Clock::toNS(Clock::ticks()));}
    void writeJSON(FILE*f,const Report&r)const{
        fprintf(f,"{\"schema\":1,\"captureEnabled\":%s,\"time\":%.9f,\"unixTimeNS\":%llu,\"windowStartNS\":%llu,\"windowEndNS\":%llu,\"windowAssignment\":\"span completion\",\"selfMeaning\":\"same-thread measured-child subtraction; async self is zero; not process CPU utilization\",\"diagnosticOverheadNotSubtracted\":true,\"rows\":[",r.captureEnabled?"true":"false",double(r.unixTimeNS)/1e9-978307200.0,(unsigned long long)r.unixTimeNS,(unsigned long long)r.windowStartNS,(unsigned long long)r.windowEndNS);
        bool comma=false;for(size_t domain=0;domain<DomainCount;++domain)for(size_t stage=0;stage<StageCount;++stage){const auto&m=r.rows[domain*StageCount+stage];if(!m.count&&!m.failures)continue;if(comma)fputc(',',f);comma=true;fprintf(f,"{\"domain\":%zu,\"stage\":%zu,\"name\":",domain,stage);printString(f,_info[stage].name);fprintf(f,",\"kind\":\"%s\",\"count\":%llu,\"inclusiveWallNS\":%llu,\"selfWallNS\":%llu,\"maxInclusiveNS\":%llu,\"maxSelfNS\":%llu,\"threadCPUCount\":%llu,\"inclusiveThreadCPUNS\":%llu,\"failures\":%llu,\"lastFailureCode\":%lld,\"p50UpperNS\":%llu,\"p95UpperNS\":%llu,\"p99UpperNS\":%llu,\"inclusiveHistogram\":[",_info[stage].kind==Kind::Work?"work":(_info[stage].kind==Kind::Wait?"wait":"async"),(unsigned long long)m.count,(unsigned long long)m.inclusiveNS,(unsigned long long)m.selfNS,(unsigned long long)m.maxInclusiveNS,(unsigned long long)m.maxSelfNS,(unsigned long long)m.threadCPUCount,(unsigned long long)m.inclusiveThreadCPUNS,(unsigned long long)m.failures,(long long)m.lastFailureCode,(unsigned long long)quantileUpper(m.inclusiveHistogram,50),(unsigned long long)quantileUpper(m.inclusiveHistogram,95),(unsigned long long)quantileUpper(m.inclusiveHistogram,99));
            for(size_t i=0;i<HistogramBins;++i)fprintf(f,"%s%llu",i?",":"",(unsigned long long)m.inclusiveHistogram[i]);fputs("],\"selfHistogram\":[",f);for(size_t i=0;i<HistogramBins;++i)fprintf(f,"%s%llu",i?",":"",(unsigned long long)m.selfHistogram[i]);fputs("]}",f);}
        fprintf(f,"],\"slowSpansDropped\":%llu,\"invalidIDs\":%llu,\"badNesting\":%llu,\"depthOverflow\":%llu,\"publicationFailures\":%llu,\"slowSpans\":[",(unsigned long long)r.slowSpansDropped,(unsigned long long)r.invalidIDs,(unsigned long long)r.badNesting,(unsigned long long)r.depthOverflow,(unsigned long long)r.publicationFailures);for(size_t i=0;i<r.slowSpans.size();++i){if(i)fputc(',',f);printSpan(f,r.slowSpans[i]);}fputs("],\"inFlight\":[",f);for(size_t i=0;i<r.inFlight.size();++i){if(i)fputc(',',f);printSpan(f,r.inFlight[i]);}
        bool aggregateIncomplete=r.diagnosticUnavailableThreads||r.invalidIDs||r.badNesting||r.depthOverflow;
        bool detailIncomplete=aggregateIncomplete||r.detailedOverflowEvents||r.detailedUnattributedEvents||r.detailedUnpreparedEvents||r.detailedThreadBudgetDropEvents;
        fprintf(f,"],\"aggregateCoverageIncomplete\":%s,\"detailedCoverageIncomplete\":%s,\"diagnosticAllocationDrops\":%llu,\"diagnosticSuppressedEvents\":%llu,\"diagnosticUnavailableThreads\":%llu,\"registeredThreads\":%llu,\"aggregateReservedBytes\":%llu,\"threadShardReservedBytes\":%llu,\"detailedReservedBytes\":%llu,\"detailReportCopyBytes\":%llu,\"maxDetailedShards\":%zu,\"detailedThreadBudgetDropEvents\":%llu,\"detailedEnabled\":%s,\"detailedArmEpoch\":%llu,\"detailedArmStartNS\":%llu,\"detailedCapacityPerThread\":%zu,\"detailedOverflowEvents\":%llu,\"detailedUnattributedEvents\":%llu,\"detailedUnattributedSelfNS\":%llu,\"detailedColdAllocations\":%llu,\"detailedColdAllocationNS\":%llu,\"detailedUnpreparedEvents\":%llu,\"submissions\":[",aggregateIncomplete?"true":"false",detailIncomplete?"true":"false",(unsigned long long)r.diagnosticAllocationDrops,(unsigned long long)r.diagnosticSuppressedEvents,(unsigned long long)r.diagnosticUnavailableThreads,(unsigned long long)r.registeredThreads,(unsigned long long)r.aggregateReservedBytes,(unsigned long long)r.threadShardReservedBytes,(unsigned long long)r.detailedReservedBytes,(unsigned long long)(r.submissions.capacity()*sizeof(SubmissionDetail)),MaxDetailedShards,(unsigned long long)r.detailedThreadBudgetDropEvents,r.detailedEnabled?"true":"false",(unsigned long long)r.detailedArmEpoch,(unsigned long long)r.detailedArmStartNS,DetailedCapacity,(unsigned long long)r.detailedOverflowEvents,(unsigned long long)r.detailedUnattributedEvents,(unsigned long long)r.detailedUnattributedSelfNS,(unsigned long long)r.detailedColdAllocations,(unsigned long long)r.detailedColdAllocationNS,(unsigned long long)r.detailedUnpreparedEvents);
        for(size_t i=0;i<r.submissions.size();++i){if(i)fputc(',',f);const auto&d=r.submissions[i];fprintf(f,"{\"domain\":%u,\"queueFamily\":%u,\"queueIndex\":%u,\"submission\":%llu,\"thread\":%llu,\"startNS\":%llu,\"endNS\":%llu,\"firstNativeCB\":%llu,\"lastNativeCB\":%llu,\"mixedNativeCB\":%s,\"firstFrame\":%llu,\"lastFrame\":%llu,\"mixedFrame\":%s,\"armEpoch\":%llu,\"mixedArm\":%s,\"beganBeforeArm\":%s,\"beganBeforeWindow\":%s,\"openAtReport\":%s,\"phases\":[",d.context.domain,d.context.queueFamily,d.context.queueIndex,(unsigned long long)d.context.submission,(unsigned long long)d.thread,(unsigned long long)d.startNS,(unsigned long long)d.endNS,(unsigned long long)d.firstNativeCB,(unsigned long long)d.lastNativeCB,d.mixedNativeCB?"true":"false",(unsigned long long)d.firstFrame,(unsigned long long)d.lastFrame,d.mixedFrame?"true":"false",(unsigned long long)d.armEpoch,d.mixedArm?"true":"false",d.beganBeforeArm?"true":"false",d.startNS<r.windowStartNS?"true":"false",d.openAtReport?"true":"false");bool phaseComma=false;for(size_t phase=0;phase<StageCount;++phase){const auto&c=d.phases[phase];if(!c.count&&!c.failures)continue;if(phaseComma)fputc(',',f);phaseComma=true;fprintf(f,"{\"stage\":%zu,\"count\":%llu,\"inclusiveWallNS\":%llu,\"selfWallNS\":%llu,\"maxInclusiveNS\":%llu,\"maxSelfNS\":%llu,\"failures\":%llu}",phase,(unsigned long long)c.count,(unsigned long long)c.inclusiveNS,(unsigned long long)c.selfNS,(unsigned long long)c.maxInclusiveNS,(unsigned long long)c.maxSelfNS,(unsigned long long)c.failures);}fputs("]}",f);}fputs("]}\n",f);
    }
    bool writeIfDue(const char*path,bool force=false){
        if(!force&&!enabled())return false;
        uint64_t now=Clock::toNS(Clock::ticks());if(!force&&now<_nextReportNS.load(std::memory_order_relaxed))return false;
        std::unique_lock<std::mutex> g(_publishLock,std::try_to_lock);if(!g.owns_lock())return false;
        if(!force&&now<_nextReportNS.load(std::memory_order_relaxed))return false;_nextReportNS.store(now+_intervalNS,std::memory_order_relaxed);
        FILE*f=fopen(path,"a");if(!f){++_publicationFailures;return false;}
        if(!_pending)_pending=snapshotLocked(now);
        // A new line also separates an earlier partial write from a retry.
        fputc('\n',f);writeJSON(f,*_pending);bool ok=!ferror(f)&&fflush(f)==0;int closed=fclose(f);ok=ok&&closed==0;
        if(ok)_pending.reset();else ++_publicationFailures;
        return ok;
    }
};
