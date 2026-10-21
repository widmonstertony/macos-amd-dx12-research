// Windows x64 compute probe, also included by the native macOS host.
// Uses the established ABI declarations without modifying the original probe.
#ifndef D3D12_COMPUTE_BASE_INCLUDED
#define mainCRTStartup original_capability_mainCRTStartup
#include "../d3d12_probe.cpp"
#undef mainCRTStartup
#endif
#include "compute_shader_dxil.h"

struct RootDescriptor { U32 ShaderRegister, RegisterSpace; };
struct RootConstants { U32 ShaderRegister, RegisterSpace, Num32BitValues; };
struct RootDescriptorTable { U32 NumRanges; const void *Ranges; };
struct RootParameter {
    U32 ParameterType;
    union { RootDescriptor Descriptor; RootConstants Constants; RootDescriptorTable Table; };
    U32 ShaderVisibility;
};
struct RootSignatureDesc {
    U32 NumParameters; const RootParameter *Parameters;
    U32 NumStaticSamplers; const void *StaticSamplers;
    U32 Flags;
};
struct ShaderBytecode { const void *Data; Size Bytes; };
struct CachedPipelineState { const void *Data; Size Bytes; };
struct ComputePipelineDesc {
    Com *RootSignature; ShaderBytecode Shader; U32 NodeMask;
    CachedPipelineState Cached; U32 Flags;
};
static_assert(sizeof(RootParameter) == 32 && sizeof(RootSignatureDesc) == 40, "D3D12 rootsig ABI");
static_assert(sizeof(ComputePipelineDesc) == 56, "D3D12 compute PSO ABI");
static const Guid IID_RootSignature = {0xc54a6b66,0x72df,0x4ee8,{0x8b,0xe5,0xa9,0x46,0xa1,0x42,0x92,0x14}};
static const Guid IID_PipelineState = {0x765a30f3,0xf624,0x4c6f,{0xa8,0x28,0xac,0xe9,0x48,0x62,0x24,0x45}};

