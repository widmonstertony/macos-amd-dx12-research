#pragma once
#include <vulkan/vulkan.h>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <vector>

// Public caller-side contract for the independent shader lowering. This is
// deliberately not installed in MoltenVK and never changes its feature flags.
// Null source descriptors become valid, nonzero-filled witness allocations;
// metadata still marks them null, so shader reads/writes must be suppressed.
struct R2Bindings {
    using Meta = std::array<uint32_t,4>;
    std::vector<Meta> metadata;
    VkDescriptorBufferInfo dummyBuffer;
    VkDescriptorImageInfo dummyImage;
    uint32_t nullBuffers=0, nullImages=0;
    R2Bindings(size_t slots, VkDescriptorBufferInfo b, VkDescriptorImageInfo i)
      :metadata(slots,Meta{0,0,0,0}),dummyBuffer(b),dummyImage(i) {}
    VkDescriptorBufferInfo buffer(size_t slot,VkBuffer buffer,VkDeviceSize offset,VkDeviceSize range) {
        if (slot>=metadata.size()) throw std::runtime_error("R2 buffer metadata slot out of range");
        if (buffer==VK_NULL_HANDLE) {
            if (!dummyBuffer.buffer || !dummyBuffer.range || dummyBuffer.range==VK_WHOLE_SIZE)
                throw std::runtime_error("R2 null buffer requires a valid, resolved dummy binding");
            metadata[slot]={0,0,0,0}; ++nullBuffers; return dummyBuffer;
        }
        if (range>UINT32_MAX) throw std::runtime_error("R2 buffer metadata range unsupported");
        if (range==0 || range==VK_WHOLE_SIZE) throw std::runtime_error("R2 needs resolved nonzero descriptor byte range");
        metadata[slot]={1,uint32_t(range),0,0};
        return {buffer,offset,range};
    }
    VkDescriptorImageInfo image(size_t slot,VkImageView view,uint32_t width,uint32_t height) {
        if (slot>=metadata.size()) throw std::runtime_error("R2 image metadata slot out of range");
        if (view==VK_NULL_HANDLE) {
            if (!dummyImage.imageView) throw std::runtime_error("R2 null image requires a valid dummy view");
            metadata[slot]={0,0,0,0};++nullImages;return dummyImage;
        }
        if (!width||!height) throw std::runtime_error("R2 image dimensions invalid");
        metadata[slot]={1,width,height,0};return {VK_NULL_HANDLE,view,VK_IMAGE_LAYOUT_GENERAL};
    }
};
