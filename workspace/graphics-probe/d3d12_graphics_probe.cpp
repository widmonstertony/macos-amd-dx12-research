// Microsoft x64 COM ABI; manually checked against Microsoft's MIT DirectX-Headers.
// https://github.com/microsoft/DirectX-Headers/blob/main/include/directx/d3d12.h
// This independent experiment never modifies the original GPTK binary.
#ifndef D3D12_GRAPHICS_BASE_INCLUDED
#define mainCRTStartup original_capability_mainCRTStartup
#include "../d3d12_probe.cpp"
#undef mainCRTStartup
#endif
#ifdef GRAPHICS_PROBE_DXBC_SM5
#include "../dxbc-probe/dxbc_shader_provider.h"
#else
#include "graphics_shaders_dxil.h"
#endif
// MSVC's freestanding floating-point marker; no CRT implementation is needed.
extern "C" { int _fltused = 0; }

struct GRootSignatureDesc { U32 NumParameters; const void *Parameters; U32 NumStaticSamplers; const void *StaticSamplers; U32 Flags; };
struct GShaderBytecode { const void *Data; Size Bytes; };
struct GCachedPipeline { const void *Data; Size Bytes; };
struct GStreamOutput { const void *Entries; U32 NumEntries; const U32 *Strides; U32 NumStrides, RasterizedStream; };
struct GTargetBlend { I32 BlendEnable, LogicEnable; U32 Src, Dest, Op, SrcAlpha, DestAlpha, OpAlpha, Logic; unsigned char WriteMask; };
struct GBlend { I32 AlphaCoverage, Independent; GTargetBlend Targets[8]; };
struct GRasterizer { U32 Fill, Cull; I32 FrontCCW, DepthBias; float BiasClamp, SlopeBias; I32 DepthClip, Multisample, AntialiasedLine; U32 ForcedSamples, Conservative; };
struct GStencilOp { U32 Fail, DepthFail, Pass, Comparison; };
struct GDepthStencil { I32 DepthEnable; U32 DepthWrite, DepthFunc; I32 StencilEnable; unsigned char StencilReadMask, StencilWriteMask; GStencilOp Front, Back; };
struct GInputLayout { const void *Elements; U32 Count; };
struct GGraphicsPipeline {
    Com *Root; GShaderBytecode VS, PS, DS, HS, GS; GStreamOutput StreamOutput;
    GBlend Blend; U32 SampleMask; GRasterizer Rasterizer; GDepthStencil DepthStencil;
    GInputLayout Input; U32 StripCut, TopologyType, NumTargets, TargetFormats[8], DepthFormat, SampleCount, SampleQuality, NodeMask;
    GCachedPipeline Cached; U32 Flags;
};
struct GHeapDesc { U32 Type, Count, Flags, NodeMask; };
struct GCpuHandle { Size Ptr; };
struct GViewport { float X, Y, Width, Height, MinDepth, MaxDepth; };
struct GRect { I32 Left, Top, Right, Bottom; };
struct GSubresourceRange { U32 FirstMip, MipCount, FirstArray, ArrayCount, FirstPlane, PlaneCount; };
struct GTextureBarrier { U32 SyncBefore, SyncAfter, AccessBefore, AccessAfter, LayoutBefore, LayoutAfter; Com *Resource; GSubresourceRange Subresources; U32 Flags; };
struct GBarrierGroup { U32 Type, Count; const GTextureBarrier *Textures; };
struct GFootprint { U32 Format, Width, Height, Depth, Pitch; };
struct GPlacedFootprint { U64 Offset; GFootprint Footprint; };
struct GCopyLocation { Com *Resource; U32 Type; union { GPlacedFootprint Placed; U32 Subresource; }; };
static_assert(sizeof(GRootSignatureDesc) == 40 && sizeof(GGraphicsPipeline) == 656, "graphics/root ABI");
static_assert(sizeof(GBlend) == 328 && sizeof(GRasterizer) == 44 && sizeof(GDepthStencil) == 52, "graphics descriptor ABI");
static_assert(sizeof(GTextureBarrier) == 64 && sizeof(GCopyLocation) == 48 && sizeof(GPlacedFootprint) == 32, "barrier/copy ABI");
static const Guid G_IID_Root = {0xc54a6b66,0x72df,0x4ee8,{0x8b,0xe5,0xa9,0x46,0xa1,0x42,0x92,0x14}};
static const Guid G_IID_PSO = {0x765a30f3,0xf624,0x4c6f,{0xa8,0x28,0xac,0xe9,0x48,0x62,0x24,0x45}};
static const Guid G_IID_DescriptorHeap = {0x8efb471d,0x616c,0x4f49,{0x90,0xf7,0x12,0x7b,0xb7,0x63,0xfa,0x51}};

