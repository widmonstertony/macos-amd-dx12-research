/*
 * MVKSync.mm
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

#include "MVKSync.h"
#include "MVKForensicsTrace.h"
#include "MVKStutterNativeTrace.h"
#include "MVKFoundation.h"
#include "MVKInstance.h"
#include "MVKQueueDependencyTrace.h"

using namespace std;

// Value-only captures survive the existing callback without retaining events or
// sitters. These rows describe host actions, never a GPU event signal timestamp.
struct MVKSyncWaitDiagnostic {
    uint64_t session=0,registrationID=0,waiterThread=0,semaphore=0,event=0,requested=0;
    MVKCPUContext owner{};
};
static uint64_t mvkSyncDiagnosticTime(uint64_t session) {
    if(!session)return 0;MVKForensics::ErrnoGuard preserve;return mvkStutterMonotonicNS();
}
static MVKSyncWaitDiagnostic mvkSyncWaitDiagnostic(const void*semaphore,const void*event,uint64_t requested) {
    MVKForensics::ErrnoGuard preserve;MVKSyncWaitDiagnostic d;d.session=mvkForensicsSessionID();if(!d.session)return d;
    static atomic<uint64_t> nextRegistrationID{1};d.registrationID=nextRegistrationID.fetch_add(1,memory_order_relaxed);
    pthread_threadid_np(nullptr,&d.waiterThread);d.owner=mvkStutterContext();
    d.semaphore=uint64_t(uintptr_t(semaphore));d.event=uint64_t(uintptr_t(event));d.requested=requested;return d;
}
struct MVKSyncIntentDiagnostic {uint64_t writerStart=0,writerEnd=0;bool fileFlushSucceeded=false;};
static MVKSyncIntentDiagnostic mvkSyncHostSignalIntent(const MVKSyncWaitDiagnostic&d,uint64_t source) {
    MVKSyncIntentDiagnostic intent;if(!d.session)return intent;
    intent.writerStart=mvkSyncDiagnosticTime(d.session);
    mvkForensicsRecordForSession(d.session,"NativeHostSignalBegin",{{"diagnosticSchema",2},{"operationID",d.registrationID},
        {"semaphore",d.semaphore},{"event",d.event},{"requestedValue",d.requested},{"signalSource",source},
        {"intentMachNS",intent.writerStart},{"signalThreadMachID",d.waiterThread},
        {"ownerSubmission",d.owner.submission},{"ownerNativeCB",d.owner.nativeCB},
        {"ownerQueueFamily",d.owner.queueFamily},{"ownerQueueIndex",d.owner.queueIndex},{"unfinishedUntilMatchingEnd",1}});
    intent.fileFlushSucceeded=mvkForensicsFlushIntent(d.session);intent.writerEnd=mvkSyncDiagnosticTime(d.session);return intent;
}
static void mvkSyncRecordHostSignal(const MVKSyncWaitDiagnostic&d,const MVKSyncIntentDiagnostic&intent,uint64_t before,uint64_t after,uint64_t source) {
    if(!d.session)return;
    mvkForensicsRecordForSession(d.session,"NativeHostSignal",{{"diagnosticSchema",2},{"operationID",d.registrationID},
        {"semaphore",d.semaphore},{"event",d.event},{"requestedValue",d.requested},
        {"observedValueAvailable",0},{"callStartMachNS",before},{"callEndMachNS",after},
        {"intentWriterWallNS",intent.writerEnd-intent.writerStart},{"intentFileFlushSucceeded",intent.fileFlushSucceeded},{"writerAdmissionKnown",0},
        {"signalSource",source},{"setterReturned",1},{"signalThreadMachID",d.waiterThread},
        {"ownerSubmission",d.owner.submission},{"ownerNativeCB",d.owner.nativeCB},
        {"ownerQueueFamily",d.owner.queueFamily},{"ownerQueueIndex",d.owner.queueIndex}});
}
static void mvkSyncPublishWaitRegistration(const MVKSyncWaitDiagnostic&d,uint64_t observed,uint64_t start,uint64_t disposition,bool installed) {
    if(!d.session)return;
    uint64_t end=mvkSyncDiagnosticTime(d.session),writerStart=mvkSyncDiagnosticTime(d.session);
    mvkForensicsRecordForSession(d.session,"NativeWaitRegistration",{
        {"diagnosticSchema",2},{"waitRegistrationID",d.registrationID},{"semaphore",d.semaphore},
        {"event",d.event},{"requestedValue",d.requested},{"observedValue",observed},
        {"registrationStartMachNS",start},{"registrationEndMachNS",end},
        {"registrationDisposition",disposition},{"listenerInstalled",installed},{"waiterThreadMachID",d.waiterThread},
        {"waiterSubmission",d.owner.submission},{"waiterNativeCB",d.owner.nativeCB},
        {"waiterQueueFamily",d.owner.queueFamily},{"waiterQueueIndex",d.owner.queueIndex}});
    bool flushed=mvkForensicsFlushIntent(d.session);uint64_t writerEnd=mvkSyncDiagnosticTime(d.session);
    mvkForensicsRecordForSession(d.session,"NativeWaitRegistrationPublished",{
        {"diagnosticSchema",2},{"waitRegistrationID",d.registrationID},{"intentWriterStartMachNS",writerStart},
        {"intentWriterEndMachNS",writerEnd},{"intentWriterWallNS",writerEnd-writerStart},
        {"intentFileFlushSucceeded",flushed},{"writerAdmissionKnown",0}});
}


#pragma mark -
#pragma mark MVKSemaphoreImpl

bool MVKSemaphoreImpl::release() {
	lock_guard<mutex> lock(_lock);
    if (isClear()) { return true; }

    // Either decrement the reservation counter, or clear it altogether
    if (_shouldWaitAll) {
		if (_reservationCount > 0) { _reservationCount--; }
    } else {
        _reservationCount = 0;
    }
    // If all reservations have been released, unblock all waiting threads
    if ( isClear() ) { _blocker.notify_all(); }
    return isClear();
}

void MVKSemaphoreImpl::reserve() {
	lock_guard<mutex> lock(_lock);
	_reservationCount++;
}

bool MVKSemaphoreImpl::isReserved() {
	lock_guard<mutex> lock(_lock);
	return !isClear();
}

uint32_t MVKSemaphoreImpl::getReservationCount() {
	lock_guard<mutex> lock(_lock);
	return _reservationCount;
}

bool MVKSemaphoreImpl::wait(uint64_t timeout, bool reserveAgain) {
    unique_lock<mutex> lock(_lock);

    bool isDone;
    if (timeout == 0) {
		isDone = isClear();
	} else if (timeout == UINT64_MAX) {
		_blocker.wait(lock, [this]{ return isClear(); });
		isDone = true;
	} else {
        // Limit timeout to avoid overflow since wait_for() uses wait_until()
        uint64_t nanoTimeout = min(timeout, kMVKUndefinedLargeUInt64);
        chrono::nanoseconds nanos(nanoTimeout);
        isDone = _blocker.wait_for(lock, nanos, [this]{ return isClear(); });
    }

	if (reserveAgain) { _reservationCount++; }
    return isDone;
}

MVKSemaphoreImpl::~MVKSemaphoreImpl() {
    // Acquire the lock to ensure proper ordering.
    lock_guard<mutex> lock(_lock);
}


#pragma mark -
#pragma mark MVKSemaphoreSingleQueue

void MVKSemaphoreSingleQueue::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
	// Metal will handle all synchronization for us automatically
}

void MVKSemaphoreSingleQueue::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
	// Metal will handle all synchronization for us automatically
}

uint64_t MVKSemaphoreSingleQueue::deferSignal() {
	return 0;
}

void MVKSemaphoreSingleQueue::encodeDeferredSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
	encodeSignal(mtlCmdBuff, 0);
}

MVKSemaphoreSingleQueue::MVKSemaphoreSingleQueue(MVKDevice* device,
                                                 const VkSemaphoreCreateInfo* pCreateInfo,
                                                 const VkExportMetalObjectCreateInfoEXT* pExportInfo,
                                                 const VkImportMetalSharedEventInfoEXT* pImportInfo) : MVKSemaphore(device, pCreateInfo) {
	if ((pImportInfo && pImportInfo->mtlSharedEvent) || (pExportInfo && pExportInfo->exportObjectType == VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT)) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkCreateEvent(): MTLSharedEvent is not available with VkSemaphores that use implicit synchronization."));
	}
}

MVKSemaphoreSingleQueue::~MVKSemaphoreSingleQueue() = default;


#pragma mark -
#pragma mark MVKSemaphoreMTLEvent

void MVKSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
	if (mtlCmdBuff) {
		uint64_t value = _mtlEventValue++;
        if(mvkForensicsArmed())mvkForensicsRecord("NativeSemaphoreEdge",{{"semaphore",uint64_t(uintptr_t(this))},{"event",uint64_t(uintptr_t(_mtlEvent))},
            {"nativeCB",mvkStutterNativeID(mtlCmdBuff)},{"value",value},{"signal",0},{"timeline",0}});
		mvkRecordEventDependency(mtlCmdBuff, _mtlEvent, value, @"wait", @"binary");
		[mtlCmdBuff encodeWaitForEvent: _mtlEvent value: value];
	}
}

void MVKSemaphoreMTLEvent::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
	if (mtlCmdBuff) {
		uint64_t value = _mtlEventValue;
        if(mvkForensicsArmed())mvkForensicsRecord("NativeSemaphoreEdge",{{"semaphore",uint64_t(uintptr_t(this))},{"event",uint64_t(uintptr_t(_mtlEvent))},
            {"nativeCB",mvkStutterNativeID(mtlCmdBuff)},{"value",value},{"signal",1},{"timeline",0}});
		mvkRecordEventDependency(mtlCmdBuff, _mtlEvent, value, @"signal", @"binary");
		[mtlCmdBuff encodeSignalEvent: _mtlEvent value: value];
	}
}

uint64_t MVKSemaphoreMTLEvent::deferSignal() {
	return _mtlEventValue;
}

void MVKSemaphoreMTLEvent::encodeDeferredSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t deferToken) {
	mvkRecordEventDependency(mtlCmdBuff, _mtlEvent, deferToken, @"signal", @"binary-deferred");
	[mtlCmdBuff encodeSignalEvent: _mtlEvent value: deferToken];
}

VkResult MVKSemaphoreMTLEvent::importFd(VkSemaphoreImportFlags flags, VkExternalSemaphoreHandleTypeFlagBits handleType, int fd) {
	if (handleType != VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT || fd != -1) {
		return reportError(VK_ERROR_INVALID_EXTERNAL_HANDLE, "importFd(): Only VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT with fd == -1 is supported.");
	}
	/**
	* If handleType is `VK_EXTERNAL_FENCE_HANDLE_TYPE_SYNC_FD_BIT`, the special
	* value -1 for fd is treated like a valid sync file descriptor referring to an object that has already
	* signaled. The import operation will succeed and the VkFence will have a temporarily
	* imported payload as if a valid file descriptor had been provided.
	*/
	/**
	* If handleType is `VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT`, the special
	* value -1 for fd is treated like a valid sync file descriptor referring to an object that has already
	* signaled. The import operation will succeed and the VkSemaphore will have a temporarily
	* imported payload as if a valid file descriptor had been provided.
	*/
	uint64_t value = _mtlEventValue.load();
	auto diagnostic=mvkSyncWaitDiagnostic(this,(__bridge const void*)_mtlEvent,value);
	auto intent=mvkSyncHostSignalIntent(diagnostic,2);
	uint64_t signalStart=mvkSyncDiagnosticTime(diagnostic.session);
	[(id<MTLSharedEvent>)_mtlEvent setSignaledValue:value];
	uint64_t signalEnd=mvkSyncDiagnosticTime(diagnostic.session);
	mvkSyncRecordHostSignal(diagnostic,intent,signalStart,signalEnd,2); // imported signaled sync-fd (-1)
	return VK_SUCCESS;
}

