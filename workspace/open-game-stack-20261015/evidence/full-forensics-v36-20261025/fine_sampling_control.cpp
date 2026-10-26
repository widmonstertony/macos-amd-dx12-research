#include "../../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKCPUTimingTrace.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
struct SimClock{inline static thread_local uint64_t now=1;static uint64_t ticks(){return now;}static uint64_t toNS(uint64_t x){return x;}static uint64_t unixNS(){return 1700000000000000000ULL+now;}static uint64_t threadNS(){return now;}};
using T=MVKCPUTimingTrace<2,2,SimClock>;
static unsigned checks=0;void need(bool b,const char*m){++checks;if(!b)throw std::runtime_error(m);}
int main(int argc,char**argv){try{
 need(argc==2,"path required");std::string out=argv[1];
 T t({{{"Parent",MVKCPUTimingKind::Work,1},{"Fine",MVKCPUTimingKind::Work,8}}});t.setEnabled(true);
 for(unsigned domain=0;domain<2;++domain){T::Context c;c.domain=domain;T::ContextGuard g(c);for(unsigned i=0;i<80;++i){errno=EDOM;{T::Scope parent(t,0);SimClock::now+=10;{T::Scope child(t,1);SimClock::now+=20;}SimClock::now+=30;}need(errno==EDOM,"errno changed");}}
 auto r=t.snapshot();for(unsigned d=0;d<2;++d){auto p=r->rows[d*2],f=r->rows[d*2+1];need(p.count==80&&f.count==10,"sampling count");need(r->fineScopesOffered[d*2+1]==80,"offer count");need(p.inclusiveNS==4800&&p.selfNS==4600&&f.inclusiveNS==200,"measured self invariant");}
 FILE*fp=fopen((out+"/sampling.json").c_str(),"w");t.writeJSON(fp,*r);fclose(fp);
 auto empty=t.snapshot();need(empty->fineScopesOffered[1]==0&&empty->rows[1].count==0,"offer drain");
 T concurrent({{{"Parent",MVKCPUTimingKind::Work,1},{"Fine",MVKCPUTimingKind::Work,8}}});concurrent.setEnabled(true);
 std::atomic<unsigned>done{0};std::vector<std::thread>w;
 for(unsigned k=0;k<4;++k)w.emplace_back([&,k]{T::Context c;c.domain=k%2;T::ContextGuard g(c);for(unsigned i=0;i<4000;++i){T::Scope a(concurrent,0);SimClock::now+=10;{T::Scope b(concurrent,1);SimClock::now+=20;}}++done;});
 uint64_t coarse=0,fine=0,offers=0;auto drain=[&]{auto x=concurrent.snapshot();for(unsigned d=0;d<2;++d){coarse+=x->rows[d*2].count;fine+=x->rows[d*2+1].count;offers+=x->fineScopesOffered[d*2+1];}};
 while(done.load()!=4){drain();std::this_thread::yield();}for(auto&x:w)x.join();drain();need(coarse==16000&&fine==2000&&offers==16000,"concurrent drain lost events");
 T normal({{{"Parent",MVKCPUTimingKind::Work},{"Fine",MVKCPUTimingKind::Work}}});normal.setEnabled(true);for(unsigned i=0;i<9;++i){T::Scope a(normal,0);{T::Scope b(normal,1);++SimClock::now;}}auto all=normal.snapshot();need(all->rows[0].count==9&&all->rows[1].count==9,"default sampling behavior changed");
 using R=MVKCPUTimingTrace<2,2>;auto bench=[](uint32_t every){R z({{{"Parent",MVKCPUTimingKind::Work,1},{"Fine",MVKCPUTimingKind::Work,every}}});z.setEnabled(true);auto s=std::chrono::steady_clock::now();for(unsigned i=0;i<200000;++i){R::Scope a(z,0);R::Scope b(z,1);std::atomic_signal_fence(std::memory_order_seq_cst);}return std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-s).count()/200000;};
 std::ofstream o(out+"/fine-sampling-qualification.json");o<<"{\"passed\":true,\"checks\":"<<checks<<",\"concurrentOffered\":"<<offers<<",\"concurrentMeasuredFine\":"<<fine<<",\"fullSamplingPairNS\":"<<bench(1)<<",\"sample64PairNS\":"<<bench(64)<<",\"noGPUCommands\":true,\"gamePerformanceNotValidated\":true}\n";
 }catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
