/*
 * MVKCmdDraw.mm
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

#include "MVKCmdDraw.h"
#include "MVKCommandBuffer.h"
#include "MVKCommandPool.h"
#include "MVKBuffer.h"
#include "MVKPipeline.h"
#include "MVKQueryPool.h"
#include "MVKFoundation.h"
#include "MVKRuntimeTrace.h"
#include "MVKGPUTimestampTrace.h"
#include "MVKQueueDependencyTrace.h"
#include "mvk_datatypes.hpp"


#pragma mark -
#pragma mark MVKCmdBindVertexBuffers

template<class Bits>
static uint32_t mvkCountTraceBits(const Bits& bits) {
	uint32_t count = 0;
	for (auto word : bits.setBitsList()) {
		for (auto bit : word) { (void)bit; ++count; }
	}
	return count;
}

struct MVKDrawResourceTraceCounts {
	uint32_t buffers = 0;
	uint32_t textures = 0;
	uint32_t samplers = 0;
	uint32_t descriptorSets = 0;
	uint32_t vertexBuffers = 0;
	uint64_t vertexBytes = 0;
};

static MVKDrawResourceTraceCounts mvkDrawResourceTraceCounts(MVKCommandEncoder* cmdEncoder) {
	MVKDrawResourceTraceCounts result;
	auto add = [&](const MVKStageResourceBits& stage) {
		result.buffers += mvkCountTraceBits(stage.buffers);
		result.textures += mvkCountTraceBits(stage.textures);
		result.samplers += mvkCountTraceBits(stage.samplers);
		result.descriptorSets += mvkCountTraceBits(stage.descriptorSetData);
	};
	auto& exists = cmdEncoder->getMtlGraphics()._exists;
	add(exists.vertex());
	add(exists.fragment());
#if MVK_XCODE_14
	add(exists.object());
	add(exists.mesh());
#endif
	for (const auto& binding : cmdEncoder->getVkGraphics()._vertexBuffers) {
		id<MTLBuffer> buffer = binding.mtlBuffer;
		if (!buffer) { continue; }
		++result.vertexBuffers;
		uint64_t length = buffer.length;
		uint64_t available = binding.offset < length ? length - binding.offset : 0;
		uint64_t requested = binding.size;
		result.vertexBytes += std::min<uint64_t>(available, requested);
	}
	return result;
}

static void mvkRecordDrawMetadata(MVKCommandEncoder* cmdEncoder,
							  id<MTLRenderCommandEncoder> encoder,
							  NSString* mode,
							  uint32_t elements,
							  uint32_t instances,
							  bool indexed) {
	if (!mvkEncoderWorkTraceEnabled()) { return; }
	auto counts = mvkDrawResourceTraceCounts(cmdEncoder);
	auto& index = cmdEncoder->getVkGraphics()._indexBuffer;
	id<MTLRenderPipelineState> pipeline = cmdEncoder->getMtlGraphics()._pipeline;
	NSString* label = [NSString stringWithFormat:
		@"mode=%@;pipeline=%@;elements=%u;instances=%u;buffers=%u;textures=%u;samplers=%u;sets=%u;vertexBuffers=%u;vertexBytes=%llu;index=%p;indexOffset=%llu;indexSize=%llu",
		mode ?: @"", mvkPipelineTraceLabel(pipeline), elements, instances,
		counts.buffers, counts.textures, counts.samplers, counts.descriptorSets,
		counts.vertexBuffers, (unsigned long long)counts.vertexBytes,
		indexed ? index.mtlBuffer : nil,
		(unsigned long long)(indexed ? index.offset : 0),
		(unsigned long long)(indexed ? index.size : 0)];
	mvkRecordEncoderWorkImpl(encoder, @"draw", label);
}

template <size_t N>
VkResult MVKCmdBindVertexBuffers<N>::setContent(MVKCommandBuffer* cmdBuff,
												uint32_t firstBinding,
												uint32_t bindingCount,
												const VkBuffer* pBuffers,
												const VkDeviceSize* pOffsets,
												const VkDeviceSize* pSizes,
												const VkDeviceSize* pStrides) {
	_firstBinding = firstBinding;
	_bindings.clear();	// Clear for reuse
    _bindings.reserve(bindingCount);
    MVKVertexMTLBufferBinding b;
    for (uint32_t bindIdx = 0; bindIdx < bindingCount; bindIdx++) {
        MVKBuffer* mvkBuffer = (MVKBuffer*)pBuffers[bindIdx];
        if (mvkBuffer) {
            b.mtlBuffer = mvkBuffer->getMTLBuffer();
            b.offset = mvkBuffer->getMTLBufferOffset() + pOffsets[bindIdx];
            b.size = pSizes ? uint32_t(pSizes[bindIdx] == VK_WHOLE_SIZE ? mvkBuffer->getByteCount() - pOffsets[bindIdx] : pSizes[bindIdx]) : 0;
        } else {
            b.mtlBuffer = nullptr;
            b.offset = 0;
            b.size = 0;
        }
		b.stride = pStrides ? (uint32_t)pStrides[bindIdx] : 0;
        _bindings.push_back(b);
    }

	return VK_SUCCESS;
}

template <size_t N>
void MVKCmdBindVertexBuffers<N>::encode(MVKCommandEncoder* cmdEncoder) {
	cmdEncoder->getState().bindVertexBuffers(_firstBinding, _bindings.contents());
}

template class MVKCmdBindVertexBuffers<1>;
template class MVKCmdBindVertexBuffers<2>;
template class MVKCmdBindVertexBuffers<8>;


#pragma mark -
#pragma mark MVKCmdBindIndexBuffer

VkResult MVKCmdBindIndexBuffer::setContent(MVKCommandBuffer* cmdBuff,
										   VkBuffer buffer,
										   VkDeviceSize offset,
										   VkIndexType indexType) {
	return setContent(cmdBuff, buffer, offset, VK_WHOLE_SIZE, indexType);
}

VkResult MVKCmdBindIndexBuffer::setContent(MVKCommandBuffer* cmdBuff,
										   VkBuffer buffer,
										   VkDeviceSize offset,
										   VkDeviceSize size,
										   VkIndexType indexType) {
	_binding.vkIndexType = indexType;
	_binding.mtlIndexType = mvkMTLIndexTypeFromVkIndexType(indexType);

	MVKBuffer* mvkBuffer = (MVKBuffer*)buffer;
	if (mvkBuffer) {
		_binding.mtlBuffer = mvkBuffer->getMTLBuffer();
		_binding.offset = mvkBuffer->getMTLBufferOffset() + offset;
		_binding.size = size == VK_WHOLE_SIZE ? mvkBuffer->getByteCount() - offset : size;
	} else {
		_binding.mtlBuffer = nullptr;
		// Must be 0 for null buffer.
		_binding.offset = 0;
		_binding.size = size == VK_WHOLE_SIZE ? mvkMTLIndexTypeSizeInBytes((MTLIndexType)_binding.mtlIndexType) : size;
	}

	return VK_SUCCESS;
}

void MVKCmdBindIndexBuffer::encode(MVKCommandEncoder* cmdEncoder) {
    if (_binding.mtlBuffer == nullptr) {
        // In the null buffer case, offset must be 0, and since we don't support nullDescriptor, the indices are undefined.
        // Thus, we can use a simple temporary buffer to stand in for the index buffer here.
        const auto* placeholderBuffer = cmdEncoder->getTempMTLBuffer(_binding.size);
        _binding.mtlBuffer = placeholderBuffer->_mtlBuffer;
        _binding.offset = placeholderBuffer->_offset;
    } else if (_binding.vkIndexType == VK_INDEX_TYPE_UINT8) {
        // Copy 8-bit indices into 16-bit index buffer compatible with Metal.
        const auto numIndices = _binding.size;
        auto* uint16Buf = cmdEncoder->getTempMTLBuffer(numIndices * 2);

        cmdEncoder->encodeStoreActions(true);

        // Determine the number of full threadgroups we can dispatch to cover the buffer content efficiently.
        // Some GPU's report different values for max threadgroup width between the pipeline state and device,
        // so conservatively use the minimum of these two reported values.
        id<MTLComputePipelineState> cps = cmdEncoder->getCommandEncodingPool()->getConvertUint8IndicesMTLComputePipelineState();
        NSUInteger tgWidth = std::min(cps.maxTotalThreadsPerThreadgroup, cmdEncoder->getMTLDevice().maxThreadsPerThreadgroup.width);
        NSUInteger tgCount = numIndices / tgWidth;

        MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
        id<MTLComputeCommandEncoder> mtlComputeEnc = cmdEncoder->getMTLComputeEncoder(kMVKCommandConvertUint8Indices);
        state.bindPipeline(mtlComputeEnc, cps);
        state.bindBuffer(mtlComputeEnc, _binding.mtlBuffer, _binding.offset, 0);
        state.bindBuffer(mtlComputeEnc, uint16Buf->_mtlBuffer, 0, 1);

        // Run as many full threadgroups as will fit into the buffer content.
        if (tgCount > 0) {
            [mtlComputeEnc dispatchThreadgroups: MTLSizeMake(tgCount, 1, 1)
                           threadsPerThreadgroup: MTLSizeMake(tgWidth, 1, 1)];
        }

        // If there is left-over buffer content after running full threadgroups, or if the buffer content
        // fits within a single threadgroup, run a single partial threadgroup of the appropriate size.
        auto remainderIndexCount = numIndices % tgWidth;
        if (remainderIndexCount > 0) {
            if (tgCount > 0) {
                const auto indicesConverted = tgCount * tgWidth;
                state.bindBuffer(mtlComputeEnc, _binding.mtlBuffer, _binding.offset + indicesConverted, 0);
                state.bindBuffer(mtlComputeEnc, uint16Buf->_mtlBuffer, indicesConverted * 2, 1);
            }
            [mtlComputeEnc dispatchThreadgroups: MTLSizeMake(1, 1, 1)
                           threadsPerThreadgroup: MTLSizeMake(remainderIndexCount, 1, 1)];
        }

        // Running this stage prematurely ended the render pass, so we have to start it up again.
        cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);

        _binding.mtlBuffer = uint16Buf->_mtlBuffer;
        _binding.offset = uint16Buf->_offset;
    }

    cmdEncoder->getState().bindIndexBuffer(_binding);
}

#pragma mark -

/* Describes the draw parameters for mesh pipelines. Must match the DrawInfo struct SPIRV-Cross
 * declares for the geometry-shader object stage, and MVKGeometryDrawInfo in the command shaders. */
struct DrawInfo {
	int32_t indexed;
	int32_t indexSize;
	uint64_t indexBuffer;
	int32_t baseVertex;      // firstVertex (non-indexed) or vertexOffset (indexed)
	uint32_t baseInstance;
	uint32_t vertexStrides[kMVKMaxBufferCount];  // by Metal vertex buffer index
	uint32_t vertexDivisors[kMVKMaxBufferCount]; // by Metal vertex buffer index: kMVKGeometryPerVertex or instance divisor
	uint8_t topoStrip;
	uint32_t primitiveBase;
	uint32_t primitiveCount;
	uint32_t instanceBase;
};
static_assert(kMVKMaxBufferCount == 31, "DrawInfo.vertexStrides must match the SPIRV-Cross object stage");
static_assert(offsetof(DrawInfo, primitiveBase) == 276 && offsetof(DrawInfo, primitiveCount) == 280 && offsetof(DrawInfo, instanceBase) == 284 && sizeof(DrawInfo) == 288,
              "DrawInfo must match generated MSL and indirect conversion");

/* Sets the vertex buffer strides the geometry-shader object stage fetches vertices with: the
 * strides bound with vkCmdBindVertexBuffers2 when the pipeline has dynamic strides, else the
 * pipeline's binding strides. */
static void setGeometryVertexStrides(DrawInfo& drawInfo, MVKCommandEncoder* cmdEncoder, MVKGraphicsPipeline* pipeline) {
	bool dynamicStride = pipeline->getDynamicStateFlags().has(MVKRenderStateFlag::VertexStride);
	const auto& vkState = cmdEncoder->getVkGraphics();
	for (size_t vkIdx : pipeline->getVkVertexBuffers()) {
		uint32_t mtlIdx = pipeline->getMetalBufferIndexForVertexAttributeBinding((uint32_t)vkIdx);
		if (mtlIdx >= kMVKMaxBufferCount) { continue; }
		drawInfo.vertexStrides[mtlIdx] = dynamicStride ? vkState._vertexBuffers[vkIdx].stride
		                                               : pipeline->getVkVertexBindingStride((uint32_t)vkIdx);
		drawInfo.vertexDivisors[mtlIdx] = pipeline->getVkVertexBindingDivisor((uint32_t)vkIdx);
	}
}

/* How the bound topology assembles the geometry shader's input primitives. Must match the values of
 * DrawInfo::topoStrip the SPIRV-Cross object stage tests, and MVKGeometryIndirectParams::topology. */
enum MVKGeometryTopology : uint32_t {
	kMVKGeometryTopologyList = 0,
	kMVKGeometryTopologyStrip = 1,
	kMVKGeometryTopologyFan = 2,
};

/* Returns the vertices per input primitive of the geometry shader and how the bound topology assembles
 * them, or false if the primitive type cannot be drawn with a geometry shader. */