VkResult MVKSemaphoreMTLEvent::exportFd(VkExternalSemaphoreHandleTypeFlagBits handleType, int *pFd) {
	if (handleType != VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT) {
		return reportError(VK_ERROR_INVALID_EXTERNAL_HANDLE, "exportFd(): Only VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT is supported.");
	}
	/**
	* `VUID-VkSemaphoreGetFdInfoKHR-handleType-03254`
	* If handleType refers to a handle type with copy payload transference semantics, semaphore
	* must have an associated semaphore signal operation that has been submitted for execution
	* and any semaphore signal operations on which it depends must have also been submitted
	* for execution
	*/
	/**
	* ... exporting a semaphore payload to a handle with copy transference has the same side
	* effects on the source semaphore’s payload as executing a semaphore wait operation.
	*/
	uint64_t value = _mtlEventValue.load();
	[(id<MTLSharedEvent>)_mtlEvent waitUntilSignaledValue:value timeoutMS:kMVKUndefinedLargeUInt64];
	*pFd = -1;
	return VK_SUCCESS;
}

MVKSemaphoreMTLEvent::MVKSemaphoreMTLEvent(MVKDevice* device,
										   const VkSemaphoreCreateInfo* pCreateInfo,
										   const VkExportMetalObjectCreateInfoEXT* pExportInfo,
										   const VkImportMetalSharedEventInfoEXT* pImportInfo) : MVKSemaphore(device, pCreateInfo) {
	// In order of preference, import a MTLSharedEvent,
	// create a MTLSharedEvent, or create a MTLEvent.
	if (pImportInfo && pImportInfo->mtlSharedEvent) {
		_mtlEvent = [pImportInfo->mtlSharedEvent retain];		// retained
		_mtlEventValue = pImportInfo->mtlSharedEvent.signaledValue + 1;
	} else if (pExportInfo && pExportInfo->exportObjectType == VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT) {
		_mtlEvent = [getMTLDevice() newSharedEvent];	//retained
		_mtlEventValue = ((id<MTLSharedEvent>)_mtlEvent).signaledValue + 1;
	} else {
		// We might use importFd()/exportFd() so we need a MTLSharedEvent
		// At creation, we might know about potential exports when
		// `VkExportSemaphoreCreateInfo` is present but we have no idea
		// if imports might happen.
		_mtlEvent = [getMTLDevice() newSharedEvent];			//retained
		_mtlEventValue = 1;
	}
}

