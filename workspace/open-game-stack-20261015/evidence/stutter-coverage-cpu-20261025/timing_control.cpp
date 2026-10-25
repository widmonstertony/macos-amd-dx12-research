#define MVK_CPU_TIMING_TEST_FAILURE 1
#include "MVKCPUTimingTrace.h"
#include <fstream>
#include <stdexcept>
#include <string>
#include <iostream>
static void need(bool b,const char*s){if(!b)throw std::runtime_error(s);}
struct FakeClock {
    inline static thread_local uint64_t tick=1000,cpu=100;
    static uint64_t ticks(){return tick;}
    static uint64_t toNS(uint64_t t){return t;}
    static uint64_t threadNS(){return cpu;}
    static uint64_t unixNS(){return UINT64_C(1700000000000000000)+tick;}
    static void advance(uint64_t wall,uint64_t work){tick+=wall;cpu+=work;}
};
using Fake=MVKCPUTimingTrace<4,4,FakeClock>;
using Real=MVKCPUTimingTrace<4,4>;
static const std::array<MVKCPUStageInfo,4> stages={{{"outer",MVKCPUTimingKind::Work},{"bind\"quoted",MVKCPUTimingKind::Work},{"wait",MVKCPUTimingKind::Wait},{"queue-delay",MVKCPUTimingKind::Async}}};
static uint64_t sum(const std::array<uint64_t,65>&a){uint64_t n=0;for(auto x:a)n+=x;return n;}
static void deep(Fake&t,unsigned level){Fake::Scope s(t,0);FakeClock::advance(1,1);if(level)deep(t,level-1);FakeClock::advance(1,1);}
int main(int argc,const char**argv){try{
    need(argc==2,"output directory required");std::string dir=argv[1];uint64_t checks=0;
    Fake t(stages,5000000000ULL,15);{Fake::Scope off(t,0);FakeClock::advance(10,10);}auto disabled=t.snapshot();need(disabled->rows[0].count==0&&disabled->inFlight.empty(),"disabled trace recorded activity");++checks;
    t.setEnabled(true);Fake::Context a;a.domain=1;a.queueFamily=0;a.queueIndex=0;a.submission=17;a.nativeCB=88;a.frame=9;
    {Fake::ContextGuard outerContext(a);Fake::Scope outer(t,0,700,true);FakeClock::advance(10,10);
        {auto b=a;b.domain=2;b.queueFamily=2;b.submission=18;b.nativeCB=89;Fake::ContextGuard innerContext(b);Fake::Scope bind(t,1,701);FakeClock::advance(20,20);{Fake::Scope wait(t,2,702,true);FakeClock::advance(30,0);} }
        FakeClock::advance(40,40);
    }
    t.recordAsync(3,200,703);t.recordFailure(1,-4,704);auto deterministic=t.snapshot();auto outer=deterministic->rows[1*4],bind=deterministic->rows[2*4+1],wait=deterministic->rows[2*4+2];
    need(outer.count==1&&outer.inclusiveNS==100&&outer.selfNS==50&&outer.inclusiveThreadCPUNS==70,"nested outer attribution mismatch");++checks;
    need(bind.count==1&&bind.inclusiveNS==50&&bind.selfNS==20,"nested bind self mismatch");++checks;
    need(wait.count==1&&wait.inclusiveNS==30&&wait.selfNS==30&&wait.threadCPUCount==1&&wait.inclusiveThreadCPUNS==0,"wait wall/CPU attribution mismatch");++checks;
    need(outer.selfNS+bind.selfNS+wait.selfNS==100,"self categories double counted");++checks;
    need(deterministic->rows[3].inclusiveNS==200&&deterministic->rows[3].selfNS==0,"async interval entered self partition");++checks;
    need(deterministic->rows[1].failures==1&&deterministic->rows[1].lastFailureCode==-4,"failure record lost");++checks;
    for(const auto&m:deterministic->rows){need(sum(m.inclusiveHistogram)==m.count&&sum(m.selfHistogram)==m.count,"histogram count mismatch");++checks;}
    bool contextSeen=false;for(auto s:deterministic->slowSpans)if(s.tag==700)contextSeen=s.context.submission==17&&s.context.nativeCB==88&&s.context.queueFamily==0&&s.context.frame==9&&s.thread!=0;need(contextSeen,"slow span correlation context missing");++checks;
    FILE* f=fopen((dir+"/deterministic.jsonl").c_str(),"w");need(f,"report output failed");t.writeJSON(f,*deterministic);fclose(f);
    {Fake::Scope active(t,0,900);FakeClock::advance(12,4);auto r=t.snapshot();need(r->inFlight.size()==1&&r->inFlight[0].tag==900&&r->inFlight[0].inclusiveNS==12&&r->rows[0].count==0,"ongoing span not visible before completion");++checks;FakeClock::advance(8,4);need(active.finish()==20&&active.finish()==0,"finish not idempotent");++checks;}
    auto closed=t.snapshot();need(closed->inFlight.empty()&&closed->rows[0].count==1&&closed->rows[0].inclusiveNS==20,"cross-window span lost or doubled");++checks;
    for(unsigned i=0;i<100;++i)t.recordAsync(3,1000,1000+i);auto capped=t.snapshot();need(capped->rows[3].count==100&&capped->slowSpans.size()==32&&capped->slowSpansDropped==68,"bounded slow ring lost total accounting");++checks;
    need(Fake::bucket(0)==0&&Fake::bucket(1)==1&&Fake::bucket(2)==2&&Fake::bucket(3)==2&&Fake::bucket(UINT64_MAX)==64,"histogram bucket edge error");++checks;
    need(Fake::quantileUpper(capped->rows[3].inclusiveHistogram,99)==1023,"quantile upper bound mismatch");++checks;
    Fake detail(stages,5000000000ULL,UINT64_MAX);detail.setEnabled(true);detail.setDetailedEnabled(true);
    auto dc=a;dc.submission=100;dc.nativeCB=111;
    {Fake::ContextGuard context(dc);Fake::Scope outerDetail(detail,0);FakeClock::advance(10,10);
        {Fake::Scope inner(detail,1);FakeClock::advance(20,20);}
        auto partial=detail.snapshot();need(partial->submissions.size()==1&&partial->submissions[0].openAtReport&&partial->submissions[0].phases[1].count==1,"open submission detail missing");++checks;
        FakeClock::advance(5,5);
    }
    dc.nativeCB=112;{Fake::ContextGuard context(dc);Fake::Scope inner(detail,1);FakeClock::advance(7,7);}dc.nativeCB=113;dc.frame=10;{Fake::ContextGuard context(dc);Fake::Scope inner(detail,1);FakeClock::advance(9,9);}
    auto detailed=detail.snapshot();need(detailed->submissions.size()==1,"same logical submission split into multiple contexts");++checks;const auto&sub=detailed->submissions[0];
    need(sub.context.submission==100&&sub.mixedNativeCB&&sub.mixedFrame&&sub.firstNativeCB==111&&sub.lastNativeCB==113&&sub.phases[0].count==1&&sub.phases[0].inclusiveNS==35&&sub.phases[0].selfNS==15&&sub.phases[1].count==2&&sub.phases[1].inclusiveNS==16,"submission totals/provenance incorrect");++checks;
    need(sub.startNS<detailed->windowStartNS,"cross-window parent start not retained");++checks;
    FILE*detailFile=fopen((dir+"/detailed.jsonl").c_str(),"w");need(detailFile,"detail output failed");detail.writeJSON(detailFile,*detailed);fclose(detailFile);
    for(unsigned i=0;i<1025;++i){dc.submission=200+i;dc.nativeCB=1000+i;Fake::ContextGuard context(dc);Fake::Scope s(detail,0);FakeClock::advance(1,1);}
    auto overflow=detail.snapshot();need(overflow->submissions.size()==1024&&overflow->detailedOverflowEvents==1&&overflow->rows[1*4].count==1025,"bounded submission detail overflow not explicit");++checks;
    {Fake::Scope unknown(detail,0);FakeClock::advance(4,4);}auto unknown=detail.snapshot();need(unknown->detailedUnattributedEvents==1&&unknown->detailedUnattributedSelfNS==4,"unattributed detail gap hidden");++checks;
    detail.setDetailedEnabled(false);dc.submission=5000;{Fake::ContextGuard context(dc);Fake::Scope s(detail,0);FakeClock::advance(1,1);}need(detail.snapshot()->submissions.empty(),"detail arm remained active");++checks;
    Fake allocationFailure(stages);allocationFailure.setEnabled(true);Fake::failNextDiagnosticAllocationForTest();errno=EDOM;unsigned backendExecuted=0;{Fake::Scope s(allocationFailure,0);++backendExecuted;}need(backendExecuted==1&&errno==EDOM,"diagnostic allocation escaped or changed backend errno");++checks;{Fake::Scope suppressed(allocationFailure,0);++backendExecuted;}auto failure=allocationFailure.snapshot();need(failure->diagnosticAllocationDrops==1&&failure->diagnosticUnavailableThreads==1&&failure->diagnosticSuppressedEvents==1&&failure->rows[0].count==0,"diagnostic drop was hidden or retried unsafely");++checks;
    bool originalEscaped=false;try{Fake::Scope s(t,0);throw std::runtime_error("original backend exception");}catch(const std::runtime_error&){originalEscaped=true;}need(originalEscaped,"original backend exception was swallowed");++checks;
    errno=ERANGE;MVKCPUDefaultClock::threadNS();need(errno==ERANGE,"thread CPU clock changed errno");++checks;
    (void)t.snapshot();deep(t,70);auto depth=t.snapshot();need(depth->rows[0].count==71&&depth->rows[0].selfNS==142&&depth->depthOverflow==7&&depth->badNesting==0,"deep nested attribution mismatch");++checks;
    Fake cadence(stages);cadence.setEnabled(true);{Fake::Scope s(cadence,0);FakeClock::advance(10,10);}std::string path=dir+"/cadence.jsonl";std::remove(path.c_str());need(!cadence.writeIfDue(path.c_str()),"published before five-second boundary");++checks;
    FakeClock::advance(5000000000ULL,0);need(cadence.writeIfDue(path.c_str())&&!cadence.writeIfDue(path.c_str()),"five-second publication gate failed");++checks;
    {Fake::Scope s(cadence,1);FakeClock::advance(3,3);}FakeClock::advance(5000000000ULL,0);need(!cadence.writeIfDue((dir+"/missing/output.jsonl").c_str()),"expected publication failure absent");++checks;need(cadence.writeIfDue(path.c_str(),true),"forced retry failed");++checks;
    // Concurrent snapshots must preserve complete per-record histograms.
    Real concurrent(stages,5000000000ULL,UINT64_MAX);concurrent.setEnabled(true);std::atomic<unsigned> done{0};std::vector<std::thread> threads;constexpr unsigned Workers=4,Iterations=6000;
    for(unsigned i=0;i<Workers;++i)threads.emplace_back([&,i]{Real::Context ctx;ctx.domain=i;ctx.queueFamily=i;Real::ContextGuard guard(ctx);for(unsigned j=0;j<Iterations;++j){Real::Scope parent(concurrent,0,j);{Real::Scope child(concurrent,1,j);std::atomic_signal_fence(std::memory_order_seq_cst);}}++done;});
    uint64_t outerCount=0,childCount=0;unsigned snapshots=0;auto consume=[&]{auto r=concurrent.snapshot();++snapshots;for(size_t d=0;d<4;++d){const auto&a=r->rows[d*4],&b=r->rows[d*4+1];outerCount+=a.count;childCount+=b.count;need(sum(a.inclusiveHistogram)==a.count&&sum(b.inclusiveHistogram)==b.count,"concurrent histogram event split");++checks;}};
    while(done.load()!=Workers){consume();std::this_thread::yield();}for(auto&x:threads)x.join();consume();need(outerCount==Workers*Iterations&&childCount==Workers*Iterations,"concurrent reporting lost or doubled events");++checks;
    Real budget(stages,5000000000ULL,UINT64_MAX);budget.setEnabled(true);budget.setDetailedEnabled(true);
    for(unsigned i=0;i<100;++i){std::thread worker([&,i]{Real::Context c;c.domain=1;c.submission=1000+i;Real::ContextGuard guard(c);Real::Scope s(budget,0);});worker.join();}
    auto memory=budget.snapshot();need(memory->registeredThreads==100&&memory->rows[4].count==100&&memory->submissions.size()==Real::MaxDetailedShards&&memory->detailedThreadBudgetDropEvents==100-Real::MaxDetailedShards&&memory->detailedReservedBytes==Real::MaxDetailedShards*Real::detailedBytesPerShard(),"detailed thread memory budget hidden or exceeded");++checks;
    Real bench(stages,5000000000ULL,UINT64_MAX);constexpr unsigned OffN=1000000,OnN=200000;auto measure=[&](bool enabled,unsigned n){bench.setEnabled(enabled);auto begin=std::chrono::steady_clock::now();for(unsigned i=0;i<n;++i){Real::Scope scope(bench,0);std::atomic_signal_fence(std::memory_order_seq_cst);}return std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-begin).count()/n;};
    Real::Context benchContext;benchContext.domain=1;benchContext.submission=777;benchContext.nativeCB=888;Real::ContextGuard benchGuard(benchContext);std::vector<double>offTimes,onTimes,detailTimes;for(unsigned i=0;i<3;++i){bench.setDetailedEnabled(false);offTimes.push_back(measure(false,OffN));onTimes.push_back(measure(true,OnN));bench.setDetailedEnabled(true);detailTimes.push_back(measure(true,OnN));}std::sort(offTimes.begin(),offTimes.end());std::sort(onTimes.begin(),onTimes.end());std::sort(detailTimes.begin(),detailTimes.end());
    std::ofstream out(dir+"/result.json");out<<"{\"passed\":true,\"GPUCommandsSubmitted\":0,\"checks\":"<<checks<<",\"nestedInclusiveSelfExact\":true,\"waitWallVersusThreadCPUChecked\":true,\"asyncExcludedFromSelfPartition\":true,\"domainSubmissionNativeCBFrameContextChecked\":true,\"ongoingSpanBeforeCompletionChecked\":true,\"slowRingBoundedWithDropCount\":true,\"fiveSecondGateChecked\":true,\"failedPublicationPreservesMetrics\":true,\"boundedSubmissionDetailChecked\":true,\"mixedNativeCBAndFrameFlagsChecked\":true,\"submissionPhaseTotalsExact\":true,\"detailOverflowAndUnattributedGapsExplicit\":true,\"concurrentWorkerCount\":"<<Workers<<",\"concurrentEvents\":"<<outerCount+childCount<<",\"concurrentSnapshots\":"<<snapshots<<",\"diagnosticAllocationFailureSuppressed\":true,\"originalBackendExceptionsPreserved\":true,\"errnoPreserved\":true,\"memoryBudgetThreads\":100,\"detailedThreadBudget\":16,\"detailedBudgetDrops\":84,\"detailedBytesPerShard\":"<<Real::detailedBytesPerShard()<<",\"noConcurrentHistogramSplits\":true,\"disabledMedianNSPerEmptyScope\":"<<offTimes[1]<<",\"enabledMedianNSPerEmptyScope\":"<<onTimes[1]<<",\"enabledDetailedMedianNSPerEmptyScope\":"<<detailTimes[1]<<",\"overheadIncludesClocksAndThreadShardLocks\":true,\"mismatches\":0}\n";return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 2;}}
