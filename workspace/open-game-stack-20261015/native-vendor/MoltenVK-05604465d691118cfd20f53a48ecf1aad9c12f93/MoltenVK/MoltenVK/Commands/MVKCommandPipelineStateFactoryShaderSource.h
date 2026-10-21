/*
 * MVKCommandPipelineStateFactoryShaderSource.h
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

#include "MVKDevice.h"

#import <Foundation/Foundation.h>


/** This file contains static MSL source code for the MoltenVK command shaders. */

static NSString* _MVKStaticCmdShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

typedef struct {
	float2 a_position [[attribute(0)]];
	float3 a_texCoord [[attribute(1)]];
} AttributesPosTex;

typedef struct {
	float4 v_position [[position]];
	float3 v_texCoord;
} VaryingsPosTex;

typedef struct {
	float4 v_position [[position]];
	float3 v_texCoord;
	uint v_layer [[render_target_array_index]];
} VaryingsPosTexLayer;

typedef size_t VkDeviceSize;

typedef enum : uint32_t {
	VK_FORMAT_BC1_RGB_UNORM_BLOCK = 131,
	VK_FORMAT_BC1_RGB_SRGB_BLOCK = 132,
	VK_FORMAT_BC1_RGBA_UNORM_BLOCK = 133,
	VK_FORMAT_BC1_RGBA_SRGB_BLOCK = 134,
	VK_FORMAT_BC2_UNORM_BLOCK = 135,
	VK_FORMAT_BC2_SRGB_BLOCK = 136,
	VK_FORMAT_BC3_UNORM_BLOCK = 137,
	VK_FORMAT_BC3_SRGB_BLOCK = 138,
} VkFormat;

typedef struct {
	uint32_t width;
	uint32_t height;
} VkExtent2D;

typedef struct {
	uint32_t width;
	uint32_t height;
	uint32_t depth;
} __attribute__((packed)) VkExtent3D;

typedef struct {
	int32_t x;
	int32_t y;
	int32_t z;
} __attribute__((packed)) VkOffset3D;
)"
#define MVK_DECOMPRESS_CODE(...) #__VA_ARGS__
#include "MVKDXTnCodec.def"
#undef MVK_DECOMPRESS_CODE
R"(
vertex VaryingsPosTex vtxCmdBlitImage(AttributesPosTex attributes [[stage_in]]) {
	VaryingsPosTex varyings;
	varyings.v_position = float4(attributes.a_position, 0.0, 1.0);
	varyings.v_texCoord = attributes.a_texCoord;
	return varyings;
}

vertex VaryingsPosTexLayer vtxCmdBlitImageLayered(AttributesPosTex attributes [[stage_in]],
                                                  uint instanceID [[instance_id]],
                                                  constant float &zIncr [[buffer(0)]]) {
	VaryingsPosTexLayer varyings;
	varyings.v_position = float4(attributes.a_position, 0.0, 1.0);
	varyings.v_texCoord = float3(attributes.a_texCoord.xy, attributes.a_texCoord.z + (instanceID + 0.5) * zIncr);
	varyings.v_layer = instanceID;
	return varyings;
}

typedef struct {
	uint32_t srcOffset;
	uint32_t dstOffset;
	uint32_t size;
} CopyInfo;

kernel void cmdCopyBufferBytes(device uint8_t* src [[ buffer(0) ]],
                               device uint8_t* dst [[ buffer(1) ]],
                               constant CopyInfo& info [[ buffer(2) ]],
                               uint index [[thread_position_in_grid]]) {
    if (index < info.size) {
        // Vulkan forbids overlapping source/destination copy ranges. Widen
        // before adding offsets so the last byte cannot wrap a uint32_t.
        size_t i = size_t(index);
        dst[i + info.dstOffset] = src[i + info.srcOffset];
    }
}

kernel void cmdFillBuffer(device uint32_t* dst [[ buffer(0) ]],
                          constant uint32_t& fillValue [[ buffer(1) ]],
                          uint pos [[thread_position_in_grid]]) {
	dst[pos] = fillValue;
}

kernel void cmdClearColorImage2DFloat(texture2d<float, access::write> dst [[ texture(0) ]],
                                      constant float4& clearValue [[ buffer(0) ]],
                                      uint2 pos [[thread_position_in_grid]]) {
	dst.write(clearValue, pos);
}

