// SPDX-License-Identifier: Apache-2.0
#include "../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKTimedTraceArm.h"
#include <cassert>
#include <fstream>
#include <thread>
#include <utime.h>
#include <unistd.h>
#include <iostream>
int main(int argc,char** argv) {
    assert(argc==2);std::string path=argv[1];assert(access(path.c_str(),F_OK)!=0);
    MVKTimedTraceArm disabled(nullptr), arm(path.c_str());assert(!disabled.enabled());assert(!arm.enabled());
    {std::ofstream f(path);f<<"owned diagnostic fixture";}
    std::this_thread::sleep_for(std::chrono::milliseconds(280));assert(arm.enabled());
    struct utimbuf t{time(nullptr)-60,time(nullptr)-60};assert(utime(path.c_str(),&t)==0);
    std::this_thread::sleep_for(std::chrono::milliseconds(280));assert(!arm.enabled());
    t.actime=t.modtime=time(nullptr)+60;assert(utime(path.c_str(),&t)==0);
    std::this_thread::sleep_for(std::chrono::milliseconds(280));assert(!arm.enabled());
    assert(unlink(path.c_str())==0);
    auto start=std::chrono::steady_clock::now();unsigned hits=0;
    for(unsigned i=0;i<1000000;++i)hits+=arm.enabled();assert(hits==0);
    double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    std::cout<<"{\"passed\":true,\"disabledAndMissingAndFreshAndExpiredAndFutureChecked\":true,\"disabledConfiguredCalls\":1000000,\"CPUms\":"<<ms<<",\"GPUCommandsChanged\":false}\n";
}