static bool getGeometryPrimitiveShape(MVKCommandEncoder* cmdEncoder, MVKGraphicsPipeline* pipeline,
									  uint32_t& vertsPerPrim, MVKGeometryTopology& topology) {
	auto& mtlGraphics = cmdEncoder->getMtlGraphics();
	auto primitiveType = mtlGraphics.getPrimitiveType();
	switch (primitiveType) {
		case MTLPrimitiveTypePoint:
		case MTLPrimitiveTypeLine:          topology = kMVKGeometryTopologyList; break;
		case MTLPrimitiveTypeTriangle:      topology = mtlGraphics.isTriangleFan() ? kMVKGeometryTopologyFan : kMVKGeometryTopologyList; break;
		case MTLPrimitiveTypeLineStrip:
		case MTLPrimitiveTypeTriangleStrip: topology = kMVKGeometryTopologyStrip; break;
		default:
			cmdEncoder->reportMessage(MVK_CONFIG_LOG_LEVEL_ERROR, "Unsupported primitive type %lu with a geometry shader.", (unsigned long)primitiveType);
			return false;
	}
	vertsPerPrim = pipeline->getGeometryInputVertexCount();
	return vertsPerPrim > 0;
}

/* Returns the number of geometry shader input primitives in a draw of the given number of vertices. */
static uint32_t getGeometryPrimitiveCount(uint32_t vertexCount, uint32_t vertsPerPrim, MVKGeometryTopology topology) {
	switch (topology) {
		case kMVKGeometryTopologyList:  return vertexCount / vertsPerPrim;
		case kMVKGeometryTopologyFan:   return vertexCount >= 3 ? vertexCount - 2 : 0;
		case kMVKGeometryTopologyStrip:
			if (vertsPerPrim == 6) { return vertexCount >= 6 ? (vertexCount - 4) / 2 : 0; }	// Triangle strip with adjacency
			return vertexCount >= vertsPerPrim ? vertexCount - vertsPerPrim + 1 : 0;
	}
	return 0;
}

#if MVK_XCODE_14
/* Parameters of the compute pass that converts indirect draws for geometry-shader (mesh) pipelines.
 * Must match MVKGeometryIndirectParams in the command shaders. */
struct GeometryIndirectParams {
	uint64_t indexBuffer;    // GPU address of the bound index buffer at its binding offset
	uint32_t indexed;
	uint32_t indexSize;
	uint32_t vertsPerPrim;
	uint32_t topology;       // MVKGeometryTopology
	uint32_t batchCount;     // Number of ordinary indirect mesh commands per Vulkan draw.
	uint32_t vertexStrides[kMVKMaxBufferCount];
	uint32_t vertexDivisors[kMVKMaxBufferCount];
};
static_assert(offsetof(GeometryIndirectParams, vertexStrides) == 28 && sizeof(GeometryIndirectParams) == 280,
              "GeometryIndirectParams must match the GPU converter");

// Timed diagnostics for one selected geometry pipeline. These snapshots contain only public Metal
// resource metadata and generated draw arguments; no vertex, index, texture, or descriptor content.
static bool mvkTraceSelectedGeometryPipeline(MVKCommandEncoder* cmdEncoder) {
	if (!mvkGPUTimestampArmed()) { return false; }
	const char* selected = getenv("MVK_AMD_GEOMETRY_DRAW_TRACE_LABEL");
	if (!selected || !selected[0]) { return false; }
	id<MTLRenderPipelineState> state = cmdEncoder->getMtlGraphics()._pipeline;
	NSString* label = state.label ?: @"";
	return (!strcmp(selected, "*")) || [label containsString:@(selected)];
}

static bool mvkTraceEverySelectedGeometryDraw() {
	const char* selected = getenv("MVK_AMD_GEOMETRY_DRAW_TRACE_LABEL");
	return selected && !strcmp(selected, "*");
}

static NSDictionary* mvkGeometryResourceMetadata(MVKCommandEncoder* cmdEncoder) {
	NSMutableArray* objectBuffers = [NSMutableArray array];
	NSMutableArray* objectTextures = [NSMutableArray array];
	NSMutableArray* vertexBuffers = [NSMutableArray array];
	auto& mtl = cmdEncoder->getMtlGraphics();
	const auto& objectExists = mtl._exists.object();
	const auto& objectBindings = mtl._bindings.object();
	for (uint32_t idx = 0; idx < kMVKMaxBufferCount; ++idx) {
		if (!objectExists.buffers.get(idx)) { continue; }
		const auto& binding = objectBindings.buffers[idx];
		id<MTLBuffer> buffer = binding.buffer;
		[objectBuffers addObject:buffer ? @{
			@"index":@(idx), @"object":[NSString stringWithFormat:@"%p", buffer],
			@"gpuAddress":@((unsigned long long)buffer.gpuAddress),
			@"offset":@((unsigned long long)binding.offset),
			@"length":@((unsigned long long)buffer.length),
			@"storageMode":@(buffer.storageMode), @"hazardTrackingMode":@(buffer.hazardTrackingMode)
		} : @{@"index":@(idx), @"object":@"nil", @"implicitMarker":@((unsigned long long)binding.offset)}];
	}
	for (uint32_t idx = 0; idx < kMVKMaxTextureCount; ++idx) {
		if (!objectExists.textures.get(idx)) { continue; }
		id<MTLTexture> texture = objectBindings.textures[idx];
		[objectTextures addObject:texture ? @{
			@"index":@(idx), @"object":[NSString stringWithFormat:@"%p", texture],
			@"type":@(texture.textureType), @"pixelFormat":@(texture.pixelFormat),
			@"width":@(texture.width), @"height":@(texture.height), @"depth":@(texture.depth),
			@"arrayLength":@(texture.arrayLength), @"mipLevels":@(texture.mipmapLevelCount),
			@"storageMode":@(texture.storageMode), @"usage":@(texture.usage)
		} : @{@"index":@(idx), @"object":@"nil"}];
	}
	const auto& vk = cmdEncoder->getVkGraphics();
	for (uint32_t idx = 0; idx < kMVKMaxBufferCount; ++idx) {
		const auto& binding = vk._vertexBuffers[idx];
		id<MTLBuffer> buffer = binding.mtlBuffer;
		if (!buffer) { continue; }
		[vertexBuffers addObject:@{
			@"binding":@(idx), @"object":[NSString stringWithFormat:@"%p", buffer],
			@"gpuAddress":@((unsigned long long)buffer.gpuAddress),
			@"offset":@((unsigned long long)binding.offset), @"size":@((unsigned long long)binding.size),
			@"stride":@(binding.stride), @"length":@((unsigned long long)buffer.length)
		}];
	}
	const auto& index = vk._indexBuffer;
	NSDictionary* indexBuffer = index.mtlBuffer ? @{
		@"object":[NSString stringWithFormat:@"%p", index.mtlBuffer],
		@"gpuAddress":@((unsigned long long)index.mtlBuffer.gpuAddress),
		@"offset":@((unsigned long long)index.offset), @"size":@((unsigned long long)index.size),
		@"length":@((unsigned long long)index.mtlBuffer.length), @"indexType":@(index.mtlIndexType)
	} : @{};
	return @{@"objectBuffers":objectBuffers, @"objectTextures":objectTextures,
	         @"vertexBuffers":vertexBuffers, @"indexBuffer":indexBuffer};
}

static NSDictionary* mvkGeometryTraceBase(MVKCommandEncoder* cmdEncoder, NSString* mode) {
	id<MTLRenderPipelineState> state = cmdEncoder->getMtlGraphics()._pipeline;
	return @{
		@"mode":mode, @"pipeline":state.label ?: @"",
		@"commandBuffer":[NSString stringWithFormat:@"%p", cmdEncoder->_mtlCmdBuffer],
		@"resources":mvkGeometryResourceMetadata(cmdEncoder)
	};
}

/* Binds the transform feedback state of the geometry stage for a draw: mode 0 (off), 1 (count the
 * captured vertices of each input primitive) or 2 (write them at the slots computed from the counts).
 * See SPIRV-Cross emit_mesh_wrapper(). */
static void bindGeometryXfb(MVKCommandEncoder* cmdEncoder, MVKGraphicsPipeline* pipeline, uint32_t mode,
							const MVKMTLBufferAllocation* prims) {
	if ( !pipeline->usesGeometryXfb() ) { return; }
	id<MTLRenderCommandEncoder> mtlRendEnc = cmdEncoder->_mtlRenderEncoder;
	const auto& idx = pipeline->getGeometryXfbIndices();
	// Placeholder bindings below are bound at every index of the 4 buffers; the shader declares only
	// the buffers it writes, so binding the others is harmless.
	[mtlRendEnc setMeshBytes: &mode length: sizeof(mode) atIndex: idx.mode];
	// The shader only touches the buffers in modes 1 and 2 and the bound transform feedback buffers,
	// but every buffer argument must be bound (Metal API validation).
	const MVKMTLBufferAllocation* placeholder = nullptr;
	auto bindOrPlaceholder = [&](id<MTLBuffer> mtlBuff, NSUInteger offset, NSUInteger index) {
		if ( !mtlBuff ) {
			if ( !placeholder ) { placeholder = cmdEncoder->getTempMTLBuffer(16, true); }
			mtlBuff = placeholder->_mtlBuffer;
			offset = placeholder->_offset;
		}
		[mtlRendEnc setMeshBuffer: mtlBuff offset: offset atIndex: index];
	};
	const MVKMTLBufferAllocation* session = mode ? cmdEncoder->_xfbSession : nullptr;
	bindOrPlaceholder(session ? session->_mtlBuffer : nil, session ? session->_offset : 0, idx.session);
	bindOrPlaceholder(mode ? prims->_mtlBuffer : nil, mode ? prims->_offset : 0, idx.prims);
	for (uint32_t b = 0; b < kMVKMaxTransformFeedbackBuffers && b <= idx.buffer0; b++) {
		const auto& binding = cmdEncoder->_xfbBindings[b];
		bindOrPlaceholder(mode ? binding.mtlBuffer : nil, binding.offset, idx.buffer0 - b);
	}
}

/* Draws primCount x instanceCount input primitives with a geometry-shader (mesh) pipeline. When the
 * geometry shader captures transform feedback and transform feedback is active, the vertices must be
 * written in primitive order although each input primitive emits a varying number of them: a first
 * pass counts the captured vertices of each primitive (and draws nothing), a compute pass turns the
 * counts into vertex slots (and advances the transform feedback offsets), and a second pass draws and
 * writes the vertices at their slots. indexBuffer is used by the object stage of indexed draws. */
static void encodeGeometryMeshDraw(MVKCommandEncoder* cmdEncoder, MVKGraphicsPipeline* pipeline, const DrawInfo& drawInfo,
								   uint32_t primCount, uint32_t instanceCount, id<MTLBuffer> indexBuffer) {
	const bool traceSelected = mvkTraceSelectedGeometryPipeline(cmdEncoder);
	if (traceSelected) {
		NSMutableDictionary* trace = [mvkGeometryTraceBase(cmdEncoder, @"direct") mutableCopy];
		trace[@"primitiveCount"] = @(primCount);
		trace[@"instanceCount"] = @(instanceCount);
		trace[@"indexed"] = @(indexBuffer != nil);
		trace[@"baseVertex"] = @(drawInfo.baseVertex);
		trace[@"baseInstance"] = @(drawInfo.baseInstance);
		trace[@"topology"] = @(drawInfo.topoStrip);
		trace[@"batchPrimitiveLimit"] = @(std::min<uint32_t>(256, primCount));
		[cmdEncoder->_mtlCmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			NSMutableDictionary* result = [trace mutableCopy];
			result[@"commandBufferStatus"] = @(cb.status);
			result[@"commandBufferError"] = cb.error.localizedDescription ?: @"";
			mvkWriteRuntimeTrace(getGlobalMVKConfig(), @"geometry-draw", result);
			[result release];
		}];
		[trace release];
		mvkRecordEncoderWork(cmdEncoder->_mtlRenderEncoder, @"geometry-direct",
			[NSString stringWithFormat:@"primitives=%u instances=%u indexed=%u", primCount, instanceCount, indexBuffer != nil]);
	}
	auto draw = [&](uint32_t xfbMode, const MVKMTLBufferAllocation* prims) {
		id<MTLRenderCommandEncoder> mtlRendEnc = cmdEncoder->_mtlRenderEncoder;
		if (indexBuffer) { [mtlRendEnc useResource: indexBuffer usage: MTLResourceUsageRead stages: MTLRenderStageObject]; }
		bindGeometryXfb(cmdEncoder, pipeline, xfbMode, prims);
		// On AMD, large object grids in layered geometry emulation have a
		// reproducible output corruption/timeout even with valid owned inputs.
		// Bound each native dispatch, retaining all global Vulkan indices.
		const bool bounded = cmdEncoder->getDevice()->getPhysicalDevice()->isAMDHardware();
		const uint32_t batchLimit = bounded ? std::min<uint32_t>(256, primCount) : primCount;
		const uint32_t instanceLimit = bounded ? std::max<uint32_t>(1, 256 / batchLimit) : instanceCount;
		for (uint64_t firstInstance = 0; firstInstance < instanceCount; ) {
		 uint32_t instances = std::min<uint32_t>(instanceLimit, instanceCount - uint32_t(firstInstance));
		 for (uint64_t first = 0; first < primCount; ) {
			uint32_t count = std::min<uint32_t>(batchLimit, primCount - uint32_t(first));
			DrawInfo batch = drawInfo;
			batch.primitiveBase = uint32_t(first);
			batch.primitiveCount = primCount;
			batch.instanceBase = uint32_t(firstInstance);
			[mtlRendEnc setObjectBytes: &batch length: sizeof(batch) atIndex: pipeline->getDrawInfoBufferIndex()];
			[mtlRendEnc drawMeshThreadgroups: MTLSizeMake(count, instances, 1)
				 threadsPerObjectThreadgroup: MTLSizeMake(1, 1, 1)
				   threadsPerMeshThreadgroup: MTLSizeMake(1, 1, 1)];
			first += count;
		 }
		 firstInstance += instances;
		}
	};

	uint32_t inputPrimCount = primCount * instanceCount;
	if ( !pipeline->usesGeometryXfb() || !cmdEncoder->_xfbSession || !inputPrimCount ) {
		if (inputPrimCount) { draw(0, nullptr); }
		return;
	}

	const MVKMTLBufferAllocation* prims = cmdEncoder->getTempMTLBuffer(inputPrimCount * sizeof(uint32_t), true);
	draw(1, prims);

	cmdEncoder->encodeStoreActions(true);
	MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
	id<MTLComputeCommandEncoder> mtlScanEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTransformFeedback);
	id<MTLComputePipelineState> mtlScanState = cmdEncoder->getCommandEncodingPool()->getCmdXfbScanPrimitivesMTLComputePipelineState();
	const MVKMTLBufferAllocation* session = cmdEncoder->_xfbSession;
	state.bindPipeline(mtlScanEncoder, mtlScanState);
	state.bindBuffer(mtlScanEncoder, prims->_mtlBuffer, prims->_offset, 0);
	state.bindBuffer(mtlScanEncoder, session->_mtlBuffer, session->_offset, 1);
	state.bindStructBytes(mtlScanEncoder, &inputPrimCount, 2);
	// Active transform feedback query (stream 0): the scan adds the primitives written and needed to it.
	uint32_t vertsPerPrim = 0;
	if (cmdEncoder->_xfbQueryPool) {
		vertsPerPrim = pipeline->getGeometryOutputVertexCount();
		state.bindBuffer(mtlScanEncoder, cmdEncoder->_xfbQueryPool->getResultsMTLBuffer(),
						 MVKTransformFeedbackQueryPool::getResultOffset(cmdEncoder->_xfbQuery), 3);
	} else {
		// Not accessed with vertsPerPrim 0, but every buffer argument must be bound.
		state.bindBuffer(mtlScanEncoder, session->_mtlBuffer, session->_offset, 3);
	}
	state.bindStructBytes(mtlScanEncoder, &vertsPerPrim, 4);
	NSUInteger tgSize = std::min<NSUInteger>(1024, mtlScanState.maxTotalThreadsPerThreadgroup);
	[mtlScanEncoder dispatchThreadgroups: MTLSizeMake(1, 1, 1) threadsPerThreadgroup: MTLSizeMake(tgSize, 1, 1)];
	cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);

	cmdEncoder->finalizeDrawState(kMVKGraphicsStageRasterization);	// Ensure all updated state has been submitted to Metal
	if ( !pipeline->hasValidMTLPipelineStates() ) { return; }
	draw(2, prims);
}

