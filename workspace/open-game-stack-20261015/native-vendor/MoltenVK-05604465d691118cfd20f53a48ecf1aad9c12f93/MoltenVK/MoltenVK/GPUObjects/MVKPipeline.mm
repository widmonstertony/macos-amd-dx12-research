/*
 * MVKPipeline.mm
 *
 * Copyright (c) 2015-2025 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKPipeline.h"
#include "MVKCommandBuffer.h"
#include "MVKInlineObjectConstructor.h"
#include "MVKImage.h"
#include "MVKFoundation.h"
#include "MVKOSExtensions.h"
#include "MVKStrings.h"
#include "MTLRenderPipelineDescriptor+MoltenVK.h"
#include "mvk_datatypes.hpp"
#include <sys/stat.h>
#include <unistd.h>
#include <sstream>

#ifndef MVK_USE_CEREAL
#define MVK_USE_CEREAL (1)
#endif

#if MVK_USE_CEREAL
#include <cereal/archives/binary.hpp>
#include <cereal/types/map.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#endif

using namespace std;
using namespace mvk;
using namespace SPIRV_CROSS_NAMESPACE;
#include "MVKRuntimeTrace.h"
#include "MVKQueueDependencyTrace.h"
#include "MVKMeshReplay.h"
#include "MVKPipelineLinkGate.h"
#include "MVKMeshLinkDifferential.h"
#include "MVKComputeArchive.h"
#include "MVKRenderArchive.h"


#pragma mark - MVKPipelineLayout

bool MVKPipelineLayout::stageUsesPushConstants(MVKShaderStage stage) const {
	return mvkIsAnyFlagEnabled(_pushConstantStages, mvkVkShaderStageFlagBitsFromMVKShaderStage(stage));
}

/** Gets the layout for use with the Metal binding API (rather than argument buffers). */
static MVKDescriptorGPULayout getBindingLayout(const MVKDescriptorBinding& binding) {
	bool hasSampler = (binding.perDescriptorResourceCount.sampler > 0) | binding.hasImmutableSamplers();
	bool hasTexture = binding.perDescriptorResourceCount.texture > 0;
	bool hasBuffer = binding.perDescriptorResourceCount.buffer > 0;
	if (hasSampler) {
		return hasTexture ? MVKDescriptorGPULayout::TexSampSoA : MVKDescriptorGPULayout::Sampler;
	} else if (hasBuffer) {
		return hasTexture ? MVKDescriptorGPULayout::TexBufSoA  : MVKDescriptorGPULayout::Buffer;
	} else  {
		return hasTexture ? MVKDescriptorGPULayout::Texture    : MVKDescriptorGPULayout::None;
	}
}

static spv::ExecutionModel spvExecModelForStage(MVKShaderStage stage) {
	switch (stage) {
		case kMVKShaderStageVertex:   return spv::ExecutionModelVertex;
		case kMVKShaderStageTessCtl:  return spv::ExecutionModelTessellationControl;
		case kMVKShaderStageTessEval: return spv::ExecutionModelTessellationEvaluation;
		case kMVKShaderStageGeometry: return spv::ExecutionModelGeometry;
		case kMVKShaderStageFragment: return spv::ExecutionModelFragment;
		case kMVKShaderStageCompute:  return spv::ExecutionModelGLCompute;
		case kMVKShaderStageCount:
			break;
	}
	assert(!"Invalid stage");
	return spv::ExecutionModelMax;
}

static mvk::MSLResourceBinding makeResourceBinding(const MVKShaderStageResourceBinding& binding,
                                                   MVKShaderStage stage,
                                                   uint32_t descriptorSetIndex,
                                                   uint32_t bindingIndex,
                                                   uint32_t count,
                                                   SPIRV_CROSS_NAMESPACE::SPIRType::BaseType type,
                                                   MVKSampler* immutableSampler)
{
	mvk::MSLResourceBinding rb;
	auto& rbb = rb.resourceBinding;
	rbb.stage = spvExecModelForStage(stage);
	rbb.basetype = type;
	rbb.desc_set = descriptorSetIndex;
	rbb.binding = bindingIndex;
	rbb.count = count;
	rbb.msl_buffer = binding.bufferIndex;
	rbb.msl_texture = binding.textureIndex;
	rbb.msl_sampler = binding.samplerIndex;
	if (immutableSampler) { immutableSampler->getConstexprSampler(rb); }
	return rb;
}

static mvk::DescriptorBinding makeDescriptorBinding(MVKShaderStage stage, uint32_t descriptorSetIndex, uint32_t bindingIndex, uint32_t dynamicOffsetIndex) {
	mvk::DescriptorBinding db;
	db.stage = spvExecModelForStage(stage);
	db.descriptorSet = descriptorSetIndex;
	db.binding = bindingIndex;
	db.index = dynamicOffsetIndex;
	return db;
}

static void addResourceBindingToShaderConfig(SPIRVToMSLConversionConfiguration& shaderConfig,
                                             const MVKShaderStageResourceBinding& binding,
                                             MVKShaderStage stage,
                                             uint32_t descriptorSetIndex,
                                             uint32_t bindingIndex,
                                             uint32_t count,
                                             MVKDescriptorGPULayout layout,
                                             MVKSampler* immutableSampler = nullptr,
                                             bool runtimeArray = false)
{
	using SPIRV_CROSS_NAMESPACE::SPIRType;
	if (count == 0) { return; }
	// Count 0 makes SPIRV-Cross declare a runtime-sized array (one element, indexed past its end).
	if (runtimeArray) { count = 0; }

	switch (layout) {
		case MVKDescriptorGPULayout::Texture:
			shaderConfig.resourceBindings.push_back(makeResourceBinding(binding, stage, descriptorSetIndex, bindingIndex, count, SPIRType::Image, immutableSampler));
			break;
		case MVKDescriptorGPULayout::Sampler:
			shaderConfig.resourceBindings.push_back(makeResourceBinding(binding, stage, descriptorSetIndex, bindingIndex, count, SPIRType::Sampler, immutableSampler));
			break;
		case MVKDescriptorGPULayout::Buffer:
		case MVKDescriptorGPULayout::BufferAuxSize:
			shaderConfig.resourceBindings.push_back(makeResourceBinding(binding, stage, descriptorSetIndex, bindingIndex, count, SPIRType::Void, immutableSampler));
			break;
		case MVKDescriptorGPULayout::OutlinedData:
			shaderConfig.resourceBindings.push_back(makeResourceBinding(binding, stage, descriptorSetIndex, bindingIndex, 1, SPIRType::Void, immutableSampler));
			break;
		case MVKDescriptorGPULayout::TexBufSoA:
			shaderConfig.resourceBindings.push_back(makeResourceBinding(binding, stage, descriptorSetIndex, bindingIndex, count, SPIRType::Image, immutableSampler));
			shaderConfig.resourceBindings.push_back(makeResourceBinding(binding, stage, descriptorSetIndex, bindingIndex, count, SPIRType::Void,  immutableSampler));
			break;
		case MVKDescriptorGPULayout::TexSampSoA:
		case MVKDescriptorGPULayout::Tex2SampSoA:
		case MVKDescriptorGPULayout::Tex3SampSoA:
			shaderConfig.resourceBindings.push_back(makeResourceBinding(binding, stage, descriptorSetIndex, bindingIndex, count, SPIRType::SampledImage, immutableSampler));
			break;

		case MVKDescriptorGPULayout::None:
			return;

		case MVKDescriptorGPULayout::InlineData:
			assert(!"SPIRV-Cross doesn't currently support inline data");
			return;
	}
}

void MVKPipelineLayout::populateShaderConversionConfig(SPIRVToMSLConversionConfiguration& shaderConfig) const {
	shaderConfig.resourceBindings.clear();
	shaderConfig.discreteDescriptorSets.clear();
	shaderConfig.dynamicBufferDescriptors.clear();

	// Add any resource bindings used by push-constants.
	for (uint32_t i = 0; i < kMVKShaderStageCount; i++) {
		auto stage = static_cast<MVKShaderStage>(i);
		if (stageUsesPushConstants(stage)) {
			MVKShaderStageResourceBinding binding = {};
			binding.bufferIndex = getPushConstantResourceIndex(stage);
			addResourceBindingToShaderConfig(shaderConfig, binding, stage, kPushConstDescSet, kPushConstBinding, 1, MVKDescriptorGPULayout::Buffer);
		}
	}

	for (uint32_t dslIdx = 0; dslIdx < _descriptorSetLayouts.size(); dslIdx++) {
		MVKDescriptorSetLayout* layout = _descriptorSetLayouts[dslIdx];
		MVKShaderResourceBinding binding = _resourceIndexOffsets[dslIdx];
		uint32_t argBufResIdx = 0;
		bool argbuf = layout->argBufMode() != MVKArgumentBufferMode::Off;
		if (argbuf) {
			if (layout->needsSizeBuf()) {
				argBufResIdx++;
				for (uint32_t i = 0; i < kMVKShaderStageCount; i++) {
					auto stage = static_cast<MVKShaderStage>(i);
					addResourceBindingToShaderConfig(shaderConfig, {}, stage, dslIdx, kBufferSizeBufferBinding, 1, MVKDescriptorGPULayout::Buffer);
				}
			}
		}
		for (const MVKDescriptorBinding& desc : layout->bindings()) {
			MVKShaderStageResourceBinding resCount = desc.totalResourceCount();
			for (uint32_t i = 0; i < kMVKShaderStageCount; i++) {
				auto stage = static_cast<MVKShaderStage>(i);
				bool used = mvkIsAnyFlagEnabled(desc.stageFlags, mvkVkShaderStageFlagBitsFromMVKShaderStage(stage));
				if (argbuf) {
					binding.stages[stage].textureIndex = argBufResIdx;
					binding.stages[stage].bufferIndex = argBufResIdx + resCount.textureIndex;
					binding.stages[stage].samplerIndex = argBufResIdx + resCount.textureIndex;
				} else if (!used) {
					continue;
				}

				MVKSampler*const* immSamp = layout->getImmutableSampler(desc);
				MVKDescriptorGPULayout gpuLayout = argbuf ? desc.gpuLayout : getBindingLayout(desc);
				// Metal 3 argument buffers: a variable-count binding (vkd3d-proton's descriptor heaps, up to 1000000
				// descriptors) is a runtime array in the shader. Declared with its full count, Metal builds a table
				// of every element for each program (32 MB per 1000000-descriptor array and program). The binding is
				// the set's last, its descriptors are one element each (8 bytes), so the layout is the same.
				bool runtimeArray = layout->argBufMode() == MVKArgumentBufferMode::Metal3 && desc.isVariable() &&
				                    (gpuLayout == MVKDescriptorGPULayout::Texture || gpuLayout == MVKDescriptorGPULayout::Sampler ||
				                     gpuLayout == MVKDescriptorGPULayout::Buffer || gpuLayout == MVKDescriptorGPULayout::BufferAuxSize);
				addResourceBindingToShaderConfig(shaderConfig, binding.stages[stage], stage, dslIdx, desc.binding, desc.descriptorCount,
				                                 gpuLayout, immSamp ? *immSamp : nullptr, runtimeArray);
				if (desc.perDescriptorResourceCount.dynamicOffset != 0 && used) {
					shaderConfig.dynamicBufferDescriptors.push_back(makeDescriptorBinding(stage, dslIdx, desc.binding, binding.stages[stage].dynamicOffsetBufferIndex));
				}
				if (argbuf) {
					if (used && desc.perDescriptorResourceCount.dynamicOffset)
						binding.stages[stage].dynamicOffsetBufferIndex += desc.descriptorCount;
				} else {
					binding.stages[stage] += resCount;
				}
			}
			argBufResIdx += resCount.textureIndex + resCount.bufferIndex + resCount.samplerIndex;
		}
		if (isUsingMetalArgumentBuffers() && !argbuf) {
			shaderConfig.discreteDescriptorSets.push_back(dslIdx);
		}
	}
}

static bool hasDynamicBuffer(VkDescriptorType type) {
	switch (type) {
		case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC:
		case VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC:
			return true;
		default:
			return false;
	}
}

static bool hasBuffer(MVKDescriptorGPULayout layout) {
	switch (layout) {
		case MVKDescriptorGPULayout::Buffer:
		case MVKDescriptorGPULayout::BufferAuxSize:
		case MVKDescriptorGPULayout::TexBufSoA:
			return true;
		default:
			return false;
	}
}

static bool isWriteable(VkDescriptorType type) {
	switch (type) {
		case VK_DESCRIPTOR_TYPE_STORAGE_IMAGE:
		case VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER:
		case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER:
		case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC:
			return true;
		default:
			return false;
	}
}

bool MVKPipelineLayout::boundsCheckBindOp(uint32_t bind, uint32_t count, uint32_t limit, const char *type) {
	if (bind + count > limit) {
		char desc[32];
		if (count > 1)
			snprintf(desc, sizeof(desc), "%d-%d", bind, bind + count - 1);
		else
			snprintf(desc, sizeof(desc), "%d", bind);
		MVKLogError("Pipeline wants to bind %s %s which goes above the limit %d, skipping...", type, desc, limit);
		return false;
	}
	return true;
}

void MVKPipelineLayout::populateBindOperations(MVKPipelineBindScript& script, const SPIRVToMSLConversionConfiguration& shaderConfig, spv::ExecutionModel execModel) {
	assert(script.ops.empty());

	for (const auto& mslBinding : shaderConfig.resourceBindings) {
		if (mslBinding.resourceBinding.stage != execModel || !mslBinding.outIsUsedByShader) { continue; }
		uint32_t set = mslBinding.resourceBinding.desc_set;
		uint32_t binding = mslBinding.resourceBinding.binding;
		if (set >= _descriptorSetLayouts.size()) { assert(set == kPushConstDescSet); continue; }
		// Aux buffers are always allocated out of the same buffer as the descriptor set itself, so they'll already be resident
		if (binding == kBufferSizeBufferBinding) { continue; }
		MVKDescriptorSetLayout* layout = _descriptorSetLayouts[set];
		uint32_t descIdx = layout->getBindingIndex(binding);
		if (descIdx >= layout->bindings().size()) { assert(!"Binding missing from layout"); continue; }
		const MVKDescriptorBinding& desc = layout->bindings()[descIdx];
		auto counts = desc.perDescriptorResourceCount;
		uint32_t nonTexOffset = counts.texture * sizeof(id);
		if (!desc.descriptorCount) { continue; }
		bool partiallyBound = mvkIsAnyFlagEnabled(desc.flags, MVK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT) || getMVKConfig().liveCheckAllResources;

		if (layout->argBufMode() == MVKArgumentBufferMode::Off) {
			if (desc.cpuLayout == MVKDescriptorCPULayout::InlineData) {
				if (boundsCheckBindOp(mslBinding.resourceBinding.msl_buffer, 1, kMVKMaxBufferCount, "buffer"))
					script.ops.push_back({ MVKDescriptorBindOperationCode::BindBytes, set, mslBinding.resourceBinding.msl_buffer, descIdx });
			} else {
				MVKDescriptorBindOperationCode bindTex  = partiallyBound ? MVKDescriptorBindOperationCode::BindTextureWithLiveCheck : MVKDescriptorBindOperationCode::BindTexture;
				MVKDescriptorBindOperationCode bindBuf  = partiallyBound ? MVKDescriptorBindOperationCode::BindBufferWithLiveCheck  : MVKDescriptorBindOperationCode::BindBuffer ;
				MVKDescriptorBindOperationCode bindSamp = partiallyBound ? MVKDescriptorBindOperationCode::BindSamplerWithLiveCheck : MVKDescriptorBindOperationCode::BindSampler;
				MVKDescriptorBindOperationCode bindBufDyn = partiallyBound ? MVKDescriptorBindOperationCode::BindBufferDynamicWithLiveCheck : MVKDescriptorBindOperationCode::BindBufferDynamic;
				uint32_t nbind = desc.descriptorCount;
				for (uint32_t i = 0; i < counts.texture; i++) {
					uint32_t base = mslBinding.resourceBinding.msl_texture + i * nbind;
					if (boundsCheckBindOp(base, nbind, kMVKMaxTextureCount, "texture"))
						script.ops.push_back({ bindTex, set, base, descIdx, sizeof(id) * i });
				}

				if (hasDynamicBuffer(desc.descriptorType)) {
					uint32_t dynOffset = 0;
					auto it = std::find_if(shaderConfig.dynamicBufferDescriptors.begin(), shaderConfig.dynamicBufferDescriptors.end(), [&](auto& dynBuf){
						return dynBuf.stage == execModel && dynBuf.descriptorSet == set && dynBuf.binding == binding;
					});
					if (it == shaderConfig.dynamicBufferDescriptors.end()) {
						assert(0);
					} else {
						dynOffset = it->index;
					}
					if (boundsCheckBindOp(mslBinding.resourceBinding.msl_buffer, nbind, kMVKMaxBufferCount, "buffer"))
						script.ops.push_back({ bindBufDyn, set, mslBinding.resourceBinding.msl_buffer, descIdx, nonTexOffset, dynOffset });
				} else if (counts.buffer > 0) {
					if (boundsCheckBindOp(mslBinding.resourceBinding.msl_buffer, nbind, kMVKMaxBufferCount, "buffer"))
						script.ops.push_back({ bindBuf, set, mslBinding.resourceBinding.msl_buffer, descIdx, nonTexOffset });
				}
				if (counts.sampler > 0) {
					if (desc.hasImmutableSamplers())
						bindSamp = MVKDescriptorBindOperationCode::BindImmutableSampler;
					if (boundsCheckBindOp(mslBinding.resourceBinding.msl_sampler, nbind, kMVKMaxSamplerCount, "sampler"))
						script.ops.push_back({ bindSamp, set, mslBinding.resourceBinding.msl_sampler, descIdx, nonTexOffset });
				}
			}
		} else if (!_device->hasResidencySet()) {
			MVKDescriptorBindOperationCode useTex = partiallyBound ? MVKDescriptorBindOperationCode::UseTextureWithLiveCheck : MVKDescriptorBindOperationCode::UseResource;
			MVKDescriptorBindOperationCode useBuf = partiallyBound ? MVKDescriptorBindOperationCode::UseBufferWithLiveCheck  : MVKDescriptorBindOperationCode::UseResource;
			MVKDescriptorGPULayout gpuLayout = desc.gpuLayout;
			uint32_t target = isWriteable(desc.descriptorType);
			for (uint32_t i = 0, n = descriptorTextureCount(gpuLayout); i < n; i++) {
				script.ops.push_back({ useTex, set, target, descIdx, sizeof(id) * i });
			}
			if (hasBuffer(gpuLayout)) {
				script.ops.push_back({ useBuf, set, target, descIdx, nonTexOffset });
			}
		}
	}
}

MVKPipelineLayout::MVKPipelineLayout(MVKDevice* device): MVKVulkanAPIDeviceObject(device) {}

MVKPipelineLayout* MVKPipelineLayout::Create(MVKDevice* device, const VkPipelineLayoutCreateInfo* pCreateInfo) {
	using Constructor = MVKInlineObjectConstructor<MVKPipelineLayout>;
	MVKArrayRef layouts(reinterpret_cast<MVKDescriptorSetLayout*const*>(pCreateInfo->pSetLayouts), pCreateInfo->setLayoutCount);

	MVKPipelineLayout* ret = Constructor::Create(
		std::tuple {
			Constructor::Copy(&MVKPipelineLayout::_descriptorSetLayouts, layouts),
			Constructor::Uninit(&MVKPipelineLayout::_resourceIndexOffsets, layouts.size()),
		},
		device
	);

	// VK_NULL_HANDLE set layouts are legal with VK_PIPELINE_LAYOUT_CREATE_INDEPENDENT_SETS_BIT_EXT (graphics
	// pipeline libraries), and guest drivers send them through Venus even though MoltenVK does not advertise
	// that extension. Such a set is empty: use one empty set layout for all of them.
	MVKDescriptorSetLayout* emptyLayout = nullptr;
	for (auto& dsl : ret->_descriptorSetLayouts) {
		if (dsl) { continue; }
		if ( !emptyLayout ) {
			VkDescriptorSetLayoutCreateInfo emptyInfo = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
			emptyLayout = MVKDescriptorSetLayout::Create(device, &emptyInfo);
		}
		dsl = emptyLayout;
	}
	auto setLayouts = ret->getDescriptorSetLayouts();

	for (const VkPushConstantRange& range : MVKArrayRef(pCreateInfo->pPushConstantRanges, pCreateInfo->pushConstantRangeCount)) {
		ret->_pushConstantStages |= range.stageFlags;
		ret->_pushConstantsLength = std::max(ret->_pushConstantsLength, range.offset + range.size);
	}

	// MSL structs can have a larger size than the equivalent C struct due to MSL alignment needs.
	// Typically any MSL struct that contains a float4 will also have a size that is rounded up to a multiple of a float4 size.
	// Ensure that we pass along enough content to cover this extra space even if it is never actually accessed by the shader.
	ret->_pushConstantsLength = static_cast<uint32_t>(mvkAlignByteCount(ret->_pushConstantsLength, 16));

	// We do not need to do anything special for pipeline layout compatibility, as the state tracker handles rebinding as necessary.
	// However, if we try to bind things in a way that would support direct layout compatibility, the state tracker will need to do less rebinding of buffers.
	// So consume the Metal resource indexes in this order:
	//   - Fixed count of argument buffers for descriptor sets (if using Metal argument buffers).
	//   - Push constants
	//   - Descriptor set content

	// If we are using Metal argument buffers, consume a fixed number of buffer indices for the Metal argument buffers themselves.
	for (const MVKDescriptorSetLayout* layout : setLayouts) {
		if (layout->argBufMode() != MVKArgumentBufferMode::Off) {
			ret->_mtlResourceCounts.addArgumentBuffers(kMVKMaxDescriptorSetCount);
			break;
		}
	}

	for (uint32_t stage = 0; stage < kMVKShaderStageCount; stage++) {
		ret->_pushConstantResourceIndices[stage] = static_cast<uint8_t>(ret->_mtlResourceCounts.stages[stage].bufferIndex);
		if (ret->stageUsesPushConstants(static_cast<MVKShaderStage>(stage)))
			++ret->_mtlResourceCounts.stages[stage].bufferIndex;
	}

	for (size_t i = 0; i < setLayouts.size(); i++) {
		setLayouts[i]->retain();
		ret->_resourceIndexOffsets[i] = ret->_mtlResourceCounts;
		MVKShaderResourceBinding count = setLayouts[i]->totalResourceCount();
		if (setLayouts[i]->argBufMode() != MVKArgumentBufferMode::Off)
			count.clearArgumentBufferResources();
		ret->_mtlResourceCounts += count;
		if (setLayouts[i]->isPushDescriptorSetLayout())
			ret->_pushDescriptor = i;
	}
	if (emptyLayout) { emptyLayout->release(); }	// Each null set retained it above.

	return ret;
}

MVKPipelineLayout::~MVKPipelineLayout() {
	for (auto dsl : _descriptorSetLayouts) { dsl->release(); }
}

#pragma mark -
#pragma mark MVKPipeline

MVKPipeline::MVKPipeline(MVKDevice* device, MVKPipelineCache* pipelineCache, MVKPipelineLayout* layout,
						 VkPipelineCreateFlags2 flags, MVKPipeline* parent) :
	MVKVulkanAPIDeviceObject(device),
	_layout(layout),
	_pipelineCache(pipelineCache),
	_flags(flags),
	_descriptorSetCount(static_cast<uint32_t>(layout->getDescriptorSetCount())) {

		layout->retain();

		// Establish descriptor counts and push constants use.
		for (uint32_t stage = kMVKShaderStageVertex; stage < kMVKShaderStageCount; stage++) {
			_descriptorBufferCounts.stages[stage] = layout->getResourceCounts().stages[stage].bufferIndex;
			_stageUsesPushConstants[stage] = layout->stageUsesPushConstants((MVKShaderStage)stage);
		}
	}


MVKPipeline::~MVKPipeline() {
	_layout->release();
}

#pragma mark -
#pragma mark MVKGraphicsPipeline

/** Populate a MVKStageResourceBits based on the resources used by the given shader info. */
static void populateResourceUsage(MVKPipelineStageResourceInfo& dst, SPIRVToMSLConversionConfiguration& src, SPIRVToMSLConversionResultInfo& results, spv::ExecutionModel stage) {
	dst.usesPhysicalStorageBufferAddresses = results.usesPhysicalStorageBufferAddressesCapability;
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::Output,        results.needsOutputBuffer);
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::PatchOutput,   results.needsPatchOutputBuffer);
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::BufferSize,    results.needsBufferSizeBuffer);
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::DynamicOffset, results.needsDynamicOffsetBuffer);
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::TextureOffset, results.needsTextureOffsetBuffer);
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::DispatchBase,  results.needsDispatchBaseBuffer);
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::ViewRange,     results.needsViewRangeBuffer);
	dst.implicitBuffers.needed |= MVKImplicitBufferList(MVKImplicitBuffer::DepthClip,     results.needsDepthClipStateBuffer);

	typedef SPIRV_CROSS_NAMESPACE::SPIRType SPIRType;
	bool isArgBuf[kMVKMaxDescriptorSetCount] = {};
	bool isUsed[kMVKMaxDescriptorSetCount] = {};
	if (src.options.mslOptions.argument_buffers) {
		std::fill(std::begin(isArgBuf), std::end(isArgBuf), true);
		for (uint32_t set : src.discreteDescriptorSets)
			isArgBuf[set] = false;
	}
	for (const auto& binding : src.resourceBindings) {
		if (!binding.outIsUsedByShader)
			continue;
		if (binding.resourceBinding.stage != stage)
			continue;
		if (binding.resourceBinding.desc_set == kPushConstDescSet) {
			dst.implicitBuffers.needed.add(MVKImplicitBuffer::PushConstant);
			continue;
		}
		assert(binding.resourceBinding.desc_set < kMVKMaxDescriptorSetCount);
		isUsed[binding.resourceBinding.desc_set] = true;
		if (isArgBuf[binding.resourceBinding.desc_set])
			continue;
		uint32_t count = binding.resourceBinding.count;
		switch (binding.resourceBinding.basetype) {
			case SPIRType::Image:
			case SPIRType::SampledImage:
			case SPIRType::Sampler:
				if (binding.requiresConstExprSampler) {
					assert(binding.resourceBinding.basetype != SPIRType::Image);
					count *= std::max(binding.constExprSampler.planes, 1u);
					dst.resources.textures.setRange(binding.resourceBinding.msl_texture, binding.resourceBinding.msl_texture + count);
				} else {
					if (binding.resourceBinding.basetype != SPIRType::Image)
						dst.resources.samplers.setRange(binding.resourceBinding.msl_sampler, binding.resourceBinding.msl_sampler + count);
					if (binding.resourceBinding.basetype != SPIRType::Sampler)
						dst.resources.textures.setRange(binding.resourceBinding.msl_texture, binding.resourceBinding.msl_texture + count);
				}
				break;

			default:
				dst.resources.buffers.setRange(binding.resourceBinding.msl_buffer, binding.resourceBinding.msl_buffer + count);
				break;
		}
	}
	for (uint32_t i = 0; i < kMVKMaxDescriptorSetCount; i++) {
		if (isArgBuf[i] && isUsed[i]) {
			dst.resources.buffers.set(i);
			dst.resources.descriptorSetData.set(i);
		}
	}
}

// Do updates that may require a render pass restart immediately on bind.
void MVKGraphicsPipeline::wasBound(MVKCommandEncoder* cmdEncoder) {
	if (_hasRemappedAttachmentLocations) {
		cmdEncoder->updateColorAttachmentLocations(_colorAttachmentLocations.contents());
	}
}

void MVKGraphicsPipeline::getStages(MVKPiplineStages& stages) {
    if (isTessellationPipeline()) {
        stages.push_back(kMVKGraphicsStageVertex);
        stages.push_back(kMVKGraphicsStageTessControl);
    }
    stages.push_back(kMVKGraphicsStageRasterization);
}

static const char vtxCompilerType[] = "Vertex stage pipeline for tessellation";

bool MVKGraphicsPipeline::compileTessVertexStageState(MTLComputePipelineDescriptor* vtxPLDesc,
													  MVKMTLFunction* pVtxFunctions,
													  VkPipelineCreationFeedback* pVertexFB) {
	uint64_t startTime = 0;
    if (pVertexFB) {
		startTime = mvkGetTimestamp();
	}
	vtxPLDesc.computeFunction = pVtxFunctions[0].getMTLFunction();
    bool res = !!getOrCompilePipeline(vtxPLDesc, _mtlTessVertexStageState, vtxCompilerType);

	vtxPLDesc.computeFunction = pVtxFunctions[1].getMTLFunction();
    vtxPLDesc.stageInputDescriptor.indexType = MTLIndexTypeUInt16;
    for (uint32_t i = 0; i < 31; i++) {
		MTLBufferLayoutDescriptor* blDesc = vtxPLDesc.stageInputDescriptor.layouts[i];
        if (blDesc.stepFunction == MTLStepFunctionThreadPositionInGridX) {
                blDesc.stepFunction = MTLStepFunctionThreadPositionInGridXIndexed;
        }
    }
    res |= !!getOrCompilePipeline(vtxPLDesc, _mtlTessVertexStageIndex16State, vtxCompilerType);

	vtxPLDesc.computeFunction = pVtxFunctions[2].getMTLFunction();
    vtxPLDesc.stageInputDescriptor.indexType = MTLIndexTypeUInt32;
    res |= !!getOrCompilePipeline(vtxPLDesc, _mtlTessVertexStageIndex32State, vtxCompilerType);

	if (pVertexFB) {
		if (!res) {
			// Compilation of the shader will have enabled the flag, so I need to turn it off.
			mvkDisableFlags(pVertexFB->flags, VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT);
		}
		pVertexFB->duration += mvkGetElapsedNanoseconds(startTime);
	}
	return res;
}

bool MVKGraphicsPipeline::compileTessControlStageState(MTLComputePipelineDescriptor* tcPLDesc,
													   VkPipelineCreationFeedback* pTessCtlFB) {
	uint64_t startTime = 0;
    if (pTessCtlFB) {
		startTime = mvkGetTimestamp();
	}
    bool res = !!getOrCompilePipeline(tcPLDesc, _mtlTessControlStageState, "Tessellation control");
	if (pTessCtlFB) {
		if (!res) {
			mvkDisableFlags(pTessCtlFB->flags, VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT);
		}
		pTessCtlFB->duration += mvkGetElapsedNanoseconds(startTime);
	}
	return res;
}


#pragma mark Construction

// Extracts and returns a VkPipelineRenderingCreateInfo from the renderPass or pNext
// chain of pCreateInfo, or returns an empty struct if neither of those are found.
// Although the Vulkan spec is vague and unclear, there are CTS that set both renderPass
// and VkPipelineRenderingCreateInfo to null in VkGraphicsPipelineCreateInfo.
static const VkPipelineRenderingCreateInfo* getRenderingCreateInfo(const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	if (pCreateInfo->renderPass) {
		return ((MVKRenderPass*)pCreateInfo->renderPass)->getSubpass(pCreateInfo->subpass)->getPipelineRenderingCreateInfo();
	}
	for (const auto* next = (VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
			case VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO: return (VkPipelineRenderingCreateInfo*)next;
			default: break;
		}
	}
	static VkPipelineRenderingCreateInfo emptyRendInfo = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO };
	return &emptyRendInfo;
}

template <typename T>
static const VkPipelineRobustnessCreateInfo* getRobustnessCreateInfo(const T* pCreateInfo) {
	const VkPipelineRobustnessCreateInfo* pRobustnessInfo = nullptr;
	for (const auto* next = (VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
			case VK_STRUCTURE_TYPE_PIPELINE_ROBUSTNESS_CREATE_INFO:
				pRobustnessInfo = (VkPipelineRobustnessCreateInfo*)next;
				break;
			default:
				break;
		}
	}
	return pRobustnessInfo;
}