MVKSemaphoreMTLEvent::~MVKSemaphoreMTLEvent() {
    [_mtlEvent release];
}


#pragma mark -
#pragma mark MVKSemaphoreEmulated

void MVKSemaphoreEmulated::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
    MVKForensicsScope forensics("NativeSemaphoreEmulatedWait",{{"semaphore",uint64_t(uintptr_t(this))},{"hostWait",uint64_t(!mtlCmdBuff)}});
	if ( !mtlCmdBuff ) {
		_device->addSemaphore(&_blocker);
		_blocker.wait(UINT64_MAX, true);
		_device->removeSemaphore(&_blocker);
	}
}

void MVKSemaphoreEmulated::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
	if ( !mtlCmdBuff ) { _blocker.release(); }
}

uint64_t MVKSemaphoreEmulated::deferSignal() {
	return 0;
}

void MVKSemaphoreEmulated::encodeDeferredSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {
	encodeSignal(mtlCmdBuff, 0);
}

MVKSemaphoreEmulated::MVKSemaphoreEmulated(MVKDevice* device,
										   const VkSemaphoreCreateInfo* pCreateInfo,
										   const VkExportMetalObjectCreateInfoEXT* pExportInfo,
										   const VkImportMetalSharedEventInfoEXT* pImportInfo) :
	MVKSemaphore(device, pCreateInfo),
	_blocker(false, 1) {

	if ((pImportInfo && pImportInfo->mtlSharedEvent) || (pExportInfo && pExportInfo->exportObjectType == VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT)) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkCreateEvent(): MTLSharedEvent is not available with VkSemaphores that use CPU emulation."));
	}
}