/* Encodes indirect draws with a geometry-shader (object + mesh) pipeline: a compute pass turns each
 * Vulkan indirect draw into mesh threadgroup counts and the DrawInfo the object stage reads, then
 * each draw is a drawMeshThreadgroupsWithIndirectBuffer. ibb is null for non-indexed draws. */
static void encodeGeometryIndirectDraws(MVKCommandEncoder* cmdEncoder, MVKGraphicsPipeline* pipeline,
										id<MTLBuffer> mtlIndirectBuffer, VkDeviceSize mtlIndirectBufferOffset,
										uint32_t indirectBufferStride, uint32_t drawCount,
										const MVKIndexMTLBufferBinding* ibb) {
	if (drawCount == 0) { return; }
	// Topology, dynamic strides, and vertex-resource state are materialized
	// during finalization. Reading Metal state before it sees the Vulkan
	// bindings uses the previous/default topology for indirect geometry.
	cmdEncoder->finalizeDrawState(kMVKGraphicsStageRasterization);
	if (!pipeline->hasValidMTLPipelineStates()) { return; }

	uint32_t vertsPerPrim = 0;
	MVKGeometryTopology topology = kMVKGeometryTopologyList;
	if ( !getGeometryPrimitiveShape(cmdEncoder, pipeline, vertsPerPrim, topology) ) { return; }

	GeometryIndirectParams params = {};
	params.indexed = ibb != nullptr;
	params.vertsPerPrim = vertsPerPrim;
	params.topology = topology;
	params.batchCount = 1;
	if (ibb) {
		params.indexSize = (uint32_t)mvkMTLIndexTypeSizeInBytes((MTLIndexType)ibb->mtlIndexType);
		params.indexBuffer = ibb->mtlBuffer.gpuAddress + ibb->offset;
	}
	if (cmdEncoder->getDevice()->getPhysicalDevice()->isAMDHardware()) {
		// Register ordinary indirect commands up front; the GPU fills each
		// command's count. This does not require mesh ICB device support or a
		// CPU readback. Limit encoding overhead and scratch storage. The final
		// command retains every remaining primitive, so a size hint can never
		// truncate a draw (including robust out-of-range index fetches).
		uint64_t capacity = (4ull * 1024 * 1024) / (uint64_t(drawCount) * (sizeof(DrawInfo) + 12));
		params.batchCount = uint32_t(std::min<uint64_t>(64, std::max<uint64_t>(1, capacity)));
	}
	const uint32_t encodedDrawCount = drawCount * params.batchCount;
	DrawInfo strides = {};
	setGeometryVertexStrides(strides, cmdEncoder, pipeline);
	memcpy(params.vertexStrides, strides.vertexStrides, sizeof(params.vertexStrides));
	memcpy(params.vertexDivisors, strides.vertexDivisors, sizeof(params.vertexDivisors));

	// Per draw: MTLDispatchThreadgroupsIndirectArguments (mesh threadgroups) and DrawInfo.
	const VkDeviceSize dispatchSize = sizeof(MTLDispatchThreadgroupsIndirectArguments) * encodedDrawCount;
	const VkDeviceSize drawInfoOffset = mvkAlignByteCount(dispatchSize, 256);
	const VkDeviceSize drawInfoStride = mvkAlignByteCount(sizeof(DrawInfo), 16);
	const MVKMTLBufferAllocation* tempBuff = cmdEncoder->getTempMTLBuffer(drawInfoOffset + drawInfoStride * encodedDrawCount, true);
	const bool traceSelected = mvkTraceSelectedGeometryPipeline(cmdEncoder);
	const bool traceEverySelected = traceSelected && mvkTraceEverySelectedGeometryDraw();
	NSDictionary* traceBase = traceSelected ? [mvkGeometryTraceBase(cmdEncoder, @"indirect") retain] : nil;

	cmdEncoder->encodeStoreActions(true);
	MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
	id<MTLComputeCommandEncoder> mtlConvertEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseDrawIndirectConvertBuffers);
	id<MTLComputePipelineState> mtlConvertState = cmdEncoder->getCommandEncodingPool()->getCmdDrawIndirectGeometryConvertBuffersMTLComputePipelineState();
	uint32_t drawInfoStride32 = (uint32_t)drawInfoStride;
	state.bindPipeline(mtlConvertEncoder, mtlConvertState);
	state.bindBuffer(mtlConvertEncoder, mtlIndirectBuffer,    mtlIndirectBufferOffset,             0);
	state.bindBuffer(mtlConvertEncoder, tempBuff->_mtlBuffer, tempBuff->_offset,                   1);
	state.bindBuffer(mtlConvertEncoder, tempBuff->_mtlBuffer, tempBuff->_offset + drawInfoOffset,  2);
	state.bindStructBytes(mtlConvertEncoder, &indirectBufferStride, 3);
	state.bindStructBytes(mtlConvertEncoder, &drawCount,            4);
	state.bindStructBytes(mtlConvertEncoder, &params,               5);
	state.bindStructBytes(mtlConvertEncoder, &drawInfoStride32,     6);
	[mtlConvertEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide<NSUInteger>(encodedDrawCount, mtlConvertState.threadExecutionWidth), 1, 1)
					  threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
	// The timed selected-pipeline diagnostic copies only the converter's generated dispatch and
	// DrawInfo metadata. It never reads application vertex/index/texture data and never waits on CPU.
	if (traceSelected) {
		NSUInteger bytes = drawInfoOffset + drawInfoStride * encodedDrawCount;
		id<MTLBuffer> readback = [tempBuff->_mtlBuffer.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		id<MTLBlitCommandEncoder> blit = cmdEncoder->getMTLBlitEncoder(kMVKCommandUseDrawIndirectConvertBuffers);
		[blit copyFromBuffer:tempBuff->_mtlBuffer sourceOffset:tempBuff->_offset
		          toBuffer:readback destinationOffset:0 size:bytes];
		[cmdEncoder->_mtlCmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			const uint32_t* grids = (const uint32_t*)readback.contents;
			uint64_t maxWork = 0;
			uint32_t maxIndex = 0;
			for (uint32_t idx = 0; idx < encodedDrawCount; ++idx) {
				uint64_t work = uint64_t(grids[idx * 3]) * grids[idx * 3 + 1];
				if (work > maxWork) { maxWork = work; maxIndex = idx; }
			}
			// Small draws are already bounded and do not need a file. A failed command buffer is
			// always retained, even if metadata was not yet visible after a GPU fault.
			if (traceEverySelected || maxWork > 256 || cb.status != MTLCommandBufferStatusCompleted) {
				NSMutableArray* rows = [NSMutableArray array];
				for (uint32_t idx = 0; idx < encodedDrawCount; ++idx) {
					uint32_t batchIndex = idx % params.batchCount;
					bool nearMaximum = idx + 2 >= maxIndex && idx <= maxIndex + 2;
					if (encodedDrawCount > 128 && batchIndex + 2 < params.batchCount && !nearMaximum) { continue; }
					const DrawInfo* info = (const DrawInfo*)((const char*)readback.contents + drawInfoOffset + drawInfoStride * idx);
					[rows addObject:@{
						@"encodedIndex":@(idx), @"sourceDraw":@(idx / params.batchCount), @"batchIndex":@(batchIndex),
						@"gridX":@(grids[idx * 3]), @"gridY":@(grids[idx * 3 + 1]), @"gridZ":@(grids[idx * 3 + 2]),
						@"primitiveBase":@(info->primitiveBase), @"primitiveCount":@(info->primitiveCount),
						@"instanceBase":@(info->instanceBase), @"baseInstance":@(info->baseInstance),
						@"baseVertex":@(info->baseVertex), @"indexed":@(info->indexed),
						@"indexSize":@(info->indexSize), @"indexBufferAddress":@((unsigned long long)info->indexBuffer),
						@"topology":@(info->topoStrip)
					}];
				}
				NSMutableDictionary* result = [traceBase mutableCopy];
				result[@"sourceDrawCount"] = @(drawCount);
				result[@"batchCount"] = @(params.batchCount);
				result[@"encodedDrawCount"] = @(encodedDrawCount);
				result[@"maximumGridWork"] = @((unsigned long long)maxWork);
				result[@"maximumGridIndex"] = @(maxIndex);
				result[@"commandBufferStatus"] = @(cb.status);
				result[@"commandBufferError"] = cb.error.localizedDescription ?: @"";
				result[@"generatedDraws"] = rows;
				mvkWriteRuntimeTrace(getGlobalMVKConfig(), @"geometry-draw", result);
				[result release];
			}
		}];
		[readback release];
	}
	// Opt-in owned-fixture diagnostic. Copy only the generated draw parameters,
	// never vertex/index contents; no synchronous CPU wait or runtime fallback.
	if (getenv("MVK_OWNED_GEOMETRY_PARAMETER_READBACK") && drawCount == 1) {
		NSUInteger bytes = drawInfoOffset + drawInfoStride;
		id<MTLBuffer> readback = [tempBuff->_mtlBuffer.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		id<MTLBlitCommandEncoder> blit = cmdEncoder->getMTLBlitEncoder(kMVKCommandUseDrawIndirectConvertBuffers);
		[blit copyFromBuffer:tempBuff->_mtlBuffer sourceOffset:tempBuff->_offset toBuffer:readback destinationOffset:0 size:bytes];
		[cmdEncoder->_mtlCmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			if (cb.status == MTLCommandBufferStatusCompleted) {
				const uint32_t* grid = (const uint32_t*)readback.contents;
				const DrawInfo* info = (const DrawInfo*)((const char*)readback.contents + drawInfoOffset);
				fprintf(stderr, "GEOMETRY_PARAMETERS grid=%u,%u,%u primitives=%u primitiveBase=%u instanceBase=%u vertex=%d instance=%u topology=%u\n", grid[0], grid[1], grid[2], info->primitiveCount, info->primitiveBase, info->instanceBase, info->baseVertex, info->baseInstance, info->topoStrip);
			}
		}];
		[readback release];
	}
	cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);

	cmdEncoder->finalizeDrawState(kMVKGraphicsStageRasterization);	// Ensure all updated state has been submitted to Metal
	if ( !pipeline->hasValidMTLPipelineStates() ) { [traceBase release]; return; }

	id<MTLRenderCommandEncoder> mtlRendEnc = cmdEncoder->_mtlRenderEncoder;
	if (ibb) { [mtlRendEnc useResource: ibb->mtlBuffer usage: MTLResourceUsageRead stages: MTLRenderStageObject]; }
	if (pipeline->usesGeometryXfb() && cmdEncoder->_xfbSession) {
		cmdEncoder->reportMessage(MVK_CONFIG_LOG_LEVEL_ERROR, "Transform feedback is not captured by indirect draws with a geometry shader.");
	}
	bindGeometryXfb(cmdEncoder, pipeline, 0, nullptr);
	for (uint32_t drawIdx = 0; drawIdx < encodedDrawCount; drawIdx++) {
		[mtlRendEnc setObjectBuffer: tempBuff->_mtlBuffer
							 offset: tempBuff->_offset + drawInfoOffset + drawInfoStride * drawIdx
							atIndex: pipeline->getDrawInfoBufferIndex()];
		if (traceSelected && drawIdx % params.batchCount + 2 >= params.batchCount) {
			mvkRecordEncoderWork(mtlRendEnc, @"geometry-tail",
				[NSString stringWithFormat:@"sourceDraw=%u batch=%u/%u drawInfoOffset=%llu",
				 drawIdx / params.batchCount, drawIdx % params.batchCount, params.batchCount,
				 (unsigned long long)(tempBuff->_offset + drawInfoOffset + drawInfoStride * drawIdx)]);
		}
		[mtlRendEnc drawMeshThreadgroupsWithIndirectBuffer: tempBuff->_mtlBuffer
									  indirectBufferOffset: tempBuff->_offset + sizeof(MTLDispatchThreadgroupsIndirectArguments) * drawIdx
								threadsPerObjectThreadgroup: MTLSizeMake(1, 1, 1)
								  threadsPerMeshThreadgroup: MTLSizeMake(1, 1, 1)];
	}
	[traceBase release];
}
#endif