template <typename T>
static void warnIfUnsupportedRobustnessEnabled(MVKPipeline* pipeline, const T* pCreateInfo) {
	if (!pCreateInfo || pipeline->isAppleGPU()) return;

	const VkPipelineRobustnessCreateInfo* pRobustnessInfo = getRobustnessCreateInfo(pCreateInfo);
	if (!pRobustnessInfo) return;

	if (pRobustnessInfo->storageBuffers == VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_ROBUST_BUFFER_ACCESS ||
		pRobustnessInfo->uniformBuffers == VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_ROBUST_BUFFER_ACCESS ||
		pRobustnessInfo->vertexInputs == VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_ROBUST_BUFFER_ACCESS ||
		pRobustnessInfo->images == VK_PIPELINE_ROBUSTNESS_IMAGE_BEHAVIOR_ROBUST_IMAGE_ACCESS) {
		pipeline->reportWarning(VK_ERROR_FEATURE_NOT_PRESENT, "Non-Apple GPUs do not fully support robustness.");
	}
}

// Determines if robust buffer access 2 should be enabled for a pipeline, checking both
// device-wide features and per-pipeline/per-stage robustness settings.
template <typename T>
static bool shouldEnableRobustBufferAccess2(MVKPipeline* pipeline, const T* pCreateInfo,
											const VkPipelineShaderStageCreateInfo* pShaderStage = nullptr) {
    // Private AMD research compiler option. Does not alter advertised/created device features.
    const char* research = getenv("MVK_AMD_REFERENCE_RBA2");
    if (research && research[0] == '1' && research[1] == 0) { return true; }
	if (pipeline->getEnabledRobustness2Features().robustBufferAccess2) { return true; }

	auto isRobust2 = [](const VkPipelineRobustnessCreateInfo* pRob) {
		return pRob && (pRob->storageBuffers == VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_ROBUST_BUFFER_ACCESS_2 ||
						pRob->uniformBuffers == VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_ROBUST_BUFFER_ACCESS_2);
	};

	if (pShaderStage && isRobust2(getRobustnessCreateInfo(pShaderStage))) { return true; }
	return isRobust2(getRobustnessCreateInfo(pCreateInfo));
}

// Determines if robust image access 2 should be enabled for a pipeline.
template <typename T>
static bool shouldEnableRobustImageAccess2(MVKPipeline* pipeline, const T* pCreateInfo,
										   const VkPipelineShaderStageCreateInfo* pShaderStage = nullptr) {
    const char* research = getenv("MVK_AMD_REFERENCE_RIA2");
    if (research && research[0] == '1' && research[1] == 0) { return true; }
	if (pipeline->getEnabledRobustness2Features().robustImageAccess2) { return true; }

	auto isRobust2 = [](const VkPipelineRobustnessCreateInfo* pRob) {
		return pRob && pRob->images == VK_PIPELINE_ROBUSTNESS_IMAGE_BEHAVIOR_ROBUST_IMAGE_ACCESS_2;
	};

	if (pShaderStage && isRobust2(getRobustnessCreateInfo(pShaderStage))) { return true; }
	return isRobust2(getRobustnessCreateInfo(pCreateInfo));
}

// Determines if robust vertex inputs should be enabled for a pipeline.
template <typename T>
static bool shouldEnableRobustVertexInputs(MVKPipeline* pipeline, const T* pCreateInfo) {
	if (pipeline->getEnabledRobustness2Features().robustBufferAccess2) { return true; }

	const VkPipelineRobustnessCreateInfo* pRob = getRobustnessCreateInfo(pCreateInfo);
	return pRob && pRob->vertexInputs == VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_ROBUST_BUFFER_ACCESS_2;
}

static MVKShaderModule* getOrCreateShaderModule(MVKDevice* device, const VkPipelineShaderStageCreateInfo* pCreateInfo,
                                                   bool& ownsShaderModule) {
	if (pCreateInfo && pCreateInfo->module == VK_NULL_HANDLE) {
		for (const auto* next = (VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
			switch (next->sType) {
				case VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO:
					ownsShaderModule = true;
					return new MVKShaderModule(device, (VkShaderModuleCreateInfo*)next);
				default:
					break;
			}
		}
	}
	ownsShaderModule = false;
	return pCreateInfo ? (MVKShaderModule*)pCreateInfo->module : nullptr;
}

// Returns the description of the vertex buffer binding, or null if the binding is not described.
static const VkVertexInputBindingDescription* getVertexBindingDescription(const VkPipelineVertexInputStateCreateInfo* pVI, uint32_t binding) {
	for (uint32_t i = 0; i < pVI->vertexBindingDescriptionCount; i++) {
		if (pVI->pVertexBindingDescriptions[i].binding == binding) { return &pVI->pVertexBindingDescriptions[i]; }
	}
	return nullptr;
}

static MVKRenderStateFlags getRenderStateFlags(VkDynamicState vk) {
	switch (vk) {
		case VK_DYNAMIC_STATE_BLEND_CONSTANTS:             return MVKRenderStateFlag::BlendConstants;
		case VK_DYNAMIC_STATE_COLOR_BLEND_EQUATION_EXT:    return MVKRenderStateFlag::ColorBlend;
		case VK_DYNAMIC_STATE_COLOR_BLEND_ENABLE_EXT:      return MVKRenderStateFlag::ColorBlendEnable;
		case VK_DYNAMIC_STATE_CULL_MODE:                   return MVKRenderStateFlag::CullMode;
		case VK_DYNAMIC_STATE_DEPTH_BIAS:                  return MVKRenderStateFlag::DepthBias;
		case VK_DYNAMIC_STATE_DEPTH_BIAS_ENABLE:           return MVKRenderStateFlag::DepthBiasEnable;
		case VK_DYNAMIC_STATE_DEPTH_BOUNDS:                return MVKRenderStateFlag::DepthBounds;
		case VK_DYNAMIC_STATE_DEPTH_BOUNDS_TEST_ENABLE:    return MVKRenderStateFlag::DepthBoundsTestEnable;
		case VK_DYNAMIC_STATE_DEPTH_CLAMP_ENABLE_EXT:      return MVKRenderStateFlag::DepthClampEnable;
		case VK_DYNAMIC_STATE_DEPTH_CLIP_ENABLE_EXT:       return MVKRenderStateFlag::DepthClipEnable;
		case VK_DYNAMIC_STATE_DEPTH_COMPARE_OP:            return MVKRenderStateFlag::DepthCompareOp;
		case VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE:           return MVKRenderStateFlag::DepthTestEnable;
		case VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE:          return MVKRenderStateFlag::DepthWriteEnable;
		case VK_DYNAMIC_STATE_FRONT_FACE:                  return MVKRenderStateFlag::FrontFace;
		case VK_DYNAMIC_STATE_LINE_RASTERIZATION_MODE_EXT: return MVKRenderStateFlag::LineRasterizationMode;
		case VK_DYNAMIC_STATE_LINE_WIDTH:                  return MVKRenderStateFlag::LineWidth;
		case VK_DYNAMIC_STATE_LOGIC_OP_EXT:                return MVKRenderStateFlag::LogicOp;
		case VK_DYNAMIC_STATE_LOGIC_OP_ENABLE_EXT:         return MVKRenderStateFlag::LogicOpEnable;
		case VK_DYNAMIC_STATE_PATCH_CONTROL_POINTS_EXT:    return MVKRenderStateFlag::PatchControlPoints;
		case VK_DYNAMIC_STATE_POLYGON_MODE_EXT:            return MVKRenderStateFlag::PolygonMode;
		case VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE:    return MVKRenderStateFlag::PrimitiveRestartEnable;
		case VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY:          return MVKRenderStateFlag::PrimitiveTopology;
		case VK_DYNAMIC_STATE_PROVOKING_VERTEX_MODE_EXT:   return MVKRenderStateFlag::ProvokingVertexMode;
		case VK_DYNAMIC_STATE_RASTERIZER_DISCARD_ENABLE:   return MVKRenderStateFlag::RasterizerDiscardEnable;
		case VK_DYNAMIC_STATE_SAMPLE_LOCATIONS_EXT:        return MVKRenderStateFlag::SampleLocations;
		case VK_DYNAMIC_STATE_SAMPLE_LOCATIONS_ENABLE_EXT: return MVKRenderStateFlag::SampleLocationsEnable;
		case VK_DYNAMIC_STATE_SCISSOR:                     return MVKRenderStateFlag::Scissors;
		case VK_DYNAMIC_STATE_SCISSOR_WITH_COUNT:          return MVKRenderStateFlag::Scissors;
		case VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK:        return MVKRenderStateFlag::StencilCompareMask;
		case VK_DYNAMIC_STATE_STENCIL_OP:                  return MVKRenderStateFlag::StencilOp;
		case VK_DYNAMIC_STATE_STENCIL_REFERENCE:           return MVKRenderStateFlag::StencilReference;
		case VK_DYNAMIC_STATE_STENCIL_TEST_ENABLE:         return MVKRenderStateFlag::StencilTestEnable;
		case VK_DYNAMIC_STATE_STENCIL_WRITE_MASK:          return MVKRenderStateFlag::StencilWriteMask;
		case VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE: return MVKRenderStateFlag::VertexStride;
		case VK_DYNAMIC_STATE_VIEWPORT:                    return MVKRenderStateFlag::Viewports;
		case VK_DYNAMIC_STATE_VIEWPORT_WITH_COUNT:         return MVKRenderStateFlag::Viewports;
		default:                                           return {};
	}
}

static void loadStencil(MVKMTLStencilDescriptorData& mtl, const VkStencilOpState& vk) {
	mtl.readMask = vk.compareMask;
	mtl.writeMask = vk.writeMask;
	mtl.op.stencilCompareFunction = mvkMTLCompareFunctionFromVkCompareOp(vk.compareOp);
	mtl.op.stencilFailureOperation = mvkMTLStencilOperationFromVkStencilOp(vk.failOp);
	mtl.op.depthFailureOperation = mvkMTLStencilOperationFromVkStencilOp(vk.depthFailOp);
	mtl.op.depthStencilPassOperation = mvkMTLStencilOperationFromVkStencilOp(vk.passOp);
}

static bool usesConstantColor(VkBlendFactor factor) {
	switch (factor) {
		case VK_BLEND_FACTOR_CONSTANT_COLOR:
		case VK_BLEND_FACTOR_CONSTANT_ALPHA:
		case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR:
		case VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA:
			return true;
		default:
			return false;
	}
}

static bool usesConstantColor(MVKRenderStateFlags dynamic, const VkPipelineColorBlendStateCreateInfo* info) {
	if (dynamic.has(MVKRenderStateFlag::ColorBlend))
		return true;
	for (const auto& attachment : MVKArrayRef(info->pAttachments, info->attachmentCount)) {
		if (usesConstantColor(attachment.srcColorBlendFactor)) return true;
		if (usesConstantColor(attachment.dstColorBlendFactor)) return true;
		if (usesConstantColor(attachment.srcAlphaBlendFactor)) return true;
		if (usesConstantColor(attachment.dstAlphaBlendFactor)) return true;
	}
	return false;
}

MVKGraphicsPipeline::MVKGraphicsPipeline(MVKDevice* device,
										 MVKPipelineCache* pipelineCache,
										 MVKPipeline* parent,
										 const VkGraphicsPipelineCreateInfo* pCreateInfo) :
	MVKPipeline(device, pipelineCache, (MVKPipelineLayout*)pCreateInfo->layout, getPipelineCreateFlags(pCreateInfo), parent)
{
	// Extract dynamic state first, as it can affect many configurations.
	initDynamicState(pCreateInfo);

	_primitiveTopologyClass = MTLPrimitiveTopologyClassUnspecified;
	if (pCreateInfo->pInputAssemblyState)
		_primitiveTopologyClass = mvkMTLPrimitiveTopologyClassFromVkPrimitiveTopology(pCreateInfo->pInputAssemblyState->topology);
	if (!_dynamicStateFlags.has(MVKRenderStateFlag::PolygonMode) && pCreateInfo->pRasterizationState->polygonMode == VK_POLYGON_MODE_POINT)
		_primitiveTopologyClass = MTLPrimitiveTopologyClassPoint;

	// Determine rasterization early, as various other structs are validated and interpreted in this context.
	const VkPipelineRenderingCreateInfo* pRendInfo = getRenderingCreateInfo(pCreateInfo);
	_isRasterizing = !isRasterizationDisabled(pCreateInfo);
	_isRasterizingColor = _isRasterizing && mvkHasColorAttachments(pRendInfo);
	populateRenderingAttachmentInfo(pCreateInfo);

	const VkPipelineCreationFeedbackCreateInfo* pFeedbackInfo = nullptr;
	for (const auto* next = (VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
			case VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO:
				pFeedbackInfo = (VkPipelineCreationFeedbackCreateInfo*)next;
				break;
			default:
				break;
		}
	}

	warnIfUnsupportedRobustnessEnabled(this, pCreateInfo);
	_needsRobustVertexInputs = shouldEnableRobustVertexInputs(this, pCreateInfo);

	// Initialize feedback. The VALID bit must be initialized, either set or cleared.
	// We'll set the VALID bits later, after successful compilation.
	VkPipelineCreationFeedback* pPipelineFB = nullptr;
	if (pFeedbackInfo) {
		pPipelineFB = pFeedbackInfo->pPipelineCreationFeedback;
		// n.b. Do *NOT* use mvkClear(). That would also clear the sType and pNext fields.
		pPipelineFB->flags = 0;
		pPipelineFB->duration = 0;
		for (uint32_t i = 0; i < pFeedbackInfo->pipelineStageCreationFeedbackCount; ++i) {
			pFeedbackInfo->pPipelineStageCreationFeedbacks[i].flags = 0;
			pFeedbackInfo->pPipelineStageCreationFeedbacks[i].duration = 0;
		}
	}

	// Get the shader stages. Do this now, because we need to extract
	// reflection data from them that informs everything else.
	const VkPipelineShaderStageCreateInfo* pVertexSS = nullptr;
	const VkPipelineShaderStageCreateInfo* pTessCtlSS = nullptr;
	const VkPipelineShaderStageCreateInfo* pTessEvalSS = nullptr;
    const VkPipelineShaderStageCreateInfo* pFragmentSS = nullptr;
    const VkPipelineShaderStageCreateInfo* pGeometrySS = nullptr;
	VkPipelineCreationFeedback* pVertexFB = nullptr;
	VkPipelineCreationFeedback* pTessCtlFB = nullptr;
	VkPipelineCreationFeedback* pTessEvalFB = nullptr;
	VkPipelineCreationFeedback* pFragmentFB = nullptr;
    VkPipelineCreationFeedback* pGeometryFB = nullptr;
	for (uint32_t i = 0; i < pCreateInfo->stageCount; i++) {
		const auto* pSS = &pCreateInfo->pStages[i];
		switch (pSS->stage) {
			case VK_SHADER_STAGE_VERTEX_BIT:
				pVertexSS = pSS;
				if (pFeedbackInfo && pFeedbackInfo->pPipelineStageCreationFeedbacks) {
					pVertexFB = &pFeedbackInfo->pPipelineStageCreationFeedbacks[i];
				}
				break;
			case VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT:
				pTessCtlSS = pSS;
				if (pFeedbackInfo && pFeedbackInfo->pPipelineStageCreationFeedbacks) {
					pTessCtlFB = &pFeedbackInfo->pPipelineStageCreationFeedbacks[i];
				}
				break;
			case VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT:
				pTessEvalSS = pSS;
				if (pFeedbackInfo && pFeedbackInfo->pPipelineStageCreationFeedbacks) {
					pTessEvalFB = &pFeedbackInfo->pPipelineStageCreationFeedbacks[i];
				}
				break;
			case VK_SHADER_STAGE_FRAGMENT_BIT:
				pFragmentSS = pSS;
				if (pFeedbackInfo && pFeedbackInfo->pPipelineStageCreationFeedbacks) {
					pFragmentFB = &pFeedbackInfo->pPipelineStageCreationFeedbacks[i];
				}
				break;
            case VK_SHADER_STAGE_GEOMETRY_BIT:
#if MVK_XCODE_14
                if (getPhysicalDevice()->getMetalFeatures()->mslVersionEnum >= MTLLanguageVersion3_0) {
                    pGeometrySS = pSS;
                    _isGeometryPipeline = true;
                    if (pFeedbackInfo && pFeedbackInfo->pPipelineStageCreationFeedbacks) {
                        pGeometryFB = &pFeedbackInfo->pPipelineStageCreationFeedbacks[i];
                    }
                }
#endif
                break;
			default:
				break;
		}
	}

	_vertexModule = getOrCreateShaderModule(device, pVertexSS, _ownsVertexModule);
	_tessCtlModule = getOrCreateShaderModule(device, pTessCtlSS, _ownsTessCtlModule);
	_tessEvalModule = getOrCreateShaderModule(device, pTessEvalSS, _ownsTessEvalModule);
	_geometryModule = getOrCreateShaderModule(device, pGeometrySS, _ownsGeometryModule);
	_fragmentModule = getOrCreateShaderModule(device, pFragmentSS, _ownsFragmentModule);

	warnIfUnsupportedRobustnessEnabled(this, pVertexSS);
	warnIfUnsupportedRobustnessEnabled(this, pTessCtlSS);
	warnIfUnsupportedRobustnessEnabled(this, pTessEvalSS);
	warnIfUnsupportedRobustnessEnabled(this, pGeometrySS);
	warnIfUnsupportedRobustnessEnabled(this, pFragmentSS);

	// Get the tessellation parameters from the shaders.
	SPIRVTessReflectionData reflectData;
	std::string reflectErrorLog;
	if (pTessCtlSS && pTessEvalSS) {
		_isTessellationPipeline = true;

		if (!getTessReflectionData(_tessCtlModule->getSPIRV(), pTessCtlSS->pName, _tessEvalModule->getSPIRV(), pTessEvalSS->pName, reflectData, reflectErrorLog) ) {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to reflect tessellation shaders: %s", reflectErrorLog.c_str()));
			return;
		}
		// Unfortunately, we can't support line tessellation at this time.
		if (reflectData.patchKind == spv::ExecutionModeIsolines) {
			setConfigurationResult(reportError(VK_ERROR_FEATURE_NOT_PRESENT, "Metal does not support isoline tessellation."));
			return;
		}
	}

	// Tessellation - must ignore allowed bad pTessellationState pointer if not tess pipeline
	_outputControlPointCount = reflectData.numControlPoints;
	if (_isTessellationPipeline && pCreateInfo->pTessellationState)
		_staticStateData.patchControlPoints = pCreateInfo->pTessellationState->patchControlPoints;

	if (const VkPipelineRasterizationStateCreateInfo* rs = pCreateInfo->pRasterizationState) {
		const auto* depthClip = mvkFindStructInChain<VkPipelineRasterizationDepthClipStateCreateInfoEXT>(rs, VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT);
		_staticStateData.enable.set(MVKRenderStateEnableFlag::DepthClamp, rs->depthClampEnable);
		_staticStateData.depthClipEnable = depthClip
			? (depthClip->depthClipEnable ? MVKDepthClipEnable::Enabled : MVKDepthClipEnable::Disabled)
			: MVKDepthClipEnable::InverseDepthClamp;
		_staticStateData.enable.set(MVKRenderStateEnableFlag::DepthBias, rs->depthBiasEnable);
		_staticStateData.setCullMode(rs->cullMode);
		_staticStateData.setFrontFace(rs->frontFace);
		_staticStateData.setPolygonMode(rs->polygonMode);
		_staticStateData.depthBias.depthBiasClamp = rs->depthBiasClamp;
		_staticStateData.depthBias.depthBiasSlopeFactor = rs->depthBiasSlopeFactor;
		_staticStateData.depthBias.depthBiasConstantFactor = rs->depthBiasConstantFactor;
		_staticStateData.lineWidth = rs->lineWidth;
		if (const auto* line = mvkFindStructInChain<VkPipelineRasterizationLineStateCreateInfo>(rs, VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_LINE_STATE_CREATE_INFO)) {
			_staticStateData.setLineRasterizationMode(line->lineRasterizationMode);
		}
#if MVK_USE_METAL_PRIVATE_API
		if (const auto* provokingVertex = mvkFindStructInChain<VkPipelineRasterizationProvokingVertexStateCreateInfoEXT>(rs, VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT)) {
			_staticStateData.provokingVertexMode = mvkMTLProvokingVertexModeFromVkProvokingVertexMode(provokingVertex->provokingVertexMode);
		}
#endif
	}

	bool isRasterizingDepthStencil = _isRasterizing && (pRendInfo->depthAttachmentFormat || pRendInfo->stencilAttachmentFormat);
	if (const VkPipelineDepthStencilStateCreateInfo* ds = isRasterizingDepthStencil ? pCreateInfo->pDepthStencilState : nullptr) {
		_staticStateData.enable.set(MVKRenderStateEnableFlag::DepthTest, ds->depthTestEnable);
		_staticStateData.enable.set(MVKRenderStateEnableFlag::DepthBoundsTest, ds->depthBoundsTestEnable);
		_staticStateData.stencilReference.backFaceValue = ds->back.reference;
		_staticStateData.stencilReference.frontFaceValue = ds->front.reference;
		_staticStateData.depthBounds.minDepthBound = ds->minDepthBounds;
		_staticStateData.depthBounds.maxDepthBound = ds->maxDepthBounds;
		_staticStateData.depthStencil.stencilTestEnabled = ds->stencilTestEnable;
		_staticStateData.depthStencil.depthWriteEnabled = ds->depthWriteEnable;
		_staticStateData.depthStencil.depthCompareFunction = mvkMTLCompareFunctionFromVkCompareOp(ds->depthCompareOp);
		loadStencil(_staticStateData.depthStencil.frontFaceStencilData, ds->front);
		loadStencil(_staticStateData.depthStencil.backFaceStencilData, ds->back);
	}

	// Topology - do this before initMTLRenderPipelineState so geometry pipelines can read it
	_vkPrimitiveTopology = VK_PRIMITIVE_TOPOLOGY_POINT_LIST;
	bool primitiveRestart = true; // Always enabled in Metal
	if (pCreateInfo->pInputAssemblyState) {
		_vkPrimitiveTopology = pCreateInfo->pInputAssemblyState->topology;
		primitiveRestart = pCreateInfo->pInputAssemblyState->primitiveRestartEnable;
	}

	// Render pipeline state. Do this as early as possible, to fail fast if pipeline requires a fail on cache-miss.
	initMTLRenderPipelineState(pCreateInfo, reflectData, pPipelineFB, pVertexSS, pVertexFB, pTessCtlSS, pTessCtlFB, pTessEvalSS, pTessEvalFB, pGeometrySS, pGeometryFB, pFragmentSS, pFragmentFB);
	if ( !_hasValidMTLPipelineStates ) { return; }

	// Blending - must ignore allowed bad pColorBlendState pointer if rasterization disabled or no color attachments
	if (_isRasterizingColor && pCreateInfo->pColorBlendState) {
		mvkCopy(_staticStateData.blendConstants.float32, pCreateInfo->pColorBlendState->blendConstants, 4);
	}

	_staticStateData.primitiveType = mvkMTLPrimitiveTypeFromVkPrimitiveTopology(_vkPrimitiveTopology);
	_staticStateData.isTriangleFan = _vkPrimitiveTopology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN;
	_staticStateData.enable.set(MVKRenderStateEnableFlag::PrimitiveRestart, primitiveRestart);

#if MVK_USE_METAL_PRIVATE_API
	if (!getMVKConfig().useMetalPrivateAPI) {
#endif
		// In Metal, primitive restart cannot be disabled, so issue a warning if the app
		// has disabled it statically, or indicates that it might do so dynamically.
		// Just issue a warning here, as it is very likely the app is not actually
		// expecting to use primitive restart at all, and is disabling it "just-in-case".
		// As such, forcing an error here would be unexpected to the app (including CTS).
		// BTW, although Metal docs avoid mentioning it, testing shows that Metal does not support primitive
		// restart for list topologies, meaning VK_EXT_primitive_topology_list_restart cannot be supported.
		if ((!primitiveRestart || _dynamicStateFlags.has(MVKRenderStateFlag::PrimitiveRestartEnable)) &&
			 (_vkPrimitiveTopology == VK_PRIMITIVE_TOPOLOGY_LINE_STRIP ||
			  _vkPrimitiveTopology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP ||
			  _vkPrimitiveTopology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN ||
			  _dynamicStateFlags.has(MVKRenderStateFlag::PrimitiveTopology))) {
			reportWarning(VK_ERROR_FEATURE_NOT_PRESENT, "Metal does not support disabling primitive restart.");
		}
#if MVK_USE_METAL_PRIVATE_API
	}
#endif

	// Must run after _isRasterizing and _dynamicState are populated
	initSampleLocations(pCreateInfo);

	// Viewports and scissors - must ignore allowed bad pViewportState pointer if rasterization is disabled
	if (auto pVPState = _isRasterizing ? pCreateInfo->pViewportState : nullptr) {
		// If viewports are dynamic, ignore them here.
		if (!_dynamicStateFlags.has(MVKRenderStateFlag::Viewports)) {
			uint32_t numViewports = std::min(pVPState->viewportCount, kMVKMaxViewportScissorCount);
			_staticStateData.numViewports = numViewports;
			mvkCopy(_viewports, pVPState->pViewports, numViewports);
		}

		// If scissors are dynamic, ignore them here.
		if (!_dynamicStateFlags.has(MVKRenderStateFlag::Scissors)) {
			uint32_t numScissors = std::min(pVPState->scissorCount, kMVKMaxViewportScissorCount);
			_staticStateData.numScissors = numScissors;
			mvkCopy(_scissors, pVPState->pScissors, numScissors);
		}
	}

	// Remove unneeded state
	MVKRenderStateFlags needed = MVKRenderStateFlags::all();
	if (!_dynamicStateFlags.has(MVKRenderStateFlag::StencilTestEnable) && !_staticStateData.depthStencil.stencilTestEnabled)
		needed.remove(MVKRenderStateFlag::StencilReference);
	if (!_isRasterizingColor || !usesConstantColor(_dynamicStateFlags, pCreateInfo->pColorBlendState))
		needed.remove(MVKRenderStateFlag::BlendConstants);
	if (_primitiveTopologyClass == MTLPrimitiveTopologyClassPoint || _primitiveTopologyClass == MTLPrimitiveTopologyClassLine)
		needed.removeAll({ MVKRenderStateFlag::CullMode, MVKRenderStateFlag::FrontFace });
	if (_primitiveTopologyClass == MTLPrimitiveTopologyClassPoint || _primitiveTopologyClass == MTLPrimitiveTopologyClassTriangle)
		needed.remove(MVKRenderStateFlag::LineWidth);
	if (!_isRasterizing) {
		needed &= {
			MVKRenderStateFlag::PatchControlPoints,
			MVKRenderStateFlag::PrimitiveRestartEnable,
			MVKRenderStateFlag::PrimitiveTopology,
			MVKRenderStateFlag::RasterizerDiscardEnable,
			MVKRenderStateFlag::VertexStride,
		};
	}
	_staticStateFlags = needed.removingAll(_dynamicStateFlags);
	_dynamicStateFlags &= needed;

	for (uint32_t stage = kMVKShaderStageVertex; stage < std::size(_stageResources); stage++) {
		_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::PushConstant] = _layout->getPushConstantResourceIndex(static_cast<MVKShaderStage>(stage));
	}
}

// This is executed first during pipeline creation. Do not depend on any internal state here.
void MVKGraphicsPipeline::initDynamicState(const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	const auto* pDS = pCreateInfo->pDynamicState;
	if ( !pDS ) { return; }

	for (VkDynamicState s : MVKArrayRef(pDS->pDynamicStates, pDS->dynamicStateCount))
		_dynamicStateFlags |= getRenderStateFlags(s);

	// Some dynamic states have other restrictions
	if (_dynamicStateFlags.has(MVKRenderStateFlag::VertexStride)) {
		if ( !getMetalFeatures().dynamicVertexStride ) {
			setConfigurationResult(reportError(VK_ERROR_FEATURE_NOT_PRESENT, "This device and platform does not support VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE (macOS 14.0 or iOS/tvOS 17.0, plus either Apple4 or Mac2 GPU)."));
			_dynamicStateFlags.remove(MVKRenderStateFlag::VertexStride);
		}
	}
}

