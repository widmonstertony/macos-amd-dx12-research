/*
 * MVKCommandEncoderState.h
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

#pragma once

#include "MVKMTLResourceBindings.h"
#include "MVKCommandResourceFactory.h"
#include "MVKDevice.h"
#include "MVKDescriptorUseCache.h"
#include "MVKHeapUseTable.h"
#include "MVKStableUseMap.h"
#include "MVKEncoderHeapLedger.h"
#include "MVKResourceForensics.h"
#include "MVKPipeline.h"
#include "MVKSmallVector.h"
#include "MVKBitArray.h"
#include <unordered_map>
#include <objc/message.h>

class MVKCommandEncoder;
class MVKGraphicsPipeline;
class MVKDescriptorSet;
class MVKOcclusionQueryPool;

struct MVKShaderImplicitRezBinding;

enum class MVKMetalGraphicsStage {
	Vertex,
	Fragment,
#if MVK_XCODE_14
	Object,
	Mesh,
#endif
	Count
};

#pragma mark - Dynamic Resource Binders

/** Provides dynamic dispatch for binding resources to an encoder. */
struct MVKResourceBinder {
	typedef void (*UseResource)(id<MTLCommandEncoder> encoder, id<MTLResource> resource, MTLResourceUsage usage, MVKResourceUsageStages stages);
	SEL _setBytes;
	SEL _setBuffer;
	SEL _setOffset;
	SEL _setTexture;
	SEL _setSampler;
	SEL _setBytesDynamic;
	SEL _setBufferDynamic;
	SEL _setOffsetDynamic;
	UseResource useResource;
	template <typename T> static MVKResourceBinder Create() {
		return { T::selSetBytes(), T::selSetBuffer(), T::selSetOffset(), T::selSetTexture(), T::selSetSampler(), nullptr, nullptr, nullptr, T::useResource() };
	}
	template <typename T> static MVKResourceBinder CreateWithDynamicStride() {
		return { T::selSetBytes(), T::selSetBuffer(), T::selSetOffset(), T::selSetTexture(), T::selSetSampler(), T::selSetBytesDynamic(), T::selSetBufferDynamic(), T::selSetOffsetDynamic(), T::useResource() };
	}
	void setBytes(id<MTLCommandEncoder> encoder, const void* bytes, NSUInteger length, NSUInteger index) const {
		if (_setBytesDynamic) {
			reinterpret_cast<void(*)(id, SEL, const void*, NSUInteger, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setBytesDynamic, bytes, length, NSUIntegerMax /* MTLAttributeStrideStatic */, index);
		} else {
			reinterpret_cast<void(*)(id, SEL, const void*, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setBytes, bytes, length, index);
		}
	}
	void setBuffer(id<MTLCommandEncoder> encoder, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) const {
		if (_setBufferDynamic) {
			reinterpret_cast<void(*)(id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setBufferDynamic, buffer, offset, NSUIntegerMax /* MTLAttributeStrideStatic */, index);
		} else {
			reinterpret_cast<void(*)(id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setBuffer, buffer, offset, index);
		}
	}
	void setBufferOffset(id<MTLCommandEncoder> encoder, NSUInteger offset, NSUInteger index) const {
		if (_setOffsetDynamic) {
			reinterpret_cast<void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setOffsetDynamic, offset, NSUIntegerMax /* MTLAttributeStrideStatic */, index);
		} else {
			reinterpret_cast<void(*)(id, SEL, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setOffset, offset, index);
		}
	}
	void setTexture(id<MTLCommandEncoder> encoder, id<MTLTexture> texture, NSUInteger index) const {
		reinterpret_cast<void(*)(id, SEL, id<MTLTexture>, NSUInteger)>(objc_msgSend)(encoder, _setTexture, texture, index);
	}
	void setSampler(id<MTLCommandEncoder> encoder, id<MTLSamplerState> sampler, NSUInteger index) const {
		reinterpret_cast<void(*)(id, SEL, id<MTLSamplerState>, NSUInteger)>(objc_msgSend)(encoder, _setSampler, sampler, index);
	}
	enum class Stage {
		Vertex   = static_cast<uint32_t>(MVKMetalGraphicsStage::Vertex),
		Fragment = static_cast<uint32_t>(MVKMetalGraphicsStage::Fragment),
#if MVK_XCODE_14
		Object   = static_cast<uint32_t>(MVKMetalGraphicsStage::Object),
		Mesh     = static_cast<uint32_t>(MVKMetalGraphicsStage::Mesh),
#endif
		Compute  = static_cast<uint32_t>(MVKMetalGraphicsStage::Count),
		Count
	};
	static const MVKResourceBinder& Get(Stage stage) GCC_CONST;
	static const MVKResourceBinder& Get(MVKMetalGraphicsStage stage) { return Get(static_cast<Stage>(stage)); }
	static const MVKResourceBinder& Vertex()   { return Get(Stage::Vertex); }
	static const MVKResourceBinder& Fragment() { return Get(Stage::Fragment); }
#if MVK_XCODE_14
	static const MVKResourceBinder& Object()   { return Get(Stage::Object); }
	static const MVKResourceBinder& Mesh()     { return Get(Stage::Mesh); }
#endif
	static const MVKResourceBinder& Compute()  { return Get(Stage::Compute); }
};