#pragma mark -
#pragma mark MVKCmdDraw

VkResult MVKCmdDraw::setContent(MVKCommandBuffer* cmdBuff,
								uint32_t vertexCount,
								uint32_t instanceCount,
								uint32_t firstVertex,
								uint32_t firstInstance) {
	_vertexCount = vertexCount;
	_instanceCount = instanceCount;
	_firstVertex = firstVertex;
	_firstInstance = firstInstance;

    // Validate
    if ((_firstInstance != 0) && !(cmdBuff->getMetalFeatures().baseVertexInstanceDrawing)) {
        return cmdBuff->reportError(VK_ERROR_FEATURE_NOT_PRESENT, "vkCmdDraw(): The current device does not support drawing with a non-zero base instance.");
    }

	return VK_SUCCESS;
}

// Populates and encodes a MVKCmdDrawIndexedIndirect command, after populating indexed indirect buffers.
void MVKCmdDraw::encodeIndexedIndirect(MVKCommandEncoder* cmdEncoder) {

	// Create an indexed indirect buffer and populate it from the draw arguments.
	uint32_t indirectIdxBuffStride = sizeof(MTLDrawIndexedPrimitivesIndirectArguments);
	auto* indirectIdxBuff = cmdEncoder->getTempMTLBuffer(indirectIdxBuffStride);
	auto* pIndArg = (MTLDrawIndexedPrimitivesIndirectArguments*)indirectIdxBuff->getContents();
	pIndArg->indexCount = _vertexCount;
	// let the indirect index point to the beginning of vertex index buffer below
	pIndArg->indexStart = 0;
	pIndArg->baseVertex = 0;
	pIndArg->instanceCount = _instanceCount;
	pIndArg->baseInstance = _firstInstance;

	// Create an index buffer populated with synthetic indexes.
	// Start populating indexes directly from the beginning and align with corresponding vertexes by adding _firstVertex
	MTLIndexType mtlIdxType = MTLIndexTypeUInt32;
	auto* vtxIdxBuff = cmdEncoder->getTempMTLBuffer(mvkMTLIndexTypeSizeInBytes(mtlIdxType) * _vertexCount);
	auto* pIdxBuff = (uint32_t*)vtxIdxBuff->getContents();

	for (uint32_t idx = 0; idx < _vertexCount; idx++) {
		pIdxBuff[idx] = _firstVertex + idx;
	}

	MVKIndexMTLBufferBinding ibb;
	ibb.mtlIndexType = mtlIdxType;
	ibb.mtlBuffer = vtxIdxBuff->_mtlBuffer;
	ibb.offset = vtxIdxBuff->_offset;
	ibb.size = vtxIdxBuff->_length;

	MVKCmdDrawIndexedIndirect diiCmd;
	diiCmd.setContent(cmdEncoder->_cmdBuffer,
					  indirectIdxBuff->_mtlBuffer,
					  indirectIdxBuff->_offset,
					  1,
					  indirectIdxBuffStride,
					  _firstInstance);
	diiCmd.encode(cmdEncoder, ibb);
}

void MVKCmdDraw::encode(MVKCommandEncoder* cmdEncoder) {

	if (_vertexCount == 0 || _instanceCount == 0) { return; }	// Nothing to do.
	if ( !cmdEncoder->getGraphicsPipeline() ) { return; }	// No valid pipeline bound (see MVKCmdBindPipeline).

	cmdEncoder->restartMetalRenderPassIfNeeded();

	auto* pipeline = cmdEncoder->getGraphicsPipeline();
	auto& mtlFeats = cmdEncoder->getMetalFeatures();
	auto& dvcLimits = cmdEncoder->getDeviceProperties().limits;

	// Metal doesn't support triangle fans, so encode it as triangles via an indexed indirect triangles command instead.
	// The object stage of a geometry-shader pipeline assembles fans itself.
	if (pipeline->getVkPrimitiveTopology() == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN && !pipeline->isGeometryPipeline()) {
		encodeIndexedIndirect(cmdEncoder);
		return;
	}

    cmdEncoder->_isIndexedDraw = false;

	MVKPiplineStages stages;
    pipeline->getStages(stages);

    const MVKMTLBufferAllocation* vtxOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcPatchOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcLevelBuff = nullptr;
	struct {
		uint32_t inControlPointCount = 0;
		uint32_t patchCount = 0;
	} tessParams;
    uint32_t outControlPointCount = 0;
    if (pipeline->isTessellationPipeline()) {
        tessParams.inControlPointCount = cmdEncoder->getVkGraphics().getPatchControlPoints();
        outControlPointCount = pipeline->getOutputControlPointCount();
        tessParams.patchCount = mvkCeilingDivide(_vertexCount, tessParams.inControlPointCount) * _instanceCount;
    }
    for (uint32_t s : stages) {
        auto stage = MVKGraphicsStage(s);
        cmdEncoder->finalizeDrawState(stage);	// Ensure all updated state has been submitted to Metal

		if ( !pipeline->hasValidMTLPipelineStates() ) { return; }	// Abort if this pipeline stage could not be compiled.

		id<MTLComputeCommandEncoder> mtlTessCtlEncoder = nil;

		switch (stage) {
            case kMVKGraphicsStageVertex: {
                mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                if (pipeline->needsVertexOutputBuffer()) {
                    vtxOutBuff = cmdEncoder->getTempMTLBuffer(_vertexCount * _instanceCount * 4 * dvcLimits.maxVertexOutputComponents, true);
                    [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                          offset: vtxOutBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageVertex).ids[MVKImplicitBuffer::Output]];
                }
				[mtlTessCtlEncoder setStageInRegion: MTLRegionMake2D(_firstVertex, _firstInstance, _vertexCount, _instanceCount)];
				// If there are vertex bindings with a zero vertex divisor, I need to offset them by
				// _firstInstance * stride, since that is the expected behaviour for a divisor of 0.
                cmdEncoder->getState().offsetZeroDivisorVertexBuffers(*cmdEncoder, stage, pipeline, _firstInstance);
				id<MTLComputePipelineState> vtxState = pipeline->getTessVertexStageState();
				if (mtlFeats.nonUniformThreadgroups) {
					[mtlTessCtlEncoder dispatchThreads: MTLSizeMake(_vertexCount, _instanceCount, 1)
					             threadsPerThreadgroup: MTLSizeMake(vtxState.threadExecutionWidth, 1, 1)];
				} else {
					[mtlTessCtlEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide(_vertexCount, vtxState.threadExecutionWidth), _instanceCount, 1)
                                      threadsPerThreadgroup: MTLSizeMake(vtxState.threadExecutionWidth, 1, 1)];
				}
                break;
			}
            case kMVKGraphicsStageTessControl: {
                mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                if (pipeline->needsTessCtlOutputBuffer()) {
                    tcOutBuff = cmdEncoder->getTempMTLBuffer(outControlPointCount * tessParams.patchCount * 4 * dvcLimits.maxTessellationControlPerVertexOutputComponents, true);
                    [mtlTessCtlEncoder setBuffer: tcOutBuff->_mtlBuffer
                                          offset: tcOutBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::Output]];
                }
                if (pipeline->needsTessCtlPatchOutputBuffer()) {
                    tcPatchOutBuff = cmdEncoder->getTempMTLBuffer(tessParams.patchCount * 4 * dvcLimits.maxTessellationControlPerPatchOutputComponents, true);
                    [mtlTessCtlEncoder setBuffer: tcPatchOutBuff->_mtlBuffer
                                          offset: tcPatchOutBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::PatchOutput]];
                }
                tcLevelBuff = cmdEncoder->getTempMTLBuffer(tessParams.patchCount * sizeof(MTLQuadTessellationFactorsHalf), true);
                [mtlTessCtlEncoder setBuffer: tcLevelBuff->_mtlBuffer
                                      offset: tcLevelBuff->_offset
                                     atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::TessLevel]];
                cmdEncoder->setComputeBytes(mtlTessCtlEncoder,
                                            &tessParams,
                                            sizeof(tessParams),
                                            pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::IndirectParams]);
                if (pipeline->needsVertexOutputBuffer()) {
                    [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                          offset: vtxOutBuff->_offset
                                         atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessCtlInputBufferBinding)];
                }
				
				NSUInteger sgSize = pipeline->getTessControlStageState().threadExecutionWidth;
				NSUInteger wgSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
				while (wgSize > dvcLimits.maxComputeWorkGroupSize[0]) {
					sgSize >>= 1;
					wgSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
				}
				if (mtlFeats.nonUniformThreadgroups) {
					[mtlTessCtlEncoder dispatchThreads: MTLSizeMake(tessParams.patchCount * outControlPointCount, 1, 1)
								 threadsPerThreadgroup: MTLSizeMake(wgSize, 1, 1)];
				} else {
					[mtlTessCtlEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide(tessParams.patchCount * outControlPointCount, wgSize), 1, 1)
									  threadsPerThreadgroup: MTLSizeMake(wgSize, 1, 1)];
				}
                // Running this stage prematurely ended the render pass, so we have to start it up again.
                // TODO: On iOS, maybe we could use a tile shader to avoid this.
                cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);
                break;
			}
            case kMVKGraphicsStageRasterization:
				mvkRecordDrawMetadata(cmdEncoder, cmdEncoder->_mtlRenderEncoder,
					@"direct", _vertexCount, _instanceCount, false);
                if (pipeline->isTessellationPipeline()) {
                    if (pipeline->needsTessCtlOutputBuffer()) {
                        [cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcOutBuff->_mtlBuffer
                                                                offset: tcOutBuff->_offset
                                                               atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalInputBufferBinding)];
                    }
                    if (pipeline->needsTessCtlPatchOutputBuffer()) {
                        [cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcPatchOutBuff->_mtlBuffer
                                                                offset: tcPatchOutBuff->_offset
                                                               atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalPatchInputBufferBinding)];
                    }
                    [cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcLevelBuff->_mtlBuffer
                                                            offset: tcLevelBuff->_offset
                                                           atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalLevelBufferBinding)];
                    [cmdEncoder->_mtlRenderEncoder setTessellationFactorBuffer: tcLevelBuff->_mtlBuffer
                                                                        offset: tcLevelBuff->_offset
                                                                instanceStride: 0];
                    [cmdEncoder->_mtlRenderEncoder drawPatches: outControlPointCount
                                                    patchStart: 0
                                                    patchCount: tessParams.patchCount
                                              patchIndexBuffer: nil
                                        patchIndexBufferOffset: 0
                                                 instanceCount: 1
                                                  baseInstance: 0];
#if MVK_XCODE_14
                } else if (pipeline->isGeometryPipeline()) {
					DrawInfo drawInfo = {};

					uint32_t vertsPerPrim = 0;
					MVKGeometryTopology topology = kMVKGeometryTopologyList;
					if ( !getGeometryPrimitiveShape(cmdEncoder, pipeline, vertsPerPrim, topology) ) { return; }
					uint32_t threadCount = getGeometryPrimitiveCount(_vertexCount, vertsPerPrim, topology);
					drawInfo.topoStrip = topology;

					drawInfo.baseVertex = (int32_t)_firstVertex;
					drawInfo.baseInstance = _firstInstance;
					setGeometryVertexStrides(drawInfo, cmdEncoder, pipeline);

					encodeGeometryMeshDraw(cmdEncoder, pipeline, drawInfo, threadCount, _instanceCount, nil);
#endif
                } else {
                    MVKRenderSubpass* subpass = cmdEncoder->getSubpass();
                    uint32_t viewCount = subpass->isMultiview() ? subpass->getViewCountInMetalPass(cmdEncoder->getMultiviewPassIndex()) : 1;
                    uint32_t instanceCount = _instanceCount * viewCount;
                    cmdEncoder->getState().offsetZeroDivisorVertexBuffers(*cmdEncoder, stage, pipeline, _firstInstance);
                    if (mtlFeats.baseVertexInstanceDrawing) {
                        [cmdEncoder->_mtlRenderEncoder drawPrimitives: cmdEncoder->getMtlGraphics().getPrimitiveType()
                                                          vertexStart: _firstVertex
                                                          vertexCount: _vertexCount
                                                        instanceCount: instanceCount
                                                         baseInstance: _firstInstance];
                    } else {
                        [cmdEncoder->_mtlRenderEncoder drawPrimitives: cmdEncoder->getMtlGraphics().getPrimitiveType()
                                                          vertexStart: _firstVertex
                                                          vertexCount: _vertexCount
                                                        instanceCount: instanceCount];
                    }
                }
                break;
        }
    }
}


#pragma mark -
#pragma mark MVKCmdDrawIndexed

VkResult MVKCmdDrawIndexed::setContent(MVKCommandBuffer* cmdBuff,
									   uint32_t indexCount,
									   uint32_t instanceCount,
									   uint32_t firstIndex,
									   int32_t vertexOffset,
									   uint32_t firstInstance) {
	_indexCount = indexCount;
	_instanceCount = instanceCount;
	_firstIndex = firstIndex;
	_vertexOffset = vertexOffset;
	_firstInstance = firstInstance;

    // Validate
	auto& mtlFeats = cmdBuff->getMetalFeatures();
    if ((_firstInstance != 0) && !(mtlFeats.baseVertexInstanceDrawing)) {
        return cmdBuff->reportError(VK_ERROR_FEATURE_NOT_PRESENT, "vkCmdDrawIndexed(): The current device does not support drawing with a non-zero base instance.");
    }
    if ((_vertexOffset != 0) && !(mtlFeats.baseVertexInstanceDrawing)) {
        return cmdBuff->reportError(VK_ERROR_FEATURE_NOT_PRESENT, "vkCmdDrawIndexed(): The current device does not support drawing with a non-zero base vertex.");
    }

	return VK_SUCCESS;
}