static bool compute_smoke(Com *device, Handle d3d12) {
    Com *rootBlob = nullptr, *errors = nullptr, *root = nullptr, *pso = nullptr;
    Com *queue = nullptr, *allocator = nullptr, *list = nullptr, *list7 = nullptr;
    Com *gpu = nullptr, *readback = nullptr, *fence = nullptr;
#ifdef D3D12_DESCRIPTOR_TABLE_CONTROL
    Com *descriptorHeap = nullptr;
#endif
    bool pass = false;
    auto need = [](const char *name, HR value) { hr(name, value); return value >= 0; };
    {
        auto serialize = reinterpret_cast<HR (__stdcall *)(const RootSignatureDesc *, U32, Com **, Com **)>(
            GetProcAddress(d3d12, "D3D12SerializeRootSignature"));
        if (!serialize) { text("compute.error=missing D3D12SerializeRootSignature\n"); goto cleanup; }
        RootParameter parameters[2] = {};
        parameters[0].ParameterType = 4; // D3D12_ROOT_PARAMETER_TYPE_UAV.
        parameters[0].Descriptor = {0, 0};
#ifdef D3D12_DESCRIPTOR_TABLE_CONTROL
        struct DescriptorRange { U32 Type, Count, Register, Space, Offset; };
        DescriptorRange range = {1, 1, 0, 0, 0}; // One UAV at u0.
        parameters[0].ParameterType = 0;
        parameters[0].Table = {1, &range};
#endif
        parameters[1].ParameterType = 1; // 32-bit root constants at b0.
        parameters[1].Constants = {0, 0, 2};
        RootSignatureDesc rootDesc = {2, parameters, 0, nullptr, 0};
        if (!need("compute.SerializeRootSignature", serialize(&rootDesc, 1, &rootBlob, &errors))) {
            if (errors) text(static_cast<const char *>(method<void *(__stdcall *)(Com *)>(errors, 3)(errors)));
            goto cleanup;
        }
        const void *rootData = method<void *(__stdcall *)(Com *)>(rootBlob, 3)(rootBlob);
        Size rootBytes = method<Size (__stdcall *)(Com *)>(rootBlob, 4)(rootBlob);
        text("compute.root_signature_bytes="); number(rootBytes); text("\n");
        if (!need("compute.CreateRootSignature", method<HR (__stdcall *)(Com *, U32, const void *, Size, const Guid *, Com **)>(device, 16)(device, 0, rootData, rootBytes, &IID_RootSignature, &root))) goto cleanup;
        ComputePipelineDesc pipeline = {};
        pipeline.RootSignature = root;
        pipeline.Shader = {compute_shader_dxil, sizeof(compute_shader_dxil)};
        text("compute.shader_dxil_bytes="); number(sizeof(compute_shader_dxil)); text("\n");
        if (!need("compute.CreateComputePipelineState", method<HR (__stdcall *)(Com *, const ComputePipelineDesc *, const Guid *, Com **)>(device, 11)(device, &pipeline, &IID_PipelineState, &pso))) goto cleanup;
        QueueDesc queueDesc = {0, 0, 0, 0};
        if (!need("compute.CreateCommandQueue", method<HR (__stdcall *)(Com *, const QueueDesc *, const Guid *, Com **)>(device, 8)(device, &queueDesc, &IID_Queue, &queue))) goto cleanup;
        if (!need("compute.CreateCommandAllocator", method<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(device, 9)(device, 0, &IID_Allocator, &allocator))) goto cleanup;
        if (!need("compute.CreateCommandList", method<HR (__stdcall *)(Com *, U32, U32, Com *, Com *, const Guid *, Com **)>(device, 12)(device, 0, 0, allocator, pso, &IID_CommandList, &list))) goto cleanup;
        if (!need("compute.QueryCommandList7", method<HR (__stdcall *)(Com *, const Guid *, Com **)>(list, 0)(list, &IID_CommandList7, &list7))) goto cleanup;
        HeapProperties gpuHeap = {1, 0, 0, 1, 1}, readHeap = {3, 0, 0, 1, 1};
        ResourceDesc gpuDesc = {1, 0, 4096, 1, 1, 1, 0, 1, 0, 1, 4}; // BUFFER, ROW_MAJOR, UAV.
        ResourceDesc readDesc = gpuDesc; readDesc.Flags = 0;
        auto createBuffer = method<HR (__stdcall *)(Com *, const HeapProperties *, U32, const ResourceDesc *, U32, const void *, const Guid *, Com **)>(device, 27);
        if (!need("compute.CreateDefaultUAV", createBuffer(device, &gpuHeap, 0, &gpuDesc, 0, nullptr, &IID_Resource, &gpu))) goto cleanup;
        if (!need("compute.CreateReadback", createBuffer(device, &readHeap, 0, &readDesc, 0x400, nullptr, &IID_Resource, &readback))) goto cleanup;
        if (!need("compute.CreateFence", method<HR (__stdcall *)(Com *, U64, U32, const Guid *, Com **)>(device, 36)(device, 0, 0, &IID_Fence, &fence))) goto cleanup;
#ifdef D3D12_DESCRIPTOR_TABLE_CONTROL
        struct HeapDesc { U32 Type, Count, Flags, NodeMask; };
        struct CPUHandle { Size Ptr; };
        struct GPUHandle { U64 Ptr; };
        struct UAVDesc { U32 Format, Dimension; U64 FirstElement; U32 Count, Stride; U64 CounterOffset; U32 Flags; };
        static_assert(sizeof(UAVDesc) == 40, "D3D12 buffer UAV ABI");
        const Guid heapIID = {0x8efb471d,0x616c,0x4f49,{0x90,0xf7,0x12,0x7b,0xb7,0x63,0xfa,0x51}};
        HeapDesc heapDesc = {0, 1, 1, 0};
        if (!need("descriptor.CreateHeap", method<HR (__stdcall *)(Com *, const HeapDesc *, const Guid *, Com **)>(device,14)(device,&heapDesc,&heapIID,&descriptorHeap))) goto cleanup;
        CPUHandle cpuHandle = {}; GPUHandle gpuHandle = {};
        method<CPUHandle *(__stdcall *)(Com *, CPUHandle *)>(descriptorHeap,9)(descriptorHeap,&cpuHandle);
        method<GPUHandle *(__stdcall *)(Com *, GPUHandle *)>(descriptorHeap,10)(descriptorHeap,&gpuHandle);
        UAVDesc uav = {39,1,0,1024,0,0,1}; // R32_TYPELESS raw buffer.
        method<void (__stdcall *)(Com *,Com *,Com *,const UAVDesc *,CPUHandle)>(device,19)(device,gpu,nullptr,&uav,cpuHandle);
        method<void (__stdcall *)(Com *,U32,Com *const *)>(list,28)(list,1,&descriptorHeap);
#endif
        U64 gpuAddress = method<U64 (__stdcall *)(Com *)>(gpu, 11)(gpu);
        text("compute.root_uav_gpuva_nonzero="); number(gpuAddress != 0); text("\n");
        if (!gpuAddress) goto cleanup;
        BufferBarrier prepare = {0, 0x80, 0x80000000u, 0x10, gpu, 0, 4096};
        BarrierGroup prepareGroup = {2, 1, &prepare};
        method<void (__stdcall *)(Com *, U32, const BarrierGroup *)>(list7, 80)(list7, 1, &prepareGroup);
        method<void (__stdcall *)(Com *, Com *)>(list, 29)(list, root);
#ifndef D3D12_DESCRIPTOR_TABLE_CONTROL
        method<void (__stdcall *)(Com *, U32, U64)>(list, 41)(list, 0, gpuAddress);
#endif
        U32 constants[2] = {1024, 0x693c24a7u};
        method<void (__stdcall *)(Com *, U32, U32, const void *, U32)>(list, 35)(list, 1, 2, constants, 0);
        text("compute.Dispatch=16 groups x 64 threads; indirect root UAV address\n");
#ifdef D3D12_DESCRIPTOR_TABLE_CONTROL
        for (U32 repeat = 0; repeat < 16; ++repeat) {
            method<void (__stdcall *)(Com *,U32,GPUHandle)>(list,31)(list,0,gpuHandle);
            method<void (__stdcall *)(Com *, U32, U32, U32)>(list,14)(list,16,1,1);
            BufferBarrier order = {0x80,0x80,0x10,0x10,gpu,0,4096};
            BarrierGroup orderGroup = {2,1,&order};
            method<void (__stdcall *)(Com *, U32, const BarrierGroup *)>(list7,80)(list7,1,&orderGroup);
        }
        text("descriptor.table_dispatches=16 actual_UAV_heap_bound=1\n");
#else
        method<void (__stdcall *)(Com *, U32, U32, U32)>(list, 14)(list, 16, 1, 1);
#endif
        BufferBarrier finish = {0x80, 0x200, 0x10, 0x800, gpu, 0, 4096};
        BarrierGroup finishGroup = {2, 1, &finish};
        method<void (__stdcall *)(Com *, U32, const BarrierGroup *)>(list7, 80)(list7, 1, &finishGroup);
        method<void (__stdcall *)(Com *, Com *, U64, Com *, U64, U64)>(list, 15)(list, readback, 0, gpu, 0, 4096);
        if (!need("compute.Close", method<HR (__stdcall *)(Com *)>(list, 9)(list))) goto cleanup;
        method<void (__stdcall *)(Com *, U32, Com *const *)>(queue, 10)(queue, 1, &list);
        if (!need("compute.Signal", method<HR (__stdcall *)(Com *, Com *, U64)>(queue, 14)(queue, fence, 1))) goto cleanup;
        bool completed = false;
        for (U32 i = 0; i < 500; ++i) {
            U64 value = method<U64 (__stdcall *)(Com *)>(fence, 8)(fence);
            if (value == ~U64(0)) { text("compute.fence=device removed\n"); goto cleanup; }
            if (value >= 1) { completed = true; break; }
            Sleep(10);
        }
        if (!completed) { text("compute.fence=timeout after 5 seconds\n"); goto cleanup; }
        Range readRange = {0, 4096}, noWrite = {0, 0};
        void *mapped = nullptr;
        if (!need("compute.MapReadback", method<HR (__stdcall *)(Com *, U32, const Range *, void **)>(readback, 8)(readback, 0, &readRange, &mapped))) goto cleanup;
        U32 mismatches = 0;
        for (U32 i = 0; i < 1024; ++i) {
            U32 expected = (i * 2654435761u) ^ constants[1];
            U32 actual = static_cast<const U32 *>(mapped)[i];
            if (actual != expected) {
                if (mismatches < 8) { text("compute.mismatch.index="); number(i); text(" expected="); hex(expected); text(" actual="); hex(actual); text("\n"); }
                ++mismatches;
            }
        }
        method<void (__stdcall *)(Com *, U32, const Range *)>(readback, 9)(readback, 0, &noWrite);
        text("compute.compared_words=1024 mismatches="); number(mismatches); text("\n");
        pass = mismatches == 0;
    }
cleanup:
    hr("compute.DeviceRemovedReason", method<HR (__stdcall *)(Com *)>(device, 37)(device));
    text("compute.result="); text(pass ? "PASS\n" : "FAIL\n");
    text("compute.scope=actual DXIL compute, root constants and indirect root UAV GPUVA, Enhanced Buffer Barriers, CPU readback; not game/conformance\n");
    release(list7); release(list); release(allocator); release(queue); release(fence);
    release(gpu); release(readback); release(pso); release(root); release(errors); release(rootBlob);
#ifdef D3D12_DESCRIPTOR_TABLE_CONTROL
    release(descriptorHeap);
#endif
    return pass;
}