/** Provides dynamic dispatch for binding vertex buffers to an encoder. */
struct MVKVertexBufferBinder {
	SEL _setBuffer;
	SEL _setOffset;
	SEL _setBufferDynamic;
	SEL _setOffsetDynamic;
	template <typename T> static MVKVertexBufferBinder Create() {
		return { T::selSetBuffer(), T::selSetOffset(), T::selSetBufferDynamic(), T::selSetOffsetDynamic() };
	}
	void setBuffer(id<MTLCommandEncoder> encoder, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) const {
		reinterpret_cast<void(*)(id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setBuffer, buffer, offset, index);
	}
	void setBufferOffset(id<MTLCommandEncoder> encoder, NSUInteger offset, NSUInteger index) const {
		reinterpret_cast<void(*)(id, SEL, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setOffset, offset, index);
	}
	void setBufferDynamic(id<MTLCommandEncoder> encoder, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger stride, NSUInteger index) const {
		reinterpret_cast<void(*)(id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setBufferDynamic, buffer, offset, stride, index);
	}
	void setBufferOffsetDynamic(id<MTLCommandEncoder> encoder, NSUInteger offset, NSUInteger stride, NSUInteger index) const {
		reinterpret_cast<void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger)>(objc_msgSend)(encoder, _setOffsetDynamic, offset, stride, index);
	}
	enum class Stage {
		Vertex,
#if MVK_XCODE_14
		Object,
#endif
		Compute,
		Count
	};
	static const MVKVertexBufferBinder& Get(Stage stage) GCC_CONST;
	static const MVKVertexBufferBinder& Vertex()  { return Get(Stage::Vertex); }
#if MVK_XCODE_14
	static const MVKVertexBufferBinder& Object()  { return Get(Stage::Object); }
#endif
	static const MVKVertexBufferBinder& Compute() { return Get(Stage::Compute); }
};

#pragma mark - Vulkan Command Encoder State Structs

/** Tracks state that's shared across both render and compute bind points. */
struct MVKVulkanSharedCommandEncoderState {
	MVKSmallVector<uint8_t, 128> _pushConstants;
};

struct MVKDepthClipState {
	uint32_t emulateViewportZ = 0;
	uint32_t emulateDepthClamp = 0;
	float viewportDepthRanges[kMVKMaxViewportScissorCount][2] = {};
};

static_assert(sizeof(MVKDepthClipState) == 136, "MVKDepthClipState must match the SPIRV-Cross MSL layout.");

struct MVKImplicitBufferData {
	MVKSmallVector<uint32_t, 8> bufferSizes;
	MVKSmallVector<uint32_t, 8> dynamicOffsets;
	MVKSmallVector<uint32_t, 8> textureOffsets;
	uint32_t emulatedReversedDepthViewportMask = 0;
	MVKDepthClipState depthClipState;
};

enum class MVKResourceUsageStages : uint8_t {
	Vertex   = static_cast<uint32_t>(MVKMetalGraphicsStage::Vertex),
	Fragment = static_cast<uint32_t>(MVKMetalGraphicsStage::Fragment),
#if MVK_XCODE_14
	Object   = static_cast<uint32_t>(MVKMetalGraphicsStage::Object),
	Mesh     = static_cast<uint32_t>(MVKMetalGraphicsStage::Mesh),
#endif
	All      = static_cast<uint32_t>(MVKMetalGraphicsStage::Count),
	Count,
	Compute  = 0, // Aliases with Render stages
	None     = Count, // Should not be passed to MVKUseResourceHelper
};