kernel void cmdClearColorImage2DFloatArray(texture2d_array<float, access::write> dst [[ texture(0) ]],
                                           constant float4& clearValue [[ buffer(0) ]],
                                           uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < dst.get_array_size(); ++i) {
		dst.write(clearValue, pos, i);
	}
}

kernel void cmdClearColorImage2DUInt(texture2d<uint, access::write> dst [[ texture(0) ]],
                                     constant uint4& clearValue [[ buffer(0) ]],
                                     uint2 pos [[thread_position_in_grid]]) {
	dst.write(clearValue, pos);
}

kernel void cmdClearColorImage2DUIntArray(texture2d_array<uint, access::write> dst [[ texture(0) ]],
                                          constant uint4& clearValue [[ buffer(0) ]],
                                          uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < dst.get_array_size(); ++i) {
		dst.write(clearValue, pos, i);
	}
}

kernel void cmdClearColorImage2DInt(texture2d<int, access::write> dst [[ texture(0) ]],
                                    constant int4& clearValue [[ buffer(0) ]],
                                    uint2 pos [[thread_position_in_grid]]) {
	dst.write(clearValue, pos);
}

kernel void cmdClearColorImage2DIntArray(texture2d_array<int, access::write> dst [[ texture(0) ]],
                                         constant int4& clearValue [[ buffer(0) ]],
                                         uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < dst.get_array_size(); ++i) {
		dst.write(clearValue, pos, i);
	}
}

kernel void cmdResolveColorImage2DFloat(texture2d<float, access::write> dst [[ texture(0) ]],
                                        texture2d_ms<float, access::read> src [[ texture(1) ]],
                                        uint2 pos [[thread_position_in_grid]]) {
	dst.write(src.read(pos, 0), pos);
}

#if __HAVE_TEXTURE_2D_MS_ARRAY__
kernel void cmdResolveColorImage2DFloatArray(texture2d_array<float, access::write> dst [[ texture(0) ]],
                                             texture2d_ms_array<float, access::read> src [[ texture(1) ]],
                                             uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < src.get_array_size(); ++i) {
		dst.write(src.read(pos, i, 0), pos, i);
	}
}
#endif

kernel void cmdResolveColorImage2DUInt(texture2d<uint, access::write> dst [[ texture(0) ]],
                                       texture2d_ms<uint, access::read> src [[ texture(1) ]],
                                       uint2 pos [[thread_position_in_grid]]) {
	dst.write(src.read(pos, 0), pos);
}

#if __HAVE_TEXTURE_2D_MS_ARRAY__
kernel void cmdResolveColorImage2DUIntArray(texture2d_array<uint, access::write> dst [[ texture(0) ]],
                                            texture2d_ms_array<uint, access::read> src [[ texture(1) ]],
                                            uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < src.get_array_size(); ++i) {
		dst.write(src.read(pos, i, 0), pos, i);
	}
}
#endif

kernel void cmdResolveColorImage2DInt(texture2d<int, access::write> dst [[ texture(0) ]],
                                      texture2d_ms<int, access::read> src [[ texture(1) ]],
                                      uint2 pos [[thread_position_in_grid]]) {
	dst.write(src.read(pos, 0), pos);
}

#if __HAVE_TEXTURE_2D_MS_ARRAY__
kernel void cmdResolveColorImage2DIntArray(texture2d_array<int, access::write> dst [[ texture(0) ]],
                                           texture2d_ms_array<int, access::read> src [[ texture(1) ]],
                                           uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < src.get_array_size(); ++i) {
		dst.write(src.read(pos, i, 0), pos, i);
	}
}
#endif

// This structure is missing from the MSL headers. :/
struct MTLStageInRegionIndirectArguments {
	uint32_t stageInOrigin[3];
	uint32_t stageInSize[3];
};

typedef enum : uint8_t {
	MTLIndexTypeUInt16 = 0,
	MTLIndexTypeUInt32 = 1,
} MTLIndexType;

typedef struct MVKVtxAdj {
	MTLIndexType idxType;
	bool isMultiView;
	bool isTriFan;
	bool isPrimRestart;
	bool isUint8Index;
	bool isProvokingVertexLast;
} MVKVtxAdj;

