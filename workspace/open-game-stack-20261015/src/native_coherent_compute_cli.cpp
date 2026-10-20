#include "spirv_msl.hpp"
#include <fstream>
#include <iostream>
#include <vector>
#include <cstdlib>
using namespace MVK_spirv_cross;
int main(int argc,char**argv) { try {
 if(argc!=7)throw std::runtime_error("input.spv options.bin bindings.tsv output.metal enabled(0|1) expected-options-size");
 std::ifstream in(argv[1],std::ios::binary|std::ios::ate);size_t bytes=size_t(in.tellg());in.seekg(0);std::vector<uint32_t> code(bytes/4);if(bytes%4||!in.read((char*)code.data(),bytes))throw std::runtime_error("Invalid SPIR-V input");
 CompilerMSL compiler(std::move(code));CompilerMSL::Options options;
 if(sizeof(options)!=strtoul(argv[6],nullptr,10))throw std::runtime_error("Captured configuration layout mismatch");
 std::ifstream config(argv[2],std::ios::binary);if(!config.read((char*)&options,sizeof(options)))throw std::runtime_error("Configuration absent");
 options.coherent_buffer_atomics=std::string(argv[5])=="1";compiler.set_msl_options(options);
 auto reflected=compiler.get_shader_resources();
 std::ifstream bindings(argv[3]);uint32_t set,binding,count,buffer;
 while(bindings>>set>>binding>>count>>buffer){MSLResourceBinding resource;resource.stage=compiler.get_execution_model();resource.desc_set=set;resource.binding=binding;resource.count=count;resource.msl_buffer=buffer;
  // The old trace omitted basetype. Recover live bindings from SPIR-V; unused
  // padding defaults to pointer slots. Byte-exact disabled-output comparison is
  // required before treating this reconstructed layout as the game configuration.
  resource.basetype=SPIRType::Struct;
  auto match=[&](const auto& list){for(auto&r:list)if(compiler.get_decoration(r.id,spv::DecorationDescriptorSet)==set&&compiler.get_decoration(r.id,spv::DecorationBinding)==binding)resource.basetype=compiler.get_type(r.base_type_id).basetype;};
  match(reflected.uniform_buffers);match(reflected.storage_buffers);match(reflected.separate_images);match(reflected.storage_images);match(reflected.separate_samplers);match(reflected.sampled_images);
  compiler.add_msl_resource_binding(resource);}
 auto source=compiler.compile();std::ofstream out(argv[4]);out<<source;
 std::cout<<"MSLbytes="<<source.size()<<" workaround="<<options.coherent_buffer_atomics<<"\n";return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 2;}}