struct MVKUseResourceHelper {
    MVKResourceForensics resourceForensics;
    void finishResourceForensics(uint64_t reason) {
        resourceForensics.heapPlansEnabled=encoderHeapPlans;
        resourceForensics.usedNodes=used.size();
        resourceForensics.heldResources=retainedLiveResources.size();
        resourceForensics.heldLeases=retainedSnapshotLeases.size();
        resourceForensics.heldSnapshotEntries=declaredSnapshots.size()+heapReadSnapshots.size();
        resourceForensics.finish(reason);
    }
	MVKUseResourceHelper() {
		// Retain nodes that are actually used across encoder transitions below,
		// without imposing a large fixed allocation on every command buffer.
		used.reserve(1024);
		const char* value = getenv("MVK_AMD_ENCODER_LIVE_CACHE");
		cacheLiveResources = value && !strcmp(value, "1");
		value = getenv("MVK_AMD_BATCH_LIVE_USE_RESOURCE");
		batchLiveResources = value && !strcmp(value, "1");
		// Runtime replay is the qualified game path that exercises the guarded
		// live-resource lookup. Enable batching there as well so a Steam client
		// that is already running with the replay environment picks up the
		// optimized library without requiring a new prefix or login session.
		value = getenv("MVK_AMD_RUNTIME_REPLAY_ONLY");
		batchLiveResources |= value && !strcmp(value, "1");
		value = getenv("MVK_AMD_BATCH_ARGUMENT_HEAPS");
		batchArgumentHeaps = value && !strcmp(value, "1");
        value = getenv("MVK_AMD_ENCODER_HEAP_PLANS");
        encoderHeapPlans = batchArgumentHeaps && batchLiveResources && value && !strcmp(value, "1");
		value = getenv("MVK_AMD_ARGUMENT_HEAP_THRESHOLD");
		if (value) {
			char* end = nullptr;
			unsigned long parsed = strtoul(value, &end, 10);
			if (end != value && !*end && parsed >= 1 && parsed <= UINT32_MAX) {
				heapBatchThreshold = static_cast<uint32_t>(parsed);
			}
		}
		value = getenv("MVK_AMD_TRACE_ARGUMENT_HEAPS");
		traceArgumentHeaps = value && !strcmp(value, "1");
		value = getenv("MVK_AMD_LIVE_LOOKUP_FAST_CACHE");
		if (cacheLiveResources && value && !strcmp(value, "1")) recentLiveResources.resize(256);
		value = getenv("MVK_AMD_CROSS_ENCODER_LIVE_CACHE");
		crossEncoderLiveCache = cacheLiveResources && value && !strcmp(value, "1");
		value = getenv("MVK_AMD_NEGATIVE_LIVE_CACHE");
		negativeLiveCache = cacheLiveResources && value && !strcmp(value, "1");
		value = getenv("MVK_AMD_DESCRIPTOR_SNAPSHOT_REUSE");
		descriptorSnapshotReuse = cacheLiveResources && value && !strcmp(value, "1");
		value = getenv("MVK_AMD_CROSS_ENCODER_SNAPSHOT_REUSE");
		crossEncoderSnapshotReuse = descriptorSnapshotReuse && crossEncoderLiveCache && value && !strcmp(value, "1");
		value = getenv("MVK_AMD_RESOURCE_USE_STATS");
		resourceUseStats = value && !strcmp(value, "1");
		value = getenv("MVK_AMD_TRACE_LIVE_CACHE");
		traceLiveCache = value && !strcmp(value, "1");
	}
	MVKUseResourceHelper(const MVKUseResourceHelper&) = delete;
	MVKUseResourceHelper& operator=(const MVKUseResourceHelper&) = delete;
	~MVKUseResourceHelper() { releaseLiveResources(); }
	struct PendingResources {
		MVKSmallVector<id<MTLResource>> resources;
		MVKSmallVector<id<MTLHeap>> heaps;
		size_t size() const { return resources.size(); }
		bool empty() const { return resources.empty(); }
		void push_back(id<MTLResource> resource, id<MTLHeap> heap) {
			resources.push_back(resource);
			heaps.push_back(heap);
		}
		void clear() { resources.clear(); heaps.clear(); }
		void removeNilResources() {
			size_t output = 0;
			for (size_t input = 0; input < resources.size(); ++input) {
				if (!resources[input]) continue;
				resources[output] = resources[input];
				heaps[output] = heaps[input];
				++output;
			}
			resources.resize(output);
			heaps.resize(output);
		}
	};
	struct Entry {
		PendingResources read;
		PendingResources readWrite;
		MVKSmallVector<id<MTLResource>> retainedSnapshotReads;
		PendingResources& get(bool write) { return write ? readWrite : read; }
	};
	struct ResourceInfo {
		MVKResourceUsageStages stages;
		bool write;
		bool deferred;
		bool liveRetained = false;
		uint64_t generation = 0;
        uint64_t pendingBatch = 0;
        size_t pendingIndex = 0;
		// A retained Metal resource keeps its heap identity stable. Cache that
		// identity with the owned resource instead of sending millions of
		// repeated Objective-C `heap` messages while rebuilding encoder-local
		// declarations. Non-retained entries refresh this at each generation.
		id<MTLHeap> heap = nil;
		bool heapKnown = false;
	};
	struct RecentLiveResource {
		id<MTLResource> resource = nil;
		MVKLiveList* list = nullptr;
		ResourceInfo* retainedInfo = nullptr;
		uint64_t absentGeneration = 0;
	};
	std::vector<RecentLiveResource> recentLiveResources;
	MVKOnePerEnumEntry<Entry, MVKResourceUsageStages> entries;
	MVKStableUseMap<id<MTLResource>, ResourceInfo> used;
	bool cacheLiveResources = false;
	bool crossEncoderLiveCache = false;
	bool batchLiveResources = false;
	bool batchArgumentHeaps = false;
    bool encoderHeapPlans = false;
    MVKEncoderHeapLedger<id<MTLResource>, id<MTLHeap>> heapLedger;
    MVKSmallVector<id<MTLHeap>> encoderHeapOwners;
    struct HeapReadSnapshot {
        MVKDescriptorUseCache::Snapshot snapshot;
        MVKLiveList* list;
        uint64_t additions;
        MVKLiveList::SnapshotLease lease;
    };
    std::vector<HeapReadSnapshot> heapReadSnapshots;
    size_t heapReadSnapshotIdentities = 0;
    struct CoveredHeapReadPlan { const BufferHeapReadPlan* plan; uint32_t stages; };
    std::vector<CoveredHeapReadPlan> coveredHeapReadPlans;
    struct HeapPlanHeapBatch { uint32_t stages; std::vector<id<MTLHeap>> resources; };
    struct HeapPlanResourceBatch { uint32_t stages; std::vector<id<MTLResource>> resources; };
    std::vector<HeapPlanHeapBatch> heapPlanHeapBatches;
    std::vector<HeapPlanResourceBatch> heapPlanReadBatches, heapPlanWriteBatches;
    uint64_t statsHeapPlanCalls=0, statsHeapPlanSkips=0, statsHeapPlanResources=0;
    uint64_t statsHeapPlanPreciseResources=0, statsHeapPlanLeaseRefreshes=0;
    uint64_t statsHeapPlanHeapCalls=0, statsHeapPlanWriteCalls=0, statsHeapPlanWriteReplays=0;
    bool tryAddBufferHeapSnapshot(MVKDescriptorUseCache::Snapshot snapshot, MVKLiveList& list,
                                 id<MTLCommandEncoder> encoder, MVKResourceBinder::UseResource func,
                                 MVKResourceUsageStages stage);
    id<MTLHeap> ownHeapPlanResource(id<MTLResource> resource, ResourceInfo& info);
    void resetHeapPlanEncoder();
    void bindHeapPlansAndReset(id<MTLCommandEncoder> encoder, bool graphics);
	MVKHeapUseTable<id<MTLHeap>> heapCounts;
	uint32_t heapBatchThreshold = 16;
	bool traceArgumentHeaps = false;
	bool traceLiveCache = false;
	bool resourceUseStats = false;
    bool negativeLiveCache = false;
    struct AbsentLiveResource { MVKLiveList* list; uint64_t additions; };
    std::unordered_map<id<MTLResource>, AbsentLiveResource> absentLiveResources;
    bool descriptorSnapshotReuse = false;
    bool crossEncoderSnapshotReuse = false;
    struct CachedDescriptorSnapshot {
        MVKDescriptorUseCache* cache;
        const char* src;
        uint32_t count;
        size_t stride;
        MVKDescriptorUseCache::SnapshotReuseToken reuse;
        MVKDescriptorUseCache::Snapshot snapshot;
    };
    std::vector<CachedDescriptorSnapshot> cachedDescriptorSnapshots;
    MVKDescriptorUseCache::Snapshot descriptorSnapshot(MVKDescriptorUseCache* cache,
                                                       const char* src, uint32_t count, size_t stride);
    struct RetainedSnapshotResource {
        id<MTLResource> resource;
        ResourceInfo* info; // Stable deque node; helper owns the Metal reference.
    };
    using RetainedSnapshot = std::vector<RetainedSnapshotResource>;
    struct RetainedReadBatch {
        // Keep the stable ResourceInfo node with each retained object.  A
        // shared snapshot can overlap many other snapshots in the same Metal
        // encoder; replaying raw resource identities would bypass the
        // encoder-generation/stage deduplication and send every overlap to
        // the native driver again.
        std::vector<RetainedSnapshotResource> records;
    };
    using SharedRetainedReadBatch = std::shared_ptr<RetainedReadBatch>;
    SharedRetainedReadBatch buildRetainedReadBatch(const std::shared_ptr<RetainedSnapshot>& live);
    void addRetainedSnapshotResource(const RetainedSnapshotResource& record,
                                    id<MTLCommandEncoder> encoder, MVKResourceBinder::UseResource func,
                                    MVKResourceUsageStages stage, bool write);
    struct DeclaredSnapshot {
        MVKDescriptorUseCache::Snapshot snapshot;
        MVKLiveList* list;
        uint32_t readStages;
        uint32_t writeStages;
        uint64_t additions;
        uint64_t generation;
        std::shared_ptr<RetainedSnapshot> liveSnapshot;
        SharedRetainedReadBatch readBatch;
    };
    size_t snapshotLiveIdentities = 0;
    std::vector<DeclaredSnapshot> declaredSnapshots;
    uint64_t statsRegistrationQueries=0, statsRegistrationUnrelated=0;
    uint64_t statsSnapshotCalls=0, statsSnapshotSkips=0, statsSnapshotWordsSkipped=0, statsSnapshotFilterHits=0;
    uint64_t statsSnapshotDeltaHits=0, statsSnapshotDeltaReused=0, statsSnapshotColdWords=0, statsSnapshotCacheClears=0;
    uint64_t statsDescriptorSnapshotFastHits=0, statsDescriptorSnapshotMisses=0;
    uint64_t statsSnapshotBulkFastHits=0, statsSnapshotBulkResources=0;
    void addLiveSnapshot(MVKDescriptorUseCache::Snapshot snapshot, MVKLiveList& list,
                         id<MTLCommandEncoder> encoder, MVKResourceBinder::UseResource func,
                         MVKResourceUsageStages stage, bool write, bool knownBuffers = false);
	uint64_t statsCalls=0, statsLookups=0, statsRetainedHits=0, statsAbsentHits=0, statsLiveFound=0;
	// Counts the resource declarations that survive helper-side deduplication
	// and are actually submitted to Metal.  The high-level call counters above
	// cannot distinguish CPU replay cost from AMD driver declaration cost.
	uint64_t statsBindCalls=0, statsInputRead=0, statsInputReadWrite=0;
	uint64_t statsPreciseRead=0, statsPreciseReadWrite=0;
	uint64_t statsCollapsedRead=0, statsHeapDeclarations=0, statsHeapQueries=0;
	uint64_t statsHeapDeclarationNS=0, statsReadDeclarationNS=0, statsWriteDeclarationNS=0;
	uint64_t statsDeclarationMaxNS=0;
	void publishResourceUseStats(bool encoderReset);
    uint64_t pendingBatchGeneration = 1;
    uint64_t statsQueuedSuperseded = 0;
    void supersedePending(id<MTLResource> resource, ResourceInfo& info);
    void queuePending(id<MTLResource> resource, ResourceInfo& info);
    void finishPendingBatch();
	uint64_t encoderGeneration = 1;
	uint64_t liveLookupCount = 0, liveReuseCount = 0;
	uint64_t liveRecentReuseCount = 0, liveAbsentReuseCount = 0;
	MVKSmallVector<id<MTLResource>> retainedLiveResources;
    std::vector<MVKLiveList::SnapshotLease> retainedSnapshotLeases;
	/** Keeps newly validated resources alive until their batched useResources call. */
	MVKSmallVector<id<MTLResource>> pendingBatchLiveResources;
	void releasePendingBatchLiveResources();
	void releaseLiveResources();
	/** Begin a new Metal encoder while retaining reusable hash-table nodes. */
	void resetForEncoder();
	/** Reuse a validated object only while this helper owns a retained reference. */
	bool addImmediateLive(id<MTLResource> resource, MVKLiveList& liveList, id<MTLCommandEncoder> enc, MVKResourceBinder::UseResource func, MVKResourceUsageStages stage, bool write);
	/** Add a resource to the list of resources to use. */
	ResourceInfo* add(id<MTLResource> resource, MVKResourceUsageStages stage, bool write);
	/**
	 * Immediately use the given resource.
	 * A live resource is retained by MVKLiveList while this call executes, so
	 * resource destruction does not require holding the live-list lock here.
	 */
	ResourceInfo* addImmediate(id<MTLResource> resource, id<MTLCommandEncoder> enc, MVKResourceBinder::UseResource func, MVKResourceUsageStages stage, bool write);
	void bindAndResetGraphics(id<MTLRenderCommandEncoder> encoder);
	void bindAndResetCompute(id<MTLComputeCommandEncoder> encoder);
};