void MVKGraphicsPipeline::populateRenderingAttachmentInfo(const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	const uint32_t* pColorAttLocs = nullptr;
	if (pCreateInfo->renderPass) {
		MVKRenderSubpass* subpass = ((MVKRenderPass*)pCreateInfo->renderPass)->getSubpass(pCreateInfo->subpass);
		_inputAttachmentIsDSAttachment = subpass->isInputAttachmentDepthStencilAttachment();
	} else {
		for (const auto* next = (VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
			switch (next->sType) {
				case VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_LOCATION_INFO:
					pColorAttLocs = ((VkRenderingAttachmentLocationInfo*)next)->pColorAttachmentLocations;
					break;
				case VK_STRUCTURE_TYPE_RENDERING_INPUT_ATTACHMENT_INDEX_INFO: {
					const auto* pRendInpAttIdxInfo = (VkRenderingInputAttachmentIndexInfo*)next;
					_inputAttachmentIsDSAttachment = ((pRendInpAttIdxInfo->pDepthInputAttachmentIndex && *pRendInpAttIdxInfo->pDepthInputAttachmentIndex != VK_ATTACHMENT_UNUSED) ||
													  (pRendInpAttIdxInfo->pStencilInputAttachmentIndex && *pRendInpAttIdxInfo->pStencilInputAttachmentIndex != VK_ATTACHMENT_UNUSED));
					break;
				}
				default:
					break;
			}
		}
	}

	// Map the attachment locations from the collection defined by VkRenderingAttachmentLocationInfo.
	// If there is no VkRenderingAttachmentLocationInfo, this is just a basic copy to _colorAttachmentFormats.
	auto attCnt = getRenderingCreateInfo(pCreateInfo)->colorAttachmentCount;
	for (uint32_t attIdx = 0; attIdx < attCnt; attIdx++) {
		_colorAttachmentLocations.push_back(pColorAttLocs ? pColorAttLocs[attIdx] : attIdx);
	}
	_hasRemappedAttachmentLocations = (attCnt && pColorAttLocs);
}

// Either returns an existing pipeline state or compiles a new one.
id<MTLRenderPipelineState> MVKGraphicsPipeline::getOrCompilePipeline(MTLRenderPipelineDescriptor* plDesc,
																	 id<MTLRenderPipelineState>& plState) {
	if ( !plState ) {
		MVKRenderPipelineCompiler* plc = new MVKRenderPipelineCompiler(this);
		plState = plc->newMTLRenderPipelineState(plDesc);	// retained
		plc->destroy();
		if ( !plState ) { _hasValidMTLPipelineStates = false; }
	}
	return plState;
}

#if MVK_XCODE_14
// Either returns an existing pipeline state or compiles a new one.
id<MTLRenderPipelineState> MVKGraphicsPipeline::getOrCompilePipeline(MTLMeshRenderPipelineDescriptor* plDesc,
																	 id<MTLRenderPipelineState>& plState) {
	if ( !plState ) {
		MVKRenderPipelineCompiler* plc = new MVKRenderPipelineCompiler(this);
		plState = plc->newMTLRenderPipelineState(plDesc);    // retained
		plc->destroy();
		if ( !plState ) { _hasValidMTLPipelineStates = false; }
	}
	return plState;
}
#endif

// Either returns an existing pipeline state or compiles a new one.
id<MTLComputePipelineState> MVKGraphicsPipeline::getOrCompilePipeline(MTLComputePipelineDescriptor* plDesc,
																	  id<MTLComputePipelineState>& plState,
																	  const char* compilerType) {
	if ( !plState ) {
		MVKComputePipelineCompiler* plc = new MVKComputePipelineCompiler(this, compilerType);
		plState = plc->newMTLComputePipelineState(plDesc);	// retained
		plc->destroy();
		if ( !plState ) { _hasValidMTLPipelineStates = false; }
	}
	return plState;
}

// Must run after _isRasterizing and _dynamicState are populated
void MVKGraphicsPipeline::initSampleLocations(const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	// Must ignore allowed bad pMultisampleState pointer if rasterization disabled
	if ( !(_isRasterizing && pCreateInfo->pMultisampleState) ) { return; }

	for (const auto* next = (VkBaseInStructure*)pCreateInfo->pMultisampleState->pNext; next; next = next->pNext) {
		switch (next->sType) {
			case VK_STRUCTURE_TYPE_PIPELINE_SAMPLE_LOCATIONS_STATE_CREATE_INFO_EXT: {
				auto* pSampLocnsCreateInfo = (VkPipelineSampleLocationsStateCreateInfoEXT*)next;
				uint32_t numLocs = std::min(pSampLocnsCreateInfo->sampleLocationsInfo.sampleLocationsCount, kMVKMaxSampleCount);
				for (uint32_t slIdx = 0; slIdx < numLocs; slIdx++) {
					VkSampleLocationEXT sl = pSampLocnsCreateInfo->sampleLocationsInfo.pSampleLocations[slIdx];
					_sampleLocations[slIdx] = MTLSamplePositionMake(
						mvkClamp(sl.x, kMVKMinSampleLocationCoordinate, kMVKMaxSampleLocationCoordinate),
						mvkClamp(sl.y, kMVKMinSampleLocationCoordinate, kMVKMaxSampleLocationCoordinate));
				}
				_staticStateData.numSampleLocations = numLocs;
				_staticStateData.enable.set(MVKRenderStateEnableFlag::SampleLocations, pSampLocnsCreateInfo->sampleLocationsEnable);
				return;
			}
			default:
				break;
		}
	}
}

// Constructs the underlying Metal render pipeline.
void MVKGraphicsPipeline::initMTLRenderPipelineState(const VkGraphicsPipelineCreateInfo* pCreateInfo,
													 const SPIRVTessReflectionData& reflectData,
													 VkPipelineCreationFeedback* pPipelineFB,
													 const VkPipelineShaderStageCreateInfo* pVertexSS,
													 VkPipelineCreationFeedback* pVertexFB,
													 const VkPipelineShaderStageCreateInfo* pTessCtlSS,
													 VkPipelineCreationFeedback* pTessCtlFB,
													 const VkPipelineShaderStageCreateInfo* pTessEvalSS,
													 VkPipelineCreationFeedback* pTessEvalFB,
                                                     const VkPipelineShaderStageCreateInfo* pGeometrySS,
                                                     VkPipelineCreationFeedback* pGeometryFB,
													 const VkPipelineShaderStageCreateInfo* pFragmentSS,
													 VkPipelineCreationFeedback* pFragmentFB) {
	_mtlTessVertexStageState = nil;
	_mtlTessVertexStageIndex16State = nil;
	_mtlTessVertexStageIndex32State = nil;
	_mtlTessControlStageState = nil;
	_mtlPipelineState = nil;

	uint64_t pipelineStart = 0;
	if (pPipelineFB) {
		pipelineStart = mvkGetTimestamp();
	}

	const char* dumpDir = getMVKConfig().shaderDumpDir;
	// Playable/replay-only runs have already captured the shader identities needed
	// for diagnostics. Avoid rewriting one small pipeline manifest for every UE PSO;
	// thousands of synchronous fopen/write/close calls add startup I/O without
	// contributing to replay or the Metal binary archive.
	if (dumpDir && *dumpDir && !mvkRuntimeReplayOnly()) {
		char filename[PATH_MAX];
		char text[1024];
		char* ptext = text;
		size_t full_hash = 0;
		const char* type = pTessCtlSS && pTessEvalSS ? "-tess" : pGeometrySS ? "-gs" : "";
		auto addShader = [&](const char* type, MVKShaderModule* module) {
			if (!module) {
				return;
			}
			size_t hash = module->getKey().codeHash;
			full_hash = full_hash * 33 ^ hash;
			ptext = std::min(ptext + snprintf(ptext, std::end(text) - ptext, "%s: %016zx\n", type, hash), std::end(text) - 1);
		};
		addShader(" VS", _vertexModule);
		addShader("TCS", _tessCtlModule);
		addShader("TES", _tessEvalModule);
		addShader(" GS", _geometryModule);
		addShader(" FS", _fragmentModule);
		mkdir(dumpDir, 0755);
		snprintf(filename, sizeof(filename), "%s/pipeline%s-%016zx.txt", dumpDir, type, full_hash);
		FILE* file = fopen(filename, "w");
		if (file) {
			fwrite(text, 1, ptext - text, file);
			fclose(file);
		}
	}

	if (isTessellationPipeline()) {
        // In this case, we need to create three render pipelines. But, the way Metal handles
        // index buffers for compute stage-in means we have to create three pipelines for
        // stage 1 (five pipelines in total).
        SPIRVToMSLConversionConfiguration shaderConfig;
        initShaderConversionConfig(shaderConfig, pCreateInfo, reflectData);

        MVKMTLFunction vtxFunctions[3] = {};
        MTLComputePipelineDescriptor* vtxPLDesc = newMTLTessVertexStageDescriptor(pCreateInfo, reflectData, shaderConfig, pVertexSS, pVertexFB, pTessCtlSS, vtxFunctions);                    // temp retained
        MTLComputePipelineDescriptor* tcPLDesc = newMTLTessControlStageDescriptor(pCreateInfo, reflectData, shaderConfig, pTessCtlSS, pTessCtlFB, pVertexSS, pTessEvalSS);                    // temp retained
        MTLRenderPipelineDescriptor* rastPLDesc = newMTLTessRasterStageDescriptor(pCreateInfo, reflectData, shaderConfig, pTessEvalSS, pTessEvalFB, pFragmentSS, pFragmentFB, pTessCtlSS);    // temp retained
        if (vtxPLDesc && tcPLDesc && rastPLDesc) {
            if (compileTessVertexStageState(vtxPLDesc, vtxFunctions, pVertexFB)) {
                if (compileTessControlStageState(tcPLDesc, pTessCtlFB)) {
                    getOrCompilePipeline(rastPLDesc, _mtlPipelineState);
                }
            }
        } else {
            _hasValidMTLPipelineStates = false;
        }
        [vtxPLDesc release];    // temp release
        [tcPLDesc release];        // temp release
        [rastPLDesc release];    // temp release
#if MVK_XCODE_14
	} else if (isGeometryPipeline()) {
		MTLMeshRenderPipelineDescriptor* plDesc = newMTLMeshRenderPipelineDescriptor(pCreateInfo, reflectData, pVertexSS, pVertexFB, pGeometrySS, pGeometryFB, pFragmentSS, pFragmentFB);    // temp retain
		if (plDesc) getOrCompilePipeline(plDesc, _mtlPipelineState);
		else _hasValidMTLPipelineStates = false;
		[plDesc release];                                                                                // temp release
#endif
	} else {
        MTLRenderPipelineDescriptor* plDesc = newMTLRenderPipelineDescriptor(pCreateInfo, reflectData, pVertexSS, pVertexFB, pFragmentSS, pFragmentFB);    // temp retain
		if (plDesc) {
			auto viewMask = getRenderingCreateInfo(pCreateInfo)->viewMask;
			if (mvkIsMultiview(viewMask)) {
				// We need to adjust the step rate for per-instance attributes to account for the
				// extra instances needed to render all views. But, there's a problem: vertex input
				// descriptions are static pipeline state. If we need multiple passes, and some have
				// different numbers of views to render than others, then the step rate must be different
				// for these passes. We'll need to make a pipeline for every pass view count we can see
				// in the render pass. This really sucks.
				std::unordered_set<uint32_t> viewCounts;
				auto passCnt = getDevice()->getMultiviewMetalPassCount(viewMask);
				for (uint32_t passIdx = 0; passIdx < passCnt; ++passIdx) {
					viewCounts.insert(getDevice()->getViewCountInMetalPass(viewMask, passIdx));
				}
				auto count = viewCounts.cbegin();
				adjustVertexInputForMultiview(plDesc.vertexDescriptor, pCreateInfo->pVertexInputState, *count);
				getOrCompilePipeline(plDesc, _mtlPipelineState);
				if (viewCounts.size() > 1) {
					_multiviewMTLPipelineStates[*count] = _mtlPipelineState;
					uint32_t oldCount = *count++;
					for (auto last = viewCounts.cend(); count != last; ++count) {
						if (_multiviewMTLPipelineStates.count(*count)) { continue; }
						adjustVertexInputForMultiview(plDesc.vertexDescriptor, pCreateInfo->pVertexInputState, *count, oldCount);
						getOrCompilePipeline(plDesc, _multiviewMTLPipelineStates[*count]);
						oldCount = *count;
					}
				}
			} else {
				getOrCompilePipeline(plDesc, _mtlPipelineState);
			}
			[plDesc release];																				// temp release
		} else {
			_hasValidMTLPipelineStates = false;
		}
	}

	if (pPipelineFB) {
		if ( _hasValidMTLPipelineStates ) {
			mvkEnableFlags(pPipelineFB->flags, VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT);
		}
		pPipelineFB->duration = mvkGetElapsedNanoseconds(pipelineStart);
	}
}

// Returns a retained MTLRenderPipelineDescriptor constructed from this instance, or nil if an error occurs.
// It is the responsibility of the caller to release the returned descriptor.
MTLRenderPipelineDescriptor* MVKGraphicsPipeline::newMTLRenderPipelineDescriptor(const VkGraphicsPipelineCreateInfo* pCreateInfo,
																				 const SPIRVTessReflectionData& reflectData,
																				 const VkPipelineShaderStageCreateInfo* pVertexSS,
																				 VkPipelineCreationFeedback* pVertexFB,
																				 const VkPipelineShaderStageCreateInfo* pFragmentSS,
																				 VkPipelineCreationFeedback* pFragmentFB) {
	SPIRVToMSLConversionConfiguration shaderConfig;
	initShaderConversionConfig(shaderConfig, pCreateInfo, reflectData);

	MTLRenderPipelineDescriptor* plDesc = [MTLRenderPipelineDescriptor new];	// retained

	SPIRVShaderOutputs vtxOutputs;
	std::string errorLog;
	if (!getShaderOutputs(_vertexModule->getSPIRV(), spv::ExecutionModelVertex, pVertexSS->pName, vtxOutputs, errorLog) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get vertex outputs: %s", errorLog.c_str()));
		return nil;
	}

	// Add shader stages. Compile vertex shader before others just in case conversion changes anything...like rasterizaion disable.
	if (!addVertexShaderToPipeline(plDesc, pCreateInfo, shaderConfig, pVertexSS, pVertexFB, pFragmentSS)) { return nil; }

	// Vertex input
	// This needs to happen before compiling the fragment shader, or we'll lose information on vertex attributes.
	if (!addVertexInputToPipeline(plDesc.vertexDescriptor, pCreateInfo->pVertexInputState, shaderConfig)) { return nil; }

	// Fragment shader - only add if rasterization is enabled
	if (!addFragmentShaderToPipeline(plDesc, pCreateInfo, shaderConfig, vtxOutputs, pFragmentSS, pFragmentFB)) { return nil; }

	// Output
	addFragmentOutputToPipeline(plDesc, pCreateInfo);

	// Metal does not allow the name of the pipeline to be changed after it has been created,
	// and we need to create the Metal pipeline immediately to provide error feedback to app.
	// The best we can do at this point is set the pipeline name from the layout.
	setMetalObjectLabel(plDesc, ((MVKPipelineLayout*)pCreateInfo->layout)->getDebugName());

	return plDesc;
}

#if MVK_XCODE_14
// Returns a retained MTLRenderPipelineDescriptor constructed from this instance, or nil if an error occurs.
// It is the responsibility of the caller to release the returned descriptor.
MTLMeshRenderPipelineDescriptor* MVKGraphicsPipeline::newMTLMeshRenderPipelineDescriptor(const VkGraphicsPipelineCreateInfo* pCreateInfo,
																						 const SPIRVTessReflectionData& reflectData,
                                                                                         const VkPipelineShaderStageCreateInfo* pVertexSS,
                                                                                         VkPipelineCreationFeedback* pVertexFB,
                                                                                         const VkPipelineShaderStageCreateInfo* pGeometrySS,
                                                                                         VkPipelineCreationFeedback* pGeometryFB,
                                                                                         const VkPipelineShaderStageCreateInfo* pFragmentSS,
                                                                                         VkPipelineCreationFeedback* pFragmentFB) {
	SPIRVToMSLConversionConfiguration shaderConfig;
	initShaderConversionConfig(shaderConfig, pCreateInfo, reflectData);

	MTLMeshRenderPipelineDescriptor* plDesc = [MTLMeshRenderPipelineDescriptor new];    // retained

	// The generated geometry-emulation object shader always calls
	// set_threadgroups_per_grid(uint3(1, 1, 1)). Advertise that exact bound
	// so Metal need not schedule for the device's default maximum mesh grid.
	// This descriptor is specific to Vulkan geometry emulation, not native mesh shaders.
	plDesc.maxTotalThreadgroupsPerMeshGrid = 1;
	// Both generated wrappers execute serially, and both direct and indirect
	// geometry dispatches pass one thread per object/mesh threadgroup.
	plDesc.maxTotalThreadsPerObjectThreadgroup = 1;
	plDesc.maxTotalThreadsPerMeshThreadgroup = 1;

	// pMultisampleState may be NULL (and must be ignored) when rasterization is disabled.
	if (_isRasterizing && pCreateInfo->pMultisampleState) {
		plDesc.rasterSampleCount = mvkSampleCountFromVkSampleCountFlagBits(getPhysicalDevice()->getSupportedSampleCount(pCreateInfo->pMultisampleState->rasterizationSamples));
	}

    std::string geomErrorLog;
    _geometryInputVertexCount = getGeometryShaderInputVertexCount(_geometryModule->getSPIRV(), pGeometrySS->pName, geomErrorLog);
    if ( !_geometryInputVertexCount ) {
        setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Geometry shader: %s", geomErrorLog.c_str()));
        return nullptr;
    }
    _geometryOutputVertexCount = getGeometryShaderOutputVertexCount(_geometryModule->getSPIRV(), pGeometrySS->pName, geomErrorLog);
    if ( !_geometryOutputVertexCount ) {
        setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Geometry shader: %s", geomErrorLog.c_str()));
        return nullptr;
    }

    if (!addVertexShaderToPipeline(plDesc, pCreateInfo, shaderConfig, pVertexSS, pVertexFB))
        return nullptr;

    // For mesh pipelines, we need to track which vertex buffers are used
    // so that bindVertexBuffers() can bind them to the object shader.
    const VkPipelineVertexInputStateCreateInfo* pVI = pCreateInfo->pVertexInputState;
    if ( !verifyVertexInputBindings(pVI, shaderConfig) ) { return nullptr; }
    const VkPipelineVertexInputDivisorStateCreateInfo* pVIDivisors = nullptr;
    for (const auto* next = (const VkBaseInStructure*)pVI->pNext; next; next = next->pNext) {
        if (next->sType == VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_DIVISOR_STATE_CREATE_INFO) {
            pVIDivisors = (const VkPipelineVertexInputDivisorStateCreateInfo*)next;
        }
    }
    uint32_t vbCnt = pVI->vertexBindingDescriptionCount;
    for (uint32_t i = 0; i < vbCnt; i++) {
        const VkVertexInputBindingDescription* pVKVB = &pVI->pVertexBindingDescriptions[i];
        if (shaderConfig.isVertexBufferUsed(pVKVB->binding)) {
            uint32_t vbIdx = getMetalBufferIndexForVertexAttributeBinding(pVKVB->binding);
            _mtlVertexBuffers.set(vbIdx);
            _vkVertexBuffers.set(pVKVB->binding);
            // The object stage fetches vertices with these.
            _vkVertexBindingStrides[pVKVB->binding] = pVKVB->stride;
            uint32_t divisor = kMVKGeometryPerVertex;
            if (pVKVB->inputRate == VK_VERTEX_INPUT_RATE_INSTANCE) {
                divisor = 1;
                for (uint32_t d = 0; pVIDivisors && d < pVIDivisors->vertexBindingDivisorCount; d++) {
                    if (pVIDivisors->pVertexBindingDivisors[d].binding == pVKVB->binding) {
                        divisor = pVIDivisors->pVertexBindingDivisors[d].divisor;
                    }
                }
            }
            _vkVertexBindingDivisors[pVKVB->binding] = divisor;
        }
    }

    std::string errorLog;
    SPIRVShaderOutputs vertexOutputs, geometryOutputs;
    if (!getShaderOutputs(_vertexModule->getSPIRV(), spv::ExecutionModelVertex, pVertexSS->pName, vertexOutputs, errorLog)) {
        reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get vertex outputs: %s", errorLog.c_str());
        return nullptr;
    }

    if (!addGeometryShaderToPipeline(plDesc, pCreateInfo, shaderConfig, pGeometrySS, pGeometryFB, vertexOutputs))
        return nullptr;

	if (!getShaderOutputs(_geometryModule->getSPIRV(), spv::ExecutionModelGeometry, pGeometrySS->pName, geometryOutputs, errorLog)) {
		reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get vertex outputs: %s", errorLog.c_str());
		return nullptr;
	}

    if (!addFragmentShaderToPipeline(plDesc, pCreateInfo, shaderConfig, geometryOutputs, pFragmentSS, pFragmentFB, true)) { return nullptr; }

	addFragmentOutputToPipeline(plDesc, pCreateInfo);

	// Metal requires a fragment function in a mesh render pipeline that rasterizes (it asserts in
	// newRenderPipelineStateWithMeshDescriptor: otherwise). Without a Vulkan fragment shader:
	// rasterizer discard (static) disables rasterization; otherwise (depth-only passes, dynamic
	// rasterizer discard) an empty fragment function rasterizes without writing color.
	if ( !_isRasterizing ) {
		plDesc.rasterizationEnabled = NO;
	} else if ( !plDesc.fragmentFunction ) {
		id<MTLFunction> mtlFunc = getDevice()->getCommandResourceFactory()->newEmptyMeshFragmentFunction();	// temp retained
		plDesc.fragmentFunction = mtlFunc;
		[mtlFunc release];
		if ( !mtlFunc ) {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Could not create the fragment function of a geometry-shader pipeline without a fragment shader."));
			return nullptr;
		}
	}

	// Metal does not allow the name of the pipeline to be changed after it has been created,
	// and we need to create the Metal pipeline immediately to provide error feedback to app.
	// The best we can do at this point is set the pipeline name from the layout.
	setMetalObjectLabel(plDesc, ((MVKPipelineLayout*)pCreateInfo->layout)->getDebugName());

	return plDesc;
}
#endif

// Returns a retained MTLComputePipelineDescriptor for the vertex stage of a tessellated draw constructed from this instance, or nil if an error occurs.
// It is the responsibility of the caller to release the returned descriptor.
MTLComputePipelineDescriptor* MVKGraphicsPipeline::newMTLTessVertexStageDescriptor(const VkGraphicsPipelineCreateInfo* pCreateInfo,
																				   const SPIRVTessReflectionData& reflectData,
																				   SPIRVToMSLConversionConfiguration& shaderConfig,
																				   const VkPipelineShaderStageCreateInfo* pVertexSS,
																				   VkPipelineCreationFeedback* pVertexFB,
																				   const VkPipelineShaderStageCreateInfo* pTessCtlSS,
																				   MVKMTLFunction* pVtxFunctions) {
	MTLComputePipelineDescriptor* plDesc = [MTLComputePipelineDescriptor new];	// retained

	SPIRVShaderInputs tcInputs;
	std::string errorLog;
	if (!getShaderInputs(_tessCtlModule->getSPIRV(), spv::ExecutionModelTessellationControl, pTessCtlSS->pName, tcInputs, errorLog) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get tessellation control inputs: %s", errorLog.c_str()));
		return nil;
	}

	// Filter out anything but builtins. We couldn't do this before because we needed to make sure
	// locations were assigned correctly.
	tcInputs.erase(std::remove_if(tcInputs.begin(), tcInputs.end(), [](const SPIRVShaderInterfaceVariable& var) {
		return var.builtin != spv::BuiltInPosition && var.builtin != spv::BuiltInPointSize && var.builtin != spv::BuiltInClipDistance && var.builtin != spv::BuiltInCullDistance;
	}), tcInputs.end());

	// Add shader stages.
	if (!addVertexShaderToPipeline(plDesc, pCreateInfo, shaderConfig, tcInputs, pVertexSS, pVertexFB, pVtxFunctions)) { return nil; }

	// Vertex input
	plDesc.stageInputDescriptor = [MTLStageInputOutputDescriptor stageInputOutputDescriptor];
	if (!addVertexInputToPipeline(plDesc.stageInputDescriptor, pCreateInfo->pVertexInputState, shaderConfig)) { return nil; }
	plDesc.stageInputDescriptor.indexBufferIndex = _stageResources[kMVKShaderStageVertex].implicitBuffers.ids[MVKImplicitBuffer::Index];

	plDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = YES;

	// Metal does not allow the name of the pipeline to be changed after it has been created,
	// and we need to create the Metal pipeline immediately to provide error feedback to app.
	// The best we can do at this point is set the pipeline name from the layout.
	setMetalObjectLabel(plDesc, ((MVKPipelineLayout*)pCreateInfo->layout)->getDebugName());

	return plDesc;
}

static VkFormat mvkFormatFromOutput(const SPIRVShaderOutput& output) {
	switch (output.baseType) {
		case SPIRType::SByte:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R8_SINT;
				case 2: return VK_FORMAT_R8G8_SINT;
				case 3: return VK_FORMAT_R8G8B8_SINT;
				case 4: return VK_FORMAT_R8G8B8A8_SINT;
			}
			break;
		case SPIRType::UByte:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R8_UINT;
				case 2: return VK_FORMAT_R8G8_UINT;
				case 3: return VK_FORMAT_R8G8B8_UINT;
				case 4: return VK_FORMAT_R8G8B8A8_UINT;
			}
			break;
		case SPIRType::Short:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R16_SINT;
				case 2: return VK_FORMAT_R16G16_SINT;
				case 3: return VK_FORMAT_R16G16B16_SINT;
				case 4: return VK_FORMAT_R16G16B16A16_SINT;
			}
			break;
		case SPIRType::UShort:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R16_UINT;
				case 2: return VK_FORMAT_R16G16_UINT;
				case 3: return VK_FORMAT_R16G16B16_UINT;
				case 4: return VK_FORMAT_R16G16B16A16_UINT;
			}
			break;
		case SPIRType::Half:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R16_SFLOAT;
				case 2: return VK_FORMAT_R16G16_SFLOAT;
				case 3: return VK_FORMAT_R16G16B16_SFLOAT;
				case 4: return VK_FORMAT_R16G16B16A16_SFLOAT;
			}
			break;
		case SPIRType::Int:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R32_SINT;
				case 2: return VK_FORMAT_R32G32_SINT;
				case 3: return VK_FORMAT_R32G32B32_SINT;
				case 4: return VK_FORMAT_R32G32B32A32_SINT;
			}
			break;
		case SPIRType::UInt:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R32_UINT;
				case 2: return VK_FORMAT_R32G32_UINT;
				case 3: return VK_FORMAT_R32G32B32_UINT;
				case 4: return VK_FORMAT_R32G32B32A32_UINT;
			}
			break;
		case SPIRType::Float:
			switch (output.vecWidth) {
				case 1: return VK_FORMAT_R32_SFLOAT;
				case 2: return VK_FORMAT_R32G32_SFLOAT;
				case 3: return VK_FORMAT_R32G32B32_SFLOAT;
				case 4: return VK_FORMAT_R32G32B32A32_SFLOAT;
			}
			break;
		default:
			break;
	}
	return VK_FORMAT_UNDEFINED;
}

// Returns a format of the same base type with vector length adjusted to fit size.
static MTLVertexFormat mvkAdjustFormatVectorToSize(MTLVertexFormat format, uint32_t size) {
#define MVK_ADJUST_FORMAT_CASE(size_1, type, suffix) \
	case MTLVertexFormat##type##4##suffix: if (size >= 4 * (size_1)) { return MTLVertexFormat##type##4##suffix; } \
	case MTLVertexFormat##type##3##suffix: if (size >= 3 * (size_1)) { return MTLVertexFormat##type##3##suffix; } \
	case MTLVertexFormat##type##2##suffix: if (size >= 2 * (size_1)) { return MTLVertexFormat##type##2##suffix; } \
	case MTLVertexFormat##type##suffix:    if (size >= 1 * (size_1)) { return MTLVertexFormat##type##suffix; } \
	return MTLVertexFormatInvalid;

	switch (format) {
		MVK_ADJUST_FORMAT_CASE(1, UChar, )
		MVK_ADJUST_FORMAT_CASE(1, Char, )
		MVK_ADJUST_FORMAT_CASE(1, UChar, Normalized)
		MVK_ADJUST_FORMAT_CASE(1, Char, Normalized)
		MVK_ADJUST_FORMAT_CASE(2, UShort, )
		MVK_ADJUST_FORMAT_CASE(2, Short, )
		MVK_ADJUST_FORMAT_CASE(2, UShort, Normalized)
		MVK_ADJUST_FORMAT_CASE(2, Short, Normalized)
		MVK_ADJUST_FORMAT_CASE(2, Half, )
		MVK_ADJUST_FORMAT_CASE(4, Float, )
		MVK_ADJUST_FORMAT_CASE(4, UInt, )
		MVK_ADJUST_FORMAT_CASE(4, Int, )
		default: return format;
	}
#undef MVK_ADJUST_FORMAT_CASE
}

// Returns a retained MTLComputePipelineDescriptor for the tess. control stage of a tessellated draw constructed from this instance, or nil if an error occurs.
// It is the responsibility of the caller to release the returned descriptor.
MTLComputePipelineDescriptor* MVKGraphicsPipeline::newMTLTessControlStageDescriptor(const VkGraphicsPipelineCreateInfo* pCreateInfo,
																					const SPIRVTessReflectionData& reflectData,
																					SPIRVToMSLConversionConfiguration& shaderConfig,
																					const VkPipelineShaderStageCreateInfo* pTessCtlSS,
																					VkPipelineCreationFeedback* pTessCtlFB,
																					const VkPipelineShaderStageCreateInfo* pVertexSS,
																					const VkPipelineShaderStageCreateInfo* pTessEvalSS) {
	MTLComputePipelineDescriptor* plDesc = [MTLComputePipelineDescriptor new];		// retained

	SPIRVShaderOutputs vtxOutputs;
	SPIRVShaderInputs teInputs;
	std::string errorLog;
	if (!getShaderOutputs(_vertexModule->getSPIRV(), spv::ExecutionModelVertex, pVertexSS->pName, vtxOutputs, errorLog) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get vertex outputs: %s", errorLog.c_str()));
		return nil;
	}
	if (!getShaderInputs(_tessEvalModule->getSPIRV(), spv::ExecutionModelTessellationEvaluation, pTessEvalSS->pName, teInputs, errorLog) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get tessellation evaluation inputs: %s", errorLog.c_str()));
		return nil;
	}

	// Filter out anything but builtins. We couldn't do this before because we needed to make sure
	// locations were assigned correctly.
	teInputs.erase(std::remove_if(teInputs.begin(), teInputs.end(), [](const SPIRVShaderInterfaceVariable& var) {
		return var.builtin != spv::BuiltInPosition && var.builtin != spv::BuiltInPointSize && var.builtin != spv::BuiltInClipDistance && var.builtin != spv::BuiltInCullDistance;
	}), teInputs.end());

	// Add shader stages.
	if (!addTessCtlShaderToPipeline(plDesc, pCreateInfo, shaderConfig, vtxOutputs, teInputs, pTessCtlSS, pTessCtlFB)) {
		[plDesc release];
		return nil;
	}

	// Metal does not allow the name of the pipeline to be changed after it has been created,
	// and we need to create the Metal pipeline immediately to provide error feedback to app.
	// The best we can do at this point is set the pipeline name from the layout.
	setMetalObjectLabel(plDesc, ((MVKPipelineLayout*)pCreateInfo->layout)->getDebugName());

	return plDesc;
}

// Returns a retained MTLRenderPipelineDescriptor for the last stage of a tessellated draw constructed from this instance, or nil if an error occurs.
// It is the responsibility of the caller to release the returned descriptor.
MTLRenderPipelineDescriptor* MVKGraphicsPipeline::newMTLTessRasterStageDescriptor(const VkGraphicsPipelineCreateInfo* pCreateInfo,
																				  const SPIRVTessReflectionData& reflectData,
																				  SPIRVToMSLConversionConfiguration& shaderConfig,
																				  const VkPipelineShaderStageCreateInfo* pTessEvalSS,
																				  VkPipelineCreationFeedback* pTessEvalFB,
																				  const VkPipelineShaderStageCreateInfo* pFragmentSS,
																				  VkPipelineCreationFeedback* pFragmentFB,
																				  const VkPipelineShaderStageCreateInfo* pTessCtlSS) {
	MTLRenderPipelineDescriptor* plDesc = [MTLRenderPipelineDescriptor new];	// retained

	SPIRVShaderOutputs tcOutputs, teOutputs;
	SPIRVShaderInputs teInputs;
	std::string errorLog;
	if (!getShaderOutputs(_tessCtlModule->getSPIRV(), spv::ExecutionModelTessellationControl, pTessCtlSS->pName, tcOutputs, errorLog) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get tessellation control outputs: %s", errorLog.c_str()));
		return nil;
	}
	if (!getShaderOutputs(_tessEvalModule->getSPIRV(), spv::ExecutionModelTessellationEvaluation, pTessEvalSS->pName, teOutputs, errorLog) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Failed to get tessellation evaluation outputs: %s", errorLog.c_str()));
		return nil;
	}

	// Add shader stages. Compile tessellation evaluation shader before others just in case conversion changes anything...like rasterizaion disable.
	if (!addTessEvalShaderToPipeline(plDesc, pCreateInfo, shaderConfig, tcOutputs, pTessEvalSS, pTessEvalFB, pFragmentSS)) {
		[plDesc release];
		return nil;
	}

	// Fragment shader - only add if rasterization is enabled
	if (!addFragmentShaderToPipeline(plDesc, pCreateInfo, shaderConfig, teOutputs, pFragmentSS, pFragmentFB)) {
		[plDesc release];
		return nil;
	}

	// Tessellation state
	addTessellationToPipeline(plDesc, reflectData, pCreateInfo->pTessellationState);

	// Output
	addFragmentOutputToPipeline(plDesc, pCreateInfo);

	return plDesc;
}

static constexpr const char* getImplicitBufferName(MVKImplicitBuffer buffer) {
	switch (buffer) {
		case MVKImplicitBuffer::PushConstant:   return "push constant";
		case MVKImplicitBuffer::BufferSize:     return "buffer size";
		case MVKImplicitBuffer::DynamicOffset:  return "dynamic offset";
		case MVKImplicitBuffer::TextureOffset:  return "texture offset";
		case MVKImplicitBuffer::ViewRange:      return "view range";
		case MVKImplicitBuffer::EmulatedReversedDepthViewport: return "emulated reversed-depth viewport";
		case MVKImplicitBuffer::DepthClip:      return "depth clip state";
		case MVKImplicitBuffer::IndirectParams: return "indirect parameter";
		case MVKImplicitBuffer::Output:         return "per-vertex output";
		case MVKImplicitBuffer::PatchOutput:    return "per-patch output";
		case MVKImplicitBuffer::TessLevel:      return "tessellation level";
		case MVKImplicitBuffer::Index:          return "index";
		case MVKImplicitBuffer::DispatchBase:   return "dispatch base";
		case MVKImplicitBuffer::Count:          break;
	}
	assert(0);
	return "unknown";
}

