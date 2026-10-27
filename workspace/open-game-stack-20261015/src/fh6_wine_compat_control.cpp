#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#define AGS_GCC
#define AGS_EXCLUDE_DIRECTX_TYPES
#include "vendor/amd_ags.h"
#include <stdio.h>

static bool gpu_copy(ID3D12Device *device) {
    ID3D12Resource *upload = NULL, *readback = NULL;
    ID3D12CommandQueue *queue = NULL; ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *list = NULL; ID3D12Fence *fence = NULL;
    D3D12_HEAP_PROPERTIES heap = {}; heap.Type = D3D12_HEAP_TYPE_UPLOAD;
    D3D12_RESOURCE_DESC desc = {}; desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = 256; desc.Height = desc.DepthOrArraySize = desc.MipLevels = 1;
    desc.SampleDesc.Count = 1; desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_GENERIC_READ, NULL, IID_PPV_ARGS(&upload)))) return false;
    heap.Type = D3D12_HEAP_TYPE_READBACK;
    if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_COPY_DEST, NULL, IID_PPV_ARGS(&readback)))) return false;
    UINT *mapped = NULL; D3D12_RANGE empty = {0, 0};
    if (FAILED(upload->Map(0, &empty, (void **)&mapped))) return false;
    for (UINT i = 0; i < 64; ++i) mapped[i] = 0x56000000u ^ (i * 17u);
    upload->Unmap(0, NULL);
    D3D12_COMMAND_QUEUE_DESC q = {};
    if (FAILED(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue))) ||
        FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator))) ||
        FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL, IID_PPV_ARGS(&list))) ||
        FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) return false;
    list->CopyBufferRegion(readback, 0, upload, 0, 256); list->Close();
    ID3D12CommandList *lists[] = {list}; queue->ExecuteCommandLists(1, lists);
    if (FAILED(queue->Signal(fence, 1))) return false;
    HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (FAILED(fence->SetEventOnCompletion(1, event)) || WaitForSingleObject(event, 10000) != WAIT_OBJECT_0) return false;
    CloseHandle(event);
    if (FAILED(readback->Map(0, NULL, (void **)&mapped))) return false;
    UINT mismatches = 0;
    for (UINT i = 0; i < 64; ++i) mismatches += mapped[i] != (0x56000000u ^ (i * 17u));
    readback->Unmap(0, &empty);
    fence->Release(); list->Release(); allocator->Release(); queue->Release(); readback->Release(); upload->Release();
    printf("ags.createdDevice.GPUCopy.values=64 mismatches=%u\n", mismatches);
    return !mismatches;
}

extern "C" __declspec(dllimport) HRESULT WINAPI GetIntegratedDisplaySize(double *);

int main() {
    const char *modules[] = {"d3d12.dll", "d3d12core.dll", "dxgi.dll"};
    for (const char *name : modules) {
        char path[2048] = "not-yet-loaded";
        if (HMODULE module = GetModuleHandleA(name)) GetModuleFileNameA(module, path, sizeof(path));
        printf("loaded.%s=%s\n", name, path);
    }
    double sentinel = 123.25;
    HRESULT result = GetIntegratedDisplaySize(&sentinel);
    printf("display.result=%08lx sentinel=%.2f\n", (unsigned long)result, sentinel);
    if (result != E_NOTIMPL || sentinel != 123.25) return 2;
    if (GetIntegratedDisplaySize(NULL) != E_NOTIMPL) return 3;
    HMODULE real = LoadLibraryW(L"amd_ags_real.dll");
    if (!real) return 4;
    auto direct_version = (int (*)())GetProcAddress(real, "agsGetVersionNumber");
    int version = agsGetVersionNumber();
    printf("ags.version=%08x direct=%08x\n", version, direct_version ? direct_version() : 0);
    if (!direct_version || version != direct_version()) return 5;
    AGSContext *context = NULL; AGSGPUInfo info = {};
    AGSReturnCode initialized = agsInitialize(version, NULL, &context, &info);
    printf("ags.initialize=%d context=%p devices=%d array=%p\n", initialized, context, info.numDevices, info.devices);
    if (initialized != AGS_SUCCESS || !context || !info.numDevices || !info.devices) return 6;
    AGSGPUInfo queried = {};
    if (agsGetGPUInfo(context, &queried) != AGS_SUCCESS || queried.devices != info.devices) return 7;
    printf("ags.adapter=%s vendor=%04x device=%04x vram=%llu\n", info.devices[0].adapterString,
           info.devices[0].vendorId, info.devices[0].deviceId, info.devices[0].localMemoryInBytes);
    AGSDX12DeviceCreationParams creation = {}; creation.iid = __uuidof(ID3D12Device);
    // Validate the actual supported base level, not a fabricated FL12 claim.
    // The earlier FL12_0 negative result remains in the evidence directory.
    // Game requests are forwarded unchanged and logged separately.
    creation.FeatureLevel = D3D_FEATURE_LEVEL_11_0;
    AGSDX12ReturnedParams returned = {};
    if (agsDriverExtensionsDX12_CreateDevice(context, &creation, NULL, &returned) != AGS_SUCCESS || !returned.pDevice) return 8;
    AGSDX12ExtensionsSupported no_extensions = {};
    if (memcmp(&returned.extensionsSupported, &no_extensions, sizeof(no_extensions))) return 9;
    if (!gpu_copy(returned.pDevice)) return 10;
    if (agsDriverExtensionsDX12_DestroyDevice(context, returned.pDevice, NULL) != AGS_SUCCESS) return 11;
    if (agsDeInitialize(context) != AGS_SUCCESS) return 12;
    printf("compat.control=PASS actual-DXGI-and-D3D12-no-proprietary-extension-claim\n");
    return 0;
}