#pragma mark -
#pragma mark MVKTimelineSemaphoreMTLEvent

// Nil mtlCmdBuff will do nothing.
void MVKTimelineSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {
    if(mvkForensicsArmed())mvkForensicsRecord("NativeSemaphoreEdge",{{"semaphore",uint64_t(uintptr_t(this))},{"event",uint64_t(uintptr_t(_mtlEvent))},
        {"nativeCB",mvkStutterNativeID(mtlCmdBuff)},{"value",value},{"signal",0},{"timeline",1}});
	mvkRecordEventDependency(mtlCmdBuff, _mtlEvent, value, @"wait", @"timeline");
	[mtlCmdBuff encodeWaitForEvent: _mtlEvent value: value];
}

// Nil mtlCmdBuff will do nothing.
void MVKTimelineSemaphoreMTLEvent::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {
    if(mvkForensicsArmed())mvkForensicsRecord("NativeSemaphoreEdge",{{"semaphore",uint64_t(uintptr_t(this))},{"event",uint64_t(uintptr_t(_mtlEvent))},
        {"nativeCB",mvkStutterNativeID(mtlCmdBuff)},{"value",value},{"signal",1},{"timeline",1}});
	mvkRecordEventDependency(mtlCmdBuff, _mtlEvent, value, @"signal", @"timeline");
	[mtlCmdBuff encodeSignalEvent: _mtlEvent value: value];
}

