#include "../repro-geometry-interface-20261015/geometry_gpu_common.hpp"
#include <chrono>
#include <filesystem>
#include <future>

static std::vector<uint32_t> readSPV(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Missing shader: " + path.string());
    size_t bytes = file.tellg();
    file.seekg(0);
    std::vector<uint32_t> words(bytes / sizeof(uint32_t));
    file.read(reinterpret_cast<char*>(words.data()), bytes);
    return words;
}

static uint32_t expected(uint32_t id, uint32_t salt) {
    uint32_t value = id + salt;
    for (uint32_t i = 0; i < 64; ++i) value = value * 1664525u + 1013904223u + salt;
    return value;
}

int main(int argc, char** argv) try {
    if (argc != 4) throw std::runtime_error("sharded_shader_cache_gpu shader-dir report.json salt-base");
    constexpr uint32_t shaderCount = 8, wordsPerShader = 256;
    uint32_t saltBase = static_cast<uint32_t>(std::stoul(argv[3]));
    GPU gpu;

    VkDescriptorSetLayoutBinding binding{};
    binding.binding = 0;
    binding.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    binding.descriptorCount = 1;
    binding.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    VkDescriptorSetLayoutCreateInfo dsli{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    dsli.bindingCount = 1;
    dsli.pBindings = &binding;
    VkDescriptorSetLayout setLayout;
    CHECK(vkCreateDescriptorSetLayout(gpu.device, &dsli, nullptr, &setLayout));
    VkPipelineLayoutCreateInfo pli{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &setLayout;
    VkPipelineLayout pipelineLayout;
    CHECK(vkCreatePipelineLayout(gpu.device, &pli, nullptr, &pipelineLayout));

    VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, shaderCount};
    VkDescriptorPoolCreateInfo dpi{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    dpi.maxSets = shaderCount;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &poolSize;
    VkDescriptorPool descriptorPool;
    CHECK(vkCreateDescriptorPool(gpu.device, &dpi, nullptr, &descriptorPool));
    std::array<VkDescriptorSetLayout, shaderCount> layouts;
    layouts.fill(setLayout);
    std::array<VkDescriptorSet, shaderCount> sets;
    VkDescriptorSetAllocateInfo dai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    dai.descriptorPool = descriptorPool;
    dai.descriptorSetCount = shaderCount;
    dai.pSetLayouts = layouts.data();
    CHECK(vkAllocateDescriptorSets(gpu.device, &dai, sets.data()));

    std::array<Buf, shaderCount> outputs;
    std::array<VkShaderModule, shaderCount> modules{};
    for (uint32_t i = 0; i < shaderCount; ++i) {
        outputs[i] = gpu.buffer(wordsPerShader * sizeof(uint32_t), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        memset(outputs[i].p, 0, outputs[i].size);
        VkDescriptorBufferInfo bi{outputs[i].b, 0, outputs[i].size};
        VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        write.dstSet = sets[i];
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &bi;
        vkUpdateDescriptorSets(gpu.device, 1, &write, 0, nullptr);
        auto spirv = readSPV(std::filesystem::path(argv[1]) / ("cache-" + std::to_string(i) + ".comp.spv"));
        VkShaderModuleCreateInfo smci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        smci.codeSize = spirv.size() * sizeof(uint32_t);
        smci.pCode = spirv.data();
        CHECK(vkCreateShaderModule(gpu.device, &smci, nullptr, &modules[i]));
    }

    VkPipelineCacheCreateInfo pci{VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
    VkPipelineCache cache;
    CHECK(vkCreatePipelineCache(gpu.device, &pci, nullptr, &cache));
    std::array<VkPipeline, shaderCount> pipelines{};
    std::vector<std::future<VkResult>> jobs;
    auto start = std::chrono::steady_clock::now();
    for (uint32_t i = 0; i < shaderCount; ++i) {
        jobs.emplace_back(std::async(std::launch::async, [&, i] {
            VkPipelineShaderStageCreateInfo stage{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
            stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
            stage.module = modules[i];
            stage.pName = "main";
            VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
            ci.stage = stage;
            ci.layout = pipelineLayout;
            return vkCreateComputePipelines(gpu.device, cache, 1, &ci, nullptr, &pipelines[i]);
        }));
    }
    uint32_t failures = 0;
    for (auto& job : jobs) if (job.get() != VK_SUCCESS) ++failures;
    double compileMS = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    if (failures) throw std::runtime_error("Pipeline failures=" + std::to_string(failures));

    for (uint32_t i = 0; i < shaderCount; ++i) {
        gpu.run([&](VkCommandBuffer cb) {
            vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelines[i]);
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &sets[i], 0, nullptr);
            vkCmdDispatch(cb, wordsPerShader / 64, 1, 1);
            VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
            barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
            barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                                 0, 1, &barrier, 0, nullptr, 0, nullptr);
        });
    }
    uint32_t mismatches = 0;
    for (uint32_t i = 0; i < shaderCount; ++i) {
        auto* values = static_cast<uint32_t*>(outputs[i].p);
        for (uint32_t j = 0; j < wordsPerShader; ++j)
            if (values[j] != expected(j, saltBase + i * 17u + 3u)) ++mismatches;
    }

    std::ofstream report(argv[2]);
    report << "{\"passed\":" << (mismatches ? "false" : "true")
           << ",\"concurrentPipelineRequests\":8,\"checkedWords\":2048,\"mismatches\":"
           << mismatches << ",\"compileMilliseconds\":" << compileMS << "}\n";
    std::cout << "SHARDED_CACHE compileMS=" << compileMS << " mismatches=" << mismatches << "\n";

    vkDeviceWaitIdle(gpu.device);
    for (uint32_t i = 0; i < shaderCount; ++i) {
        vkDestroyPipeline(gpu.device, pipelines[i], nullptr);
        vkDestroyShaderModule(gpu.device, modules[i], nullptr);
        gpu.destroy(outputs[i]);
    }
    vkDestroyPipelineCache(gpu.device, cache, nullptr);
    vkDestroyDescriptorPool(gpu.device, descriptorPool, nullptr);
    vkDestroyPipelineLayout(gpu.device, pipelineLayout, nullptr);
    vkDestroyDescriptorSetLayout(gpu.device, setLayout, nullptr);
    return mismatches ? 4 : 0;
} catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
}
