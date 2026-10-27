// SPDX-License-Identifier: LGPL-2.1-or-later
// App-local implementation of the AGS 6.3 base contract using actual DXGI and
// D3D12 objects. Architecture reference: Proton's open amd_ags_x64 implementation.
// No AMD Windows driver version or proprietary extension support is invented.
#pragma once
#include <dxgi1_6.h>

struct CompatAGSContext {
    CompatAGSContext *next;
    AGSGPUInfo info;
    AGSDeviceInfo devices[16];
    char names[16][256];
    char driver[96];
};
static SRWLOCK context_lock = SRWLOCK_INIT;
static CompatAGSContext *contexts;

static CompatAGSContext *compat_context(AGSContext *pointer) {
    AcquireSRWLockShared(&context_lock);
    CompatAGSContext *found = contexts;
    while (found && (AGSContext *)found != pointer) found = found->next;
    ReleaseSRWLockShared(&context_lock);
    return found;
}

static AGSReturnCode compat_initialize(int version, AGSContext **context, AGSGPUInfo *info) {
    // The layout below is the public 6.3 ABI; do not guess older/newer layouts.
    if (!context || (version & 0xfffff000) != AGS_MAKE_VERSION(6, 3, 0)) return AGS_INVALID_ARGS;
    *context = NULL;
    IDXGIFactory1 *factory = NULL;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void **)&factory);
    if (FAILED(hr)) { log_line("AGS-DXGI factory failed=%08lx", (unsigned long)hr); return AGS_DX_FAILURE; }
    auto object = (CompatAGSContext *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(CompatAGSContext));
    if (!object) { factory->Release(); return AGS_OUT_OF_MEMORY; }
    strcpy(object->driver, "Wine/vkd3d-proton; AMD Windows driver unavailable");
    object->info.driverVersion = object->driver;
    object->info.radeonSoftwareVersion = "unavailable";
    object->info.devices = object->devices;
    for (UINT i = 0; object->info.numDevices < 16; ++i) {
        IDXGIAdapter1 *adapter = NULL;
        hr = factory->EnumAdapters1(i, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) { factory->Release(); HeapFree(GetProcessHeap(), 0, object); return AGS_DX_FAILURE; }
        DXGI_ADAPTER_DESC1 desc = {};
        hr = adapter->GetDesc1(&desc); adapter->Release();
        if (FAILED(hr)) continue;
        unsigned n = object->info.numDevices++;
        auto &device = object->devices[n];
        WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, object->names[n], 256, NULL, NULL);
        device.adapterString = object->names[n];
        device.asicFamily = AGSAsicFamily_Unknown; // Not exposed by DXGI; don't infer a family.
        device.isPrimaryDevice = n == 0;
        device.vendorId = desc.VendorId; device.deviceId = desc.DeviceId; device.revisionId = desc.Revision;
        device.localMemoryInBytes = desc.DedicatedVideoMemory;
        device.sharedMemoryInBytes = desc.SharedSystemMemory;
        log_line("AGS-DXGI adapter=%u name=%s vendor=%04x device=%04x VRAM=%llu", n,
                 device.adapterString, desc.VendorId, desc.DeviceId, (unsigned long long)desc.DedicatedVideoMemory);
    }
    factory->Release();
    if (!object->info.numDevices) { HeapFree(GetProcessHeap(), 0, object); return AGS_DX_FAILURE; }
    AcquireSRWLockExclusive(&context_lock);
    object->next = contexts; contexts = object;
    ReleaseSRWLockExclusive(&context_lock);
    *context = (AGSContext *)object;
    if (info) *info = object->info;
    return AGS_SUCCESS; // Real enumeration and an owned, valid base-service context.
}

static void compat_destroy(CompatAGSContext *object) {
    AcquireSRWLockExclusive(&context_lock);
    auto slot = &contexts;
    while (*slot && *slot != object) slot = &(*slot)->next;
    if (*slot) *slot = object->next;
    ReleaseSRWLockExclusive(&context_lock);
    HeapFree(GetProcessHeap(), 0, object);
}

static AGSReturnCode compat_create_device(const AGSDX12DeviceCreationParams *creation,
                                         AGSDX12ReturnedParams *returned) {
    if (!creation || !returned) return AGS_INVALID_ARGS;
    memset(returned, 0, sizeof(*returned));
    HRESULT hr = D3D12CreateDevice(creation->pAdapter, creation->FeatureLevel, creation->iid,
                                 (void **)&returned->pDevice);
    log_line("AGS-DXGI D3D12CreateDevice result=%08lx device=%p proprietaryExtensions=0",
             (unsigned long)hr, returned->pDevice);
    return SUCCEEDED(hr) ? AGS_SUCCESS : AGS_DX_FAILURE;
}
