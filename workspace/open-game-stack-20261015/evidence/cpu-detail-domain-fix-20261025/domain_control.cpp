#define MVK_CPU_TIMING_TEST_FAILURE 1
#include "../../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKStutterCoverage.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
struct Clock {
 inline static std::atomic<uint64_t> tick{1000};
 static uint64_t ticks(){return tick.load();} static uint64_t toNS(uint64_t n){return n;}
 static uint64_t unixNS(){return UINT64_C(1700000000000000000)+ticks();}
 static uint64_t threadNS(){return ticks();} static void advance(uint64_t n){tick+=n;}
};
using Sim=MVKCPUTimingTrace<3,8,Clock>;using Real=MVKCPUTimingTrace<3,8>;
static const std::array<MVKCPUStageInfo,3> Info={{{"CallbackCompletion",MVKCPUTimingKind::Work},{"HostEncode",MVKCPUTimingKind::Work},{"ResourceReplay",MVKCPUTimingKind::Work}}};
static unsigned checks=0;
static void need(bool ok,const char*why){++checks;if(!ok)throw std::runtime_error(why);}
template<class T> static void arm(T&trace){trace.setEnabled(true);trace.setDetailedEnabled(true);}
template<class T> static void save(T&t,const typename T::Report&r,const std::string&p){FILE*f=fopen(p.c_str(),"w");need(f,"output failed");t.writeJSON(f,r);fclose(f);}
static Sim::Context context(unsigned domain,uint64_t submission,unsigned index=0){Sim::Context c;c.domain=domain;c.queueFamily=domain==7?0:domain-1;c.queueIndex=index;c.submission=submission;c.nativeCB=submission+100;c.frame=1;return c;}
int main(int argc,char**argv){try{
 need(argc==2,"output required");std::string out=argv[1];Sim t(Info,5000000000ULL,1);arm(t);
 for(unsigned i=0;i<16;++i){std::thread callback([&,i]{Sim::ContextGuard g(context(7,100+i));Sim::Scope scope(t,0);Clock::advance(100);});callback.join();}
 auto callbacks=t.snapshot();need(callbacks->submissions.size()==16,"callback detail lost");
 std::thread queue([&]{Sim::ContextGuard g(context(1,9000));Sim::Scope encode(t,1);Clock::advance(10);{Sim::Scope replay(t,2);Clock::advance(30);}Clock::advance(60);});queue.join();
 auto admitted=t.snapshot();save(t,*admitted,out+"/queue-after-callbacks.json");need(admitted->submissions.size()==1&&admitted->detailedThreadBudgetDropEvents==0,"new queue denied after callback workers");
 auto sub=admitted->submissions[0];need(sub.context.domain==1&&sub.context.submission==9000&&sub.phases[1].inclusiveNS==100&&sub.phases[1].selfNS==70&&sub.phases[2].selfNS==30,"queue phase attribution incorrect");
 need(admitted->rows[1*3+1].inclusiveNS==100&&admitted->rows[1*3+1].selfNS==70,"thread aggregate changed");
 t.setDetailedEnabled(false);t.setDetailedEnabled(true);
 for(unsigned i=0;i<64;++i){std::thread moved([&,i]{Sim::ContextGuard g(context(1,10000+i));Sim::Scope scope(t,1);Clock::advance(1);});moved.join();}
 auto rotation=t.snapshot();need(rotation->submissions.size()==64&&rotation->detailedThreadBudgetDropEvents==0,"queue thread rotation/rearm lost details");
 for(unsigned i=0;i<2;++i){std::thread moved([&,i]{auto c=context(1,12345);c.nativeCB=111+i;c.frame=20+i;Sim::ContextGuard g(c);Sim::Scope scope(t,1);Clock::advance(10);});moved.join();}
 auto mixed=t.snapshot();save(t,*mixed,out+"/mixed-thread-submission.json");need(mixed->submissions.size()==1,"same logical submission split by OS thread");sub=mixed->submissions[0];need(sub.mixedThread&&sub.thread!=sub.lastThread&&sub.mixedNativeCB&&sub.mixedFrame&&sub.phases[1].count==2&&sub.phases[1].selfNS==20,"mixed-thread/native/frame provenance or totals lost");
 for(unsigned i=0;i<2;++i){Sim::ContextGuard g(context(1,777,i));Sim::Scope scope(t,1);Clock::advance(10);}
 auto queues=t.snapshot();need(queues->submissions.size()==2&&queues->submissions[0].context.queueIndex!=queues->submissions[1].context.queueIndex,"same-domain queue indices merged");
 {Sim::ContextGuard g(context(1,888));Sim::Scope scope(t,1);Clock::advance(10);auto open=t.snapshot();need(open->inFlight.size()==1&&open->submissions.size()==1&&open->submissions[0].openAtReport&&open->submissions[0].phases[1].count==0,"inflight detail missing or counted as completed");Clock::advance(10);}
 auto closed=t.snapshot();need(closed->submissions.size()==1&&closed->submissions[0].phases[1].count==1&&closed->submissions[0].phases[1].selfNS==20,"report boundary double count/loss");
 t.setDetailedEnabled(false);{Sim::ContextGuard g(context(3,999));Sim::Scope scope(t,1);Clock::advance(10);t.setDetailedEnabled(true);Clock::advance(10);}auto armedLate=t.snapshot();need(armedLate->submissions.size()==1&&armedLate->submissions[0].beganBeforeArm,"arm during active scope lost/hidden");
 Sim capacity(Info,5000000000ULL,UINT64_MAX);arm(capacity);
 for(unsigned i=0;i<Sim::DetailedCapacity+1;++i){Sim::ContextGuard g(context(1,20000+i));Sim::Scope scope(capacity,1);Clock::advance(1);}
 {Sim::ContextGuard g(context(7,50000));Sim::Scope scope(capacity,0);Clock::advance(1);}
 auto full=capacity.snapshot();save(capacity,*full,out+"/capacity.json");need(full->detailDomainEntries[1]==2048&&full->detailDomainEntries[7]==1&&full->detailedOverflowEvents==1&&full->detailDomainOverflowEvents[1]==1,"capacity truncation hidden or callback domain starved");need(full->rows[3+1].count==2049,"capacity overflow damaged aggregate");
 Real concurrent(Info,5000000000ULL,UINT64_MAX);arm(concurrent);constexpr unsigned Workers=4,Events=2000;std::atomic<unsigned>done{0};std::vector<std::thread>workers;
 for(unsigned i=0;i<Workers;++i)workers.emplace_back([&,i]{for(unsigned j=0;j<Events;++j){Real::Context c;c.domain=i==3?7:1;c.queueFamily=0;c.queueIndex=i%2;c.submission=100000+i*1000+j%128;c.nativeCB=j+1;Real::ContextGuard guard(c);Real::Scope parent(concurrent,1);{Real::Scope child(concurrent,2);std::atomic_signal_fence(std::memory_order_seq_cst);}}++done;});
 uint64_t aggregate=0,details=0,overflows=0;auto consume=[&]{auto r=concurrent.snapshot();for(auto&m:r->rows){aggregate+=m.count;uint64_t h=0;for(auto n:m.inclusiveHistogram)h+=n;need(h==m.count,"histogram split by concurrent drain");}for(auto&d:r->submissions)for(auto&p:d.phases)details+=p.count;overflows+=r->detailedOverflowEvents;};
 while(done.load()!=Workers){consume();std::this_thread::sleep_for(std::chrono::microseconds(100));}for(auto&w:workers)w.join();consume();need(aggregate==Workers*Events*2&&details==aggregate&&overflows==0,"concurrent writer/report loss or double count");
 Real failure(Info);failure.setEnabled(true);{Real::Scope warm(failure,1);}failure.snapshot();failure.setDetailedEnabled(true);Real::Context fctx;fctx.domain=1;fctx.submission=900;unsigned backend=0;{Real::ContextGuard g(fctx);Real::failNextDiagnosticAllocationForTest();errno=EDOM;{Real::Scope s(failure,1);++backend;}need(errno==EDOM&&backend==1,"cold domain-table allocation changed backend/errno");}auto fail=failure.snapshot();need(fail->diagnosticAllocationDrops==1&&fail->diagnosticUnavailableThreads==1,"allocation failure hidden");
 bool originalEscaped=false;try{Sim::Scope s(t,1);throw std::logic_error("backend");}catch(const std::logic_error&){originalEscaped=true;}need(originalEscaped,"backend exception swallowed");
 MVKStutterCPUTrace bench(mvkStutterStageInfo(),5000000000ULL,UINT64_MAX);MVKCPUContext bc;bc.domain=1;bc.queueFamily=0;bc.queueIndex=0;bc.submission=1;MVKCPUContextGuard bg(bc);
 auto measure=[&](bool enabled,bool detail,unsigned n){bench.setEnabled(enabled);bench.setDetailedEnabled(detail);{MVKStutterCPUTrace::Scope warm(bench,static_cast<size_t>(MVKCPUPhase::HostEncode));}auto start=std::chrono::steady_clock::now();for(unsigned i=0;i<n;++i){MVKStutterCPUTrace::Scope scope(bench,static_cast<size_t>(MVKCPUPhase::HostEncode));std::atomic_signal_fence(std::memory_order_seq_cst);}return std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-start).count()/n;};
 std::array<double,3>off{},on{},detail{};for(unsigned i=0;i<3;++i){off[i]=measure(false,false,1000000);on[i]=measure(true,false,200000);detail[i]=measure(true,true,200000);}std::sort(off.begin(),off.end());std::sort(on.begin(),on.end());std::sort(detail.begin(),detail.end());
 auto memory=bench.snapshot();save(bench,*memory,out+"/full-phase-memory.json");need(MVKStutterCPUTrace::DetailedCapacity*MVKStutterCPUTrace::MaxDetailedShards==16384,"total cell budget changed");
 std::ofstream result(out+"/result.json");result<<"{\"passed\":true,\"checks\":"<<checks<<",\"GPUCommandsSubmitted\":0,\"nativeBuildRun\":false,\"oldFailuresPreservedSeparately\":true,\"newQueueAfter16Callbacks\":true,\"queueThreadRotation64\":true,\"sameSubmissionMixedThreadProvenance\":true,\"sameDomainMultipleQueueIsolation\":true,\"inflightAndArmTransitions\":true,\"domainOverflowVisible\":true,\"otherDomainUnaffectedByOverflow\":true,\"concurrentWriterEvents\":"<<aggregate<<",\"allConcurrentEventsDetailed\":true,\"ownAllocationFailureIsolated\":true,\"backendExceptionPreserved\":true,\"disabledMedianNS\":"<<off[1]<<",\"enabledDetailOffMedianNS\":"<<on[1]<<",\"enabledDetailOnMedianNS\":"<<detail[1]<<",\"cellsPerDomain\":2048,\"domains\":8,\"totalCellBudget\":16384,\"fullPhaseCount\":"<<size_t(MVKCPUPhase::Count)<<",\"bytesPerDomainTable\":"<<MVKStutterCPUTrace::detailedBytesPerShard()<<",\"maximumDetailedTableBytes\":"<<8*MVKStutterCPUTrace::detailedBytesPerShard()<<",\"scopeTimingsAreNotGameFPS\":true}\n";return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 2;}}
