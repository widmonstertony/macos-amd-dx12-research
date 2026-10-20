#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>
struct R2Resource {
    uint32_t set=0,binding=0,slot=0,count=1;
    bool buffer=false,sampler=false,array=false;
    std::string type,content,storage;
};
struct R2NativeResult {
    std::vector<uint32_t> binary;
    std::vector<R2Resource> resources;
    uint32_t slots=0,physicalAccesses=0,guardedOperations=0;
    std::string assembly;
};
// In-process C++ implementation. PhysicalStorageBuffer memory accesses retain
// Vulkan's caller-managed BDA semantics; descriptor accesses remain guarded.
bool r2NativeLower(const std::vector<uint32_t>&,
                   const std::map<std::pair<uint32_t,uint32_t>,uint32_t>&,
                   R2NativeResult&,std::string&);