#ifndef D3D12_COMPUTE_PROBE_NO_MAIN
extern "C" __declspec(noreturn) void mainCRTStartup() {
    text("D3D12_COMPUTE_PROBE_VERSION=1\nABI=Windows x64 COM/export; original generated shader\n");
    Handle dxgi = LoadLibraryW(L"dxgi.dll"), d3d12 = LoadLibraryW(L"d3d12.dll");
    module("DXGI.module", dxgi); module("D3D12.module", d3d12);
    if (!dxgi || !d3d12) ExitProcess(2);
    auto createFactory = reinterpret_cast<HR (__stdcall *)(const Guid *, Com **)>(GetProcAddress(dxgi, "CreateDXGIFactory1"));
    auto createDevice = reinterpret_cast<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(GetProcAddress(d3d12, "D3D12CreateDevice"));
    if (!createFactory || !createDevice) ExitProcess(3);
    Com *factory = nullptr;
    if (createFactory(&IID_Factory1, &factory) < 0) ExitProcess(4);
    U32 tested = 0, passed = 0;
    for (U32 i = 0; i < 16; ++i) {
        Com *adapter = nullptr;
        HR result = method<HR (__stdcall *)(Com *, U32, Com **)>(factory, 12)(factory, i, &adapter);
        if (U32(result) == 0x887a0002) break;
        if (result < 0) break;
        AdapterDesc1 desc = {};
        result = method<HR (__stdcall *)(Com *, AdapterDesc1 *)>(adapter, 10)(adapter, &desc);
        if (result < 0 || desc.VendorId != 0x1002) { release(adapter); continue; }
        text("ADAPTER.description="); wide(desc.Description); text("\nADAPTER.vendor="); hex(desc.VendorId); text("\n");
        Com *device = nullptr;
        result = createDevice(adapter, 0xb000, &IID_Device, &device); hr("compute.D3D12CreateDevice", result);
        if (result >= 0 && device) { ++tested; if (compute_smoke(device, d3d12)) ++passed; release(device); }
        release(adapter);
    }
    release(factory);
    text("compute.amd_adapters_tested="); number(tested); text(" passed="); number(passed); text("\n");
    ExitProcess(tested && passed == tested ? 0 : 5);
}
#endif