static bool graphics_smoke(Com *device, Handle d3d12) {
    Com *blob = nullptr, *errors = nullptr, *root = nullptr, *pso = nullptr, *heap = nullptr;
    Com *queue = nullptr, *allocator = nullptr, *list = nullptr, *list7 = nullptr, *texture = nullptr, *readback = nullptr, *fence = nullptr;
    bool pass = false;
#ifdef GRAPHICS_PROBE_DXBC_SM5
    DxbcPrograms dxbc = {};
#endif
    auto need = [](const char *name, HR value) { hr(name, value); return value >= 0; };
    {
        auto serialize = reinterpret_cast<HR (__stdcall *)(const GRootSignatureDesc *, U32, Com **, Com **)>(GetProcAddress(d3d12, "D3D12SerializeRootSignature"));
        if (!serialize) { text("graphics.error=no root serializer\n"); goto cleanup; }
        GRootSignatureDesc rootDesc = {};
        if (!need("graphics.SerializeEmptyRootSignature", serialize(&rootDesc, 1, &blob, &errors))) {
            if (errors) text(static_cast<const char *>(method<void *(__stdcall *)(Com *)>(errors, 3)(errors)));
            goto cleanup;
        }
        void *rootData = method<void *(__stdcall *)(Com *)>(blob, 3)(blob);
        Size rootBytes = method<Size (__stdcall *)(Com *)>(blob, 4)(blob);
        if (!need("graphics.CreateRootSignature", method<HR (__stdcall *)(Com *, U32, const void *, Size, const Guid *, Com **)>(device, 16)(device, 0, rootData, rootBytes, &G_IID_Root, &root))) goto cleanup;
        GGraphicsPipeline pipeline = {};
        pipeline.Root = root;
#ifdef GRAPHICS_PROBE_DXBC_SM5
        if (!dxbc_compile_programs(&dxbc)) goto cleanup;
        pipeline.VS = {dxbc.VS, dxbc.VSBytes}; pipeline.PS = {dxbc.PS, dxbc.PSBytes};
#else
        pipeline.VS = {graphics_vs_dxil, sizeof(graphics_vs_dxil)}; pipeline.PS = {graphics_ps_dxil, sizeof(graphics_ps_dxil)};
#endif
        for (U32 i = 0; i < 8; ++i) pipeline.Blend.Targets[i] = {0, 0, 2, 1, 1, 2, 1, 1, 5, 15};
        pipeline.SampleMask = 0xffffffffu;
        pipeline.Rasterizer = {3, 1, 0, 0, 0.0f, 0.0f, 1, 0, 0, 0, 0};
        pipeline.DepthStencil.DepthFunc = 8;
        pipeline.DepthStencil.Front = pipeline.DepthStencil.Back = {1, 1, 1, 8};
        pipeline.TopologyType = 3; pipeline.NumTargets = 1; pipeline.TargetFormats[0] = 28; pipeline.SampleCount = 1;
#ifdef GRAPHICS_PROBE_DXBC_SM5
        text("graphics.DXBC_SM5.vs_bytes="); number(dxbc.VSBytes); text(" ps_bytes="); number(dxbc.PSBytes); text("\n");
#else
        text("graphics.DXIL.vs_bytes="); number(sizeof(graphics_vs_dxil)); text(" ps_bytes="); number(sizeof(graphics_ps_dxil)); text("\n");
#endif
        if (!need("graphics.CreateGraphicsPipelineState", method<HR (__stdcall *)(Com *, const GGraphicsPipeline *, const Guid *, Com **)>(device, 10)(device, &pipeline, &G_IID_PSO, &pso))) goto cleanup;
        GHeapDesc heapDesc = {2, 1, 0, 0}; // RTV, CPU-only.
        if (!need("graphics.CreateRTVDescriptorHeap", method<HR (__stdcall *)(Com *, const GHeapDesc *, const Guid *, Com **)>(device, 14)(device, &heapDesc, &G_IID_DescriptorHeap, &heap))) goto cleanup;
        GCpuHandle rtv = {};
        // Windows COM member methods returning a struct use this + hidden output pointer.
        method<GCpuHandle *(__stdcall *)(Com *, GCpuHandle *)>(heap, 9)(heap, &rtv);
        text("graphics.GetCPUDescriptorHandle.nonzero="); number(rtv.Ptr != 0); text("\n");
        if (!rtv.Ptr) goto cleanup;
        QueueDesc queueDesc = {0, 0, 0, 0};
        if (!need("graphics.CreateCommandQueue", method<HR (__stdcall *)(Com *, const QueueDesc *, const Guid *, Com **)>(device, 8)(device, &queueDesc, &IID_Queue, &queue))) goto cleanup;
        if (!need("graphics.CreateCommandAllocator", method<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(device, 9)(device, 0, &IID_Allocator, &allocator))) goto cleanup;
        if (!need("graphics.CreateCommandList", method<HR (__stdcall *)(Com *, U32, U32, Com *, Com *, const Guid *, Com **)>(device, 12)(device, 0, 0, allocator, pso, &IID_CommandList, &list))) goto cleanup;
        if (!need("graphics.QueryCommandList7", method<HR (__stdcall *)(Com *, const Guid *, Com **)>(list, 0)(list, &IID_CommandList7, &list7))) goto cleanup;
        HeapProperties gpuHeap = {1, 0, 0, 1, 1}, readHeap = {3, 0, 0, 1, 1};
        ResourceDesc textureDesc = {3, 0, 64, 64, 1, 1, 28, 1, 0, 0, 1}; // TEXTURE2D, RGBA8_UNORM, UNKNOWN layout, RT flag.
        ResourceDesc readDesc = {1, 0, 16384, 1, 1, 1, 0, 1, 0, 1, 0};
        auto createResource = method<HR (__stdcall *)(Com *, const HeapProperties *, U32, const ResourceDesc *, U32, const void *, const Guid *, Com **)>(device, 27);
        if (!need("graphics.CreateRenderTexture", createResource(device, &gpuHeap, 0, &textureDesc, 0, nullptr, &IID_Resource, &texture))) goto cleanup;
        if (!need("graphics.CreateReadback", createResource(device, &readHeap, 0, &readDesc, 0x400, nullptr, &IID_Resource, &readback))) goto cleanup;
        method<void (__stdcall *)(Com *, Com *, const void *, GCpuHandle)>(device, 20)(device, texture, nullptr, rtv);
        text("graphics.CreateRenderTargetView=called\n");
        GPlacedFootprint actualFootprint = {}; U32 rows = 0; U64 rowBytes = 0, totalBytes = 0;
        method<void (__stdcall *)(Com *, const ResourceDesc *, U32, U32, U64, GPlacedFootprint *, U32 *, U64 *, U64 *)>(device, 38)(device, &textureDesc, 0, 1, 0, &actualFootprint, &rows, &rowBytes, &totalBytes);
        text("graphics.GetCopyableFootprints.pitch="); number(actualFootprint.Footprint.Pitch); text(" rows="); number(rows); text(" total_bytes="); number(totalBytes); text("\n");
        if (actualFootprint.Footprint.Pitch != 256 || rows != 64 || rowBytes != 256 || totalBytes > 16384) { text("graphics.error=unexpected footprint\n"); goto cleanup; }
        if (!need("graphics.CreateFence", method<HR (__stdcall *)(Com *, U64, U32, const Guid *, Com **)>(device, 36)(device, 0, 0, &IID_Fence, &fence))) goto cleanup;
        GTextureBarrier prepare = {0, 0x40, 0x80000000u, 8, 0, 2, texture, {0, 1, 0, 1, 0, 1}, 0};
        GBarrierGroup prepareGroup = {1, 1, &prepare};
        method<void (__stdcall *)(Com *, U32, const GBarrierGroup *)>(list7, 80)(list7, 1, &prepareGroup);
        method<void (__stdcall *)(Com *, Com *)>(list, 30)(list, root);
        GViewport viewport = {0, 0, 64, 64, 0, 1}; GRect rect = {0, 0, 64, 64};
        method<void (__stdcall *)(Com *, U32, const GViewport *)>(list, 21)(list, 1, &viewport);
        method<void (__stdcall *)(Com *, U32, const GRect *)>(list, 22)(list, 1, &rect);
        method<void (__stdcall *)(Com *, U32)>(list, 20)(list, 4); // TRIANGLELIST.
        method<void (__stdcall *)(Com *, U32, const GCpuHandle *, I32, const GCpuHandle *)>(list, 46)(list, 1, &rtv, 0, nullptr);
        const float clear[4] = {0, 0, 0, 0};
        method<void (__stdcall *)(Com *, GCpuHandle, const float *, U32, const GRect *)>(list, 48)(list, rtv, clear, 0, nullptr);
        text("graphics.DrawInstanced=3 vertices fullscreen triangle; position-based XY gradient\n");
        method<void (__stdcall *)(Com *, U32, U32, U32, U32)>(list, 12)(list, 3, 1, 0, 0);
        GTextureBarrier finish = {0x40, 0x200, 8, 0x800, 2, 7, texture, {0, 1, 0, 1, 0, 1}, 0};
        GBarrierGroup finishGroup = {1, 1, &finish};
        method<void (__stdcall *)(Com *, U32, const GBarrierGroup *)>(list7, 80)(list7, 1, &finishGroup);
        GCopyLocation source = {}; source.Resource = texture; source.Type = 0; source.Subresource = 0;
        GCopyLocation dest = {}; dest.Resource = readback; dest.Type = 1; dest.Placed = actualFootprint;
        method<void (__stdcall *)(Com *, const GCopyLocation *, U32, U32, U32, const GCopyLocation *, const void *)>(list, 16)(list, &dest, 0, 0, 0, &source, nullptr);
        text("graphics.CopyTextureRegion=texture to CPU-readback buffer\n");
        if (!need("graphics.Close", method<HR (__stdcall *)(Com *)>(list, 9)(list))) goto cleanup;
        method<void (__stdcall *)(Com *, U32, Com *const *)>(queue, 10)(queue, 1, &list);
        if (!need("graphics.Signal", method<HR (__stdcall *)(Com *, Com *, U64)>(queue, 14)(queue, fence, 1))) goto cleanup;
        bool completed = false;
        for (U32 i = 0; i < 500; ++i) {
            U64 value = method<U64 (__stdcall *)(Com *)>(fence, 8)(fence);
            if (value == ~U64(0)) { text("graphics.fence=device removed\n"); goto cleanup; }
            if (value >= 1) { completed = true; break; } Sleep(10);
        }
        if (!completed) { text("graphics.fence=timeout after 5 seconds\n"); goto cleanup; }
        void *mapped = nullptr; Range readRange = {0, 16384}, noWrite = {0, 0};
        if (!need("graphics.MapReadback", method<HR (__stdcall *)(Com *, U32, const Range *, void **)>(readback, 8)(readback, 0, &readRange, &mapped))) goto cleanup;
        U32 mismatches = 0;
        for (U32 y = 0; y < 64; ++y) for (U32 x = 0; x < 64; ++x) {
            const auto *pixel = static_cast<const unsigned char *>(mapped) + y * 256 + x * 4;
            U32 expected = ((x * 3 + 17) & 255) | (((y * 5 + 29) & 255) << 8) | (73u << 16) | (255u << 24);
            U32 actual = U32(pixel[0]) | (U32(pixel[1]) << 8) | (U32(pixel[2]) << 16) | (U32(pixel[3]) << 24);
            if (((x == 0 || x == 63) && (y == 0 || y == 63)) || (x == 32 && y == 32)) {
                text("graphics.pixel.x="); number(x); text(" y="); number(y); text(" expected_RGBA="); hex(expected); text(" actual_RGBA="); hex(actual); text("\n");
            }
            if (actual != expected) {
                if (mismatches < 8) { text("graphics.mismatch.x="); number(x); text(" y="); number(y); text(" expected="); hex(expected); text(" actual="); hex(actual); text("\n"); }
                ++mismatches;
            }
        }
        method<void (__stdcall *)(Com *, U32, const Range *)>(readback, 9)(readback, 0, &noWrite);
        text("graphics.compared_pixels=4096 mismatches="); number(mismatches); text("\n");
        pass = mismatches == 0;
    }
cleanup:
#ifdef GRAPHICS_PROBE_DXBC_SM5
    release(dxbc.PSBlob); release(dxbc.VSBlob);
#endif
    hr("graphics.DeviceRemovedReason", method<HR (__stdcall *)(Com *)>(device, 37)(device));
    text("graphics.result="); text(pass ? "PASS\n" : "FAIL\n");
#ifdef GRAPHICS_PROBE_DXBC_SM5
    text("graphics.scope=genuine Windows D3DCompile VS+PS SM5 DXBC, PSO, RTV texture, draw, Enhanced Texture Barriers, 4096-pixel CPU readback; classification simulated; not game/conformance\n");
#else
    text("graphics.scope=actual VS+PS DXIL, PSO, RTV texture, draw, Enhanced Texture Barriers, texture CPU readback; classification simulated; software residency incomplete; not game/conformance\n");
#endif
    release(list7); release(list); release(allocator); release(queue); release(fence); release(texture); release(readback); release(heap); release(pso); release(root); release(errors); release(blob);
    return pass;
}

