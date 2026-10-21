// Generalized helper-binding regression; derived from owned heap graphics probe.
#include "gpu_common.hpp"
#include <chrono>

static VkDeviceSize alignUp(VkDeviceSize value, VkDeviceSize alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static VkShaderModule loadShader(VkDevice device, const char* path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Missing shader");
    size_t bytes = size_t(file.tellg()); file.seekg(0);
    std::vector<uint32_t> code(bytes / 4); file.read(reinterpret_cast<char*>(code.data()), bytes);
    VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; info.codeSize = bytes; info.pCode = code.data();
    VkShaderModule shader = VK_NULL_HANDLE; CHECK(vkCreateShaderModule(device, &info, nullptr, &shader)); return shader;
}

int main(int argc, char** argv) { try {
    if (argc != 4) throw std::runtime_error("heap_graphics_probe vertex.spv fragment.spv output.json");
    GPU g;
    // Reuse the same bindless resources across render -> blit -> render
    // transitions within a single submission, checking every intermediate image.
    uint32_t encoderPasses = 1;
    if (const char* value = getenv("GPU_ENCODER_TRANSITIONS")) encoderPasses = std::clamp(uint32_t(atoi(value)),1u,64u);
    constexpr uint32_t count = 64;
    constexpr VkDeviceSize bufferSize = 256;
    constexpr auto bufferUsage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    std::array<VkBuffer, count> buffers{};
    uint32_t memoryTypeBits = ~0u; VkDeviceSize stride = 0;
    for (uint32_t i = 0; i < count; ++i) {
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; info.size = bufferSize; info.usage = bufferUsage; info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        CHECK(vkCreateBuffer(g.device, &info, nullptr, &buffers[i]));
        VkMemoryRequirements req{}; vkGetBufferMemoryRequirements(g.device, buffers[i], &req);
        stride = std::max(stride, alignUp(req.size, req.alignment)); memoryTypeBits &= req.memoryTypeBits;
    }
    VkMemoryAllocateInfo memoryInfo{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    memoryInfo.allocationSize = stride * count; memoryInfo.memoryTypeIndex = g.memoryType(memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory sharedMemory = VK_NULL_HANDLE; CHECK(vkAllocateMemory(g.device, &memoryInfo, nullptr, &sharedMemory));
    for (uint32_t i = 0; i < count; ++i) CHECK(vkBindBufferMemory(g.device, buffers[i], sharedMemory, stride * i));

    VkDescriptorSetLayoutBinding binding{8, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, count, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
    VkDescriptorBindingFlags bindingFlag = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
    VkDescriptorSetLayoutBindingFlagsCreateInfo flagsInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO};
    flagsInfo.bindingCount = 1; flagsInfo.pBindingFlags = &bindingFlag;
    VkDescriptorSetLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    layoutInfo.pNext = &flagsInfo; layoutInfo.bindingCount = 1; layoutInfo.pBindings = &binding;
    VkDescriptorSetLayout layout = VK_NULL_HANDLE; CHECK(vkCreateDescriptorSetLayout(g.device, &layoutInfo, nullptr, &layout));
    VkPipelineLayoutCreateInfo pipelineLayoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pipelineLayoutInfo.setLayoutCount = 1; pipelineLayoutInfo.pSetLayouts = &layout;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE; CHECK(vkCreatePipelineLayout(g.device, &pipelineLayoutInfo, nullptr, &pipelineLayout));

    Img color;
    VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM; imageInfo.extent = {8, 8, 1}; imageInfo.mipLevels = 1; imageInfo.arrayLayers = 1;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT; imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT; imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    CHECK(vkCreateImage(g.device, &imageInfo, nullptr, &color.image));
    VkMemoryRequirements imageReq{}; vkGetImageMemoryRequirements(g.device, color.image, &imageReq);
    VkMemoryAllocateInfo imageMemoryInfo{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; imageMemoryInfo.allocationSize = imageReq.size;
    imageMemoryInfo.memoryTypeIndex = g.memoryType(imageReq.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CHECK(vkAllocateMemory(g.device, &imageMemoryInfo, nullptr, &color.memory)); CHECK(vkBindImageMemory(g.device, color.image, color.memory, 0));
    VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO}; viewInfo.image = color.image; viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = imageInfo.format; viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    CHECK(vkCreateImageView(g.device, &viewInfo, nullptr, &color.view));

    VkAttachmentDescription attachment{}; attachment.format = imageInfo.format; attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference attachmentRef{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass{}; subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; subpass.colorAttachmentCount = 1; subpass.pColorAttachments = &attachmentRef;
    VkSubpassDependency dependency{0, VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, 0};
    VkRenderPassCreateInfo renderPassInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO}; renderPassInfo.attachmentCount = 1; renderPassInfo.pAttachments = &attachment;
    renderPassInfo.subpassCount = 1; renderPassInfo.pSubpasses = &subpass; renderPassInfo.dependencyCount = 1; renderPassInfo.pDependencies = &dependency;
    VkRenderPass renderPass = VK_NULL_HANDLE; CHECK(vkCreateRenderPass(g.device, &renderPassInfo, nullptr, &renderPass));
    VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO}; framebufferInfo.renderPass = renderPass;
    framebufferInfo.attachmentCount = 1; framebufferInfo.pAttachments = &color.view; framebufferInfo.width = 8; framebufferInfo.height = 8; framebufferInfo.layers = 1;
    VkFramebuffer framebuffer = VK_NULL_HANDLE; CHECK(vkCreateFramebuffer(g.device, &framebufferInfo, nullptr, &framebuffer));

    VkShaderModule vertexShader = loadShader(g.device, argv[1]), fragmentShader = loadShader(g.device, argv[2]);
    VkPipelineShaderStageCreateInfo stages[2]{};
    for (uint32_t i = 0; i < 2; ++i) { stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; stages[i].stage = i ? VK_SHADER_STAGE_FRAGMENT_BIT : VK_SHADER_STAGE_VERTEX_BIT; stages[i].module = i ? fragmentShader : vertexShader; stages[i].pName = "main"; }
    VkPipelineVertexInputStateCreateInfo vertexInput{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport viewport{0, 0, 8, 8, 0, 1}; VkRect2D scissor{{0, 0}, {8, 8}};
    VkPipelineViewportStateCreateInfo viewportState{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO}; viewportState.viewportCount = 1; viewportState.pViewports = &viewport; viewportState.scissorCount = 1; viewportState.pScissors = &scissor;
    VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO}; raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blendAttachment{}; blendAttachment.colorWriteMask = 15;
    VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; blend.attachmentCount = 1; blend.pAttachments = &blendAttachment;
    VkGraphicsPipelineCreateInfo graphicsInfo{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO}; graphicsInfo.stageCount = 2; graphicsInfo.pStages = stages;
    graphicsInfo.pVertexInputState = &vertexInput; graphicsInfo.pInputAssemblyState = &assembly; graphicsInfo.pViewportState = &viewportState;
    graphicsInfo.pRasterizationState = &raster; graphicsInfo.pMultisampleState = &multisample; graphicsInfo.pColorBlendState = &blend;
    graphicsInfo.layout = pipelineLayout; graphicsInfo.renderPass = renderPass;
    VkPipeline pipeline = VK_NULL_HANDLE; CHECK(vkCreateGraphicsPipelines(g.device, VK_NULL_HANDLE, 1, &graphicsInfo, nullptr, &pipeline));

    VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, count};
    VkDescriptorPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; poolInfo.maxSets = 1; poolInfo.poolSizeCount = 1; poolInfo.pPoolSizes = &poolSize;
    VkDescriptorPool pool = VK_NULL_HANDLE; CHECK(vkCreateDescriptorPool(g.device, &poolInfo, nullptr, &pool));
    VkDescriptorSetVariableDescriptorCountAllocateInfo variableInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO}; variableInfo.descriptorSetCount = 1; variableInfo.pDescriptorCounts = &count;
    VkDescriptorSetAllocateInfo setInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; setInfo.pNext = &variableInfo; setInfo.descriptorPool = pool; setInfo.descriptorSetCount = 1; setInfo.pSetLayouts = &layout;
    VkDescriptorSet set = VK_NULL_HANDLE; CHECK(vkAllocateDescriptorSets(g.device, &setInfo, &set));
    std::vector<VkDescriptorBufferInfo> descriptorInfo(count);
    for (uint32_t i = 0; i < count; ++i) descriptorInfo[i] = {buffers[i], 0, bufferSize};
    VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET}; write.dstSet = set; write.dstBinding = 8; write.descriptorCount = count; write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; write.pBufferInfo = descriptorInfo.data();
    vkUpdateDescriptorSets(g.device, 1, &write, 0, nullptr);
    Buf pixels = g.buffer(256 * encoderPasses, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    std::vector<uint32_t> expected(count);
    for (uint32_t i = 0; i < count; ++i) expected[i] = 0xff000000u | ((i + 1) & 255u) | (((i * 3 + 1) & 255u) << 8u) | (((i * 5 + 1) & 255u) << 16u);
    std::sort(expected.begin(), expected.end());

    uint64_t mismatches = 0; auto started = std::chrono::steady_clock::now();
    for (uint32_t round = 0; round < 20; ++round) {
        memset(pixels.p, 0xcd, pixels.size);
        g.run([&](VkCommandBuffer cb) {
            if (!round) {
                for (uint32_t i = 0; i < count; ++i) vkCmdFillBuffer(cb, buffers[i], 0, bufferSize, expected[i]);
                VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
                vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 1, &barrier, 0, nullptr, 0, nullptr);
            }
            for (uint32_t pass = 0; pass < encoderPasses; ++pass) {
            VkClearValue clear{}; VkRenderPassBeginInfo begin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO}; begin.renderPass = renderPass; begin.framebuffer = framebuffer;
            begin.renderArea = {{0, 0}, {8, 8}}; begin.clearValueCount = 1; begin.pClearValues = &clear;
            vkCmdBeginRenderPass(cb, &begin, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &set, 0, nullptr); vkCmdDraw(cb, 3, 1, 0, 0);
            VkClearAttachment helperClear{};helperClear.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;helperClear.colorAttachment=0;helperClear.clearValue.color.float32[3]=1.0f;
            VkClearRect helperRect{};helperRect.rect.extent={8,8};helperRect.layerCount=1;
            vkCmdClearAttachments(cb,1,&helperClear,1,&helperRect);
            // No Vulkan descriptors change or rebind between the helper and draw.
            vkCmdDraw(cb,3,1,0,0); vkCmdEndRenderPass(cb);
            VkBufferImageCopy copy{}; copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}; copy.imageExtent = {8, 8, 1};
            copy.bufferOffset = pass * 256;
            vkCmdCopyImageToBuffer(cb, color.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, pixels.b, 1, &copy);
            if (pass + 1 < encoderPasses) {
                VkMemoryBarrier nextRender{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
                nextRender.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; nextRender.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,0,1,&nextRender,0,nullptr,0,nullptr);
            }
            }
            VkMemoryBarrier hostBarrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; hostBarrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; hostBarrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &hostBarrier, 0, nullptr, 0, nullptr);
        });
        for (uint32_t pass = 0; pass < encoderPasses; ++pass) {
        std::vector<uint32_t> actual(static_cast<uint32_t*>(pixels.p) + pass * count, static_cast<uint32_t*>(pixels.p) + (pass + 1) * count); std::sort(actual.begin(), actual.end());
        for (uint32_t i = 0; i < count; ++i) if (actual[i] != expected[i]) ++mismatches;
        }
    }
    double elapsedMS = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    std::ofstream report(argv[3]); report << "{\"passed\":" << (mismatches ? "false" : "true") << ",\"sharedAllocationResources\":64,\"rounds\":20,\"passesPerSubmission\":" << encoderPasses << ",\"checkedPixels\":" << 1280 * encoderPasses << ",\"mismatches\":" << mismatches << ",\"milliseconds\":" << elapsedMS << "}\n";
    std::cout << "HEAP_GRAPHICS_STRESS resources=64 rounds=20 mismatches=" << mismatches << " milliseconds=" << elapsedMS << "\n";

    g.destroy(pixels); vkDestroyDescriptorPool(g.device, pool, nullptr); vkDestroyPipeline(g.device, pipeline, nullptr);
    vkDestroyShaderModule(g.device, fragmentShader, nullptr); vkDestroyShaderModule(g.device, vertexShader, nullptr);
    vkDestroyFramebuffer(g.device, framebuffer, nullptr); vkDestroyRenderPass(g.device, renderPass, nullptr); g.destroy(color);
    vkDestroyPipelineLayout(g.device, pipelineLayout, nullptr); vkDestroyDescriptorSetLayout(g.device, layout, nullptr);
    for (VkBuffer buffer : buffers) vkDestroyBuffer(g.device, buffer, nullptr); vkFreeMemory(g.device, sharedMemory, nullptr);
    return mismatches ? 5 : 0;
} catch (const std::exception& error) { std::cerr << "ERROR " << error.what() << "\n"; return 2; }
}
