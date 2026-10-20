#include "spirv_msl.hpp"
#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>
using namespace MVK_spirv_cross;
int main(int argc,char**argv) { try {
    if(argc!=4 && argc!=5) throw std::runtime_error("native_typed_root_cli input.spv output.metal enabled(0|1) [force-temporaries(0|1)]");
    std::ifstream in(argv[1],std::ios::binary|std::ios::ate);
    if(!in) throw std::runtime_error("input unavailable");
    size_t size=size_t(in.tellg()); in.seekg(0); std::vector<uint32_t> code(size/4);
    if(size%4||!in.read(reinterpret_cast<char*>(code.data()),size)) throw std::runtime_error("invalid input");
    CompilerMSL c(std::move(code)); auto o=c.get_msl_options();
    o.platform=CompilerMSL::Options::macOS; o.msl_version=CompilerMSL::Options::make_msl_version(4,0);
    o.argument_buffers=true; o.argument_buffers_tier=CompilerMSL::Options::ArgumentBuffersTier::Tier2;
    o.runtime_array_rich_descriptor=true; o.robust_buffer_access2=true; o.robust_image_access2=true; o.null_descriptor=true;
    o.typed_root_pointers=std::string(argv[3])=="1"; o.buffer_size_buffer_index=30;
    if (argc==5) {
        // The profiling recipe mirrors these two explicit options in the
        // live compute pipeline path; the original four-argument CLI is kept.
        o.texture_buffer_native=true;
        o.coherent_buffer_atomics=true;
    }
    c.set_msl_options(o); auto common=c.get_common_options(); common.vertex.flip_vert_y=true;
    // Diagnostic only: preserve the existing default and compare the standard
    // SPIRV-Cross temporary-expression policy without removing robust guards.
    common.force_temporary = argc==5 && std::string(argv[4])=="1";
    c.set_common_options(common);
    auto stage=c.get_execution_model();
    MSLResourceBinding pc; pc.stage=stage; pc.desc_set=kPushConstDescSet; pc.binding=kPushConstBinding; pc.msl_buffer=8;
    c.add_msl_resource_binding(pc);
    for(uint32_t set=0;set<7;set++) {
        MSLResourceBinding rb; rb.stage=stage; rb.desc_set=set; rb.binding=kArgumentBufferBinding; rb.msl_buffer=set;
        c.add_msl_resource_binding(rb);
    }
    std::string msl=c.compile(); std::ofstream out(argv[2]); out<<msl;
    size_t count=0,pos=0; while((pos=msl.find("address-only 64-bit root",pos))!=std::string::npos) { count++;pos++; }
    std::cout<<"nativeTypedRootMembers="<<count<<" stage="<<int(stage)<<" MSLbytes="<<msl.size()<<"\n";
    return 0;
} catch(const std::exception&e) { std::cerr<<e.what()<<"\n";return 1; } }
