// Actual MoltenVK 3D image -> 2D slice render alias output test.
// Upload/readback baseline first, then clear only one alias slice and compare
// every byte of the original 3D image, including untouched witness slices.
#include "alias_gpu_common.hpp"

static void one(GPU& g,VkFormat fmt,unsigned w,unsigned h,unsigned depth,unsigned slice,unsigned& cases,uint64_t& bytes) {
 const unsigned pixel=fmt==VK_FORMAT_R16G16B16A16_SFLOAT?8:4;
 const size_t size=size_t(w)*h*depth*pixel;
 Buf upload=g.buffer(size,VK_BUFFER_USAGE_TRANSFER_SRC_BIT),read=g.buffer(size,VK_BUFFER_USAGE_TRANSFER_DST_BIT);
 std::vector<unsigned char> expect(size);
 for(size_t i=0;i<size;i++)expect[i]=(i*37+slice*13+fmt)&255;
 memcpy(upload.p,expect.data(),size);memset(read.p,0xCD,size);
 Img im;VkImageCreateInfo ii{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};ii.flags=VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT;ii.imageType=VK_IMAGE_TYPE_3D;ii.format=fmt;ii.extent={w,h,depth};ii.mipLevels=1;ii.arrayLayers=1;ii.samples=VK_SAMPLE_COUNT_1_BIT;ii.tiling=VK_IMAGE_TILING_OPTIMAL;ii.usage=VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;ii.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
 CHECK(vkCreateImage(g.device,&ii,nullptr,&im.image));VkMemoryRequirements req;vkGetImageMemoryRequirements(g.device,im.image,&req);
 VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.allocationSize=req.size;ai.memoryTypeIndex=g.memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
 CHECK(vkAllocateMemory(g.device,&ai,nullptr,&im.memory));CHECK(vkBindImageMemory(g.device,im.image,im.memory,0));
 VkBufferImageCopy region{};region.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};region.imageExtent=ii.extent;
 g.run([&](VkCommandBuffer cb){g.barrier(cb,im.image,VK_IMAGE_LAYOUT_UNDEFINED,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);vkCmdCopyBufferToImage(cb,upload.b,im.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&region);g.barrier(cb,im.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);vkCmdCopyImageToBuffer(cb,im.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,read.b,1,&region);});
 for(size_t i=0;i<size;i++)if(((unsigned char*)read.p)[i]!=expect[i])throw std::runtime_error("Baseline 3D upload/readback mismatch byte="+std::to_string(i));
 std::cout<<"BASELINE format="<<fmt<<" extent="<<w<<"x"<<h<<"x"<<depth<<" bytes="<<size<<" mismatches=0\n"<<std::flush;
 VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};vi.image=im.image;vi.viewType=VK_IMAGE_VIEW_TYPE_2D;vi.format=fmt;vi.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,slice,1};CHECK(vkCreateImageView(g.device,&vi,nullptr,&im.view));
 VkAttachmentDescription attachment{};attachment.format=fmt;attachment.samples=VK_SAMPLE_COUNT_1_BIT;attachment.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR;attachment.storeOp=VK_ATTACHMENT_STORE_OP_STORE;attachment.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE;attachment.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE;attachment.initialLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;attachment.finalLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
 VkAttachmentReference ref{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};VkSubpassDescription sub{};sub.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS;sub.colorAttachmentCount=1;sub.pColorAttachments=&ref;
 VkRenderPassCreateInfo rp{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};rp.attachmentCount=1;rp.pAttachments=&attachment;rp.subpassCount=1;rp.pSubpasses=&sub;VkRenderPass render;CHECK(vkCreateRenderPass(g.device,&rp,nullptr,&render));
 VkFramebufferCreateInfo fb{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};fb.renderPass=render;fb.attachmentCount=1;fb.pAttachments=&im.view;fb.width=w;fb.height=h;fb.layers=1;VkFramebuffer frame;CHECK(vkCreateFramebuffer(g.device,&fb,nullptr,&frame));
 VkClearValue clear{};unsigned char pattern[8]={255,0,255,255};
 if(fmt==VK_FORMAT_R16G16B16A16_SFLOAT){clear.color.float32[0]=1;clear.color.float32[2]=1;clear.color.float32[3]=1;unsigned char half[]={0,60,0,0,0,60,0,60};memcpy(pattern,half,8);}
 else if(fmt==VK_FORMAT_R32_UINT){clear.color.uint32[0]=0xa1b2c3d4;uint32_t v=0xa1b2c3d4;memcpy(pattern,&v,4);}
 else{clear.color.float32[0]=1;clear.color.float32[2]=1;clear.color.float32[3]=1;}
 g.run([&](VkCommandBuffer cb){g.barrier(cb,im.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);VkRenderPassBeginInfo begin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};begin.renderPass=render;begin.framebuffer=frame;begin.renderArea={{0,0},{w,h}};begin.clearValueCount=1;begin.pClearValues=&clear;vkCmdBeginRenderPass(cb,&begin,VK_SUBPASS_CONTENTS_INLINE);vkCmdEndRenderPass(cb);g.barrier(cb,im.image,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);vkCmdCopyImageToBuffer(cb,im.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,read.b,1,&region);});
 for(size_t i=size_t(slice)*w*h*pixel;i<size_t(slice+1)*w*h*pixel;i++)expect[i]=pattern[i%pixel];
 size_t mismatches=0;for(size_t i=0;i<size;i++)if(((unsigned char*)read.p)[i]!=expect[i]){if(mismatches<8)std::cerr<<"DIFF byte="<<i<<" expected="<<unsigned(expect[i])<<" actual="<<unsigned(((unsigned char*)read.p)[i])<<"\n";mismatches++;}
 std::cout<<"ALIAS format="<<fmt<<" extent="<<w<<"x"<<h<<"x"<<depth<<" slice="<<slice<<" checkedBytes="<<size<<" mismatches="<<mismatches<<"\n"<<std::flush;
 if(mismatches)throw std::runtime_error("2D-on-3D alias GPU output differs from original volume; do not enable for game");
 cases++;bytes+=size*2;vkDestroyFramebuffer(g.device,frame,nullptr);vkDestroyRenderPass(g.device,render,nullptr);g.destroy(im);g.destroy(upload);g.destroy(read);
}
int main(){try{GPU g;unsigned cases=0;uint64_t bytes=0;for(VkFormat f:{VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_R16G16B16A16_SFLOAT,VK_FORMAT_R32_UINT})for(unsigned w:{7u,16u,65u})for(unsigned z:{0u,1u,3u})one(g,f,w,w==7?5:17,4,z,cases,bytes);std::cout<<"RESULT PASS cases="<<cases<<" checkedBytes="<<bytes<<" actualGPU=true gameStarted=false fullConformance=false\n";return 0;}catch(const std::exception& e){std::cerr<<"RESULT FAIL "<<e.what()<<"\n";return 2;}}