// Populates triangle vertex indexes for a triangle fan.
template<typename T>
static inline void populateTriIndxsFromTriFan(device T* triIdxs,
                                              constant T* triFanIdxs,
                                              uint32_t triFanIdxCnt,
                                              constant MVKVtxAdj& vtxAdj) {
	T primRestartSentinel = vtxAdj.isUint8Index ? (T)0xFF : (T)0xFFFFFFFF;
	uint32_t triIdxIdx = 0;
	uint32_t triFanBaseIdx = 0;
	uint32_t triFanIdxIdx = triFanBaseIdx + 2;
	while (triFanIdxIdx < triFanIdxCnt) {
		uint32_t triFanBaseIdxCurr = triFanBaseIdx;

		// Detect primitive restart on any index, to catch possible consecutive restarts
		T triIdx0 = triFanIdxs[triFanBaseIdx];
		if (vtxAdj.isPrimRestart && triIdx0 == primRestartSentinel)
			triFanBaseIdx++;

		T triIdx1 = triFanIdxs[triFanIdxIdx - 1];
		if (vtxAdj.isPrimRestart && triIdx1 == primRestartSentinel)
			triFanBaseIdx = triFanIdxIdx;

		T triIdx2 = triFanIdxs[triFanIdxIdx];
		if (vtxAdj.isPrimRestart && triIdx2 == primRestartSentinel)
			triFanBaseIdx = triFanIdxIdx + 1;

		if (triFanBaseIdx != triFanBaseIdxCurr) {    // Restart the triangle fan
			triFanIdxIdx = triFanBaseIdx + 2;
		} else {
			// Provoking vertex is 1 in triangle fan but 0 in triangle list
			triIdxs[triIdxIdx++] = vtxAdj.isProvokingVertexLast ? triIdx0 : triIdx1;
			triIdxs[triIdxIdx++] = vtxAdj.isProvokingVertexLast ? triIdx1 : triIdx2;
			triIdxs[triIdxIdx++] = vtxAdj.isProvokingVertexLast ? triIdx2 : triIdx0;
			triFanIdxIdx++;
		}
	}
}

kernel void cmdDrawIndirectPopulateIndexes(const device char* srcBuff [[buffer(0)]],
                                           device MTLDrawIndexedPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                           constant uint32_t& srcStride [[buffer(2)]],
                                           constant uint32_t& drawCount [[buffer(3)]],
                                           device uint32_t* idxBuff [[buffer(4)]],
                                           uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	device auto& dst = destBuff[idx];
	dst.indexCount = src.vertexCount;
	dst.indexStart = src.vertexStart;
	dst.baseVertex = 0;
	dst.instanceCount = src.instanceCount;
	dst.baseInstance = src.baseInstance;

	for (uint32_t idxIdx = 0; idxIdx < dst.indexCount; idxIdx++) {
		uint32_t idxBuffIdx = dst.indexStart + idxIdx;
		idxBuff[idxBuffIdx] = idxBuffIdx;
	}
}

typedef struct {
	uint64_t indexBuffer;
	uint32_t indexed;
	uint32_t indexSize;
	uint32_t vertsPerPrim;
	uint32_t topology;          // 0 list, 1 strip, 2 fan
	uint32_t vertexStrides[31];
	uint32_t vertexDivisors[31];
} MVKGeometryIndirectParams;

typedef struct {
	int32_t indexed;
	int32_t indexSize;
	int64_t indexBuffer;
	int32_t baseVertex;
	uint32_t baseInstance;
	uint32_t vertexStrides[31];
	uint32_t vertexDivisors[31];
	uint8_t topoStrip;
} MVKGeometryDrawInfo;

// Converts Vulkan indirect draws (VkDrawIndirectCommand or VkDrawIndexedIndirectCommand) for a
// geometry-shader (object + mesh) pipeline: mesh threadgroups = primitives x instances, and the
// DrawInfo the object stage reads (index buffer at firstIndex, base vertex, base instance).
// Fragment function of geometry-shader (mesh) pipelines that rasterize without a Vulkan fragment shader.
fragment void fragCmdMeshWithoutFragmentShader() {}

kernel void cmdCopyUint32(device uint* dst [[buffer(0)]],
                          const device uint* src [[buffer(1)]]) {
	dst[0] = src[0];
}

