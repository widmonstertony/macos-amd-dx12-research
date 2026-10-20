#!/usr/bin/env python3
"""Patch only the copied, isolated MoltenVK source tree."""
import pathlib,re,shutil
ROOT=pathlib.Path(__file__).resolve().parent
V=ROOT/'vendor/MoltenVK-db66022459ffb663aa2b50f6b018bc2e124f5edf';GPU=V/'MoltenVK/MoltenVK/GPUObjects'
def edit(path,old,new):
    s=path.read_text()
    if new in s:return
    if s.count(old)!=1:raise RuntimeError(str(path)+' unexpected source: '+str(s.count(old)))
    path.write_text(s.replace(old,new))
for name in ['MVKR2.h','MVKR2.mm','R2Native.h','R2Native.cpp']:shutil.copy2(ROOT/'src'/name,GPU/name)
h=GPU/'MVKPipeline.h'
s=h.read_text();s=s.replace('#include "MVKR2.h"\n','');s=s.replace('#include "MVKShaderModule.h"','#include "MVKShaderModule.h"\n#include "MVKR2.h"');h.write_text(s)
edit(h,'class MVKGraphicsPipeline : public MVKPipeline {\n\npublic:', 'class MVKGraphicsPipeline : public MVKPipeline {\n\npublic:\n    MVKR2State _r2Stages[kMVKShaderStageCount];\n    std::vector<MVKShaderModule*> _r2Modules;')
p=GPU/'MVKPipeline.mm'
edit(p,'\tMVKMTLFunction func = pShaderModule->getMTLFunction(&shaderConfig,','''    MVKShaderStage r2Stage=kMVKShaderStageCount;
    if(mvkR2Enabled()) {
        if(shaderConfig.options.entryPointStage==spv::ExecutionModelVertex)r2Stage=kMVKShaderStageVertex;
        else if(shaderConfig.options.entryPointStage==spv::ExecutionModelFragment)r2Stage=kMVKShaderStageFragment;
        else {setConfigurationResult(VK_ERROR_FEATURE_NOT_PRESENT);return MVKMTLFunctionNull;}
        auto& state=_r2Stages[r2Stage];std::vector<uint32_t> guarded;
        uint32_t hidden=getImplicitBufferIndex(r2Stage,8);
        if(hidden>=getMetalFeatures().maxPerStageBufferCount || _layout->getResourceCounts().stages[r2Stage].bufferIndex>=hidden || !mvkR2Compile(pShaderModule,_layout,guarded,state)) {
            setConfigurationResult(reportError(VK_ERROR_FEATURE_NOT_PRESENT,"Native R2 graphics lowering refused input or binding collision"));return MVKMTLFunctionNull;
        }
        state.metalIndex=hidden;
        VkShaderModuleCreateInfo info={VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};info.codeSize=guarded.size()*4;info.pCode=guarded.data();
        pShaderModule=new MVKShaderModule(_device,&info);_r2Modules.push_back(pShaderModule);
        if(state.slots){
            mvk::MSLResourceBinding rb;rb.resourceBinding.stage=shaderConfig.options.entryPointStage;
            rb.resourceBinding.desc_set=31;rb.resourceBinding.binding=0;rb.resourceBinding.count=1;
            rb.resourceBinding.basetype=SPIRV_CROSS_NAMESPACE::SPIRType::Void;rb.resourceBinding.msl_buffer=hidden;
            shaderConfig.resourceBindings.push_back(rb);shaderConfig.discreteDescriptorSets.push_back(31);
        }
    }
    MVKMTLFunction func = pShaderModule->getMTLFunction(&shaderConfig,''')
edit(p,'\t\t\t\t\t\t\t\t\t\t\t\t\t    pStageFB);\n\tif ( !func.getMTLFunction() ) {','''                                                    pStageFB);
    if(r2Stage!=kMVKShaderStageCount){
        auto& bindings=shaderConfig.resourceBindings;
        bindings.erase(std::remove_if(bindings.begin(),bindings.end(),[](const auto& b){return b.resourceBinding.desc_set==31;}),bindings.end());
        auto& discrete=shaderConfig.discreteDescriptorSets;
        discrete.erase(std::remove(discrete.begin(),discrete.end(),31),discrete.end());
    }
\tif ( !func.getMTLFunction() ) {''')
edit(p,'MVKGraphicsPipeline::~MVKGraphicsPipeline() {','MVKGraphicsPipeline::~MVKGraphicsPipeline() {\n    for(auto* module:_r2Modules)delete module;')
edit(p,'    if (mvkR2Enabled()) {\n        std::vector<uint32_t> guarded;','    if (mvkR2Enabled()) {\n        if(_layout->getResourceCounts().stages[kMVKShaderStageCompute].bufferIndex>=26){setConfigurationResult(VK_ERROR_FEATURE_NOT_PRESENT);return MVKMTLFunctionNull;}\n        std::vector<uint32_t> guarded;')
state=V/'MoltenVK/MoltenVK/Commands/MVKCommandEncoderState.mm'
needle='\tbindVulkanGraphicsToMetalGraphics(encoder, mvkEncoder, vk, vkShared, *this, pipeline, kMVKShaderStageFragment, MVKMetalGraphicsStage::Fragment);'
edit(state,needle,needle+'\n    mvkR2BindRender(encoder,mvkEncoder,vk._descriptorSets,pipeline->_r2Stages[kMVKShaderStageVertex],false);\n    mvkR2BindRender(encoder,mvkEncoder,vk._descriptorSets,pipeline->_r2Stages[kMVKShaderStageFragment],true);')
vk=V/'MoltenVK/MoltenVK/Vulkan/vulkan.mm'
old='    if (mvkR2Enabled()) { for(uint32_t i=0;i<count;i++)pPipelines[i]=VK_NULL_HANDLE; MVKTraceVulkanCallEnd(); return VK_ERROR_FEATURE_NOT_PRESENT; }'
new='''    if(mvkR2Enabled())for(uint32_t i=0;i<count;i++)for(uint32_t s=0;s<pCreateInfos[i].stageCount;s++){
        auto stage=pCreateInfos[i].pStages[s].stage;
        if(stage!=VK_SHADER_STAGE_VERTEX_BIT && stage!=VK_SHADER_STAGE_FRAGMENT_BIT){for(uint32_t n=0;n<count;n++)pPipelines[n]=VK_NULL_HANDLE;MVKTraceVulkanCallEnd();return VK_ERROR_FEATURE_NOT_PRESENT;}
    }'''
edit(vk,old,new)
cm=V/'MoltenVK/CMakeLists.txt';s=cm.read_text();s=re.sub(r'\n# Isolated research compiler paths\..*', '',s,flags=re.S)
if 'libSPIRV-Tools-shared.dylib' not in s:s+='\ntarget_include_directories(MoltenVK PRIVATE /usr/local/include)\ntarget_link_libraries(MoltenVK PRIVATE /usr/local/lib/libSPIRV-Tools-shared.dylib)\n'
cm.write_text(s)
print('Native compiler and vertex/fragment hooks applied to isolated source only.')
