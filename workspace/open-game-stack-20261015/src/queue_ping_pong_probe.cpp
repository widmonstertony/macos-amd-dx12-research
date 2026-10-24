// Bounded real-GPU reproduction for a consumer-first cross-queue timeline ping-pong.
// Queue A waits for B and signals A; queue B signals B and then waits for A.
#include "gpu_common.hpp"
#include <chrono>

static VkSemaphore makeTimeline(VkDevice device) {
    VkSemaphoreTypeCreateInfo type{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
    type.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    VkSemaphoreCreateInfo ci{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    ci.pNext = &type;
    VkSemaphore semaphore;
    CHECK(vkCreateSemaphore(device, &ci, nullptr, &semaphore));
    return semaphore;
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    std::ofstream output(argv[1]);
    try {
        GPU gpu;
        uint32_t count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(gpu.physical, &count, nullptr);
        std::vector<VkQueueFamilyProperties> props(count);
        vkGetPhysicalDeviceQueueFamilyProperties(gpu.physical, &count, props.data());
        uint32_t graphics = ~0u, transfer = ~0u;
        for (uint32_t i = 0; i < count; ++i) {
            if (graphics == ~0u && (props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) graphics = i;
            if (transfer == ~0u && (props[i].queueFlags & VK_QUEUE_TRANSFER_BIT) &&
                !(props[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT))) transfer = i;
        }
        if (graphics == ~0u) throw std::runtime_error("No graphics queue");
        if (transfer == ~0u) transfer = graphics;

        std::vector<uint32_t> families{graphics, transfer};
        std::sort(families.begin(), families.end());
        families.erase(std::unique(families.begin(), families.end()), families.end());
        float priority = 1.0f;
        std::vector<VkDeviceQueueCreateInfo> queueInfos;
        for (auto family : families) {
            VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
            qi.queueFamilyIndex = family;
            qi.queueCount = 1;
            qi.pQueuePriorities = &priority;
            queueInfos.push_back(qi);
        }
        VkPhysicalDeviceTimelineSemaphoreFeatures timelineFeature{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
        timelineFeature.timelineSemaphore = VK_TRUE;
        const char* extension = "VK_KHR_portability_subset";
        VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        di.pNext = &timelineFeature;
        di.queueCreateInfoCount = (uint32_t)queueInfos.size();
        di.pQueueCreateInfos = queueInfos.data();
        di.enabledExtensionCount = 1;
        di.ppEnabledExtensionNames = &extension;
        VkDevice device;
        CHECK(vkCreateDevice(gpu.physical, &di, nullptr, &device));

        VkQueue producer, consumer;
        vkGetDeviceQueue(device, graphics, 0, &producer);
        vkGetDeviceQueue(device, transfer, 0, &consumer);
        VkCommandPool pools[2];
        VkCommandBuffer commands[2];
        uint32_t selected[2]{transfer, graphics};
        for (unsigned i = 0; i < 2; ++i) {
            VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
            pi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            pi.queueFamilyIndex = selected[i];
            CHECK(vkCreateCommandPool(device, &pi, nullptr, &pools[i]));
            VkCommandBufferAllocateInfo ai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
            ai.commandPool = pools[i];
            ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            ai.commandBufferCount = 1;
            CHECK(vkAllocateCommandBuffers(device, &ai, &commands[i]));
        }

        constexpr uint32_t words = 4096, rounds = 1024;
        VkBuffer buffers[2];
        VkDeviceMemory memories[2];
        void* maps[2];
        for (unsigned i = 0; i < 2; ++i) {
            VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
            bi.size = words * sizeof(uint32_t);
            bi.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
            bi.sharingMode = families.size() > 1 ? VK_SHARING_MODE_CONCURRENT : VK_SHARING_MODE_EXCLUSIVE;
            bi.queueFamilyIndexCount = families.size() > 1 ? (uint32_t)families.size() : 0;
            bi.pQueueFamilyIndices = families.size() > 1 ? families.data() : nullptr;
            CHECK(vkCreateBuffer(device, &bi, nullptr, &buffers[i]));
            VkMemoryRequirements req;
            vkGetBufferMemoryRequirements(device, buffers[i], &req);
            VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
            ai.allocationSize = req.size;
            ai.memoryTypeIndex = gpu.memoryType(req.memoryTypeBits,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            CHECK(vkAllocateMemory(device, &ai, nullptr, &memories[i]));
            CHECK(vkBindBufferMemory(device, buffers[i], memories[i], 0));
            CHECK(vkMapMemory(device, memories[i], 0, bi.size, 0, &maps[i]));
        }

        VkSemaphore eventA = makeTimeline(device), eventB = makeTimeline(device);
        uint64_t checked = 0, mismatches = 0;
        double slowestMS = 0;
        auto began = std::chrono::steady_clock::now();
        for (uint64_t round = 1; round <= rounds; ++round) {
            auto start = std::chrono::steady_clock::now();
            uint32_t pattern = 0x51a7c300u ^ (uint32_t)round;
            for (unsigned i = 0; i < 2; ++i) {
                CHECK(vkResetCommandPool(device, pools[i], 0));
                VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
                bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
                CHECK(vkBeginCommandBuffer(commands[i], &bi));
            }
            vkCmdFillBuffer(commands[0], buffers[0], 0, words * sizeof(uint32_t), pattern);
            VkBufferCopy copy{0, 0, words * sizeof(uint32_t)};
            vkCmdCopyBuffer(commands[1], buffers[0], buffers[1], 1, &copy);
            VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
            barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
            vkCmdPipelineBarrier(commands[1], VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                                 0, 1, &barrier, 0, nullptr, 0, nullptr);
            CHECK(vkEndCommandBuffer(commands[0]));
            CHECK(vkEndCommandBuffer(commands[1]));

            VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            VkTimelineSemaphoreSubmitInfo consumerTimeline{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
            consumerTimeline.waitSemaphoreValueCount = 1;
            consumerTimeline.pWaitSemaphoreValues = &round;
            consumerTimeline.signalSemaphoreValueCount = 1;
            consumerTimeline.pSignalSemaphoreValues = &round;
            VkSubmitInfo consumerSubmit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
            consumerSubmit.pNext = &consumerTimeline;
            consumerSubmit.waitSemaphoreCount = 1;
            consumerSubmit.pWaitSemaphores = &eventB;
            consumerSubmit.pWaitDstStageMask = &waitStage;
            consumerSubmit.commandBufferCount = 1;
            consumerSubmit.pCommandBuffers = &commands[0];
            consumerSubmit.signalSemaphoreCount = 1;
            consumerSubmit.pSignalSemaphores = &eventA;
            CHECK(vkQueueSubmit(consumer, 1, &consumerSubmit, VK_NULL_HANDLE));

            VkTimelineSemaphoreSubmitInfo signalTimeline{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
            signalTimeline.signalSemaphoreValueCount = 1;
            signalTimeline.pSignalSemaphoreValues = &round;
            VkSubmitInfo signalSubmit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
            signalSubmit.pNext = &signalTimeline;
            signalSubmit.signalSemaphoreCount = 1;
            signalSubmit.pSignalSemaphores = &eventB;
            CHECK(vkQueueSubmit(producer, 1, &signalSubmit, VK_NULL_HANDLE));

            VkTimelineSemaphoreSubmitInfo finishTimeline{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
            finishTimeline.waitSemaphoreValueCount = 1;
            finishTimeline.pWaitSemaphoreValues = &round;
            VkSubmitInfo finishSubmit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
            finishSubmit.pNext = &finishTimeline;
            finishSubmit.waitSemaphoreCount = 1;
            finishSubmit.pWaitSemaphores = &eventA;
            finishSubmit.pWaitDstStageMask = &waitStage;
            finishSubmit.commandBufferCount = 1;
            finishSubmit.pCommandBuffers = &commands[1];
            CHECK(vkQueueSubmit(producer, 1, &finishSubmit, VK_NULL_HANDLE));

            VkSemaphoreWaitInfo wi{VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};
            wi.semaphoreCount = 1;
            wi.pSemaphores = &eventA;
            wi.pValues = &round;
            CHECK(vkWaitSemaphores(device, &wi, 2000000000ull));
            CHECK(vkQueueWaitIdle(producer));
            auto* data = static_cast<uint32_t*>(maps[1]);
            for (uint32_t i = 0; i < words; ++i) {
                ++checked;
                if (data[i] != pattern) ++mismatches;
            }
            slowestMS = std::max(slowestMS,
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
        }
        CHECK(vkDeviceWaitIdle(device));
        double totalMS = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - began).count();
        output << "{\"passed\":" << (mismatches ? "false" : "true")
               << ",\"consumerFamily\":" << transfer << ",\"producerFamily\":" << graphics
               << ",\"rounds\":" << rounds << ",\"checkedWords\":" << checked
               << ",\"mismatches\":" << mismatches << ",\"totalMilliseconds\":" << totalMS
               << ",\"slowestRoundMilliseconds\":" << slowestMS << "}\n";
        vkDestroySemaphore(device, eventA, nullptr);
        vkDestroySemaphore(device, eventB, nullptr);
        for (unsigned i = 0; i < 2; ++i) {
            vkUnmapMemory(device, memories[i]);
            vkDestroyBuffer(device, buffers[i], nullptr);
            vkFreeMemory(device, memories[i], nullptr);
            vkDestroyCommandPool(device, pools[i], nullptr);
        }
        vkDestroyDevice(device, nullptr);
        return mismatches ? 1 : 0;
    } catch (const std::exception& e) {
        output << "{\"passed\":false,\"exception\":\"" << e.what() << "\"}\n";
        return 1;
    }
}