// Transform feedback of a geometry-shader (mesh) draw: turns the number of vertices each input primitive
// captured (counting pass) into the vertex slot of its first vertex, or 0xffffffff if the primitive does
// not fit in every bound transform feedback buffer, and advances the byte offsets of the buffers by the
// vertices written. Session state as in MVKCommandEncoder::_xfbSession. One threadgroup.
// With an active transform feedback query (vertsPerPrim = vertices of each output primitive, 0 without
// a query), adds the primitives written and the primitives needed to its two 64-bit results.
kernel void cmdXfbScanPrimitives(device uint* prims [[buffer(0)]],
                                 device uint* session [[buffer(1)]],
                                 constant uint& count [[buffer(2)]],
                                 device ulong* query [[buffer(3)]],
                                 constant uint& vertsPerPrim [[buffer(4)]],
                                 uint lid [[thread_index_in_threadgroup]],
                                 uint tgSize [[threads_per_threadgroup]]) {
	threadgroup uint sums[1024];
	threadgroup uint carry;
	threadgroup atomic_uint written;
	uint used = session[12];
	uint capacity = 0xFFFFFFFFu;
	for (uint b = 0; b < 4; b++) {
		uint size = session[b], start = session[4 + b], stride = session[8 + b];
		if ((used & (1u << b)) && size && stride) {
			capacity = min(capacity, size > start ? (size - start) / stride : 0u);
		}
	}
	if (lid == 0) {
		carry = 0;
		atomic_store_explicit(&written, 0u, memory_order_relaxed);
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	for (uint base = 0; base < count; base += tgSize) {
		uint i = base + lid;
		uint c = i < count ? prims[i] : 0u;
		sums[lid] = c;
		threadgroup_barrier(mem_flags::mem_threadgroup);
		for (uint off = 1; off < tgSize; off <<= 1) {
			uint v = lid >= off ? sums[lid - off] : 0u;
			threadgroup_barrier(mem_flags::mem_threadgroup);
			sums[lid] += v;
			threadgroup_barrier(mem_flags::mem_threadgroup);
		}
		uint first = carry + sums[lid] - c;
		bool fits = ulong(first) + c <= capacity;
		if (i < count) {
			prims[i] = fits ? first : 0xFFFFFFFFu;
			if (fits && c) { atomic_fetch_max_explicit(&written, first + c, memory_order_relaxed); }
		}
		threadgroup_barrier(mem_flags::mem_threadgroup);
		if (lid == tgSize - 1) { carry += sums[lid]; }
		threadgroup_barrier(mem_flags::mem_threadgroup);
	}
	if (lid == 0) {
		uint w = atomic_load_explicit(&written, memory_order_relaxed);
		for (uint b = 0; b < 4; b++) {
			session[16 + b] = session[4 + b];	// Where this draw writes
			if (used & (1u << b)) { session[4 + b] += w * session[8 + b]; }
		}
		if (vertsPerPrim) {
			query[0] += w / vertsPerPrim;		// Primitives written
			query[1] += carry / vertsPerPrim;	// Primitives needed: every captured vertex was counted
		}
	}
}

kernel void cmdDrawIndirectGeometryConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                                  device MTLDispatchThreadgroupsIndirectArguments* destDispatch [[buffer(1)]],
                                                  device char* destDrawInfo [[buffer(2)]],
                                                  constant uint32_t& srcStride [[buffer(3)]],
                                                  constant uint32_t& drawCount [[buffer(4)]],
                                                  constant MVKGeometryIndirectParams& params [[buffer(5)]],
                                                  constant uint32_t& drawInfoStride [[buffer(6)]],
                                                  uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device uint32_t* src = reinterpret_cast<const device uint32_t*>(srcBuff + idx * srcStride);
	uint32_t count = src[0];
	uint32_t instanceCount = src[1];
	uint32_t firstIndex = 0;
	int32_t baseVertex;
	uint32_t baseInstance;
	if (params.indexed) {
		firstIndex = src[2];
		baseVertex = as_type<int32_t>(src[3]);
		baseInstance = src[4];
	} else {
		baseVertex = int32_t(src[2]);
		baseInstance = src[3];
	}
	uint32_t primCount;
	if (params.topology == 2) {
		primCount = count >= 3 ? count - 2 : 0;			// Triangle fan
	} else if (params.topology == 1 && params.vertsPerPrim == 6) {
		primCount = count >= 6 ? (count - 4) / 2 : 0;	// Triangle strip with adjacency
	} else if (params.topology == 1) {
		primCount = count >= params.vertsPerPrim ? count - params.vertsPerPrim + 1 : 0;
	} else {
		primCount = count / params.vertsPerPrim;
	}
	destDispatch[idx].threadgroupsPerGrid[0] = primCount;
	destDispatch[idx].threadgroupsPerGrid[1] = primCount ? instanceCount : 0;
	destDispatch[idx].threadgroupsPerGrid[2] = 1;

	device auto& drawInfo = *reinterpret_cast<device MVKGeometryDrawInfo*>(destDrawInfo + idx * drawInfoStride);
	drawInfo.indexed = int32_t(params.indexed);
	drawInfo.indexSize = int32_t(params.indexSize);
	drawInfo.indexBuffer = int64_t(params.indexBuffer + uint64_t(firstIndex) * params.indexSize);
	drawInfo.baseVertex = baseVertex;
	drawInfo.baseInstance = baseInstance;
	for (uint i = 0; i < 31; i++) {
		drawInfo.vertexStrides[i] = params.vertexStrides[i];
		drawInfo.vertexDivisors[i] = params.vertexDivisors[i];
	}
	drawInfo.topoStrip = uint8_t(params.topology);
}

