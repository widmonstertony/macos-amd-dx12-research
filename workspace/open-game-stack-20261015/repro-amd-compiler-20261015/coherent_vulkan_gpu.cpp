#include "gpu_common.hpp"
int main(int argc,char**argv) { try {
 if(argc!=4)throw std::runtime_error("coherent_vulkan_gpu uint.spv int.spv result.json");
 GPU g; constexpr uint32_t count=65536, poison=0xcd37a591;
 VkDescriptorSetLayoutBinding bindings[]={{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr}};
 VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};li.bindingCount=2;li.pBindings=bindings;VkDescriptorSetLayout layout;CHECK(vkCreateDescriptorSetLayout(g.device,&li,nullptr,&layout));
 VkPushConstantRange pc{VK_SHADER_STAGE_COMPUTE_BIT,0,16};VkPipelineLayoutCreateInfo pli{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pli.setLayoutCount=1;pli.pSetLayouts=&layout;pli.pushConstantRangeCount=1;pli.pPushConstantRanges=&pc;VkPipelineLayout pl;CHECK(vkCreatePipelineLayout(g.device,&pli,nullptr,&pl));
 VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2};VkDescriptorPoolCreateInfo dpi{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};dpi.maxSets=1;dpi.poolSizeCount=1;dpi.pPoolSizes=&size;VkDescriptorPool pool;CHECK(vkCreateDescriptorPool(g.device,&dpi,nullptr,&pool));VkDescriptorSetAllocateInfo dai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};dai.descriptorPool=pool;dai.descriptorSetCount=1;dai.pSetLayouts=&layout;VkDescriptorSet ds;CHECK(vkAllocateDescriptorSets(g.device,&dai,&ds));
 Buf data=g.buffer((count+8)*4,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT), output=g.buffer(count*4,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
 uint64_t checks=0,mismatches=0,scenarios=0;
 auto pattern=[](uint32_t i){return (i*1664525u+1013904223u)^(i<<17u);};
 for(unsigned sign=0;sign<2;sign++) {
  std::ifstream f(argv[1+sign],std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("shader absent");size_t bytes=size_t(f.tellg());f.seekg(0);std::vector<uint32_t> code(bytes/4);f.read((char*)code.data(),bytes);VkShaderModuleCreateInfo mi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};mi.codeSize=bytes;mi.pCode=code.data();VkShaderModule module;CHECK(vkCreateShaderModule(g.device,&mi,nullptr,&module));
  VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};ci.layout=pl;ci.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=module;ci.stage.pName="main";VkPipeline pipeline;CHECK(vkCreateComputePipelines(g.device,VK_NULL_HANDLE,1,&ci,nullptr,&pipeline));
  auto run=[&](bool null,uint32_t range,uint32_t mode,uint32_t index){
   std::vector<uint32_t> expectedData(count+8,poison),expectedOutput(count,poison);
   for(uint32_t i=0;i<count;i++)expectedData[i+4]=pattern(i);
   if(mode==0)std::fill(expectedData.begin()+4,expectedData.begin()+4+count,poison);
   memcpy(data.p,expectedData.data(),data.size);memcpy(output.p,expectedOutput.data(),output.size);
   if(mode==0){if(!null)for(uint32_t i=0;i<count;i++)expectedData[i+4]=pattern(i);for(uint32_t i=0;i<count;i++)expectedOutput[i]=null?0:pattern((i*40503u)&(count-1));}
   if(mode==2&&!null&&uint64_t(index)*4+4<=range)expectedData[index+4]=0xdead1327;
   if(mode==3)expectedOutput[0]=!null&&uint64_t(index)*4+4<=range?expectedData[index+4]:0;
   VkDescriptorBufferInfo infos[]={{null?VK_NULL_HANDLE:data.b,16,range},{output.b,0,output.size}};VkWriteDescriptorSet writes[2]{};for(unsigned i=0;i<2;i++){writes[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;writes[i].dstSet=ds;writes[i].dstBinding=i;writes[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;writes[i].descriptorCount=1;writes[i].pBufferInfo=&infos[i];}vkUpdateDescriptorSets(g.device,2,writes,0,nullptr);
   g.run([&](VkCommandBuffer cb){VkMemoryBarrier mb{VK_STRUCTURE_TYPE_MEMORY_BARRIER};mb.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;mb.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&mb,0,nullptr,0,nullptr);vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pl,0,1,&ds,0,nullptr);uint32_t params[]={mode,index,count,0xdead1327};vkCmdPushConstants(cb,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,16,params);vkCmdDispatch(cb,mode==0?(count+63)/64:1,1,1);
    if(mode==0){mb.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;mb.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&mb,0,nullptr,0,nullptr);params[0]=1;vkCmdPushConstants(cb,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,16,params);vkCmdDispatch(cb,(count+63)/64,1,1);}
    mb.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;mb.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&mb,0,nullptr,0,nullptr);});
   for(size_t i=0;i<expectedData.size();i++){checks++;if(((uint32_t*)data.p)[i]!=expectedData[i])mismatches++;}for(size_t i=0;i<expectedOutput.size();i++){checks++;if(((uint32_t*)output.p)[i]!=expectedOutput[i]){if(mismatches<5)std::cerr<<"mismatch sign="<<sign<<" null="<<null<<" range="<<range<<" mode="<<mode<<" index="<<index<<" word="<<i<<"\n";mismatches++;}}scenarios++;
  };
  for(bool null:{false,true}){run(null,count*4,0,0);for(uint32_t range:{4u,12u,20u})for(uint32_t index:{0u,1u,4u,5u,0xffffffffu})for(uint32_t mode:{2u,3u})run(null,range,mode,index);}
  vkDestroyPipeline(g.device,pipeline,nullptr);vkDestroyShaderModule(g.device,module,nullptr);
 }
 std::ofstream report(argv[3]);report<<"{\"passed\":"<<(mismatches?"false":"true")<<",\"scenarios\":"<<scenarios<<",\"checkedWords\":"<<checks<<",\"mismatches\":"<<mismatches<<",\"signedAndUnsigned\":true,\"nullAndBoundsGuards\":true}\n";
 std::cout<<"scenarios="<<scenarios<<" checkedWords="<<checks<<" mismatches="<<mismatches<<"\n";
 g.destroy(data);g.destroy(output);vkDestroyDescriptorPool(g.device,pool,nullptr);vkDestroyPipelineLayout(g.device,pl,nullptr);vkDestroyDescriptorSetLayout(g.device,layout,nullptr);return mismatches?5:0;
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 2;}}