void MVKTimelineSemaphoreMTLEvent::signal(const VkSemaphoreSignalInfo* pSignalInfo) {
	auto diagnostic=mvkSyncWaitDiagnostic(this,(__bridge const void*)_mtlEvent,pSignalInfo->value);
	auto intent=mvkSyncHostSignalIntent(diagnostic,1);
	uint64_t signalStart=mvkSyncDiagnosticTime(diagnostic.session);
	_mtlEvent.signaledValue = pSignalInfo->value;
	uint64_t signalEnd=mvkSyncDiagnosticTime(diagnostic.session);
	mvkSyncRecordHostSignal(diagnostic,intent,signalStart,signalEnd,1); // Vulkan host timeline signal
}

bool MVKTimelineSemaphoreMTLEvent::registerWait(MVKFenceSitter* sitter, const VkSemaphoreWaitInfo* pWaitInfo, uint32_t index) {
	auto diagnostic=mvkSyncWaitDiagnostic(this,(__bridge const void*)_mtlEvent,pWaitInfo->pValues[index]);
	uint64_t registrationStart=mvkSyncDiagnosticTime(diagnostic.session);
	uint64_t observedValue=_mtlEvent.signaledValue; // original single read, also retained as evidence
	if (observedValue >= pWaitInfo->pValues[index]) {
		mvkSyncPublishWaitRegistration(diagnostic,observedValue,registrationStart,1,false);
		return true;
	}
	bool listenerInstalled=false;
	{
		lock_guard<mutex> lock(_lock);
		sitter->await();
		auto addRslt = _sitters.insert(sitter);
		if (addRslt.second) {
			listenerInstalled=true;
			retain();
			_device->addSemaphore(&sitter->_blocker);
			[_mtlEvent notifyListener: sitter->getMTLSharedEventListener()
							  atValue: pWaitInfo->pValues[index]
								block: ^(id<MTLSharedEvent> notifiedEvent, uint64_t notifiedValue) {
				uint64_t callbackEntry=mvkSyncDiagnosticTime(diagnostic.session),releaseBefore=0,releaseAfter=0;
				uint64_t entryWriterStart=0,entryWriterEnd=0;bool entryFlushed=false;
				if(diagnostic.session){
					entryWriterStart=mvkSyncDiagnosticTime(diagnostic.session);
					mvkForensicsRecordForSession(diagnostic.session,"NativeWaitNotifyEntry",{
						{"diagnosticSchema",2},{"waitRegistrationID",diagnostic.registrationID},{"event",diagnostic.event},
						{"callbackEvent",uint64_t(uintptr_t((__bridge const void*)notifiedEvent))},{"requestedValue",diagnostic.requested},
						{"observedValue",notifiedValue},{"callbackEntryMachNS",callbackEntry},{"waiterThreadMachID",diagnostic.waiterThread},
						{"waiterSubmission",diagnostic.owner.submission},{"unfinishedUntilMatchingEnd",1}});
					entryFlushed=mvkForensicsFlushIntent(diagnostic.session);entryWriterEnd=mvkSyncDiagnosticTime(diagnostic.session);
				}
				bool sitterSignaled=false;
				{
					lock_guard<mutex> blockLock(_lock);
					if (_sitters.count(sitter)) {
						releaseBefore=mvkSyncDiagnosticTime(diagnostic.session);
						sitter->signaled();
						releaseAfter=mvkSyncDiagnosticTime(diagnostic.session);sitterSignaled=true;
					}
					release();
				}
				// Emit outside the original lock. The passed callback value is raw;
				// no extra event query or listener is introduced. A sitter signal
				// requests release; it does not prove the waiter has returned.
				if(diagnostic.session)mvkForensicsRecordForSession(diagnostic.session,"NativeWaitNotify",{
					{"diagnosticSchema",2},{"waitRegistrationID",diagnostic.registrationID},{"semaphore",diagnostic.semaphore},
					{"event",diagnostic.event},{"callbackEvent",uint64_t(uintptr_t((__bridge const void*)notifiedEvent))},
					{"requestedValue",diagnostic.requested},{"observedValue",notifiedValue},{"callbackEntryMachNS",callbackEntry},
					{"releaseBeforeMachNS",releaseBefore},{"releaseAfterMachNS",releaseAfter},
					{"entryWriterWallNS",entryWriterEnd-entryWriterStart},{"entryFileFlushSucceeded",entryFlushed},{"writerAdmissionKnown",0},
					{"releaseReason",sitterSignaled?1u:2u},{"sitterSignaled",sitterSignaled},
					{"signalOriginKnown",0},{"waiterThreadMachID",diagnostic.waiterThread},
					{"waiterSubmission",diagnostic.owner.submission},{"waiterNativeCB",diagnostic.owner.nativeCB},
					{"waiterQueueFamily",diagnostic.owner.queueFamily},{"waiterQueueIndex",diagnostic.owner.queueIndex}});
			}];
		}
	}
	mvkSyncPublishWaitRegistration(diagnostic,observedValue,registrationStart,listenerInstalled?2u:3u,listenerInstalled);
	return false;
}

