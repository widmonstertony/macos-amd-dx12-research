#include <vulkan/vulkan.h>
#include <array>
#include <vector>
#include <stdexcept>
#include <cstdint>
#include <dlfcn.h>
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
  VkPhysicalDeviceDescriptorIndexingFeatures indexing{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES};indexing.shaderStorageBufferArrayNonUniformIndexing=VK_TRUE;indexing.runtimeDescriptorArray=VK_TRUE;indexing.descriptorBindingVariableDescriptorCount=VK_TRUE;indexing.descriptorBindingPartiallyBound=VK_TRUE;
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


inline void driverWitness(unsigned,unsigned) {
 std::cout << "REFERENCE_COMPARISON: old custom-driver counters are not available; real output checks retained.\n";
}
