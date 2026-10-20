// Public Vulkan/Metal interop fixture. No game code, invented completion or driver patch.
#define VK_USE_PLATFORM_METAL_EXT
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>
extern "C" void vkGetMTLCommandQueueMVK(VkQueue, id<MTLCommandQueue>*);
extern "C" void vkGetMTLDeviceMVK(VkPhysicalDevice, id<MTLDevice>*);
#define CHECK(call) do { auto result=(call); if(result!=VK_SUCCESS) {fprintf(stderr,"%s returned %d\n",#call,result); std::_Exit(2);} }while(0)
struct Context {
    VkDevice device{}; VkQueue queue{}; id<MTLCommandQueue> native{};
    VkCommandPool pool{}; VkCommandBuffer command{}; VkSemaphore semaphore{};
    VkBuffer buffer{}; VkDeviceMemory memory{}; uint32_t* map{};
};
constexpr unsigned words=4096, rounds=32;
static Context make(VkPhysicalDevice physical, unsigned family, id<MTLSharedEvent> event) {
    Context c; float priority=1;
    VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
    VkPhysicalDeviceTimelineSemaphoreFeatures tf{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
    tf.timelineSemaphore=VK_TRUE;
    const char* extensions[]={"VK_KHR_portability_subset","VK_EXT_metal_objects"};
    VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.pNext=&tf;
    di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi;di.enabledExtensionCount=2;di.ppEnabledExtensionNames=extensions;
    CHECK(vkCreateDevice(physical,&di,nullptr,&c.device));
    vkGetDeviceQueue(c.device,family,0,&c.queue);vkGetMTLCommandQueueMVK(c.queue,&c.native);
    VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};pi.queueFamilyIndex=family;pi.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    CHECK(vkCreateCommandPool(c.device,&pi,nullptr,&c.pool));
    VkCommandBufferAllocateInfo ai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};ai.commandPool=c.pool;ai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;ai.commandBufferCount=1;
    CHECK(vkAllocateCommandBuffers(c.device,&ai,&c.command));
    VkImportMetalSharedEventInfoEXT imported{VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT};imported.mtlSharedEvent=event;
    VkSemaphoreTypeCreateInfo st{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};st.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;st.pNext=&imported;
    VkSemaphoreCreateInfo si{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};si.pNext=&st;CHECK(vkCreateSemaphore(c.device,&si,nullptr,&c.semaphore));
    VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bi.size=words*4;bi.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    CHECK(vkCreateBuffer(c.device,&bi,nullptr,&c.buffer));
    VkMemoryRequirements mr;vkGetBufferMemoryRequirements(c.device,c.buffer,&mr);
    VkPhysicalDeviceMemoryProperties mp;vkGetPhysicalDeviceMemoryProperties(physical,&mp);unsigned memoryType=~0u;
    for(unsigned i=0;i<mp.memoryTypeCount;i++)if((mr.memoryTypeBits&(1u<<i)) && (mp.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)){memoryType=i;break;}
    if(memoryType==~0u)std::_Exit(3);
    VkMemoryAllocateInfo ma{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ma.allocationSize=mr.size;ma.memoryTypeIndex=memoryType;
    CHECK(vkAllocateMemory(c.device,&ma,nullptr,&c.memory));CHECK(vkBindBufferMemory(c.device,c.buffer,c.memory,0));
    CHECK(vkMapMemory(c.device,c.memory,0,words*4,0,(void**)&c.map));return c;
}
static void submit(Context& c,uint64_t wait,uint64_t signal,uint32_t pattern) {
    CHECK(vkResetCommandPool(c.device,c.pool,0));
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CHECK(vkBeginCommandBuffer(c.command,&bi));vkCmdFillBuffer(c.command,c.buffer,0,words*4,pattern);
    VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(c.command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,nullptr,0,nullptr);
    CHECK(vkEndCommandBuffer(c.command));
    VkTimelineSemaphoreSubmitInfo ti{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};ti.waitSemaphoreValueCount=1;ti.pWaitSemaphoreValues=&wait;ti.signalSemaphoreValueCount=1;ti.pSignalSemaphoreValues=&signal;
    VkPipelineStageFlags stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};si.pNext=&ti;si.waitSemaphoreCount=1;si.pWaitSemaphores=&c.semaphore;si.pWaitDstStageMask=&stage;si.signalSemaphoreCount=1;si.pSignalSemaphores=&c.semaphore;si.commandBufferCount=1;si.pCommandBuffers=&c.command;
    CHECK(vkQueueSubmit(c.queue,1,&si,VK_NULL_HANDLE));
}
static void destroy(Context& c) {
    CHECK(vkDeviceWaitIdle(c.device));vkUnmapMemory(c.device,c.memory);vkDestroyBuffer(c.device,c.buffer,nullptr);vkFreeMemory(c.device,c.memory,nullptr);
    vkDestroySemaphore(c.device,c.semaphore,nullptr);vkDestroyCommandPool(c.device,c.pool,nullptr);vkDestroyDevice(c.device,nullptr);
}
int main(){@autoreleasepool {
    VkApplicationInfo ai{VK_STRUCTURE_TYPE_APPLICATION_INFO};ai.apiVersion=VK_API_VERSION_1_2;
    VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};ci.pApplicationInfo=&ai;VkInstance instance;CHECK(vkCreateInstance(&ci,nullptr,&instance));
    uint32_t n=0;CHECK(vkEnumeratePhysicalDevices(instance,&n,nullptr));std::vector<VkPhysicalDevice> devices(n);CHECK(vkEnumeratePhysicalDevices(instance,&n,devices.data()));
    VkPhysicalDevice physical{};for(auto d:devices){VkPhysicalDeviceProperties p;vkGetPhysicalDeviceProperties(d,&p);if(p.vendorID==0x1002&&strstr(p.deviceName,"5600M"))physical=d;}
    if(!physical)return 3;
    VkPhysicalDeviceTimelineSemaphoreFeatures supported{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};features.pNext=&supported;vkGetPhysicalDeviceFeatures2(physical,&features);if(!supported.timelineSemaphore)return 4;
    uint32_t count=0;vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,nullptr);std::vector<VkQueueFamilyProperties> props(count);vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,props.data());unsigned family=~0u;for(unsigned i=0;i<count;i++)if(props[i].queueFlags&VK_QUEUE_GRAPHICS_BIT){family=i;break;}
    if(family==~0u)return 5;
    id<MTLDevice> metal;vkGetMTLDeviceMVK(physical,&metal);id<MTLSharedEvent> event=[metal newSharedEvent];if(!event)return 6;
    Context a=make(physical,family,event),b=make(physical,family,event);
    if(a.native==b.native){fprintf(stderr,"Native queues alias: no dependent GPU work submitted\n");return 7;}
    uint64_t checked=0,bad=0;
    for(unsigned r=0;r<rounds;r++){
        uint32_t pa=0xa5000000u^r,pb=0x5a000000u^r;
        // A is enqueued first but requires B's later-submitted signal.
        // Distinct native queues were checked before any dependent GPU work.
        submit(a,2*r+1,2*r+2,pa);submit(b,2*r,2*r+1,pb);
        uint64_t target=2*r+2;VkSemaphoreWaitInfo wi{VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};wi.semaphoreCount=1;wi.pSemaphores=&a.semaphore;wi.pValues=&target;
        CHECK(vkWaitSemaphores(a.device,&wi,2000000000ull));
        for(unsigned k=0;k<words;k++){checked+=2;bad+=(a.map[k]!=pa)+(b.map[k]!=pb);}
    }
    id<MTLCommandQueue> old=a.native;destroy(a);
    // Keep B alive while a new device reuses only the released queue lease.
    Context c=make(physical,family,event);bool reused=c.native==old,exclusive=c.native!=b.native;
    destroy(c);destroy(b);[event release];vkDestroyInstance(instance,nullptr);
    printf("{\"passed\":%s,\"independentNativeQueues\":true,\"releasedQueueReused\":%s,\"liveQueueNotReused\":%s,\"rounds\":%u,\"checkedWords\":%llu,\"mismatches\":%llu}\n",(!bad&&reused&&exclusive)?"true":"false",reused?"true":"false",exclusive?"true":"false",rounds,(unsigned long long)checked,(unsigned long long)bad);
    return (!bad&&reused&&exclusive)?0:1;
}}