static bool verifyImplicitBuffers(MVKImplicitBufferBindings& buffers, const char* stageName, uint32_t limit, MVKPipeline* pipeline) {
	static constexpr MVKImplicitBufferList ignored = MVKImplicitBuffer::PushConstant; // Push constants are in the main buffer area
	for (MVKImplicitBuffer needed : buffers.needed.removingAll(ignored)) {
		if (buffers.ids[needed] < limit || buffers.ids[needed] == kMVKUnassignedImplicitBufferIndex) {
			pipeline->setConfigurationResult(pipeline->reportError(VK_ERROR_INITIALIZATION_FAILED, "%s shader requires %s buffer, but there is no free slot to pass it.", stageName, getImplicitBufferName(needed)));
			return false;
		}
	}
	return true;
}

static void addCommonImplicitBuffersToShaderConfig(SPIRVToMSLConversionConfiguration& dst, const MVKOnePerEnumEntry<uint8_t, MVKImplicitBuffer>& src) {
	dst.options.mslOptions.buffer_size_buffer_index = src[MVKImplicitBuffer::BufferSize];
	dst.options.mslOptions.dynamic_offsets_buffer_index = src[MVKImplicitBuffer::DynamicOffset];
	dst.options.mslOptions.texture_offset_buffer_index = src[MVKImplicitBuffer::TextureOffset];
}

static void setEmulatedReversedDepthViewportConfig(SPIRVToMSLConversionConfiguration& shaderConfig, const MVKOnePerEnumEntry<uint8_t, MVKImplicitBuffer>& implicit, bool enable) {
	shaderConfig.options.mslOptions.emulate_reversed_depth_viewport = enable;
	shaderConfig.options.mslOptions.reversed_depth_viewport_buffer_index = enable ? implicit[MVKImplicitBuffer::EmulatedReversedDepthViewport] : 0;
}

static bool canDepthClipAndClampBothBe(MVKRenderStateFlags dynamic, const MVKRenderStateData& state, bool enabled) {
	bool dynamicClamp = dynamic.has(MVKRenderStateFlag::DepthClampEnable);
	bool dynamicClip = dynamic.has(MVKRenderStateFlag::DepthClipEnable);

	// Without explicit clip state, Vulkan defines clip as the inverse of clamp.
	if (!dynamicClip && state.depthClipEnable == MVKDepthClipEnable::InverseDepthClamp) {
		return false;
	}

	bool staticClampMatches = state.enable.has(MVKRenderStateEnableFlag::DepthClamp) == enabled;
	bool staticClipMatches = mvkIsDepthClipEnabled(state.depthClipEnable,
	                                               state.enable.has(MVKRenderStateEnableFlag::DepthClamp)) == enabled;
	return (dynamicClamp || staticClampMatches) && (dynamicClip || staticClipMatches);
}

static void setDepthClipConfig(SPIRVToMSLConversionConfiguration& shaderConfig, const MVKOnePerEnumEntry<uint8_t, MVKImplicitBuffer>& implicit, bool enable) {
	shaderConfig.options.mslOptions.emulate_depth_clip_enable = enable;
	shaderConfig.options.mslOptions.depth_clip_state_buffer_index = enable ? implicit[MVKImplicitBuffer::DepthClip] : 0;
}

bool MVKGraphicsPipeline::verifyImplicitBuffers(MVKShaderStage stage) {
	const char* stageNames[] = {
		"Vertex",
		"Tessellation control",
		"Tessellation evaluation",
		"Geometry",
		"Fragment"
	};

	return ::verifyImplicitBuffers(_stageResources[stage].implicitBuffers, stageNames[stage], _descriptorBufferCounts.stages[stage], this);
}

// Adds a vertex shader to the pipeline description.
bool MVKGraphicsPipeline::addVertexShaderToPipeline(MTLRenderPipelineDescriptor* plDesc,
													const VkGraphicsPipelineCreateInfo* pCreateInfo,
													SPIRVToMSLConversionConfiguration& shaderConfig,
													const VkPipelineShaderStageCreateInfo* pVertexSS,
													VkPipelineCreationFeedback* pVertexFB,
													const VkPipelineShaderStageCreateInfo*& pFragmentSS) {
	const auto& implicit = _stageResources[kMVKShaderStageVertex].implicitBuffers.ids;
	shaderConfig.options.entryPointStage = spv::ExecutionModelVertex;
	shaderConfig.options.entryPointName = pVertexSS->pName;
	addCommonImplicitBuffersToShaderConfig(shaderConfig, implicit);
	shaderConfig.options.mslOptions.shader_output_buffer_index = implicit[MVKImplicitBuffer::Output];
	shaderConfig.options.mslOptions.view_mask_buffer_index = implicit[MVKImplicitBuffer::ViewRange];
	shaderConfig.options.mslOptions.capture_output_to_buffer = false;
	shaderConfig.options.mslOptions.disable_rasterization = !_isRasterizing;
	shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo, pVertexSS);
	shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo, pVertexSS);
	setEmulatedReversedDepthViewportConfig(shaderConfig, implicit, getPhysicalDevice()->shouldEmulateReversedDepthViewport());
	setDepthClipConfig(shaderConfig, implicit, _isRasterizing && canDepthClipAndClampBothBe(_dynamicStateFlags, _staticStateData, false));
    addVertexInputToShaderConversionConfig(shaderConfig, pCreateInfo);
	// Metal fails a render pipeline whose vertex function reads an attribute missing from the vertex descriptor
	// ("Vertex attribute in_var_NORMAL(1) is missing from the vertex descriptor", SCS Truck Simulator, STEAMAC-2Y),
	// while Vulkan only leaves the values read undefined: SPIRV-Cross makes inputs without an attribute read zeros.
	shaderConfig.options.mslOptions.zero_missing_vertex_attributes = true;

	MVKMTLFunction func = getMTLFunction(shaderConfig, pVertexSS, pVertexFB, _vertexModule, "Vertex");
	id<MTLFunction> mtlFunc = func.getMTLFunction();
	plDesc.vertexFunction = mtlFunc;
	if ( !mtlFunc ) { return false; }

	auto& funcRslts = func.shaderConversionResults;
	// Transform feedback is only captured by geometry shaders (emulated with mesh shaders).
	if (funcRslts.needsXfbBuffer) {
		setConfigurationResult(reportError(VK_ERROR_FEATURE_NOT_PRESENT, "Transform feedback from a vertex shader without a geometry shader is not supported."));
		return false;
	}
	plDesc.rasterizationEnabled = !funcRslts.isRasterizationDisabled;
	populateResourceUsage(_stageResources[kMVKShaderStageVertex], shaderConfig, funcRslts, spv::ExecutionModelVertex);
	_stageResources[kMVKShaderStageVertex].implicitBuffers.needed.set(MVKImplicitBuffer::EmulatedReversedDepthViewport, shaderConfig.options.mslOptions.emulate_reversed_depth_viewport);
	_layout->populateBindOperations(_stageResources[kMVKShaderStageVertex].bindScript, shaderConfig, spv::ExecutionModelVertex);

	if (funcRslts.isRasterizationDisabled) {
		pFragmentSS = nullptr;
	}

	return verifyImplicitBuffers(kMVKShaderStageVertex);
}

// The component type in memory of a vertex format, for the geometry-shader (mesh) object stage, which
// fetches vertex attributes itself and converts them to the shader's type (SCALED formats are integers
// converted to float, NORM formats are additionally normalized).
static MSLShaderVariableFormat mvkMSLMeshVertexMemoryFormat(MTLVertexFormat mtlFormat) {
	switch (mtlFormat) {
		case MTLVertexFormatUChar: case MTLVertexFormatUChar2: case MTLVertexFormatUChar3: case MTLVertexFormatUChar4:
		case MTLVertexFormatUCharNormalized: case MTLVertexFormatUChar2Normalized:
		case MTLVertexFormatUChar3Normalized: case MTLVertexFormatUChar4Normalized:
			return MSL_SHADER_VARIABLE_FORMAT_UINT8;
		case MTLVertexFormatChar: case MTLVertexFormatChar2: case MTLVertexFormatChar3: case MTLVertexFormatChar4:
		case MTLVertexFormatCharNormalized: case MTLVertexFormatChar2Normalized:
		case MTLVertexFormatChar3Normalized: case MTLVertexFormatChar4Normalized:
			return MSL_SHADER_VARIABLE_FORMAT_INT8;
		case MTLVertexFormatUShort: case MTLVertexFormatUShort2: case MTLVertexFormatUShort3: case MTLVertexFormatUShort4:
		case MTLVertexFormatUShortNormalized: case MTLVertexFormatUShort2Normalized:
		case MTLVertexFormatUShort3Normalized: case MTLVertexFormatUShort4Normalized:
			return MSL_SHADER_VARIABLE_FORMAT_UINT16;
		case MTLVertexFormatShort: case MTLVertexFormatShort2: case MTLVertexFormatShort3: case MTLVertexFormatShort4:
		case MTLVertexFormatShortNormalized: case MTLVertexFormatShort2Normalized:
		case MTLVertexFormatShort3Normalized: case MTLVertexFormatShort4Normalized:
			return MSL_SHADER_VARIABLE_FORMAT_INT16;
		case MTLVertexFormatHalf: case MTLVertexFormatHalf2: case MTLVertexFormatHalf3: case MTLVertexFormatHalf4:
			return MSL_SHADER_VARIABLE_FORMAT_HALF;
		case MTLVertexFormatFloat: case MTLVertexFormatFloat2: case MTLVertexFormatFloat3: case MTLVertexFormatFloat4:
			return MSL_SHADER_VARIABLE_FORMAT_FLOAT;
		case MTLVertexFormatUInt: case MTLVertexFormatUInt2: case MTLVertexFormatUInt3: case MTLVertexFormatUInt4:
			return MSL_SHADER_VARIABLE_FORMAT_UINT32;
		case MTLVertexFormatInt: case MTLVertexFormatInt2: case MTLVertexFormatInt3: case MTLVertexFormatInt4:
			return MSL_SHADER_VARIABLE_FORMAT_INT32;
		default:
			return MSL_SHADER_VARIABLE_FORMAT_OTHER;
	}
}

struct MSLVertexFormatInfo {
	uint8_t num_elements : 7;
	bool normalized : 1;
};

static constexpr MSLVertexFormatInfo vertexFormatInfo[] = {
	[VK_FORMAT_R8_UNORM]             = {1, true},
	[VK_FORMAT_R8_SNORM]             = {1, true},
	[VK_FORMAT_R8_USCALED]           = {1, false},
	[VK_FORMAT_R8_SSCALED]           = {1, false},
	[VK_FORMAT_R8_UINT]              = {1, false},
	[VK_FORMAT_R8_SINT]              = {1, false},
	[VK_FORMAT_R8G8_UNORM]           = {2, true},
	[VK_FORMAT_R8G8_SNORM]           = {2, true},
	[VK_FORMAT_R8G8_USCALED]         = {2, false},
	[VK_FORMAT_R8G8_SSCALED]         = {2, false},
	[VK_FORMAT_R8G8_UINT]            = {2, false},
	[VK_FORMAT_R8G8_SINT]            = {2, false},
	[VK_FORMAT_R8G8B8_UNORM]         = {3, true},
	[VK_FORMAT_R8G8B8_SNORM]         = {3, true},
	[VK_FORMAT_R8G8B8_USCALED]       = {3, false},
	[VK_FORMAT_R8G8B8_SSCALED]       = {3, false},
	[VK_FORMAT_R8G8B8_UINT]          = {3, false},
	[VK_FORMAT_R8G8B8_SINT]          = {3, false},
	[VK_FORMAT_R8G8B8A8_UNORM]       = {4, true},
	[VK_FORMAT_R8G8B8A8_SNORM]       = {4, true},
	[VK_FORMAT_R8G8B8A8_USCALED]     = {4, false},
	[VK_FORMAT_R8G8B8A8_SSCALED]     = {4, false},
	[VK_FORMAT_R8G8B8A8_UINT]        = {4, false},
	[VK_FORMAT_R8G8B8A8_SINT]        = {4, false},
    [VK_FORMAT_B8G8R8A8_UNORM]       = {4, true},
    [VK_FORMAT_B8G8R8A8_SNORM]       = {4, true},
    [VK_FORMAT_B8G8R8A8_USCALED]     = {4, false},
    [VK_FORMAT_B8G8R8A8_SSCALED]     = {4, false},
    [VK_FORMAT_B8G8R8A8_UINT]        = {4, false},
    [VK_FORMAT_B8G8R8A8_SINT]        = {4, false},
    [VK_FORMAT_R16_UNORM]            = {1, true},
	[VK_FORMAT_R16_SNORM]            = {1, true},
	[VK_FORMAT_R16_USCALED]          = {1, false},
	[VK_FORMAT_R16_SSCALED]          = {1, false},
	[VK_FORMAT_R16_UINT]             = {1, false},
	[VK_FORMAT_R16_SINT]             = {1, false},
	[VK_FORMAT_R16_SFLOAT]           = {1, false},
	[VK_FORMAT_R16G16_UNORM]         = {2, true},
	[VK_FORMAT_R16G16_SNORM]         = {2, true},
	[VK_FORMAT_R16G16_USCALED]       = {2, false},
	[VK_FORMAT_R16G16_SSCALED]       = {2, false},
	[VK_FORMAT_R16G16_UINT]          = {2, false},
	[VK_FORMAT_R16G16_SINT]          = {2, false},
	[VK_FORMAT_R16G16_SFLOAT]        = {2, false},
	[VK_FORMAT_R16G16B16_UNORM]      = {3, true},
	[VK_FORMAT_R16G16B16_SNORM]      = {3, true},
	[VK_FORMAT_R16G16B16_USCALED]    = {3, false},
	[VK_FORMAT_R16G16B16_SSCALED]    = {3, false},
	[VK_FORMAT_R16G16B16_UINT]       = {3, false},
	[VK_FORMAT_R16G16B16_SINT]       = {3, false},
	[VK_FORMAT_R16G16B16_SFLOAT]     = {3, false},
	[VK_FORMAT_R16G16B16A16_UNORM]   = {4, true},
	[VK_FORMAT_R16G16B16A16_SNORM]   = {4, true},
	[VK_FORMAT_R16G16B16A16_USCALED] = {4, false},
	[VK_FORMAT_R16G16B16A16_SSCALED] = {4, false},
	[VK_FORMAT_R16G16B16A16_UINT]    = {4, false},
	[VK_FORMAT_R16G16B16A16_SINT]    = {4, false},
	[VK_FORMAT_R16G16B16A16_SFLOAT]  = {4, false},
	[VK_FORMAT_R32_UINT]             = {1, false},
	[VK_FORMAT_R32_SINT]             = {1, false},
	[VK_FORMAT_R32_SFLOAT]           = {1, false},
	[VK_FORMAT_R32G32_UINT]          = {2, false},
	[VK_FORMAT_R32G32_SINT]          = {2, false},
	[VK_FORMAT_R32G32_SFLOAT]        = {2, false},
	[VK_FORMAT_R32G32B32_UINT]       = {3, false},
	[VK_FORMAT_R32G32B32_SINT]       = {3, false},
	[VK_FORMAT_R32G32B32_SFLOAT]     = {3, false},
	[VK_FORMAT_R32G32B32A32_UINT]    = {4, false},
	[VK_FORMAT_R32G32B32A32_SINT]    = {4, false},
	[VK_FORMAT_R32G32B32A32_SFLOAT]  = {4, false},
};

#if MVK_XCODE_14

// Sets the input primitive type of the geometry-shader emulation (object + mesh stages)
// from the pipeline topology. Returns false (pipeline creation fails) if it is not supported.
bool MVKGraphicsPipeline::setGeometryInputPrimitiveType(SPIRVToMSLConversionConfiguration& shaderConfig) {
	// The input primitive is the geometry shader's (InputPoints, InputLines, ...). The pipeline topology
	// may be dynamic state, and then only its class is known here; whether the draw's topology is a list,
	// strip or fan is passed to the object stage at draw time (DrawInfo::topoStrip).
	using Topology = CompilerMSL::Options::PrimitiveTopology;
	auto& inputType = shaderConfig.options.mslOptions.input_primitive_type;
	switch (_geometryInputVertexCount) {
		case 1: inputType = Topology::Points;             return true;
		case 2: inputType = Topology::Lines;              return true;
		case 3: inputType = Topology::Triangles;          return true;
		case 4: inputType = Topology::LinesAdjacency;     return true;
		case 6: inputType = Topology::TrianglesAdjacency; return true;
		default:
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Geometry shaders: unsupported input primitive (%u vertices).", _geometryInputVertexCount));
			return false;
	}
}

bool MVKGraphicsPipeline::addVertexShaderToPipeline(MTLMeshRenderPipelineDescriptor* plDesc,
                                                    const VkGraphicsPipelineCreateInfo* pCreateInfo,
                                                    SPIRVToMSLConversionConfiguration& shaderConfig,
                                                    const VkPipelineShaderStageCreateInfo* pVertexSS,
                                                    VkPipelineCreationFeedback* pVertexFB) {
	const auto& implicit = _stageResources[kMVKShaderStageVertex].implicitBuffers.ids;
	shaderConfig.options.entryPointStage = spv::ExecutionModelVertex;
	shaderConfig.options.entryPointName = pVertexSS->pName;
	addCommonImplicitBuffersToShaderConfig(shaderConfig, implicit);
	shaderConfig.options.mslOptions.shader_output_buffer_index = implicit[MVKImplicitBuffer::Output];
	shaderConfig.options.mslOptions.view_mask_buffer_index = implicit[MVKImplicitBuffer::ViewRange];
	shaderConfig.options.mslOptions.capture_output_to_buffer = false;
	// The vertex shader feeds the geometry shader (object stage), never the rasterizer.
	shaderConfig.options.mslOptions.disable_rasterization = false;
	shaderConfig.options.mslOptions.for_mesh_pipeline = true;
	shaderConfig.options.uniqueEntryPointName = getPhysicalDevice()->isAMDHardware();
	shaderConfig.options.mslOptions.msl_version = getPhysicalDevice()->getMetalFeatures()->mslVersion;
	shaderConfig.options.shouldFlipVertexY = false;
	// steamac: the object/mesh (geometry shader) stages emit positions through the mesh path, which
	// has no reversed-depth/depth-clip emulation in SPIRV-Cross; keep both off.
	setEmulatedReversedDepthViewportConfig(shaderConfig, implicit, false);
	setDepthClipConfig(shaderConfig, implicit, false);
	// Apply per-stage robustness settings
	shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo, pVertexSS);
	shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo, pVertexSS);

	if ( !setGeometryInputPrimitiveType(shaderConfig) ) { return false; }

	if (_meshDrawInfoBufferIndex < _descriptorBufferCounts.stages[kMVKShaderStageVertex] ||
		_meshDrawInfoBufferIndex == kMVKUnassignedImplicitBufferIndex) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Vertex shader of a geometry pipeline requires a draw info buffer, but there is no free slot to pass it."));
		return false;
	}
	shaderConfig.options.mslOptions.draw_info_index = _meshDrawInfoBufferIndex;

	addVertexInputToShaderConversionConfig(shaderConfig, pCreateInfo);

	MVKMTLFunction func = getMTLFunction(shaderConfig, pVertexSS, pVertexFB, _vertexModule, "Vertex");
	id<MTLFunction> mtlFunc = func.getMTLFunction();
	if ( !mtlFunc ) { return false; }

	auto& funcRslts = func.shaderConversionResults;
	populateResourceUsage(_stageResources[kMVKShaderStageVertex], shaderConfig, funcRslts, spv::ExecutionModelVertex);
	_layout->populateBindOperations(_stageResources[kMVKShaderStageVertex].bindScript, shaderConfig, spv::ExecutionModelVertex);

	plDesc.objectFunction = mtlFunc;
	return verifyImplicitBuffers(kMVKShaderStageVertex);
}

bool MVKGraphicsPipeline::addGeometryShaderToPipeline(MTLMeshRenderPipelineDescriptor* plDesc,
                                                      const VkGraphicsPipelineCreateInfo* pCreateInfo,
                                                      SPIRVToMSLConversionConfiguration& shaderConfig,
                                                      const VkPipelineShaderStageCreateInfo* pGeometrySS,
                                                      VkPipelineCreationFeedback* pGeometryFB,
                                                      SPIRVShaderOutputs &vertexOutputs) {
	const auto& implicit = _stageResources[kMVKShaderStageGeometry].implicitBuffers.ids;
	shaderConfig.options.entryPointStage = spv::ExecutionModelGeometry;
	shaderConfig.options.entryPointName = pGeometrySS->pName;
	addCommonImplicitBuffersToShaderConfig(shaderConfig, implicit);
	shaderConfig.options.mslOptions.shader_output_buffer_index = implicit[MVKImplicitBuffer::Output];
	shaderConfig.options.mslOptions.view_mask_buffer_index = implicit[MVKImplicitBuffer::ViewRange];
	shaderConfig.options.mslOptions.capture_output_to_buffer = false;
	shaderConfig.options.mslOptions.disable_rasterization = !_isRasterizing;
	shaderConfig.options.mslOptions.for_mesh_pipeline = true;
	shaderConfig.options.uniqueEntryPointName = getPhysicalDevice()->isAMDHardware();
	shaderConfig.options.mslOptions.msl_version = getPhysicalDevice()->getMetalFeatures()->mslVersion;
	shaderConfig.options.shouldFlipVertexY = true;
	setEmulatedReversedDepthViewportConfig(shaderConfig, implicit, false);
	setDepthClipConfig(shaderConfig, implicit, false);
	// Apply per-stage robustness settings
	shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo, pGeometrySS);
	shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo, pGeometrySS);

	if ( !setGeometryInputPrimitiveType(shaderConfig) ) { return false; }

	// Transform feedback buffers 0..3, session state, per-primitive slots, mode (see SPIRV-Cross emit_mesh_wrapper()).
	_geometryXfbIndices.buffer0 = getImplicitBufferIndex(kMVKShaderStageGeometry, 9);
	_geometryXfbIndices.session = getImplicitBufferIndex(kMVKShaderStageGeometry, 13);
	_geometryXfbIndices.prims   = getImplicitBufferIndex(kMVKShaderStageGeometry, 14);
	_geometryXfbIndices.mode    = getImplicitBufferIndex(kMVKShaderStageGeometry, 15);
	shaderConfig.options.mslOptions.xfb_buffer_index  = _geometryXfbIndices.buffer0;
	shaderConfig.options.mslOptions.xfb_session_index = _geometryXfbIndices.session;
	shaderConfig.options.mslOptions.xfb_prims_index   = _geometryXfbIndices.prims;
	shaderConfig.options.mslOptions.xfb_mode_index    = _geometryXfbIndices.mode;

	addPrevStageOutputToShaderConversionConfig(shaderConfig, vertexOutputs);

	MVKMTLFunction func = getMTLFunction(shaderConfig, pGeometrySS, pGeometryFB, _geometryModule, "Geometry");
	id<MTLFunction> mtlFunc = func.getMTLFunction();
	if ( !mtlFunc ) { return false; }

	auto& funcRslts = func.shaderConversionResults;
	_usesGeometryXfb = funcRslts.needsXfbBuffer;
	if (_usesGeometryXfb && (_geometryXfbIndices.mode == kMVKUnassignedImplicitBufferIndex ||
							 _geometryXfbIndices.mode < _descriptorBufferCounts.stages[kMVKShaderStageGeometry])) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Geometry shader requires transform feedback buffers, but there is no free slot to pass them."));
		return false;
	}
	populateResourceUsage(_stageResources[kMVKShaderStageGeometry], shaderConfig, funcRslts, spv::ExecutionModelGeometry);
	_layout->populateBindOperations(_stageResources[kMVKShaderStageGeometry].bindScript, shaderConfig, spv::ExecutionModelGeometry);

	plDesc.meshFunction = mtlFunc;
	return verifyImplicitBuffers(kMVKShaderStageGeometry);
}

#endif

// Adds a vertex shader compiled as a compute kernel to the pipeline description.
bool MVKGraphicsPipeline::addVertexShaderToPipeline(MTLComputePipelineDescriptor* plDesc,
													const VkGraphicsPipelineCreateInfo* pCreateInfo,
													SPIRVToMSLConversionConfiguration& shaderConfig,
													SPIRVShaderInputs& tcInputs,
													const VkPipelineShaderStageCreateInfo* pVertexSS,
													VkPipelineCreationFeedback* pVertexFB,
													MVKMTLFunction* pVtxFunctions) {
	const auto& implicit = _stageResources[kMVKShaderStageVertex].implicitBuffers.ids;
	shaderConfig.options.entryPointStage = spv::ExecutionModelVertex;
	shaderConfig.options.entryPointName = pVertexSS->pName;
	addCommonImplicitBuffersToShaderConfig(shaderConfig, implicit);
	shaderConfig.options.mslOptions.shader_index_buffer_index = implicit[MVKImplicitBuffer::Index];
	shaderConfig.options.mslOptions.shader_output_buffer_index = implicit[MVKImplicitBuffer::Output];
	shaderConfig.options.mslOptions.capture_output_to_buffer = true;
	shaderConfig.options.mslOptions.vertex_for_tessellation = true;
	shaderConfig.options.mslOptions.disable_rasterization = true;
	shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo, pVertexSS);
	shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo, pVertexSS);
	setEmulatedReversedDepthViewportConfig(shaderConfig, implicit, false);
	setDepthClipConfig(shaderConfig, implicit, false);
    addVertexInputToShaderConversionConfig(shaderConfig, pCreateInfo);
	addNextStageInputToShaderConversionConfig(shaderConfig, tcInputs);

	// We need to compile this function three times, with no indexing, 16-bit indices, and 32-bit indices.
	static const CompilerMSL::Options::IndexType indexTypes[] = {
		CompilerMSL::Options::IndexType::None,
		CompilerMSL::Options::IndexType::UInt16,
		CompilerMSL::Options::IndexType::UInt32,
	};
	MVKMTLFunction func;
	for (uint32_t i = 0; i < sizeof(indexTypes)/sizeof(indexTypes[0]); i++) {
		shaderConfig.options.mslOptions.vertex_index_type = indexTypes[i];
		func = getMTLFunction(shaderConfig, pVertexSS, pVertexFB, _vertexModule, "Vertex");
		if ( !func.getMTLFunction() ) { return false; }

		pVtxFunctions[i] = func;

		auto& funcRslts = func.shaderConversionResults;
		populateResourceUsage(_stageResources[kMVKShaderStageVertex], shaderConfig, funcRslts, spv::ExecutionModelVertex);
	}

	_layout->populateBindOperations(_stageResources[kMVKShaderStageVertex].bindScript, shaderConfig, spv::ExecutionModelVertex);

	_stageResources[kMVKShaderStageVertex].implicitBuffers.needed.set(MVKImplicitBuffer::Index, !shaderConfig.shaderInputs.empty());
	return verifyImplicitBuffers(kMVKShaderStageVertex);
}

bool MVKGraphicsPipeline::addTessCtlShaderToPipeline(MTLComputePipelineDescriptor* plDesc,
													 const VkGraphicsPipelineCreateInfo* pCreateInfo,
													 SPIRVToMSLConversionConfiguration& shaderConfig,
													 SPIRVShaderOutputs& vtxOutputs,
													 SPIRVShaderInputs& teInputs,
													 const VkPipelineShaderStageCreateInfo* pTessCtlSS,
													 VkPipelineCreationFeedback* pTessCtlFB) {
	const auto& implicit = _stageResources[kMVKShaderStageTessCtl].implicitBuffers.ids;
	shaderConfig.options.entryPointStage = spv::ExecutionModelTessellationControl;
	shaderConfig.options.entryPointName = pTessCtlSS->pName;
	addCommonImplicitBuffersToShaderConfig(shaderConfig, implicit);
	shaderConfig.options.mslOptions.indirect_params_buffer_index = implicit[MVKImplicitBuffer::IndirectParams];
	shaderConfig.options.mslOptions.shader_input_buffer_index = getMetalBufferIndexForVertexAttributeBinding(kMVKTessCtlInputBufferBinding);
	shaderConfig.options.mslOptions.shader_output_buffer_index = implicit[MVKImplicitBuffer::Output];
	shaderConfig.options.mslOptions.shader_patch_output_buffer_index = implicit[MVKImplicitBuffer::PatchOutput];
	shaderConfig.options.mslOptions.shader_tess_factor_buffer_index = implicit[MVKImplicitBuffer::TessLevel];
	shaderConfig.options.mslOptions.capture_output_to_buffer = true;
	shaderConfig.options.mslOptions.multi_patch_workgroup = true;
	shaderConfig.options.mslOptions.fixed_subgroup_size = mvkIsAnyFlagEnabled(pTessCtlSS->flags, VK_PIPELINE_SHADER_STAGE_CREATE_ALLOW_VARYING_SUBGROUP_SIZE_BIT) ? 0 : getMetalFeatures().maxSubgroupSize;
	shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo, pTessCtlSS);
	shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo, pTessCtlSS);
	setEmulatedReversedDepthViewportConfig(shaderConfig, implicit, false);
	setDepthClipConfig(shaderConfig, implicit, false);
	addPrevStageOutputToShaderConversionConfig(shaderConfig, vtxOutputs);
	addNextStageInputToShaderConversionConfig(shaderConfig, teInputs);

	MVKMTLFunction func = getMTLFunction(shaderConfig, pTessCtlSS, pTessCtlFB, _tessCtlModule, "Tessellation control");
	id<MTLFunction> mtlFunc = func.getMTLFunction();
	if ( !mtlFunc ) { return false; }
	plDesc.computeFunction = mtlFunc;

	auto& funcRslts = func.shaderConversionResults;
	_stageResources[kMVKShaderStageTessCtl].implicitBuffers.needed.addAll({ // Always needed
		MVKImplicitBuffer::IndirectParams,
		MVKImplicitBuffer::TessLevel,
	});
	populateResourceUsage(_stageResources[kMVKShaderStageTessCtl], shaderConfig, funcRslts, spv::ExecutionModelTessellationControl);
	_layout->populateBindOperations(_stageResources[kMVKShaderStageTessCtl].bindScript, shaderConfig, spv::ExecutionModelTessellationControl);

	return verifyImplicitBuffers(kMVKShaderStageTessCtl);
}

