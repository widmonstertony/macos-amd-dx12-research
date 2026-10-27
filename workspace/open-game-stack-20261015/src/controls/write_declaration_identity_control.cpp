#include "MVKEncoderHeapLedger.h"
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <tuple>
#include <vector>
using Ledger=MVKEncoderHeapLedger<uint64_t,uint64_t>;
static unsigned checks=0;
static void need(bool b,const char* why){++checks;if(!b)throw std::runtime_error(why);}
int main(int argc,char**argv){try{
 need(argc==2,"report required");Ledger ledger;
 std::vector<std::tuple<uint64_t,uint64_t,uint32_t>> writes;
 unsigned reads=0,heaps=0;
 auto flush=[&]{ledger.flush([&](uint64_t,uint32_t){++heaps;},[&](uint64_t,uint32_t){++reads;},
  [&](uint64_t logical,uint64_t declaration,uint32_t stages){writes.emplace_back(logical,declaration,stages);},[]{});};
 ledger.queueWrite(101,7,1,900);ledger.queueWrite(102,7,2,900);flush();
 need(writes.size()==2&&std::get<0>(writes[0])==101&&std::get<0>(writes[1])==102,"logical writes merged in ledger");
 need(std::get<1>(writes[0])==900&&std::get<1>(writes[1])==900,"native declaration owner lost");
 need(ledger.queuePreciseRead(101,7,4),"logical writer read-stage upgrade suppressed");flush();
 need(reads==0&&std::get<2>(writes.back())==5,"physical owner broke logical read/write supersession");
 auto old=writes.size();ledger.queueHeapRead(7,8,1);flush();
 need(heaps==1&&writes.size()==old+2,"heap failed to replay both logical writers");
 std::map<uint64_t,uint32_t> native;
 for(size_t i=old;i<writes.size();++i)native[std::get<1>(writes[i])]|=std::get<2>(writes[i]);
 need(native.size()==1&&native[900]==15,"coalesced owner lost stage coverage");
 bool rejected=false;try{ledger.queueWrite(101,7,1,901);}catch(const std::logic_error&e){rejected=std::string(e.what())=="retained resource changed declaration identity";}
 need(rejected,"retained declaration identity mutation accepted");
 rejected=false;try{ledger.queueWrite(102,8,1,900);}catch(const std::logic_error&e){rejected=std::string(e.what())=="retained resource changed heap identity";}
 need(rejected,"true heap mismatch accepted");
 ledger.reset();writes.clear();ledger.queueWrite(101,7,1,901);flush();
 need(std::get<1>(writes.back())==901,"encoder reset retained old physical owner");
 ledger.reset();ledger.queueWrite(101,7,1,900);uint64_t logical=0;
 ledger.flush([](uint64_t,uint32_t){},[](uint64_t,uint32_t){},[&](uint64_t r,uint32_t){logical=r;},[]{});
 need(logical==101,"legacy two-argument callback contract changed");
 ledger.reset();ledger.queueWrite(101,7,1,900);bool failed=false;
 try{ledger.flush([](uint64_t,uint32_t){},[](uint64_t,uint32_t){},[](uint64_t,uint64_t,uint32_t){throw std::runtime_error("injected");},[]{});}catch(const std::runtime_error&){failed=true;}
 need(failed,"failure injection missed write callback");writes.clear();flush();
 need(writes.size()==1&&std::get<1>(writes[0])==900,"failed callback lost physical replay");
 std::ofstream f(argv[1]);f<<"{\"passed\":true,\"CPUOnly\":true,\"checks\":"<<checks<<",\"logicalIdentityAndStageCoveragePreserved\":true,\"physicalDeclarationIdentityValidated\":true,\"heapReplayAndFailureRetryPassed\":true}\n";return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 2;}}
