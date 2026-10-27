#include "MVKEncoderResourceIndex.h"
#include "MVKEncoderHeapLedger.h"
#define MVKEncoderHeapLedger V43EncoderHeapLedger
#include "encoder_heap_ledger_before_dense_index.h"
#undef MVKEncoderHeapLedger
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <new>
#include <unordered_map>

static bool countAllocations=false;
static uint64_t allocations=0,checks=0;
void* operator new(size_t n) {if(countAllocations)++allocations;if(void* p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void operator delete(void* p) noexcept {std::free(p);}
void operator delete(void* p,size_t) noexcept {std::free(p);}
void* operator new[](size_t n) {return ::operator new(n);}
void operator delete[](void* p) noexcept {::operator delete(p);}
void operator delete[](void* p,size_t) noexcept {::operator delete(p);}
static void need(bool b,const char* s) {++checks;if(!b)throw std::runtime_error(s);}
static uint64_t randomWord(uint64_t& x) {x^=x<<13;x^=x>>7;x^=x<<17;return x;}
struct CollisionHash {size_t operator()(uint64_t)const{return 0;}};
template<class Hash> static void indexControl() {
    MVKEncoderResourceIndex<uint64_t,Hash> index;
    std::unordered_map<uint64_t,size_t> reference;
    uint64_t seed=UINT64_C(0xaf2549ecabc31225);
    for(unsigned epoch=0;epoch<32;++epoch) {
        index.clear();reference.clear();
        need(index.size()==0,"clear retained identities");
        for(unsigned n=0;n<4096;++n) {
            uint64_t key=(randomWord(seed)%2048)*256;
            if(n%3){index.emplace(key,n);reference.emplace(key,n);}
            auto expected=reference.find(key);auto found=index.findValue(key);
            need(bool(found)==(expected!=reference.end()),"index presence differs");
            if(found)need(*found==expected->second,"duplicate insertion changed value");
            need(index.size()==reference.size(),"index size differs");
        }
        for(const auto& e:reference)need(index.findValue(e.first)&&*index.findValue(e.first)==e.second,"growth lost entry");
    }
}
struct Run {double milliseconds=0;uint64_t allocations=0,hash=0,events=0;};
template<class Ledger> static Run replay() {
    Ledger ledger;Run result;uint64_t hash=0,events=0;
    auto emit=[&](uint64_t id,uint32_t stages){hash=(hash*UINT64_C(0x100000001b3))^(id+stages);++events;};
    // Scene-scale metadata workload, not a recording of the game's identities:
    // 494 precise reads, 101 writes, 36 heaps; stage/epoch upgrades and resets.
    auto encoder=[&](unsigned epoch) {
        ledger.reset();
        for(uint64_t h=1;h<=36;++h)ledger.queueHeapRead(h*256,2,epoch);
        for(uint64_t n=1;n<=494;++n)ledger.queuePreciseRead(n*256,(n%36+1)*256,2);
        for(uint64_t n=450;n<551;++n)ledger.queueWrite(n*256,(n%36+1)*256,27);
        ledger.flush(emit,emit,emit,[]{});
        for(uint64_t n=1;n<=494;n+=2)ledger.queuePreciseRead(n*256,(n%36+1)*256,4);
        for(uint64_t h=1;h<=36;++h)ledger.queueHeapRead(h*256,8,epoch+1);
        ledger.flush(emit,emit,emit,[]{});
    };
    encoder(0);hash=events=0;allocations=0;countAllocations=true;
    auto begin=std::chrono::steady_clock::now();
    for(unsigned i=1;i<=1024;++i)encoder(i);
    auto end=std::chrono::steady_clock::now();countAllocations=false;
    result.milliseconds=std::chrono::duration<double,std::milli>(end-begin).count();
    result.allocations=allocations;result.hash=hash;result.events=events;return result;
}
int main(int argc,char** argv) {try {
    need(argc==2,"report path required");indexControl<std::hash<uint64_t>>();indexControl<CollisionHash>();
    auto old=replay<V43EncoderHeapLedger<uint64_t,uint64_t>>();
    auto next=replay<MVKEncoderHeapLedger<uint64_t,uint64_t>>();
    need(old.events==next.events&&old.hash==next.hash,"declaration order/values changed");
    need(next.allocations<old.allocations,"node allocations did not decrease");
    std::ofstream f(argv[1]);f<<"{\"passed\":true,\"CPUOnly\":true,\"checks\":"<<checks<<",\"oldMilliseconds\":"<<old.milliseconds<<",\"newMilliseconds\":"<<next.milliseconds<<",\"oldAllocations\":"<<old.allocations<<",\"newAllocations\":"<<next.allocations<<",\"nativeDeclarationEventsCompared\":"<<next.events<<",\"nativeDeclarationOrderIdentical\":true,\"syntheticSceneScaleNotGameReplay\":true,\"gameFPSClaimed\":false}\n";
    need(bool(f),"report write failed");return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 2;}}
