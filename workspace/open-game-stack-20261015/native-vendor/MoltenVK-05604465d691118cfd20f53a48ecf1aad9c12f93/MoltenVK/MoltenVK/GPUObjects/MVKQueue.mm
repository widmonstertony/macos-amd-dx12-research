/*
 * MVKQueue.mm
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

#include "MVKInstance.h"
#include "MVKQueue.h"
#include "MVKSurface.h"
#include "MVKSwapchain.h"
#include "MVKSync.h"
#include "MVKFoundation.h"
#include "MVKOSExtensions.h"
#include "MVKGPUCapture.h"
#include "MVKRuntimeTrace.h"
#include "MVKQueueDependencyTrace.h"
#include "MVKQueueTimingTrace.h"
#include "MVKStutterNativeTrace.h"
#include "MVKStutterCoverage.h"
#include "MVKMemoryTrace.h"
#include "MVKForensicsTrace.h"

using namespace std;

void mvkMarkTrackedCommandBufferCommit(id<MTLCommandBuffer> cb) {
    mvkMarkDependencyCounterCommit(cb);
    mvkQueueTimingCommit(cb);
    mvkStutterMarkNativeCommit(cb);
    if (mvkForensicsArmed() && cb) {
        auto p=mvkStutterNativeSnapshot(cb);
        mvkForensicsRecord("NativeCBCommit",{{"ownerNativeCB",p.nativeID},{"ownerSubmit",p.logical},
            {"ownerFrame",p.frame},{"ownerFamily",p.family},{"ownerIndex",p.index},{"split",p.split}});
    }
}



#pragma mark -
#pragma mark MVKQueueFamily

// Reuse queues across sequential logical devices, but never alias concurrently live
// VkQueues: a FIFO native queue must not put a signal behind another queue's wait.
id<MTLCommandQueue> MVKQueueFamily::getMTLCommandQueue(uint32_t queueIndex) {
    lock_guard<mutex> lock(_qLock);
    for (auto& entry : _mtlQueues) {
        if (!entry.inUse && entry.index == queueIndex && entry.queue) {
            entry.inUse = true;
            return entry.queue;
        }
    }
    @autoreleasepool {
        uint32_t maxCmdBuffs = getMVKConfig().maxActiveMetalCommandBuffersPerQueue;
        id<MTLCommandQueue> queue = [_physicalDevice->getMTLDevice() newCommandQueueWithMaxCommandBufferCount:maxCmdBuffs];
        if (queue) _mtlQueues.push_back({queue, queueIndex, true});
        return queue;
    }
}

void MVKQueueFamily::releaseMTLCommandQueue(id<MTLCommandQueue> queue, bool reusable) {
    lock_guard<mutex> lock(_qLock);
    for (auto& entry : _mtlQueues) {
        if (entry.queue != queue) continue;
        // A lost device's queue may still be draining errors. Never lend it to a
        // new device. Metal retains any outstanding submitted command buffers.
        if (!reusable) { [entry.queue release]; entry.queue = nil; }
        entry.inUse = false;
        return;
    }
}

MVKQueueFamily::MVKQueueFamily(MVKPhysicalDevice* physicalDevice, uint32_t queueFamilyIndex, const VkQueueFamilyProperties* pProperties) {
	_physicalDevice = physicalDevice;
	_queueFamilyIndex = queueFamilyIndex;
	_properties = *pProperties;

}

MVKQueueFamily::~MVKQueueFamily() {
	for (auto& entry : _mtlQueues) [entry.queue release];
}


#pragma mark -
#pragma mark MVKQueue

void MVKQueue::propagateDebugName() { setMetalObjectLabel(_mtlQueue, _debugName); }


#pragma mark Queue submissions

// Execute the queue submission under an autoreleasepool to ensure transient Metal objects are autoreleased.
// This is critical for apps that don't use standard OS autoreleasing runloop threading.
static inline VkResult execute(MVKQueueSubmission* qSubmit) { @autoreleasepool { return qSubmit->execute(); } }

// Executes the submmission, either immediately, or by dispatching to an execution queue.
// Submissions to the execution queue are wrapped in a dedicated autoreleasepool.
// Relying on the dispatch queue to find time to drain the autoreleasepool can
// result in significant memory creep under heavy workloads.
VkResult MVKQueue::submit(MVKQueueSubmission* qSubmit) {
    MVKForensicsScope forensics("NativeQueueDispatch",{{"vkQueue",uint64_t(uintptr_t(getDiagnosticVkQueue()))},
        {"queueFamily",_queueFamily->getIndex()},{"queueIndex",_index},{"async",uint64_t(_execQueue!=nullptr)}});
	if (_device->getConfigurationResult() != VK_SUCCESS) { return _device->getConfigurationResult(); }

	if ( !qSubmit ) { return VK_SUCCESS; }     // Ignore nils

	// Extract result before submission to avoid race condition with early destruction
	// Submit regardless of config result, to ensure submission semaphores and fences are signalled.
	// The submissions will ensure a misconfiguration will be safe to execute.
	VkResult rslt = qSubmit->getConfigurationResult();
	if (_execQueue) {
		std::unique_lock lock(_execQueueMutex);
		_execQueueJobCount++;
        mvkForensicsRecord("NativeDispatchDepth",{{"ownerSubmit",qSubmit->_stutterSubmissionID},
            {"vkQueue",uint64_t(uintptr_t(getDiagnosticVkQueue()))},{"pendingJobs",_execQueueJobCount}});

		dispatch_async(_execQueue, ^{
			execute(qSubmit);

			std::unique_lock execLock(_execQueueMutex);
			if (!--_execQueueJobCount)
				_execQueueConditionVariable.notify_all();
		} );
	} else {
		rslt = execute(qSubmit);
	}
	return rslt;
}

static inline uint32_t getCommandBufferCount(const VkSubmitInfo2* pSubmitInfo) { return pSubmitInfo->commandBufferInfoCount; }
static inline uint32_t getCommandBufferCount(const VkSubmitInfo* pSubmitInfo) { return pSubmitInfo->commandBufferCount; }

// Numeric edge records are bounded per VkSubmit. Values are copied from the caller,
// never inferred for binary semaphores. Dispatchable guest/native handles require a
// verified mapping; pointer equality across Wine is not assumed by the analyzer.
static void mvkForensicsSubmitEdges(const VkSubmitInfo2* s, uint32_t ordinal, uint64_t queue) {
    if(!mvkForensicsArmed()||!s)return;
    mvkForensicsRecord("NativeSubmitShape",{{"vkQueue",queue},{"ordinal",ordinal},{"commands",s->commandBufferInfoCount},
        {"waits",s->waitSemaphoreInfoCount},{"signals",s->signalSemaphoreInfoCount},{"edgeCap",64}});
    for(uint32_t direction=0;direction<2;++direction){
        uint32_t n=direction?s->signalSemaphoreInfoCount:s->waitSemaphoreInfoCount;
        auto* edges=direction?s->pSignalSemaphoreInfos:s->pWaitSemaphoreInfos;
        for(uint32_t i=0;i<std::min(n,64u);++i)mvkForensicsRecord("NativeSubmitEdge",{{"vkQueue",queue},{"ordinal",ordinal},
            {"direction",direction},{"edgeIndex",i},{"semaphore",uint64_t(uintptr_t(edges[i].semaphore))},
            {"value",edges[i].value},{"valueSupplied",1},{"stageMask",edges[i].stageMask}});
    }
}
static void mvkForensicsSubmitEdges(const VkSubmitInfo* s, uint32_t ordinal, uint64_t queue) {
    if(!mvkForensicsArmed()||!s)return;
    const VkTimelineSemaphoreSubmitInfo* timeline=nullptr;
    auto* p=static_cast<const VkBaseInStructure*>(s->pNext);uint32_t chainCount=0;
    for(;p&&chainCount<64;p=p->pNext,++chainCount)if(p->sType==VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO){timeline=reinterpret_cast<const VkTimelineSemaphoreSubmitInfo*>(p);break;}
    mvkForensicsRecord("NativeSubmitShape",{{"vkQueue",queue},{"ordinal",ordinal},{"commands",s->commandBufferCount},
        {"waits",s->waitSemaphoreCount},{"signals",s->signalSemaphoreCount},{"edgeCap",64},{"pNextCapped",uint64_t(p&&chainCount>=64)}});
    for(uint32_t direction=0;direction<2;++direction){
        uint32_t n=direction?s->signalSemaphoreCount:s->waitSemaphoreCount;
        auto* edges=direction?s->pSignalSemaphores:s->pWaitSemaphores;
        for(uint32_t i=0;i<std::min(n,64u);++i){
            bool supplied=timeline&&i<(direction?timeline->signalSemaphoreValueCount:timeline->waitSemaphoreValueCount);
            uint64_t value=supplied?(direction?timeline->pSignalSemaphoreValues[i]:timeline->pWaitSemaphoreValues[i]):0;
            mvkForensicsRecord("NativeSubmitEdge",{{"vkQueue",queue},{"ordinal",ordinal},{"direction",direction},{"edgeIndex",i},
                {"semaphore",uint64_t(uintptr_t(edges[i]))},{"value",value},{"valueSupplied",uint64_t(supplied)},
                {"stageMask",direction?0:uint64_t(s->pWaitDstStageMask[i])}});
        }
    }
}
template <typename S>
VkResult MVKQueue::submit(uint32_t submitCount, const S* pSubmits, VkFence fence, MVKCommandUse cmdUse) {
    MVKForensicsScope forensics("NativeSubmitAPI",{{"vkQueue",uint64_t(uintptr_t(getDiagnosticVkQueue()))},
        {"submitCount",submitCount},{"fence",uint64_t(uintptr_t(fence))},{"commandUse",uint64_t(cmdUse)}});

    // Fence-only submission
    if (submitCount == 0 && fence) {
        return submit(new MVKQueueCommandBufferSubmission(this, (S*)nullptr, fence, cmdUse));
    }

    VkResult rslt = VK_SUCCESS;
    for (uint32_t sIdx = 0; sIdx < submitCount; sIdx++) {
        VkFence fenceOrNil = (sIdx == (submitCount - 1)) ? fence : VK_NULL_HANDLE; // last one gets the fence

		const S* pVkSub = &pSubmits[sIdx];
        mvkForensicsSubmitEdges(pVkSub,sIdx,uint64_t(uintptr_t(getDiagnosticVkQueue())));
		MVKQueueCommandBufferSubmission* mvkSub;
		uint32_t cbCnt = getCommandBufferCount(pVkSub);
		if (cbCnt <= 1) {
			mvkSub = new MVKQueueFullCommandBufferSubmission<1>(this, pVkSub, fenceOrNil, cmdUse);
		} else if (cbCnt <= 16) {
			mvkSub = new MVKQueueFullCommandBufferSubmission<16>(this, pVkSub, fenceOrNil, cmdUse);
		} else if (cbCnt <= 32) {
			mvkSub = new MVKQueueFullCommandBufferSubmission<32>(this, pVkSub, fenceOrNil, cmdUse);
		} else if (cbCnt <= 64) {
			mvkSub = new MVKQueueFullCommandBufferSubmission<64>(this, pVkSub, fenceOrNil, cmdUse);
		} else if (cbCnt <= 128) {
			mvkSub = new MVKQueueFullCommandBufferSubmission<128>(this, pVkSub, fenceOrNil, cmdUse);
		} else if (cbCnt <= 256) {
			mvkSub = new MVKQueueFullCommandBufferSubmission<256>(this, pVkSub, fenceOrNil, cmdUse);
		} else {
			mvkSub = new MVKQueueFullCommandBufferSubmission<512>(this, pVkSub, fenceOrNil, cmdUse);
		}

        if(mvkForensicsArmed())mvkForensicsRecord("NativeSubmitLink",{{"vkQueue",uint64_t(uintptr_t(getDiagnosticVkQueue()))},
            {"ordinal",sIdx},{"ownerSubmit",mvkSub->_stutterSubmissionID},{"commandBuffers",cbCnt},
            {"queueFamily",_queueFamily->getIndex()},{"queueIndex",_index}});
        VkResult subRslt = submit(mvkSub);
        if (rslt == VK_SUCCESS) { rslt = subRslt; }
    }
    return rslt;
}

// Concrete implementations of templated MVKQueue::submit().
template VkResult MVKQueue::submit(uint32_t submitCount, const VkSubmitInfo2* pSubmits, VkFence fence, MVKCommandUse cmdUse);
template VkResult MVKQueue::submit(uint32_t submitCount, const VkSubmitInfo* pSubmits, VkFence fence, MVKCommandUse cmdUse);

VkResult MVKQueue::submit(const VkPresentInfoKHR* pPresentInfo) {
	return submit(new MVKQueuePresentSurfaceSubmission(this, pPresentInfo));
}

VkResult MVKQueue::waitIdle(MVKCommandUse cmdUse) {
    MVKForensicsScope forensics("NativeQueueWaitIdle",{{"vkQueue",uint64_t(uintptr_t(getDiagnosticVkQueue()))}});
    MVK_CPU_SCOPE_CPU(HostFenceWait);
	if (_execQueue) {
		std::unique_lock lock(_execQueueMutex);
		while (_execQueueJobCount)
			_execQueueConditionVariable.wait(lock);
	}
	@autoreleasepool {
		auto* mtlCmdBuff = getMTLCommandBuffer(cmdUse);
		mvkRecordDependencyPhase(mtlCmdBuff, @"commitRequested");
		mvkStutterNativePhase(mtlCmdBuff,"commitRequested");
    mvkMarkTrackedCommandBufferCommit(mtlCmdBuff);
		[mtlCmdBuff commit];
		[mtlCmdBuff waitUntilCompleted];
	}
	return _device->getConfigurationResult();
}

id<MTLCommandBuffer> MVKQueue::getMTLCommandBuffer(MVKCommandUse cmdUse, bool retainRefs) {
    MVK_CPU_SCOPE_CPU(CommandAllocation);
    MVKForensicsScope allocation("NativeCommandAllocation",{{"commandUse",uint64_t(cmdUse)},{"retainedRefs",uint64_t(retainRefs)}});
    const uint64_t forensicsSession=mvkForensicsSessionID();
    mvkStutterReportMetalMemory(_mtlQueue.device);
	id<MTLCommandBuffer> mtlCmdBuff = nil;
	uint64_t startTime = getPerformanceTimestamp();

	MTLCommandBufferDescriptor* mtlCmdBuffDesc = [MTLCommandBufferDescriptor new];	// temp retain
	mtlCmdBuffDesc.retainedReferences = retainRefs;
	if (getMVKConfig().debugMode || mvkGPUTimeoutTraceEnabled() || mvkGPUFailureTraceEnabled()) {
		mtlCmdBuffDesc.errorOptions |= MTLCommandBufferErrorOptionEncoderExecutionStatus;
	}
	mtlCmdBuff = [_mtlQueue commandBufferWithDescriptor: mtlCmdBuffDesc];
	[mtlCmdBuffDesc release];														// temp release
	mvkQueueTimingBegin(mtlCmdBuff, _queueFamily->getIndex(), _index, getMVKConfig().shaderDumpDir);
    mvkStutterBeginNativeCB(mtlCmdBuff,_queueFamily->getIndex(),_index);
    if(forensicsSession){auto p=mvkStutterNativeSnapshot(mtlCmdBuff);mvkForensicsRecordForSession(forensicsSession,"NativeCBCreated",
        {{"ownerNativeCB",p.nativeID},{"ownerFamily",p.family},{"ownerIndex",p.index},{"nativeQueue",uint64_t(uintptr_t(_mtlQueue))},
         {"nativeObject",uint64_t(uintptr_t(mtlCmdBuff))},{"commandUse",uint64_t(cmdUse)}});}

	addPerformanceInterval(getPerformanceStats().queue.retrieveMTLCommandBuffer, startTime);
	NSString* mtlCmdBuffLabel = getMTLCommandBufferLabel(cmdUse);
	setMetalObjectLabel(mtlCmdBuff, mtlCmdBuffLabel);
	mvkBeginDependencyTrace(mtlCmdBuff, _queueFamily->getIndex(), _index, _device, this);
    if (mvkDependencyTraceEnabled()||forensicsSession) [mtlCmdBuff addScheduledHandler:^(id<MTLCommandBuffer> cb) {
        mvkRecordDependencyPhase(cb, @"scheduled");
        mvkStutterNativePhase(cb,"scheduled");
        if(forensicsSession){auto p=mvkStutterNativeSnapshot(cb);mvkForensicsRecordForSession(forensicsSession,"NativeCBScheduled",
            {{"ownerNativeCB",p.nativeID},{"ownerSubmit",p.logical},{"ownerFamily",p.family},{"ownerIndex",p.index}});}
    }];
	[mtlCmdBuff addCompletedHandler: ^(id<MTLCommandBuffer> mtlCB) {
        auto provenance=mvkStutterNativeSnapshot(mtlCB);
        MVKCPUContext context;context.domain=7;context.queueFamily=provenance.family;context.queueIndex=provenance.index;
        context.submission=provenance.logical;context.nativeCB=provenance.nativeID;context.frame=provenance.frame;
        MVKCPUContextGuard contextGuard(context);MVK_CPU_SCOPE_CPU(CallbackCompletion);
        const uint64_t completionSession=forensicsSession?forensicsSession:mvkForensicsSessionID();
        if(completionSession)mvkForensicsRecordForSession(completionSession,"NativeCBCompleted",
            {{"ownerNativeCB",provenance.nativeID},{"ownerSubmit",provenance.logical},{"ownerFrame",provenance.frame},
             {"ownerFamily",provenance.family},{"ownerIndex",provenance.index},{"split",provenance.split},
             {"status",uint64_t(mtlCB.status)},{"error",uint64_t(mtlCB.error.code)},
             {"gpuStartCANS",uint64_t(mtlCB.GPUStartTime*1e9)},{"gpuEndCANS",uint64_t(mtlCB.GPUEndTime*1e9)},
             {"createdCANS",uint64_t(provenance.createdCA*1e9)},{"committedCANS",uint64_t(provenance.committedCA*1e9)},
             {"partialPrefix",uint64_t(!forensicsSession)}});
        mvkRecordDependencyPhase(mtlCB, @"completed");
        NSDictionary* counterRecord=objc_getAssociatedObject(mtlCB,mvkDependencyKey());
        if(mvkStutterNativeEnabled()) {
            NSDictionary*outcome=mvkGPUCounterCaptureOutcome(counterRecord);
            mvkStutterNativePhase(mtlCB,"completed",[outcome[@"sessionID"]unsignedLongLongValue],
                [outcome[@"skipReasonCode"]intValue],[outcome[@"allocated"]boolValue],
                [outcome[@"captureStartedMidCommandBuffer"]boolValue]);
        }
        if(counterRecord[@"gpuCounterBuffer"])mvkWriteRuntimeTrace(getMVKConfig(), @"gpu-timestamps", mvkCommandBufferDependencies(mtlCB));
		// A downstream present buffer may be the command that reports the
		// watchdog even when the expensive upstream buffer completed normally.
		// Preserve the bounded work ring for any unusually long successful
		// buffer before mvkEndDependencyTrace() removes it from the registry.
		// This is diagnostic only: it never changes ordering or completion.
		static const double slowTraceMilliseconds = [] {
			const char* value = getenv("MVK_AMD_SLOW_COMMAND_BUFFER_TRACE_MS");
			if (!value || !value[0]) { return 0.0; }
			char* end = nullptr;
			double parsed = strtod(value, &end);
			return end && !*end && parsed >= 1.0 && parsed <= 60000.0 ? parsed : 0.0;
		}();
		double gpuMilliseconds = (mtlCB.GPUStartTime > 0.0 && mtlCB.GPUEndTime >= mtlCB.GPUStartTime)
			? (mtlCB.GPUEndTime - mtlCB.GPUStartTime) * 1000.0 : 0.0;
        MVKQueueTimingRecord* timing=objc_getAssociatedObject(mtlCB,mvkQueueTimingKey());
        double hostMilliseconds=timing&&timing->committed>=timing->created?(timing->committed-timing->created)*1000.0:0.0;
        double waitMilliseconds=timing&&timing->committed>0&&mtlCB.GPUStartTime>=timing->committed?(mtlCB.GPUStartTime-timing->committed)*1000.0:0.0;
        bool slowGPU=gpuMilliseconds>=slowTraceMilliseconds;
        bool slowHost=mvkStutterNativeEnabled()&&hostMilliseconds>=slowTraceMilliseconds;
        bool slowWait=mvkStutterNativeEnabled()&&waitMilliseconds>=slowTraceMilliseconds;
		if (slowTraceMilliseconds > 0.0 && (slowGPU||slowHost||slowWait) && mvkStutterAdmitSlowSnapshot()) {
			NSMutableDictionary* slow = [mvkCommandBufferDependencies(mtlCB) mutableCopy];
			slow[@"gpuDurationMilliseconds"] = @(gpuMilliseconds);
            slow[@"slowGPUExecution"]=@(slowGPU);slow[@"slowHostPrecommit"]=@(slowHost);slow[@"slowCommitWait"]=@(slowWait);
			slow[@"nativeStatus"] = @(mtlCB.status);
			slow[@"nativeError"] = mtlCB.error.localizedDescription ?: @"";
			slow[@"thresholdMilliseconds"] = @(slowTraceMilliseconds);
			slow[@"GPUStartTime"] = @(mtlCB.GPUStartTime);
			slow[@"GPUEndTime"] = @(mtlCB.GPUEndTime);
			MVKQueueTimingRecord* timing = objc_getAssociatedObject(mtlCB, mvkQueueTimingKey());
			if (timing) {
				slow[@"hostEncodingMilliseconds"] = @((timing->committed - timing->created) * 1000.0);
				slow[@"commitToGPUStartMilliseconds"] = @((mtlCB.GPUStartTime - timing->committed) * 1000.0);
			}
			mvkWriteRuntimeTrace(getMVKConfig(), @"slow-command-buffer", slow);
			[slow release];
		}
		handleMTLCommandBufferError(mtlCB);
		if (mvkDependencyTraceEnabled() && getenv("MVK_AMD_QUEUE_DEPENDENCY_DUMP_ALL"))
			mvkWriteRuntimeTrace(getMVKConfig(), @"queue-dependencies", mvkCommandBufferDependencies(mtlCB));
		mvkEndDependencyTrace(mtlCB);
	}];

	if ( !mtlCmdBuff ) { reportError(VK_ERROR_OUT_OF_POOL_MEMORY, "%s could not be acquired.", mtlCmdBuffLabel.UTF8String); }
	return mtlCmdBuff;
}

NSString* MVKQueue::getMTLCommandBufferLabel(MVKCommandUse cmdUse) {
#define CASE_GET_LABEL(cu)  \
	case kMVKCommandUse ##cu:  \
		if ( !_mtlCmdBuffLabel ##cu ) { _mtlCmdBuffLabel ##cu = [[NSString stringWithFormat: @"%s MTLCommandBuffer on Queue %d-%d", mvkVkCommandName(kMVKCommandUse ##cu), _queueFamily->getIndex(), _index] retain]; }  \
		return _mtlCmdBuffLabel ##cu

	switch (cmdUse) {
		CASE_GET_LABEL(BeginCommandBuffer);
		CASE_GET_LABEL(QueueSubmit);
		CASE_GET_LABEL(QueuePresent);
		CASE_GET_LABEL(QueueWaitIdle);
		CASE_GET_LABEL(DeviceWaitIdle);
		CASE_GET_LABEL(AcquireNextImage);
		CASE_GET_LABEL(InvalidateMappedMemoryRanges);
		CASE_GET_LABEL(CopyImageToMemory);
		default:
			MVKAssert(false, "Uncached MTLCommandBuffer label for command use %s.", mvkVkCommandName(cmdUse));
			return [NSString stringWithFormat: @"%s MTLCommandBuffer on Queue %d-%d", mvkVkCommandName(cmdUse), _queueFamily->getIndex(), _index];
	}
#undef CASE_GET_LABEL
}

static const char* mvkStringFromMTLCommandEncoderErrorState(MTLCommandEncoderErrorState errState) {
	switch (errState) {
		case MTLCommandEncoderErrorStateUnknown:   return "unknown";
		case MTLCommandEncoderErrorStateAffected:  return "affected";
		case MTLCommandEncoderErrorStateCompleted: return "completed";
		case MTLCommandEncoderErrorStateFaulted:   return "faulted";
		case MTLCommandEncoderErrorStatePending:   return "pending";
	}
	return "unknown";
}

void MVKQueue::handleMTLCommandBufferError(id<MTLCommandBuffer> mtlCmdBuff) {
	if (mtlCmdBuff.status != MTLCommandBufferStatusError) { return; }

	// If a command buffer error has occurred, report the error. If the error affects
	// the physical device, always mark both the device and physical device as lost.
	// If the error is local to this command buffer, optionally mark the device (but not the
	// physical device) as lost, depending on the value of MVKConfiguration::resumeLostDevice.
	VkResult vkErr = VK_ERROR_UNKNOWN;
	bool markDeviceLoss = !getMVKConfig().resumeLostDevice;
	bool markPhysicalDeviceLoss = false;
	switch (mtlCmdBuff.error.code) {
		case MTLCommandBufferErrorBlacklisted:
		case MTLCommandBufferErrorNotPermitted:	// May also be used for command buffers executed in the background without the right entitlement.
#if MVK_MACOS && !MVK_MACCAT
		case MTLCommandBufferErrorDeviceRemoved:
#endif
			vkErr = VK_ERROR_DEVICE_LOST;
			markDeviceLoss = true;
			markPhysicalDeviceLoss = true;
			break;
		case MTLCommandBufferErrorTimeout:
			vkErr = VK_TIMEOUT;
			break;
		case MTLCommandBufferErrorStackOverflow:
		case MTLCommandBufferErrorPageFault:
		case MTLCommandBufferErrorOutOfMemory:
		default:
			vkErr = VK_ERROR_OUT_OF_DEVICE_MEMORY;
			break;
	}
    static std::atomic<uint32_t> failureSnapshots{0};
    bool captureFailure = mvkGPUTimeoutTraceEnabled() ||
        (mvkGPUFailureTraceEnabled() && failureSnapshots.fetch_add(1, std::memory_order_relaxed) < 8);
    // Bound expensive failure snapshots, not native error reporting/results.
    if (captureFailure) {
        NSMutableArray* encoders = [NSMutableArray array];
        NSArray<id<MTLCommandBufferEncoderInfo>>* infos = mtlCmdBuff.error.userInfo[MTLCommandBufferEncoderInfoErrorKey];
        for (id<MTLCommandBufferEncoderInfo> encoder in infos) {
            [encoders addObject:@{@"label":encoder.label ?: @"", @"state":@(encoder.errorState),
                @"stateName":@(mvkStringFromMTLCommandEncoderErrorState(encoder.errorState)),
                @"signposts":encoder.debugSignposts ?: @[]}];
        }
        mvkWriteRuntimeTrace(getMVKConfig(), @"gpu-timeout", @{
            @"snapshotBeforeDeviceLossMark":@YES, @"perEncoderWorkTraceEnabled":@(mvkEncoderWorkTraceEnabled()), @"time":@([NSDate timeIntervalSinceReferenceDate]), @"queueFamily":@(_queueFamily->getIndex()),
            @"queueIndex":@(_index), @"label":mtlCmdBuff.label ?: @"", @"errorCode":@(mtlCmdBuff.error.code),
            @"error":mtlCmdBuff.error.localizedDescription ?: @"", @"status":@(mtlCmdBuff.status),
            @"GPUStartTime":@(mtlCmdBuff.GPUStartTime), @"GPUEndTime":@(mtlCmdBuff.GPUEndTime),
            @"encoders":encoders,
            @"dependencies":mvkCommandBufferDependencies(mtlCmdBuff),
            @"pendingQueueDependencies":mvkSnapshotPendingDependencies()});
    }
	if (markDeviceLoss) {
		getDevice()->stopAutoGPUCapture(MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE_DEVICE);
		getDevice()->markLost(markPhysicalDeviceLoss);
	}
	reportResult(vkErr, (markDeviceLoss ? MVK_CONFIG_LOG_LEVEL_ERROR : MVK_CONFIG_LOG_LEVEL_WARNING),
				 "%s VkDevice after MTLCommandBuffer \"%s\" execution failed (code %li): %s",
				 (markDeviceLoss ? "Lost" : "Resumed"),
				 (mtlCmdBuff.label ? mtlCmdBuff.label.UTF8String : ""),
				 mtlCmdBuff.error.code, mtlCmdBuff.error.localizedDescription.UTF8String);


	if (NSArray<id<MTLCommandBufferEncoderInfo>>* mtlEncInfo = mtlCmdBuff.error.userInfo[MTLCommandBufferEncoderInfoErrorKey]) {
		MVKLogInfo("Encoders for %p \"%s\":", mtlCmdBuff, mtlCmdBuff.label ? mtlCmdBuff.label.UTF8String : "");
		for (id<MTLCommandBufferEncoderInfo> enc in mtlEncInfo) {
			MVKLogInfo(" - %s: %s", enc.label.UTF8String, mvkStringFromMTLCommandEncoderErrorState(enc.errorState));
			if (enc.debugSignposts.count > 0) {
				MVKLogInfo("   Debug signposts:");
				for (NSString* signpost in enc.debugSignposts) {
					MVKLogInfo("    - %s", signpost.UTF8String);
				}
			}
		}
	}

	bool isFirstMsg = true;
	for (id<MTLFunctionLog> log in mtlCmdBuff.logs) {
		if (isFirstMsg) {
			MVKLogInfo("Shader log messages:");
			isFirstMsg = false;
		}
		MVKLogInfo("%s", log.description.UTF8String);
	}
}

#pragma mark Construction

MVKQueue::MVKQueue(MVKDevice* device, MVKQueueFamily* queueFamily, uint32_t index, float priority, VkQueueGlobalPriority globalPriority) : MVKDeviceTrackingMixin(device) {
	_queueFamily = queueFamily;
	_index = index;


	_priority = priority;
	_globalPriority = globalPriority;

	initName();
	initExecQueue();
	initMTLCommandQueue();
}

void MVKQueue::initName() {
	const char* fmt = "MoltenVKQueue-%d-%d-%.1f";
	char name[256];
	snprintf(name, sizeof(name)/sizeof(char), fmt, _queueFamily->getIndex(), _index, _priority);
	_name = name;
}

void MVKQueue::initExecQueue() {
	_execQueue = nil;
	if ( !getMVKConfig().synchronousQueueSubmits ) {
		// Determine the dispatch queue priority
		dispatch_qos_class_t dqQOS;
		switch (_globalPriority) {
			case VK_QUEUE_GLOBAL_PRIORITY_LOW:
				dqQOS = QOS_CLASS_UTILITY;
				break;
			case VK_QUEUE_GLOBAL_PRIORITY_HIGH:
				dqQOS = QOS_CLASS_USER_INTERACTIVE;
				break;
			case VK_QUEUE_GLOBAL_PRIORITY_MEDIUM:
			default: // Fall back to default (medium)
				dqQOS = QOS_CLASS_USER_INITIATED;
				break;
		}
		int dqPriority = (1.0 - _priority) * QOS_MIN_RELATIVE_PRIORITY;
		dispatch_queue_attr_t dqAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, dqQOS, dqPriority);

		// Create the dispatch queue
		_execQueue = dispatch_queue_create((getName() + "-Dispatch").c_str(), dqAttr);		// retained
	}
}

// Retrieves and initializes the Metal command queue and Xcode GPU capture scopes
void MVKQueue::initMTLCommandQueue() {
	_mtlQueue = _queueFamily->getMTLCommandQueue(_index);	// exclusive lease; retained by family
    if (mvkGPUTimeoutTraceEnabled()) mvkWriteRuntimeTrace(getMVKConfig(), @"queue-config", @{
        @"queueFamily":@(_queueFamily->getIndex()), @"queueIndex":@(_index),
        @"logicalDevice":[NSString stringWithFormat:@"%p",_device],
        @"logicalQueue":[NSString stringWithFormat:@"%p",this],
        @"nativeQueue":[NSString stringWithFormat:@"%p",_mtlQueue],
        @"specializedFamilies":@(getMVKConfig().specializedQueueFamilies)});
	_device->addResidencySet(_mtlQueue);

	_submissionCaptureScope = new MVKGPUCaptureScope(this);
	if (_queueFamily->getIndex() == getMVKConfig().defaultGPUCaptureScopeQueueFamilyIndex &&
		_index == getMVKConfig().defaultGPUCaptureScopeQueueIndex) {
		getDevice()->startAutoGPUCapture(MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE_FRAME, _mtlQueue);
		_submissionCaptureScope->makeDefault();
	}
	_submissionCaptureScope->beginScope();	// Allow Xcode to capture the first frame if desired.
}

MVKQueue::~MVKQueue() {
	destroyExecQueue();
	_submissionCaptureScope->destroy();
	_device->removeResidencySet(_mtlQueue);
	_queueFamily->releaseMTLCommandQueue(_mtlQueue, _device->getConfigurationResult() == VK_SUCCESS);

	[_mtlCmdBuffLabelBeginCommandBuffer release];
	[_mtlCmdBuffLabelQueueSubmit release];
	[_mtlCmdBuffLabelQueuePresent release];
	[_mtlCmdBuffLabelDeviceWaitIdle release];
	[_mtlCmdBuffLabelQueueWaitIdle release];
	[_mtlCmdBuffLabelAcquireNextImage release];
	[_mtlCmdBuffLabelInvalidateMappedMemoryRanges release];
}

// Destroys the execution dispatch queue.
void MVKQueue::destroyExecQueue() {
	if (_execQueue) {
		dispatch_release(_execQueue);
		_execQueue = nullptr;
	}
}


#pragma mark -
#pragma mark MVKQueueSubmission

void MVKSemaphoreSubmitInfo::encodeWait(id<MTLCommandBuffer> mtlCmdBuff) {
	// A timeline wait that completed through the host notification path has
	// already established the required ordering. Do not enqueue the same wait
	// into Metal: on the Intel-era AMD driver, an otherwise-satisfied shared
	// event wait can still sit at the head of a native queue and block the queue
	// that produces the next value.
    if (!mtlCmdBuff) {
        MVK_CPU_SCOPE_CPU(HostSemaphoreWait);
        if (_semaphore && !hostWaitSatisfied) _semaphore->encodeWait(mtlCmdBuff,value);
    } else if (_semaphore && !hostWaitSatisfied) _semaphore->encodeWait(mtlCmdBuff,value);
}

// The AMD macOS driver can watchdog a Metal queue that contains an unsatisfied
// MTLSharedEvent wait while another native queue is still producing the value.
// Keep Vulkan queue submission asynchronous and preserve per-queue FIFO order,
// but do not put that unsatisfied timeline wait into the native GPU scheduler.
// Once the value is visible on the host, the normal encoded wait remains in the
// command buffer and is immediately satisfied.
void MVKSemaphoreSubmitInfo::gateUnsignaledTimelineWaitOnHost() {
    MVK_CPU_SCOPE_CPU(HostSemaphoreWait);
	// Submission values distinguish the Vulkan timeline path here. Binary
	// semaphore submit records carry zero and therefore return immediately. Do
	// not depend on a late environment lookup or the concrete semaphore wrapper:
	// the game can import a shared-event-backed timeline through a base wrapper,
	// which made the earlier type check skip a real unsatisfied wait.
	hostWaitSatisfied = false;
	if (!_semaphore || value == 0 || _semaphore->getSemaphoreType() != VK_SEMAPHORE_TYPE_TIMELINE) { return; }
	id<MTLSharedEvent> event = _semaphore->getMTLSharedEvent();
	if (!event || event.signaledValue >= value) { return; }

	// MTLSharedEvent::waitUntilSignaledValue() returned before the requested
	// value was visible in the Stellar Blade workload even with an effectively
	// infinite timeout. Use MoltenVK's own listener-backed Vulkan timeline wait,
	// which is also the implementation used by vkWaitSemaphores(). Other VkQueue
	// executors remain runnable, so the producer queue can make progress.
	VkSemaphore vkSemaphore = (VkSemaphore)_semaphore;
	VkSemaphoreWaitInfo waitInfo = {
		VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
		nullptr,
		0,
		1,
		&vkSemaphore,
		&value,
	};
    auto diagnosticWaitArm=mvkStutterNativeArm();
    mvkStutterNativeEvent(nil,(__bridge const void*)event,value,"hostWaitBegin",diagnosticSubmission,event.signaledValue,false,diagnosticWaitArm.session,true);
    VkResult waitResult=mvkWaitSemaphores(_semaphore->getDevice(), &waitInfo, UINT64_MAX);
    if (waitResult==VK_SUCCESS) hostWaitSatisfied=true;
    mvkStutterNativeEvent(nil,(__bridge const void*)event,value,"hostWaitEnd",diagnosticSubmission,event.signaledValue,hostWaitSatisfied,diagnosticWaitArm.session,diagnosticWaitArm.active,!diagnosticWaitArm.active);
}

void MVKSemaphoreSubmitInfo::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff) {
	if (_semaphore) { _semaphore->encodeSignal(mtlCmdBuff, value); }
}

MVKSemaphoreSubmitInfo::MVKSemaphoreSubmitInfo(const VkSemaphoreSubmitInfo& semaphoreSubmitInfo) :
	_semaphore((MVKSemaphore*)semaphoreSubmitInfo.semaphore),
	value(semaphoreSubmitInfo.value),
	stageMask(semaphoreSubmitInfo.stageMask),
	deviceIndex(semaphoreSubmitInfo.deviceIndex) {
		if (_semaphore) { _semaphore->retain(); }
}

MVKSemaphoreSubmitInfo::MVKSemaphoreSubmitInfo(const VkSemaphore semaphore,
											   VkPipelineStageFlags stageMask) :
	_semaphore((MVKSemaphore*)semaphore),
	value(0),
	stageMask(stageMask),
	deviceIndex(0) {
		if (_semaphore) { _semaphore->retain(); }
}

MVKSemaphoreSubmitInfo::MVKSemaphoreSubmitInfo(const MVKSemaphoreSubmitInfo& other) :
	_semaphore(other._semaphore),
	value(other.value),
	stageMask(other.stageMask),
	deviceIndex(other.deviceIndex),
	hostWaitSatisfied(other.hostWaitSatisfied), diagnosticSubmission(other.diagnosticSubmission) {
		if (_semaphore) { _semaphore->retain(); }
}

MVKSemaphoreSubmitInfo& MVKSemaphoreSubmitInfo::operator=(const MVKSemaphoreSubmitInfo& other) {
	// Retain new object first in case it's the same object
	if (other._semaphore) {other._semaphore->retain(); }
	if (_semaphore) { _semaphore->release(); }
	_semaphore = other._semaphore;

	value = other.value;
	stageMask = other.stageMask;
	deviceIndex = other.deviceIndex;
	hostWaitSatisfied = other.hostWaitSatisfied;
    diagnosticSubmission = other.diagnosticSubmission;
	return *this;
}

MVKSemaphoreSubmitInfo::~MVKSemaphoreSubmitInfo() {
	if (_semaphore) { _semaphore->release(); }
}

MVKCommandBufferSubmitInfo::MVKCommandBufferSubmitInfo(const VkCommandBufferSubmitInfo& commandBufferInfo) :
	commandBuffer(MVKCommandBuffer::getMVKCommandBuffer(commandBufferInfo.commandBuffer)),
	deviceMask(commandBufferInfo.deviceMask) {}

MVKCommandBufferSubmitInfo::MVKCommandBufferSubmitInfo(VkCommandBuffer commandBuffer) :
	commandBuffer(MVKCommandBuffer::getMVKCommandBuffer(commandBuffer)),
	deviceMask(0) {}

MVKQueueSubmission::MVKQueueSubmission(MVKQueue* queue,
									   uint32_t waitSemaphoreInfoCount,
									   const VkSemaphoreSubmitInfo* pWaitSemaphoreSubmitInfos) : 
	MVKBaseDeviceObject(queue->getDevice()),
	_queue(queue) {

	_queue->retain();	// Retain here and release in destructor. See note for MVKQueueCommandBufferSubmission::finish().
	_creationTime = getPerformanceTimestamp();
    _stutterSubmissionID=mvkStutterNextLogicalID();
    _stutterCreatedNS=mvkStutterCoverageEnabled()?mvkStutterMonotonicNS():0;
    mvkStutterSubmissionPhase(_stutterSubmissionID,_queue->_queueFamily->getIndex(),_queue->_index,"queued",_stutterCreatedNS);

	_waitSemaphores.reserve(waitSemaphoreInfoCount);
	for (uint32_t i = 0; i < waitSemaphoreInfoCount; i++) {
		_waitSemaphores.emplace_back(pWaitSemaphoreSubmitInfos[i]);
        _waitSemaphores.back().diagnosticSubmission=_stutterSubmissionID;
	}
}

MVKQueueSubmission::MVKQueueSubmission(MVKQueue* queue,
									   uint32_t waitSemaphoreCount,
									   const VkSemaphore* pWaitSemaphores,
									   const VkPipelineStageFlags* pWaitDstStageMask) :
	MVKBaseDeviceObject(queue->getDevice()),
	_queue(queue) {

	_queue->retain();	// Retain here and release in destructor. See note for MVKQueueCommandBufferSubmission::finish().
	_creationTime = getPerformanceTimestamp();
    _stutterSubmissionID=mvkStutterNextLogicalID();
    _stutterCreatedNS=mvkStutterCoverageEnabled()?mvkStutterMonotonicNS():0;
    mvkStutterSubmissionPhase(_stutterSubmissionID,_queue->_queueFamily->getIndex(),_queue->_index,"queued",_stutterCreatedNS);

	_waitSemaphores.reserve(waitSemaphoreCount);
	for (uint32_t i = 0; i < waitSemaphoreCount; i++) {
		_waitSemaphores.emplace_back(pWaitSemaphores[i], pWaitDstStageMask ? pWaitDstStageMask[i] : 0);
        _waitSemaphores.back().diagnosticSubmission=_stutterSubmissionID;
	}
}

MVKQueueSubmission::~MVKQueueSubmission() {
	_queue->release();
}


#pragma mark -
#pragma mark MVKQueueCommandBufferSubmission

VkResult MVKQueueCommandBufferSubmission::execute() {
    MVKCPUContext context=mvkStutterContext();
    context.domain=std::min(_queue->_queueFamily->getIndex()+1,6u);
    context.queueFamily=_queue->_queueFamily->getIndex(); context.queueIndex=_queue->_index;
    context.submission=_stutterSubmissionID; context.nativeCB=0; context.frame=0;
    MVKCPUContextGuard contextGuard(context);
    MVK_CPU_SCOPE_TAG(QueueExecute,_stutterSubmissionID);
    // The submission may destroy itself in commit completion. The scope saves
    // only numeric context and never dereferences this from its destructor.
    MVKForensicsScope forensics("NativeQueueExecute",{{"vkQueue",uint64_t(uintptr_t(_queue->getDiagnosticVkQueue()))},
        {"waitCount",_waitSemaphores.size()},{"signalCount",_signalSemaphores.size()}});
    if(_stutterCreatedNS)mvkStutterAsync(MVKCPUPhase::QueueDispatchDelay,mvkStutterMonotonicNS()-_stutterCreatedNS,_stutterSubmissionID);
    mvkStutterSubmissionPhase(_stutterSubmissionID,context.queueFamily,context.queueIndex,"executing",_stutterCreatedNS);

	_queue->_submissionCaptureScope->beginScope();

	// This gate is only enabled together with asynchronous queue submission.
	// Each VkQueue owns a serial dispatch queue, so waiting here preserves Vulkan
	// queue order while other queues remain free to produce the required value.
	for (auto& ws : _waitSemaphores) { MVKForensicsScope gate("NativeTimelineHostGate"); ws.gateUnsignaledTimelineWaitOnHost(); }

	// If using encoded semaphore waiting, do so now.
	for (auto& ws : _waitSemaphores) { ws.encodeWait(getActiveMTLCommandBuffer()); }

	// Wait time from an async vkQueueSubmit() call to starting submit and encoding of the command buffers
	addPerformanceInterval(_queue->getPerformanceStats().queue.waitSubmitCommandBuffers, _creationTime);

	// Submit each command buffer.
    { MVK_CPU_SCOPE_CPU(QueueSubmitWork); submitCommandBuffers(); }

	// If using encoded semaphore signaling, do so now.
	for (auto& ss : _signalSemaphores) { ss.encodeSignal(getActiveMTLCommandBuffer()); }

	// Commit the last MTLCommandBuffer.
	// Nothing after this because callback might destroy this instance before this function ends.
	return commitActiveMTLCommandBuffer(true);
}

// Returns the active MTLCommandBuffer, lazily retrieving it from the queue if needed.
id<MTLCommandBuffer> MVKQueueCommandBufferSubmission::getActiveMTLCommandBuffer() {
	if ( !_activeMTLCommandBuffer ) {
		bool needsRetain = false;
		if (!_device->hasResidencySet() && (getEnabledDescriptorIndexingFeatures().descriptorBindingPartiallyBound || getMVKConfig().liveCheckAllResources)) {
			// Partially bound descriptors will get bound by us even if they're not used at runtime by the shader.
			// The application is free to destroy them even if they're not used at runtime even if we bound them.
			// Metal will be very unhappy if we destroy something we bound, even if it isn't used at runtime.
			needsRetain = true;
		}
		setActiveMTLCommandBuffer(_queue->getMTLCommandBuffer(_commandUse, needsRetain));
	}
	return _activeMTLCommandBuffer;
}

// Commits the current active MTLCommandBuffer, if it exists, and sets a new active MTLCommandBuffer.
void MVKQueueCommandBufferSubmission::setActiveMTLCommandBuffer(id<MTLCommandBuffer> mtlCmdBuff) {

	if (_activeMTLCommandBuffer) { commitActiveMTLCommandBuffer(); }

	_activeMTLCommandBuffer = [mtlCmdBuff retain];		// retained to handle prefilled
    mvkStutterTagNativeCB(_activeMTLCommandBuffer,_stutterSubmissionID,_stutterNativeSplit++);
    if(mvkStutterNativeEnabled())MVKStutterCPUTrace::currentContext.nativeCB=mvkStutterNativeID(_activeMTLCommandBuffer);
    if(mvkStutterNativeEnabled()) {
        NSMutableDictionary*record=objc_getAssociatedObject(_activeMTLCommandBuffer,mvkDependencyKey());
        if(record)@synchronized(record){record[@"logicalSubmissionID"]=@(_stutterSubmissionID);record[@"nativeSplitIndex"]=@(_stutterNativeSplit-1);record[@"presentFrameID"]=@0;}
    }
    mvkStutterNativePhase(_activeMTLCommandBuffer,"enqueue");
	mvkRecordDependencyPhase(_activeMTLCommandBuffer, @"enqueueRequested");
	[_activeMTLCommandBuffer enqueue];
}

// Commits and releases the currently active MTLCommandBuffer, optionally signalling
// when the MTLCommandBuffer is done. The first time this is called, it will wait on
// any semaphores. We have delayed signalling the semaphores as long as possible to
// allow as much filling of the MTLCommandBuffer as possible before forcing a wait.
VkResult MVKQueueCommandBufferSubmission::commitActiveMTLCommandBuffer(bool signalCompletion) {
    MVK_CPU_SCOPE(NativeCommit);

	// If using inline semaphore waiting, do so now.
	// When prefilled command buffers are used, multiple commits will happen because native semaphore
	// waits need to be committed before the prefilled command buffer is committed. Since semaphores
	// will reset their internal signal flag on wait, we need to make sure that we only wait once, otherwise we will freeze.
	// Another option to wait on emulated semaphores once is to do it in the execute function, but doing it here
	// should be more performant when prefilled command buffers aren't used, because we spend time encoding commands
	// first, thus giving the command buffer signalling these semaphores more time to complete.
	if ( !_emulatedWaitDone ) {
		for (auto& ws : _waitSemaphores) { ws.encodeWait(nil); }
		_emulatedWaitDone = true;
	}

	// The visibility result buffer will be returned to its pool when the active MTLCommandBuffer
	// finishes executing, and therefore cannot be used beyond the active MTLCommandBuffer.
	// By now, it's been submitted to the MTLCommandBuffer, so remove it from the encoding context,
	// to ensure a fresh one will be used by commands executing on any subsequent MTLCommandBuffers.
	if (_encodingContext.visibilityResultBuffer.buffer())
		_device->returnVisibilityBuffer(std::move(_encodingContext.visibilityResultBuffer));

	// If this is the last command buffer in the submission, we're losing the context and need synchronize
	// current barrier fences to the ones at index 0, which will be what the next submision starts with.
	if (isUsingMetalArgumentBuffers() && signalCompletion) {
		_encodingContext.syncFences(getDevice(), _activeMTLCommandBuffer);
	}

	// If we need to signal completion, use getActiveMTLCommandBuffer() to ensure at least
	// one MTLCommandBuffer is used, otherwise if this instance has no content, it will not
	// finish(), signal the fence and semaphores, and be destroyed.
	// Use temp var for MTLCommandBuffer commit and release because completion callback
	// may destroy this instance before this function ends.
	id<MTLCommandBuffer> mtlCmdBuff = signalCompletion ? getActiveMTLCommandBuffer() : _activeMTLCommandBuffer;
	_activeMTLCommandBuffer = nil;
    if(mvkStutterNativeEnabled())MVKStutterCPUTrace::currentContext.nativeCB=0;

	uint64_t startTime = getPerformanceTimestamp();
	[mtlCmdBuff addCompletedHandler: ^(id<MTLCommandBuffer> mtlCB) {
		addPerformanceInterval(getPerformanceStats().queue.mtlCommandBufferExecution, startTime);
		if (signalCompletion) { this->finish(); }	// Must be the last thing the completetion callback does.
	}];

	// Retrieve the result before committing MTLCommandBuffer, because finish() will destroy this instance.
	VkResult rslt = mtlCmdBuff ? getConfigurationResult() : VK_ERROR_OUT_OF_POOL_MEMORY;
	mvkRecordDependencyPhase(mtlCmdBuff, @"commitRequested");
	mvkStutterNativePhase(mtlCmdBuff,"commitRequested");
    mvkMarkTrackedCommandBufferCommit(mtlCmdBuff);
		[mtlCmdBuff commit];
	[mtlCmdBuff release];		// retained

	// If we need to signal completion, but an error occurred and the MTLCommandBuffer
	// was not created, call the finish() function directly.
	if (signalCompletion && !mtlCmdBuff) { finish(); }

	return rslt;
}

// Be sure to retain() any API objects referenced in this function, and release() them in the
// destructor (or superclass destructor). It is possible for rare race conditions to result
// in the app destroying API objects before this function completes execution. For example,
// this may occur if a GPU semaphore here triggers another submission that triggers a fence,
// and the app immediately destroys objects. Rare, but it has been encountered.
void MVKQueueCommandBufferSubmission::finish() {

	// Performed here instead of as part of execute() for rare case where app destroys queue
	// immediately after a waitIdle() is cleared by fence below, taking the capture scope with it.
	_queue->_submissionCaptureScope->endScope();

	// If using inline semaphore signaling, do so now.
	for (auto& ss : _signalSemaphores) { ss.encodeSignal(nil); }

	// If a fence exists, signal it.
	if (_fence) { _fence->signal(); }

	this->destroy();
}

// On device loss, the fence and signal semaphores may be signalled early, and they might then
// be destroyed on the waiting thread before this submission is done with them. We therefore
// retain() each here to ensure they live long enough for this submission to finish using them.
MVKQueueCommandBufferSubmission::MVKQueueCommandBufferSubmission(MVKQueue* queue,
																 const VkSubmitInfo2* pSubmit,
																 VkFence fence,
																 MVKCommandUse cmdUse) :
	MVKQueueSubmission(queue,
					   pSubmit ? pSubmit->waitSemaphoreInfoCount : 0,
					   pSubmit ? pSubmit->pWaitSemaphoreInfos : nullptr),
	_fence((MVKFence*)fence),
	_commandUse(cmdUse) {
	
	if (_fence) { _fence->retain(); }

	// pSubmit can be null if just tracking the fence alone
	if (pSubmit) {
		uint32_t ssCnt = pSubmit->signalSemaphoreInfoCount;
		_signalSemaphores.reserve(ssCnt);
		for (uint32_t i = 0; i < ssCnt; i++) {
			_signalSemaphores.emplace_back(pSubmit->pSignalSemaphoreInfos[i]);
		}
	}
}

// On device loss, the fence and signal semaphores may be signalled early, and they might then
// be destroyed on the waiting thread before this submission is done with them. We therefore
// retain() each here to ensure they live long enough for this submission to finish using them.
MVKQueueCommandBufferSubmission::MVKQueueCommandBufferSubmission(MVKQueue* queue,
																 const VkSubmitInfo* pSubmit,
																 VkFence fence,
																 MVKCommandUse cmdUse)
	: MVKQueueSubmission(queue,
						 pSubmit ? pSubmit->waitSemaphoreCount : 0,
						 pSubmit ? pSubmit->pWaitSemaphores : nullptr,
						 pSubmit ? pSubmit->pWaitDstStageMask : nullptr),

	_fence((MVKFence*)fence),
	_commandUse(cmdUse) {
	
	if (_fence) { _fence->retain(); }

    // pSubmit can be null if just tracking the fence alone
    if (pSubmit) {
		uint32_t ssCnt = pSubmit->signalSemaphoreCount;
		_signalSemaphores.reserve(ssCnt);
		for (uint32_t i = 0; i < ssCnt; i++) {
			_signalSemaphores.emplace_back(pSubmit->pSignalSemaphores[i], 0);
		}

		VkTimelineSemaphoreSubmitInfo* pTimelineSubmit = nullptr;
        for (const auto* next = (const VkBaseInStructure*)pSubmit->pNext; next; next = next->pNext) {
            switch (next->sType) {
                case VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO:
                    pTimelineSubmit = (VkTimelineSemaphoreSubmitInfo*)next;
                    break;
                default:
                    break;
            }
        }
        if (pTimelineSubmit) {
            uint32_t wsvCnt = pTimelineSubmit->waitSemaphoreValueCount;
            for (uint32_t i = 0; i < wsvCnt; i++) {
                _waitSemaphores[i].value = pTimelineSubmit->pWaitSemaphoreValues[i];
            }

			uint32_t ssvCnt = pTimelineSubmit->signalSemaphoreValueCount;
			for (uint32_t i = 0; i < ssvCnt; i++) {
				_signalSemaphores[i].value = pTimelineSubmit->pSignalSemaphoreValues[i];
			}
        }
    }
}

MVKQueueCommandBufferSubmission::~MVKQueueCommandBufferSubmission() {
	if (_fence) { _fence->release(); }
}


template <size_t N>
void MVKQueueFullCommandBufferSubmission<N>::submitCommandBuffers() {
	uint64_t startTime = getPerformanceTimestamp();

	// A Vulkan queue submit may contain several command buffers. MoltenVK normally
	// coalesces them into one Metal command buffer. On the affected AMD driver a
	// large D3D12 frame can then contain many independent shadow/cubemap encoders
	// and exceed the driver's per-command-buffer watchdog even though every
	// encoder completes successfully. Keep the Vulkan ordering and semaphore
	// scope, but allow a native commit at the already-safe Vulkan command-buffer
	// boundary. commitActiveMTLCommandBuffer(false) is the same path used when a
	// prefilled command buffer forces an intermediate commit; queue order carries
	// the work dependency and the final buffer alone signals submission completion.
	static const bool splitVulkanCommandBuffers = [] {
		const char* value = getenv("MVK_AMD_SPLIT_VULKAN_COMMAND_BUFFERS");
		return value && !strcmp(value, "1");
	}();
	for (size_t idx = 0; idx < _cmdBuffers.size(); ++idx) {
		_cmdBuffers[idx].commandBuffer->submit(this, &_encodingContext);
		if (splitVulkanCommandBuffers && idx + 1 < _cmdBuffers.size()) {
			commitActiveMTLCommandBuffer(false);
		}
	}

	addPerformanceInterval(getPerformanceStats().queue.submitCommandBuffers, startTime);
}

template <size_t N>
MVKQueueFullCommandBufferSubmission<N>::MVKQueueFullCommandBufferSubmission(MVKQueue* queue,
																			const VkSubmitInfo2* pSubmit,
																			VkFence fence,
																			MVKCommandUse cmdUse)
	: MVKQueueCommandBufferSubmission(queue, pSubmit, fence, cmdUse) {

	if (pSubmit) {
		uint32_t cbCnt = pSubmit->commandBufferInfoCount;
		_cmdBuffers.reserve(cbCnt);
		for (uint32_t i = 0; i < cbCnt; i++) {
			_cmdBuffers.emplace_back(pSubmit->pCommandBufferInfos[i]);
			setConfigurationResult(_cmdBuffers.back().commandBuffer->getConfigurationResult());
		}
	}
}

template <size_t N>
MVKQueueFullCommandBufferSubmission<N>::MVKQueueFullCommandBufferSubmission(MVKQueue* queue,
																			const VkSubmitInfo* pSubmit,
																			VkFence fence,
																			MVKCommandUse cmdUse)
	: MVKQueueCommandBufferSubmission(queue, pSubmit, fence, cmdUse) {

	if (pSubmit) {
		uint32_t cbCnt = pSubmit->commandBufferCount;
		_cmdBuffers.reserve(cbCnt);
		for (uint32_t i = 0; i < cbCnt; i++) {
			_cmdBuffers.emplace_back(pSubmit->pCommandBuffers[i]);
			setConfigurationResult(_cmdBuffers.back().commandBuffer->getConfigurationResult());
		}
	}
}


#pragma mark -
#pragma mark MVKQueuePresentSurfaceSubmission

// If the semaphores are encodable, wait on them by encoding them on the MTLCommandBuffer before presenting.
// If the semaphores are not encodable, wait on them inline after presenting.
// The semaphores know what to do.
VkResult MVKQueuePresentSurfaceSubmission::execute() {
    MVKCPUContext context=mvkStutterContext();
    context.domain=std::min(_queue->_queueFamily->getIndex()+1,6u);
    context.queueFamily=_queue->_queueFamily->getIndex(); context.queueIndex=_queue->_index;
    context.submission=_stutterSubmissionID; context.nativeCB=0; context.frame=_stutterSubmissionID;
    MVKCPUContextGuard contextGuard(context);
    MVK_CPU_SCOPE_TAG(QueueExecute,_stutterSubmissionID);
    if(_stutterCreatedNS)mvkStutterAsync(MVKCPUPhase::QueueDispatchDelay,mvkStutterMonotonicNS()-_stutterCreatedNS,_stutterSubmissionID);
    mvkStutterSubmissionPhase(_stutterSubmissionID,context.queueFamily,context.queueIndex,"executing",_stutterCreatedNS);
	// MTLCommandBuffer retain references to avoid rare case where objects are destroyed too early.
	// Although testing could not determine which objects were being lost, queue present MTLCommandBuffers
	// are used only once per frame, and retain so few objects, that blanket retention is still performant.
	id<MTLCommandBuffer> mtlCmdBuff = _queue->getMTLCommandBuffer(kMVKCommandUseQueuePresent, true);
    mvkStutterTagNativeCB(mtlCmdBuff,_stutterSubmissionID,0,_stutterSubmissionID);
    if(mvkStutterNativeEnabled())MVKStutterCPUTrace::currentContext.nativeCB=mvkStutterNativeID(mtlCmdBuff);
    if(mvkStutterNativeEnabled()){
        NSMutableDictionary*record=objc_getAssociatedObject(mtlCmdBuff,mvkDependencyKey());
        if(record)@synchronized(record){record[@"logicalSubmissionID"]=@(_stutterSubmissionID);record[@"nativeSplitIndex"]=@0;record[@"presentFrameID"]=@(_stutterSubmissionID);}
    }

	// Present submissions run on the queue's same serial host executor as ordinary
	// submissions. Apply the AMD cross-queue timeline gate here too, before an
	// unsatisfied MTLSharedEvent wait reaches the native GPU scheduler. Without
	// this, leaving an in-game menu can make the present queue wait for work on a
	// different Metal queue and trigger the AMD driver's five-second watchdog.
	for (auto& ws : _waitSemaphores) { ws.gateUnsignaledTimelineWaitOnHost(); }

	for (auto& ws : _waitSemaphores) {
		ws.encodeWait(mtlCmdBuff);	// Encoded semaphore waits
		ws.encodeWait(nil);			// Inline semaphore waits
	}

	// Wait time from an async vkQueuePresentKHR() call to starting presentation of the swapchains
	addPerformanceInterval(getPerformanceStats().queue.waitPresentSwapchains, _creationTime);

	for (int i = 0; i < _presentInfo.size(); i++ ) {
        MVK_CPU_SCOPE(NativePresent);
        _presentInfo[i].diagnosticFrameID=_stutterSubmissionID;
        _presentInfo[i].diagnosticNativeCB=mvkStutterNativeID(mtlCmdBuff);
        auto provenance=mvkStutterNativeSnapshot(mtlCmdBuff);
        _presentInfo[i].diagnosticCaptureSession=provenance.session;
        _presentInfo[i].diagnosticPartialPrefix=provenance.partialPrefix;
		setConfigurationResult(_presentInfo[i].presentableImage->presentCAMetalDrawable(mtlCmdBuff, _presentInfo[i]));
	}

	if (_queue->_queueFamily->getIndex() == getMVKConfig().defaultGPUCaptureScopeQueueFamilyIndex &&
		_queue->_index == getMVKConfig().defaultGPUCaptureScopeQueueIndex) {
		getDevice()->stopAutoGPUCapture(MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE_ON_DEMAND);
		getDevice()->startAutoGPUCapture(MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE_ON_DEMAND, _queue->getMTLCommandQueue());
	}

	if ( !mtlCmdBuff ) { setConfigurationResult(VK_ERROR_OUT_OF_POOL_MEMORY); }	// Check after images may set error.

	// Add completion callback to the MTLCommandBuffer to call finish(), 
	// or if the MTLCommandBuffer could not be created, call finish() directly.
	// Retrieve the result first, because finish() will destroy this instance.
	VkResult rslt = getConfigurationResult();
	if (mtlCmdBuff) {
		[mtlCmdBuff addCompletedHandler: ^(id<MTLCommandBuffer> mtlCB) { this->finish(); }];
		mvkRecordDependencyPhase(mtlCmdBuff, @"commitRequested");
		mvkStutterNativePhase(mtlCmdBuff,"commitRequested");
    mvkMarkTrackedCommandBufferCommit(mtlCmdBuff);
		[mtlCmdBuff commit];
	} else {
		finish();
	}
	return rslt;
}

void MVKQueuePresentSurfaceSubmission::finish() {

	// Let Xcode know the current frame is done, then start a new frame,
	// and if auto GPU capture is active, and it's time to stop it, do so.
	auto cs = _queue->_submissionCaptureScope;
	cs->endScope();
	cs->beginScope();
	if (_queue->_queueFamily->getIndex() == getMVKConfig().defaultGPUCaptureScopeQueueFamilyIndex &&
		_queue->_index == getMVKConfig().defaultGPUCaptureScopeQueueIndex) {
		getDevice()->stopAutoGPUCapture(MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE_FRAME);
	}

	this->destroy();
}

MVKQueuePresentSurfaceSubmission::MVKQueuePresentSurfaceSubmission(MVKQueue* queue,
																   const VkPresentInfoKHR* pPresentInfo)
	: MVKQueueSubmission(queue, pPresentInfo->waitSemaphoreCount, pPresentInfo->pWaitSemaphores, nullptr) {

	const VkPresentTimesInfoGOOGLE* pPresentTimesInfo = nullptr;
	const VkSwapchainPresentFenceInfoKHR* pPresentFenceInfo = nullptr;
	const VkSwapchainPresentModeInfoKHR* pPresentModeInfo = nullptr;
	const VkPresentRegionsKHR* pPresentRegions = nullptr;
	const VkPresentIdKHR* pPresentId = nullptr;
	const VkPresentId2KHR* pPresentId2 = nullptr;
	for (auto* next = (const VkBaseInStructure*)pPresentInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
			case VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR:
				pPresentRegions = (const VkPresentRegionsKHR*) next;
				break;
			case VK_STRUCTURE_TYPE_PRESENT_ID_KHR:
				pPresentId = (const VkPresentIdKHR*) next;
				break;
			case VK_STRUCTURE_TYPE_PRESENT_ID_2_KHR:
				pPresentId2 = (const VkPresentId2KHR*) next;
				break;
			case VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_KHR:
				pPresentFenceInfo = (const VkSwapchainPresentFenceInfoKHR*) next;
				break;
			case VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_MODE_INFO_KHR:
				pPresentModeInfo = (const VkSwapchainPresentModeInfoKHR*) next;
				break;
			case VK_STRUCTURE_TYPE_PRESENT_TIMES_INFO_GOOGLE:
				pPresentTimesInfo = (const VkPresentTimesInfoGOOGLE*) next;
				break;
			default:
				break;
		}
	}

	// Populate the array of swapchain images, testing each one for status
	uint32_t scCnt = pPresentInfo->swapchainCount;
	const VkPresentTimeGOOGLE* pPresentTimes = nullptr;
	if (pPresentTimesInfo) {
		pPresentTimes = pPresentTimesInfo->pTimes;
		MVKAssert(pPresentTimesInfo->swapchainCount == scCnt, "VkPresentTimesInfoGOOGLE swapchainCount must match VkPresentInfo swapchainCount.");
	}
	const VkPresentModeKHR* pPresentModes = nullptr;
	if (pPresentModeInfo) {
		pPresentModes = pPresentModeInfo->pPresentModes;
		MVKAssert(pPresentModeInfo->swapchainCount == scCnt, "VkSwapchainPresentModeInfoKHR swapchainCount must match VkPresentInfo swapchainCount.");
	}
	const VkFence* pFences = nullptr;
	if (pPresentFenceInfo) {
		pFences = pPresentFenceInfo->pFences;
		MVKAssert(pPresentFenceInfo->swapchainCount == scCnt, "VkSwapchainPresentFenceInfoKHR swapchainCount must match VkPresentInfo swapchainCount.");
	}
	const VkPresentRegionKHR* pRegions = nullptr;
	if (pPresentRegions) {
		pRegions = pPresentRegions->pRegions;
	}
	const uint64_t* pPresentIds = nullptr;
	if (pPresentId2) {
		pPresentIds = pPresentId2->pPresentIds;
	} else if (pPresentId) {
		pPresentIds = pPresentId->pPresentIds;
	}

	VkResult* pSCRslts = pPresentInfo->pResults;
	_presentInfo.reserve(scCnt);
	for (uint32_t scIdx = 0; scIdx < scCnt; scIdx++) {
		MVKSwapchain* mvkSC = (MVKSwapchain*)pPresentInfo->pSwapchains[scIdx];
		MVKImagePresentInfo presentInfo = {};	// Start with everything zeroed
		presentInfo.queue = _queue;
		presentInfo.presentableImage = mvkSC->getPresentableImage(pPresentInfo->pImageIndices[scIdx]);
		presentInfo.presentMode = pPresentModes ? pPresentModes[scIdx] : VK_PRESENT_MODE_MAX_ENUM_KHR;
		presentInfo.fence = pFences ? (MVKFence*)pFences[scIdx] : nullptr;
		presentInfo.presentId = pPresentIds ? pPresentIds[scIdx] : 0;
		if (pPresentTimes) {
			presentInfo.presentIDGoogle = pPresentTimes[scIdx].presentID;
			presentInfo.desiredPresentTime = pPresentTimes[scIdx].desiredPresentTime;
		}
		mvkSC->setLayerNeedsDisplay(pRegions ? &pRegions[scIdx] : nullptr);
		_presentInfo.push_back(presentInfo);
		VkResult scRslt = mvkSC->getSurfaceStatus();
		if (pSCRslts) { pSCRslts[scIdx] = scRslt; }
		setConfigurationResult(scRslt);
	}
}