kernel void cmdDrawIndirectConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                          device MTLDrawPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                          constant uint32_t& srcStride [[buffer(2)]],
                                          constant uint32_t& drawCount [[buffer(3)]],
                                          constant uint32_t& viewCount [[buffer(4)]],
                                          uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	destBuff[idx] = src;
	destBuff[idx].instanceCount *= viewCount;
}

kernel void cmdDrawIndexedIndirectConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                                 device MTLDrawIndexedPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                                 constant uint32_t& srcStride [[buffer(2)]],
                                                 constant uint32_t& drawCount [[buffer(3)]],
                                                 constant uint32_t& viewCount [[buffer(4)]],
                                                 constant MVKVtxAdj& vtxAdj [[buffer(5)]],
                                                 device void* triIdxs [[buffer(6)]],
                                                 constant void* triFanIdxs [[buffer(7)]],
                                                 uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawIndexedPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	destBuff[idx] = src;

	device auto& dst = destBuff[idx];
	if (vtxAdj.isMultiView) {
		dst.instanceCount *= viewCount;
	}
	if (vtxAdj.isTriFan) {
		dst.indexCount = (src.indexCount - 2) * 3;
		switch (vtxAdj.idxType) {
			case MTLIndexTypeUInt16:
				populateTriIndxsFromTriFan(&((device uint16_t*)triIdxs)[dst.indexStart],
				                           &((constant uint16_t*)triFanIdxs)[src.indexStart],
				                           src.indexCount,
				                           vtxAdj);
				break;
			case MTLIndexTypeUInt32:
				populateTriIndxsFromTriFan(&((device uint32_t*)triIdxs)[dst.indexStart],
				                           &((constant uint32_t*)triFanIdxs)[src.indexStart],
				                           src.indexCount,
				                           vtxAdj);
				break;
		}
	}
}

kernel void cmdDrawIndirectTessConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                              device char* destBuff [[buffer(1)]],
                                              device char* paramsBuff [[buffer(2)]],
                                              constant uint32_t& srcStride [[buffer(3)]],
                                              constant uint32_t& inControlPointCount [[buffer(4)]],
                                              constant uint32_t& outControlPointCount [[buffer(5)]],
                                              constant uint32_t& drawCount [[buffer(6)]],
                                              constant uint32_t& vtxThreadExecWidth [[buffer(7)]],
                                              constant uint32_t& tcWorkgroupSize [[buffer(8)]],
                                              uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	device char* dest;
	device auto* params = reinterpret_cast<device uint32_t*>(paramsBuff + idx * 256);
	dest = destBuff + idx * (sizeof(MTLStageInRegionIndirectArguments) + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2 + sizeof(MTLDrawPatchIndirectArguments));
	device auto& destSI = *(device MTLStageInRegionIndirectArguments*)dest;
	dest += sizeof(MTLStageInRegionIndirectArguments);
	device auto& destVtx = *(device MTLDispatchThreadgroupsIndirectArguments*)dest;
	device auto& destTC = *(device MTLDispatchThreadgroupsIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments));
	device auto& destTE = *(device MTLDrawPatchIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2);
	uint32_t patchCount = (src.vertexCount * src.instanceCount + inControlPointCount - 1) / inControlPointCount;
	params[0] = inControlPointCount;
	params[1] = patchCount;
	destVtx.threadgroupsPerGrid[0] = (src.vertexCount + vtxThreadExecWidth - 1) / vtxThreadExecWidth;
	destVtx.threadgroupsPerGrid[1] = src.instanceCount;
	destVtx.threadgroupsPerGrid[2] = 1;
	destTC.threadgroupsPerGrid[0] = (patchCount * outControlPointCount + tcWorkgroupSize - 1) / tcWorkgroupSize;
	destTC.threadgroupsPerGrid[1] = destTC.threadgroupsPerGrid[2] = 1;
	destTE.patchCount = patchCount;
	destTE.instanceCount = 1;
	destTE.patchStart = destTE.baseInstance = 0;
	destSI.stageInOrigin[0] = src.vertexStart;
	destSI.stageInOrigin[1] = src.baseInstance;
	destSI.stageInOrigin[2] = 0;
	destSI.stageInSize[0] = src.vertexCount;
	destSI.stageInSize[1] = src.instanceCount;
	destSI.stageInSize[2] = 1;
}

kernel void cmdDrawIndexedIndirectTessConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                                     device char* destBuff [[buffer(1)]],
                                                     device char* paramsBuff [[buffer(2)]],
                                                     constant uint32_t& srcStride [[buffer(3)]],
                                                     constant uint32_t& inControlPointCount [[buffer(4)]],
                                                     constant uint32_t& outControlPointCount [[buffer(5)]],
                                                     constant uint32_t& drawCount [[buffer(6)]],
                                                     constant uint32_t& vtxThreadExecWidth [[buffer(7)]],
                                                     constant uint32_t& tcWorkgroupSize [[buffer(8)]],
                                                     uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawIndexedPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	device char* dest;
	device auto* params = reinterpret_cast<device uint32_t*>(paramsBuff + idx * 256);
	dest = destBuff + idx * (sizeof(MTLStageInRegionIndirectArguments) + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2 + sizeof(MTLDrawPatchIndirectArguments));
	device auto& destSI = *(device MTLStageInRegionIndirectArguments*)dest;
	dest += sizeof(MTLStageInRegionIndirectArguments);
	device auto& destVtx = *(device MTLDispatchThreadgroupsIndirectArguments*)dest;
	device auto& destTC = *(device MTLDispatchThreadgroupsIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments));
	device auto& destTE = *(device MTLDrawPatchIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2);
	uint32_t patchCount = (src.indexCount * src.instanceCount + inControlPointCount - 1) / inControlPointCount;
	params[0] = inControlPointCount;
	params[1] = patchCount;
	destVtx.threadgroupsPerGrid[0] = (src.indexCount + vtxThreadExecWidth - 1) / vtxThreadExecWidth;
	destVtx.threadgroupsPerGrid[1] = src.instanceCount;
	destVtx.threadgroupsPerGrid[2] = 1;
	destTC.threadgroupsPerGrid[0] = (patchCount * outControlPointCount + tcWorkgroupSize - 1) / tcWorkgroupSize;
	destTC.threadgroupsPerGrid[1] = destTC.threadgroupsPerGrid[2] = 1;
	destTE.patchCount = patchCount;
	destTE.instanceCount = 1;
	destTE.patchStart = destTE.baseInstance = 0;
	destSI.stageInOrigin[0] = src.baseVertex;
	destSI.stageInOrigin[1] = src.baseInstance;
	destSI.stageInOrigin[2] = 0;
	destSI.stageInSize[0] = src.indexCount;
	destSI.stageInSize[1] = src.instanceCount;
	destSI.stageInSize[2] = 1;
}

kernel void cmdDrawIndexedCopyIndex16Buffer(const device uint16_t* srcBuff [[buffer(0)]],
                                            device uint16_t* destBuff [[buffer(1)]],
                                            const device MTLDrawIndexedPrimitivesIndirectArguments& params [[buffer(2)]],
                                            uint i [[thread_position_in_grid]]) {
	destBuff[i] = srcBuff[params.indexStart + i];
}