bool MVKGraphicsPipeline::addTessEvalShaderToPipeline(MTLRenderPipelineDescriptor* plDesc,
													  const VkGraphicsPipelineCreateInfo* pCreateInfo,
													  SPIRVToMSLConversionConfiguration& shaderConfig,
													  SPIRVShaderOutputs& tcOutputs,
													  const VkPipelineShaderStageCreateInfo* pTessEvalSS,
													  VkPipelineCreationFeedback* pTessEvalFB,
													  const VkPipelineShaderStageCreateInfo*& pFragmentSS) {
	const auto& implicit = _stageResources[kMVKShaderStageTessEval].implicitBuffers.ids;
	shaderConfig.options.entryPointStage = spv::ExecutionModelTessellationEvaluation;
	shaderConfig.options.entryPointName = pTessEvalSS->pName;
	addCommonImplicitBuffersToShaderConfig(shaderConfig, implicit);
	shaderConfig.options.mslOptions.shader_input_buffer_index = getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalInputBufferBinding);
	shaderConfig.options.mslOptions.shader_patch_input_buffer_index = getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalPatchInputBufferBinding);
	shaderConfig.options.mslOptions.shader_tess_factor_buffer_index = getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalLevelBufferBinding);
	shaderConfig.options.mslOptions.capture_output_to_buffer = false;
	shaderConfig.options.mslOptions.raw_buffer_tese_input = true;
	shaderConfig.options.mslOptions.disable_rasterization = !_isRasterizing;
	shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo, pTessEvalSS);
	shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo, pTessEvalSS);
	setEmulatedReversedDepthViewportConfig(shaderConfig, implicit, getPhysicalDevice()->shouldEmulateReversedDepthViewport());
	setDepthClipConfig(shaderConfig, implicit, _isRasterizing && canDepthClipAndClampBothBe(_dynamicStateFlags, _staticStateData, false));
	addPrevStageOutputToShaderConversionConfig(shaderConfig, tcOutputs);

	MVKMTLFunction func = getMTLFunction(shaderConfig, pTessEvalSS, pTessEvalFB, _tessEvalModule, "Tessellation evaluation");
	id<MTLFunction> mtlFunc = func.getMTLFunction();
	plDesc.vertexFunction = mtlFunc;	// Yeah, you read that right. Tess. eval functions are a kind of vertex function in Metal.
	if ( !mtlFunc ) { return false; }

	auto& funcRslts = func.shaderConversionResults;
	if (funcRslts.needsXfbBuffer) {
		setConfigurationResult(reportError(VK_ERROR_FEATURE_NOT_PRESENT, "Transform feedback from a tessellation evaluation shader is not supported."));
		return false;
	}
	plDesc.rasterizationEnabled = !funcRslts.isRasterizationDisabled;
	populateResourceUsage(_stageResources[kMVKShaderStageTessEval], shaderConfig, funcRslts, spv::ExecutionModelTessellationEvaluation);
	_stageResources[kMVKShaderStageTessEval].implicitBuffers.needed.set(MVKImplicitBuffer::EmulatedReversedDepthViewport, shaderConfig.options.mslOptions.emulate_reversed_depth_viewport);
	_layout->populateBindOperations(_stageResources[kMVKShaderStageTessEval].bindScript, shaderConfig, spv::ExecutionModelTessellationEvaluation);

	if (funcRslts.isRasterizationDisabled) {
		pFragmentSS = nullptr;
	}

	return verifyImplicitBuffers(kMVKShaderStageTessEval);
}

template<class T>
bool MVKGraphicsPipeline::addFragmentShaderToPipeline(T* plDesc,
													  const VkGraphicsPipelineCreateInfo* pCreateInfo,
													  SPIRVToMSLConversionConfiguration& shaderConfig,
													  SPIRVShaderOutputs& shaderOutputs,
													  const VkPipelineShaderStageCreateInfo* pFragmentSS,
												  VkPipelineCreationFeedback* pFragmentFB,
												  bool forceReplaySource) {
	const auto& implicit = _stageResources[kMVKShaderStageFragment].implicitBuffers.ids;
	auto& mtlFeats = getMetalFeatures();
	if (pFragmentSS) {
		shaderConfig.options.entryPointStage = spv::ExecutionModelFragment;
		addCommonImplicitBuffersToShaderConfig(shaderConfig, implicit);
		shaderConfig.options.mslOptions.view_mask_buffer_index = implicit[MVKImplicitBuffer::ViewRange];
		shaderConfig.options.entryPointName = pFragmentSS->pName;
		shaderConfig.options.mslOptions.capture_output_to_buffer = false;
		shaderConfig.options.mslOptions.fixed_subgroup_size = mvkIsAnyFlagEnabled(pFragmentSS->flags, VK_PIPELINE_SHADER_STAGE_CREATE_ALLOW_VARYING_SUBGROUP_SIZE_BIT) ? 0 : mtlFeats.maxSubgroupSize;
		bool shouldEmulateReversedDepthViewports = getPhysicalDevice()->shouldEmulateReversedDepthViewport();
		setEmulatedReversedDepthViewportConfig(shaderConfig, implicit, false);
		setDepthClipConfig(shaderConfig, implicit, _isRasterizing && canDepthClipAndClampBothBe(_dynamicStateFlags, _staticStateData, true));
		shaderConfig.options.mslOptions.check_discarded_frag_stores = true;
		if (shouldEmulateReversedDepthViewports) {
			// The discard-store helper path uses simd_is_helper_thread(), which is unreliable on the
			// same AMD Metal path that needs reversed-depth viewport emulation.
			shaderConfig.options.mslOptions.check_discarded_frag_stores = false;
		}
		/* Enabling makes dEQP-VK.fragment_shader_interlock.basic.discard.image.pixel_ordered.1xaa.no_sample_shading.1024x1024 and similar tests fail. Requires investigation */
		shaderConfig.options.mslOptions.force_fragment_with_side_effects_execution = false;
		shaderConfig.options.mslOptions.input_attachment_is_ds_attachment = _inputAttachmentIsDSAttachment;
		shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo, pFragmentSS);
		shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo, pFragmentSS);
		if (mtlFeats.needsSampleDrefLodArrayWorkaround) {
			shaderConfig.options.mslOptions.sample_dref_lod_array_as_grad = true;
		}
		shaderConfig.options.mslOptions.for_mesh_pipeline = false;
		shaderConfig.options.uniqueEntryPointName = forceReplaySource && getPhysicalDevice()->isAMDHardware();
		if (_isRasterizing && pCreateInfo->pMultisampleState) {		// Must ignore allowed bad pMultisampleState pointer if rasterization disabled
#if MVK_USE_METAL_PRIVATE_API
			if (!getMVKConfig().useMetalPrivateAPI) {
#endif
				if (pCreateInfo->pMultisampleState->pSampleMask && pCreateInfo->pMultisampleState->pSampleMask[0] != 0xffffffff) {
					shaderConfig.options.mslOptions.additional_fixed_sample_mask = pCreateInfo->pMultisampleState->pSampleMask[0];
				}
#if MVK_USE_METAL_PRIVATE_API
			}
#endif
			shaderConfig.options.mslOptions.force_sample_rate_shading = pCreateInfo->pMultisampleState->sampleShadingEnable && pCreateInfo->pMultisampleState->minSampleShading != 0.0f;
		}
		if (std::any_of(shaderOutputs.begin(), shaderOutputs.end(), [](const SPIRVShaderOutput& output) { return output.builtin == spv::BuiltInLayer; })) {
			shaderConfig.options.mslOptions.arrayed_subpass_input = true;
		}
		addPrevStageOutputToShaderConversionConfig(shaderConfig, shaderOutputs);

		MVKMTLFunction func = getMTLFunction(shaderConfig, pFragmentSS, pFragmentFB, _fragmentModule, "Fragment", forceReplaySource);
		id<MTLFunction> mtlFunc = func.getMTLFunction();
		plDesc.fragmentFunction = mtlFunc;
		if ( !mtlFunc ) { return false; }

		auto& funcRslts = func.shaderConversionResults;
		populateResourceUsage(_stageResources[kMVKShaderStageFragment], shaderConfig, funcRslts, spv::ExecutionModelFragment);
		_layout->populateBindOperations(_stageResources[kMVKShaderStageFragment].bindScript, shaderConfig, spv::ExecutionModelFragment);
	}
	return verifyImplicitBuffers(kMVKShaderStageFragment);
}

template<class T>
bool MVKGraphicsPipeline::addVertexInputToPipeline(T* inputDesc,
												   const VkPipelineVertexInputStateCreateInfo* pVI,
												   const SPIRVToMSLConversionConfiguration& shaderConfig) {
    // Collect extension structures
    VkPipelineVertexInputDivisorStateCreateInfo* pVertexInputDivisorState = nullptr;
	for (const auto* next = (VkBaseInStructure*)pVI->pNext; next; next = next->pNext) {
        switch (next->sType) {
        case VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_DIVISOR_STATE_CREATE_INFO:
            pVertexInputDivisorState = (VkPipelineVertexInputDivisorStateCreateInfo*)next;
            break;
        default:
            break;
        }
    }

	if ( !verifyVertexInputBindings(pVI, shaderConfig) ) { return false; }

    // Vertex buffer bindings
	bool isVtxStrideStatic = !_dynamicStateFlags.has(MVKRenderStateFlag::VertexStride);
	int32_t maxBinding = -1;
	uint32_t vbCnt = pVI->vertexBindingDescriptionCount;
    for (uint32_t i = 0; i < vbCnt; i++) {
        const VkVertexInputBindingDescription* pVKVB = &pVI->pVertexBindingDescriptions[i];
        if (shaderConfig.isVertexBufferUsed(pVKVB->binding)) {

			// Vulkan allows any stride, but Metal requires multiples of 4 on older GPUs.
            if (isVtxStrideStatic && (pVKVB->stride % getMetalFeatures().vertexStrideAlignment) != 0) {
				setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Under Metal, vertex attribute binding strides must be aligned to %llu bytes.", getMetalFeatures().vertexStrideAlignment));
                return false;
            }

			maxBinding = max<int32_t>(pVKVB->binding, maxBinding);
			uint32_t vbIdx = getMetalBufferIndexForVertexAttributeBinding(pVKVB->binding);
			_mtlVertexBuffers.set(vbIdx);
			_vkVertexBuffers.set(pVKVB->binding);
			_vertexStrides[pVKVB->binding] = isVtxStrideStatic ? pVKVB->stride : 0;
			auto vbDesc = inputDesc.layouts[vbIdx];
			if (isVtxStrideStatic && pVKVB->stride == 0) {
				// Stride can't be 0, it will be set later to attributes' maximum offset + size
				// to prevent it from being larger than the underlying buffer permits.
				vbDesc.stride = 0;
				vbDesc.stepFunction = (decltype(vbDesc.stepFunction))MTLStepFunctionConstant;
				vbDesc.stepRate = 0;
			} else {
				vbDesc.stride = isVtxStrideStatic ? pVKVB->stride : MTLBufferLayoutStrideDynamic;
				vbDesc.stepFunction = (decltype(vbDesc.stepFunction))mvkMTLStepFunctionFromVkVertexInputRate(pVKVB->inputRate, isTessellationPipeline());
				vbDesc.stepRate = 1;
			}
        }
    }

    // Vertex buffer divisors (step rates)
    std::unordered_set<uint32_t> zeroDivisorBindings;
    if (pVertexInputDivisorState) {
        uint32_t vbdCnt = pVertexInputDivisorState->vertexBindingDivisorCount;
        for (uint32_t i = 0; i < vbdCnt; i++) {
            const VkVertexInputBindingDivisorDescription* pVKVB = &pVertexInputDivisorState->pVertexBindingDivisors[i];
            if (shaderConfig.isVertexBufferUsed(pVKVB->binding)) {
                uint32_t vbIdx = getMetalBufferIndexForVertexAttributeBinding(pVKVB->binding);
                if ((NSUInteger)inputDesc.layouts[vbIdx].stepFunction == MTLStepFunctionPerInstance ||
					(NSUInteger)inputDesc.layouts[vbIdx].stepFunction == MTLStepFunctionThreadPositionInGridY) {
                    if (pVKVB->divisor == 0) {
                        inputDesc.layouts[vbIdx].stepFunction = (decltype(inputDesc.layouts[vbIdx].stepFunction))MTLStepFunctionConstant;
                        zeroDivisorBindings.insert(pVKVB->binding);
                    }
                    inputDesc.layouts[vbIdx].stepRate = pVKVB->divisor;
                }
            }
        }
    }

	// Vertex attributes
	uint32_t vaCnt = pVI->vertexAttributeDescriptionCount;
	for (uint32_t i = 0; i < vaCnt; i++) {
		const VkVertexInputAttributeDescription* pVKVA = &pVI->pVertexAttributeDescriptions[i];
		if (shaderConfig.isShaderInputLocationUsed(pVKVA->location)) {
			uint32_t vaBinding = pVKVA->binding;
			uint32_t vaOffset = pVKVA->offset;
			auto vaDesc = inputDesc.attributes[pVKVA->location];
			auto mtlFormat = (decltype(vaDesc.format))getPixelFormats()->getMTLVertexFormat(pVKVA->format);

			// Vulkan allows offsets to exceed the buffer stride, but Metal doesn't.
			// If this is the case, fetch a translated artificial buffer binding, using the same MTLBuffer,
			// but that is translated so that the reduced VA offset fits into the binding stride.
			if (isVtxStrideStatic) {
				const VkVertexInputBindingDescription* pVKVB = getVertexBindingDescription(pVI, pVKVA->binding);	// Verified above.
				uint32_t attrSize = getPixelFormats()->getBytesPerBlock(pVKVA->format);
				if (pVKVB->stride == 0) {
					// The step is set to constant, but Metal requires a non-zero stride for any layout an attribute
					// uses (it asserts otherwise, whatever the step function). Use the maximum offset + size of the
					// attributes, so the stride is not larger than the underlying buffer permits.
					uint32_t vbIdx = getMetalBufferIndexForVertexAttributeBinding(pVKVB->binding);
					auto vbDesc = inputDesc.layouts[vbIdx];
					uint32_t strideLowBound = (uint32_t)mvkAlignByteCount(max(vaOffset + attrSize, 1u), getMetalFeatures().vertexStrideAlignment);
					if (vbDesc.stride < strideLowBound) {
						vbDesc.stride = strideLowBound;
						_vertexStrides[pVKVB->binding] = strideLowBound;
					}
				} else if (vaOffset && vaOffset + attrSize > pVKVB->stride) {
					// Move vertex attribute offset into the stride. This vertex attribute may be
					// combined with other vertex attributes into the same translated buffer binding.
					// But if the reduced offset combined with the vertex attribute size still won't
					// fit into the buffer binding stride, force the vertex attribute offset to zero,
					// effectively dedicating this vertex attribute to its own buffer binding.
					uint32_t origOffset = vaOffset;
					vaOffset %= pVKVB->stride;
					if (vaOffset + attrSize > pVKVB->stride) {
						vaOffset = 0;
					}
					vaBinding = getTranslatedVertexBinding(vaBinding, origOffset - vaOffset, maxBinding);
					if (vaBinding >= getMetalFeatures().maxPerStageBufferCount) {
						setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Vertex attribute at location %u (offset %u) is beyond the stride (%u) of binding %u, and no Metal buffer index is left for an offset copy of the binding.",
															 pVKVA->location, origOffset, pVKVB->stride, pVKVB->binding));
						return false;
					}
					if (zeroDivisorBindings.count(pVKVB->binding)) {
						zeroDivisorBindings.insert(vaBinding);
					}
				}
				if (pVKVB->stride && attrSize > pVKVB->stride) {
					/* Metal does not support overlapping loads. Truncate format vector length to prevent an assertion
					 * and hope it's not used by the shader. */
					MTLVertexFormat newFormat = mvkAdjustFormatVectorToSize((MTLVertexFormat)mtlFormat, pVKVB->stride);
					reportError(VK_SUCCESS, "Found attribute with size (%u) larger than it's binding's stride (%u). Changing descriptor format from %s to %s.",
								attrSize, pVKVB->stride, getPixelFormats()->getName((MTLVertexFormat)mtlFormat), getPixelFormats()->getName(newFormat));
					mtlFormat = (decltype(vaDesc.format))newFormat;
				}
			}

			vaDesc.format = mtlFormat;
			vaDesc.bufferIndex = (decltype(vaDesc.bufferIndex))getMetalBufferIndexForVertexAttributeBinding(vaBinding);
			vaDesc.offset = vaOffset;
		}
	}

	// Run through the vertex bindings. Add a new Metal vertex layout for each translated binding,
	// identical to the original layout. The translated binding will index into the same MTLBuffer,
	// but at an offset that is one or more strides away from the original.
	for (uint32_t i = 0; i < vbCnt; i++) {
		const VkVertexInputBindingDescription* pVKVB = &pVI->pVertexBindingDescriptions[i];
		uint32_t vbVACnt = shaderConfig.countShaderInputsAt(pVKVB->binding);
		if (vbVACnt > 0) {
			uint32_t vbIdx = getMetalBufferIndexForVertexAttributeBinding(pVKVB->binding);
			auto vbDesc = inputDesc.layouts[vbIdx];

			uint32_t xldtVACnt = 0;
			for (auto& xltdBind : _translatedVertexBindings) {
				if (xltdBind.binding == pVKVB->binding) {
					uint32_t vbXltdIdx = getMetalBufferIndexForVertexAttributeBinding(xltdBind.translationBinding);
					auto vbXltdDesc = inputDesc.layouts[vbXltdIdx];
					vbXltdDesc.stride = vbDesc.stride;
					vbXltdDesc.stepFunction = vbDesc.stepFunction;
					vbXltdDesc.stepRate = vbDesc.stepRate;
					xldtVACnt += xltdBind.mappedAttributeCount;
					_mtlVertexBuffers.set(vbXltdIdx);
				}
			}

			// If all of the vertex attributes at this vertex buffer binding have been translated, remove it.
			if (xldtVACnt == vbVACnt) { vbDesc.stride = 0; }
		}
	}

    // Collect all bindings with zero divisors. We need to remember them so we can offset
    // the vertex buffers during a draw.
    for (uint32_t binding : zeroDivisorBindings) {
        uint32_t stride = (uint32_t)inputDesc.layouts[getMetalBufferIndexForVertexAttributeBinding(binding)].stride;
        _zeroDivisorVertexBindings.emplace_back(binding, stride);
    }

	return verifyVertexDescriptor(inputDesc, pVI, shaderConfig);
}

// Every vertex attribute the vertex shader uses must come from a described vertex buffer binding (VUID-VkPipelineVertexInputStateCreateInfo-binding-00615).
// Guest drivers and apps still send attributes of undescribed bindings: their Metal buffer layout would have no stride,
// and Metal aborts the process on such a vertex descriptor. Fail the pipeline instead.
bool MVKGraphicsPipeline::verifyVertexInputBindings(const VkPipelineVertexInputStateCreateInfo* pVI,
													 const SPIRVToMSLConversionConfiguration& shaderConfig) {
	for (uint32_t i = 0; i < pVI->vertexAttributeDescriptionCount; i++) {
		const VkVertexInputAttributeDescription* pVKVA = &pVI->pVertexAttributeDescriptions[i];
		if (shaderConfig.isShaderInputLocationUsed(pVKVA->location) && !getVertexBindingDescription(pVI, pVKVA->binding)) {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Vertex attribute at location %u uses vertex buffer binding %u, which has no VkVertexInputBindingDescription (%u binding descriptions).",
												 pVKVA->location, pVKVA->binding, pVI->vertexBindingDescriptionCount));
			return false;
		}
	}
	return true;
}

// Checks the vertex descriptor (or compute stage input descriptor) the way Metal validates it when the pipeline is created,
// where an invalid descriptor is not an error but an assertion that aborts the process: every buffer layout a used
// attribute reads needs a non-zero stride (whatever its step function), and a step rate consistent with its step function.
template<class T>
bool MVKGraphicsPipeline::verifyVertexDescriptor(T* inputDesc,
												  const VkPipelineVertexInputStateCreateInfo* pVI,
												  const SPIRVToMSLConversionConfiguration& shaderConfig) {
	for (uint32_t i = 0; i < pVI->vertexAttributeDescriptionCount; i++) {
		uint32_t location = pVI->pVertexAttributeDescriptions[i].location;
		if ( !shaderConfig.isShaderInputLocationUsed(location) ) { continue; }

		auto vaDesc = inputDesc.attributes[location];
		NSUInteger bufferIndex = vaDesc.bufferIndex;
		if (bufferIndex >= getMetalFeatures().maxPerStageBufferCount) {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Vertex attribute at location %u uses Metal buffer index %lu, beyond the %u Metal buffers.",
												 location, (unsigned long)bufferIndex, getMetalFeatures().maxPerStageBufferCount));
			return false;
		}
		auto vbDesc = inputDesc.layouts[bufferIndex];
		NSUInteger stride = vbDesc.stride;
		NSUInteger stepRate = vbDesc.stepRate;
		NSUInteger stepFunction = (NSUInteger)vbDesc.stepFunction;
		const char* problem = nullptr;
		if (stride == 0) {
			problem = "has no stride";
		} else if (stepFunction == MTLStepFunctionConstant) {
			if (stepRate != 0) { problem = "has a constant step function and a non-zero step rate"; }
		} else if (stepRate == 0) {
			problem = "has a zero step rate";
		} else if constexpr (std::is_same_v<T, MTLVertexDescriptor>) {
			if (stepFunction == MTLVertexStepFunctionPerVertex && stepRate != 1) { problem = "steps per vertex with a step rate other than 1"; }
		}
		if (problem) {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Vertex attribute at location %u uses Metal vertex buffer layout %lu, which %s (stride %lu, step function %lu, step rate %lu).",
												 location, (unsigned long)bufferIndex, problem, (unsigned long)stride, (unsigned long)stepFunction, (unsigned long)stepRate));
			return false;
		}
	}
	return true;
}

// Adjusts step rates for per-instance vertex buffers based on the number of views to be drawn.
void MVKGraphicsPipeline::adjustVertexInputForMultiview(MTLVertexDescriptor* inputDesc, const VkPipelineVertexInputStateCreateInfo* pVI, uint32_t viewCount, uint32_t oldViewCount) {
	uint32_t vbCnt = pVI->vertexBindingDescriptionCount;
	const VkVertexInputBindingDescription* pVKVB = pVI->pVertexBindingDescriptions;
	for (uint32_t i = 0; i < vbCnt; ++i, ++pVKVB) {
		uint32_t vbIdx = getMetalBufferIndexForVertexAttributeBinding(pVKVB->binding);
		if (inputDesc.layouts[vbIdx].stepFunction == MTLVertexStepFunctionPerInstance) {
			inputDesc.layouts[vbIdx].stepRate = inputDesc.layouts[vbIdx].stepRate / oldViewCount * viewCount;
			for (auto& xltdBind : _translatedVertexBindings) {
				if (xltdBind.binding == pVKVB->binding) {
					uint32_t vbXltdIdx = getMetalBufferIndexForVertexAttributeBinding(xltdBind.translationBinding);
					inputDesc.layouts[vbXltdIdx].stepRate = inputDesc.layouts[vbXltdIdx].stepRate / oldViewCount * viewCount;
				}
			}
		}
	}
}

// Returns a translated binding for the existing binding and translation offset, creating it if needed.
uint32_t MVKGraphicsPipeline::getTranslatedVertexBinding(uint32_t binding, uint32_t translationOffset, uint32_t maxBinding) {
	// See if a translated binding already exists (for example if more than one VA needs the same translation).
	for (auto& xltdBind : _translatedVertexBindings) {
		if (xltdBind.binding == binding && xltdBind.translationOffset == translationOffset) {
			xltdBind.mappedAttributeCount++;
			return xltdBind.translationBinding;
		}
	}

	// Get next available binding point and add a translation binding description for it
	uint16_t xltdBindPt = (uint16_t)(maxBinding + _translatedVertexBindings.size() + 1);
	_translatedVertexBindings.push_back( {.binding = (uint16_t)binding, .translationBinding = xltdBindPt, .translationOffset = translationOffset, .mappedAttributeCount = 1u} );

	return xltdBindPt;
}

void MVKGraphicsPipeline::addTessellationToPipeline(MTLRenderPipelineDescriptor* plDesc,
													const SPIRVTessReflectionData& reflectData,
													const VkPipelineTessellationStateCreateInfo* pTS) {

	VkPipelineTessellationDomainOriginStateCreateInfo* pTessDomainOriginState = nullptr;
	if (pTS && reflectData.patchKind == spv::ExecutionModeTriangles) {
		for (const auto* next = (VkBaseInStructure*)pTS->pNext; next; next = next->pNext) {
			switch (next->sType) {
			case VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_DOMAIN_ORIGIN_STATE_CREATE_INFO:
				pTessDomainOriginState = (VkPipelineTessellationDomainOriginStateCreateInfo*)next;
				break;
			default:
				break;
			}
		}
	}

	plDesc.maxTessellationFactor = getDeviceProperties().limits.maxTessellationGenerationLevel;
	plDesc.tessellationFactorFormat = MTLTessellationFactorFormatHalf;  // FIXME Use Float when it becomes available
	plDesc.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionPerPatch;
	plDesc.tessellationOutputWindingOrder = mvkMTLWindingFromSpvExecutionMode(reflectData.windingOrder);
	if (pTessDomainOriginState && pTessDomainOriginState->domainOrigin == VK_TESSELLATION_DOMAIN_ORIGIN_LOWER_LEFT) {
		// Reverse the winding order for triangle patches with lower-left domains.
		if (plDesc.tessellationOutputWindingOrder == MTLWindingClockwise) {
			plDesc.tessellationOutputWindingOrder = MTLWindingCounterClockwise;
		} else {
			plDesc.tessellationOutputWindingOrder = MTLWindingClockwise;
		}
	}
	plDesc.tessellationPartitionMode = mvkMTLTessellationPartitionModeFromSpvExecutionMode(reflectData.partitionMode);
}

template<typename T>
void MVKGraphicsPipeline::addFragmentOutputToPipeline(T* plDesc, const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	// Topology - only set for MTLRenderPipelineDescriptor, not MTLMeshRenderPipelineDescriptor
	if constexpr (std::is_same_v<T, MTLRenderPipelineDescriptor>) {
		if (pCreateInfo->pInputAssemblyState) {
			plDesc.inputPrimitiveTopology = getPrimitiveTopologyClass();
		}
	}

	const VkPipelineRenderingCreateInfo* pRendInfo = getRenderingCreateInfo(pCreateInfo);

	// Color attachments - must ignore bad pColorBlendState pointer if rasterization is disabled or subpass has no color attachments
    if (_isRasterizingColor && pCreateInfo->pColorBlendState) {
        for (uint32_t caIdx = 0; caIdx < pCreateInfo->pColorBlendState->attachmentCount; caIdx++) {
            const VkPipelineColorBlendAttachmentState* pCA = &pCreateInfo->pColorBlendState->pAttachments[caIdx];

			uint32_t caLoc = _colorAttachmentLocations[caIdx];
			if (caLoc == VK_ATTACHMENT_UNUSED) { continue; }

			MTLPixelFormat mtlPixFmt = getPixelFormats()->getMTLPixelFormat(pRendInfo->pColorAttachmentFormats[caIdx]);
			MTLRenderPipelineColorAttachmentDescriptor* colorDesc = plDesc.colorAttachments[caLoc];
            colorDesc.pixelFormat = mtlPixFmt;

			if (colorDesc.pixelFormat == MTLPixelFormatRGB9E5Float) {
                // Metal doesn't allow disabling individual channels for a RGB9E5 render target.
                // Either all must be disabled or none must be disabled.
                // TODO: Use framebuffer fetch to support this anyway. I don't understand why Apple doesn't
                // support it, given that the only GPUs that support this in Metal also support framebuffer fetch.
                colorDesc.writeMask = pCA->colorWriteMask ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
            } else {
                colorDesc.writeMask = mvkMTLColorWriteMaskFromVkChannelFlags(pCA->colorWriteMask);
            }
            // Don't set the blend state if we're not using this attachment.
            // The pixel format will be MTLPixelFormatInvalid in that case, and
            // Metal asserts if we turn on blending with that pixel format.
            if (mtlPixFmt) {
                colorDesc.blendingEnabled = pCA->blendEnable;
                colorDesc.rgbBlendOperation = mvkMTLBlendOperationFromVkBlendOp(pCA->colorBlendOp);
                colorDesc.sourceRGBBlendFactor = mvkMTLBlendFactorFromVkBlendFactor(pCA->srcColorBlendFactor);
                colorDesc.destinationRGBBlendFactor = mvkMTLBlendFactorFromVkBlendFactor(pCA->dstColorBlendFactor);
                colorDesc.alphaBlendOperation = mvkMTLBlendOperationFromVkBlendOp(pCA->alphaBlendOp);
                colorDesc.sourceAlphaBlendFactor = mvkMTLBlendFactorFromVkBlendFactor(pCA->srcAlphaBlendFactor);
                colorDesc.destinationAlphaBlendFactor = mvkMTLBlendFactorFromVkBlendFactor(pCA->dstAlphaBlendFactor);
#if MVK_USE_METAL_PRIVATE_API
				if (getMVKConfig().useMetalPrivateAPI) {
					plDesc.logicOperationEnabledMVK = pCreateInfo->pColorBlendState->logicOpEnable;
					plDesc.logicOperationMVK = mvkMTLLogicOperationFromVkLogicOp(pCreateInfo->pColorBlendState->logicOp);
				}
#endif
            }
        }
    }

    // Depth & stencil attachment formats
	MVKPixelFormats* pixFmts = getPixelFormats();
	MTLPixelFormat mtlDepthPixFmt = pixFmts->getMTLPixelFormat(pRendInfo->depthAttachmentFormat);
	MTLPixelFormat mtlStencilPixFmt = pixFmts->getMTLPixelFormat(pRendInfo->stencilAttachmentFormat);

	if (pixFmts->isDepthFormat(mtlDepthPixFmt)) {
		plDesc.depthAttachmentPixelFormat = mtlDepthPixFmt;
	} else if (pixFmts->isDepthFormat(mtlStencilPixFmt)) {
		plDesc.depthAttachmentPixelFormat = mtlStencilPixFmt;
	}

	if (pixFmts->isStencilFormat(mtlStencilPixFmt)) {
		plDesc.stencilAttachmentPixelFormat = mtlStencilPixFmt;
	} else if (pixFmts->isStencilFormat(mtlDepthPixFmt)) {
		plDesc.stencilAttachmentPixelFormat = mtlDepthPixFmt;
	}

    // Multisampling - must ignore allowed bad pMultisampleState pointer if rasterization disabled
    if (_isRasterizing && pCreateInfo->pMultisampleState) {
		// Metal fails the pipeline with an unsupported rasterSampleCount ("rasterSampleCount (8) is not supported
		// by device" on Apple GPUs, which support 1, 2 and 4 samples), and apps and guest drivers request counts
		// the device does not report: use the largest supported count instead.
		VkSampleCountFlagBits sampleCount = pCreateInfo->pMultisampleState->rasterizationSamples;
		VkSampleCountFlagBits supportedSampleCount = getPhysicalDevice()->getSupportedSampleCount(sampleCount);
		if (supportedSampleCount != sampleCount) {
			reportWarning(VK_ERROR_FEATURE_NOT_PRESENT, "vkCreateGraphicsPipelines(): rasterizationSamples %u is not supported by this device, using %u.",
						  (uint32_t)sampleCount, (uint32_t)supportedSampleCount);
		}
        plDesc.rasterSampleCount = mvkSampleCountFromVkSampleCountFlagBits(supportedSampleCount);
#if MVK_USE_METAL_PRIVATE_API
        if (getMVKConfig().useMetalPrivateAPI && pCreateInfo->pMultisampleState->pSampleMask) {
            plDesc.sampleMaskMVK = pCreateInfo->pMultisampleState->pSampleMask[0];
        }
#endif
        plDesc.alphaToCoverageEnabled = pCreateInfo->pMultisampleState->alphaToCoverageEnable;
        plDesc.alphaToOneEnabled = pCreateInfo->pMultisampleState->alphaToOneEnable;

		// If the pipeline uses a specific render subpass, set its default sample count
		if (pCreateInfo->renderPass) {
			((MVKRenderPass*)pCreateInfo->renderPass)->getSubpass(pCreateInfo->subpass)->setDefaultSampleCount(supportedSampleCount);
		}
    }
}

