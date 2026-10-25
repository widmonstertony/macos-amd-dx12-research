/*
 * MVKCmdDispatch.mm
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

#include "MVKCmdDispatch.h"
#include "MVKCommandBuffer.h"
#include "MVKCommandPool.h"
#include "MVKBuffer.h"
#include "MVKPipeline.h"
#include "MVKFoundation.h"
#include "MVKQueueDependencyTrace.h"
#include "mvk_datatypes.hpp"

static uint64_t mvkNextDispatchTraceID() {
    static std::atomic<uint64_t> sequence{0};
    return sequence.fetch_add(1, std::memory_order_relaxed) + 1;
}

#pragma mark -
#pragma mark MVKCmdDispatch

VkResult MVKCmdDispatch::setContent(MVKCommandBuffer* cmdBuff,
									uint32_t baseGroupX, uint32_t baseGroupY, uint32_t baseGroupZ,
									uint32_t groupCountX, uint32_t groupCountY, uint32_t groupCountZ) {
	_baseGroupX = baseGroupX;
	_baseGroupY = baseGroupY;
	_baseGroupZ = baseGroupZ;

	_groupCountX = groupCountX;
	_groupCountY = groupCountY;
	_groupCountZ = groupCountZ;

	return VK_SUCCESS;
}

void MVKCmdDispatch::encode(MVKCommandEncoder* cmdEncoder) {
	if ( !cmdEncoder->getComputePipeline() ) { return; }	// No valid pipeline bound (see MVKCmdBindPipeline).
	MTLRegion mtlThreadgroupCount = MTLRegionMake3D(_baseGroupX, _baseGroupY, _baseGroupZ, _groupCountX, _groupCountY, _groupCountZ);
	cmdEncoder->finalizeDispatchState();	// Ensure all updated state has been submitted to Metal
	id<MTLComputeCommandEncoder> mtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseDispatch);
	auto* pipeline = cmdEncoder->getComputePipeline();
	uint64_t dispatchID = 0;
	if (mvkEncoderWorkTraceEnabled()) {
		dispatchID = mvkNextDispatchTraceID();
		auto& bits = cmdEncoder->getMtlCompute()._exists;
		uint32_t buffers = 0, textures = 0, samplers = 0, sets = 0;
		for (auto word : bits.buffers.setBitsList()) for (auto bit : word) { (void)bit; ++buffers; }
		for (auto word : bits.textures.setBitsList()) for (auto bit : word) { (void)bit; ++textures; }
		for (auto word : bits.samplers.setBitsList()) for (auto bit : word) { (void)bit; ++samplers; }
		for (auto word : bits.descriptorSetData.setBitsList()) for (auto bit : word) { (void)bit; ++sets; }
		MTLSize threads = pipeline->getThreadgroupSize();
		mvkRecordEncoderWorkImpl(mtlEncoder, @"dispatch", [NSString stringWithFormat:
			@"dispatchID=%llu;mode=direct;pipeline=%@;nativePSO=%p;base=%ux%ux%u;groups=%ux%ux%u;threads=%lux%lux%lu;buffers=%u;textures=%u;samplers=%u;sets=%u",
			(unsigned long long)dispatchID, cmdEncoder->getMtlCompute()._pipeline.label ?: @"", (void*)cmdEncoder->getMtlCompute()._pipeline,
			_baseGroupX, _baseGroupY, _baseGroupZ, _groupCountX, _groupCountY, _groupCountZ,
			(unsigned long)threads.width, (unsigned long)threads.height, (unsigned long)threads.depth,
			buffers, textures, samplers, sets]);
	}
	if (pipeline->allowsDispatchBase()) {
		// We'll use the stage-input region to pass the base along to the shader.
		// Hopefully Metal won't complain that we didn't set up a stage-input descriptor.
		[mtlEncoder setStageInRegion: mtlThreadgroupCount];
	}
	[mtlEncoder dispatchThreadgroups: mtlThreadgroupCount.size
			   threadsPerThreadgroup: pipeline->getThreadgroupSize()];
	if (dispatchID && mvkGPUTimestampArmed()) {
		mvkRecordEncoderWorkImpl(mtlEncoder, @"dispatch-end", [NSString stringWithFormat:
			@"dispatchID=%llu;mode=direct;pipeline=%@;nativePSO=%p", (unsigned long long)dispatchID,
			cmdEncoder->getMtlCompute()._pipeline.label ?: @"", (void*)cmdEncoder->getMtlCompute()._pipeline]);
	}
}


#pragma mark -
#pragma mark MVKCmdDispatchIndirect

VkResult MVKCmdDispatchIndirect::setContent(MVKCommandBuffer* cmdBuff, VkBuffer buffer, VkDeviceSize offset) {
	MVKBuffer* mvkBuffer = (MVKBuffer*)buffer;
	_mtlIndirectBuffer = mvkBuffer->getMTLBuffer();
	_mtlIndirectBufferOffset = mvkBuffer->getMTLBufferOffset() + offset;

	return VK_SUCCESS;
}

void MVKCmdDispatchIndirect::encode(MVKCommandEncoder* cmdEncoder) {
	if ( !cmdEncoder->getComputePipeline() ) { return; }	// No valid pipeline bound (see MVKCmdBindPipeline).
    cmdEncoder->finalizeDispatchState();	// Ensure all updated state has been submitted to Metal
	id<MTLComputeCommandEncoder> mtlEncoder = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseDispatch);
	uint64_t dispatchID = 0;
	if (mvkEncoderWorkTraceEnabled()) {
		dispatchID = mvkNextDispatchTraceID();
		MTLSize threads = cmdEncoder->getComputePipeline()->getThreadgroupSize();
		uint64_t length = _mtlIndirectBuffer.length;
		uint64_t available = _mtlIndirectBufferOffset < length ? length - _mtlIndirectBufferOffset : 0;
		mvkRecordEncoderWorkImpl(mtlEncoder, @"dispatch-indirect", [NSString stringWithFormat:
			@"dispatchID=%llu;mode=indirect;pipeline=%@;nativePSO=%p;indirectBuffer=%p;indirectOffset=%llu;indirectBytes=%llu;availableBytes=%llu;threads=%lux%lux%lu;indirectArgumentsCaptured=0",
			(unsigned long long)dispatchID, cmdEncoder->getMtlCompute()._pipeline.label ?: @"", (void*)cmdEncoder->getMtlCompute()._pipeline,
			(void*)_mtlIndirectBuffer, (unsigned long long)_mtlIndirectBufferOffset, (unsigned long long)length,
			(unsigned long long)available, (unsigned long)threads.width, (unsigned long)threads.height, (unsigned long)threads.depth]);
	}
    [mtlEncoder dispatchThreadgroupsWithIndirectBuffer: _mtlIndirectBuffer
																				indirectBufferOffset: _mtlIndirectBufferOffset
																			   threadsPerThreadgroup: cmdEncoder->getComputePipeline()->getThreadgroupSize()];
	if (dispatchID && mvkGPUTimestampArmed()) {
		mvkRecordEncoderWorkImpl(mtlEncoder, @"dispatch-end", [NSString stringWithFormat:
			@"dispatchID=%llu;mode=indirect;pipeline=%@;nativePSO=%p", (unsigned long long)dispatchID,
			cmdEncoder->getMtlCompute()._pipeline.label ?: @"", (void*)cmdEncoder->getMtlCompute()._pipeline]);
	}
}

