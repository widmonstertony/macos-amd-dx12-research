// CPU-only contract/state-transition control; no Metal or GPU dependencies.
#include "MVKEncoderHeapLedger.h"
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>
using ID=uint64_t;
using Ledger=MVKEncoderHeapLedger<ID,ID>;
static uint64_t checks=0;
static void need(bool yes,const char*message){++checks;if(!yes)throw std::runtime_error(message);}
struct Usage {uint32_t stages=0;bool writes=false,precise=false;};
struct Want {uint32_t stages=0;bool writes=false,precise=false;};
struct Model {
 Ledger ledger;
 std::map<ID,ID> heap;
 std::map<ID,uint64_t> epoch;
 std::map<ID,Usage> native;
 std::map<ID,Want> required;
 uint64_t hCalls=0,rCalls=0,wCalls=0,resets=0,flushes=0;
 void add(ID resource,ID parent){need(resource&&heap.emplace(resource,parent).second,"bad owned resource");if(parent)++epoch[parent];}
 bool read(ID r,uint32_t s){auto&w=required[r];w.stages|=s;w.precise=true;return ledger.queuePreciseRead(r,heap.at(r),s);}
 bool write(ID r,uint32_t s){auto&w=required[r];w.stages|=s;w.writes=true;w.precise=true;return ledger.queueWrite(r,heap.at(r),s);}
 bool bulk(ID h,uint32_t s){for(auto x:heap)if(x.second==h)required[x.first].stages|=s;return ledger.queueHeapRead(h,s,epoch.at(h));}
 void reset(){ledger.reset();native.clear();required.clear();++resets;}
 void check(){for(auto x:required){auto f=native.find(x.first);need(f!=native.end(),"missing native resource");const auto&a=f->second;auto b=x.second;need((a.stages&b.stages)==b.stages,"lost cumulative stage coverage");need(!b.writes||a.writes,"heap/read downgraded prior write");need(!b.precise||a.precise,"heap declaration lost precise access exception");}}
 void flush(unsigned failAt=0){
  unsigned phase=0;bool heapPhase=true,after=false;
  auto fail=[&](unsigned n){if(failAt==n)throw std::runtime_error("injected callback failure");};
  ledger.flush([&](ID h,uint32_t s){need(heapPhase&&!after,"heap ordering");++hCalls;for(auto x:heap)if(x.second==h)native[x.first]={s,false,false};phase=1;fail(1);},
   [&](ID r,uint32_t s){heapPhase=false;need(!after,"read ordering");native[r]={s,false,true};++rCalls;phase=2;fail(2);},
   [&](ID r,uint32_t s){need(after,"write ordering");native[r]={s,true,true};++wCalls;phase=4;fail(4);},
   [&]{heapPhase=false;after=true;phase=3;fail(3);});
  (void)phase;++flushes;check();
 }
};
static void transitions(Model&m){
 m.add(1,10);m.add(2,10);m.add(3,0);m.add(4,20);m.add(5,20);
 need(m.read(1,1),"first read not queued");m.flush();auto n=m.rCalls;
 for(unsigned i=0;i<100;++i){need(!m.read(1,1),"redundant precise read marked dirty");m.flush();}
 need(m.rCalls==n,"same encoder/stage reread emitted");
 need(m.read(1,2),"new read stage suppressed");m.flush();need(m.native[1].stages==3,"read stage upgrade lost prior mask");
 n=m.rCalls;m.bulk(10,4);m.flush();need(m.rCalls==n+1,"heap failed to replay earlier precise read");need(m.native[1].precise,"heap replaced precise access exception");
 auto h=m.hCalls;n=m.rCalls;need(!m.bulk(10,4),"same heap/stage/epoch queued");m.flush();need(m.rCalls==n&&m.hCalls==h,"unchanged heap caused declarations");
 m.add(6,10);m.bulk(10,4);m.flush();need(m.hCalls==h+1&&m.rCalls==n+1,"membership epoch failed read replay");
 m.read(3,8);m.flush();n=m.rCalls;m.bulk(10,16);m.flush();need(m.rCalls==n+1,"nil-heap resource replayed on unrelated heap");
 m.write(1,32);m.flush();n=m.rCalls;auto w=m.wCalls;m.bulk(10,64);m.flush();need(m.rCalls==n&&m.wCalls==w+1,"read not superseded or write exception missing");
 w=m.wCalls;need(!m.read(1,1),"read covered by precise write not suppressed");m.flush();need(m.wCalls==w,"read needlessly dirtied unchanged write");
 need(m.read(1,128),"read stage upgrade of writer suppressed");m.flush();need(m.wCalls==w+1&&m.native[1].writes,"read upgrade lost read/write usage");
 m.read(4,1);m.read(4,2);m.read(4,1);n=m.rCalls;m.bulk(20,4);m.flush();need(m.rCalls==n+1,"pending read/dirty heap selection duplicated read");
 m.read(4,8);m.write(4,16);n=m.rCalls;m.flush();need(m.rCalls==n&&m.native[4].writes,"pending write failed read supersession");
 bool bad=false;try{m.ledger.queuePreciseRead(1,99,1);}catch(const std::logic_error&){bad=true;}need(bad,"changed read heap identity accepted");bad=false;try{m.ledger.queueWrite(1,99,1);}catch(const std::logic_error&){bad=true;}need(bad,"changed write heap identity accepted");
 need(!m.ledger.queuePreciseRead(0,0,1),"null read accepted");need(!m.ledger.queuePreciseRead(3,0,0),"empty stages accepted");
 for(unsigned i=0;i<32;++i){m.reset();n=m.rCalls;need(m.read(1,1),"cross-encoder reuse suppressed");m.bulk(10,2);m.flush();need(m.rCalls==n+1,"encoder reset skipped read exception");}
}
static void failures(){
 for(unsigned phase=1;phase<=4;++phase){Model m;m.add(1,10);m.add(2,10);m.read(1,1);m.write(2,2);m.flush();m.bulk(10,4);bool failed=false;try{m.flush(phase);}catch(const std::runtime_error&){failed=true;}need(failed,"injected phase not reached");m.flush();m.check();}
 Model m;m.add(1,10);m.read(1,1);m.flush();m.bulk(10,2);bool failed=false;try{m.ledger.flush([&](ID,uint32_t){m.ledger.reset();},[](ID,uint32_t){},[](ID,uint32_t){},[]{});}catch(const std::logic_error&){failed=true;}need(failed,"callback reentry accepted");m.flush();
}
static uint64_t rng(uint64_t&s){s^=s<<13;s^=s>>7;s^=s<<17;return s;}
static void randomized(Model&m){
 for(ID r=100;r<164;++r)m.add(r,(r%5)?1000+r%4:0);
 uint64_t seed=UINT64_C(0x1de7c0e9f3a58d29);
 for(unsigned encoder=0;encoder<64;++encoder){m.reset();
  for(unsigned i=0;i<256;++i){ID r=100+rng(seed)%64;uint32_t s=1u<<(rng(seed)%8);switch(rng(seed)%5){case 0:m.bulk(1000+rng(seed)%4,s);break;case 1:m.write(r,s);break;default:m.read(r,s);break;}if(i%3==0)m.flush();}m.flush();
 }
}
int main(int argc,char**argv){try{need(argc==2,"report path required");Model m;transitions(m);failures();randomized(m);auto s=m.ledger.stats();need(s.preciseReadQueueSuppressed>0,"suppression not exercised");need(s.readExceptionsReplayed>0,"read replay not exercised");need(s.writeExceptionsReplayed>0,"write replay not exercised");need(s.readResourceReplayOperations==0,"bulk child replay introduced");std::ofstream f(argv[1]);f<<"{\"passed\":true,\"CPUOnly\":true,\"GPUCommandsSubmitted\":0,\"checks\":"<<checks<<",\"randomSeed\":\"0x1de7c0e9f3a58d29\",\"resets\":"<<m.resets<<",\"flushes\":"<<m.flushes<<",\"readQueueCalls\":"<<s.preciseReadQueueCalls<<",\"readQueueSuppressed\":"<<s.preciseReadQueueSuppressed<<",\"readCallsEmitted\":"<<s.readCallsEmitted<<",\"readExceptionsReplayed\":"<<s.readExceptionsReplayed<<",\"writeExceptionsReplayed\":"<<s.writeExceptionsReplayed<<",\"bulkChildReplayOperations\":"<<s.readResourceReplayOperations<<",\"mismatches\":0,\"scope\":\"owned CPU state/contract transitions; no Metal driver, game integration or FPS validation\"}\n";need(bool(f),"report write failed");return 0;}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 2;}}