void MVKTimelineSemaphoreMTLEvent::unregisterWait(MVKFenceSitter* sitter) {
	lock_guard<mutex> lock(_lock);
	_device->removeSemaphore(&sitter->_blocker);
	_sitters.erase(sitter);
}

MVKTimelineSemaphoreMTLEvent::MVKTimelineSemaphoreMTLEvent(MVKDevice* device,
														   const VkSemaphoreCreateInfo* pCreateInfo,
														   const VkSemaphoreTypeCreateInfo* pTypeCreateInfo,
														   const VkExportMetalObjectCreateInfoEXT* pExportInfo,
														   const VkImportMetalSharedEventInfoEXT* pImportInfo) : MVKTimelineSemaphore(device, pCreateInfo) {

	// Import or create a Metal event
	_mtlEvent = (pImportInfo && pImportInfo->mtlSharedEvent
				 ? [pImportInfo->mtlSharedEvent retain]
				 : [getMTLDevice() newSharedEvent]);	//retained

	if (pTypeCreateInfo) {
		_mtlEvent.signaledValue = pTypeCreateInfo->initialValue;
	}
}

MVKTimelineSemaphoreMTLEvent::~MVKTimelineSemaphoreMTLEvent() {
    [_mtlEvent release];
}


#pragma mark -
#pragma mark MVKFence

void MVKFence::addSitter(MVKFenceSitter* fenceSitter) {
	lock_guard<mutex> lock(_lock);

	// We only care about unsignaled fences. If already signaled,
	// don't add myself to the sitter and don't signal the sitter.
	if (_isSignaled) { return; }

	// Ensure each fence only added once to each fence sitter
	auto addRslt = _fenceSitters.insert(fenceSitter);	// pair with second element true if was added
	if (addRslt.second) {
		_device->addSemaphore(&fenceSitter->_blocker);
		fenceSitter->await();
	}
}

void MVKFence::removeSitter(MVKFenceSitter* fenceSitter) {
	lock_guard<mutex> lock(_lock);

	_device->removeSemaphore(&fenceSitter->_blocker);
	_fenceSitters.erase(fenceSitter);
}

void MVKFence::signal() {
	lock_guard<mutex> lock(_lock);

	if (_isSignaled) { return; }	// Only signal once
	_isSignaled = true;

	// Notify all the fence sitters, and clear them from this instance.
    for (auto& fs : _fenceSitters) {
        fs->signaled();
    }
	_fenceSitters.clear();
}

void MVKFence::reset() {
	lock_guard<mutex> lock(_lock);

	_isSignaled = false;
	_fenceSitters.clear();
}

bool MVKFence::getIsSignaled() {
	lock_guard<mutex> lock(_lock);

	return _isSignaled;
}


#pragma mark -
#pragma mark MVKFenceSitter

MTLSharedEventListener* MVKFenceSitter::getMTLSharedEventListener() {
	// TODO: Use dispatch queue from device?
	if (!_listener) { _listener = [MTLSharedEventListener new]; }
	return _listener;
}


#pragma mark -
#pragma mark MVKEventNative

// Odd == set / Even == reset.
bool MVKEventNative::isSet() { return _mtlEvent.signaledValue & 1; }

void MVKEventNative::signal(bool status) {
	if (isSet() != status) {
		_mtlEvent.signaledValue += 1;
	}
}

void MVKEventNative::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, bool status) {
	if (isSet() != status) {
		uint64_t value = _mtlEvent.signaledValue + 1;
        mvkRecordEventDependency(mtlCmdBuff, _mtlEvent, value, @"signal", status ? @"vk-event-set" : @"vk-event-reset");
		[mtlCmdBuff encodeSignalEvent: _mtlEvent value: value];
	}
}

