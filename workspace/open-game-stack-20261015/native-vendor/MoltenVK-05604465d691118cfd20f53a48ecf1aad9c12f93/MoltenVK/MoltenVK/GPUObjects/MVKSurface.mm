/*
 * MVKSurface.mm
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

#include "MVKSurface.h"
#include "MVKForensicsTrace.h"
#include "MVKSwapchain.h"
#include "MVKInstance.h"
#include "MVKFoundation.h"
#include "MVKOSExtensions.h"
#include "mvk_datatypes.hpp"

#import "CAMetalLayer+MoltenVK.h"
#import "MVKBlockObserver.h"

#ifdef VK_USE_PLATFORM_IOS_MVK
#	define PLATFORM_VIEW_CLASS	UIView
#	import <UIKit/UIView.h>
#endif

#ifdef VK_USE_PLATFORM_MACOS_MVK
#	define PLATFORM_VIEW_CLASS	NSView
#	import <AppKit/NSView.h>
#endif


// We need to double-dereference the name to first convert to the platform symbol, then to a string.
#define STR_PLATFORM(NAME) #NAME
#define STR(NAME) STR_PLATFORM(NAME)

// As defined in the Vulkan spec, represents an undefined extent.
// Spec is currently somewhat ambiguous about whether an undefined surface extent should be updated
// once a swapchain is attached, but consensus amoung the spec authors is that it should not.
static constexpr VkExtent2D kMVKUndefinedExtent = {0xFFFFFFFF, 0xFFFFFFFF};


#pragma mark MVKSurface

uint64_t MVKSurface::nextDiagnosticGeneration() {
	static std::atomic<uint64_t> next{1};
	return next.fetch_add(1, std::memory_order_relaxed);
}

CAMetalLayer* MVKSurface::getCAMetalLayer(MVKSurfaceDiagnosticInfo* diagnostics) {
	uint64_t session = mvkForensicsSessionID();
	uint64_t requested = session ? mvkStutterMonotonicNS() : 0, acquired = 0;
	CAMetalLayer* layer;
	uint64_t layerBindingGeneration;
	{
		std::lock_guard<std::mutex> lock(_layerLock);
		if (session) { acquired = mvkStutterMonotonicNS(); }
		layer = _mtlCAMetalLayer;
		layerBindingGeneration = _diagnosticLayerBindingGeneration;
		if (diagnostics) {
			diagnostics->surfaceGeneration = _diagnosticGeneration;
			diagnostics->layerBindingGeneration = layerBindingGeneration;
		}
	}
	if (session) { mvkForensicsRecordForSession(session, "NativeSurfaceLayerGet", {
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"layer", uint64_t(uintptr_t(layer))}, {"layerBindingGeneration", layerBindingGeneration},
		{"externalLayerBirthKnown", 0}, {"lockRequestedMachNS", requested},
		{"lockAcquiredMachNS", acquired}, {"lockReleasedMachNS", mvkStutterMonotonicNS()}}); }
	return layer;
}

VkExtent2D MVKSurface::getExtent() {
	return _mtlCAMetalLayer ? mvkVkExtent2DFromCGSize(_mtlCAMetalLayer.drawableSize) : kMVKUndefinedExtent;
}

VkExtent2D MVKSurface::getNaturalExtent() {
	return _mtlCAMetalLayer ? mvkVkExtent2DFromCGSize(_mtlCAMetalLayer.naturalDrawableSizeMVK) : kMVKUndefinedExtent;
}

void MVKSurface::setActiveSwapchain(MVKSwapchain* swapchain) {
	_activeSwapchain = swapchain;
}

MVKSurface::MVKSurface(MVKInstance* mvkInstance,
					   const VkMetalSurfaceCreateInfoEXT* pCreateInfo,
					   const VkAllocationCallbacks* pAllocator) : _mvkInstance(mvkInstance) {
	mvkForensicsRecord("NativeSurfaceConstruct", {{"phase", 0}, {"constructorKind", 1},
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration}});
	initLayer((CAMetalLayer*)pCreateInfo->pLayer, "vkCreateMetalSurfaceEXT", false);
	mvkForensicsRecord("NativeSurfaceConstruct", {{"phase", 1}, {"constructorKind", 1},
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"configurationResultBits", uint64_t(int64_t(getConfigurationResult()))}});
}

MVKSurface::MVKSurface(MVKInstance* mvkInstance,
					   const VkHeadlessSurfaceCreateInfoEXT* pCreateInfo,
					   const VkAllocationCallbacks* pAllocator) : _mvkInstance(mvkInstance) {
	mvkForensicsRecord("NativeSurfaceConstruct", {{"phase", 0}, {"constructorKind", 2},
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration}});
	initLayer(nil, "vkCreateHeadlessSurfaceEXT", true);
	mvkForensicsRecord("NativeSurfaceConstruct", {{"phase", 1}, {"constructorKind", 2},
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"configurationResultBits", uint64_t(int64_t(getConfigurationResult()))}});
}

// pCreateInfo->pView can be either a CAMetalLayer or a view (NSView/UIView).
MVKSurface::MVKSurface(MVKInstance* mvkInstance,
					   const Vk_PLATFORM_SurfaceCreateInfoMVK* pCreateInfo,
					   const VkAllocationCallbacks* pAllocator) : _mvkInstance(mvkInstance) {
	mvkForensicsRecord("NativeSurfaceConstruct", {{"phase", 0}, {"constructorKind", 3},
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration}});
	MVKLogWarn("%s() is deprecated. Use vkCreateMetalSurfaceEXT() from the VK_EXT_metal_surface extension.", STR(vkCreate_PLATFORM_SurfaceMVK));

	// Get the platform object contained in pView
	// If it's a view (NSView/UIView), extract the layer, otherwise assume it's already a CAMetalLayer.
	id<NSObject> obj = (id<NSObject>)pCreateInfo->pView;
	if ([obj isKindOfClass: [PLATFORM_VIEW_CLASS class]]) {
		__block id<NSObject> layer;
		mvkDispatchToMainAndWait(^{ layer = ((PLATFORM_VIEW_CLASS*)obj).layer; });
		obj = layer;
	}

	// Confirm that we were provided with a CAMetalLayer
	initLayer([obj isKindOfClass: CAMetalLayer.class] ? (CAMetalLayer*)obj : nil, STR(vkCreate_PLATFORM_SurfaceMVK), false);
	mvkForensicsRecord("NativeSurfaceConstruct", {{"phase", 1}, {"constructorKind", 3},
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"configurationResultBits", uint64_t(int64_t(getConfigurationResult()))}});
}

void MVKSurface::initLayer(CAMetalLayer* mtlLayer, const char* vkFuncName, bool isHeadless) {

	uint64_t session = mvkForensicsSessionID();
	if (session) { mvkForensicsRecordForSession(session, "NativeSurfaceLayerBind", {
		{"phase", 0}, {"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"layer", uint64_t(uintptr_t(mtlLayer))}, {"externalLayerBirthKnown", 0}, {"headless", uint64_t(isHeadless)}}); }
	uint64_t retainStart = session ? mvkStutterMonotonicNS() : 0;
	_mtlCAMetalLayer = [mtlLayer retain];	// retained
	uint64_t retainEnd = session ? mvkStutterMonotonicNS() : 0;
	if (_mtlCAMetalLayer) { _diagnosticLayerBindingGeneration = nextDiagnosticGeneration(); }
	if (session) { mvkForensicsRecordForSession(session, "NativeSurfaceLayerBind", {
		{"phase", 1}, {"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"layer", uint64_t(uintptr_t(_mtlCAMetalLayer))}, {"layerBindingGeneration", _diagnosticLayerBindingGeneration},
		{"externalLayerBirthKnown", 0}, {"headless", uint64_t(isHeadless)},
		{"retainStartMachNS", retainStart}, {"retainEndMachNS", retainEnd}}); }
	if ( !_mtlCAMetalLayer && !isHeadless ) { setConfigurationResult(reportError(VK_ERROR_SURFACE_LOST_KHR, "%s(): On-screen rendering requires a layer of type CAMetalLayer.", vkFuncName)); }

	// Sometimes, the owning view can replace its CAMetalLayer.
	// When that happens, the app needs to recreate the surface.
	if ([_mtlCAMetalLayer.delegate isKindOfClass: [PLATFORM_VIEW_CLASS class]]) {
		_layerObserver = [MVKBlockObserver observerWithBlock: ^(NSString* path, id observedObject, NSDictionary*, void*) {
			if ([path isEqualToString: @"layer"]) {
				mvkForensicsRecord("NativeSurfaceLayerKVO", {{"surface", uint64_t(uintptr_t(this))},
					{"surfaceGeneration", _diagnosticGeneration}, {"externalLayerBirthKnown", 0},
					{"observedObject", uint64_t(uintptr_t(observedObject))}, {"replacementLayerKnown", 0}});
				this->releaseLayer(1);
			}
		} forObject: _mtlCAMetalLayer.delegate atKeyPath: @"layer"];
	}
}

void MVKSurface::releaseLayer(uint64_t reason) {
	uint64_t session = mvkForensicsSessionID();
	uint64_t requested = 0, acquired = 0;
	uint64_t layer = 0, layerBindingGeneration = 0, releaseStart = 0, releaseEnd = 0;
	if (session) { mvkForensicsRecordForSession(session, "NativeSurfaceLayerReleaseIntent", {
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"reason", reason}, {"intentMachNS", mvkStutterMonotonicNS()}}); }
	requested = session ? mvkStutterMonotonicNS() : 0;
	{
		std::lock_guard<std::mutex> lock(_layerLock);
		if (session) {
			acquired = mvkStutterMonotonicNS();
			layer = uint64_t(uintptr_t(_mtlCAMetalLayer));
			layerBindingGeneration = _diagnosticLayerBindingGeneration;
		}
		setConfigurationResult(VK_ERROR_SURFACE_LOST_KHR);
		if (session) { releaseStart = mvkStutterMonotonicNS(); }
		[_mtlCAMetalLayer release];
		if (session) { releaseEnd = mvkStutterMonotonicNS(); }
		_mtlCAMetalLayer = nil;
		_diagnosticLayerBindingGeneration = 0;
		[_layerObserver release];
		_layerObserver = nil;
	}
	if (session) { mvkForensicsRecordForSession(session, "NativeSurfaceLayerReleased", {
		{"surface", uint64_t(uintptr_t(this))}, {"surfaceGeneration", _diagnosticGeneration},
		{"layer", layer}, {"layerBindingGeneration", layerBindingGeneration}, {"externalLayerBirthKnown", 0},
		{"reason", reason}, {"lockRequestedMachNS", requested}, {"lockAcquiredMachNS", acquired},
		{"releaseStartMachNS", releaseStart}, {"releaseEndMachNS", releaseEnd},
		{"lockReleasedMachNS", mvkStutterMonotonicNS()}}); }
}

MVKSurface::~MVKSurface() {
	mvkForensicsRecord("NativeSurfaceDestroy", {{"phase", 0}, {"surface", uint64_t(uintptr_t(this))},
		{"surfaceGeneration", _diagnosticGeneration}});
	releaseLayer(2);
	mvkForensicsRecord("NativeSurfaceDestroy", {{"phase", 1}, {"surface", uint64_t(uintptr_t(this))},
		{"surfaceGeneration", _diagnosticGeneration}});
}