kernel void cmdDrawIndexedCopyIndex32Buffer(const device uint32_t* srcBuff [[buffer(0)]],
                                            device uint32_t* destBuff [[buffer(1)]],
                                            const device MTLDrawIndexedPrimitivesIndirectArguments& params [[buffer(2)]],
                                            uint i [[thread_position_in_grid]]) {
	destBuff[i] = srcBuff[params.indexStart + i];
}

typedef struct alignas(8) {
	uint32_t count;
	uint32_t countHigh;
} VisibilityBuffer;

typedef struct alignas(8) {
	atomic_uint count;
	atomic_uint countHigh;
} AtomicVisibilityBuffer;

typedef struct alignas(8) {
	uint32_t dst;
	uint32_t src;
} QueryResultOffsets;

typedef enum {
	Initial,
	DeviceAvailable,
	Available
} QueryStatus;

typedef enum {
	VK_QUERY_RESULT_64_BIT                = 0x00000001,
	VK_QUERY_RESULT_WAIT_BIT              = 0x00000002,
	VK_QUERY_RESULT_WITH_AVAILABILITY_BIT = 0x00000004,
	VK_QUERY_RESULT_PARTIAL_BIT           = 0x00000008,
} VkQueryResultFlagBits;

// Each query has elementCount 64-bit results (2 for transform feedback queries), followed by the
// availability value when requested.
kernel void cmdCopyQueryPoolResultsToBuffer(const device VisibilityBuffer* src [[buffer(0)]],
                                            device uint8_t* dest [[buffer(1)]],
                                            constant uint& stride [[buffer(2)]],
                                            constant uint& numQueries [[buffer(3)]],
                                            constant uint& flags [[buffer(4)]],
                                            constant QueryStatus* availability [[buffer(5)]],
                                            constant uint& elementCount [[buffer(6)]],
                                            uint query [[thread_position_in_grid]]) {
	if (query >= numQueries) { return; }
	device uint32_t* destCount = (device uint32_t*)(dest + stride * query);
	bool is64Bit = flags & VK_QUERY_RESULT_64_BIT;
	if (availability[query] != Initial || flags & VK_QUERY_RESULT_PARTIAL_BIT) {
		for (uint e = 0; e < elementCount; e++) {
			VisibilityBuffer value = src[query * elementCount + e];
			if (is64Bit) {
				destCount[2 * e] = value.count;
				destCount[2 * e + 1] = value.countHigh;
			} else {
				destCount[e] = value.count;
			}
		}
	}
	if (flags & VK_QUERY_RESULT_WITH_AVAILABILITY_BIT) {
		if (is64Bit) {
			destCount[2 * elementCount] = availability[query] != Initial ? 1 : 0;
			destCount[2 * elementCount + 1] = 0;
		} else {
			destCount[elementCount] = availability[query] != Initial ? 1 : 0;
		}
	}
}

kernel void accumulateOcclusionQueryResults(uint pos [[thread_position_in_grid]],
                                            const device QueryResultOffsets* offsets  [[buffer(0)]],
                                            device AtomicVisibilityBuffer* dst_buffer [[buffer(1)]],
                                            const device VisibilityBuffer* src_buffer [[buffer(2)]])
{
	VisibilityBuffer src = src_buffer[offsets[pos].src];
	device AtomicVisibilityBuffer& dst = dst_buffer[offsets[pos].dst];
	uint32_t prev_lo = atomic_fetch_add_explicit(&dst.count, src.count, memory_order_relaxed);
	uint32_t next_lo = prev_lo + src.count;
	atomic_fetch_add_explicit(&dst.countHigh, src.countHigh, memory_order_relaxed);
	if (next_lo < prev_lo)
		atomic_fetch_add_explicit(&dst.countHigh, 1, memory_order_relaxed);
}

kernel void convertUint8Indices(device uint8_t* src [[ buffer(0) ]],
                                device uint16_t* dst [[ buffer(1) ]],
                                uint pos [[thread_position_in_grid]]) {
	uint8_t idx = src[pos];
	dst[pos] = idx == 0xFF ? 0xFFFF : idx;
}

kernel void convertUint8IndicesRaw(device uint8_t* src [[ buffer(0) ]],
                                   device uint16_t* dst [[ buffer(1) ]],
                                   uint pos [[thread_position_in_grid]]) {
	uint8_t idx = src[pos];
	dst[pos] = idx;
}
)";