/**
 * Tracks state that is needed by all Vulkan command encoder state trackers but is independent.
 * (Commands that update these take a VkPipelineBindPoint to specify which state to update.)
 */
struct MVKVulkanCommonEncoderState {
	MVKPipelineLayout* _layout = nullptr;
	MVKDescriptorSet* _descriptorSets[kMVKMaxDescriptorSetCount];
	MVKDescriptorSet _pushDescriptor = {};
	MVKSmallVector<uint8_t, 16> _pushDescData;
	void ensurePushDescriptorSize(uint32_t size);
	void setLayout(MVKPipelineLayout* layout);
	MVKVulkanCommonEncoderState() = default;
	MVKVulkanCommonEncoderState(const MVKVulkanCommonEncoderState& other);
	MVKVulkanCommonEncoderState& operator=(const MVKVulkanCommonEncoderState& other);
};

/** Tracks the state of a Vulkan render encoder. */
struct MVKVulkanGraphicsCommandEncoderState: public MVKVulkanCommonEncoderState {
	MVKGraphicsPipeline* _pipeline = nullptr;
	MVKRenderStateData _renderState;
	MVKVertexMTLBufferBinding _vertexBuffers[kMVKMaxBufferCount];
	MVKIndexMTLBufferBinding _indexBuffer;
	VkViewport _viewports[kMVKMaxViewportScissorCount];
	VkRect2D _scissors[kMVKMaxViewportScissorCount];
	MTLSamplePosition _sampleLocations[kMVKMaxSampleCount];
	MVKImplicitBufferData _implicitBufferData[kMVKShaderStageFragment + 1];

