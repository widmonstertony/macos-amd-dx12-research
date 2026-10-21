// Dispatch/fill/dispatch control: reproduces upstream #2822 helper binding loss.
// Initial #2805 barrier hypothesis did not explain this one-encoder failure.
// Finite work only; every host wait has a two-second bound. No game resources.
#include "gpu_common.hpp"
#include <chrono>
int main(int argc,char**argv) {
 if(argc!=4)return 2;
 std::ofstream report(argv[2]);
 try {
  unsigned rounds=std::stoul(argv[3]);if(!rounds||rounds>128)return 3;
  GPU g(false);constexpr uint32_t words=1024,budget=4096;
  Buf payload=g.buffer(words*4,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
  Buf output=g.buffer(words*4,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
  Buf scratch=g.buffer(words*4,VK_BUFFER_USAGE_TRANSFER_DST_BIT);
  std::ifstream input(argv[1],std::ios::binary|std::ios::ate);auto bytes=input.tellg();
  if(bytes<=0||bytes%4)throw std::runtime_error("Invalid owned SPIR-V file");
  std::vector<uint32_t> code(size_t(bytes)/4);input.seekg(0);input.read((char*)code.data(),bytes);
  VkShaderModuleCreateInfo sm{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};sm.codeSize=bytes;sm.pCode=code.data();VkShaderModule shader;CHECK(vkCreateShaderModule(g.device,&sm,nullptr,&shader));
  VkDescriptorSetLayoutBinding bindings[2]={{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr}};
  VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};li.bindingCount=2;li.pBindings=bindings;VkDescriptorSetLayout setLayout;CHECK(vkCreateDescriptorSetLayout(g.device,&li,nullptr,&setLayout));
  VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT,0,16};VkPipelineLayoutCreateInfo pli{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pli.setLayoutCount=1;pli.pSetLayouts=&setLayout;pli.pushConstantRangeCount=1;pli.pPushConstantRanges=&push;VkPipelineLayout layout;CHECK(vkCreatePipelineLayout(g.device,&pli,nullptr,&layout));
  VkComputePipelineCreateInfo pi{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};pi.layout=layout;pi.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};pi.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;pi.stage.module=shader;pi.stage.pName="main";VkPipeline pipeline;CHECK(vkCreateComputePipelines(g.device,VK_NULL_HANDLE,1,&pi,nullptr,&pipeline));
  VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2};VkDescriptorPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};poolInfo.maxSets=1;poolInfo.poolSizeCount=1;poolInfo.pPoolSizes=&size;VkDescriptorPool descriptors;CHECK(vkCreateDescriptorPool(g.device,&poolInfo,nullptr,&descriptors));VkDescriptorSetAllocateInfo sa{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};sa.descriptorPool=descriptors;sa.descriptorSetCount=1;sa.pSetLayouts=&setLayout;VkDescriptorSet set;CHECK(vkAllocateDescriptorSets(g.device,&sa,&set));
  VkDescriptorBufferInfo infos[2]={{payload.b,0,payload.size},{output.b,0,output.size}};VkWriteDescriptorSet writes[2]{};
  for(unsigned i=0;i<2;++i){writes[i]={VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};writes[i].dstSet=set;writes[i].dstBinding=i;writes[i].descriptorCount=1;writes[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;writes[i].pBufferInfo=&infos[i];}vkUpdateDescriptorSets(g.device,2,writes,0,nullptr);
  VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};ca.commandPool=g.pool;ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;ca.commandBufferCount=1;VkCommandBuffer cb;CHECK(vkAllocateCommandBuffers(g.device,&ca,&cb));VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};VkFence fence;CHECK(vkCreateFence(g.device,&fi,nullptr,&fence));
  uint32_t multiplier=1,addition=0;for(unsigned i=0;i<budget;++i){multiplier*=1664525u;addition=addition*1664525u+1013904223u;}
  uint64_t bad[3]={},badOutput[3]={},badScratch[3]={},checked[3]={};uint32_t firstActual[3]={},firstExpected[3]={};auto started=std::chrono::steady_clock::now();
  for(unsigned arm=0;arm<3;++arm)for(unsigned round=0;round<rounds;++round){
   memset(payload.p,0xcd,payload.size);memset(output.p,0xef,output.size);memset(scratch.p,0,scratch.size);
   CHECK(vkResetCommandPool(g.device,g.pool,0));CHECK(vkResetFences(g.device,1,&fence));VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;CHECK(vkBeginCommandBuffer(cb,&begin));
   vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,layout,0,1,&set,0,nullptr);
   uint32_t p[4]={0,0x12345678u+round,budget,words};vkCmdPushConstants(cb,layout,VK_SHADER_STAGE_COMPUTE_BIT,0,16,p);vkCmdDispatch(cb,words/64,1,1);
   uint32_t fill=arm==1?0xabcdabcdu:0x99999999u;
   if(arm)vkCmdFillBuffer(cb,scratch.b,0,scratch.size,fill);
   if(arm && getenv("GPU_REBIND_AFTER_HELPER"))vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,layout,0,1,&set,0,nullptr);
   VkMemoryBarrier dependency{VK_STRUCTURE_TYPE_MEMORY_BARRIER};dependency.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;dependency.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
   vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&dependency,0,nullptr,0,nullptr);
   p[0]=1;vkCmdPushConstants(cb,layout,VK_SHADER_STAGE_COMPUTE_BIT,0,16,p);vkCmdDispatch(cb,words/64,1,1);
   VkMemoryBarrier host{VK_STRUCTURE_TYPE_MEMORY_BARRIER};host.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT|VK_ACCESS_TRANSFER_WRITE_BIT;host.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
   vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT|VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&host,0,nullptr,0,nullptr);CHECK(vkEndCommandBuffer(cb));
   VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&cb;CHECK(vkQueueSubmit(g.queue,1,&submit,fence));VkResult waited=vkWaitForFences(g.device,1,&fence,VK_TRUE,2000000000ull);
   if(waited!=VK_SUCCESS){report<<"{\"passed\":false,\"waitResult\":"<<waited<<",\"arm\":"<<arm<<",\"round\":"<<round<<"}\n";report.flush();std::_Exit(5);}
   for(unsigned i=0;i<words;++i){uint32_t expected=multiplier*(i^p[1])+addition;++checked[arm];if(((uint32_t*)output.p)[i]!=expected){++bad[arm];if(!badOutput[arm]++){firstActual[arm]=((uint32_t*)output.p)[i];firstExpected[arm]=expected;}}if(arm){++checked[arm];if(((uint32_t*)scratch.p)[i]!=fill){++bad[arm];++badScratch[arm];}}}
  }
  auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
  report<<"{\"passed\":"<<((bad[0]+bad[1]+bad[2])?"false":"true")<<",\"roundsPerArm\":"<<rounds<<",\"milliseconds\":"<<ms<<",\"arms\":[";
  for(unsigned i=0;i<3;++i){if(i)report<<",";report<<"{\"kind\":\""<<(i==0?"dispatch-only":i==1?"compute-fill-gap":"byte-pattern-fill-gap")<<"\",\"checkedWords\":"<<checked[i]<<",\"mismatches\":"<<bad[i]<<",\"outputMismatches\":"<<badOutput[i]<<",\"scratchMismatches\":"<<badScratch[i]<<",\"firstActual\":"<<firstActual[i]<<",\"firstExpected\":"<<firstExpected[i]<<"}";}report<<"]}\n";
  return bad[0]+bad[1]+bad[2]?6:0;
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";report<<"{\"passed\":false}\n";return 1;}
}
