#include "gpu_common.hpp"
int main(int argc,char** argv){try{
 if(argc<3)throw std::runtime_error("reject_probe result.json unsupported-modules...");GPU g;
 VkDescriptorSetLayoutBinding binding{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr};VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};li.bindingCount=1;li.pBindings=&binding;VkDescriptorSetLayout layout;CHECK(vkCreateDescriptorSetLayout(g.device,&li,nullptr,&layout));
 VkPushConstantRange pc{VK_SHADER_STAGE_COMPUTE_BIT,0,16};VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pl.setLayoutCount=1;pl.pSetLayouts=&layout;pl.pushConstantRangeCount=1;pl.pPushConstantRanges=&pc;VkPipelineLayout pipelineLayout;CHECK(vkCreatePipelineLayout(g.device,&pl,nullptr,&pipelineLayout));unsigned refused=0;
 for(int i=1;i<argc-1;i++){
  std::ifstream f(argv[i],std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("Missing unsupported fixture");size_t size=size_t(f.tellg());f.seekg(0);std::vector<uint32_t> code(size/4);f.read(reinterpret_cast<char*>(code.data()),size);VkShaderModuleCreateInfo mi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};mi.codeSize=size;mi.pCode=code.data();VkShaderModule module;CHECK(vkCreateShaderModule(g.device,&mi,nullptr,&module));
  VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};ci.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=module;ci.stage.pName="main";ci.layout=pipelineLayout;VkPipeline pipeline=VK_NULL_HANDLE;VkResult r=vkCreateComputePipelines(g.device,VK_NULL_HANDLE,1,&ci,nullptr,&pipeline);std::cout<<"REFUSAL "<<argv[i]<<" result="<<r<<" nullPipeline="<<(pipeline==VK_NULL_HANDLE)<<"\n";if(r!=VK_ERROR_FEATURE_NOT_PRESENT||pipeline)throw std::runtime_error("Unsupported pipeline accepted or returned wrong failure");++refused;vkDestroyShaderModule(g.device,module,nullptr);
 }
 // Research mode explicitly rejects graphics pipelines rather than silently
 // executing an unguarded graphics path.
 VkGraphicsPipelineCreateInfo graphics{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};graphics.layout=pipelineLayout;VkPipeline pipeline=VK_NULL_HANDLE;VkResult r=vkCreateGraphicsPipelines(g.device,VK_NULL_HANDLE,1,&graphics,nullptr,&pipeline);if(r!=VK_ERROR_FEATURE_NOT_PRESENT||pipeline)throw std::runtime_error("Graphics bypassed compute-only restriction");++refused;
 std::ofstream out(argv[argc-1]);out<<"{\"passed\":true,\"expectedRefusals\":"<<refused<<",\"unprotectedFallbackUsed\":false}\n";vkDestroyPipelineLayout(g.device,pipelineLayout,nullptr);vkDestroyDescriptorSetLayout(g.device,layout,nullptr);return 0;
 }catch(const std::exception& e){std::cerr<<"ERROR "<<e.what()<<"\n";return 1;}}
