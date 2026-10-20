// SPDX-License-Identifier: MIT
// Minimal device selection for the public queue fixtures. No feature overrides.
#include <vulkan/vulkan.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#define CHECK(call) do { VkResult result=(call); if(result!=VK_SUCCESS) throw std::runtime_error(std::string(#call)+" => "+std::to_string(result)); } while(0)
struct GPU {
    VkInstance instance=VK_NULL_HANDLE;
    VkPhysicalDevice physical=VK_NULL_HANDLE;
    VkPhysicalDeviceMemoryProperties mem{};
    GPU() {
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.pApplicationName="amd-dx12-public-queue-fixture";app.apiVersion=VK_API_VERSION_1_2;
        VkInstanceCreateInfo create{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        // This fixture links the driver directly. Portability enumeration is
        // a Vulkan Loader extension and must not be requested from MoltenVK.
        create.pApplicationInfo=&app;
        CHECK(vkCreateInstance(&create,nullptr,&instance));
        uint32_t count=0;CHECK(vkEnumeratePhysicalDevices(instance,&count,nullptr));
        std::vector<VkPhysicalDevice> devices(count);CHECK(vkEnumeratePhysicalDevices(instance,&count,devices.data()));
        const char* filter=std::getenv("AMD_DX12_DEVICE");
        for(auto device:devices) {
            VkPhysicalDeviceProperties properties;vkGetPhysicalDeviceProperties(device,&properties);
            if(properties.vendorID==0x1002 && (!filter||std::string(properties.deviceName).find(filter)!=std::string::npos)) {
                physical=device;std::cout<<"GPU "<<properties.deviceName<<"\n";break;
            }
        }
        if(!physical)throw std::runtime_error("No matching real AMD GPU; no substitute or capability override is used");
        vkGetPhysicalDeviceMemoryProperties(physical,&mem);
    }
    uint32_t memoryType(uint32_t bits,VkMemoryPropertyFlags flags) {
        for(uint32_t index=0;index<mem.memoryTypeCount;index++)
            if((bits&(1u<<index)) && (mem.memoryTypes[index].propertyFlags&flags)==flags)return index;
        throw std::runtime_error("Required memory type is unavailable");
    }
    ~GPU(){if(instance)vkDestroyInstance(instance,nullptr);}
};