	/** Choose between the dynamic and pipeline render states based on whether the given state flag is marked dynamic on the pipeline. */
	const MVKRenderStateData& pickRenderState(MVKRenderStateFlag state) const {
		bool dynamic = _pipeline->getDynamicStateFlags().has(state);
		return *(dynamic ? &_renderState : &_pipeline->getStaticStateData());
	}
	MVKArrayRef<const MTLSamplePosition> getSamplePositions() const;
	bool isBresenhamLines() const;
	uint32_t getPatchControlPoints() const {
		return pickRenderState(MVKRenderStateFlag::PatchControlPoints).patchControlPoints;
	}
	bool isPrimitiveRestartEnabled() const {
		return pickRenderState(MVKRenderStateFlag::PrimitiveRestartEnable).enable.has(MVKRenderStateEnableFlag::PrimitiveRestart);
	}
	bool getProvokingVertexMode() const {
		return pickRenderState(MVKRenderStateFlag::ProvokingVertexMode).provokingVertexMode;
	}

	/** Bind the given descriptor sets, placing their bindings into `_descriptorSetBindings`. */
	void bindDescriptorSets(MVKPipelineLayout* layout,
	                        uint32_t firstSet,
	                        uint32_t setCount,
	                        MVKDescriptorSet*const* sets,
	                        uint32_t dynamicOffsetCount,
	                        const uint32_t* dynamicOffsets);
};

/** Tracks the state of a Vulkan compute encoder. */
struct MVKVulkanComputeCommandEncoderState: public MVKVulkanCommonEncoderState {
	MVKComputePipeline* _pipeline = nullptr;
	MVKImplicitBufferData _implicitBufferData;

	/** Bind the given descriptor sets, placing their bindings into `_descriptorSetBindings`. */
	void bindDescriptorSets(MVKPipelineLayout* layout,
	                        uint32_t firstSet,
	                        uint32_t setCount,
	                        MVKDescriptorSet*const* sets,
	                        uint32_t dynamicOffsetCount,
	                        const uint32_t* dynamicOffsets);
};

struct MVKMetalSharedCommandEncoderState {
	/** Storage space for use by various methods to reduce alloc/free. */
	MVKSmallVector<uint32_t, 8> _scratch;

	/** Storage for tracking which objects need to have useResource called on them. */
	MVKUseResourceHelper _useResource;

	/** Which GPU addressable resources have been added to `_useResource`. */
	MVKResourceUsageStages _gpuAddressableResourceStages;

	void reset() {
		_gpuAddressableResourceStages = MVKResourceUsageStages::None;
		_useResource.resetForEncoder();
	}
};

#pragma mark - MVKMetalRenderCommandEncoderState

struct MVKStageResourceBindings {
	id<MTLTexture> textures[kMVKMaxTextureCount];
	struct Buffer {
		id<MTLBuffer> buffer;
		VkDeviceSize offset;
		bool operator==(Buffer other) const { return std::make_pair(buffer, offset) == std::make_pair(other.buffer, other.offset); }
		bool operator!=(Buffer other) const { return !(*this == other); }
	} buffers[kMVKMaxBufferCount];
	id<MTLSamplerState> samplers[kMVKMaxSamplerCount];
	MVKBitArray descriptorSetResourceUse[kMVKMaxDescriptorSetCount];
	MVKOnePerEnumEntry<uint8_t, MVKNonVolatileImplicitBuffer> implicitBufferIndices = {};
	static Buffer ImplicitBuffer(MVKImplicitBuffer buffer) {
		return { nil, static_cast<VkDeviceSize>(buffer) + 1 };
	}
	static Buffer ImplicitBuffer(MVKNonVolatileImplicitBuffer buffer) {
		return ImplicitBuffer(static_cast<MVKImplicitBuffer>(buffer));
	}
	static Buffer NullBuffer() { return { nil, 0 }; }
	static Buffer InvalidBuffer() { return { nil, ~0ull }; }
};

template <typename T>
struct MVKOnePerGraphicsStage: public MVKOnePerEnumEntry<T, MVKMetalGraphicsStage> {
	      T& vertex()         { return (*this)[MVKMetalGraphicsStage::Vertex]; }
	const T& vertex()   const { return (*this)[MVKMetalGraphicsStage::Vertex]; }
	      T& fragment()       { return (*this)[MVKMetalGraphicsStage::Fragment]; }
	const T& fragment() const { return (*this)[MVKMetalGraphicsStage::Fragment]; }
#if MVK_XCODE_14
	      T& object()         { return (*this)[MVKMetalGraphicsStage::Object]; }
	const T& object()   const { return (*this)[MVKMetalGraphicsStage::Object]; }
	      T& mesh()           { return (*this)[MVKMetalGraphicsStage::Mesh]; }
	const T& mesh()     const { return (*this)[MVKMetalGraphicsStage::Mesh]; }
#endif
};