// Initializes the shader conversion config used to prepare the MSL library used by this pipeline.
void MVKGraphicsPipeline::initShaderConversionConfig(SPIRVToMSLConversionConfiguration& shaderConfig,
													 const VkGraphicsPipelineCreateInfo* pCreateInfo,
													 const SPIRVTessReflectionData& reflectData) {

	// Tessellation - must ignore allowed bad pTessellationState pointer if not tess pipeline
    VkPipelineTessellationDomainOriginStateCreateInfo* pTessDomainOriginState = nullptr;
    if (isTessellationPipeline() && pCreateInfo->pTessellationState) {
		for (const auto* next = (VkBaseInStructure*)pCreateInfo->pTessellationState->pNext; next; next = next->pNext) {
            switch (next->sType) {
            case VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_DOMAIN_ORIGIN_STATE_CREATE_INFO:
                pTessDomainOriginState = (VkPipelineTessellationDomainOriginStateCreateInfo*)next;
                break;
            default:
                break;
            }
        }
    }

	auto& mtlFeats = getMetalFeatures();
	auto& mvkCfg = getMVKConfig();
    shaderConfig.options.mslOptions.msl_version = mtlFeats.mslVersion;
    shaderConfig.options.mslOptions.texel_buffer_texture_width = mtlFeats.maxTextureDimension;
    shaderConfig.options.mslOptions.r32ui_linear_texture_alignment = (uint32_t)_device->getVkFormatTexelBufferAlignment(VK_FORMAT_R32_UINT, this);
	shaderConfig.options.mslOptions.texture_buffer_native = true;
	shaderConfig.options.mslOptions.bitwise_not_causes_ice = mtlFeats.bitwiseNotCausesICE;
	// Texel buffer views at offsets Metal cannot use start at the aligned offset below; the shader adds the rest.
	shaderConfig.options.mslOptions.add_texture_buffer_offsets = mtlFeats.emulatedTexelBufferAlignment;

	bool useMetalArgBuff = isUsingMetalArgumentBuffers();
	shaderConfig.options.mslOptions.argument_buffers = useMetalArgBuff;
	shaderConfig.options.mslOptions.force_active_argument_buffer_resources = false;
	shaderConfig.options.mslOptions.pad_argument_buffer_resources = useMetalArgBuff;
	shaderConfig.options.mslOptions.argument_buffers_tier = (SPIRV_CROSS_NAMESPACE::CompilerMSL::Options::ArgumentBuffersTier)getMetalFeatures().argumentBuffersTier;
	shaderConfig.options.mslOptions.agx_manual_cube_grad_fixup = mtlFeats.needsCubeGradWorkaround;

	MVKPipelineLayout* layout = (MVKPipelineLayout*)pCreateInfo->layout;
	layout->populateShaderConversionConfig(shaderConfig);

	// Set implicit buffer indices
	// FIXME: Many of these are optional. We shouldn't set the ones that aren't
	// present--or at least, we should move the ones that are down to avoid running over
	// the limit of available buffers. But we can't know that until we compile the shaders.
	initReservedVertexAttributeBufferCount(pCreateInfo);
	for (uint32_t i = 0; i < std::size(_stageResources); i++) {
		MVKShaderStage stage = (MVKShaderStage)i;
		_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::TextureOffset]  = getImplicitBufferIndex(stage, 0);
		_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::DynamicOffset]  = getImplicitBufferIndex(stage, 1);
		_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::BufferSize]     = getImplicitBufferIndex(stage, 2);
		_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::Output]         = getImplicitBufferIndex(stage, 4);
		_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::EmulatedReversedDepthViewport] = getImplicitBufferIndex(stage, 7);
		_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::DepthClip]       = getImplicitBufferIndex(stage, 8);
		uint32_t extra = getImplicitBufferIndex(stage, 3);
		switch (stage) {
			case kMVKShaderStageVertex:
				// Since we currently can't use multiview with tessellation or geometry shaders,
				// to conserve the number of buffer bindings, use the same bindings for the
				// view range buffer as for the tessellation index buffer.
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::ViewRange] = extra;
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::Index]     = extra;
				break;
			case kMVKShaderStageFragment:
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::ViewRange] = extra;
				break;
			case kMVKShaderStageTessCtl:
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::PatchOutput]    = getImplicitBufferIndex(stage, 5);
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::TessLevel]      = getImplicitBufferIndex(stage, 6);
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::IndirectParams] = extra;
				break;
			case kMVKShaderStageTessEval:
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::IndirectParams] = extra;
				break;
			case kMVKShaderStageGeometry:
				_stageResources[stage].implicitBuffers.ids[MVKImplicitBuffer::ViewRange] = extra;
				break;
			default:
				break;
		}
	}
	// The vertex shader of a geometry-shader pipeline is the object stage of a mesh pipeline: it uses no
	// output, view range, index, reversed-depth or depth-clip buffers, but the DrawInfo buffer.
	// Keep the free indices for the buffers it can use.
	if (isGeometryPipeline()) {
		auto& vtxIds = _stageResources[kMVKShaderStageVertex].implicitBuffers.ids;
		vtxIds[MVKImplicitBuffer::Output] = kMVKUnassignedImplicitBufferIndex;
		vtxIds[MVKImplicitBuffer::ViewRange] = kMVKUnassignedImplicitBufferIndex;
		vtxIds[MVKImplicitBuffer::Index] = kMVKUnassignedImplicitBufferIndex;
		vtxIds[MVKImplicitBuffer::EmulatedReversedDepthViewport] = kMVKUnassignedImplicitBufferIndex;
		vtxIds[MVKImplicitBuffer::DepthClip] = kMVKUnassignedImplicitBufferIndex;
		_meshDrawInfoBufferIndex = getImplicitBufferIndex(kMVKShaderStageVertex, 3);
	}

	const VkPipelineRenderingCreateInfo* pRendInfo = getRenderingCreateInfo(pCreateInfo);
	MVKPixelFormats* pixFmts = getPixelFormats();

	// Disable any unused color attachments, because Metal validation can complain if the
	// fragment shader outputs a color value without a corresponding color attachment.
	// However, if alpha-to-coverage is enabled, we must enable the fragment shader first color output,
	// even without a color attachment present or in use, so that coverage can be calculated.
	// Must ignore allowed bad pMultisampleState pointer if rasterization disabled
	bool hasA2C = _isRasterizing && pCreateInfo->pMultisampleState && pCreateInfo->pMultisampleState->alphaToCoverageEnable;
	shaderConfig.options.mslOptions.enable_frag_output_mask = hasA2C ? 1 : 0;
	if (_isRasterizingColor && pCreateInfo->pColorBlendState) {
		for (uint32_t caIdx = 0; caIdx < pCreateInfo->pColorBlendState->attachmentCount; caIdx++) {
			if (mvkIsColorAttachmentUsed(pRendInfo, caIdx)) {
				mvkEnableFlags(shaderConfig.options.mslOptions.enable_frag_output_mask, 1 << caIdx);
			}
		}
	}

	// Metal fails a render pipeline whose fragment output has another numeric type than its color attachment
	// ("output of type uint4 is not compatible with a MTLPixelFormatR32Sint color attachment", STEAMAC-2C), while
	// Vulkan only leaves the values written undefined. Tell SPIRV-Cross the attachments' numeric types by location,
	// so that it declares such outputs with the attachment's type and bit casts the values to it.
	if (_isRasterizingColor) {
		auto& mslOpts = shaderConfig.options.mslOptions;
		for (uint32_t caIdx = 0; caIdx < pRendInfo->colorAttachmentCount; caIdx++) {
			uint32_t caLoc = _colorAttachmentLocations[caIdx];
			if (caLoc >= 32) { continue; }	// VK_ATTACHMENT_UNUSED
			switch (pixFmts->getFormatType(pRendInfo->pColorAttachmentFormats[caIdx])) {
				case kMVKFormatColorHalf:
				case kMVKFormatColorFloat:
					mvkEnableFlags(mslOpts.frag_output_float_mask, 1u << caLoc);
					break;
				case kMVKFormatColorInt8:
				case kMVKFormatColorInt16:
				case kMVKFormatColorInt32:
					mvkEnableFlags(mslOpts.frag_output_sint_mask, 1u << caLoc);
					break;
				case kMVKFormatColorUInt8:
				case kMVKFormatColorUInt16:
				case kMVKFormatColorUInt32:
					mvkEnableFlags(mslOpts.frag_output_uint_mask, 1u << caLoc);
					break;
				default:
					break;
			}
		}
	}

	shaderConfig.options.mslOptions.ios_support_base_vertex_instance = mtlFeats.baseVertexInstanceDrawing;
	shaderConfig.options.mslOptions.texture_1D_as_2D = mvkCfg.texture1DAs2D;
	shaderConfig.options.mslOptions.null_descriptor = getEnabledRobustness2Features().nullDescriptor;
	shaderConfig.options.mslOptions.typed_root_pointers = getPhysicalDevice()->isAMDHardware();
	shaderConfig.options.mslOptions.coherent_buffer_atomics = getPhysicalDevice()->isAMDHardware() && getenv("MVK_AMD_COHERENT_ATOMICS") && !strcmp(getenv("MVK_AMD_COHERENT_ATOMICS"), "1");
    if (getenv("MVK_AMD_REFERENCE_NULL") && std::string(getenv("MVK_AMD_REFERENCE_NULL")) == "1") { shaderConfig.options.mslOptions.null_descriptor = true; }
	shaderConfig.options.mslOptions.enable_point_size_builtin = isRenderingPoints() || reflectData.pointMode;
	shaderConfig.options.mslOptions.enable_point_size_default = shaderConfig.options.mslOptions.enable_point_size_builtin;
	shaderConfig.options.mslOptions.default_point_size = 1.0f; // See VK_KHR_maintenance5
	shaderConfig.options.mslOptions.enable_frag_depth_builtin = pixFmts->isDepthFormat(pixFmts->getMTLPixelFormat(pRendInfo->depthAttachmentFormat));
	shaderConfig.options.mslOptions.enable_frag_stencil_ref_builtin = pixFmts->isStencilFormat(pixFmts->getMTLPixelFormat(pRendInfo->stencilAttachmentFormat));
    shaderConfig.options.shouldFlipVertexY = mvkCfg.shaderConversionFlipVertexY;
    shaderConfig.options.shouldFixupClipSpace = isDepthClipNegativeOneToOne(pCreateInfo);
    shaderConfig.options.mslOptions.tess_domain_origin_lower_left = pTessDomainOriginState && pTessDomainOriginState->domainOrigin == VK_TESSELLATION_DOMAIN_ORIGIN_LOWER_LEFT;
    shaderConfig.options.mslOptions.multiview = mvkIsMultiview(pRendInfo->viewMask);
    shaderConfig.options.mslOptions.multiview_layered_rendering = getPhysicalDevice()->canUseInstancingForMultiview();
    shaderConfig.options.mslOptions.view_index_from_device_index = mvkAreAllFlagsEnabled(_flags, VK_PIPELINE_CREATE_2_VIEW_INDEX_FROM_DEVICE_INDEX_BIT);
	shaderConfig.options.mslOptions.replace_recursive_inputs = mvkOSVersionIsAtLeast(14.0, 17.0, 1.0);
#if MVK_MACOS
    shaderConfig.options.mslOptions.emulate_subgroups = !mtlFeats.simdPermute;
#else
    shaderConfig.options.mslOptions.emulate_subgroups = !mtlFeats.quadPermute;
    shaderConfig.options.mslOptions.ios_use_simdgroup_functions = !!mtlFeats.simdPermute;
#endif

    shaderConfig.options.tessPatchKind = reflectData.patchKind;
    shaderConfig.options.numTessControlPoints = reflectData.numControlPoints;
}

// Implicit buffers take the free Metal buffer indices from the top down, skipping the indices of the
// vertex buffers (Vulkan binding b is at index maxPerStageBufferCount - 1 - b, so sparse or high binding
// numbers leave free indices below them) and the reserved buffers of the stage, and staying above the
// descriptor buffers. Returns kMVKUnassignedImplicitBufferIndex if there is no free index; the stage
// then fails with a clear error if it needs that buffer (verifyImplicitBuffers()).
uint32_t MVKGraphicsPipeline::getImplicitBufferIndex(MVKShaderStage stage, uint32_t bufferIndexOffset) {
	int32_t maxIdx = (int32_t)getMetalFeatures().maxPerStageBufferCount - 1;
	uint32_t remaining = bufferIndexOffset;
	for (int32_t idx = maxIdx; idx >= (int32_t)_descriptorBufferCounts.stages[stage]; idx--) {
		if (mvkIsAnyFlagEnabled(_occupiedVertexBufferIndices[stage], 1u << idx)) { continue; }
		if (remaining == 0) { return (uint32_t)idx; }
		remaining--;
	}
	return kMVKUnassignedImplicitBufferIndex;
}

// Set the number of vertex attribute buffers consumed by this pipeline at each stage.
// Any implicit buffers needed by this pipeline will be assigned indexes below the range
// defined by this count below the max number of Metal buffer bindings per stage.
// Must be called before any calls to getImplicitBufferIndex().
void MVKGraphicsPipeline::initReservedVertexAttributeBufferCount(const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	int32_t maxBinding = -1;
	uint32_t xltdBuffCnt = 0;

	const VkPipelineVertexInputStateCreateInfo* pVI = pCreateInfo->pVertexInputState;
	uint32_t vaCnt = pVI->vertexAttributeDescriptionCount;
	uint32_t vbCnt = pVI->vertexBindingDescriptionCount;

	// Determine the highest binding number used by the vertex buffers
	for (uint32_t vbIdx = 0; vbIdx < vbCnt; vbIdx++) {
		const VkVertexInputBindingDescription* pVKVB = &pVI->pVertexBindingDescriptions[vbIdx];
		maxBinding = max<int32_t>(pVKVB->binding, maxBinding);

		// Iterate through the vertex attributes and determine if any need a synthetic binding buffer to
		// accommodate offsets that are outside the stride, which Vulkan supports, but Metal does not.
		// This value will be worst case, as some synthetic buffers may end up being shared.
		for (uint32_t vaIdx = 0; vaIdx < vaCnt; vaIdx++) {
			const VkVertexInputAttributeDescription* pVKVA = &pVI->pVertexAttributeDescriptions[vaIdx];

			if (pVKVA->binding == pVKVB->binding) {
				uint32_t attrSize = getPixelFormats()->getBytesPerBlock(pVKVA->format);
				uint32_t vaOffset = pVKVA->offset;
				if (vaOffset && vaOffset + attrSize > pVKVB->stride) {
					xltdBuffCnt++;
				}
			}
		}
	}

	// The number of reserved bindings we need for the vertex stage is determined from the largest vertex
	// attribute binding number, plus any synthetic buffer bindings created to support translated offsets.
	mvkClear<uint32_t>(_reservedVertexAttributeBufferCount.stages, kMVKShaderStageCount);
	_reservedVertexAttributeBufferCount.stages[kMVKShaderStageVertex] = (maxBinding + 1) + xltdBuffCnt;
	_reservedVertexAttributeBufferCount.stages[kMVKShaderStageTessCtl] = kMVKTessCtlNumReservedBuffers;
	_reservedVertexAttributeBufferCount.stages[kMVKShaderStageTessEval] = kMVKTessEvalNumReservedBuffers;

	// Metal buffer indices taken by vertex buffers (declared bindings, and the synthetic bindings
	// after the highest one) and by the reserved buffers of the tessellation stages.
	mvkClear<uint32_t>(_occupiedVertexBufferIndices, kMVKShaderStageCount);
	auto occupy = [&](MVKShaderStage stage, uint32_t binding) {
		uint32_t idx = getMetalBufferIndexForVertexAttributeBinding(binding);
		if (idx < 32) { _occupiedVertexBufferIndices[stage] |= 1u << idx; }
	};
	for (uint32_t vbIdx = 0; vbIdx < vbCnt; vbIdx++) {
		occupy(kMVKShaderStageVertex, pVI->pVertexBindingDescriptions[vbIdx].binding);
	}
	for (uint32_t i = 0; i < xltdBuffCnt; i++) { occupy(kMVKShaderStageVertex, maxBinding + 1 + i); }
	for (uint32_t i = 0; i < kMVKTessCtlNumReservedBuffers; i++) { occupy(kMVKShaderStageTessCtl, i); }
	for (uint32_t i = 0; i < kMVKTessEvalNumReservedBuffers; i++) { occupy(kMVKShaderStageTessEval, i); }
}

static MVK_spirv_cross::MSLShaderVariableFormat toMslShaderFormat(MVKFormatType type) {
    switch (type) {
        case kMVKFormatColorInt8: return MSL_SHADER_VARIABLE_FORMAT_INT8;
        case kMVKFormatColorUInt8: return MSL_SHADER_VARIABLE_FORMAT_UINT8;
        case kMVKFormatColorInt16: return MSL_SHADER_VARIABLE_FORMAT_INT16;
        case kMVKFormatColorUInt16: return MSL_SHADER_VARIABLE_FORMAT_UINT16;
        case kMVKFormatColorInt32: return MSL_SHADER_VARIABLE_FORMAT_INT32;
        case kMVKFormatColorUInt32: return MSL_SHADER_VARIABLE_FORMAT_UINT32;
        case kMVKFormatColorFloat: return MSL_SHADER_VARIABLE_FORMAT_FLOAT;
        case kMVKFormatColorHalf: return MSL_SHADER_VARIABLE_FORMAT_HALF;
        default: return MSL_SHADER_VARIABLE_FORMAT_OTHER;
    }
}

// Initializes the vertex attributes in a shader conversion configuration.
void MVKGraphicsPipeline::addVertexInputToShaderConversionConfig(SPIRVToMSLConversionConfiguration& shaderConfig,
                                                                 const VkGraphicsPipelineCreateInfo* pCreateInfo) {
    // Set the shader conversion config vertex attribute information
    shaderConfig.shaderInputs.clear();
    uint32_t vaCnt = pCreateInfo->pVertexInputState->vertexAttributeDescriptionCount;
    for (uint32_t vaIdx = 0; vaIdx < vaCnt; vaIdx++) {
        const VkVertexInputAttributeDescription* pVKVA = &pCreateInfo->pVertexInputState->pVertexAttributeDescriptions[vaIdx];
        // An attribute whose binding has no description is invalid; addVertexInputToPipeline() rejects the pipeline.
        const VkVertexInputBindingDescription* pVKVB = getVertexBindingDescription(pCreateInfo->pVertexInputState, pVKVA->binding);

        // Set binding and offset from Vulkan vertex attribute
        mvk::MSLShaderInput si;
        si.shaderVar.location = pVKVA->location;
        si.shaderVar.offset = pVKVA->offset;
        si.shaderVar.stride = pVKVB ? pVKVB->stride : 0;

        if (shaderConfig.options.mslOptions.for_mesh_pipeline) {
            si.shaderVar.vecsize = vertexFormatInfo[pVKVA->format].num_elements;
            si.shaderVar.normalized = vertexFormatInfo[pVKVA->format].normalized;
            si.shaderVar.binding = getDevice()->getMetalBufferIndexForVertexAttributeBinding(pVKVA->binding);
        }

        si.binding = pVKVA->binding;

        // Metal can't do signedness conversions on vertex buffers (rdar://45922847). If the shader
        // and the vertex attribute have mismatched signedness, we have to fix the shader
        // to match the vertex attribute. So tell SPIRV-Cross if we're expecting an unsigned format.
        // Only do this if the attribute could be reasonably expected to fit in the shader's
        // declared type. Programs that try to invoke undefined behavior are on their own.
		auto mvkFormat = getPixelFormats()->getFormatType(pVKVA->format);
        si.shaderVar.format = toMslShaderFormat(mvkFormat);

        if (si.shaderVar.format == MSL_VERTEX_FORMAT_OTHER) {
			switch (getPixelFormats()->getFormatType(pVKVA->format) ) {
			case kMVKFormatColorUInt8:
				si.shaderVar.format = MSL_SHADER_VARIABLE_FORMAT_UINT8;
				break;

			case kMVKFormatColorUInt16:
				si.shaderVar.format = MSL_SHADER_VARIABLE_FORMAT_UINT16;
				break;

			case kMVKFormatDepthStencil:
				// Only some depth/stencil formats have unsigned components.
				switch (pVKVA->format) {
				case VK_FORMAT_S8_UINT:
				case VK_FORMAT_D16_UNORM_S8_UINT:
				case VK_FORMAT_D24_UNORM_S8_UINT:
				case VK_FORMAT_D32_SFLOAT_S8_UINT:
					si.shaderVar.format = MSL_SHADER_VARIABLE_FORMAT_UINT8;
					break;

				default:
					break;
				}
				break;

			default:
				break;
			}
		}

		// The mesh (geometry-shader) object stage reads the attribute's memory itself.
		if (shaderConfig.options.mslOptions.for_mesh_pipeline) {
			auto memFormat = mvkMSLMeshVertexMemoryFormat(getPixelFormats()->getMTLVertexFormat(pVKVA->format));
			if (memFormat != MSL_SHADER_VARIABLE_FORMAT_OTHER) { si.shaderVar.format = memFormat; }
		}

        shaderConfig.shaderInputs.push_back(si);
    }
}

// Initializes the shader outputs in a shader conversion config from the next stage input.
void MVKGraphicsPipeline::addNextStageInputToShaderConversionConfig(SPIRVToMSLConversionConfiguration& shaderConfig,
                                                                    SPIRVShaderInputs& shaderInputs) {
    shaderConfig.shaderOutputs.clear();

	mvk::MSLShaderInterfaceVariable so;
	auto& sosv = so.shaderVar;
	for (auto& si : shaderInputs) {
		if ( !si.isUsed ) { continue; }

        sosv.location = si.location;
		sosv.component = si.component;
        sosv.builtin = si.builtin;
        sosv.vecsize = si.vecWidth;
		sosv.rate = si.perPatch ? MSL_SHADER_VARIABLE_RATE_PER_PATCH : MSL_SHADER_VARIABLE_RATE_PER_VERTEX;
        sosv.format = toMslShaderFormat(getPixelFormats()->getFormatType(mvkFormatFromOutput(si)));

        shaderConfig.shaderOutputs.push_back(so);
    }
}

// Initializes the shader inputs in a shader conversion config from the previous stage output.
void MVKGraphicsPipeline::addPrevStageOutputToShaderConversionConfig(SPIRVToMSLConversionConfiguration& shaderConfig,
                                                                     SPIRVShaderOutputs& shaderOutputs) {
    shaderConfig.shaderInputs.clear();

	mvk::MSLShaderInput si;
	auto& sisv = si.shaderVar;
	for (auto& so : shaderOutputs) {
		if ( !so.isUsed ) { continue; }

        sisv.location = so.location;
		sisv.component = so.component;
        sisv.builtin = so.builtin;
        sisv.vecsize = so.vecWidth;
		sisv.rate = so.perPatch ? MSL_SHADER_VARIABLE_RATE_PER_PATCH : MSL_SHADER_VARIABLE_RATE_PER_VERTEX;
        sisv.format = toMslShaderFormat(getPixelFormats()->getFormatType(mvkFormatFromOutput(so)));

        shaderConfig.shaderInputs.push_back(si);
    }
}

// We render points if either the static topology or static polygon-mode dictate it.
// The topology class must be the same between static and dynamic, so point topology
// in static also implies point topology in dynamic.
// Metal does not support VK_POLYGON_MODE_POINT, but it can be emulated if the polygon mode
// is static, which allows both the topology and the pipeline topology-class to be set to points.
// This cannot be accomplished if the dynamic polygon mode has been changed to points when the
// pipeline is expecting triangles or lines, because the pipeline topology class will be incorrect.
bool MVKGraphicsPipeline::isRenderingPoints() {
	return getPrimitiveTopologyClass() == MTLPrimitiveTopologyClassPoint || getPrimitiveTopologyClass() == MTLPrimitiveTopologyClassUnspecified;
}

// We disable rasterization if either static rasterizerDiscard is enabled or the static cull mode dictates it.
bool MVKGraphicsPipeline::isRasterizationDisabled(const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	if (!_dynamicStateFlags.has(MVKRenderStateFlag::RasterizerDiscardEnable) && pCreateInfo->pRasterizationState->rasterizerDiscardEnable)
		return true;
	if (!_dynamicStateFlags.has(MVKRenderStateFlag::CullMode) && pCreateInfo->pRasterizationState->cullMode == VK_CULL_MODE_FRONT_AND_BACK)
		return pCreateInfo->pInputAssemblyState && mvkMTLPrimitiveTopologyClassFromVkPrimitiveTopology(pCreateInfo->pInputAssemblyState->topology) == MTLPrimitiveTopologyClassTriangle;
	return false;
}

// We ask SPIRV-Cross to fix up the clip space from [-w, w] to [0, w] if a
// VkPipelineViewportDepthClipControlCreateInfoEXT is provided with negativeOneToOne enabled.
// Must ignore allowed bad pViewportState pointer if rasterization is disabled.
bool MVKGraphicsPipeline::isDepthClipNegativeOneToOne(const VkGraphicsPipelineCreateInfo* pCreateInfo) {
	if (_isRasterizing && pCreateInfo->pViewportState ) {
		for (const auto* next = (VkBaseInStructure*)pCreateInfo->pViewportState->pNext; next; next = next->pNext) {
			switch (next->sType) {
				case VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_DEPTH_CLIP_CONTROL_CREATE_INFO_EXT: return ((VkPipelineViewportDepthClipControlCreateInfoEXT*)next)->negativeOneToOne;
				default: break;
			}
		}
	}
	return false;
}

MVKMTLFunction MVKGraphicsPipeline::getMTLFunction(SPIRVToMSLConversionConfiguration& shaderConfig,
												   const VkPipelineShaderStageCreateInfo* pShaderStage,
												   VkPipelineCreationFeedback* pStageFB,
												   MVKShaderModule* pShaderModule,
												   const char* pStageName,
												   bool forceReplaySource) {
	MVKMTLFunction func = pShaderModule->getMTLFunction(&shaderConfig,
													    pShaderStage->pSpecializationInfo,
													    this,
													    pStageFB,
													    forceReplaySource);
	if ( !func.getMTLFunction() ) {
		if (shouldFailOnPipelineCompileRequired()) {
			setConfigurationResult(VK_PIPELINE_COMPILE_REQUIRED);
		} else {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "%s shader function could not be compiled into pipeline. See previous logged error.", pStageName));
		}
	}
	return func;
}

MVKGraphicsPipeline::~MVKGraphicsPipeline() {
	@synchronized (getMTLDevice()) {
		[_mtlTessVertexStageState release];
		[_mtlTessVertexStageIndex16State release];
		[_mtlTessVertexStageIndex32State release];
		[_mtlTessControlStageState release];
		[_mtlPipelineState release];
		if (_ownsVertexModule) delete _vertexModule;
		if (_ownsTessCtlModule) delete _tessCtlModule;
		if (_ownsTessEvalModule) delete _tessEvalModule;
		if (_ownsGeometryModule) delete _geometryModule;
		if (_ownsFragmentModule) delete _fragmentModule;
	}
}


#pragma mark -
#pragma mark MVKComputePipeline

MVKComputePipeline::MVKComputePipeline(MVKDevice* device,
									   MVKPipelineCache* pipelineCache,
									   MVKPipeline* parent,
									   const VkComputePipelineCreateInfo* pCreateInfo) :
	MVKPipeline(device, pipelineCache, (MVKPipelineLayout*)pCreateInfo->layout, getPipelineCreateFlags(pCreateInfo), parent) {
	const uint64_t slowThreshold = mvkSlowComputeTraceThresholdNS(getMVKConfig());
	const bool traceSlow = slowThreshold != UINT64_MAX;
	const uint64_t slowStart = traceSlow ? mvkGetTimestamp() : 0;
	static std::atomic<uint64_t> activeCompute{0};
	static std::atomic<uint64_t> timedComputeSequence{0};
	const uint64_t timedRequest = traceSlow ? timedComputeSequence.fetch_add(1) : 0;
	const uint64_t activeAtStart = traceSlow ? activeCompute.fetch_add(1) + 1 : 0;

	_allowsDispatchBase = mvkAreAllFlagsEnabled(_flags, VK_PIPELINE_CREATE_2_DISPATCH_BASE_BIT);

	const VkPipelineCreationFeedbackCreateInfo* pFeedbackInfo = nullptr;
	for (const auto* next = (VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
			case VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO:
				pFeedbackInfo = (VkPipelineCreationFeedbackCreateInfo*)next;
				break;
			default:
				break;
		}
	}

	warnIfUnsupportedRobustnessEnabled(this, pCreateInfo);

	// Initialize feedback. The VALID bit must be initialized, either set or cleared.
	// We'll set the VALID bit on the stage feedback when we compile it.
	VkPipelineCreationFeedback* pPipelineFB = nullptr;
	VkPipelineCreationFeedback* pStageFB = nullptr;
	uint64_t pipelineStart = 0;
	if (pFeedbackInfo) {
		pPipelineFB = pFeedbackInfo->pPipelineCreationFeedback;
		// n.b. Do *NOT* use mvkClear().
		pPipelineFB->flags = 0;
		pPipelineFB->duration = 0;
		for (uint32_t i = 0; i < pFeedbackInfo->pipelineStageCreationFeedbackCount; ++i) {
			pFeedbackInfo->pPipelineStageCreationFeedbacks[i].flags = 0;
			pFeedbackInfo->pPipelineStageCreationFeedbacks[i].duration = 0;
		}
		pStageFB = &pFeedbackInfo->pPipelineStageCreationFeedbacks[0];
		pipelineStart = mvkGetTimestamp();
	}

	MVKMTLFunction func = getMTLFunction(pCreateInfo, pStageFB);
	const uint64_t functionNS = traceSlow ? mvkGetElapsedNanoseconds(slowStart) : 0;
	_mtlThreadgroupSize = func.threadGroupSize;
	_mtlPipelineState = nil;

	id<MTLFunction> mtlFunc = func.getMTLFunction();
	if (mtlFunc) {
		MTLComputePipelineDescriptor* plDesc = [MTLComputePipelineDescriptor new];	// temp retain
		plDesc.computeFunction = mtlFunc;
		plDesc.maxTotalThreadsPerThreadgroup = _mtlThreadgroupSize.width * _mtlThreadgroupSize.height * _mtlThreadgroupSize.depth;
		plDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = mvkIsAnyFlagEnabled(pCreateInfo->stage.flags, VK_PIPELINE_SHADER_STAGE_CREATE_REQUIRE_FULL_SUBGROUPS_BIT);

		// Metal does not allow the name of the pipeline to be changed after it has been created,
		// and we need to create the Metal pipeline immediately to provide error feedback to app.
		// The best we can do at this point is set the pipeline name from the layout.
		setMetalObjectLabel(plDesc, ((MVKPipelineLayout*)pCreateInfo->layout)->getDebugName());
		if (!_nativeComputeArchiveKey.empty()) plDesc.label = @(_nativeComputeArchiveKey.c_str());

		MVKComputePipelineCompiler* plc = new MVKComputePipelineCompiler(this);
		_mtlPipelineState = plc->newMTLComputePipelineState(plDesc);	// retained
		plc->destroy();
		[plDesc release];															// temp release

		if ( !_mtlPipelineState ) { _hasValidMTLPipelineStates = false; }
	} else {
		_hasValidMTLPipelineStates = false;
	}
	if (pPipelineFB) {
		if (_hasValidMTLPipelineStates) { mvkEnableFlags(pPipelineFB->flags, VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT); }
		pPipelineFB->duration = mvkGetElapsedNanoseconds(pipelineStart);
	}

	_stageResources.implicitBuffers.ids[MVKImplicitBuffer::PushConstant] = _layout->getPushConstantResourceIndex(kMVKShaderStageCompute);
	verifyImplicitBuffers(_stageResources.implicitBuffers, "Compute", _descriptorBufferCounts.stages[kMVKShaderStageCompute], this);
	if (traceSlow) {
		const uint64_t totalNS = mvkGetElapsedNanoseconds(slowStart);
		const uint64_t activeAtEnd = activeCompute.fetch_sub(1) - 1;
		if (totalNS >= slowThreshold || !_hasValidMTLPipelineStates) {
			mvkWriteRuntimeTrace(getMVKConfig(), @"slow-compute", @{
				@"request":@(timedRequest), @"time":@([NSDate timeIntervalSinceReferenceDate]),
				@"totalMilliseconds":@(totalNS / 1e6), @"functionMilliseconds":@(functionNS / 1e6),
				@"pipelineMilliseconds":@((totalNS - functionNS) / 1e6),
				@"activeAtStart":@(activeAtStart), @"activeAtEnd":@(activeAtEnd),
				@"function":mvkTraceFunction(mtlFunc), @"created":@(_hasValidMTLPipelineStates),
				@"configurationResult":@(getConfigurationResult())});
		}
	}
}

