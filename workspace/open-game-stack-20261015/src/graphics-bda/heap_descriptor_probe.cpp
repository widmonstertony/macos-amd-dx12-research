#include "gpu_common.hpp"
#include <chrono>

static VkDeviceSize alignUp(VkDeviceSize value, VkDeviceSize alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

int main(int argc, char** argv) { try {
    if (argc != 3) throw std::runtime_error("heap_descriptor_probe variable-array.spv output.json");
    GPU g;
    constexpr uint32_t count = 64;
    constexpr VkDeviceSize bufferSize = 256;
    constexpr auto usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;

    std::array<VkBuffer, count> buffers{};
    VkMemoryRequirements req{};
    uint32_t memoryTypeBits = ~0u;
    VkDeviceSize stride = 0;
    for (uint32_t i = 0; i < count; ++i) {
        VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        bi.size = bufferSize; bi.usage = usage; bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        CHECK(vkCreateBuffer(g.device, &bi, nullptr, &buffers[i]));
        VkMemoryRequirements current{}; vkGetBufferMemoryRequirements(g.device, buffers[i], &current);
        if (!i) req = current;
        stride = std::max(stride, alignUp(current.size, current.alignment));
        memoryTypeBits &= current.memoryTypeBits;
    }
    VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    mai.allocationSize = stride * count;
    mai.memoryTypeIndex = g.memoryType(memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory sharedMemory = VK_NULL_HANDLE; CHECK(vkAllocateMemory(g.device, &mai, nullptr, &sharedMemory));
    for (uint32_t i = 0; i < count; ++i) CHECK(vkBindBufferMemory(g.device, buffers[i], sharedMemory, stride * i));

    VkDescriptorSetLayoutBinding bindings[] = {
        {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr},
        {2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr},
        {8, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, count, VK_SHADER_STAGE_COMPUTE_BIT, nullptr}};
    VkDescriptorBindingFlags bindingFlags[] = {0, 0, VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT};
    VkDescriptorSetLayoutBindingFlagsCreateInfo flagsInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO};
    flagsInfo.bindingCount = 3; flagsInfo.pBindingFlags = bindingFlags;
    VkDescriptorSetLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    layoutInfo.pNext = &flagsInfo; layoutInfo.bindingCount = 3; layoutInfo.pBindings = bindings;
    VkDescriptorSetLayout layout = VK_NULL_HANDLE; CHECK(vkCreateDescriptorSetLayout(g.device, &layoutInfo, nullptr, &layout));
    VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT, 0, 4};
    VkPipelineLayoutCreateInfo pipelineLayoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pipelineLayoutInfo.setLayoutCount = 1; pipelineLayoutInfo.pSetLayouts = &layout;
    pipelineLayoutInfo.pushConstantRangeCount = 1; pipelineLayoutInfo.pPushConstantRanges = &push;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE; CHECK(vkCreatePipelineLayout(g.device, &pipelineLayoutInfo, nullptr, &pipelineLayout));

    std::ifstream shaderFile(argv[1], std::ios::binary | std::ios::ate);
    if (!shaderFile) throw std::runtime_error("Missing shader");
    size_t shaderBytes = size_t(shaderFile.tellg()); shaderFile.seekg(0);
    std::vector<uint32_t> shaderCode(shaderBytes / 4); shaderFile.read(reinterpret_cast<char*>(shaderCode.data()), shaderBytes);
    VkShaderModuleCreateInfo shaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    shaderInfo.codeSize = shaderBytes; shaderInfo.pCode = shaderCode.data();
    VkShaderModule shader = VK_NULL_HANDLE; CHECK(vkCreateShaderModule(g.device, &shaderInfo, nullptr, &shader));
    VkComputePipelineCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    pipelineInfo.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    pipelineInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT; pipelineInfo.stage.module = shader; pipelineInfo.stage.pName = "main";
    pipelineInfo.layout = pipelineLayout;
    VkPipeline pipeline = VK_NULL_HANDLE; CHECK(vkCreateComputePipelines(g.device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &pipeline));

    VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, count + 2};
    VkDescriptorPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    poolInfo.maxSets = 1; poolInfo.poolSizeCount = 1; poolInfo.pPoolSizes = &poolSize;
    VkDescriptorPool pool = VK_NULL_HANDLE; CHECK(vkCreateDescriptorPool(g.device, &poolInfo, nullptr, &pool));
    VkDescriptorSetVariableDescriptorCountAllocateInfo variableInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO};
    variableInfo.descriptorSetCount = 1; variableInfo.pDescriptorCounts = &count;
    VkDescriptorSetAllocateInfo setInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    setInfo.pNext = &variableInfo; setInfo.descriptorPool = pool; setInfo.descriptorSetCount = 1; setInfo.pSetLayouts = &layout;
    VkDescriptorSet set = VK_NULL_HANDLE; CHECK(vkAllocateDescriptorSets(g.device, &setInfo, &set));

    Buf input = g.buffer(sizeof(Case) * count, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    Buf output = g.buffer(sizeof(uint32_t) * count, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    auto* cases = static_cast<Case*>(input.p);
    for (uint32_t i = 0; i < count; ++i) cases[i] = {int32_t(i), 0, 0, 0};
    std::vector<VkDescriptorBufferInfo> table(count);
    for (uint32_t i = 0; i < count; ++i) table[i] = {buffers[i], 0, bufferSize};
    VkDescriptorBufferInfo other[] = {{input.b, 0, input.size}, {output.b, 0, output.size}};
    VkWriteDescriptorSet writes[3]{};
    for (uint32_t i = 0; i < 3; ++i) {
        writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[i].dstSet = set;
        writes[i].dstBinding = i == 2 ? 8 : i + 1; writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[i].descriptorCount = i == 2 ? count : 1; writes[i].pBufferInfo = i == 2 ? table.data() : &other[i];
    }
    vkUpdateDescriptorSets(g.device, 3, writes, 0, nullptr);

    uint64_t mismatches = 0;
    double elapsedMS = 0.0;
    auto started = std::chrono::steady_clock::now();
    for (uint32_t round = 0; round < 20; ++round) {
        memset(output.p, 0xcd, output.size);
        g.run([&](VkCommandBuffer cb) {
            if (!round) {
                for (uint32_t i = 0; i < count; ++i) vkCmdFillBuffer(cb, buffers[i], 0, bufferSize, 0x10000000u + i);
                VkMemoryBarrier transferBarrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
                transferBarrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; transferBarrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
                vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &transferBarrier, 0, nullptr, 0, nullptr);
            }
            VkMemoryBarrier hostBarrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
            hostBarrier.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT; hostBarrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &hostBarrier, 0, nullptr, 0, nullptr);
            vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &set, 0, nullptr);
            uint32_t dispatchCount = count; vkCmdPushConstants(cb, pipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &dispatchCount);
            vkCmdDispatch(cb, (count + 31) / 32, 1, 1);
            VkMemoryBarrier readBarrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
            readBarrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT; readBarrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &readBarrier, 0, nullptr, 0, nullptr);
        });
        auto* values = static_cast<uint32_t*>(output.p);
        for (uint32_t i = 0; i < count; ++i) if (values[i] != 0x10000000u + i) ++mismatches;
    }
    elapsedMS = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();

    std::ofstream report(argv[2]);
    report << "{\"passed\":" << (mismatches ? "false" : "true")
           << ",\"sharedAllocationResources\":" << count << ",\"rounds\":20,\"checkedWords\":" << count * 20
           << ",\"mismatches\":" << mismatches << ",\"milliseconds\":" << elapsedMS << "}\n";
    std::cout << "HEAP_DESCRIPTOR_STRESS resources=" << count << " rounds=20 mismatches=" << mismatches << " milliseconds=" << elapsedMS << "\n";

    g.destroy(input); g.destroy(output);
    vkDestroyDescriptorPool(g.device, pool, nullptr); vkDestroyPipeline(g.device, pipeline, nullptr);
    vkDestroyShaderModule(g.device, shader, nullptr); vkDestroyPipelineLayout(g.device, pipelineLayout, nullptr);
    vkDestroyDescriptorSetLayout(g.device, layout, nullptr);
    for (VkBuffer buffer : buffers) vkDestroyBuffer(g.device, buffer, nullptr);
    vkFreeMemory(g.device, sharedMemory, nullptr);
    return mismatches ? 5 : 0;
} catch (const std::exception& error) {
    std::cerr << "ERROR " << error.what() << "\n";
    return 2;
}
}
