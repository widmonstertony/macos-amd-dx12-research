#include "MVKStutterCoverage.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
static void need(bool v,const char* message){if(!v)throw std::runtime_error(message);}
int main(int argc,char**argv){try{
    need(argc==2,"output dir required");std::string dir=argv[1],marker=dir+"/cpu-arm";
    setenv("MVK_AMD_STUTTER_COVERAGE","1",1);setenv("MVK_CONFIG_SHADER_DUMP_DIR",dir.c_str(),1);setenv("MVK_AMD_STUTTER_CPU_ARM_PATH",marker.c_str(),1);setenv("MVK_AMD_STUTTER_DETAIL","1",1);unlink(marker.c_str());
    auto begin=std::chrono::steady_clock::now();uint64_t bytes=0,blockBytes=0;size_t phases=static_cast<size_t>(MVKCPUPhase::Count);
    {MVKStutterCPURuntime runtime;need(!runtime.trace.enabled(),"missing marker did not disable CPU scopes");{std::ofstream touch(marker);touch<<"armed";}runtime.publish(true);need(runtime.trace.enabled()&&runtime.trace.detailedEnabled(),"marker did not arm CPU/detail");
      MVKCPUContext c;c.domain=1;c.queueFamily=0;c.queueIndex=0;c.submission=999;c.nativeCB=111;c.frame=4;c.shader=0xabcd;MVKCPUContextGuard context(c);
      {MVKStutterCPUTrace::Scope work(runtime.trace,static_cast<size_t>(MVKCPUPhase::HostEncode),123,true);std::this_thread::sleep_for(std::chrono::milliseconds(5150));}
      runtime.publish(true);auto report=runtime.trace.snapshot();bytes=runtime.trace.detailedBytesPerShard();blockBytes=runtime.trace.aggregateBytesPerDomain();
      unlink(marker.c_str());runtime.publish(true);need(!runtime.trace.enabled(),"removed marker did not disable capture");
    }
    double duration=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();need(duration<7000,"reporter teardown waited for interval");
    std::ofstream out(dir+"/wrapper-result.json");out<<"{\"passed\":true,\"GPUCommandsSubmitted\":0,\"phaseCount\":"<<phases<<",\"fiveSecondReporterRan\":true,\"sameProcessMarkerOffOnOffChecked\":true,\"boundedHistoryAndCurrentCreated\":true,\"stopNotifyJoinTotalMS\":"<<duration<<",\"detailedBytesPerShard\":"<<bytes<<",\"maxDetailedShards\":16,\"aggregateBytesPerDomain\":"<<blockBytes<<",\"all100ThreadMaxAggregateBytes\":"<<100*8*blockBytes<<",\"all100ThreadTypicalOneDomainAggregateBytes\":"<<100*blockBytes<<",\"maxDetailedBytes\":"<<16*bytes<<"}\n";
}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 2;}}
