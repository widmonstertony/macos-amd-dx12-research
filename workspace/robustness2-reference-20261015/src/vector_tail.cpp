#include "gpu_common.hpp"
int main(int argc,char**argv){try{
 if(argc!=3)throw std::runtime_error("vector_tail spv-directory results.json");
 GPU g;uint64_t checks=0,mismatches=0,scenarios=0;
 VkDescriptorSetLayoutBinding binding[]={{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr}};
 VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};li.bindingCount=2;li.pBindings=binding;VkDescriptorSetLayout layout;CHECK(vkCreateDescriptorSetLayout(g.device,&li,nullptr,&layout));
 VkPushConstantRange pc{VK_SHADER_STAGE_COMPUTE_BIT,0,12};VkPipelineLayoutCreateInfo pi{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pi.setLayoutCount=1;pi.pSetLayouts=&layout;pi.pushConstantRangeCount=1;pi.pPushConstantRanges=&pc;VkPipelineLayout pipelineLayout;CHECK(vkCreatePipelineLayout(g.device,&pi,nullptr,&pipelineLayout));
 VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2};VkDescriptorPoolCreateInfo dpi{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};dpi.maxSets=1;dpi.poolSizeCount=1;dpi.pPoolSizes=&size;VkDescriptorPool pool;CHECK(vkCreateDescriptorPool(g.device,&dpi,nullptr,&pool));VkDescriptorSetAllocateInfo ai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};ai.descriptorPool=pool;ai.descriptorSetCount=1;ai.pSetLayouts=&layout;VkDescriptorSet ds;CHECK(vkAllocateDescriptorSets(g.device,&ai,&ds));
 Buf input=g.buffer(512,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT),output=g.buffer(64,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
 for(unsigned width:{2,3,4}){
  std::ifstream f(std::string(argv[1])+"/vector"+std::to_string(width)+".spv",std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("Missing shader");size_t length=size_t(f.tellg());f.seekg(0);std::vector<uint32_t> code(length/4);f.read(reinterpret_cast<char*>(code.data()),length);VkShaderModuleCreateInfo mi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};mi.codeSize=length;mi.pCode=code.data();VkShaderModule module;CHECK(vkCreateShaderModule(g.device,&mi,nullptr,&module));
  VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};ci.layout=pipelineLayout;ci.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=module;ci.stage.pName="main";VkPipeline pipeline;CHECK(vkCreateComputePipelines(g.device,VK_NULL_HANDLE,1,&ci,nullptr,&pipeline));vkDestroyShaderModule(g.device,module,nullptr);
  unsigned stride=width==2?8:16;
  for(unsigned range:{1,3,4,7,8,12,15,16,17,20,24,28,31,32,36,48,52,64})for(unsigned index:{0,1,2,5})for(unsigned op=0;op<4;op++){
   std::array<uint32_t,128> expected;for(unsigned i=0;i<expected.size();i++)expected[i]=1000+i;memcpy(input.p,expected.data(),512);std::fill_n(static_cast<uint32_t*>(output.p),16,0xcdcdcdcd);std::array<uint32_t,16> result;result.fill(0xcdcdcdcd);std::fill_n(result.begin(),4,0);
   unsigned component=width-1;for(unsigned c=0;c<width;c++){
    unsigned byte=index*stride+c*4;bool inside=byte+4<=range;unsigned word=4+byte/4;
    if(op==0&&inside)result[c]=expected[word];if(op==1&&inside)expected[word]=900+c;
    if(op==2&&c==component&&inside)result[0]=expected[word];if(op==3&&c==component&&inside)expected[word]=901;
   }
   VkDescriptorBufferInfo bufs[]={{input.b,16,range},{output.b,0,64}};VkWriteDescriptorSet writes[2]{};for(unsigned i=0;i<2;i++){writes[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;writes[i].dstSet=ds;writes[i].dstBinding=i;writes[i].descriptorCount=1;writes[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;writes[i].pBufferInfo=&bufs[i];}vkUpdateDescriptorSets(g.device,2,writes,0,nullptr);
   g.run([&](VkCommandBuffer cb){VkMemoryBarrier b{VK_STRUCTURE_TYPE_MEMORY_BARRIER};b.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;b.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&b,0,nullptr,0,nullptr);vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipelineLayout,0,1,&ds,0,nullptr);uint32_t params[]={index,op,component};vkCmdPushConstants(cb,pipelineLayout,VK_SHADER_STAGE_COMPUTE_BIT,0,12,params);vkCmdDispatch(cb,1,1,1);b.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;b.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&b,0,nullptr,0,nullptr);});
   for(unsigned i=0;i<128;i++){checks++;if(static_cast<uint32_t*>(input.p)[i]!=expected[i])mismatches++;}for(unsigned i=0;i<16;i++){checks++;if(static_cast<uint32_t*>(output.p)[i]!=result[i]){if(mismatches<6)std::cerr<<"Mismatch width="<<width<<" range="<<range<<" index="<<index<<" op="<<op<<" word="<<i<<" got="<<static_cast<uint32_t*>(output.p)[i]<<" expected="<<result[i]<<"\n";mismatches++;}}scenarios++;
  }
  vkDestroyPipeline(g.device,pipeline,nullptr);std::cout<<"WIDTH "<<width<<" scenarios="<<scenarios<<" mismatches="<<mismatches<<"\n";
 }
 g.destroy(input);g.destroy(output);vkDestroyDescriptorPool(g.device,pool,nullptr);vkDestroyPipelineLayout(g.device,pipelineLayout,nullptr);vkDestroyDescriptorSetLayout(g.device,layout,nullptr);
 std::ofstream out(argv[2]);out<<"{\"scenarios\":"<<scenarios<<",\"checkedWords\":"<<checks<<",\"mismatches\":"<<mismatches<<",\"passed\":"<<(mismatches?"false":"true")<<"}\n";
 return mismatches?1:0;
}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 2;}}