// Populates and encodes a MVKCmdDrawIndexedIndirect command, after populating an indexed indirect buffer.
void MVKCmdDrawIndexed::encodeIndexedIndirect(MVKCommandEncoder* cmdEncoder) {

	// Create an indexed indirect buffer and populate it from the draw arguments.
	uint32_t indirectIdxBuffStride = sizeof(MTLDrawIndexedPrimitivesIndirectArguments);
	auto* indirectIdxBuff = cmdEncoder->getTempMTLBuffer(indirectIdxBuffStride);
	auto* pIndArg = (MTLDrawIndexedPrimitivesIndirectArguments*)indirectIdxBuff->getContents();
	pIndArg->indexCount = _indexCount;
	pIndArg->indexStart = _firstIndex;
	pIndArg->baseVertex = _vertexOffset;
	pIndArg->instanceCount = _instanceCount;
	pIndArg->baseInstance = _firstInstance;

	MVKCmdDrawIndexedIndirect diiCmd;
	diiCmd.setContent(cmdEncoder->_cmdBuffer,
					  indirectIdxBuff->_mtlBuffer,
					  indirectIdxBuff->_offset,
					  1,
					  indirectIdxBuffStride,
					  _firstInstance);
	diiCmd.encode(cmdEncoder);
}

void MVKCmdDrawIndexed::encode(MVKCommandEncoder* cmdEncoder) {

	if (_indexCount == 0 || _instanceCount == 0) { return; }	// Nothing to do.
	if ( !cmdEncoder->getGraphicsPipeline() ) { return; }	// No valid pipeline bound (see MVKCmdBindPipeline).

	cmdEncoder->restartMetalRenderPassIfNeeded();

	auto* pipeline = cmdEncoder->getGraphicsPipeline();
	auto& mtlFeats = cmdEncoder->getMetalFeatures();
	auto& dvcLimits = cmdEncoder->getDeviceProperties().limits;

	// Metal doesn't support triangle fans, so encode it as triangles via an indexed indirect triangles command instead.
	// The object stage of a geometry-shader pipeline assembles fans itself.
	if (pipeline->getVkPrimitiveTopology() == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN && !pipeline->isGeometryPipeline()) {
		encodeIndexedIndirect(cmdEncoder);
		return;
	}

    cmdEncoder->_isIndexedDraw = true;

	MVKPiplineStages stages;
    pipeline->getStages(stages);

    MVKIndexMTLBufferBinding ibb = cmdEncoder->getVkGraphics()._indexBuffer;
    size_t idxSize = mvkMTLIndexTypeSizeInBytes((MTLIndexType)ibb.mtlIndexType);
    VkDeviceSize idxBuffOffset = ibb.offset + ((VkDeviceSize)_firstIndex * idxSize);

    // For robust buffer access 2, handle OOB index buffer access
    if (cmdEncoder->getEnabledRobustness2Features().robustBufferAccess2 && ibb.size > 0) {
        VkDeviceSize firstIndexBytes = (VkDeviceSize)_firstIndex * idxSize;
        VkDeviceSize lastIndexBytes = (VkDeviceSize)(_firstIndex + _indexCount) * idxSize;

        if (firstIndexBytes >= ibb.size) {
            // All indices are OOB - create a zeroed index buffer so all reads return index 0
            auto* zeroIdxBuff = cmdEncoder->getTempMTLBuffer(idxSize * _indexCount);
            memset(zeroIdxBuff->getContents(), 0, idxSize * _indexCount);
            ibb.mtlBuffer = zeroIdxBuff->_mtlBuffer;
            idxBuffOffset = zeroIdxBuff->_offset;
        } else if (lastIndexBytes > ibb.size) {
            // Some indices are OOB - create a new buffer with valid indices copied and OOB indices zeroed
            auto* newIdxBuff = cmdEncoder->getTempMTLBuffer(idxSize * _indexCount);
            uint8_t* dst = (uint8_t*)newIdxBuff->getContents();

            // Calculate how many indices are valid (within the bound size)
            VkDeviceSize validBytes = ibb.size - firstIndexBytes;

            // Copy valid indices from original buffer
			if (ibb.mtlBuffer.storageMode != MTLStorageModePrivate) {
				memcpy(dst, (uint8_t*)ibb.mtlBuffer.contents + ibb.offset + firstIndexBytes, validBytes);
				memset(dst + validBytes, 0, (idxSize * _indexCount) - validBytes);
			} else {
				memset(dst, 0, idxSize * _indexCount);
			}

            ibb.mtlBuffer = newIdxBuff->_mtlBuffer;
            idxBuffOffset = newIdxBuff->_offset;
        }
    }

    const MVKMTLBufferAllocation* vtxOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcPatchOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcLevelBuff = nullptr;
	struct {
		uint32_t inControlPointCount = 0;
		uint32_t patchCount = 0;
	} tessParams;
    uint32_t outControlPointCount = 0;
    if (pipeline->isTessellationPipeline()) {
        tessParams.inControlPointCount = cmdEncoder->getVkGraphics().getPatchControlPoints();
        outControlPointCount = pipeline->getOutputControlPointCount();
        tessParams.patchCount = mvkCeilingDivide(_indexCount, tessParams.inControlPointCount) * _instanceCount;
    }
    for (uint32_t s : stages) {
        auto stage = MVKGraphicsStage(s);
        id<MTLComputeCommandEncoder> mtlTessCtlEncoder = nil;
        cmdEncoder->finalizeDrawState(stage);	// Ensure all updated state has been submitted to Metal

		if ( !pipeline->hasValidMTLPipelineStates() ) { return; }	// Abort if this pipeline stage could not be compiled.

        switch (stage) {
            case kMVKGraphicsStageVertex: {
                mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                if (pipeline->needsVertexOutputBuffer()) {
                    vtxOutBuff = cmdEncoder->getTempMTLBuffer(_indexCount * _instanceCount * 4 * dvcLimits.maxVertexOutputComponents, true);
                    [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                          offset: vtxOutBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageVertex).ids[MVKImplicitBuffer::Output]];
                }
				[mtlTessCtlEncoder setBuffer: ibb.mtlBuffer
                                      offset: idxBuffOffset
                                     atIndex: pipeline->getImplicitBuffers(kMVKShaderStageVertex).ids[MVKImplicitBuffer::Index]];
				[mtlTessCtlEncoder setStageInRegion: MTLRegionMake2D(_vertexOffset, _firstInstance, _indexCount, _instanceCount)];
				// If there are vertex bindings with a zero vertex divisor, I need to offset them by
				// _firstInstance * stride, since that is the expected behaviour for a divisor of 0.
                cmdEncoder->getState().offsetZeroDivisorVertexBuffers(*cmdEncoder, stage, pipeline, _firstInstance);
				id<MTLComputePipelineState> vtxState = ibb.mtlIndexType == MTLIndexTypeUInt16 ? pipeline->getTessVertexStageIndex16State() : pipeline->getTessVertexStageIndex32State();
				if (mtlFeats.nonUniformThreadgroups) {
					[mtlTessCtlEncoder dispatchThreads: MTLSizeMake(_indexCount, _instanceCount, 1)
					             threadsPerThreadgroup: MTLSizeMake(vtxState.threadExecutionWidth, 1, 1)];
				} else {
					[mtlTessCtlEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide(_indexCount, vtxState.threadExecutionWidth), _instanceCount, 1)
                                      threadsPerThreadgroup: MTLSizeMake(vtxState.threadExecutionWidth, 1, 1)];
				}
                break;
			}
            case kMVKGraphicsStageTessControl: {
                mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                if (pipeline->needsTessCtlOutputBuffer()) {
                    tcOutBuff = cmdEncoder->getTempMTLBuffer(outControlPointCount * tessParams.patchCount * 4 * dvcLimits.maxTessellationControlPerVertexOutputComponents, true);
                    [mtlTessCtlEncoder setBuffer: tcOutBuff->_mtlBuffer
                                          offset: tcOutBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::Output]];
                }
                if (pipeline->needsTessCtlPatchOutputBuffer()) {
                    tcPatchOutBuff = cmdEncoder->getTempMTLBuffer(tessParams.patchCount * 4 * dvcLimits.maxTessellationControlPerPatchOutputComponents, true);
                    [mtlTessCtlEncoder setBuffer: tcPatchOutBuff->_mtlBuffer
                                          offset: tcPatchOutBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::PatchOutput]];
                }
                tcLevelBuff = cmdEncoder->getTempMTLBuffer(tessParams.patchCount * sizeof(MTLQuadTessellationFactorsHalf), true);
                [mtlTessCtlEncoder setBuffer: tcLevelBuff->_mtlBuffer
                                      offset: tcLevelBuff->_offset
                                     atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::TessLevel]];
                cmdEncoder->setComputeBytes(mtlTessCtlEncoder,
                                            &tessParams,
                                            sizeof(tessParams),
                                            pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::IndirectParams]);
                if (pipeline->needsVertexOutputBuffer()) {
                    [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                          offset: vtxOutBuff->_offset
                                         atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessCtlInputBufferBinding)];
                }
				// The vertex shader produced output in the correct order, so there's no need to use
				// an index buffer here.
				NSUInteger sgSize = pipeline->getTessControlStageState().threadExecutionWidth;
				NSUInteger wgSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
				while (wgSize > dvcLimits.maxComputeWorkGroupSize[0]) {
					sgSize >>= 1;
					wgSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
				}
				if (mtlFeats.nonUniformThreadgroups) {
					[mtlTessCtlEncoder dispatchThreads: MTLSizeMake(tessParams.patchCount * outControlPointCount, 1, 1)
								 threadsPerThreadgroup: MTLSizeMake(wgSize, 1, 1)];
				} else {
					[mtlTessCtlEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide(tessParams.patchCount * outControlPointCount, wgSize), 1, 1)
									  threadsPerThreadgroup: MTLSizeMake(wgSize, 1, 1)];
				}
                // Running this stage prematurely ended the render pass, so we have to start it up again.
                // TODO: On iOS, maybe we could use a tile shader to avoid this.
                cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);
                break;
			}
            case kMVKGraphicsStageRasterization:
				mvkRecordDrawMetadata(cmdEncoder, cmdEncoder->_mtlRenderEncoder,
					@"direct-indexed", _indexCount, _instanceCount, true);
                if (pipeline->isTessellationPipeline()) {
                    if (pipeline->needsTessCtlOutputBuffer()) {
                        [cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcOutBuff->_mtlBuffer
                                                                offset: tcOutBuff->_offset
                                                               atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalInputBufferBinding)];
                    }
                    if (pipeline->needsTessCtlPatchOutputBuffer()) {
                        [cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcPatchOutBuff->_mtlBuffer
                                                                offset: tcPatchOutBuff->_offset
                                                               atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalPatchInputBufferBinding)];
                    }
                    [cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcLevelBuff->_mtlBuffer
                                                            offset: tcLevelBuff->_offset
                                                           atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalLevelBufferBinding)];
                    [cmdEncoder->_mtlRenderEncoder setTessellationFactorBuffer: tcLevelBuff->_mtlBuffer
                                                                        offset: tcLevelBuff->_offset
                                                                instanceStride: 0];
                    // The tessellation control shader produced output in the correct order, so there's no need to use
                    // an index buffer here.
                    [cmdEncoder->_mtlRenderEncoder drawPatches: outControlPointCount
                                                    patchStart: 0
                                                    patchCount: tessParams.patchCount
                                              patchIndexBuffer: nil
                                        patchIndexBufferOffset: 0
                                                 instanceCount: 1
                                                  baseInstance: 0];
#if MVK_XCODE_14
                } else if (pipeline->isGeometryPipeline()) {
					DrawInfo drawInfo = {};
					drawInfo.indexed = true;
					drawInfo.indexSize = (int)idxSize;
					drawInfo.indexBuffer = ibb.mtlBuffer.gpuAddress + idxBuffOffset;


					uint32_t vertsPerPrim = 0;
					MVKGeometryTopology topology = kMVKGeometryTopologyList;
					if ( !getGeometryPrimitiveShape(cmdEncoder, pipeline, vertsPerPrim, topology) ) { return; }
					uint32_t threadCount = getGeometryPrimitiveCount(_indexCount, vertsPerPrim, topology);
					drawInfo.topoStrip = topology;

					drawInfo.baseVertex = _vertexOffset;
					drawInfo.baseInstance = _firstInstance;
					setGeometryVertexStrides(drawInfo, cmdEncoder, pipeline);

					encodeGeometryMeshDraw(cmdEncoder, pipeline, drawInfo, threadCount, _instanceCount, ibb.mtlBuffer);
#endif
                } else {
                    MVKRenderSubpass* subpass = cmdEncoder->getSubpass();
                    uint32_t viewCount = subpass->isMultiview() ? subpass->getViewCountInMetalPass(cmdEncoder->getMultiviewPassIndex()) : 1;
                    uint32_t instanceCount = _instanceCount * viewCount;
                    cmdEncoder->getState().offsetZeroDivisorVertexBuffers(*cmdEncoder, stage, pipeline, _firstInstance);
                    if (mtlFeats.baseVertexInstanceDrawing) {
                        [cmdEncoder->_mtlRenderEncoder drawIndexedPrimitives: cmdEncoder->getMtlGraphics().getPrimitiveType()
                                                                  indexCount: _indexCount
                                                                   indexType: (MTLIndexType)ibb.mtlIndexType
                                                                 indexBuffer: ibb.mtlBuffer
                                                           indexBufferOffset: idxBuffOffset
                                                               instanceCount: instanceCount
                                                                  baseVertex: _vertexOffset
                                                                baseInstance: _firstInstance];
                    } else {
                        [cmdEncoder->_mtlRenderEncoder drawIndexedPrimitives: cmdEncoder->getMtlGraphics().getPrimitiveType()
                                                                  indexCount: _indexCount
                                                                   indexType: (MTLIndexType)ibb.mtlIndexType
                                                                 indexBuffer: ibb.mtlBuffer
                                                           indexBufferOffset: idxBuffOffset
                                                               instanceCount: instanceCount];
                    }
                }
                break;
        }
    }
}


