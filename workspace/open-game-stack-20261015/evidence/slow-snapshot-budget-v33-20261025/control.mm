#include "MVKStutterNativeTrace.h"
#include <thread>
#include <vector>
#include <atomic>
#include <fcntl.h>
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 2;setenv("MVK_AMD_STUTTER_COVERAGE","1",1);setenv("MVK_CONFIG_SHADER_DUMP_DIR",argv[1],1);
 std::string path=std::string(argv[1])+"/control.arm";setenv("MVK_AMD_STUTTER_ARM_PATH",path.c_str(),1);
 bool off=!mvkStutterAdmitSlowSnapshot();int fd=open(path.c_str(),O_CREAT|O_WRONLY,0600);close(fd);usleep(120000);
 auto arm=mvkStutterNativeArm();{auto&w=mvkStutterNativeWriter();std::lock_guard<std::mutex>g(w.lock);w.sessions[arm.session]={};}
 // Align the concurrent burst within one real monotonic second.
 uint64_t n=mvkStutterNativeMonotonicNS();usleep((unsigned)((1000000000ULL-n%1000000000ULL)/1000+10000));
 std::atomic<unsigned> count{0};std::vector<std::thread>workers;
 for(unsigned i=0;i<32;++i)workers.emplace_back([&]{for(unsigned j=0;j<8;++j)if(mvkStutterAdmitSlowSnapshot())++count;});
 for(auto&t:workers)t.join();bool rate=count.load()==4;
 for(unsigned i=0;i<16;++i){usleep(1030000);for(unsigned j=0;j<4;++j)if(mvkStutterAdmitSlowSnapshot())++count;}
 bool cap=count.load()==64;unlink(path.c_str());usleep(120000);bool stopped=!mvkStutterAdmitSlowSnapshot();
 printf("{\"passed\":%s,\"unarmedDisabled\":%s,\"concurrentRateLimit\":%s,\"perArmMaximum\":64,\"actualAdmitted\":%u,\"closedArmDisabled\":%s,\"GPUWorkExecuted\":false}\n",(off&&rate&&cap&&stopped)?"true":"false",off?"true":"false",rate?"true":"false",count.load(),stopped?"true":"false");return off&&rate&&cap&&stopped?0:1;
}}
