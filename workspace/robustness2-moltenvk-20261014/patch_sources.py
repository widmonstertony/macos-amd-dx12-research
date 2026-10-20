#!/usr/bin/env python3
"""Apply the reviewed isolated research hooks to the pinned upstream tree."""
import pathlib, shutil, sys
ROOT=pathlib.Path(__file__).resolve().parent
VENDOR=ROOT/'vendor/MoltenVK-db66022459ffb663aa2b50f6b018bc2e124f5edf'
GPU=VENDOR/'MoltenVK/MoltenVK/GPUObjects'
def edit(path,old,new,count=1):
    s=path.read_text()
    if new in s:return
    if s.count(old)!=count:raise RuntimeError(f'Unexpected upstream source: {path}: {s.count(old)} matches')
    path.write_text(s.replace(old,new))
for name in ('MVKR2.h','MVKR2.mm'):shutil.copy2(ROOT/'src'/name,GPU/name)
edit(GPU/'MVKPipeline.h','#pragma mark MVKComputePipeline\n','#include "MVKR2.h"\n\n#pragma mark MVKComputePipeline\n')
edit(GPU/'MVKPipeline.h','bool allowsDispatchBase() { return _allowsDispatchBase; }','bool allowsDispatchBase() { return _allowsDispatchBase; }\n\tMVKR2State _r2;')
edit(GPU/'MVKPipeline.mm','\t_module = getOrCreateShaderModule(_device, pSS, _ownsModule);', '''\t_module = getOrCreateShaderModule(_device, pSS, _ownsModule);
    if (mvkR2Enabled()) {
        std::vector<uint32_t> guarded;
        if (!mvkR2Compile(_module, _layout, guarded, _r2)) {
            setConfigurationResult(reportError(VK_ERROR_FEATURE_NOT_PRESENT, "R2 research compiler refused unsupported pipeline; no unprotected fallback."));
            return MVKMTLFunctionNull;
        }
        VkShaderModuleCreateInfo info = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        info.codeSize=guarded.size()*4;info.pCode=guarded.data();
        if (_ownsModule) delete _module;
        _module=new MVKShaderModule(_device,&info);_ownsModule=true;
    }''')
edit(GPU/'MVKPipeline.mm','    MVKMTLFunction func = _module->getMTLFunction(&shaderConfig, pSS->pSpecializationInfo, this, pStageFB);','''    if (_r2.slots) {
        mvk::MSLResourceBinding hidden;
        hidden.resourceBinding.stage=spv::ExecutionModelGLCompute;
        hidden.resourceBinding.desc_set=31;hidden.resourceBinding.binding=0;
        hidden.resourceBinding.count=1;hidden.resourceBinding.basetype=SPIRV_CROSS_NAMESPACE::SPIRType::Void;
        hidden.resourceBinding.msl_buffer=_r2.metalIndex;
        shaderConfig.resourceBindings.push_back(hidden);
        shaderConfig.discreteDescriptorSets.push_back(31);
    }
    MVKMTLFunction func = _module->getMTLFunction(&shaderConfig, pSS->pSpecializationInfo, this, pStageFB);''')