// This is totally arbitrary, but we're forced to do this because we don't know how many vertices
// there are at encoding time. And this will probably be inadequate for large instanced draws.
// TODO: Consider breaking up such draws using different base instance values. But this will
// require yet more munging of the indirect buffers...
static const uint32_t kMVKMaxDrawIndirectVertexCount = 128 * KIBI;

#pragma mark -
#pragma mark MVKCmdDrawIndirect

VkResult MVKCmdDrawIndirect::setContent(MVKCommandBuffer* cmdBuff,
										VkBuffer buffer,
										VkDeviceSize offset,
										uint32_t drawCount,
										uint32_t stride) {
	MVKBuffer* mvkBuffer = (MVKBuffer*)buffer;
	_mtlIndirectBuffer = mvkBuffer->getMTLBuffer();
	_mtlIndirectBufferOffset = mvkBuffer->getMTLBufferOffset() + offset;
	_mtlIndirectBufferStride = stride;
	_drawCount = drawCount;

    // Validate
	auto& mtlFeats = cmdBuff->getMetalFeatures();
    if ( !mtlFeats.indirectDrawing ) {
        return cmdBuff->reportError(VK_ERROR_FEATURE_NOT_PRESENT, "vkCmdDrawIndirect(): The current device does not support indirect drawing.");
    }
	if (cmdBuff->_lastTessellationPipeline && !mtlFeats.indirectTessellationDrawing) {
		return cmdBuff->reportError(VK_ERROR_FEATURE_NOT_PRESENT, "vkCmdDrawIndirect(): The current device does not support indirect tessellated drawing.");
	}

	return VK_SUCCESS;
}

// Populates and encodes a MVKCmdDrawIndexedIndirect command, after populating indexed indirect buffers.
void MVKCmdDrawIndirect::encodeIndexedIndirect(MVKCommandEncoder* cmdEncoder) {

	// Create an indexed indirect buffer to be populated from the non-indexed indirect buffer.
	uint32_t indirectIdxBuffStride = sizeof(MTLDrawIndexedPrimitivesIndirectArguments);
	auto* indirectIdxBuff = cmdEncoder->getTempMTLBuffer(indirectIdxBuffStride * _drawCount, true);

	// Create an index buffer to be populated with synthetic indexes.
	MTLIndexType mtlIdxType = MTLIndexTypeUInt32;
	auto* vtxIdxBuff = cmdEncoder->getTempMTLBuffer(mvkMTLIndexTypeSizeInBytes(mtlIdxType) * kMVKMaxDrawIndirectVertexCount, true);
	MVKIndexMTLBufferBinding ibb;
	ibb.mtlIndexType = mtlIdxType;
	ibb.mtlBuffer = vtxIdxBuff->_mtlBuffer;
	ibb.offset = vtxIdxBuff->_offset;
	ibb.size = vtxIdxBuff->_length;

	// Schedule a compute action to populate indexed buffers from non-indexed buffers.
	cmdEncoder->encodeStoreActions(true);
	id<MTLComputeCommandEncoder> mtlConvertEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseDrawIndirectConvertBuffers);
	MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
	id<MTLComputePipelineState> mtlConvertState = cmdEncoder->getCommandEncodingPool()->getCmdDrawIndirectPopulateIndexesMTLComputePipelineState();
	state.bindPipeline(mtlConvertEncoder, mtlConvertState);
	state.bindBuffer(mtlConvertEncoder, _mtlIndirectBuffer,          _mtlIndirectBufferOffset, 0);
	state.bindBuffer(mtlConvertEncoder, indirectIdxBuff->_mtlBuffer, indirectIdxBuff->_offset, 1);
	state.bindStructBytes(mtlConvertEncoder, &_mtlIndirectBufferStride, 2);
	state.bindStructBytes(mtlConvertEncoder, &_drawCount,               3);
	state.bindBuffer(mtlConvertEncoder, ibb.mtlBuffer, ibb.offset, 4);
	if (cmdEncoder->getMetalFeatures().nonUniformThreadgroups) {
		[mtlConvertEncoder dispatchThreads: MTLSizeMake(_drawCount, 1, 1)
					 threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
	} else {
		[mtlConvertEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide<NSUInteger>(_drawCount, mtlConvertState.threadExecutionWidth), 1, 1)
						  threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
	}
	// Switch back to rendering now.
	cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);

	MVKCmdDrawIndexedIndirect diiCmd;
	diiCmd.setContent(cmdEncoder->_cmdBuffer,
					  indirectIdxBuff->_mtlBuffer,
					  indirectIdxBuff->_offset,
					  _drawCount,
					  indirectIdxBuffStride,
					  0);
	diiCmd.encode(cmdEncoder, ibb);
}

void MVKCmdDrawIndirect::encode(MVKCommandEncoder* cmdEncoder) {
	if ( !cmdEncoder->getGraphicsPipeline() ) { return; }	// No valid pipeline bound (see MVKCmdBindPipeline).

	cmdEncoder->restartMetalRenderPassIfNeeded();

	auto* pipeline = cmdEncoder->getGraphicsPipeline();
	auto& mtlFeats = cmdEncoder->getMetalFeatures();
	auto& dvcLimits = cmdEncoder->getDeviceProperties().limits;

#if MVK_XCODE_14
    if (pipeline->isGeometryPipeline()) {
        cmdEncoder->_isIndexedDraw = false;
        encodeGeometryIndirectDraws(cmdEncoder, pipeline, _mtlIndirectBuffer, _mtlIndirectBufferOffset,
                                    _mtlIndirectBufferStride, _drawCount, nullptr);
        return;
    }
#endif

	// Metal doesn't support triangle fans, so encode it as indexed indirect triangles instead.
	if (pipeline->getVkPrimitiveTopology() == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN) {
		encodeIndexedIndirect(cmdEncoder);
		return;
	}

    cmdEncoder->_isIndexedDraw = false;

    bool needsInstanceAdjustment = cmdEncoder->getSubpass()->isMultiview() &&
                                   cmdEncoder->getPhysicalDevice()->canUseInstancingForMultiview();
    // The indirect calls for dispatchThreadgroups:... and drawPatches:... have different formats.
    // We have to convert from the drawPrimitives:... format to them.
    // While we're at it, we can create the temporary output buffers once and reuse them
    // for each draw.
    const MVKMTLBufferAllocation* tempIndirectBuff = nullptr;
	const MVKMTLBufferAllocation* tcParamsBuff = nullptr;
    const MVKMTLBufferAllocation* vtxOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcPatchOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcLevelBuff = nullptr;
    uint32_t patchCount = 0, vertexCount = 0;
    uint32_t inControlPointCount = 0, outControlPointCount = 0;
	VkDeviceSize paramsIncr = 0;

    id<MTLBuffer> mtlIndBuff = _mtlIndirectBuffer;
    VkDeviceSize mtlIndBuffOfst = _mtlIndirectBufferOffset;
    VkDeviceSize mtlParmBuffOfst = 0;
    NSUInteger vtxThreadExecWidth = 0;
    NSUInteger tcWorkgroupSize = 0;

    if (pipeline->isTessellationPipeline()) {
        // We can't read the indirect buffer CPU-side, since it may change between
        // encoding and execution. So we don't know how big to make the buffers.
        // We must assume an arbitrarily large number of vertices may be submitted.
        // But not too many, or we'll exhaust available VRAM.
        inControlPointCount = cmdEncoder->getVkGraphics().getPatchControlPoints();
        outControlPointCount = pipeline->getOutputControlPointCount();
        vertexCount = kMVKMaxDrawIndirectVertexCount;
        patchCount = mvkCeilingDivide(vertexCount, inControlPointCount);
        VkDeviceSize indirectSize = (2 * sizeof(MTLDispatchThreadgroupsIndirectArguments) + sizeof(MTLDrawPatchIndirectArguments) + sizeof(MTLStageInRegionIndirectArguments)) * _drawCount;
		paramsIncr = std::max((size_t)dvcLimits.minUniformBufferOffsetAlignment, sizeof(uint32_t) * 2);
		VkDeviceSize paramsSize = paramsIncr * _drawCount;
        tempIndirectBuff = cmdEncoder->getTempMTLBuffer(indirectSize, true);
        mtlIndBuff = tempIndirectBuff->_mtlBuffer;
        mtlIndBuffOfst = tempIndirectBuff->_offset;
		tcParamsBuff = cmdEncoder->getTempMTLBuffer(paramsSize, true);
        mtlParmBuffOfst = tcParamsBuff->_offset;
        if (pipeline->needsVertexOutputBuffer()) {
            vtxOutBuff = cmdEncoder->getTempMTLBuffer(vertexCount * 4 * dvcLimits.maxVertexOutputComponents, true);
        }
        if (pipeline->needsTessCtlOutputBuffer()) {
            tcOutBuff = cmdEncoder->getTempMTLBuffer(outControlPointCount * patchCount * 4 * dvcLimits.maxTessellationControlPerVertexOutputComponents, true);
        }
        if (pipeline->needsTessCtlPatchOutputBuffer()) {
            tcPatchOutBuff = cmdEncoder->getTempMTLBuffer(patchCount * 4 * dvcLimits.maxTessellationControlPerPatchOutputComponents, true);
        }
        tcLevelBuff = cmdEncoder->getTempMTLBuffer(patchCount * sizeof(MTLQuadTessellationFactorsHalf), true);

        vtxThreadExecWidth = pipeline->getTessVertexStageState().threadExecutionWidth;
        NSUInteger sgSize = pipeline->getTessControlStageState().threadExecutionWidth;
        tcWorkgroupSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
        while (tcWorkgroupSize > dvcLimits.maxComputeWorkGroupSize[0]) {
            sgSize >>= 1;
            tcWorkgroupSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
        }
    } else if (needsInstanceAdjustment) {
        // In this case, we need to adjust the instance count for the views being drawn.
        VkDeviceSize indirectSize = sizeof(MTLDrawPrimitivesIndirectArguments) * _drawCount;
        tempIndirectBuff = cmdEncoder->getTempMTLBuffer(indirectSize, true);
        mtlIndBuff = tempIndirectBuff->_mtlBuffer;
        mtlIndBuffOfst = tempIndirectBuff->_offset;
    }

	MVKPiplineStages stages;
    pipeline->getStages(stages);

    for (uint32_t drawIdx = 0; drawIdx < _drawCount; drawIdx++) {
        for (uint32_t s : stages) {
            auto stage = MVKGraphicsStage(s);
            id<MTLComputeCommandEncoder> mtlTessCtlEncoder = nil;
            if (drawIdx == 0 && stage == kMVKGraphicsStageVertex && pipeline->isTessellationPipeline()) {
                // We need the indirect buffers now. This must be done before finalizing
                // draw state, or the pipeline will get overridden. This is a good time
                // to do it, since it will require switching to compute anyway. Do it all
                // at once to get it over with.
				cmdEncoder->encodeStoreActions(true);
				mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
				id<MTLComputePipelineState> mtlConvertState = cmdEncoder->getCommandEncodingPool()->getCmdDrawIndirectTessConvertBuffersMTLComputePipelineState(false);
				MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
				state.bindPipeline(mtlTessCtlEncoder, mtlConvertState);
				state.bindBuffer(mtlTessCtlEncoder, _mtlIndirectBuffer,           _mtlIndirectBufferOffset,  0);
				state.bindBuffer(mtlTessCtlEncoder, tempIndirectBuff->_mtlBuffer, tempIndirectBuff->_offset, 1);
				state.bindBuffer(mtlTessCtlEncoder, tcParamsBuff->_mtlBuffer,     tcParamsBuff->_offset,     2);
				state.bindStructBytes(mtlTessCtlEncoder, &_mtlIndirectBufferStride, 3);
				state.bindStructBytes(mtlTessCtlEncoder, &inControlPointCount,      4);
				state.bindStructBytes(mtlTessCtlEncoder, &outControlPointCount,     5);
				state.bindStructBytes(mtlTessCtlEncoder, &_drawCount,               6);
				state.bindStructBytes(mtlTessCtlEncoder, &vtxThreadExecWidth,       7);
				state.bindStructBytes(mtlTessCtlEncoder, &tcWorkgroupSize,          8);
				if (mtlFeats.nonUniformThreadgroups) {
					[mtlTessCtlEncoder dispatchThreads: MTLSizeMake(_drawCount, 1, 1)
								 threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
				} else {
					[mtlTessCtlEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide<NSUInteger>(_drawCount, mtlConvertState.threadExecutionWidth), 1, 1)
									  threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
				}
            } else if (drawIdx == 0 && needsInstanceAdjustment) {
                // Similarly, for multiview, we need to adjust the instance count now.
                // Unfortunately, this requires switching to compute.
                // TODO: Consider using tile shaders to avoid this cost.
				cmdEncoder->encodeStoreActions(true);
				id<MTLComputeCommandEncoder> mtlConvertEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseDrawIndirectConvertBuffers);
				id<MTLComputePipelineState> mtlConvertState = cmdEncoder->getCommandEncodingPool()->getCmdDrawIndirectConvertBuffersMTLComputePipelineState(false);
				uint32_t viewCount = cmdEncoder->getSubpass()->getViewCountInMetalPass(cmdEncoder->getMultiviewPassIndex());
				MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
				state.bindPipeline(mtlConvertEncoder, mtlConvertState);
				state.bindBuffer(mtlConvertEncoder, _mtlIndirectBuffer,           _mtlIndirectBufferOffset,  0);
				state.bindBuffer(mtlConvertEncoder, tempIndirectBuff->_mtlBuffer, tempIndirectBuff->_offset, 1);
				state.bindStructBytes(mtlConvertEncoder, &_mtlIndirectBufferStride, 2);
				state.bindStructBytes(mtlConvertEncoder, &_drawCount,               3);
				state.bindStructBytes(mtlConvertEncoder, &viewCount,                4);
                if (mtlFeats.nonUniformThreadgroups) {
					[mtlConvertEncoder dispatchThreads: MTLSizeMake(_drawCount, 1, 1)
					             threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
                } else {
                    [mtlConvertEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide<NSUInteger>(_drawCount, mtlConvertState.threadExecutionWidth), 1, 1)
                                      threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
                }
                // Switch back to rendering now, since we don't have compute stages to run anyway.
                cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);
            }

            cmdEncoder->finalizeDrawState(stage);	// Ensure all updated state has been submitted to Metal

			if ( !pipeline->hasValidMTLPipelineStates() ) { return; }	// Abort if this pipeline stage could not be compiled.

            switch (stage) {
                case kMVKGraphicsStageVertex:
                    mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                    if (pipeline->needsVertexOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                              offset: vtxOutBuff->_offset
                                             atIndex: pipeline->getImplicitBuffers(kMVKShaderStageVertex).ids[MVKImplicitBuffer::Output]];
                    }
					// We must assume we can read up to the maximum number of vertices.
					[mtlTessCtlEncoder setStageInRegion: MTLRegionMake2D(0, 0, vertexCount, vertexCount)];
					[mtlTessCtlEncoder setStageInRegionWithIndirectBuffer: mtlIndBuff
						                             indirectBufferOffset: mtlIndBuffOfst];
					mtlIndBuffOfst += sizeof(MTLStageInRegionIndirectArguments);
					[mtlTessCtlEncoder dispatchThreadgroupsWithIndirectBuffer: mtlIndBuff
														 indirectBufferOffset: mtlIndBuffOfst
														threadsPerThreadgroup: MTLSizeMake(vtxThreadExecWidth, 1, 1)];
					mtlIndBuffOfst += sizeof(MTLDispatchThreadgroupsIndirectArguments);
                    break;
                case kMVKGraphicsStageTessControl:
                    mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                    if (pipeline->needsTessCtlOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: tcOutBuff->_mtlBuffer
                                              offset: tcOutBuff->_offset
                                             atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::Output]];
                    }
                    if (pipeline->needsTessCtlPatchOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: tcPatchOutBuff->_mtlBuffer
                                              offset: tcPatchOutBuff->_offset
                                             atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::PatchOutput]];
                    }
                    [mtlTessCtlEncoder setBuffer: tcLevelBuff->_mtlBuffer
                                          offset: tcLevelBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::TessLevel]];
					[mtlTessCtlEncoder setBuffer: tcParamsBuff->_mtlBuffer
										  offset: mtlParmBuffOfst
										 atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::IndirectParams]];
					mtlParmBuffOfst += paramsIncr;
                    if (pipeline->needsVertexOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                              offset: vtxOutBuff->_offset
                                             atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessCtlInputBufferBinding)];
                    }
                    [mtlTessCtlEncoder dispatchThreadgroupsWithIndirectBuffer: mtlIndBuff
                                                         indirectBufferOffset: mtlIndBuffOfst
                                                        threadsPerThreadgroup: MTLSizeMake(tcWorkgroupSize, 1, 1)];
                    mtlIndBuffOfst += sizeof(MTLDispatchThreadgroupsIndirectArguments);
                    // Running this stage prematurely ended the render pass, so we have to start it up again.
                    // TODO: On iOS, maybe we could use a tile shader to avoid this.
                    cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);
                    break;
                case kMVKGraphicsStageRasterization:
                    if (pipeline->isTessellationPipeline()) {
						if (mtlFeats.indirectTessellationDrawing) {
							if (pipeline->needsTessCtlOutputBuffer()) {
								[cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcOutBuff->_mtlBuffer
																		offset: tcOutBuff->_offset
																	   atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalInputBufferBinding)];
							}
							if (pipeline->needsTessCtlPatchOutputBuffer()) {
								[cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcPatchOutBuff->_mtlBuffer
																		offset: tcPatchOutBuff->_offset
																	   atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalPatchInputBufferBinding)];
							}
							[cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcLevelBuff->_mtlBuffer
																	offset: tcLevelBuff->_offset
																   atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalLevelBufferBinding)];
							[cmdEncoder->_mtlRenderEncoder setTessellationFactorBuffer: tcLevelBuff->_mtlBuffer
																				offset: tcLevelBuff->_offset
																		instanceStride: 0];
							[cmdEncoder->_mtlRenderEncoder drawPatches: outControlPointCount
													  patchIndexBuffer: nil
												patchIndexBufferOffset: 0
														indirectBuffer: mtlIndBuff
												  indirectBufferOffset: mtlIndBuffOfst];
						}

						mtlIndBuffOfst += sizeof(MTLDrawPatchIndirectArguments);
                    } else {
                        [cmdEncoder->_mtlRenderEncoder drawPrimitives: cmdEncoder->getMtlGraphics().getPrimitiveType()
                                                       indirectBuffer: mtlIndBuff
                                                 indirectBufferOffset: mtlIndBuffOfst];
                        mtlIndBuffOfst += needsInstanceAdjustment ? sizeof(MTLDrawPrimitivesIndirectArguments) : _mtlIndirectBufferStride;
                    }
                    break;
            }
        }
    }
}


