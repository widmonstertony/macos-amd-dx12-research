#include "r2_bindings.hpp"
#include "manifest.hpp"
#include <algorithm>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <set>
#include <string>

#define CHECK(v) do { VkResult r2_check_result=(v); if(r2_check_result!=VK_SUCCESS) throw std::runtime_error(std::string(#v)+" => "+std::to_string(r2_check_result)); } while(0)
struct Buf {VkBuffer b=VK_NULL_HANDLE;VkDeviceMemory m=VK_NULL_HANDLE;void* p=nullptr;size_t size=0;};
struct Img {VkImage image=VK_NULL_HANDLE;VkImageView view=VK_NULL_HANDLE;VkDeviceMemory memory=VK_NULL_HANDLE;};
using U4=std::array<uint32_t,4>;
struct Case {int32_t op,x,y,z;};
struct GPU {
 VkInstance instance;VkPhysicalDevice physical;VkDevice device;VkQueue queue;uint32_t family;VkCommandPool pool;
 VkPhysicalDeviceMemoryProperties mem;
 GPU(){
  const char* ext=VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
  VkApplicationInfo ai{VK_STRUCTURE_TYPE_APPLICATION_INFO};ai.pApplicationName="isolated-r2-output-validation";ai.apiVersion=VK_API_VERSION_1_2;
  VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};ci.pApplicationInfo=&ai;ci.flags=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;ci.enabledExtensionCount=1;ci.ppEnabledExtensionNames=&ext;
  CHECK(vkCreateInstance(&ci,nullptr,&instance));uint32_t n=0;CHECK(vkEnumeratePhysicalDevices(instance,&n,nullptr));std::vector<VkPhysicalDevice> ps(n);CHECK(vkEnumeratePhysicalDevices(instance,&n,ps.data()));physical=VK_NULL_HANDLE;
  for(auto p:ps){VkPhysicalDeviceProperties prop;vkGetPhysicalDeviceProperties(p,&prop);if(prop.vendorID==0x1002 && std::string(prop.deviceName).find("5600M")!=std::string::npos){physical=p;std::cout<<"GPU "<<prop.deviceName<<" driver="<<prop.driverVersion<<"\n";break;}}
  if(!physical)throw std::runtime_error("Exact AMD Radeon Pro5600M unavailable; refusing substitute GPU");
  VkPhysicalDeviceRobustness2FeaturesEXT robust{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT};VkPhysicalDeviceFeatures2 fs{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};fs.pNext=&robust;vkGetPhysicalDeviceFeatures2(physical,&fs);
  std::cout<<"ORIGINAL_FEATURES robustBufferAccess2="<<robust.robustBufferAccess2<<" robustImageAccess2="<<robust.robustImageAccess2<<" nullDescriptor="<<robust.nullDescriptor<<" (unchanged)\n";
  uint32_t qn=0;vkGetPhysicalDeviceQueueFamilyProperties(physical,&qn,nullptr);std::vector<VkQueueFamilyProperties> qs(qn);vkGetPhysicalDeviceQueueFamilyProperties(physical,&qn,qs.data());family=~0u;
  for(uint32_t i=0;i<qn;i++)if(qs[i].queueFlags&VK_QUEUE_COMPUTE_BIT){family=i;break;}
  if(family==~0u)throw std::runtime_error("No compute queue");float priority=1;
  VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};qi.queueFamilyIndex=family;qi.queueCount=1;qi.pQueuePriorities=&priority;
  VkPhysicalDeviceFeatures enabled{};enabled.shaderInt64=VK_TRUE;enabled.shaderStorageBufferArrayDynamicIndexing=VK_TRUE;
  VkPhysicalDeviceDescriptorIndexingFeatures indexing{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES};indexing.shaderStorageBufferArrayNonUniformIndexing=VK_TRUE;indexing.runtimeDescriptorArray=VK_TRUE;
  const char* dext[]={"VK_KHR_portability_subset","VK_EXT_descriptor_indexing"};VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};di.pNext=&indexing;di.queueCreateInfoCount=1;di.pQueueCreateInfos=&qi;di.pEnabledFeatures=&enabled;di.enabledExtensionCount=2;di.ppEnabledExtensionNames=dext;
  CHECK(vkCreateDevice(physical,&di,nullptr,&device));vkGetDeviceQueue(device,family,0,&queue);vkGetPhysicalDeviceMemoryProperties(physical,&mem);
  VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};pi.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;pi.queueFamilyIndex=family;CHECK(vkCreateCommandPool(device,&pi,nullptr,&pool));
 }
 uint32_t memoryType(uint32_t bits,VkMemoryPropertyFlags flags){for(uint32_t i=0;i<mem.memoryTypeCount;i++)if((bits&(1u<<i)) && (mem.memoryTypes[i].propertyFlags&flags)==flags)return i;throw std::runtime_error("No required memory type");}
 Buf buffer(size_t size,VkBufferUsageFlags usage){Buf r;r.size=size;VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bi.size=size;bi.usage=usage;bi.sharingMode=VK_SHARING_MODE_EXCLUSIVE;CHECK(vkCreateBuffer(device,&bi,nullptr,&r.b));VkMemoryRequirements req;vkGetBufferMemoryRequirements(device,r.b,&req);VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.allocationSize=req.size;ai.memoryTypeIndex=memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);CHECK(vkAllocateMemory(device,&ai,nullptr,&r.m));CHECK(vkBindBufferMemory(device,r.b,r.m,0));CHECK(vkMapMemory(device,r.m,0,size,0,&r.p));return r;}
 Img image(){Img r;VkImageCreateInfo ii{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};ii.imageType=VK_IMAGE_TYPE_2D;ii.format=VK_FORMAT_R32G32B32A32_UINT;ii.extent={4,3,1};ii.mipLevels=1;ii.arrayLayers=1;ii.samples=VK_SAMPLE_COUNT_1_BIT;ii.tiling=VK_IMAGE_TILING_OPTIMAL;ii.usage=VK_IMAGE_USAGE_STORAGE_BIT|VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT;ii.sharingMode=VK_SHARING_MODE_EXCLUSIVE;CHECK(vkCreateImage(device,&ii,nullptr,&r.image));VkMemoryRequirements req;vkGetImageMemoryRequirements(device,r.image,&req);VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.allocationSize=req.size;ai.memoryTypeIndex=memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);CHECK(vkAllocateMemory(device,&ai,nullptr,&r.memory));CHECK(vkBindImageMemory(device,r.image,r.memory,0));VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};vi.image=r.image;vi.viewType=VK_IMAGE_VIEW_TYPE_2D;vi.format=ii.format;vi.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};CHECK(vkCreateImageView(device,&vi,nullptr,&r.view));return r;}
 void run(const std::function<void(VkCommandBuffer)>& fn){VkCommandBufferAllocateInfo ai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};ai.commandPool=pool;ai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;ai.commandBufferCount=1;VkCommandBuffer cb;CHECK(vkAllocateCommandBuffers(device,&ai,&cb));VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;CHECK(vkBeginCommandBuffer(cb,&bi));fn(cb);CHECK(vkEndCommandBuffer(cb));VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};VkFence f;CHECK(vkCreateFence(device,&fi,nullptr,&f));VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};si.commandBufferCount=1;si.pCommandBuffers=&cb;CHECK(vkQueueSubmit(queue,1,&si,f));CHECK(vkWaitForFences(device,1,&f,VK_TRUE,15000000000ull));vkDestroyFence(device,f,nullptr);vkFreeCommandBuffers(device,pool,1,&cb);}
 void barrier(VkCommandBuffer cb,VkImage image,VkImageLayout old,VkImageLayout next){VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};b.srcAccessMask=old==VK_IMAGE_LAYOUT_UNDEFINED?0:VK_ACCESS_MEMORY_WRITE_BIT|VK_ACCESS_MEMORY_READ_BIT;b.dstAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;b.oldLayout=old;b.newLayout=next;b.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;b.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;b.image=image;b.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,nullptr,0,nullptr,1,&b);}
 void destroy(Buf& b){vkUnmapMemory(device,b.m);vkDestroyBuffer(device,b.b,nullptr);vkFreeMemory(device,b.m,nullptr);}
 void destroy(Img& i){vkDestroyImageView(device,i.view,nullptr);vkDestroyImage(device,i.image,nullptr);vkFreeMemory(device,i.memory,nullptr);}
 ~GPU(){vkDestroyCommandPool(device,pool,nullptr);vkDestroyDevice(device,nullptr);vkDestroyInstance(instance,nullptr);}
};

