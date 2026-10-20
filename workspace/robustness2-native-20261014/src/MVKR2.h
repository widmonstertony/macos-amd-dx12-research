#pragma once
#include <Metal/Metal.h>
#include <array>
#include <vector>
#include <cstdint>
class MVKShaderModule;
class MVKCommandEncoder;
class MVKPipelineLayout;
struct MVKDescriptorSet;
struct MVKR2Resource { uint32_t set,binding,slot,count; bool buffer; };
struct MVKR2State {
    std::vector<MVKR2Resource> resources;
    uint32_t slots=0, metalIndex=0;
};
bool mvkR2Enabled();
bool mvkR2Compile(MVKShaderModule*,MVKPipelineLayout*,std::vector<uint32_t>&,MVKR2State&);
void mvkR2Bind(id<MTLComputeCommandEncoder>,MVKCommandEncoder&,MVKDescriptorSet*const*,const MVKR2State&);
id<MTLBuffer> mvkR2DummyBuffer(id<MTLDevice>);
id<MTLTexture> mvkR2DummyTexture(id<MTLDevice>,bool texel=false);

void mvkR2BindRender(id<MTLRenderCommandEncoder>,MVKCommandEncoder&,MVKDescriptorSet*const*,const MVKR2State&,bool fragment);
