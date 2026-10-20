#include "../../robustness2-reference-20261015/src/gpu_common.hpp"
#include <chrono>

// Large partially-bound descriptor table with many views of the same buffers.
// Checks real dispatch/readback after descriptor updates and encoder resets.
int main(int argc, char** argv) { try {
    if (argc != 3) throw std::runtime_error("live_descriptor_gpu variable-array.spv report.json");
    GPU g;
    constexpr uint32_t count = 16384, rounds = 16;
    VkDescriptorSetLayoutBinding bindings[] = {
        {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr},
        {2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr},
        {8, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, count, VK_SHADER_STAGE_COMPUTE_BIT, nullptr}};
    VkDescriptorBindingFlags flags[] = {0, 0, VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT};
    VkDescriptorSetLayoutBindingFlagsCreateInfo fi{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO};
    fi.bindingCount = 3; fi.pBindingFlags = flags;
    VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    li.pNext = &fi; li.bindingCount = 3; li.pBindings = bindings;
    VkDescriptorSetLayout layout; CHECK(vkCreateDescriptorSetLayout(g.device, &li, nullptr, &layout));
    VkPushConstantRange range{VK_SHADER_STAGE_COMPUTE_BIT, 0, 4};
    VkPipelineLayoutCreateInfo pli{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pli.setLayoutCount = 1; pli.pSetLayouts = &layout; pli.pushConstantRangeCount = 1; pli.pPushConstantRanges = &range;
    VkPipelineLayout pl; CHECK(vkCreatePipelineLayout(g.device, &pli, nullptr, &pl));
    std::ifstream file(argv[1], std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Shader absent");
    size_t bytes = size_t(file.tellg()); file.seekg(0);
    std::vector<uint32_t> code(bytes / 4); file.read((char*)code.data(), bytes);
    VkShaderModuleCreateInfo smi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; smi.codeSize = bytes; smi.pCode = code.data();
    VkShaderModule sm; CHECK(vkCreateShaderModule(g.device, &smi, nullptr, &sm));
    VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    ci.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}; ci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    ci.stage.module = sm; ci.stage.pName = "main"; ci.layout = pl;
    VkPipeline pipe; CHECK(vkCreateComputePipelines(g.device, VK_NULL_HANDLE, 1, &ci, nullptr, &pipe));
    VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2*(count + 2)};
    VkDescriptorPoolCreateInfo dpi{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; dpi.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT; dpi.maxSets = 2; dpi.poolSizeCount = 1; dpi.pPoolSizes = &poolSize;
    VkDescriptorPool pool; CHECK(vkCreateDescriptorPool(g.device, &dpi, nullptr, &pool));
    VkDescriptorSetVariableDescriptorCountAllocateInfo vi{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO};
    vi.descriptorSetCount = 1; vi.pDescriptorCounts = &count;
    VkDescriptorSetAllocateInfo dai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; dai.pNext = &vi;
    dai.descriptorPool = pool; dai.descriptorSetCount = 1; dai.pSetLayouts = &layout;
    VkDescriptorSet ds; CHECK(vkAllocateDescriptorSets(g.device, &dai, &ds));
    VkDescriptorSet sourceDS; CHECK(vkAllocateDescriptorSets(g.device, &dai, &sourceDS));
    constexpr auto usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    Buf a = g.buffer(256, usage), b = g.buffer(256, usage), input = g.buffer(64, usage), output = g.buffer(64, usage);
    for (uint32_t i = 0; i < 64; ++i) { ((uint32_t*)a.p)[i] = 100+i; ((uint32_t*)b.p)[i] = 900+i; }
    const Case cases[] = {{0, 0, 0, 0}, {int32_t(count-1), 4, 0, 0}, {1, 0, 0, 0}, {int32_t(count-1), 5, 0, 0}};
    memcpy(input.p, cases, sizeof(cases));
    uint64_t checks = 0, mismatches = 0;
    const bool manyUnused = getenv("MVK_LIVE_STRESS_DEAD_ALIASES") != nullptr;
    const bool manyUnique = getenv("MVK_LIVE_STRESS_UNIQUE") != nullptr;
    std::vector<Buf> unique;
    if (manyUnique) {
        unique.reserve(512);
        for (uint32_t i = 0; i < 512; ++i) unique.push_back(g.buffer(64, usage));
    }
    auto started = std::chrono::steady_clock::now();
    double submitMilliseconds = 0;
    for (uint32_t phase = 0; phase < 5; ++phase) {
        if (phase == 2) {
            CHECK(vkFreeDescriptorSets(g.device, pool, 1, &ds));
            CHECK(vkAllocateDescriptorSets(g.device, &dai, &ds));
        } else if (phase == 3) {
            CHECK(vkResetDescriptorPool(g.device, pool, 0));
            CHECK(vkAllocateDescriptorSets(g.device, &dai, &ds));
            CHECK(vkAllocateDescriptorSets(g.device, &dai, &sourceDS));
        }
        std::vector<VkDescriptorBufferInfo> table(count, {(phase%2) ? b.b : a.b, 16, 20});
        if (manyUnique) {
            for (uint32_t i = 2; i < count-1; ++i)
                table[i] = {unique[i % unique.size()].b, 0, 64};
        }
        for (uint32_t i = 1; i < count-1; i += 7) table[i] = {VK_NULL_HANDLE, 0, VK_WHOLE_SIZE};
        // Keep every shader-observed slot on the original deterministic data.
        table[0] = {(phase%2) ? b.b : a.b, 16, 20};
        table[count-1] = {(phase%2) ? b.b : a.b, 16, 20};
        Buf unused = g.buffer(64, usage);
        table[count/2] = {unused.b, 0, 64};
        if (manyUnused) {
            for (uint32_t i = count/2; i < count-1; ++i) table[i] = {unused.b, 0, 64};
        }
        VkDescriptorBufferInfo other[] = {{input.b, 0, 64}, {output.b, 0, 64}};
        VkWriteDescriptorSet writes[3]{};
        for (uint32_t i = 0; i < 3; ++i) {
            writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[i].dstSet = phase == 1 ? sourceDS : ds;
            writes[i].dstBinding = i == 2 ? 8 : i+1; writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[i].descriptorCount = i == 2 ? count : 1; writes[i].pBufferInfo = i == 2 ? table.data() : &other[i];
        }
        if (phase == 4) {
            writes[2].dstArrayElement = count-1; writes[2].descriptorCount = 1;
            writes[2].pBufferInfo = &table.back();
            vkUpdateDescriptorSets(g.device, 1, &writes[2], 0, nullptr);
        } else vkUpdateDescriptorSets(g.device, 3, writes, 0, nullptr);
        if (phase == 1) {
            VkCopyDescriptorSet copy{VK_STRUCTURE_TYPE_COPY_DESCRIPTOR_SET};
            copy.srcSet = sourceDS; copy.dstSet = ds; copy.srcBinding = copy.dstBinding = 8;
            copy.descriptorCount = count;
            vkUpdateDescriptorSets(g.device, 0, nullptr, 1, &copy);
        }
        // This invalid descriptor is never accessed by the shader. A partially
        // bound unused slot must not cause a dangling Objective-C dereference.
        g.destroy(unused);
        for (uint32_t round = 0; round < rounds; ++round) {
            memset(output.p, 0xcd, 64);
            auto submitStarted = std::chrono::steady_clock::now();
            g.run([&](VkCommandBuffer cb) {
                VkMemoryBarrier mb{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; mb.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT;
                mb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
                vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, nullptr, 0, nullptr);
                vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
                vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, nullptr);
                uint32_t n = 4; vkCmdPushConstants(cb, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &n);
                vkCmdDispatch(cb, 1, 1, 1);
                mb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT; mb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
                vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, nullptr, 0, nullptr);
            });
            submitMilliseconds += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-submitStarted).count();
            const uint32_t expected[] = {(phase==4 || phase%2) ? 904u : 104u, (phase%2) ? 908u : 108u, 0, 0};
            for (uint32_t i = 0; i < 16; ++i) {
                ++checks;
                uint32_t value = i < 4 ? expected[i] : 0xcdcdcdcdu;
                if (((uint32_t*)output.p)[i] != value) ++mismatches;
            }
        }
    }
    double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-started).count();
    std::ofstream report(argv[2]);
    report << "{\"passed\":" << (mismatches ? "false" : "true") << ",\"descriptors\":" << count
           << ",\"dispatches\":" << rounds*5 << ",\"checkedWords\":" << checks << ",\"mismatches\":" << mismatches
           << ",\"milliseconds\":" << milliseconds << ",\"manyUnusedAliases\":" << (manyUnused ? "true" : "false")
           << ",\"manyUniqueResources\":" << (manyUnique ? "true" : "false")
           << ",\"submitAndWaitMilliseconds\":" << submitMilliseconds
           << ",\"descriptorCopy\":true,\"descriptorFreeReuse\":true,\"descriptorPoolReset\":true"
           << ",\"partialSingleSlotUpdate\":true"
           << ",\"descriptorReplacedBetweenPhases\":true,\"unusedDestroyedSlot\":true}\n";
    std::cout << "DESCRIPTOR_STRESS dispatches=" << rounds*5 << " checkedWords=" << checks << " mismatches=" << mismatches << " milliseconds=" << milliseconds << "\n";
    for (Buf* buf : {&a, &b, &input, &output}) g.destroy(*buf);
    for (auto& buf : unique) g.destroy(buf);
    vkDestroyDescriptorPool(g.device, pool, nullptr); vkDestroyPipeline(g.device, pipe, nullptr);
    vkDestroyShaderModule(g.device, sm, nullptr); vkDestroyPipelineLayout(g.device, pl, nullptr); vkDestroyDescriptorSetLayout(g.device, layout, nullptr);
    return mismatches ? 5 : 0;
} catch (const std::exception& e) { std::cerr << e.what() << "\n"; return 2; } }