#ifndef R2_GPU_NO_MAIN
int main(int argc,char** argv){try{
 if(argc!=4)throw std::runtime_error("gpu_probe original.spv lowered.spv results.json");
 GPU g;
 std::vector<VkDescriptorSetLayoutBinding> bindings;
 for(int i=0;i<10;i++)bindings.push_back({uint32_t(i),i==4||i==5?VK_DESCRIPTOR_TYPE_STORAGE_IMAGE:i==8?VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE:i==9?VK_DESCRIPTOR_TYPE_SAMPLER:VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr});
 bindings.push_back({31,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr});
 VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};li.bindingCount=uint32_t(bindings.size());li.pBindings=bindings.data();VkDescriptorSetLayout layout;CHECK(vkCreateDescriptorSetLayout(g.device,&li,nullptr,&layout));
 VkPushConstantRange pc{VK_SHADER_STAGE_COMPUTE_BIT,0,4};VkPipelineLayoutCreateInfo pli{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pli.setLayoutCount=1;pli.pSetLayouts=&layout;pli.pushConstantRangeCount=1;pli.pPushConstantRanges=&pc;VkPipelineLayout pipelineLayout;CHECK(vkCreatePipelineLayout(g.device,&pli,nullptr,&pipelineLayout));
 auto pipeline=[&](const char* path){std::ifstream f(path,std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("SPIR-V missing");size_t sz=size_t(f.tellg());f.seekg(0);std::vector<uint32_t> code(sz/4);f.read(reinterpret_cast<char*>(code.data()),sz);VkShaderModuleCreateInfo mi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};mi.codeSize=sz;mi.pCode=code.data();VkShaderModule module;CHECK(vkCreateShaderModule(g.device,&mi,nullptr,&module));VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};ci.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=module;ci.stage.pName="main";ci.layout=pipelineLayout;VkPipeline p;VkResult result=vkCreateComputePipelines(g.device,VK_NULL_HANDLE,1,&ci,nullptr,&p);vkDestroyShaderModule(g.device,module,nullptr);CHECK(result);return p;};
 VkPipeline original=pipeline(argv[1]),lowered=pipeline(argv[2]);
 VkDescriptorPoolSize sizes[]={{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,7},{VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,2},{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,1},{VK_DESCRIPTOR_TYPE_SAMPLER,1}};VkDescriptorPoolCreateInfo pi{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};pi.maxSets=1;pi.poolSizeCount=4;pi.pPoolSizes=sizes;VkDescriptorPool pool;CHECK(vkCreateDescriptorPool(g.device,&pi,nullptr,&pool));VkDescriptorSetAllocateInfo dai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};dai.descriptorPool=pool;dai.descriptorSetCount=1;dai.pSetLayouts=&layout;VkDescriptorSet ds;CHECK(vkAllocateDescriptorSets(g.device,&dai,&ds));
 VkSamplerCreateInfo sci{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};sci.magFilter=VK_FILTER_NEAREST;sci.minFilter=VK_FILTER_NEAREST;sci.mipmapMode=VK_SAMPLER_MIPMAP_MODE_NEAREST;sci.addressModeU=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;sci.addressModeV=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;sci.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;sci.maxLod=100;VkSampler sampler;CHECK(vkCreateSampler(g.device,&sci,nullptr,&sampler));
 constexpr auto usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_TRANSFER_SRC_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT;
 Buf words=g.buffer(256,usage),cases=g.buffer(65536,usage),results=g.buffer(65536,usage),vectors=g.buffer(256,usage),atomic=g.buffer(256,usage),wide=g.buffer(256,usage),dummy=g.buffer(256,usage),meta=g.buffer(R2_SLOT_COUNT*16,usage);
 Buf upload=g.buffer(192*3,usage),readback=g.buffer(192*3,usage);Img input=g.image(),output=g.image(),dummyImg=g.image();
 // Validate binding errors before submission using actual allocated resources.
 {
  R2Bindings t(1,{dummy.b,0,64},{VK_NULL_HANDLE,dummyImg.view,VK_IMAGE_LAYOUT_GENERAL});
  auto b=t.buffer(0,VK_NULL_HANDLE,~VkDeviceSize(0),VK_WHOLE_SIZE);
  if(b.buffer!=dummy.b||b.offset!=0||b.range!=64||t.metadata[0]!=R2Bindings::Meta{0,0,0,0})throw std::runtime_error("Null descriptor range/offset must be ignored");
  unsigned refusals=0;auto refuse=[&](const std::function<void()>& f){try{f();}catch(const std::runtime_error&){++refusals;return;}throw std::runtime_error("Invalid binding accepted");};
  refuse([&]{t.buffer(0,words.b,0,VK_WHOLE_SIZE);});refuse([&]{t.buffer(0,words.b,0,0);});refuse([&]{t.buffer(0,words.b,0,VkDeviceSize(UINT32_MAX)+1);});refuse([&]{t.buffer(1,words.b,0,4);});refuse([&]{t.image(0,input.view,0,3);});
  R2Bindings absent(1,{},{});refuse([&]{absent.buffer(0,VK_NULL_HANDLE,0,0);});refuse([&]{absent.image(0,VK_NULL_HANDLE,0,0);});
  std::cout<<"BINDING_CONTRACT null range/offset ignored; invalid bindings refused="<<refusals<<"\n";
 }
 std::vector<U4> inputPixels(12),outputPixels(12,U4{0xeeeeeeee,0xeeeeeeee,0xeeeeeeee,0xeeeeeeee}),dummyPixels(12,U4{0xa5a55a5a,0xa5a55a5a,0xa5a55a5a,0xa5a55a5a});
 for(uint32_t i=0;i<12;i++)inputPixels[i]={10+i,20+i,30+i,40+i};
 bool imagesInitialized=false;uint64_t mismatches=0,readChecks=0,witnessChecks=0;unsigned scenarios=0;std::vector<std::string> names;
 auto mismatch=[&](const std::string& s){if(mismatches<15)std::cerr<<"MISMATCH "<<s<<"\n";++mismatches;};
 auto run=[&](std::string name,std::vector<Case> cs,bool nb,bool ni,bool control,bool stress){
  std::vector<uint32_t> expWords(64),expVectors(64),expAtomic(64),expDummy(64,0xa5a55a5a);std::vector<uint64_t> expWide(32);
  for(uint32_t i=0;i<64;i++){expWords[i]=1000+i;expVectors[i]=3000+i;expAtomic[i]=2000+i;}
  for(uint64_t i=0;i<32;i++)expWide[i]=0x1234567800000000ull+i;
  std::memcpy(words.p,expWords.data(),256);std::memcpy(vectors.p,expVectors.data(),256);std::memcpy(atomic.p,expAtomic.data(),256);std::memcpy(wide.p,expWide.data(),256);std::memcpy(dummy.p,expDummy.data(),256);std::memcpy(cases.p,cs.data(),cs.size()*16);std::memset(results.p,0xcd,results.size);
  std::memcpy(upload.p,inputPixels.data(),192);std::memcpy(static_cast<char*>(upload.p)+192,outputPixels.data(),192);std::memcpy(static_cast<char*>(upload.p)+384,dummyPixels.data(),192);
  R2Bindings table(R2_SLOT_COUNT,{dummy.b,0,64},{VK_NULL_HANDLE,dummyImg.view,VK_IMAGE_LAYOUT_GENERAL});
  std::array<VkDescriptorBufferInfo,9> bis{};std::array<VkDescriptorImageInfo,10> iis{};std::vector<VkWriteDescriptorSet> writes;
  std::map<int,std::tuple<Buf*,size_t,size_t>> bufs={{0,{&words,16,20}},{1,{&cases,0,cs.size()*16}},{2,{&results,0,cs.size()*16}},{3,{&vectors,16,20}},{6,{&atomic,16,20}},{7,{&wide,16,24}}};
  for(auto [binding,v]:bufs){auto [b,offset,range]=v;bis[binding]=table.buffer(R2_SLOTS[binding],nb && binding!=1 && binding!=2?VK_NULL_HANDLE:b->b,offset,range);VkWriteDescriptorSet w{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};w.dstSet=ds;w.dstBinding=binding;w.descriptorCount=1;w.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;w.pBufferInfo=&bis[binding];writes.push_back(w);}
  for(int b:{4,5}){iis[b]=table.image(R2_SLOTS[b],ni?VK_NULL_HANDLE:(b==4?input.view:output.view),4,3);VkWriteDescriptorSet w{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};w.dstSet=ds;w.dstBinding=b;w.descriptorCount=1;w.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;w.pImageInfo=&iis[b];writes.push_back(w);}
  iis[8]=table.image(R2_SLOTS[8],ni?VK_NULL_HANDLE:input.view,4,3);iis[9]={sampler,VK_NULL_HANDLE,VK_IMAGE_LAYOUT_UNDEFINED};
  for(int b:{8,9}){VkWriteDescriptorSet w{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};w.dstSet=ds;w.dstBinding=b;w.descriptorCount=1;w.descriptorType=b==8?VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE:VK_DESCRIPTOR_TYPE_SAMPLER;w.pImageInfo=&iis[b];writes.push_back(w);}
  bis[8]={meta.b,0,meta.size};VkWriteDescriptorSet mw{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};mw.dstSet=ds;mw.dstBinding=31;mw.descriptorCount=1;mw.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;mw.pBufferInfo=&bis[8];writes.push_back(mw);std::memcpy(meta.p,table.metadata.data(),meta.size);vkUpdateDescriptorSets(g.device,uint32_t(writes.size()),writes.data(),0,nullptr);
  std::vector<U4> expected(cs.size(),U4{0,0,0,0});auto expectedImage=outputPixels;
  // CPU reference operates on descriptor ranges, never allocation sizes.
  for(size_t i=0;i<cs.size();i++){auto c=cs[i];auto& o=expected[i];int idx=c.x;bool scalar=idx>=0&&idx<5;
   switch(c.op){
    case 0:if(!nb&&scalar)o[0]=expWords[4+idx];break;
    case 1:if(!nb&&scalar)expWords[4+idx]=uint32_t(c.y);o[0]=1;break;
    case 2:for(int k=0;k<4;k++){int64_t j=int64_t(idx)*4+k;if(!nb&&j>=0&&j<5)o[k]=expVectors[4+j];}break;
    case 3:for(int k=0;k<4;k++){int64_t j=int64_t(idx)*4+k;if(!nb&&j>=0&&j<5)expVectors[4+j]=uint32_t(c.y)+k;}o[0]=1;break;
    case 4:if(!nb&&scalar){o[0]=expAtomic[4+idx];expAtomic[4+idx]+=uint32_t(c.y);}break;
    case 5:if(!ni&&idx>=0&&idx<4&&c.y>=0&&c.y<3)o=inputPixels[c.y*4+idx];break;
    case 6:if(!ni&&idx>=0&&idx<4&&c.y>=0&&c.y<3)for(int k=0;k<4;k++)expectedImage[c.y*4+idx][k]=uint32_t(c.z)+k;o[0]=1;break;
    case 7:if(!nb&&idx>=0&&idx<3){uint64_t v=expWide[2+idx];o={uint32_t(v),uint32_t(v>>32),0,0};}break;
    case 8:if(!nb&&idx>=0&&idx<3)expWide[2+idx]=(uint64_t(uint32_t(c.z))<<32)|uint32_t(c.y);o[0]=1;break;
    case 9:if(!nb)o={5,1,3,0};break;
    case 10:if(!ni){int x=std::max(0,std::min(3,idx)),y=std::max(0,std::min(2,c.y));o=inputPixels[y*4+x];}break;
   }
  }
  g.run([&](VkCommandBuffer cb){
   std::array<Img*,3> images={&input,&output,&dummyImg};
   for(int i=0;i<3;i++){g.barrier(cb,images[i]->image,imagesInitialized?VK_IMAGE_LAYOUT_GENERAL:VK_IMAGE_LAYOUT_UNDEFINED,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);VkBufferImageCopy copy{};copy.bufferOffset=i*192;copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};copy.imageExtent={4,3,1};vkCmdCopyBufferToImage(cb,upload.b,images[i]->image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);g.barrier(cb,images[i]->image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,VK_IMAGE_LAYOUT_GENERAL);}
   VkMemoryBarrier mb{VK_STRUCTURE_TYPE_MEMORY_BARRIER};mb.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT|VK_ACCESS_TRANSFER_WRITE_BIT;mb.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_HOST_BIT|VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&mb,0,nullptr,0,nullptr);
   vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,control?original:lowered);vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipelineLayout,0,1,&ds,0,nullptr);uint32_t count=uint32_t(cs.size());vkCmdPushConstants(cb,pipelineLayout,VK_SHADER_STAGE_COMPUTE_BIT,0,4,&count);vkCmdDispatch(cb,(count+31)/32,1,1);
   for(int i=0;i<3;i++){g.barrier(cb,images[i]->image,VK_IMAGE_LAYOUT_GENERAL,VK_IMAGE_LAYOUT_GENERAL);VkBufferImageCopy copy{};copy.bufferOffset=i*192;copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};copy.imageExtent={4,3,1};vkCmdCopyImageToBuffer(cb,images[i]->image,VK_IMAGE_LAYOUT_GENERAL,readback.b,1,&copy);}
   mb.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT|VK_ACCESS_TRANSFER_WRITE_BIT;mb.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT|VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&mb,0,nullptr,0,nullptr);
  });imagesInitialized=true;
  auto actual=static_cast<U4*>(results.p);std::vector<uint32_t> atomicReturns;
  for(size_t i=0;i<cs.size();i++)for(int k=0;k<4;k++){++readChecks;if(stress&&cs[i].op==4&&cs[i].x==0&&!nb&&k==0){atomicReturns.push_back(actual[i][k]);continue;}if(actual[i][k]!=expected[i][k])mismatch(name+" result["+std::to_string(i)+"]["+std::to_string(k)+"] actual="+std::to_string(actual[i][k])+" expected="+std::to_string(expected[i][k]));}
  if(stress&&!nb){std::sort(atomicReturns.begin(),atomicReturns.end());for(size_t i=0;i<atomicReturns.size();i++)if(atomicReturns[i]!=2004+i)mismatch(name+" atomic linearization");}
  auto check=[&](const void* p,const void* e,size_t bytes,const char* what){auto a=static_cast<const uint32_t*>(p),v=static_cast<const uint32_t*>(e);for(size_t i=0;i<bytes/4;i++){++witnessChecks;if(a[i]!=v[i])mismatch(name+" "+what+" word="+std::to_string(i));}};
  check(words.p,expWords.data(),256,"buffer range + padding");check(vectors.p,expVectors.data(),256,"partial vector + padding");check(atomic.p,expAtomic.data(),256,"atomic witness");check(wide.p,expWide.data(),256,"64bit range");check(dummy.p,expDummy.data(),256,"null-buffer nonzero witness");
  check(readback.p,inputPixels.data(),192,"input image unchanged");check(static_cast<char*>(readback.p)+192,expectedImage.data(),192,"output image");check(static_cast<char*>(readback.p)+384,dummyPixels.data(),192,"null-image nonzero witness");
  for(size_t i=cs.size()*16;i<results.size;i+=4){++witnessChecks;if(*reinterpret_cast<uint32_t*>(static_cast<char*>(results.p)+i)!=0xcdcdcdcd)mismatch(name+" result padding");}
  ++scenarios;names.push_back(name);std::cout<<"CASE "<<name<<" operations="<<cs.size()<<" nullBuffers="<<table.nullBuffers<<" nullImages="<<table.nullImages<<" cumulativeMismatches="<<mismatches<<"\n";
 };
 std::vector<Case> valid={{0,0,0,0},{0,4,0,0},{2,0,0,0},{4,0,7,0},{5,0,0,0},{5,3,2,0},{7,0,0,0},{7,2,0,0},{10,0,0,0},{10,3,2,0}};
 run("unmodified-valid-control",valid,false,false,true,false);run("lowered-valid-control",valid,false,false,false,false);
 std::vector<Case> reads;
 for(int op:{0,2,7})for(int i:{-1,0,1,2,4,5,6,0x40000000,0x7fffffff})reads.push_back({op,i,0,0});
 for(int x:{-1,0,3,4,0x7fffffff})for(int y:{-1,0,2,3,0x7fffffff})reads.push_back({5,x,y,0});
 reads.push_back({9,0,0,0});for(int x:{-4,0,3,4})for(int y:{-4,0,2,3})reads.push_back({10,x,y,0});
 for(bool nb:{false,true})for(bool ni:{false,true})run(std::string("reads-")+(nb?"null-buffers":"bound-buffers")+"-"+(ni?"null-images":"bound-images"),reads,nb,ni,false,false);
 std::vector<Case> writes={{1,2,900,0},{1,5,999,0},{1,-1,999,0},{1,0x40000000,999,0},{1,0x7fffffff,999,0},{3,1,800,0},{3,2,999,0},{3,-1,999,0},{8,1,123,456},{8,3,999,999},{8,-1,999,999},{8,0x40000000,999,999},{6,2,1,700},{6,-1,0,999},{6,4,0,999},{6,0,3,999},{6,0x7fffffff,0,999}};
 for(bool nb:{false,true})for(bool ni:{false,true})run(std::string("writes-")+(nb?"null-buffers":"bound-buffers")+"-"+(ni?"null-images":"bound-images"),writes,nb,ni,false,false);
 std::vector<Case> stress;for(int i=0;i<1024;i++)stress.push_back({4,i%2?5:0,1,0});run("atomic-concurrent-bound-and-oob",stress,false,false,false,true);run("atomic-concurrent-null",stress,true,false,false,true);
 std::ofstream report(argv[3]);report<<"{\n  \"device\":\"AMD Radeon Pro 5600M\",\n  \"nativeRobustness2FeaturesChanged\":false,\n  \"scenarios\":"<<scenarios<<",\n  \"gpuResultWordsChecked\":"<<readChecks<<",\n  \"witnessWordsChecked\":"<<witnessChecks<<",\n  \"mismatches\":"<<mismatches<<",\n  \"passed\":"<<(mismatches?"false":"true")<<",\n  \"scope\":\"Independent SPIR-V lowering and descriptor adapter; not full MoltenVK Robustness2 conformance or game compatibility\"\n}\n";report.close();
 for(auto b:{&words,&cases,&results,&vectors,&atomic,&wide,&dummy,&meta,&upload,&readback})g.destroy(*b);for(auto i:{&input,&output,&dummyImg})g.destroy(*i);vkDestroySampler(g.device,sampler,nullptr);vkDestroyDescriptorPool(g.device,pool,nullptr);vkDestroyPipeline(g.device,original,nullptr);vkDestroyPipeline(g.device,lowered,nullptr);vkDestroyPipelineLayout(g.device,pipelineLayout,nullptr);vkDestroyDescriptorSetLayout(g.device,layout,nullptr);
 std::cout<<(mismatches?"FAIL":"PASS")<<" resultWords="<<readChecks<<" witnesses="<<witnessChecks<<" mismatches="<<mismatches<<"\n";return mismatches?2:0;
 }catch(const std::exception& e){std::cerr<<"ERROR "<<e.what()<<"\n";return 1;}}
#endif