edit(GPU/'MVKPipeline.mm','\tauto& funcRslts = func.shaderConversionResults;\n\tpopulateResourceUsage(_stageResources,', '''    // Hidden resources have a private Metal binding and are not Vulkan sets.
    if (_r2.slots) {
        auto& bindings=shaderConfig.resourceBindings;
        bindings.erase(std::remove_if(bindings.begin(),bindings.end(),[](const auto& b){return b.resourceBinding.desc_set==31;}),bindings.end());
        auto& discrete=shaderConfig.discreteDescriptorSets;
        discrete.erase(std::remove(discrete.begin(),discrete.end(),31),discrete.end());
    }
\tauto& funcRslts = func.shaderConversionResults;
\tpopulateResourceUsage(_stageResources,''')
state=VENDOR/'MoltenVK/MoltenVK/Commands/MVKCommandEncoderState.mm'
edit(state,'\tbindVulkanComputeToMetalCompute(encoder, mvkEncoder, vk, vkShared, *this, pipeline);','\tbindVulkanComputeToMetalCompute(encoder, mvkEncoder, vk, vkShared, *this, pipeline);\n\tmvkR2Bind(encoder, mvkEncoder, vk._descriptorSets, pipeline->_r2);')
desc=GPU/'MVKDescriptorSet.mm'
edit(desc,'#include "MVKDescriptorSet.h"','#include "MVKDescriptorSet.h"\n#include "MVKR2.h"')
edit(desc,'MVKArgBufEncoder(id<MTLArgumentEncoder> enc, char* base): dst(reinterpret_cast<MVKGPUResource*>(base)) {}','id<MTLDevice> device;\n\tMVKArgBufEncoder(id<MTLArgumentEncoder> enc, char* base, id<MTLDevice> dev): dst(reinterpret_cast<MVKGPUResource*>(base)),device(dev) {}')
edit(desc,'MVKArgBufEncoder(id<MTLArgumentEncoder> enc_, char* base): enc(enc_), base(0) {}','id<MTLDevice> device;\n\tMVKArgBufEncoder(id<MTLArgumentEncoder> enc_, char* base, id<MTLDevice> dev): enc(enc_), base(0),device(dev) {}')
edit(desc,'dst[index].resource = tex.gpuResourceID;','dst[index].resource = (tex ? tex : mvkR2DummyTexture(device)).gpuResourceID;')
edit(desc,'dst[index].gpuAddress = buf.gpuAddress + offset;','dst[index].gpuAddress = (buf ? buf : mvkR2DummyBuffer(device)).gpuAddress + offset;')
edit(desc,'void setNullTexture(size_t index = 0) { dst[index].resource = {}; }','void setNullTexture(size_t index = 0) { setTexture((id<MTLTexture>)nil,index); }')
edit(desc,'void setNullBuffer (size_t index = 0) { dst[index].gpuAddress = 0; }','void setNullBuffer (size_t index = 0) { setBuffer(nil,0,index); }')
edit(desc,'dst[index].gpuAddress = addr;','dst[index].gpuAddress = addr ? addr : mvkR2DummyBuffer(device).gpuAddress;')
edit(desc,'[enc setTexture:tex atIndex:base + index];','[enc setTexture:tex ? tex : mvkR2DummyTexture(device) atIndex:base + index];')
edit(desc,'[enc setBuffer:buf offset:static_cast<NSUInteger>(offset) atIndex:base + index];','[enc setBuffer:buf ? buf : mvkR2DummyBuffer(device) offset:static_cast<NSUInteger>(offset) atIndex:base + index];')
edit(desc,'void setNullTexture(size_t index = 0) { [enc setTexture:nil atIndex:base + index]; }','void setNullTexture(size_t index = 0) { setTexture((id<MTLTexture>)nil,index); }')
edit(desc,'void setNullBuffer (size_t index = 0) { [enc setBuffer:nil offset:0 atIndex:base + index]; }','void setNullBuffer (size_t index = 0) { setBuffer(nil,0,index); }')
edit(desc,'[enc setTexture:img ? img->getMTLTexture() : nil atIndex:base + index];','setTexture(img ? img->getMTLTexture() : nil,index);')
edit(desc,'[enc setBuffer:mtlbuf offset:offset atIndex:base + index];','[enc setBuffer:mtlbuf ? mtlbuf : mvkR2DummyBuffer(device) offset:offset atIndex:base + index];')
edit(desc,'id<MTLArgumentEncoder> enc_, char* base, const uint32_t* auxOffsets,','id<MTLArgumentEncoder> enc_, char* base, const uint32_t* auxOffsets, id<MTLDevice> device,')
edit(desc,'MVKArgBufEncoder<ArgBufMode> enc(enc_, base);','MVKArgBufEncoder<ArgBufMode> enc(enc_, base, device);')
edit(desc,'(*binding, enc, base, auxOffsets, src, srcStride, srcType, start, count)','(*binding, enc, base, auxOffsets, set->layout->getMTLDevice(), src, srcStride, srcType, start, count)')
edit(desc,'(*binding, enc, base, auxOffsets, src, srcStride, srcType, start, numWrite)','(*binding, enc, base, auxOffsets, set->layout->getMTLDevice(), src, srcStride, srcType, start, numWrite)')
cm=VENDOR/'MoltenVK/CMakeLists.txt'
extra='''
# Isolated research compiler paths. No installed runtime is modified.
target_compile_definitions(MoltenVK PRIVATE
    MVK_R2_COMPILER="'''+str(ROOT/'src/driver_lower.py')+'''"
    MVK_R2_PYTHON="'''+sys.executable+'''"
    MVK_R2_RUNTIME_DIR="'''+str(ROOT/'runtime')+'''"
)
'''
if 'MVK_R2_COMPILER=' not in cm.read_text():cm.write_text(cm.read_text()+extra)
# Preserve nonzero null witnesses through the argument-encoder copy path too.
edit(desc,'[enc setTexture:tex && device->getLiveResources().isLive(tex) ? tex : nil atIndex:start + i];','[enc setTexture:tex && device->getLiveResources().isLive(tex) ? tex : mvkR2DummyTexture(device->getPhysicalDevice()->getMTLDevice()) atIndex:start + i];')
edit(desc,'[enc setBuffer:nil offset:0 atIndex:start + i];','[enc setBuffer:mvkR2DummyBuffer(device->getPhysicalDevice()->getMTLDevice()) offset:0 atIndex:start + i];')
# The opt-in mode is compute-only; graphics must never silently bypass guards.
vk=VENDOR/'MoltenVK/MoltenVK/Vulkan/vulkan.mm'
edit(vk,'\tVkResult rslt = mvkDev->createPipelines<MVKGraphicsPipeline, VkGraphicsPipelineCreateInfo>', '    if (mvkR2Enabled()) { for(uint32_t i=0;i<count;i++)pPipelines[i]=VK_NULL_HANDLE; MVKTraceVulkanCallEnd(); return VK_ERROR_FEATURE_NOT_PRESENT; }\n\tVkResult rslt = mvkDev->createPipelines<MVKGraphicsPipeline, VkGraphicsPipelineCreateInfo>')
device=GPU/'MVKDevice.mm'
edit(device,'#include "MVKDevice.h"','#include "MVKDevice.h"\n#include "MVKR2.h"')
edit(device,'_liveResources.enabled = needsLiveTrackingForCopy || needsLiveTrackingForEncode;','_liveResources.enabled = needsLiveTrackingForCopy || needsLiveTrackingForEncode || mvkR2Enabled();')
print('Pinned MoltenVK hooks applied; no installed files touched.')
