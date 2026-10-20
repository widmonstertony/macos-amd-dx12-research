#include "spirv_msl.hpp"
#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>
using namespace MVK_spirv_cross;
int main(int argc,char**argv) { try {
    if(argc!=4) throw std::runtime_error("native_typed_root_cli input.spv output.metal enabled(0|1)");
    std::ifstream in(argv[1],std::ios::binary|std::ios::ate);
    if(!in) throw std::runtime_error("input unavailable");
    size_t size=size_t(in.tellg()); in.seekg(0); std::vector<uint32_t> code(size/4);
    if(size%4||!in.read(reinterpret_cast<char*>(code.data()),size)) throw std::runtime_error("invalid input");
    CompilerMSL c(std::move(code)); auto o=c.get_msl_options();
    o.platform=CompilerMSL::Options::macOS; o.msl_version=CompilerMSL::Options::make_msl_version(4,0);
    o.argument_buffers=true; o.argument_buffers_tier=CompilerMSL::Options::ArgumentBuffersTier::Tier2;
    o.runtime_array_rich_descriptor=true; o.robust_buffer_access2=true; o.robust_image_access2=true; o.null_descriptor=true;
    o.typed_root_pointers=std::string(argv[3])=="1"; o.buffer_size_buffer_index=18; o.for_mesh_pipeline=true; o.draw_info_index=17; o.input_primitive_type=CompilerMSL::Options::PrimitiveTopology::Triangles;
    c.set_msl_options(o); auto common=c.get_common_options(); common.vertex.flip_vert_y=true; c.set_common_options(common);
    auto stage=c.get_execution_model();
    MSLResourceBinding pc; pc.stage=stage; pc.desc_set=kPushConstDescSet; pc.binding=kPushConstBinding; pc.msl_buffer=8;
    c.add_msl_resource_binding(pc);
    for(uint32_t set=0;set<7;set++) {
        MSLResourceBinding rb; rb.stage=stage; rb.desc_set=set; rb.binding=kArgumentBufferBinding; rb.msl_buffer=set;
        c.add_msl_resource_binding(rb);
    }
    struct Input {unsigned location,binding,offset,size;MSLShaderVariableFormat format;bool normalized;};
    Input inputs[]={{0,30,0,3,MSL_SHADER_VARIABLE_FORMAT_FLOAT,false},
        {1,29,0,4,MSL_SHADER_VARIABLE_FORMAT_INT8,true},{2,29,4,4,MSL_SHADER_VARIABLE_FORMAT_INT8,true},
        {7,28,0,2,MSL_SHADER_VARIABLE_FORMAT_HALF,false},{8,28,4,2,MSL_SHADER_VARIABLE_FORMAT_HALF,false},
        {11,27,0,4,MSL_SHADER_VARIABLE_FORMAT_UINT16,false},
        {4,26,0,4,MSL_SHADER_VARIABLE_FORMAT_UINT8,false},{3,26,0,4,MSL_SHADER_VARIABLE_FORMAT_UINT8,false},
        {6,26,4,4,MSL_SHADER_VARIABLE_FORMAT_UINT8,true},{5,26,4,4,MSL_SHADER_VARIABLE_FORMAT_UINT8,true},
        {10,25,0,3,MSL_SHADER_VARIABLE_FORMAT_FLOAT,false},{9,25,0,3,MSL_SHADER_VARIABLE_FORMAT_FLOAT,false}};
    for(auto i:inputs){MSLShaderInterfaceVariable v;v.location=i.location;v.binding=i.binding;v.offset=i.offset;v.vecsize=i.size;v.format=i.format;v.normalized=i.normalized;c.add_msl_shader_input(v);}
    std::string msl=c.compile(); std::ofstream out(argv[2]); out<<msl;
    size_t count=0,pos=0; while((pos=msl.find("address-only 64-bit root",pos))!=std::string::npos) { count++;pos++; }
    std::cout<<"nativeTypedRootMembers="<<count<<" stage="<<int(stage)<<" MSLbytes="<<msl.size()<<"\n";
    return 0;
} catch(const std::exception&e) { std::cerr<<e.what()<<"\n";return 1; } }