enum class MVKMetalRenderEncoderStateFlag {
	DepthBiasEnable,
	DepthBoundsEnable,
	DepthClampEnable,
	DepthTestEnable,
	PrimitiveRestartEnable,
	RasterizationDisabledByScissor,
	ScissorDirty,
	PipelineReady,
	SamplePositionsOverridden,
	Count
};

using MVKMetalRenderEncoderStateFlags = MVKFlagList<MVKMetalRenderEncoderStateFlag>;

class MVKRenderSubpass;

/** The state for a draw inserted by MoltenVK. */
struct MVKHelperDrawState {
	id<MTLRenderPipelineState> pipeline;
	VkRect2D viewportAndScissor;
	uint32_t stencilReference;
	bool writeDepth;
	bool writeStencil;
};

/** Subset of MVKMetalGraphicsCommandEncoderState that can be reset with memset. */
struct MVKMetalGraphicsCommandEncoderStateQuickReset {
	/**
	 * If clear, ignore the binding in `bindings` and assume the Metal default value (usually nil / zero).
	 * Allows us to quickly reset to the state of a fresh command encoder without having to zero all the bindings.
	 */
	MVKOnePerGraphicsStage<MVKStageResourceBits> _exists;

	id<MTLRenderPipelineState> _pipeline;

	/** Flags that mark whether a render state matches the current Vulkan render state. */
	MVKRenderStateFlags _stateReady;
	/** Other single-bit flags. */
	MVKMetalRenderEncoderStateFlags _flags;

	MVKStencilReference _stencilReference;
	MVKColor32 _blendConstants;
	uint8_t _numViewports;
	uint8_t _numScissors;
	uint8_t _patchControlPoints;
	uint8_t _cullMode;
	uint8_t _frontFace;
	MVKPolygonMode _polygonMode;
	uint8_t _provokingVertexMode;

	// Memset 0 to here to clear.
	// DO NOT memset sizeof(*this), or you'll clear padding, which is used by subclasses.
	struct {} MEMSET_RESET_LINE;
};

/** Tracks the state of a Metal render encoder. */
struct MVKMetalGraphicsCommandEncoderState : public MVKMetalGraphicsCommandEncoderStateQuickReset {
	uint8_t _primitiveType;
	bool _isTriangleFan = false;
	uint8_t _numSamplePositions = 0;
	MVKDepthBias _depthBias;
	MVKDepthBounds _depthBounds;
	float _lineWidth;
	uint32_t _sampleCount;
	uint32_t _primitiveRestartIndex;
	MVKMTLDepthStencilDescriptorData _depthStencil;

	MVKOnePerGraphicsStage<MVKStageResourceBindings> _bindings;

	VkViewport _viewports[kMVKMaxViewportScissorCount];
	VkRect2D _scissors[kMVKMaxViewportScissorCount];
	MTLSamplePosition _samplePositions[kMVKMaxSampleCount];

	MTLPrimitiveType getPrimitiveType() const { return static_cast<MTLPrimitiveType>(_primitiveType); }
	/** Whether the bound topology is VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN (getPrimitiveType() is then MTLPrimitiveTypeTriangle). */
	bool isTriangleFan() const { return _isTriangleFan; }

	/** For API compatibility with MVKMetalComputeCommandEncoderState. */
	MVKArrayRef<MVKStageResourceBits> exists() { return _exists.elements; }

	/** Reset to the state of a fresh Metal render encoder. */
	void reset(VkSampleCountFlags sampleCount);

	/** Mark the given pieces of render state as dirty. */
	void markDirty(MVKRenderStateFlags flags) { _stateReady.removeAll(flags); }
	/** Mark everything dirty that needs to be marked when changing pipelines. */
	void changePipeline(MVKGraphicsPipeline* from, MVKGraphicsPipeline* to);

	void bindFragmentBuffer(id<MTLRenderCommandEncoder> encoder, id<MTLBuffer> buffer, VkDeviceSize offset, NSUInteger index);
	void bindFragmentBytes(id<MTLRenderCommandEncoder> encoder, const void* data, size_t size, NSUInteger index);
	void bindFragmentTexture(id<MTLRenderCommandEncoder> encoder, id<MTLTexture> texture, NSUInteger index);
	void bindFragmentSampler(id<MTLRenderCommandEncoder> encoder, id<MTLSamplerState> sampler, NSUInteger index);
	void bindVertexBuffer(id<MTLRenderCommandEncoder> encoder, id<MTLBuffer> buffer, VkDeviceSize offset, NSUInteger index);
	void bindVertexBytes(id<MTLRenderCommandEncoder> encoder, const void* data, size_t size, NSUInteger index);
	void bindVertexTexture(id<MTLRenderCommandEncoder> encoder, id<MTLTexture> texture, NSUInteger index);
	void bindVertexSampler(id<MTLRenderCommandEncoder> encoder, id<MTLSamplerState> sampler, NSUInteger index);
	template <typename T> void bindFragmentStructBytes(id<MTLComputeCommandEncoder> encoder, const T& t, NSUInteger index) { bindFragmentBytes(encoder, &t, sizeof(T), index); }
	template <typename T> void bindVertexStructBytes(id<MTLComputeCommandEncoder> encoder, const T& t, NSUInteger index) { bindVertexBytes(encoder, &t, sizeof(T), index); }
	void bindStateData(id<MTLRenderCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder, const MVKRenderStateData& data, MVKRenderStateFlags flags, const VkRect2D* scissors);
	void bindState(id<MTLRenderCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder, const MVKVulkanGraphicsCommandEncoderState& vkState);
	void prepareDraw(id<MTLRenderCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder, const MVKVulkanGraphicsCommandEncoderState& vkState, const MVKVulkanSharedCommandEncoderState& vkShared);
	void prepareHelperDraw(id<MTLRenderCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder, const MVKHelperDrawState& state);
};

#pragma mark - MVKMetalComputeCommandEncoderState