#pragma mark -
#pragma mark MVKCmdDrawIndexedIndirect

typedef struct MVKVertexAdjustments {
	uint8_t mtlIndexType = MTLIndexTypeUInt16;	// Enum must match enum in shader
	bool isMultiView = false;
	bool isTriangleFan = false;
	bool isPrimRestart = true;
	bool isUint8Index = false;
	bool isProvokingVertexLast = false;

	bool needsAdjustment() { return isMultiView || isTriangleFan; }
} MVKVertexAdjustments;

VkResult MVKCmdDrawIndexedIndirect::setContent(MVKCommandBuffer* cmdBuff,
											   VkBuffer buffer,
											   VkDeviceSize offset,
											   uint32_t drawCount,
											   uint32_t stride) {
	auto* mvkBuff = (MVKBuffer*)buffer;
	return setContent(cmdBuff,
					  mvkBuff->getMTLBuffer(),
					  mvkBuff->getMTLBufferOffset() + offset,
					  drawCount,
					  stride,
					  0);
}

VkResult MVKCmdDrawIndexedIndirect::setContent(MVKCommandBuffer* cmdBuff,
											   id<MTLBuffer> indirectMTLBuff,
											   VkDeviceSize indirectMTLBuffOffset,
											   uint32_t drawCount,
											   uint32_t stride,
											   uint32_t directCmdFirstInstance) {
	_mtlIndirectBuffer = indirectMTLBuff;
	_mtlIndirectBufferOffset = indirectMTLBuffOffset;
	_mtlIndirectBufferStride = stride;
	_drawCount = drawCount;
	_directCmdFirstInstance = directCmdFirstInstance;

	// Validate
	auto& mtlFeats = cmdBuff->getMetalFeatures();
	if ( !mtlFeats.indirectDrawing ) {
		return cmdBuff->reportError(VK_ERROR_FEATURE_NOT_PRESENT, "vkCmdDrawIndexedIndirect(): The current device does not support indirect drawing.");
	}
	if (cmdBuff->_lastTessellationPipeline && !mtlFeats.indirectTessellationDrawing) {
		return cmdBuff->reportError(VK_ERROR_FEATURE_NOT_PRESENT, "vkCmdDrawIndexedIndirect(): The current device does not support indirect tessellated drawing.");
	}

	return VK_SUCCESS;
}

void MVKCmdDrawIndexedIndirect::encode(MVKCommandEncoder* cmdEncoder) {
	if ( !cmdEncoder->getGraphicsPipeline() ) { return; }	// No valid pipeline bound (see MVKCmdBindPipeline).
	cmdEncoder->restartMetalRenderPassIfNeeded();
	encode(cmdEncoder, cmdEncoder->getVkGraphics()._indexBuffer);
}