// Returns a MTLFunction to use when creating the MTLComputePipelineState.
MVKMTLFunction MVKComputePipeline::getMTLFunction(const VkComputePipelineCreateInfo* pCreateInfo,
												  VkPipelineCreationFeedback* pStageFB) {

    const VkPipelineShaderStageCreateInfo* pSS = &pCreateInfo->stage;
    if ( !mvkAreAllFlagsEnabled(pSS->stage, VK_SHADER_STAGE_COMPUTE_BIT) ) { return MVKMTLFunctionNull; }

	_module = getOrCreateShaderModule(_device, pSS, _ownsModule);

	warnIfUnsupportedRobustnessEnabled(this, pSS);

	auto& mtlFeats = getMetalFeatures();
	auto& mvkCfg = getMVKConfig();
    SPIRVToMSLConversionConfiguration shaderConfig;
	shaderConfig.options.entryPointName = pCreateInfo->stage.pName;
	shaderConfig.options.entryPointStage = spv::ExecutionModelGLCompute;
    shaderConfig.options.mslOptions.msl_version = mtlFeats.mslVersion;
    shaderConfig.options.mslOptions.texel_buffer_texture_width = mtlFeats.maxTextureDimension;
    shaderConfig.options.mslOptions.r32ui_linear_texture_alignment = (uint32_t)_device->getVkFormatTexelBufferAlignment(VK_FORMAT_R32_UINT, this);
	shaderConfig.options.mslOptions.texture_buffer_native = true;
	shaderConfig.options.mslOptions.dispatch_base = _allowsDispatchBase;
	shaderConfig.options.mslOptions.texture_1D_as_2D = mvkCfg.texture1DAs2D;
    shaderConfig.options.mslOptions.fixed_subgroup_size = mvkIsAnyFlagEnabled(pSS->flags, VK_PIPELINE_SHADER_STAGE_CREATE_ALLOW_VARYING_SUBGROUP_SIZE_BIT) ? 0 : mtlFeats.maxSubgroupSize;
	shaderConfig.options.mslOptions.bitwise_not_causes_ice = mtlFeats.bitwiseNotCausesICE;
	shaderConfig.options.mslOptions.add_texture_buffer_offsets = mtlFeats.emulatedTexelBufferAlignment;

	bool useMetalArgBuff = isUsingMetalArgumentBuffers();
	shaderConfig.options.mslOptions.argument_buffers = useMetalArgBuff;
	shaderConfig.options.mslOptions.force_active_argument_buffer_resources = false;
	shaderConfig.options.mslOptions.pad_argument_buffer_resources = useMetalArgBuff;
	shaderConfig.options.mslOptions.argument_buffers_tier = (SPIRV_CROSS_NAMESPACE::CompilerMSL::Options::ArgumentBuffersTier)getMetalFeatures().argumentBuffersTier;
	shaderConfig.options.mslOptions.robust_buffer_access2 = shouldEnableRobustBufferAccess2(this, pCreateInfo);
	shaderConfig.options.mslOptions.robust_image_access2 = shouldEnableRobustImageAccess2(this, pCreateInfo);
	shaderConfig.options.mslOptions.null_descriptor = getEnabledRobustness2Features().nullDescriptor;
	shaderConfig.options.mslOptions.typed_root_pointers = getPhysicalDevice()->isAMDHardware();
	shaderConfig.options.mslOptions.coherent_buffer_atomics = getPhysicalDevice()->isAMDHardware() && getenv("MVK_AMD_COHERENT_ATOMICS") && !strcmp(getenv("MVK_AMD_COHERENT_ATOMICS"), "1");
    if (getenv("MVK_AMD_REFERENCE_NULL") && std::string(getenv("MVK_AMD_REFERENCE_NULL")) == "1") { shaderConfig.options.mslOptions.null_descriptor = true; }

#if MVK_MACOS
    shaderConfig.options.mslOptions.emulate_subgroups = !mtlFeats.simdPermute;
#else
    shaderConfig.options.mslOptions.emulate_subgroups = !mtlFeats.quadPermute;
    shaderConfig.options.mslOptions.ios_use_simdgroup_functions = !!mtlFeats.simdPermute;
#endif

	MVKPipelineLayout* layout = (MVKPipelineLayout*)pCreateInfo->layout;
	layout->populateShaderConversionConfig(shaderConfig);

	// Set implicit buffer indices
	// FIXME: Many of these are optional. We shouldn't set the ones that aren't
	// present--or at least, we should move the ones that are down to avoid running over
	// the limit of available buffers. But we can't know that until we compile the shaders.
	_stageResources.implicitBuffers.ids[MVKImplicitBuffer::TextureOffset] = getImplicitBufferIndex(0);
	_stageResources.implicitBuffers.ids[MVKImplicitBuffer::DynamicOffset] = getImplicitBufferIndex(1);
	_stageResources.implicitBuffers.ids[MVKImplicitBuffer::BufferSize]    = getImplicitBufferIndex(2);
	_stageResources.implicitBuffers.ids[MVKImplicitBuffer::DispatchBase]  = getImplicitBufferIndex(3);

	addCommonImplicitBuffersToShaderConfig(shaderConfig, _stageResources.implicitBuffers.ids);
	shaderConfig.options.mslOptions.indirect_params_buffer_index = _stageResources.implicitBuffers.ids[MVKImplicitBuffer::DispatchBase];
	shaderConfig.options.mslOptions.replace_recursive_inputs = mvkOSVersionIsAtLeast(14.0, 17.0, 1.0);

    MVKMTLFunction func = _module->getMTLFunction(&shaderConfig, pSS->pSpecializationInfo, this, pStageFB);
	if ( !func.getMTLFunction() ) {
		if (shouldFailOnPipelineCompileRequired()) {
			setConfigurationResult(VK_PIPELINE_COMPILE_REQUIRED);
		} else {
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Compute shader function could not be compiled into pipeline. See previous logged error."));
		}
	}
	auto& funcRslts = func.shaderConversionResults;
	populateResourceUsage(_stageResources, shaderConfig, funcRslts, spv::ExecutionModelGLCompute);
	_layout->populateBindOperations(_stageResources.bindScript, shaderConfig, spv::ExecutionModelGLCompute);

	return func;
}

uint32_t MVKComputePipeline::getImplicitBufferIndex(uint32_t bufferIndexOffset) {
	return getMetalFeatures().maxPerStageBufferCount - (bufferIndexOffset + 1);
}

MVKComputePipeline::~MVKComputePipeline() {
	@synchronized (getMTLDevice()) {
		[_mtlPipelineState release];
		if (_ownsModule) delete _module;
	}
}


#pragma mark -
#pragma mark MVKPipelineCache

// Return a shader library from the specified shader conversion configuration sourced from the specified shader module.
MVKShaderLibrary* MVKPipelineCache::getShaderLibrary(SPIRVToMSLConversionConfiguration* pContext,
													 MVKShaderModule* shaderModule,
													 MVKPipeline* pipeline,
													 VkPipelineCreationFeedback* pShaderFeedback,
													 uint64_t startTime) {
	const char* shardedOption = getenv("MVK_AMD_SHARDED_SHADER_CACHE_LOCKS");
	bool sharded = shardedOption && !strcmp(shardedOption, "1") &&
		getPhysicalDevice()->isAMDHardware() && !_isExternallySynchronized;
	if (sharded) {
		// The legacy path held the global cache mutex while SPIR-V conversion
		// and Metal library compilation completed. Protect only the module-key
		// table here; each module cache serializes its own conversion variants.
		MVKShaderLibraryCache* slCache;
		{
			lock_guard<mutex> lock(_shaderCacheLock);
			slCache = getShaderLibraryCache(shaderModule->getKey());
		}
		bool wasAdded = false;
		MVKShaderLibrary* shLib = slCache->getShaderLibrary(pContext, shaderModule, pipeline,
			&wasAdded, pShaderFeedback, startTime);
		if (wasAdded) {
			lock_guard<mutex> lock(_shaderCacheLock);
			markDirty();
		} else if (pShaderFeedback) {
			mvkEnableFlags(pShaderFeedback->flags,
				VK_PIPELINE_CREATION_FEEDBACK_APPLICATION_PIPELINE_CACHE_HIT_BIT);
		}
		return shLib;
	}
	if (_isExternallySynchronized) {
		return getShaderLibraryImpl(pContext, shaderModule, pipeline, pShaderFeedback, startTime);
	} else {
		lock_guard<mutex> lock(_shaderCacheLock);
		return getShaderLibraryImpl(pContext, shaderModule, pipeline, pShaderFeedback, startTime);
	}
}

MVKShaderLibrary* MVKPipelineCache::getShaderLibraryImpl(SPIRVToMSLConversionConfiguration* pContext,
														 MVKShaderModule* shaderModule,
														 MVKPipeline* pipeline,
														 VkPipelineCreationFeedback* pShaderFeedback,
														 uint64_t startTime) {
	bool wasAdded = false;
	MVKShaderLibraryCache* slCache = getShaderLibraryCache(shaderModule->getKey());
	MVKShaderLibrary* shLib = slCache->getShaderLibrary(pContext, shaderModule, pipeline, &wasAdded, pShaderFeedback, startTime);
	if (wasAdded) { markDirty(); }
	else if (pShaderFeedback) { mvkEnableFlags(pShaderFeedback->flags, VK_PIPELINE_CREATION_FEEDBACK_APPLICATION_PIPELINE_CACHE_HIT_BIT); }
	return shLib;
}

// Returns a shader library cache for the specified shader module key, creating it if necessary.
MVKShaderLibraryCache* MVKPipelineCache::getShaderLibraryCache(MVKShaderModuleKey smKey) {
	MVKShaderLibraryCache* slCache = _shaderCache[smKey];
	if ( !slCache ) {
		slCache = new MVKShaderLibraryCache(this);
		_shaderCache[smKey] = slCache;
	}
	return slCache;
}


#pragma mark Streaming pipeline cache to and from offline memory

#if MVK_USE_CEREAL
static uint32_t kDataHeaderSize = (sizeof(uint32_t) * 4) + VK_UUID_SIZE;
#endif

// Entry type markers to be inserted into data stream
typedef enum {
	MVKPipelineCacheEntryTypeEOF = 0,
	MVKPipelineCacheEntryTypeShaderLibrary = 1,
} MVKPipelineCacheEntryType;

// Helper class to iterate through the shader libraries in a shader library cache in order to serialize them.
// Needs to support input of null shader library cache.
class MVKShaderCacheIterator : public MVKBaseObject {

	/** Returns the Vulkan API opaque object controlling this object. */
	MVKVulkanAPIObject* getVulkanAPIObject() override { return _pSLCache->getVulkanAPIObject(); };

protected:
	friend MVKPipelineCache;

	bool next() { return (++_index < (_pSLCache ? _pSLCache->_shaderLibraries.size() : 0)); }
	SPIRVToMSLConversionConfiguration& getShaderConversionConfig() { return _pSLCache->_shaderLibraries[_index].first; }
	MVKCompressor<std::string>& getCompressedMSL() { return _pSLCache->_shaderLibraries[_index].second->getCompressedMSL(); }
	SPIRVToMSLConversionResultInfo& getShaderConversionResultInfo() { return _pSLCache->_shaderLibraries[_index].second->_shaderConversionResultInfo; }
	MVKShaderCacheIterator(MVKShaderLibraryCache* pSLCache) :
		_pSLCache(pSLCache),
		_cacheLock(pSLCache ? unique_lock<mutex>(pSLCache->_accessLock) : unique_lock<mutex>()) {}

	MVKShaderLibraryCache* _pSLCache;
	unique_lock<mutex> _cacheLock;
	size_t _count = 0;
	int32_t _index = -1;
};

VkResult MVKPipelineCache::writeData(size_t* pDataSize, void* pData) {
	if (_isExternallySynchronized) {
		return writeDataImpl(pDataSize, pData);
	} else {
		lock_guard<mutex> lock(_shaderCacheLock);
		return writeDataImpl(pDataSize, pData);
	}
}

// If pData is not null, serializes at most pDataSize bytes of the contents of the cache into that
// memory location, and returns the number of bytes serialized in pDataSize. If pData is null,
// returns the number of bytes required to serialize the contents of this pipeline cache.
// This is the compliment of the readData() function. The two must be kept aligned.
VkResult MVKPipelineCache::writeDataImpl(size_t* pDataSize, void* pData) {
#if MVK_USE_CEREAL
	try {

		if ( !pDataSize ) { return VK_SUCCESS; }

		if (pData) {
			if (*pDataSize >= _dataSize) {
				mvk::membuf mb((char*)pData, _dataSize);
				ostream outStream(&mb);
				writeData(outStream);
				*pDataSize = _dataSize;
				return VK_SUCCESS;
			} else {
				*pDataSize = 0;
				return VK_INCOMPLETE;
			}
		} else {
			if (_dataSize == 0) {
				mvk::countbuf cb;
				ostream outStream(&cb);
				writeData(outStream, true);
				_dataSize = cb.buffSize;
			}
			*pDataSize = _dataSize;
			return VK_SUCCESS;
		}

	} catch (cereal::Exception& ex) {
		*pDataSize = 0;
		return reportError(VK_INCOMPLETE, "Error writing pipeline cache data: %s", ex.what());
	}
#else
	*pDataSize = 0;
	return reportError(VK_INCOMPLETE, "Pipeline cache serialization is unavailable. To enable pipeline cache serialization, build MoltenVK with MVK_USE_CEREAL=1 build setting.");
#endif
}

// Serializes the data in this cache to a stream
void MVKPipelineCache::writeData(ostream& outstream, bool isCounting) {
#if MVK_USE_CEREAL
	MVKPerformanceTracker& perfTracker = isCounting
		? getPerformanceStats().pipelineCache.sizePipelineCache
		: getPerformanceStats().pipelineCache.writePipelineCache;

	uint32_t cacheEntryType;
	cereal::BinaryOutputArchive writer(outstream);

	// Write the data header...after ensuring correct byte-order.
	auto& devProps = getDeviceProperties();
	writer(NSSwapHostIntToLittle(kDataHeaderSize));
	writer(NSSwapHostIntToLittle(VK_PIPELINE_CACHE_HEADER_VERSION_ONE));
	writer(NSSwapHostIntToLittle(devProps.vendorID));
	writer(NSSwapHostIntToLittle(devProps.deviceID));
	writer(devProps.pipelineCacheUUID);

	// Shader libraries
	// Output a cache entry for each shader library, including the shader module key in each entry.
	cacheEntryType = MVKPipelineCacheEntryTypeShaderLibrary;
	for (auto& scPair : _shaderCache) {
		MVKShaderModuleKey smKey = scPair.first;
		MVKShaderCacheIterator cacheIter(scPair.second);
		while (cacheIter.next()) {
			uint64_t startTime = getPerformanceTimestamp();
			writer(cacheEntryType);
			writer(smKey);
			writer(cacheIter.getShaderConversionConfig());
			writer(cacheIter.getShaderConversionResultInfo());
			writer(cacheIter.getCompressedMSL());
			addPerformanceInterval(perfTracker, startTime);
		}
	}

	// Mark the end of the archive
	cacheEntryType = MVKPipelineCacheEntryTypeEOF;
	writer(cacheEntryType);
#else
	MVKAssert(false, "Pipeline cache serialization is unavailable. To enable pipeline cache serialization, build MoltenVK with MVK_USE_CEREAL=1 build setting.");
#endif
}

// Loads any data indicated by the creation info.
// This is the compliment of the writeData() function. The two must be kept aligned.
void MVKPipelineCache::readData(const VkPipelineCacheCreateInfo* pCreateInfo) {
#if MVK_USE_CEREAL
	try {

		size_t byteCount = pCreateInfo->initialDataSize;
		uint32_t cacheEntryType;

		// Must be able to read the header and at least one cache entry type.
		if (byteCount < kDataHeaderSize + sizeof(cacheEntryType)) { return; }

		mvk::membuf mb((char*)pCreateInfo->pInitialData, byteCount);
		istream inStream(&mb);
		cereal::BinaryInputArchive reader(inStream);

		// Read the data header...and ensure correct byte-order.
		uint32_t hdrComponent;
		uint8_t pcUUID[VK_UUID_SIZE];
		auto& dvcProps = getDeviceProperties();

		reader(hdrComponent);	// Header size
		if (NSSwapLittleIntToHost(hdrComponent) !=  kDataHeaderSize) { return; }

		reader(hdrComponent);	// Header version
		if (NSSwapLittleIntToHost(hdrComponent) !=  VK_PIPELINE_CACHE_HEADER_VERSION_ONE) { return; }

		reader(hdrComponent);	// Vendor ID
		if (NSSwapLittleIntToHost(hdrComponent) !=  dvcProps.vendorID) { return; }

		reader(hdrComponent);	// Device ID
		if (NSSwapLittleIntToHost(hdrComponent) !=  dvcProps.deviceID) { return; }

		reader(pcUUID);			// Pipeline cache UUID
		if ( !mvkAreEqual(pcUUID, dvcProps.pipelineCacheUUID, VK_UUID_SIZE) ) { return; }

		bool done = false;
		while ( !done ) {
			reader(cacheEntryType);
			switch (cacheEntryType) {
				case MVKPipelineCacheEntryTypeShaderLibrary: {
					uint64_t startTime = getPerformanceTimestamp();

					MVKShaderModuleKey smKey;
					reader(smKey);

					SPIRVToMSLConversionConfiguration shaderConversionConfig;
					reader(shaderConversionConfig);

					SPIRVToMSLConversionResultInfo resultInfo;
					reader(resultInfo);

					MVKCompressor<std::string> compressedMSL;
					reader(compressedMSL);

					// Add the shader library to the staging cache.
					MVKShaderLibraryCache* slCache = getShaderLibraryCache(smKey);
					addPerformanceInterval(getPerformanceStats().pipelineCache.readPipelineCache, startTime);
					// Initial data must not make the pipeline cache fail: an entry whose MSL does not
					// compile is dropped (addShaderLibrary()) and its compile error is not kept.
					VkResult prevResult = getConfigurationResult();
					if ( !slCache->addShaderLibrary(&shaderConversionConfig, resultInfo, compressedMSL) && prevResult == VK_SUCCESS ) {
						clearConfigurationResult();
						reportWarning(VK_SUCCESS, "Dropped a pipeline cache entry whose MSL does not compile.");
					}

					break;
				}

				default: {
					done = true;
					break;
				}
			}
		}

	} catch (cereal::Exception& ex) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Error reading pipeline cache data: %s", ex.what()));
	}
#else
	setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "Pipeline cache serialization is unavailable. To enable pipeline cache serialization, build MoltenVK with MVK_USE_CEREAL=1 build setting."));
#endif
}

// Mark the cache as dirty, so that existing streaming info is released
void MVKPipelineCache::markDirty() {
	_dataSize = 0;
}

VkResult MVKPipelineCache::mergePipelineCaches(uint32_t srcCacheCount, const VkPipelineCache* pSrcCaches) {
	if (!_isMergeInternallySynchronized) {
		return mergePipelineCachesImpl(srcCacheCount, pSrcCaches);
	} else {
		lock_guard<mutex> lock(_shaderCacheLock);
		return mergePipelineCachesImpl(srcCacheCount, pSrcCaches);
	}
}

VkResult MVKPipelineCache::mergePipelineCachesImpl(uint32_t srcCacheCount, const VkPipelineCache* pSrcCaches) {
	for (uint32_t srcIdx = 0; srcIdx < srcCacheCount; srcIdx++) {
		MVKPipelineCache* srcPLC = (MVKPipelineCache*)pSrcCaches[srcIdx];
		for (auto& srcPair : srcPLC->_shaderCache) {
			getShaderLibraryCache(srcPair.first)->merge(srcPair.second);
		}
	}
	markDirty();

	return VK_SUCCESS;
}


#pragma mark Cereal archive definitions

namespace SPIRV_CROSS_NAMESPACE {

	template<class Archive>
	void serialize(Archive & archive, CompilerMSL::Options& opt) {
		archive(opt.platform,
				opt.msl_version,
				opt.texel_buffer_texture_width,
				opt.r32ui_linear_texture_alignment,
				opt.r32ui_alignment_constant_id,
				opt.swizzle_buffer_index,
				opt.indirect_params_buffer_index,
				opt.shader_output_buffer_index,
				opt.shader_patch_output_buffer_index,
				opt.shader_tess_factor_buffer_index,
				opt.buffer_size_buffer_index,
				opt.view_mask_buffer_index,
				opt.dynamic_offsets_buffer_index,
				opt.shader_input_buffer_index,
				opt.shader_index_buffer_index,
				opt.shader_patch_input_buffer_index,
				opt.draw_info_index,
				opt.xfb_buffer_index,
				opt.xfb_session_index,
				opt.xfb_prims_index,
				opt.xfb_mode_index,
				opt.texture_offset_buffer_index,
				opt.reversed_depth_viewport_buffer_index,
				opt.depth_clip_state_buffer_index,
				opt.shader_input_wg_index,
				opt.device_index,
				opt.enable_frag_output_mask,
				opt.frag_output_float_mask,
				opt.frag_output_sint_mask,
				opt.frag_output_uint_mask,
				opt.additional_fixed_sample_mask,
				opt.enable_point_size_builtin,
				opt.enable_point_size_default,
				opt.default_point_size,
				opt.enable_frag_depth_builtin,
				opt.enable_frag_stencil_ref_builtin,
				opt.disable_rasterization,
				opt.capture_output_to_buffer,
				opt.swizzle_texture_samples,
				opt.tess_domain_origin_lower_left,
				opt.multiview,
				opt.multiview_layered_rendering,
				opt.view_index_from_device_index,
				opt.dispatch_base,
				opt.texture_1D_as_2D,
				opt.emulate_reversed_depth_viewport,
				opt.emulate_depth_clip_enable,
				opt.argument_buffers,
				opt.argument_buffers_tier,
				opt.runtime_array_rich_descriptor,
				opt.enable_base_index_zero,
				opt.pad_fragment_output_components,
				opt.ios_support_base_vertex_instance,
				opt.use_framebuffer_fetch_subpasses,
				opt.invariant_float_math,
				opt.emulate_cube_array,
				opt.enable_decoration_binding,
				opt.texture_buffer_native,
				opt.add_texture_buffer_offsets,
				opt.force_active_argument_buffer_resources,
				opt.pad_argument_buffer_resources,
				opt.force_native_arrays,
				opt.enable_clip_distance_user_varying,
				opt.multi_patch_workgroup,
				opt.raw_buffer_tese_input,
				opt.vertex_for_tessellation,
				opt.arrayed_subpass_input,
				opt.ios_use_simdgroup_functions,
				opt.emulate_subgroups,
				opt.fixed_subgroup_size,
				opt.vertex_index_type,
				opt.force_sample_rate_shading,
				opt.manual_helper_invocation_updates,
				opt.check_discarded_frag_stores,
				opt.sample_dref_lod_array_as_grad,
				opt.readwrite_texture_fences,
				opt.bitwise_not_causes_ice,
				opt.replace_recursive_inputs,
				opt.agx_manual_cube_grad_fixup,
				opt.force_fragment_with_side_effects_execution,
				opt.input_attachment_is_ds_attachment,
				opt.auto_disable_rasterization,
				opt.use_fast_math_pragmas,
				opt.robust_buffer_access2,
				opt.robust_image_access2,
				opt.null_descriptor,
				opt.typed_root_pointers,
				opt.coherent_buffer_atomics,
				opt.for_mesh_pipeline,
				opt.zero_missing_vertex_attributes,
				opt.input_primitive_type);
	}

	template<class Archive>
	void serialize(Archive & archive, MSLShaderInterfaceVariable& si) {
		archive(si.location,
				si.component,
				si.format,
				si.builtin,
				si.vecsize,
				si.rate,
				si.offset,
				si.stride,
				si.binding,
				si.normalized);
	}

	template<class Archive>
	void serialize(Archive & archive, MSLResourceBinding& rb) {
		archive(rb.stage,
				rb.basetype,
				rb.desc_set,
				rb.binding,
				rb.count,
				rb.msl_buffer,
				rb.msl_texture,
				rb.msl_sampler,
				rb.image_format_components);
	}

	template<class Archive>
	void serialize(Archive & archive, MSLConstexprSampler& cs) {
		archive(cs.coord,
				cs.min_filter,
				cs.mag_filter,
				cs.mip_filter,
				cs.s_address,
				cs.t_address,
				cs.r_address,
				cs.compare_func,
				cs.border_color,
				cs.lod_clamp_min,
				cs.lod_clamp_max,
				cs.max_anisotropy,
				cs.planes,
				cs.resolution,
				cs.chroma_filter,
				cs.x_chroma_offset,
				cs.y_chroma_offset,
				cs.swizzle,
				cs.ycbcr_model,
				cs.ycbcr_range,
				cs.bpc,
				cs.compare_enable,
				cs.lod_clamp_enable,
				cs.anisotropy_enable,
				cs.ycbcr_conversion_enable);
	}

}

namespace mvk {

	template<class Archive>
	void serialize(Archive & archive, SPIRVWorkgroupSizeDimension& wsd) {
		archive(wsd.size,
				wsd.specializationID,
				wsd.isSpecialized);
	}

	template<class Archive>
	void serialize(Archive & archive, SPIRVEntryPoint& ep) {
		archive(ep.mtlFunctionName,
				ep.workgroupSize.width,
				ep.workgroupSize.height,
				ep.workgroupSize.depth,
				ep.fpFastMathFlags);
	}

	template<class Archive>
	void serialize(Archive & archive, SPIRVToMSLConversionOptions& opt) {
		archive(opt.mslOptions,
				opt.entryPointName,
				opt.entryPointStage,
				opt.tessPatchKind,
				opt.numTessControlPoints,
				opt.shouldFlipVertexY,
				opt.shouldFixupClipSpace,
				opt.uniqueEntryPointName);
	}

	template<class Archive>
	void serialize(Archive & archive, MSLShaderInterfaceVariable& si) {
		archive(si.shaderVar,
				si.binding,
				si.outIsUsedByShader);
	}

	template<class Archive>
	void serialize(Archive & archive, MSLResourceBinding& rb) {
		archive(rb.resourceBinding,
				rb.constExprSampler,
				rb.requiresConstExprSampler,
				rb.outIsUsedByShader);
	}

	template<class Archive>
	void serialize(Archive & archive, DescriptorBinding& db) {
		archive(db.stage,
				db.descriptorSet,
				db.binding,
				db.index);
	}

	template<class Archive>
	void serialize(Archive & archive, SPIRVToMSLConversionConfiguration& cfg) {
		archive(cfg.options,
				cfg.shaderInputs,
				cfg.shaderOutputs,
				cfg.resourceBindings,
				cfg.discreteDescriptorSets,
				cfg.dynamicBufferDescriptors);
	}

	template<class Archive>
	void serialize(Archive & archive, SPIRVToMSLConversionResultInfo& scr) {
		archive(scr.entryPoint,
				scr.specializationMacros,
				scr.isRasterizationDisabled,
				scr.isPositionInvariant,
				scr.needsOutputBuffer,
				scr.needsPatchOutputBuffer,
				scr.needsBufferSizeBuffer,
				scr.needsDynamicOffsetBuffer,
				scr.needsTextureOffsetBuffer,
				scr.needsInputThreadgroupMem,
				scr.needsDispatchBaseBuffer,
				scr.needsViewRangeBuffer,
				scr.needsXfbBuffer,
				scr.needsDepthClipStateBuffer,
				scr.usesPhysicalStorageBufferAddressesCapability);
	}

	template<class Archive>
	void serialize(Archive & archive, MSLSpecializationMacroInfo& info) {
		archive(info.name,
				info.isFloat,
				info.isSigned);
	}

}

template<class Archive>
void serialize(Archive & archive, MVKShaderModuleKey& k) {
	archive(k.codeSize,
			k.codeHash);
}

template<class Archive, class C>
void serialize(Archive & archive, MVKCompressor<C>& comp) {
	archive(comp._compressed,
			comp._uncompressedSize,
			comp._algorithm);
}


#pragma mark Construction

MVKPipelineCache::MVKPipelineCache(MVKDevice* device, const VkPipelineCacheCreateInfo* pCreateInfo) :
	MVKVulkanAPIDeviceObject(device),
	_isExternallySynchronized(getEnabledPipelineCreationCacheControlFeatures().pipelineCreationCacheControl &&
							  mvkIsAnyFlagEnabled(pCreateInfo->flags, VK_PIPELINE_CACHE_CREATE_EXTERNALLY_SYNCHRONIZED_BIT)),
	_isMergeInternallySynchronized(getEnabledPipelineCreationCacheControlFeatures().pipelineCreationCacheControl &&
								   mvkIsAnyFlagEnabled(pCreateInfo->flags, VK_PIPELINE_CACHE_CREATE_INTERNALLY_SYNCHRONIZED_MERGE_BIT_KHR)) {

	readData(pCreateInfo);
}

MVKPipelineCache::~MVKPipelineCache() {
	for (auto& pair : _shaderCache) { pair.second->destroy(); }
	_shaderCache.clear();
}


#pragma mark -
#pragma mark Optional AMD Metal binary archive

// Vulkan pipeline caches persist converted MSL, but Metal still has to compile
// the final native pipeline after the cache is reloaded. Keep this explicitly
// opt-in because Metal recommends shipping prebuilt archives. The research
// paths are supplied by the launcher and are never inferred from application data.
struct MVKBinaryArchiveState {
	mutex lock;
	id<MTLBinaryArchive> archive = nil;
	NSString* path = nil;
	bool attempted = false;
	bool full = false;
	uint64_t additions = 0;
};