/** Tracks the state of a Metal compute encoder */
struct MVKMetalComputeCommandEncoderState {
	/**
	 * If clear, ignore the binding in `bindings` and assume the Metal default value (usually nil / zero).
	 * Allows us to quickly reset to the state of a fresh command encoder without having to zero all the bindings.
	 */
	MVKStageResourceBits _exists;

	id<MTLComputePipelineState> _pipeline;

	MVKPipeline* _vkPipeline;

	// Everything above here can be reset by a memset from the beginning of the struct to offsetof(struct, MEMSET_RESET_LINE)
	struct {} MEMSET_RESET_LINE;

	/** The current stage being run on this compute encoder. */
	MVKShaderStage _vkStage = kMVKShaderStageCount;

	MVKStageResourceBindings _bindings;

	void bindPipeline(id<MTLComputeCommandEncoder> encoder, id<MTLComputePipelineState> pipeline);
	void bindBuffer(id<MTLComputeCommandEncoder> encoder, id<MTLBuffer> buffer, VkDeviceSize offset, NSUInteger index);
	void bindBytes(id<MTLComputeCommandEncoder> encoder, const void* data, size_t size, NSUInteger index);
	void bindTexture(id<MTLComputeCommandEncoder> encoder, id<MTLTexture> texture, NSUInteger index);
	void bindSampler(id<MTLComputeCommandEncoder> encoder, id<MTLSamplerState> sampler, NSUInteger index);
	template <typename T> void bindStructBytes(id<MTLComputeCommandEncoder> encoder, const T* t, NSUInteger index) { bindBytes(encoder, t, sizeof(T), index); }
	void prepareComputeDispatch(id<MTLComputeCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder, const MVKVulkanComputeCommandEncoderState& vkState, const MVKVulkanSharedCommandEncoderState& vkShared);
	void prepareRenderDispatch(id<MTLComputeCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder, const MVKVulkanGraphicsCommandEncoderState& vkState, const MVKVulkanSharedCommandEncoderState& vkShared, MVKShaderStage stage);

	/** For API compatibility with MVKMetalGraphicsCommandEncoderState. */
	MVKArrayRef<MVKStageResourceBits> exists() { return {&_exists, 1}; }

	void reset();
};

#pragma mark - MVKCommandEncoderState

/** Holds both Metal and Vulkan state for both compute and graphics. */
class MVKCommandEncoderState {
	MVKVulkanSharedCommandEncoderState   _vkShared;
	MVKVulkanGraphicsCommandEncoderState _vkGraphics;
	MVKVulkanComputeCommandEncoderState  _vkCompute;
	MVKMetalSharedCommandEncoderState    _mtlShared;
	MVKMetalGraphicsCommandEncoderState  _mtlGraphics;
	MVKMetalComputeCommandEncoderState   _mtlCompute;
	enum class CommandEncoderClass {
		None,
		Graphics,
		Compute
	};
	/** The type of Metal encoder, if any, that is currently active. */
	CommandEncoderClass _mtlActiveEncoder;

	/** Get the encoder state associated with the given bind point, or nullptr if the bindPoint isn't supported. */
	MVKVulkanCommonEncoderState* getVkEncoderState(VkPipelineBindPoint bindPoint);

public:
	/** Get a reference to the Vulkan state shared between graphics and compute.  Read-only, use methods on this class (which will invalidate associated Metal state) to modify. */
	const MVKVulkanSharedCommandEncoderState&   vkShared()   const { return _vkShared; }
	/** Get a reference to the Vulkan graphics state.  Read-only, use methods on this class (which will invalidate associated Metal state) to modify. */
	const MVKVulkanGraphicsCommandEncoderState& vkGraphics() const { return _vkGraphics; }
	/** Get a reference to the Vulkan compute state.  Read-only, use methods on this class (which will invalidate associated Metal state) to modify. */
	const MVKVulkanComputeCommandEncoderState&  vkCompute()  const { return _vkCompute; }
	/** Returns a reference to the Metal state shared between graphics and compute. */
	MVKMetalSharedCommandEncoderState&   mtlShared()   { return _mtlShared; }
	/** Returns a reference to the Metal graphics state. */
	MVKMetalGraphicsCommandEncoderState& mtlGraphics() { return _mtlGraphics; }
	/** Returns a reference to the Metal compute state. */
	MVKMetalComputeCommandEncoderState&  mtlCompute()  { return _mtlCompute; }

	/**
	 * Updates the given dynamic state, invalidating the passed flags on the Metal graphics state.
	 * Use the returned reference to do the actual update to the Vulkan state.
	 */
	MVKVulkanGraphicsCommandEncoderState& updateDynamicState(MVKRenderStateFlags state) {
		_mtlGraphics.markDirty(state);
		return _vkGraphics;
	}