void MVKCmdDrawIndexedIndirect::encode(MVKCommandEncoder* cmdEncoder, const MVKIndexMTLBufferBinding& ibbOrig) {
	if ( !cmdEncoder->getGraphicsPipeline() ) { return; }	// No valid pipeline bound (see MVKCmdBindPipeline).

    cmdEncoder->_isIndexedDraw = true;

    MVKIndexMTLBufferBinding ibb = ibbOrig;
	MVKIndexMTLBufferBinding ibbTriFan = ibb;
    auto* pipeline = cmdEncoder->getGraphicsPipeline();
	auto& mtlFeats = cmdEncoder->getMetalFeatures();
	auto& dvcLimits = cmdEncoder->getDeviceProperties().limits;

#if MVK_XCODE_14
    if (pipeline->isGeometryPipeline()) {
        encodeGeometryIndirectDraws(cmdEncoder, pipeline, _mtlIndirectBuffer, _mtlIndirectBufferOffset,
                                    _mtlIndirectBufferStride, _drawCount, &ibb);
        return;
    }
#endif

	MVKVertexAdjustments vtxAdjmts{};
	vtxAdjmts.mtlIndexType = ibb.mtlIndexType;
	vtxAdjmts.isMultiView = (cmdEncoder->getSubpass()->isMultiview() &&
							 cmdEncoder->getPhysicalDevice()->canUseInstancingForMultiview());
	vtxAdjmts.isTriangleFan = pipeline->getVkPrimitiveTopology() == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN;
#if MVK_USE_METAL_PRIVATE_API
	// With private APIs for primitive restart, we need to handle disabled restart and raw Uint8 indices.
	vtxAdjmts.isPrimRestart = cmdEncoder->getState().vkGraphics().isPrimitiveRestartEnabled();
	vtxAdjmts.isUint8Index = ibb.vkIndexType == VK_INDEX_TYPE_UINT8;
	vtxAdjmts.isProvokingVertexLast = cmdEncoder->getState().vkGraphics().getProvokingVertexMode() == MTLProvokingVertexModeLast;
#endif

	// The indirect calls for dispatchThreadgroups:... and drawPatches:... have different formats.
    // We have to convert from the drawIndexedPrimitives:... format to them.
    // While we're at it, we can create the temporary output buffers once and reuse them
    // for each draw.
    const MVKMTLBufferAllocation* tempIndirectBuff = nullptr;
    const MVKMTLBufferAllocation* tcParamsBuff = nullptr;
    const MVKMTLBufferAllocation* vtxOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcPatchOutBuff = nullptr;
    const MVKMTLBufferAllocation* tcLevelBuff = nullptr;
    const MVKMTLBufferAllocation* vtxIndexBuff = nullptr;
    uint32_t patchCount = 0, vertexCount = 0;
    uint32_t inControlPointCount = 0, outControlPointCount = 0;
	VkDeviceSize paramsIncr = 0;

	id<MTLBuffer> mtlIndBuff = _mtlIndirectBuffer;
    VkDeviceSize mtlIndBuffOfst = _mtlIndirectBufferOffset;
    VkDeviceSize mtlTempIndBuffOfst = _mtlIndirectBufferOffset;
    VkDeviceSize mtlParmBuffOfst = 0;
    NSUInteger vtxThreadExecWidth = 0;
    NSUInteger tcWorkgroupSize = 0;

    if (pipeline->isTessellationPipeline()) {
        // We can't read the indirect buffer CPU-side, since it may change between
        // encoding and execution. So we don't know how big to make the buffers.
        // We must assume an arbitrarily large number of vertices may be submitted.
        // But not too many, or we'll exhaust available VRAM.
        inControlPointCount = cmdEncoder->getVkGraphics().getPatchControlPoints();
        outControlPointCount = pipeline->getOutputControlPointCount();
        vertexCount = kMVKMaxDrawIndirectVertexCount;
        patchCount = mvkCeilingDivide(vertexCount, inControlPointCount);
        VkDeviceSize indirectSize = (sizeof(MTLDispatchThreadgroupsIndirectArguments) + sizeof(MTLDrawPatchIndirectArguments) + sizeof(MTLStageInRegionIndirectArguments)) * _drawCount;
		paramsIncr = std::max((size_t)dvcLimits.minUniformBufferOffsetAlignment, sizeof(uint32_t) * 2);
		VkDeviceSize paramsSize = paramsIncr * _drawCount;
        tempIndirectBuff = cmdEncoder->getTempMTLBuffer(indirectSize, true);
        mtlIndBuff = tempIndirectBuff->_mtlBuffer;
        mtlTempIndBuffOfst = tempIndirectBuff->_offset;
        tcParamsBuff = cmdEncoder->getTempMTLBuffer(paramsSize, true);
        mtlParmBuffOfst = tcParamsBuff->_offset;
        if (pipeline->needsVertexOutputBuffer()) {
            vtxOutBuff = cmdEncoder->getTempMTLBuffer(vertexCount * 4 * dvcLimits.maxVertexOutputComponents, true);
        }
        if (pipeline->needsTessCtlOutputBuffer()) {
            tcOutBuff = cmdEncoder->getTempMTLBuffer(outControlPointCount * patchCount * 4 * dvcLimits.maxTessellationControlPerVertexOutputComponents, true);
        }
        if (pipeline->needsTessCtlPatchOutputBuffer()) {
            tcPatchOutBuff = cmdEncoder->getTempMTLBuffer(patchCount * 4 * dvcLimits.maxTessellationControlPerPatchOutputComponents, true);
        }
        tcLevelBuff = cmdEncoder->getTempMTLBuffer(patchCount * sizeof(MTLQuadTessellationFactorsHalf), true);
        vtxIndexBuff = cmdEncoder->getTempMTLBuffer(ibb.size, true);

        id<MTLComputePipelineState> vtxState;
        vtxState = ibb.mtlIndexType == MTLIndexTypeUInt16 ? pipeline->getTessVertexStageIndex16State() : pipeline->getTessVertexStageIndex32State();
        vtxThreadExecWidth = vtxState.threadExecutionWidth;

        NSUInteger sgSize = pipeline->getTessControlStageState().threadExecutionWidth;
        tcWorkgroupSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
        while (tcWorkgroupSize > dvcLimits.maxComputeWorkGroupSize[0]) {
            sgSize >>= 1;
            tcWorkgroupSize = mvkLeastCommonMultiple(outControlPointCount, sgSize);
        }
    } else if (vtxAdjmts.needsAdjustment()) {
        // In this case, we need to adjust the instance count for the views being drawn.
        VkDeviceSize indirectSize = sizeof(MTLDrawIndexedPrimitivesIndirectArguments) * _drawCount;
        tempIndirectBuff = cmdEncoder->getTempMTLBuffer(indirectSize, true);
        mtlIndBuff = tempIndirectBuff->_mtlBuffer;
        mtlTempIndBuffOfst = tempIndirectBuff->_offset;
		if (vtxAdjmts.isTriangleFan) {
			auto* triVtxBuff = cmdEncoder->getTempMTLBuffer(mvkMTLIndexTypeSizeInBytes((MTLIndexType)ibb.mtlIndexType) * kMVKMaxDrawIndirectVertexCount, true);
			ibb.mtlBuffer = triVtxBuff->_mtlBuffer;
			ibb.offset = triVtxBuff->_offset;
		}
    }

	MVKPiplineStages stages;
    pipeline->getStages(stages);

    for (uint32_t drawIdx = 0; drawIdx < _drawCount; drawIdx++) {
        for (uint32_t s : stages) {
            auto stage = MVKGraphicsStage(s);
            id<MTLComputeCommandEncoder> mtlTessCtlEncoder = nil;
            if (stage == kMVKGraphicsStageVertex && pipeline->isTessellationPipeline()) {
				cmdEncoder->encodeStoreActions(true);
				MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
                mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                // We need the indirect buffers now. This must be done before finalizing
                // draw state, or the pipeline will get overridden. This is a good time
                // to do it, since it will require switching to compute anyway. Do it all
                // at once to get it over with.
                if (drawIdx == 0) {
                    id<MTLComputePipelineState> mtlConvertState = cmdEncoder->getCommandEncodingPool()->getCmdDrawIndirectTessConvertBuffersMTLComputePipelineState(true);
                    state.bindPipeline(mtlTessCtlEncoder, mtlConvertState);
                    state.bindBuffer(mtlTessCtlEncoder, _mtlIndirectBuffer,           _mtlIndirectBufferOffset,  0);
                    state.bindBuffer(mtlTessCtlEncoder, tempIndirectBuff->_mtlBuffer, tempIndirectBuff->_offset, 1);
                    state.bindBuffer(mtlTessCtlEncoder, tcParamsBuff->_mtlBuffer,     tcParamsBuff->_offset,     2);
                    state.bindStructBytes(mtlTessCtlEncoder, &_mtlIndirectBufferStride, 3);
                    state.bindStructBytes(mtlTessCtlEncoder, &inControlPointCount,      4);
                    state.bindStructBytes(mtlTessCtlEncoder, &outControlPointCount,     5);
                    state.bindStructBytes(mtlTessCtlEncoder, &_drawCount,               6);
                    state.bindStructBytes(mtlTessCtlEncoder, &vtxThreadExecWidth,       7);
                    state.bindStructBytes(mtlTessCtlEncoder, &tcWorkgroupSize,          8);
                    [mtlTessCtlEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide<NSUInteger>(_drawCount, mtlConvertState.threadExecutionWidth), 1, 1)
                                      threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
                }
                // We actually need to make a copy of the index buffer, because there's no way to tell Metal to
                // offset an index buffer from a value in an indirect buffer. This also
                // means that, to make a copy, we have to use a compute shader.
                state.bindPipeline(mtlTessCtlEncoder, cmdEncoder->getCommandEncodingPool()->getCmdDrawIndexedCopyIndexBufferMTLComputePipelineState((MTLIndexType)ibb.mtlIndexType));
                state.bindBuffer(mtlTessCtlEncoder, ibb.mtlBuffer,            ibb.offset,            0);
                state.bindBuffer(mtlTessCtlEncoder, vtxIndexBuff->_mtlBuffer, vtxIndexBuff->_offset, 1);
                state.bindBuffer(mtlTessCtlEncoder, _mtlIndirectBuffer,       mtlIndBuffOfst,        2);
                [mtlTessCtlEncoder dispatchThreadgroupsWithIndirectBuffer: mtlIndBuff
													 indirectBufferOffset: mtlTempIndBuffOfst
                                                    threadsPerThreadgroup: MTLSizeMake(vtxThreadExecWidth, 1, 1)];
				mtlIndBuffOfst += sizeof(MTLDrawIndexedPrimitivesIndirectArguments);
            } else if (drawIdx == 0 && vtxAdjmts.needsAdjustment()) {
                // Similarly, for multiview, we need to adjust the instance count now.
                // Unfortunately, this requires switching to compute. Luckily, we don't also
                // have to copy the index buffer.
                // TODO: Consider using tile shaders to avoid this cost.
				cmdEncoder->encodeStoreActions(true);
				MVKMetalComputeCommandEncoderState& state = cmdEncoder->getMtlCompute();
				id<MTLComputeCommandEncoder> mtlConvertEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseDrawIndirectConvertBuffers);
				id<MTLComputePipelineState> mtlConvertState = cmdEncoder->getCommandEncodingPool()->getCmdDrawIndirectConvertBuffersMTLComputePipelineState(true);
				uint32_t viewCount = cmdEncoder->getSubpass()->getViewCountInMetalPass(cmdEncoder->getMultiviewPassIndex());
				state.bindPipeline(mtlConvertEncoder, mtlConvertState);
				state.bindBuffer(mtlConvertEncoder, _mtlIndirectBuffer,           _mtlIndirectBufferOffset,  0);
				state.bindBuffer(mtlConvertEncoder, tempIndirectBuff->_mtlBuffer, tempIndirectBuff->_offset, 1);
				state.bindStructBytes(mtlConvertEncoder, &_mtlIndirectBufferStride, 2);
				state.bindStructBytes(mtlConvertEncoder, &_drawCount,               3);
				state.bindStructBytes(mtlConvertEncoder, &viewCount,                4);
				state.bindStructBytes(mtlConvertEncoder, &vtxAdjmts,                5);
				state.bindBuffer(mtlConvertEncoder, ibb.mtlBuffer,       ibb.offset,       6);
				state.bindBuffer(mtlConvertEncoder, ibbTriFan.mtlBuffer, ibbTriFan.offset, 7);
				if (mtlFeats.nonUniformThreadgroups) {
					[mtlConvertEncoder dispatchThreads: MTLSizeMake(_drawCount, 1, 1)
								 threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
				} else {
					[mtlConvertEncoder dispatchThreadgroups: MTLSizeMake(mvkCeilingDivide<NSUInteger>(_drawCount, mtlConvertState.threadExecutionWidth), 1, 1)
									  threadsPerThreadgroup: MTLSizeMake(mtlConvertState.threadExecutionWidth, 1, 1)];
				}
				// Switch back to rendering now, since we don't have compute stages to run anyway.
                cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);
            }

	        cmdEncoder->finalizeDrawState(stage);	// Ensure all updated state has been submitted to Metal

			if ( !pipeline->hasValidMTLPipelineStates() ) { return; }	// Abort if this pipeline stage could not be compiled.

            switch (stage) {
                case kMVKGraphicsStageVertex:
                    mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                    if (pipeline->needsVertexOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                             offset: vtxOutBuff->_offset
                                            atIndex: pipeline->getImplicitBuffers(kMVKShaderStageVertex).ids[MVKImplicitBuffer::Output]];
                    }
					[mtlTessCtlEncoder setBuffer: vtxIndexBuff->_mtlBuffer
										  offset: vtxIndexBuff->_offset
										 atIndex: pipeline->getImplicitBuffers(kMVKShaderStageVertex).ids[MVKImplicitBuffer::Index]];
					[mtlTessCtlEncoder setStageInRegion: MTLRegionMake2D(0, 0, vertexCount, vertexCount)];
					[mtlTessCtlEncoder setStageInRegionWithIndirectBuffer: mtlIndBuff
						                             indirectBufferOffset: mtlTempIndBuffOfst];
					mtlTempIndBuffOfst += sizeof(MTLStageInRegionIndirectArguments);
					// If this is a synthetic command that originated in a direct call, and there are vertex bindings with a zero vertex
					// divisor, I need to offset them by _firstInstance * stride, since that is the expected behaviour for a divisor of 0.
					cmdEncoder->getState().offsetZeroDivisorVertexBuffers(*cmdEncoder, stage, pipeline, _directCmdFirstInstance);
					[mtlTessCtlEncoder dispatchThreadgroupsWithIndirectBuffer: mtlIndBuff
														 indirectBufferOffset: mtlTempIndBuffOfst
														threadsPerThreadgroup: MTLSizeMake(vtxThreadExecWidth, 1, 1)];
					mtlTempIndBuffOfst += sizeof(MTLDispatchThreadgroupsIndirectArguments);
                    break;
                case kMVKGraphicsStageTessControl:
                    mtlTessCtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl);
                    if (pipeline->needsTessCtlOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: tcOutBuff->_mtlBuffer
                                              offset: tcOutBuff->_offset
                                             atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::Output]];
                    }
                    if (pipeline->needsTessCtlPatchOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: tcPatchOutBuff->_mtlBuffer
                                              offset: tcPatchOutBuff->_offset
                                             atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::PatchOutput]];
                    }
                    [mtlTessCtlEncoder setBuffer: tcLevelBuff->_mtlBuffer
                                          offset: tcLevelBuff->_offset
                                         atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::TessLevel]];
					[mtlTessCtlEncoder setBuffer: tcParamsBuff->_mtlBuffer
										  offset: mtlParmBuffOfst
										 atIndex: pipeline->getImplicitBuffers(kMVKShaderStageTessCtl).ids[MVKImplicitBuffer::IndirectParams]];
					mtlParmBuffOfst += paramsIncr;
                    if (pipeline->needsVertexOutputBuffer()) {
                        [mtlTessCtlEncoder setBuffer: vtxOutBuff->_mtlBuffer
                                              offset: vtxOutBuff->_offset
                                             atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessCtlInputBufferBinding)];
                    }
                    [mtlTessCtlEncoder dispatchThreadgroupsWithIndirectBuffer: mtlIndBuff
                                                         indirectBufferOffset: mtlTempIndBuffOfst
                                                        threadsPerThreadgroup: MTLSizeMake(tcWorkgroupSize, 1, 1)];
                    mtlTempIndBuffOfst += sizeof(MTLDispatchThreadgroupsIndirectArguments);
                    // Running this stage prematurely ended the render pass, so we have to start it up again.
                    // TODO: On iOS, maybe we could use a tile shader to avoid this.
                    cmdEncoder->beginMetalRenderPass(kMVKCommandUseRestartSubpass);
                    break;
                case kMVKGraphicsStageRasterization:
                    if (pipeline->isTessellationPipeline()) {
						if (mtlFeats.indirectTessellationDrawing) {
							if (pipeline->needsTessCtlOutputBuffer()) {
								[cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcOutBuff->_mtlBuffer
																		offset: tcOutBuff->_offset
																	   atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalInputBufferBinding)];
							}
							if (pipeline->needsTessCtlPatchOutputBuffer()) {
								[cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcPatchOutBuff->_mtlBuffer
																		offset: tcPatchOutBuff->_offset
																	   atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalPatchInputBufferBinding)];
							}
							[cmdEncoder->_mtlRenderEncoder setVertexBuffer: tcLevelBuff->_mtlBuffer
																	offset: tcLevelBuff->_offset
																   atIndex: cmdEncoder->getDevice()->getMetalBufferIndexForVertexAttributeBinding(kMVKTessEvalLevelBufferBinding)];
							[cmdEncoder->_mtlRenderEncoder setTessellationFactorBuffer: tcLevelBuff->_mtlBuffer
																				offset: tcLevelBuff->_offset
																		instanceStride: 0];
							[cmdEncoder->_mtlRenderEncoder drawPatches: outControlPointCount
							                          patchIndexBuffer: nil
							                    patchIndexBufferOffset: 0
							                            indirectBuffer: mtlIndBuff
							                      indirectBufferOffset: mtlTempIndBuffOfst];
						}

						mtlTempIndBuffOfst += sizeof(MTLDrawPatchIndirectArguments);
                    } else {
						cmdEncoder->getState().offsetZeroDivisorVertexBuffers(*cmdEncoder, stage, pipeline, _directCmdFirstInstance);
                        [cmdEncoder->_mtlRenderEncoder drawIndexedPrimitives: cmdEncoder->getMtlGraphics().getPrimitiveType()
                                                                   indexType: (MTLIndexType)ibb.mtlIndexType
                                                                 indexBuffer: ibb.mtlBuffer
                                                           indexBufferOffset: ibb.offset
                                                              indirectBuffer: mtlIndBuff
                                                        indirectBufferOffset: mtlTempIndBuffOfst];
                        mtlTempIndBuffOfst += vtxAdjmts.needsAdjustment() ? sizeof(MTLDrawIndexedPrimitivesIndirectArguments) : _mtlIndirectBufferStride;
                    }
                    break;
            }
        }
    }
}