void MVKEventNative::encodeWait(id<MTLCommandBuffer> mtlCmdBuff) {
	if ( !isSet() ) {
		uint64_t value = _mtlEvent.signaledValue + 1;
        mvkRecordEventDependency(mtlCmdBuff, _mtlEvent, value, @"wait", @"vk-event");
		[mtlCmdBuff encodeWaitForEvent: _mtlEvent value: value];
	}
}

MVKEventNative::MVKEventNative(MVKDevice* device,
							   const VkEventCreateInfo* pCreateInfo,
							   const VkExportMetalObjectCreateInfoEXT* pExportInfo,
							   const VkImportMetalSharedEventInfoEXT* pImportInfo) :
	MVKEvent(device, pCreateInfo, pExportInfo, pImportInfo) {

	// Import or create a Metal event
	_mtlEvent = (pImportInfo
				 ? [pImportInfo->mtlSharedEvent retain]
				 : [getMTLDevice() newSharedEvent]);	//retained
}

MVKEventNative::~MVKEventNative() {
	[_mtlEvent release];
}


#pragma mark -
#pragma mark Support functions

VkResult mvkResetFences(uint32_t fenceCount, const VkFence* pFences) {
	for (uint32_t i = 0; i < fenceCount; i++) {
		((MVKFence*)pFences[i])->reset();
	}
	return VK_SUCCESS;
}

// Create a blocking fence sitter, add it to each fence, wait, then remove it.
VkResult mvkWaitForFences(MVKDevice* device,
						  uint32_t fenceCount,
						  const VkFence* pFences,
						  VkBool32 waitAll,
						  uint64_t timeout) {

	if (device->getConfigurationResult() != VK_SUCCESS) {
		return device->getConfigurationResult();
	}

	VkResult rslt = VK_SUCCESS;
	MVKFenceSitter fenceSitter(waitAll);

	for (uint32_t i = 0; i < fenceCount; i++) {
		((MVKFence*)pFences[i])->addSitter(&fenceSitter);
	}

	bool finished = fenceSitter.wait(timeout);
	if (device->getConfigurationResult() != VK_SUCCESS) {
		rslt = device->getConfigurationResult();
	} else if ( !finished ) {
		rslt = VK_TIMEOUT;
	}

	for (uint32_t i = 0; i < fenceCount; i++) {
		((MVKFence*)pFences[i])->removeSitter(&fenceSitter);
	}

	return rslt;
}

// Create a blocking fence sitter, add it to each semaphore, wait, then remove it.
VkResult mvkWaitSemaphores(MVKDevice* device,
						   const VkSemaphoreWaitInfo* pWaitInfo,
						   uint64_t timeout) {

	if (device->getConfigurationResult() != VK_SUCCESS) {
		return device->getConfigurationResult();
	}

	VkResult rslt = VK_SUCCESS;
	bool waitAny = mvkIsAnyFlagEnabled(pWaitInfo->flags, VK_SEMAPHORE_WAIT_ANY_BIT);
	bool alreadySignaled = false;
	MVKFenceSitter fenceSitter(!waitAny);

	for (uint32_t i = 0; i < pWaitInfo->semaphoreCount; i++) {
		if (((MVKTimelineSemaphore*)pWaitInfo->pSemaphores[i])->registerWait(&fenceSitter, pWaitInfo, i) && waitAny) {
			// In this case, we don't need to wait.
			alreadySignaled = true;
			break;
		}
	}

	bool finished = alreadySignaled || fenceSitter.wait(timeout);
	if (device->getConfigurationResult() != VK_SUCCESS) {
		rslt = device->getConfigurationResult();
	} else if ( !finished ) {
		rslt = VK_TIMEOUT;
	}

	for (uint32_t i = 0; i < pWaitInfo->semaphoreCount; i++) {
		((MVKTimelineSemaphore*)pWaitInfo->pSemaphores[i])->unregisterWait(&fenceSitter);
	}

	return rslt;
}


#pragma mark -
#pragma mark MVKMetalCompiler