template<class AddFunctions>
static id<MTLBinaryArchive> mvkPrepareBinaryArchive(MVKBinaryArchiveState& state,
												 id<MTLDevice> mtlDev,
												 id descriptor,
												 bool isAMD,
												 const char* pathEnvironment,
												 AddFunctions addFunctions) {
	if (!isAMD) { return nil; }
	const char* archivePathC = getenv(pathEnvironment);
	if (!archivePathC || archivePathC[0] != '/') { return nil; }
	lock_guard<mutex> lock(state.lock);

	uint64_t maxBytes = 1024ull * 1024ull * 1024ull;
	if (const char* maxC = getenv("MVK_AMD_BINARY_ARCHIVE_MAX_BYTES")) {
		char* end = nullptr;
		uint64_t parsed = strtoull(maxC, &end, 10);
		if (end && !*end && parsed > 0) { maxBytes = parsed; }
	}
	if (!state.attempted) {
		state.attempted = true;
		state.path = [[NSString alloc] initWithUTF8String:archivePathC];
		MTLBinaryArchiveDescriptor* archiveDesc = [MTLBinaryArchiveDescriptor new];
		if ([[NSFileManager defaultManager] fileExistsAtPath:state.path]) {
			struct stat archiveStat {};
			if (stat(state.path.fileSystemRepresentation, &archiveStat) == 0 && archiveStat.st_size >= maxBytes) {
				// Loading an opaque archive can require several times its on-disk
				// size in the AMD Metal driver.  Treat the configured byte limit as
				// a load limit too.  Previously we marked an oversized archive full
				// but still opened it; a 1.70 GB cache alone peaked at 5.68 GB RSS.
				// Preserve the file and run without this cache rather than replacing
				// it or risking an out-of-memory failure before the application starts.
				state.full = true;
				if (getenv("MVK_AMD_BINARY_ARCHIVE_TRACE")) {
					fprintf(stderr, "MoltenVK binary archive skipped (size %lld >= limit %llu): %s\n",
						(long long)archiveStat.st_size, (unsigned long long)maxBytes, archivePathC);
				}
				[archiveDesc release];
				return nil;
			}
			archiveDesc.url = [NSURL fileURLWithPath:state.path];
		}
		NSError* error = nil;
		state.archive = [mtlDev newBinaryArchiveWithDescriptor:archiveDesc error:&error];
		[archiveDesc release];
		if (!state.archive) {
			// An OS/driver update can invalidate an archive. Preserve the old file
			// until a new archive is successfully serialized over it.
			MTLBinaryArchiveDescriptor* emptyDesc = [MTLBinaryArchiveDescriptor new];
			state.archive = [mtlDev newBinaryArchiveWithDescriptor:emptyDesc error:&error];
			[emptyDesc release];
			state.full = false;
		}
	}
	if (!state.archive) { return nil; }

	mvkSetBinaryArchive(descriptor, state.archive);
	bool isRenderArchive = !strcmp(pathEnvironment, "MVK_AMD_RENDER_BINARY_ARCHIVE_PATH");
	bool readOnly = isRenderArchive && getenv("MVK_AMD_RENDER_BINARY_ARCHIVE_READ_ONLY") &&
		!strcmp(getenv("MVK_AMD_RENDER_BINARY_ARCHIVE_READ_ONLY"), "1");
	NSError* addError = nil;
	if (!readOnly && !state.full && addFunctions(state.archive, &addError)) {
		state.additions++;
		uint64_t flushEvery = 64;
		if (const char* flushC = getenv("MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL")) {
			char* end = nullptr;
			uint64_t parsed = strtoull(flushC, &end, 10);
			if (end && !*end && parsed > 0) { flushEvery = parsed; }
		}
		// Intel macOS AMD can spend minutes (or never return) while serializing a
		// large render archive. The serializer runs under the same Metal-device
		// critical section as shader-library creation, so one flush blocks every
		// UE shader worker. Playable replay-only runs may consume the last verified
		// archive and extend it in memory, but defer render serialization until a
		// future sharded writer can do so without holding the device lock.
		bool deferPlayableRenderSerialization = isRenderArchive && mvkRuntimeReplayOnly();
		if (!deferPlayableRenderSerialization && (state.additions % flushEvery) == 0) {
			NSString* tempPath = [state.path stringByAppendingFormat:@".tmp.%d.%llu", getpid(),
				(unsigned long long)state.additions];
			NSURL* tempURL = [NSURL fileURLWithPath:tempPath];
			NSError* serializeError = nil;
			// Check the serialized candidate BEFORE replacing the last loadable
			// archive. Metal's opaque archive can jump from <256 MB to >2 GB in
			// one flush; checking only after rename destroys the useful warm file
			// and the next process then skips the oversized replacement entirely.
			// Preserve rejected candidates separately for diagnosis, too.
			if (![[NSFileManager defaultManager] fileExistsAtPath:tempPath] &&
				[state.archive serializeToURL:tempURL error:&serializeError]) {
				struct stat archiveStat {};
				if (stat(tempPath.fileSystemRepresentation, &archiveStat) == 0) {
					if (archiveStat.st_size >= maxBytes) {
						state.full = true;
						NSString* oversizedPath = [state.path stringByAppendingFormat:@".oversized.%d.%llu", getpid(),
							(unsigned long long)state.additions];
						if (![[NSFileManager defaultManager] fileExistsAtPath:oversizedPath])
							rename(tempPath.fileSystemRepresentation, oversizedPath.fileSystemRepresentation);
						if (getenv("MVK_AMD_BINARY_ARCHIVE_TRACE"))
							fprintf(stderr, "MoltenVK binary archive oversized candidate preserved (size %lld >= limit %llu); prior archive retained: %s\n",
								(long long)archiveStat.st_size, (unsigned long long)maxBytes, archivePathC);
						// The descriptor already retains this archive for the current
						// pipeline creation. Stop retaining it process-wide: merely
						// setting full left a multi-GB archive resident for the rest
						// of the game. Future pipelines can compile without it;
						// the last bounded on-disk archive remains unchanged.
						[state.archive release];
						state.archive = nil;
						if (getenv("MVK_AMD_BINARY_ARCHIVE_TRACE"))
							fprintf(stderr, "MoltenVK binary archive retired from persistent state after oversized publication was rejected: %s\n", archivePathC);
					} else {
						rename(tempPath.fileSystemRepresentation, state.path.fileSystemRepresentation);
					}
				}
			}
		}
	} else if (addError && getenv("MVK_AMD_BINARY_ARCHIVE_TRACE")) {
		fprintf(stderr, "MoltenVK binary archive add failed for %s: %s\n", pathEnvironment,
				addError.localizedDescription.UTF8String ?: "unknown error");
	}
	return state.archive;
}

static id<MTLBinaryArchive> mvkPrepareComputeBinaryArchive(id<MTLDevice> mtlDev,
													MTLComputePipelineDescriptor* plDesc,
													bool isAMD) {
	static MVKBinaryArchiveState state;
	return mvkPrepareBinaryArchive(state, mtlDev, plDesc, isAMD, "MVK_AMD_BINARY_ARCHIVE_PATH",
		[&](id<MTLBinaryArchive> archive, NSError** error) {
			uint64_t operation=mvkLinkOperationBegin(@"compute-legacy-archive-add",plDesc.label);
			bool result=[archive addComputePipelineFunctionsWithDescriptor:plDesc error:error];
			mvkLinkOperationEnd(operation);return result;
		});
}

// Metal binary archives are opaque, and some Intel macOS AMD driver versions can
// become stuck forever while deserializing a single archived render pipeline.
// Keep the archive and bypass only shader pairs that have been isolated by an
// external watchdog. The optional denylist lives beside the archive and contains
// one vertex-function-label prefix and fragment-function-label prefix per line.
static bool mvkRenderBinaryArchiveDenied(MTLRenderPipelineDescriptor* plDesc, bool isAMD) {
	if (!isAMD) { return false; }
	const char* archivePath = getenv("MVK_AMD_RENDER_BINARY_ARCHIVE_PATH");
	if (!archivePath || archivePath[0] != '/') { return false; }

	static mutex denyLock;
	static string loadedPath;
	static vector<pair<string, string>> deniedPairs;
	lock_guard<mutex> lock(denyLock);
	string denyPath = string(archivePath) + ".denylist";
	if (loadedPath != denyPath) {
		loadedPath = denyPath;
		deniedPairs.clear();
		if (FILE* file = fopen(denyPath.c_str(), "r")) {
			char line[512];
			while (fgets(line, sizeof(line), file)) {
				istringstream fields(line);
				string vertexPrefix;
				string fragmentPrefix;
				if ((fields >> vertexPrefix >> fragmentPrefix) && vertexPrefix[0] != '#') {
					deniedPairs.emplace_back(vertexPrefix, fragmentPrefix);
				}
			}
			fclose(file);
		}
	}

	const char* vertexLabel = plDesc.vertexFunction.label.UTF8String ?: "";
	const char* fragmentLabel = plDesc.fragmentFunction.label.UTF8String ?: "";
	for (const auto& denied : deniedPairs) {
		if (!strncmp(vertexLabel, denied.first.c_str(), denied.first.size()) &&
			!strncmp(fragmentLabel, denied.second.c_str(), denied.second.size())) {
			if (getenv("MVK_AMD_BINARY_ARCHIVE_TRACE")) {
				fprintf(stderr, "MoltenVK render archive denylist bypass: %s %s\n",
					vertexLabel, fragmentLabel);
			}
			return true;
		}
	}
	return false;
}

static id<MTLBinaryArchive> mvkPrepareRenderBinaryArchive(id<MTLDevice> mtlDev,
												 MTLRenderPipelineDescriptor* plDesc,
												 bool isAMD) {
	if (mvkRenderBinaryArchiveDenied(plDesc, isAMD)) { return nil; }
	static MVKBinaryArchiveState state;
	return mvkPrepareBinaryArchive(state, mtlDev, plDesc, isAMD, "MVK_AMD_RENDER_BINARY_ARCHIVE_PATH",
		[&](id<MTLBinaryArchive> archive, NSError** error) {
			uint64_t operation=mvkLinkOperationBegin(@"render-legacy-archive-add",plDesc.label);
			bool result=[archive addRenderPipelineFunctionsWithDescriptor:plDesc error:error];
			mvkLinkOperationEnd(operation);return result;
		});
}


#pragma mark -
#pragma mark MVKRenderPipelineCompiler

id<MTLRenderPipelineState> MVKRenderPipelineCompiler::newMTLRenderPipelineState(MTLRenderPipelineDescriptor* mtlRPLDesc) {
    // Function entry names (often "main0") do not identify shader content.
    // Keep the existing source identity in the opt-in failure label instead.
    // Labels are diagnostic only and are not included in archive recipes.
    if (mvkWorkTraceConfigured()) mtlRPLDesc.label = [NSString stringWithFormat:@"vs=%@;fs=%@", mtlRPLDesc.vertexFunction.label ?: mtlRPLDesc.vertexFunction.name ?: @"", mtlRPLDesc.fragmentFunction.label ?: mtlRPLDesc.fragmentFunction.name ?: @""];

	unique_lock<mutex> lock(_completionLock);
	const char* root = getenv("MVK_AMD_RENDER_ARCHIVE_DIR");
	bool useShards = getPhysicalDevice()->isAMDHardware() && root && root[0] == '/';
	NSString* shardPath = useShards && !mvkRenderBinaryArchiveDenied(mtlRPLDesc, true)
		? mvkRenderShardPath(getMTLDevice(), mtlRPLDesc) : nil;
	uint64_t started = mvkGetTimestamp();
	bool loaded = shardPath && mvkLoadRenderShard(getMTLDevice(), mtlRPLDesc, shardPath);
	double loadMS = mvkGetElapsedNanoseconds(started) / 1e6;
	bool requireHit = useShards && getenv("MVK_AMD_RENDER_ARCHIVE_REQUIRE_HIT") &&
		!strcmp(getenv("MVK_AMD_RENDER_ARCHIVE_REQUIRE_HIT"), "1");
	__block bool strictHit = false;
	__block bool fallback = false;
	__block NSInteger archiveErrorCode = 0;
	bool rehydrated = false;
	double rehydrateMS = 0;
	NSInteger rehydrateErrorCode = 0;

	compile(lock, ^{
		auto mtlDev = getMTLDevice();
        // Archive preparation is synchronous driver compilation and already
        // serializes its own state. Do not hold the device-wide monitor while
        // waiting: unrelated library/function requests need that monitor.
        if (!useShards) mvkPrepareRenderBinaryArchive(mtlDev, mtlRPLDesc, getPhysicalDevice()->isAMDHardware());
		uint64_t operation=mvkLinkOperationBegin(@"render-pipeline",mtlRPLDesc.label);
		@synchronized (mtlDev) {
			if (loaded || requireHit) {
				// Loading a file alone does not prove reuse. Ask Metal to reject a
				// miss before permitting the normal, correctness-preserving fallback.
				[mtlDev newRenderPipelineStateWithDescriptor:mtlRPLDesc
					options:MTLPipelineOptionFailOnBinaryArchiveMiss
					completionHandler:^(id<MTLRenderPipelineState> ps, MTLRenderPipelineReflection*, NSError* error) {
						strictHit = ps != nil;
						archiveErrorCode = error.code;
						if (!ps && !requireHit) {
							fallback = true;
							MTLRenderPipelineDescriptor* cold = [mtlRPLDesc copy];
							cold.binaryArchives = nil;
							@synchronized (mtlDev) {
								[mtlDev newRenderPipelineStateWithDescriptor:cold
									completionHandler:^(id<MTLRenderPipelineState> normal, NSError* normalError) {
										mvkLinkOperationEnd(operation);
							bool isLate = compileComplete(normal, normalError);
										if (isLate) destroy();
									}];
							}
							[cold release];
						} else {
							mvkLinkOperationEnd(operation);
							bool isLate = compileComplete(ps, error);
							if (isLate) destroy();
						}
					}];
			} else [mtlDev newRenderPipelineStateWithDescriptor: mtlRPLDesc
									   completionHandler: ^(id<MTLRenderPipelineState> ps, NSError* error) {
										   mvkLinkOperationEnd(operation);
							bool isLate = compileComplete(ps, error);
										   if (isLate) { destroy(); }
									   }];
		}
	});
	// On this Intel macOS AMD driver, a pipeline state created directly from a
	// binary archive keeps that archive file mapped for the state's lifetime.
	// Thousands of per-pipeline shards therefore exhaust memory. The successful
	// archive creation warms Metal's in-process native cache; immediately create
	// the retained state again without an archive, which is a cheap cache hit and
	// no longer pins the shard. Preserve the archive-backed state on any failure.
	bool shouldRehydrate = loaded && _mtlRenderPipelineState &&
		getenv("MVK_AMD_RENDER_ARCHIVE_REHYDRATE") &&
		!strcmp(getenv("MVK_AMD_RENDER_ARCHIVE_REHYDRATE"), "1");
	if (shouldRehydrate) {
		MTLRenderPipelineDescriptor* detachedDesc = [mtlRPLDesc copy];
		detachedDesc.binaryArchives = nil;
		NSError* detachedError = nil;
		uint64_t detachedStart = mvkGetTimestamp();
		id<MTLRenderPipelineState> detachedState = nil;
		@synchronized (getMTLDevice()) {
			detachedState = [getMTLDevice() newRenderPipelineStateWithDescriptor:detachedDesc
				error:&detachedError];
		}
		rehydrateMS = mvkGetElapsedNanoseconds(detachedStart) / 1e6;
		rehydrateErrorCode = detachedError.code;
		if (detachedState) {
			[_mtlRenderPipelineState release];
			_mtlRenderPipelineState = detachedState;
			rehydrated = true;
		}
		[detachedDesc release];
	}
	// Metal does not consistently copy a render descriptor's diagnostic label
	// to the immutable pipeline state on Intel macOS. Preserve the shader-pair
	// identity explicitly so failure snapshots and selected counter captures do
	// not contain anonymous graphics pipelines.
	if (_mtlRenderPipelineState && mtlRPLDesc.label.length)
		objc_setAssociatedObject(_mtlRenderPipelineState, mvkPipelineTraceLabelKey(),
			mtlRPLDesc.label, OBJC_ASSOCIATION_COPY_NONATOMIC);
	// MTLRenderPipelineState is immutable and owns everything needed for use.
	// Vulkan pipeline objects keep this descriptor alive, so leaving the
	// per-request archive attached would pin one mapped .metalar file for every
	// cache hit until the Vulkan pipeline is destroyed.
	if (loaded) mtlRPLDesc.binaryArchives = nil;
	double pipelineMS = mvkGetElapsedNanoseconds(started) / 1e6 - loadMS;
	uint64_t publishStart = mvkGetTimestamp();
	bool published = shardPath && !loaded && !requireHit && _mtlRenderPipelineState &&
		mvkStoreRenderShard(getMTLDevice(), mtlRPLDesc, shardPath);
	if (useShards && mvkRuntimeEnvFlagEnabled("MVK_AMD_RENDER_ARCHIVE_TRACE"))
		mvkWriteRuntimeTrace(getMVKConfig(), @"render-archive", @{
			@"shard":shardPath.lastPathComponent ?: @"", @"loaded":@(loaded),
			@"strictArchiveHit":@(strictHit), @"requireHit":@(requireHit),
			@"fallback":@(fallback), @"archiveErrorCode":@(archiveErrorCode),
			@"rehydrated":@(rehydrated), @"rehydrateMilliseconds":@(rehydrateMS),
			@"rehydrateErrorCode":@(rehydrateErrorCode),
			@"published":@(published), @"pipelineCreated":@(_mtlRenderPipelineState != nil),
			@"loadMilliseconds":@(loadMS), @"pipelineMilliseconds":@(pipelineMS),
			@"publishMilliseconds":@(mvkGetElapsedNanoseconds(publishStart) / 1e6)});

	if (mvkRuntimeTraceEnabled(getMVKConfig()) && (!mvkRuntimeReplayOnly() || !_mtlRenderPipelineState))
		mvkWriteRuntimeTrace(getMVKConfig(), mvkRuntimeReplayOnly() ? @"pipeline-failure" : @"pipeline", @{@"kind":@"vertex",@"vertex":mvkTraceFunction(mtlRPLDesc.vertexFunction),@"fragment":mvkTraceFunction(mtlRPLDesc.fragmentFunction),@"descriptor":mtlRPLDesc.description?:@"",@"created":@(_mtlRenderPipelineState!=nil),@"error":_compileError.localizedDescription?:@"",@"errorCode":@(_compileError.code)});
	return [_mtlRenderPipelineState retain];
}

#if MVK_XCODE_14
id<MTLRenderPipelineState> MVKRenderPipelineCompiler::newMTLRenderPipelineState(MTLMeshRenderPipelineDescriptor* mtlRPLDesc) {
    if (mvkWorkTraceConfigured()) mtlRPLDesc.label = [NSString stringWithFormat:@"obj=%@;mesh=%@;fs=%@", mtlRPLDesc.objectFunction.name ?: @"", mtlRPLDesc.meshFunction.name ?: @"", mtlRPLDesc.fragmentFunction.name ?: @""];
	const char* syncOption = getenv("MVK_AMD_SYNC_MESH_PIPELINES");
	bool synchronousMesh = getPhysicalDevice()->isAMDHardware() && syncOption && !strcmp(syncOption, "1");

	unique_lock<mutex> lock(_completionLock);
	VkResult previousResult = _owner->getConfigurationResult();

	compile(lock, ^{
		auto mtlDev = _owner->getMTLDevice();
		// Waiting for another mesh link must not monopolize the device
		// monitor needed by unrelated shader-library and compute work.
		// Keep mesh submissions serialized through their completion callback.
		dispatch_semaphore_t linkGate = mvkGetPipelineLinkGate(getPhysicalDevice()->isAMDHardware());
		if (linkGate) dispatch_semaphore_wait(linkGate,DISPATCH_TIME_FOREVER);
		if (mvkMeshDifferentialEnabled()) {
			static std::atomic<unsigned> submits{0};
			if (submits.fetch_add(1)<64) mvkWriteRuntimeTrace(getMVKConfig(),@"mesh-link-differential",@{
				@"case":@"original-submit",@"timeNS":@(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)),
				@"activeOperations":mvkLinkOperationSnapshot(),@"deviceIdentity":mvkMeshIdentity(mtlDev),
				@"object":mvkTraceFunction(mtlRPLDesc.objectFunction),@"mesh":mvkTraceFunction(mtlRPLDesc.meshFunction),@"fragment":mvkTraceFunction(mtlRPLDesc.fragmentFunction)});
		}
		if (synchronousMesh) {
			// Public API control matching the successful diagnostic rebuild.
			// Preserve the complete descriptor, native result and timeout;
			// this is a first attempt, not a retry or a fabricated success.
			// Do not hold the device monitor across a blocking driver call.
			NSError* error = nil;
			id<MTLRenderPipelineState> ps = [mtlDev newRenderPipelineStateWithMeshDescriptor:mtlRPLDesc
				options:MTLPipelineOptionNone reflection:nil error:&error];
			if (linkGate) dispatch_semaphore_signal(linkGate);
			bool isLate = compileComplete(ps, error);
			[ps release];
			if (isLate) { destroy(); }
			return;
		}
		@synchronized (mtlDev) {
			[mtlDev newRenderPipelineStateWithMeshDescriptor: mtlRPLDesc
													 options: MTLPipelineOptionNone
										   completionHandler: ^(id<MTLRenderPipelineState> ps, MTLRenderPipelineReflection *refl, NSError* error) {
				if (linkGate) dispatch_semaphore_signal(linkGate);
				bool isLate = compileComplete(ps, error);
				if (isLate) { destroy(); }
			}];
		}
	});

	if (mvkRuntimeTraceEnabled(getMVKConfig()) && (!mvkRuntimeReplayOnly() || !_mtlRenderPipelineState))
		mvkWriteRuntimeTrace(getMVKConfig(), mvkRuntimeReplayOnly() ? @"pipeline-failure" : @"pipeline", @{@"kind":@"mesh",@"linkCreationAPI":synchronousMesh ? @"synchronous" : @"asynchronous",@"object":mvkTraceFunction(mtlRPLDesc.objectFunction),@"mesh":mvkTraceFunction(mtlRPLDesc.meshFunction),@"fragment":mvkTraceFunction(mtlRPLDesc.fragmentFunction),@"descriptor":mtlRPLDesc.description?:@"",@"created":@(_mtlRenderPipelineState!=nil),@"error":_compileError.localizedDescription?:@"",@"errorCode":@(_compileError.code)});
	if (!_mtlRenderPipelineState && _compileError.code == 2 &&
		[_compileError.localizedDescription containsString:@"fragment input"] && getPhysicalDevice()->isAMDHardware()) {
		mvkDiagnoseMeshLink(getMTLDevice(),mtlRPLDesc,mvkGetPipelineLinkGate(true),^(NSDictionary* row) {
			mvkWriteRuntimeTrace(getMVKConfig(),@"mesh-link-differential",row);
		});
	}
	if (!_mtlRenderPipelineState && _compileError.code == 2 &&
		[_compileError.localizedDescription containsString:@"fragment input"] && getPhysicalDevice()->isAMDHardware()) {
		_mtlRenderPipelineState = mvkReplayFailedMesh(getMTLDevice(),mtlRPLDesc,getMVKConfig());
		if (_mtlRenderPipelineState && previousResult == VK_SUCCESS) _owner->clearConfigurationResult();
	}
	return [_mtlRenderPipelineState retain];
}
#endif

bool MVKRenderPipelineCompiler::compileComplete(id<MTLRenderPipelineState> mtlRenderPipelineState, NSError* compileError) {
	lock_guard<mutex> lock(_completionLock);

	_mtlRenderPipelineState = [mtlRenderPipelineState retain];		// retained
	return endCompile(compileError);
}

#pragma mark Construction

MVKRenderPipelineCompiler::~MVKRenderPipelineCompiler() {
	[_mtlRenderPipelineState release];
}


#pragma mark -
#pragma mark MVKComputePipelineCompiler

id<MTLComputePipelineState> MVKComputePipelineCompiler::newMTLComputePipelineState(MTLComputePipelineDescriptor* plDesc) {
	unique_lock<mutex> lock(_completionLock);
    if (mvkGPUTimeoutTraceEnabled()) mvkWriteRuntimeTrace(getMVKConfig(), @"compute-map", @{@"pipelineKey":plDesc.label ?: @"", @"function":mvkTraceFunction(plDesc.computeFunction), @"maxThreads":@(plDesc.maxTotalThreadsPerThreadgroup), @"fullSubgroups":@(plDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth)});

	static std::atomic<uint64_t> computeRequestSequence{0};
	NSNumber* request = @(computeRequestSequence.fetch_add(1));
    NSString* shardPath = getPhysicalDevice()->isAMDHardware() ? mvkComputeShardPath(plDesc) : nil;
    uint64_t shardStart = shardPath ? mvkGetTimestamp() : 0;
    bool shardLoaded = shardPath && mvkLoadComputeShard(getMTLDevice(), plDesc, shardPath);
    double loadMS = shardPath ? mvkGetElapsedNanoseconds(shardStart) / 1e6 : 0;
    bool requireHit = shardPath && getenv("MVK_AMD_COMPUTE_ARCHIVE_REQUIRE_HIT") &&
        !strcmp(getenv("MVK_AMD_COMPUTE_ARCHIVE_REQUIRE_HIT"), "1");
	bool rehydrated = false;
	double rehydrateMS = 0;
	NSInteger rehydrateErrorCode = 0;

	compile(lock, ^{
		auto mtlDev = getMTLDevice();
        // Same lock ordering as render archives: private archive lock only
        // during synchronous add/serialize; device monitor for submission only.
        if (!shardPath) mvkPrepareComputeBinaryArchive(mtlDev, plDesc, getPhysicalDevice()->isAMDHardware());
		uint64_t operation=mvkLinkOperationBegin(@"compute-pipeline",plDesc.label);
		@synchronized (mtlDev) {
			if (mvkRuntimeTraceEnabled(getMVKConfig()) && !mvkRuntimeReplayOnly()) mvkWriteRuntimeTrace(getMVKConfig(), @"compute-request", @{@"request":request,@"time":@([NSDate timeIntervalSinceReferenceDate]),@"function":mvkTraceFunction(plDesc.computeFunction),@"maxThreads":@(plDesc.maxTotalThreadsPerThreadgroup),@"fullSubgroups":@(plDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth),@"descriptor":plDesc.description?:@""});
			[mtlDev newComputePipelineStateWithDescriptor: plDesc
												  options: requireHit ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone
										completionHandler: ^(id<MTLComputePipelineState> ps, MTLComputePipelineReflection*, NSError* error) {
				if (mvkRuntimeTraceEnabled(getMVKConfig()) && (!mvkRuntimeReplayOnly() || !ps)) mvkWriteRuntimeTrace(getMVKConfig(), mvkRuntimeReplayOnly() ? @"compute-failure" : @"compute-result", @{@"request":request,@"time":@([NSDate timeIntervalSinceReferenceDate]),@"function":mvkTraceFunction(plDesc.computeFunction),@"created":@(ps!=nil),@"error":error.localizedDescription?:@"",@"errorCode":@(error.code)});
											mvkLinkOperationEnd(operation);
				bool isLate = compileComplete(ps, error);
											if (isLate) { destroy(); }
										}];
		}
	});
    bool shouldRehydrate = shardLoaded && _mtlComputePipelineState &&
        getenv("MVK_AMD_COMPUTE_ARCHIVE_REHYDRATE") &&
        !strcmp(getenv("MVK_AMD_COMPUTE_ARCHIVE_REHYDRATE"), "1");
    if (shouldRehydrate) {
        MTLComputePipelineDescriptor* detachedDesc = [plDesc copy];
        detachedDesc.binaryArchives = nil;
        NSError* detachedError = nil;
        uint64_t detachedStart = mvkGetTimestamp();
        id<MTLComputePipelineState> detachedState = nil;
        @synchronized (getMTLDevice()) {
            detachedState = [getMTLDevice() newComputePipelineStateWithDescriptor:detachedDesc
                options:MTLPipelineOptionNone reflection:nil error:&detachedError];
        }
        rehydrateMS = mvkGetElapsedNanoseconds(detachedStart) / 1e6;
        rehydrateErrorCode = detachedError.code;
        if (detachedState) {
            [_mtlComputePipelineState release];
            _mtlComputePipelineState = detachedState;
            rehydrated = true;
        }
        [detachedDesc release];
    }
    // The Vulkan pipeline keeps this descriptor alive after the immutable
    // compute pipeline state has been created. Drop the request-local archive
    // so its file mapping does not live for the lifetime of the Vulkan object.
    if (shardLoaded) plDesc.binaryArchives = nil;
    bool shardPublished = false;
    uint64_t publishStart = shardPath ? mvkGetTimestamp() : 0;
    if (shardPath && !shardLoaded && !requireHit && _mtlComputePipelineState)
        shardPublished = mvkStoreComputeShard(getMTLDevice(), plDesc, shardPath);
    if (shardPath && mvkRuntimeEnvFlagEnabled("MVK_AMD_COMPUTE_ARCHIVE_TRACE"))
        mvkWriteRuntimeTrace(getMVKConfig(), @"compute-archive", @{
            @"request":request, @"key":plDesc.label ?: @"", @"loaded":@(shardLoaded),
            @"published":@(shardPublished), @"requireHit":@(requireHit),
            @"pipelineCreated":@(_mtlComputePipelineState != nil), @"loadMilliseconds":@(loadMS),
            @"rehydrated":@(rehydrated), @"rehydrateMilliseconds":@(rehydrateMS),
            @"rehydrateErrorCode":@(rehydrateErrorCode),
            @"postCompilePublishMilliseconds":@(mvkGetElapsedNanoseconds(publishStart) / 1e6)});
	return [_mtlComputePipelineState retain];
}

bool MVKComputePipelineCompiler::compileComplete(id<MTLComputePipelineState> mtlComputePipelineState, NSError* compileError) {
	lock_guard<mutex> lock(_completionLock);

	_mtlComputePipelineState = [mtlComputePipelineState retain];		// retained
	return endCompile(compileError);
}

#pragma mark Construction

MVKComputePipelineCompiler::~MVKComputePipelineCompiler() {
	[_mtlComputePipelineState release];
}


#pragma mark -
#pragma mark Support functions

// Validate that the Cereal Archive covers the entire struct, to ensure consistency and accuracy.
// Ideally this should be a compile-time validation, but that doesn't appear to be possible, so we
// validate by serializing a struct and seeing if all the bytes of the struct have been serialized.
// Since sizeof() also includes gaps between the struct members, padByteCnt can be used to specify
// the amount of padding in the struct. This function works best for simple data structs. Care should
// be taken with structs that contain strings or collections, as streaming size depends on contents,
// and potentially an upgrade to the stdc++ library. Changes to basic struct sizes may affect the
// padding of aggregate structs that contain them.
template<class C>
static size_t mvkValidateCerealArchiveSize(size_t padByteCnt = 0) {
	int64_t missingBytes = 0;
#if MVK_USE_CEREAL
	mvk::countbuf cb;
	ostream outStream(&cb);
	cereal::BinaryOutputArchive writer(outStream);
	C obj = C();
	writer(obj);
	missingBytes = int64_t(sizeof(C)) - int64_t(cb.buffSize + padByteCnt);
	if (missingBytes) {
		printf("[MVK-BUILD-ERROR] Cereal serialization Archive for %s is not completely defined."
			   " Missing %lld bytes. Struct size is %zu (including an expected %zu bytes of padding)"
			   " and Cereal Archive size is %zu. The Cereal Archive definition may be missing members.\n",
			   mvk::getTypeName(&obj).c_str(), missingBytes, sizeof(C), padByteCnt, cb.buffSize);
	}
#endif
	return missingBytes;
}

void mvkValidateCeralArchiveDefinitions() {
	[[maybe_unused]] size_t missingBytes = 0;
	missingBytes += mvkValidateCerealArchiveSize<SPIRV_CROSS_NAMESPACE::CompilerMSL::Options>(9);
	missingBytes += mvkValidateCerealArchiveSize<SPIRV_CROSS_NAMESPACE::MSLShaderInterfaceVariable>(3);
	missingBytes += mvkValidateCerealArchiveSize<SPIRV_CROSS_NAMESPACE::MSLResourceBinding>();
	missingBytes += mvkValidateCerealArchiveSize<SPIRV_CROSS_NAMESPACE::MSLConstexprSampler>();
	missingBytes += mvkValidateCerealArchiveSize<mvk::SPIRVWorkgroupSizeDimension>(3);
	missingBytes += mvkValidateCerealArchiveSize<mvk::SPIRVEntryPoint>(20);						// Contains string
	missingBytes += mvkValidateCerealArchiveSize<mvk::SPIRVToMSLConversionOptions>(26);			// Contains string
	missingBytes += mvkValidateCerealArchiveSize<mvk::MSLShaderInterfaceVariable>(6);
	missingBytes += mvkValidateCerealArchiveSize<mvk::MSLResourceBinding>(2);
	missingBytes += mvkValidateCerealArchiveSize<mvk::DescriptorBinding>();
	missingBytes += mvkValidateCerealArchiveSize<mvk::SPIRVToMSLConversionConfiguration>(106);	// Contains collection
	missingBytes += mvkValidateCerealArchiveSize<mvk::SPIRVToMSLConversionResultInfo>(39);		// Contains collection
	missingBytes += mvkValidateCerealArchiveSize<mvk::MSLSpecializationMacroInfo>(22);			// Contains string
	missingBytes += mvkValidateCerealArchiveSize<MVKShaderModuleKey>();
	missingBytes += mvkValidateCerealArchiveSize<MVKCompressor<std::string>>(20);				// Contains collection
	assert(missingBytes == 0 && "Cereal Archive definitions incomplete. See previous logged errors.");
}