	/** Returns the current sample positions and marks those positions as the currently bound positions. */
	MVKArrayRef<const MTLSamplePosition> updateSamplePositions();
	/** Checks if the render pass needs to be restarted before drawing with the current graphics configuration. */
	bool needsMetalRenderPassRestart();
	/** Binds everything needed to render with the current Vulkan graphics state on the current Metal graphics state. */
	void prepareDraw(id<MTLRenderCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder) {
		_mtlGraphics.prepareDraw(encoder, mvkEncoder, _vkGraphics, _vkShared);
	}
	/** Binds everything needed to dispatch a compute-based emulation of the given stage of the current Vulkan graphics state on the current Metal compute state. */
	void prepareRenderDispatch(id<MTLComputeCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder, MVKGraphicsStage stage) {
		assert(stage == kMVKGraphicsStageVertex || stage == kMVKGraphicsStageTessControl);
		MVKShaderStage shaderStage = stage == kMVKGraphicsStageVertex ? kMVKShaderStageVertex : kMVKShaderStageTessCtl;
		_mtlCompute.prepareRenderDispatch(encoder, mvkEncoder, _vkGraphics, _vkShared, shaderStage);
	}
	/** Binds everything needed to dispatch a Vulkan compute shader on the current Metal compute state. */
	void prepareComputeDispatch(id<MTLComputeCommandEncoder> encoder, MVKCommandEncoder& mvkEncoder) {
		_mtlCompute.prepareComputeDispatch(encoder, mvkEncoder, _vkCompute, _vkShared);
	}
	/** Binds the given graphics pipeline to the Vulkan graphics state, invalidating any necessary resources. */
	void bindGraphicsPipeline(MVKGraphicsPipeline* pipeline);
	/** Updates the mask of viewports whose reversed-depth range should be emulated in graphics shaders. */
	void setGraphicsEmulatedReversedDepthViewportMask(uint32_t mask);
	/** Updates the depth clip and clamp emulation state used by graphics shaders. */
	void setGraphicsDepthClipState(const MVKDepthClipState& depthClipState);
	/** Binds the given compute pipeline to the Vulkan graphics state, invalidating any necessary resources. */
	void bindComputePipeline(MVKComputePipeline* pipeline);
	/** Binds the given push constants to the Vulkan state, invalidating any necessary resources. */
	void pushConstants(uint32_t offset, uint32_t size, const void* data);
	/** Binds the given descriptor sets to the Vulkan state, invalidating any necessary resources. */
	void bindDescriptorSets(VkPipelineBindPoint bindPoint,
	                        MVKPipelineLayout* layout,
	                        uint32_t firstSet,
	                        uint32_t setCount,
	                        MVKDescriptorSet*const* sets,
	                        uint32_t dynamicOffsetCount,
	                        const uint32_t* dynamicOffsets);
	/** Applies the given descriptor set writes to the push descriptor set on bindPoint. */
	void pushDescriptorSet(VkPipelineBindPoint bindPoint, MVKPipelineLayout* layout, uint32_t set, uint32_t writeCount, const VkWriteDescriptorSet* writes);
	/** Applies the given descriptor update template to the push descriptor to its specified bindPoint. */
	void pushDescriptorSet(MVKDescriptorUpdateTemplate* updateTemplate, MVKPipelineLayout* layout, uint32_t set, const void* data);
	/** Binds the given vertex buffers to the Vulkan state, invalidating any necessary resources. */
	void bindVertexBuffers(uint32_t firstBinding, MVKArrayRef<const MVKVertexMTLBufferBinding> buffers);
	/** Binds the given index buffer to the Vulkan state, invalidating any necessary resources. */
	void bindIndexBuffer(const MVKIndexMTLBufferBinding& buffer);
	void offsetZeroDivisorVertexBuffers(MVKCommandEncoder& mvkEncoder, MVKGraphicsStage stage, MVKGraphicsPipeline* pipeline, uint32_t firstInstance);

	/** Begins tracking for a fresh MTLRenderCommandEncoder. */
	void beginGraphicsEncoding(VkSampleCountFlags sampleCount);
	/** Begins tracking for a fresh MTLComputeCommandEncoder. */
	void beginComputeEncoding();

	/**
	 * Calls the given function on either the Metal graphics or compute state tracker, whichever one is active (or neither if neither is active).
	 * `bindPoint` can be used to only call the function if the given Vulkan pipeline is being encoded to the active encoder.
	 */
	template <typename Fn>
	void applyToActiveMTLState(VkPipelineBindPoint bindPoint, Fn&& fn);
};

#pragma mark -
#pragma mark MVKOcclusionQueryCommandEncoderState

/** Holds encoder state established by occlusion query commands. */
class MVKOcclusionQueryCommandEncoderState {

public:
	void endMetalRenderPass(MVKCommandEncoder* cmdEncoder);

	/** Begins an occlusion query. */
	void beginOcclusionQuery(MVKCommandEncoder* cmdEncoder, MVKOcclusionQueryPool* pQueryPool, uint32_t query, VkQueryControlFlags flags);

	/** Ends an occlusion query. */
	void endOcclusionQuery(MVKCommandEncoder* cmdEncoder, MVKOcclusionQueryPool* pQueryPool, uint32_t query);

	void encode(id<MTLRenderCommandEncoder> encoder, MVKCommandEncoder* mvkEncoder);

	void prepareHelperDraw(id<MTLRenderCommandEncoder> encoder, MVKCommandEncoder* mvkEncoder);

private:
	/** Advances to the next index in the Metal visibility buffer. */
	void nextMetalQuery(MVKCommandEncoder* cmdEncoder);

	typedef struct OcclusionQueryLocation {
		MVKOcclusionQueryPool* queryPool = nullptr;
		uint32_t query = 0;
		uint32_t visibilityBufferOffset = 0;

		OcclusionQueryLocation(MVKOcclusionQueryPool* qPool, uint32_t qIdx, uint32_t vbOfst)
		: queryPool(qPool), query(qIdx), visibilityBufferOffset(vbOfst) {}

	} OcclusionQueryLocation;

	struct CopyFence {
		id<MTLFence> read;
		id<MTLFence> write;
	};

	id<MTLFence> _lastFenceUpdate = nullptr;
	// Max 3 Fences:
	// [        |        ] <- buffer
	//     00000 11111111 <loop around, update fences>
	//  222 <can't write more without starting a new render pass>
	CopyFence _copyFences[3];
	MVKSmallVector<OcclusionQueryLocation> _mtlRenderPassQueries;
	/// The pool of the current active query.
	MVKOcclusionQueryPool* _currentPool = nullptr;
	/// The index of the current active query.
	uint32_t _currentQueryIndex = 0;
	/// The visibility result mode of the current active query.
	uint8_t _currentVisibilityResultMode = MTLVisibilityResultModeDisabled;
	/// The visibility result mode of the current Metal render pass.
	uint8_t _metalVisibilityResultMode = MTLVisibilityResultModeDisabled;
	/// The number of fences that need to be waited on by the result copy shader.
	uint8_t _numCopyFences = 0;
	/// If true, accumulation will be run at the end of the next render pass.
	bool _shouldAccumulate = false;
};