extern "C" __declspec(noreturn) void mainCRTStartup() {
#ifdef GRAPHICS_PROBE_DXBC_SM5
    text("D3D12_GRAPHICS_PROBE_VERSION=DXBC_SM5_1\nABI=Windows x64 COM/export; runtime genuine Windows D3DCompile SM5\n");
#else
    text("D3D12_GRAPHICS_PROBE_VERSION=1\nABI=Windows x64 COM/export; original DXIL shaders\n");
#endif
    Handle dxgi = LoadLibraryW(L"dxgi.dll"), d3d12 = LoadLibraryW(L"d3d12.dll");
    module("DXGI.module", dxgi); module("D3D12.module", d3d12);
    if (!dxgi || !d3d12) ExitProcess(2);
    auto createFactory = reinterpret_cast<HR (__stdcall *)(const Guid *, Com **)>(GetProcAddress(dxgi, "CreateDXGIFactory1"));
    auto createDevice = reinterpret_cast<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(GetProcAddress(d3d12, "D3D12CreateDevice"));
    if (!createFactory || !createDevice) ExitProcess(3);
    Com *factory = nullptr; if (createFactory(&IID_Factory1, &factory) < 0) ExitProcess(4);
    U32 tested = 0, passed = 0;
    for (U32 i = 0; i < 16; ++i) {
        Com *adapter = nullptr;
        HR result = method<HR (__stdcall *)(Com *, U32, Com **)>(factory, 12)(factory, i, &adapter);
        if (U32(result) == 0x887a0002 || result < 0) break;
        AdapterDesc1 desc = {}; result = method<HR (__stdcall *)(Com *, AdapterDesc1 *)>(adapter, 10)(adapter, &desc);
        if (result < 0 || desc.VendorId != 0x1002) { release(adapter); continue; }
        text("ADAPTER.description="); wide(desc.Description); text("\nADAPTER.vendor="); hex(desc.VendorId); text("\n");
        Com *device = nullptr; result = createDevice(adapter, 0xb000, &IID_Device, &device); hr("graphics.D3D12CreateDevice", result);
        if (result >= 0 && device) { ++tested; if (graphics_smoke(device, d3d12)) ++passed; release(device); } release(adapter);
    }
    release(factory); text("graphics.amd_adapters_tested="); number(tested); text(" passed="); number(passed); text("\n");
    ExitProcess(tested && passed == tested ? 0 : 5);
}
