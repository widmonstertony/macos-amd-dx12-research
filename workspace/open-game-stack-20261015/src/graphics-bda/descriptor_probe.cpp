#include "gpu_common.hpp"

int main(int argc,char** argv){try{
 if(argc!=3)throw std::runtime_error("array_probe lowered.spv results.json");
 GPU g;
 uint32_t allocated=getenv("R2_VARIABLE_COUNT")?uint32_t(std::stoul(getenv("R2_VARIABLE_COUNT"))):3;bool variable=getenv("R2_VARIABLE_COUNT")!=nullptr;if(allocated<1||allocated>3)throw std::runtime_error("Invalid variable test count");
 VkDescriptorSetLayoutBinding bindings[]={{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,3,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{2,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr}};
 VkDescriptorBindingFlags flags[]={VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT|VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT,0,0};VkDescriptorSetLayoutBindingFlagsCreateInfo flagInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO};flagInfo.bindingCount=3;flagInfo.pBindingFlags=flags;if(variable)bindings[0].binding=8;
 VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};li.pNext=variable?&flagInfo:nullptr;li.bindingCount=3;li.pBindings=bindings;VkDescriptorSetLayout layout;CHECK(vkCreateDescriptorSetLayout(g.device,&li,nullptr,&layout));
 VkPushConstantRange range{VK_SHADER_STAGE_COMPUTE_BIT,0,4};VkPipelineLayoutCreateInfo pi{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pi.setLayoutCount=1;pi.pSetLayouts=&layout;pi.pushConstantRangeCount=1;pi.pPushConstantRanges=&range;VkPipelineLayout pl;CHECK(vkCreatePipelineLayout(g.device,&pi,nullptr,&pl));
 std::ifstream f(argv[1],std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("Missing shader");size_t sz=size_t(f.tellg());f.seekg(0);std::vector<uint32_t> code(sz/4);f.read(reinterpret_cast<char*>(code.data()),sz);VkShaderModuleCreateInfo smi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};smi.codeSize=sz;smi.pCode=code.data();VkShaderModule sm;CHECK(vkCreateShaderModule(g.device,&smi,nullptr,&sm));
 VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};ci.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=sm;ci.stage.pName="main";ci.layout=pl;VkPipeline pipe;CHECK(vkCreateComputePipelines(g.device,VK_NULL_HANDLE,1,&ci,nullptr,&pipe));
 VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,5};VkDescriptorPoolCreateInfo dpi{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};dpi.poolSizeCount=1;dpi.pPoolSizes=&size;dpi.maxSets=1;VkDescriptorPool pool;CHECK(vkCreateDescriptorPool(g.device,&dpi,nullptr,&pool));VkDescriptorSetAllocateInfo dai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};dai.descriptorPool=pool;dai.descriptorSetCount=1;dai.pSetLayouts=&layout;VkDescriptorSetVariableDescriptorCountAllocateInfo variableInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO};variableInfo.descriptorSetCount=1;variableInfo.pDescriptorCounts=&allocated;dai.pNext=variable?&variableInfo:nullptr;VkDescriptorSet ds;CHECK(vkAllocateDescriptorSets(g.device,&dai,&ds));
 constexpr auto usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_TRANSFER_SRC_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT;
 Buf a=g.buffer(256,usage),b=g.buffer(256,usage),dummy=g.buffer(256,usage),inputs=g.buffer(65536,usage),out=g.buffer(65536,usage);
 uint64_t mismatches=0,checks=0;unsigned scenarios=0;auto fail=[&](const std::string& s){if(mismatches<12)std::cerr<<"MISMATCH "<<s<<"\n";++mismatches;};
 auto run=[&](std::string name,const std::vector<Case>& cases,bool allNull,bool atomicStress){
  std::vector<uint32_t> ea(64),eb(64),ed(64,0xa5a55a5a);for(uint32_t i=0;i<64;i++){ea[i]=100+i;eb[i]=200+i;}
  std::memcpy(a.p,ea.data(),256);std::memcpy(b.p,eb.data(),256);std::memcpy(dummy.p,ed.data(),256);std::memcpy(inputs.p,cases.data(),cases.size()*16);std::memset(out.p,0xcd,out.size);
  VkDescriptorBufferInfo arrayInfo[]={VkDescriptorBufferInfo{allNull?VK_NULL_HANDLE:a.b,16,20},VkDescriptorBufferInfo{VK_NULL_HANDLE,0,VK_WHOLE_SIZE},VkDescriptorBufferInfo{allNull?VK_NULL_HANDLE:b.b,32,12}};
  VkDescriptorBufferInfo other[]={VkDescriptorBufferInfo{inputs.b,0,cases.size()*16},VkDescriptorBufferInfo{out.b,0,cases.size()*4}};
  VkWriteDescriptorSet w[3]{};for(int i=0;i<3;i++){w[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;w[i].dstSet=ds;w[i].dstBinding=i?i:variable?8:0;w[i].descriptorCount=i?1:allocated;w[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;w[i].pBufferInfo=i?&other[i-1]:arrayInfo;}vkUpdateDescriptorSets(g.device,3,w,0,nullptr);
  std::vector<uint32_t> expected(cases.size(),0);std::map<int,std::vector<uint32_t>> returns;
  for(size_t i=0;i<cases.size();i++){auto c=cases[i];int descriptor=c.op,index=c.x,op=c.y;bool valid=!allNull && (descriptor==0||(descriptor==2&&allocated==3)) && index>=0 && index<(descriptor==0?5:3);auto& e=descriptor==0?ea:eb;size_t offset=descriptor==0?4:8;
   if(op==0){if(valid)expected[i]=e[offset+index];}
   else if(op==1){if(valid)e[offset+index]=uint32_t(c.z);expected[i]=1;}
   else if(op==2 && valid){expected[i]=e[offset+index];e[offset+index]+=uint32_t(c.z);}
   else if(op==3 && !allNull && (descriptor==0||(descriptor==2&&allocated==3)))expected[i]=descriptor==0?5:3;
  }
  g.run([&](VkCommandBuffer cb){VkMemoryBarrier mb{VK_STRUCTURE_TYPE_MEMORY_BARRIER};mb.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;mb.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&mb,0,nullptr,0,nullptr);vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pl,0,1,&ds,0,nullptr);uint32_t count=uint32_t(cases.size());vkCmdPushConstants(cb,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,4,&count);vkCmdDispatch(cb,(count+31)/32,1,1);mb.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;mb.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&mb,0,nullptr,0,nullptr);});
  auto actual=static_cast<uint32_t*>(out.p);
  for(size_t i=0;i<cases.size();i++){++checks;auto c=cases[i];if(atomicStress&&!allNull&&(c.op==0||(c.op==2&&allocated==3))&&c.x==0&&c.y==2)returns[c.op].push_back(actual[i]);else if(actual[i]!=expected[i])fail(name+" result="+std::to_string(i)+" got="+std::to_string(actual[i])+" expected="+std::to_string(expected[i]));}
  for(auto& [d,v]:returns){std::sort(v.begin(),v.end());for(size_t i=0;i<v.size();i++)if(v[i]!=(d==0?104:208)+i)fail(name+" atomic ordering");}
  for(auto [buf,exp]:std::vector<std::pair<Buf*,std::vector<uint32_t>*>>{{&a,&ea},{&b,&eb},{&dummy,&ed}})for(size_t i=0;i<64;i++){++checks;if(static_cast<uint32_t*>(buf->p)[i]!=(*exp)[i])fail(name+" allocation/dummy witness word="+std::to_string(i));}
  for(size_t i=cases.size();i<out.size/4;i++){++checks;if(actual[i]!=0xcdcdcdcd)fail(name+" output padding");}
  ++scenarios;std::cout<<"CASE "<<name<<" allocated="<<allocated<<" operations="<<cases.size()<<" nullDescriptors="<<(allNull?3:1)<<" mismatches="<<mismatches<<"\n";
 };
 std::vector<Case> reads;for(int d=0;d<int(allocated);d++){for(int i:{-1,0,2,3,4,5,0x40000000,0x7fffffff})reads.push_back({d,i,0,0});reads.push_back({d,0,3,0});}run("mixed-real-null-dynamic-descriptor-reads",reads,false,false);run("all-null-dynamic-descriptor-reads",reads,true,false);
 std::vector<Case> writes;for(int d=0;d<int(allocated);d++)for(int i:{-1,1,3,5,0x40000000,0x7fffffff})writes.push_back({d,i,1,int32_t(uint32_t(700)+uint32_t(d))});run("mixed-real-null-dynamic-descriptor-writes",writes,false,false);run("all-null-dynamic-descriptor-writes",writes,true,false);
 std::vector<Case> stress;for(int i=0;i<1024;i++)stress.push_back({i%int(allocated),i%7?0:5,2,1});run("mixed-real-null-dynamic-descriptor-atomics",stress,false,true);run("all-null-dynamic-descriptor-atomics",stress,true,true);
 driverWitness(1,6);
 std::ofstream result(argv[2]);result<<"{\"passed\":"<<(mismatches?"false":"true")<<",\"device\":\"AMD Radeon Pro 5600M\",\"scenarios\":"<<scenarios<<",\"checkedWords\":"<<checks<<",\"mismatches\":"<<mismatches<<",\"nativeFeatureFlagsModified\":false}\n";
 for(auto p:{&a,&b,&dummy,&inputs,&out})g.destroy(*p);vkDestroyDescriptorPool(g.device,pool,nullptr);vkDestroyPipeline(g.device,pipe,nullptr);vkDestroyShaderModule(g.device,sm,nullptr);vkDestroyPipelineLayout(g.device,pl,nullptr);vkDestroyDescriptorSetLayout(g.device,layout,nullptr);
 std::cout<<(mismatches?"FAIL":"PASS")<<" checkedWords="<<checks<<" mismatches="<<mismatches<<"\n";return mismatches?2:0;
 }catch(const std::exception& e){std::cerr<<"ERROR "<<e.what()<<"\n";return 1;}}
