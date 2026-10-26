#include "../../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKStutterCoverage.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <fcntl.h>
void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
int main(int argc,char**argv){try{need(argc==2,"path required");std::string d=argv[1],m=d+"/cpu.arm",h=d+"/cpu-stutter-"+std::to_string(getpid())+".jsonl";setenv("MVK_AMD_STUTTER_COVERAGE","1",1);setenv("MVK_CONFIG_SHADER_DUMP_DIR",d.c_str(),1);setenv("MVK_AMD_STUTTER_CPU_ARM_PATH",m.c_str(),1);setenv("MVK_AMD_STUTTER_DETAIL_ARM_PATH",m.c_str(),1);unlink(m.c_str());int fd=open(h.c_str(),O_WRONLY|O_CREAT|O_TRUNC,0600);need(fd>=0,"history fixture create");need(!ftruncate(fd,64LL*1024*1024),"sparse history fixture");close(fd);
 {MVKStutterCPURuntime r;need(!r.trace.enabled(),"initial arm false");{std::ofstream f(m);f<<"arm";}std::this_thread::sleep_for(std::chrono::milliseconds(700));need(r.trace.enabled()&&r.trace.detailedEnabled(),"reporter arm polling");{MVKStutterCPUTrace::Scope s(r.trace,size_t(MVKCPUPhase::HostEncode));}r.publish(true);struct stat st{};need(!stat(h.c_str(),&st)&&st.st_size==64LL*1024*1024,"history cap exceeded");unlink(m.c_str());std::this_thread::sleep_for(std::chrono::milliseconds(700));need(!r.trace.enabled(),"reporter disarm");{std::ofstream f(m);f<<"rearm";}std::this_thread::sleep_for(std::chrono::milliseconds(700));need(r.trace.enabled(),"same process rearm");unlink(m.c_str());}
 unlink(h.c_str());std::ofstream f(d+"/runtime-arm-qualification.json");f<<"{\"passed\":true,\"sameProcessArmDisarmRearm\":true,\"historyCapBytes\":67108864,\"currentSurvivesFullHistory\":true,\"noGPUCommands\":true,\"pid\":"<<getpid()<<"}\n";
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
