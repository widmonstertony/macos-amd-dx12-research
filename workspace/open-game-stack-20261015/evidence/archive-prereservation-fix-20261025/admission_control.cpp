#define MVK_ARCHIVE_ADMISSION_CPU_CONTROL 1
#include "../../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKComputeArchive.h"
#include <atomic>
#include <thread>
#include <vector>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <chrono>
using Ledger=MVKArchiveAdmissionLedger;namespace fs=std::filesystem;
static uint64_t checks=0;
static void need(bool ok,const char*why){++checks;if(!ok)throw std::runtime_error(why);}
static void invariant(const Ledger::Stats&s,uint64_t cap){need(s.committed<=cap&&s.reserved<=cap-s.committed,"quota oversubscribed");}
static void write(const fs::path&p,std::string bytes){std::ofstream f(p,std::ios::binary);f<<bytes;f.close();need(bool(f),"test file write failed");}
static std::string read(const fs::path&p){std::ifstream f(p,std::ios::binary);return {std::istreambuf_iterator<char>(f),{}};}
int main(int argc,char**argv){try{
 need(argc==2,"output directory required");fs::path out=argv[1];Ledger ledger;unsigned scans=0;auto inventory=[&]{++scans;return uint64_t(128);};
 {auto a=ledger.reserve("serial","a",1024,256,inventory);auto b=ledger.reserve("serial","b",1024,256,inventory);auto c=ledger.reserve("serial","c",1024,256,inventory);need(bool(a)&&bool(b)&&bool(c),"initial reservations rejected");
 auto full=ledger.reserve("serial","d",1024,256,inventory);need(!full&&full.decision()==Ledger::Decision::Budget,"full reserved quota not rejected");
 auto duplicate=ledger.reserve("serial","a",1024,256,inventory);need(!duplicate&&duplicate.decision()==Ledger::Decision::Pending,"same-key pending not deduplicated");
 need(a.publish(100,[]{return true;}),"actual-byte commit failed");invariant(ledger.snapshot("serial"),1024);
 auto d=ledger.reserve("serial","d",1024,256,inventory);need(bool(d),"released headroom not reusable");auto moved=std::move(d);need(!d&&bool(moved),"reservation move lost ownership");}
 auto serial=ledger.snapshot("serial");need(scans==1&&serial.inventoryRuns==1&&serial.committed==228&&serial.reserved==0&&serial.pending==0&&serial.published==1,"serial actual accounting or RAII release failed");
 unsigned linked=0;{auto r=ledger.reserve("invalid-size","x",1024,256,[]{return 0;});need(!r.publish(256,[&]{++linked;return true;}),"equal-to-limit shard accepted");}need(linked==0&&ledger.snapshot("invalid-size").reserved==0,"size rejection called link or leaked reservation");
 try{auto r=ledger.reserve("throw","x",1024,256,[]{return 0;});r.publish(64,[]{throw std::runtime_error("controlled link exception");return false;});}catch(const std::runtime_error&){}
 need(ledger.snapshot("throw").reserved==0&&ledger.snapshot("throw").pending==0,"exception path leaked reservation");
 {auto r=ledger.reserve("failed","x",1024,256,[]{return 0;});need(!r.publish(64,[]{return false;}),"failed link succeeded");}need(ledger.snapshot("failed").reserved==0,"failed link leaked quota");
 auto changed=ledger.reserve("serial","changed",2048,256,inventory);need(!changed&&changed.decision()==Ledger::Decision::Invalid,"midprocess quota change silently accepted");
 unsigned builders=0;constexpr uint64_t SaturatedCap=2ull<<30;auto start=std::chrono::steady_clock::now();
 for(unsigned i=0;i<2000;++i){auto r=ledger.reserve("real-saturation-shape",std::to_string(i),SaturatedCap,16ull<<20,[]{return SaturatedCap-784;});if(r)++builders;}
 double rejectNS=std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-start).count()/2000;
 auto saturation=ledger.snapshot("real-saturation-shape");need(builders==0&&saturation.budgetSkipped==2000&&saturation.inventoryRuns==1&&saturation.reserved==0,"784-byte-tail ran archive builder or rescanned");
 fs::path files=out/("small-files-"+std::to_string(getpid()));fs::create_directories(files);write(files/"rs1-existing.metalar",std::string(64,'E'));
 Ledger concurrent;constexpr uint64_t Cap=4096,Shard=256;std::atomic<unsigned>scanCount{0},done{0},bad{0},tempCount{0};std::vector<std::thread>threads;
 auto fileInventory=[&]{++scanCount;uint64_t n=0;for(auto&e:fs::directory_iterator(files))if(e.path().extension()==".metalar")n+=e.file_size();return n;};
 for(unsigned worker=0;worker<8;++worker)threads.emplace_back([&,worker]{try{for(unsigned j=0;j<32;++j){std::string key="rs1-"+std::to_string(worker)+"-"+std::to_string(j)+".metalar";auto r=concurrent.reserve(files.string(),key,Cap,Shard,fileInventory);if(!r)continue;fs::path final=files/key,temporary=files/(key+".tmp."+std::to_string(worker));{std::ofstream f(temporary,std::ios::binary);f<<std::string(64,'A'+worker);if(!f)++bad;}++tempCount;bool published=r.publish(64,[&]{return link(temporary.c_str(),final.c_str())==0;});if(!published)++bad;unlink(temporary.c_str());auto s=concurrent.snapshot(files.string());if(s.committed>Cap||s.reserved>Cap-s.committed)++bad;}}catch(...){++bad;}++done;});
 while(done.load()!=8){invariant(concurrent.snapshot(files.string()),Cap);std::this_thread::sleep_for(std::chrono::microseconds(100));}for(auto&t:threads)t.join();auto disk=concurrent.snapshot(files.string());invariant(disk,Cap);
 uint64_t actual=0;unsigned temps=0;for(auto&e:fs::directory_iterator(files)){if(e.path().extension()==".metalar")actual+=e.file_size();else if(e.path().string().find(".tmp.")!=std::string::npos)++temps;}
 need(bad==0&&scanCount==1&&disk.inventoryRuns==1&&disk.reserved==0&&disk.pending==0&&actual==disk.committed&&actual<=Cap&&Cap-actual<Shard&&temps==0,"concurrent files/accounting/one-inventory failed");need(read(files/"rs1-existing.metalar")==std::string(64,'E'),"existing archive modified");
 Ledger same;auto hold=same.reserve("same","same-key",4096,256,[]{return 0;});std::atomic<unsigned>sameBuilders{0};threads.clear();for(unsigned i=0;i<8;++i)threads.emplace_back([&]{auto r=same.reserve("same","same-key",4096,256,[]{return 999;});if(r)++sameBuilders;});for(auto&t:threads)t.join();need(sameBuilders==0&&same.snapshot("same").pendingSkipped==8,"concurrent same-key builders not suppressed");hold.cancel();need(same.snapshot("same").reserved==0,"pending-key cancel leaked");
 fs::path existing=files/"existing-create-only.bin",temporary=files/"owned-temporary.bin";write(existing,"preserve existing");write(temporary,"new data");auto race=same.reserve("create-only","final",4096,256,[]{return 0;});need(!race.publish(8,[&]{return link(temporary.c_str(),existing.c_str())==0;}),"create-only link replaced destination");need(read(existing)=="preserve existing"&&same.snapshot("create-only").reserved==0,"EEXIST altered file or leaked quota");unlink(temporary.c_str());
 std::ofstream result(out/"result.json");result<<"{\"passed\":true,\"checks\":"<<checks<<",\"GPUCommandsSubmitted\":0,\"nativeLibraryBuilt\":false,\"gameOrSteamLaunched\":false,\"actualCacheModified\":false,\"saturatedAttempts\":2000,\"saturatedBuilderCalls\":0,\"saturatedInventoryRuns\":1,\"saturatedRejectAverageNS\":"<<rejectNS<<",\"pendingDedupThreads\":8,\"concurrentWriters\":8,\"smallFilePublished\":"<<disk.published<<",\"smallFileCommittedBytes\":"<<disk.committed<<",\"smallFileQuota\":4096,\"smallFileRemainingBytes\":"<<Cap-disk.committed<<",\"maxShardReservationBytes\":256,\"inventoryRuns\":"<<scanCount<<",\"failureAndExceptionReservationsReleased\":true,\"actualSizeReconciliation\":true,\"existingFilesPreserved\":true,\"tailUnderfillExplicit\":true,\"multipleProcessesOutsideOriginalGuarantee\":true}\n";return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 2;}}