// Create a compiled object by dispatching the block to the default global dispatch queue, and waiting only as long
// as the MVKConfiguration::metalCompileTimeout value. If the timeout is triggered, a Vulkan error is created.
// This approach is used to limit the lengthy time (30+ seconds!) consumed by Metal when it's internal compiler fails.
// The thread dispatch is needed because even the sync portion of the async Metal compilation methods can take well
// over a second to return when a compiler failure occurs!
void MVKMetalCompiler::compile(unique_lock<mutex>& lock, dispatch_block_t block) {
	MVKAssert( _startTime == 0, "%s compile occurred already in this instance. Instances of %s should only be used for a single compile activity.", _compilerType.c_str(), getClassName().c_str());

	_startTime = getPerformanceTimestamp();

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ @autoreleasepool { block(); } });

	// Limit timeout to avoid overflow since wait_for() uses wait_until()
	chrono::nanoseconds nanoTimeout(min(getMVKConfig().metalCompileTimeout, kMVKUndefinedLargeUInt64));
	_blocker.wait_for(lock, nanoTimeout, [this]{ return _isCompileDone; });

	if ( !_isCompileDone ) {
		@autoreleasepool {
			NSString* errDesc = [NSString stringWithFormat: @"Timeout after %.3f milliseconds. Likely internal Metal compiler error", (double)nanoTimeout.count() / 1e6];
			_compileError = [[NSError alloc] initWithDomain: @(kMVKMoltenVKDriverLayerName) code: 1 userInfo: @{NSLocalizedDescriptionKey : errDesc}];	// retained
		}
	}

	if (_compileError) { handleError(); }

	addPerformanceInterval(*_pPerformanceTracker, _startTime);
}

void MVKMetalCompiler::handleError() {
	MVKInstance* instance = _owner->getInstance();
	if (instance && instance->getEngine() == MVKInstance::EngineID::Angle) {
		MVKLogWarn("%s compile failed but Angle is special so we'll pretend everything is happy: %s",
		           _compilerType.c_str(), _compileError.localizedDescription.UTF8String);
		return;
	}
	_owner->setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED,
											   "%s compile failed (Error code %li):\n%s.",
											   _compilerType.c_str(), (long)_compileError.code,
											   _compileError.localizedDescription.UTF8String));
}

// Returns whether the compilation came in late, after the compiler was destroyed.
bool MVKMetalCompiler::endCompile(NSError* compileError) {
	_compileError = [compileError retain];		// retained
	_isCompileDone = true;
	_blocker.notify_all();
	return _isDestroyed;
}

void MVKMetalCompiler::destroy() {
	if (markDestroyed()) { MVKBaseObject::destroy(); }
}

// Marks this object as destroyed, and returns whether the compilation is complete.
bool MVKMetalCompiler::markDestroyed() {
	lock_guard<mutex> lock(_completionLock);

	_isDestroyed = true;
	return _isCompileDone;
}


#pragma mark Construction

MVKMetalCompiler::~MVKMetalCompiler() {
	[_compileError release];
}

#pragma mark -
#pragma mark MVKDeferredOperation

// Call appropriate function from MVKDeferredOperationFunctionPointer with parameters.
// While executing, the function can call setOperationResult() and setMaxConcurrency()
// to update status of the operation, and should return a VkResult that is returned here.
VkResult MVKDeferredOperation::join() {
	switch(_functionType) {
		// .....
        default: return VK_SUCCESS;
    };
}

void MVKDeferredOperation::deferOperation(const MVKDeferredOperationFunctionPointer& pointer,
										  MVKDeferredOperationFunctionType type,
										  void** parameters,
										  uint32_t paramCount) {
    _functionPointer = pointer;
    _functionType = type;

	_functionParameters.reserve(paramCount);
	for(int i = 0; i < paramCount; i++) {
        _functionParameters.push_back(parameters[i]);
    }

	updateResults(VK_SUCCESS, mvkGetAvaliableCPUCores());
}

VkResult MVKDeferredOperation::getOperationResult() {
	lock_guard<mutex> lock(_lock);
	return _operationResult;
}

void MVKDeferredOperation::setOperationResult(VkResult opResult) {
	lock_guard<mutex> lock(_lock);
	_operationResult = opResult;
}

uint32_t MVKDeferredOperation::getMaxConcurrency() {
	lock_guard<mutex> lock(_lock);
	return _maxConcurrency;
}

void MVKDeferredOperation::setMaxConcurrency(uint32_t maxConCurr) {
	lock_guard<mutex> lock(_lock);
	_maxConcurrency = maxConCurr;
}

void MVKDeferredOperation::updateResults(VkResult opResult, uint32_t maxConCurr) {
	lock_guard<mutex> lock(_lock);
	_operationResult = opResult;
	_maxConcurrency = maxConCurr;
}

