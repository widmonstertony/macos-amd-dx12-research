// Standalone Windows x64 D3D12 probe. No SDK, CRT, shader compiler, or game needed.
// Minimal ABI declarations verified against Microsoft DirectX-Headers d3d12.h
// and the DXGI interfaces. This is a capability query and COPY barrier smoke
// test, NOT an Enhanced Barriers conformance test or proof a game can run.
// https://github.com/microsoft/DirectX-Headers/blob/main/include/directx/d3d12.h
// https://learn.microsoft.com/windows/win32/api/dxgi1_2/nn-dxgi1_2-idxgiadapter1

using U32 = unsigned int;
using I32 = int;
using U64 = unsigned long long;
using Size = unsigned long long;
using HR = I32;
using Handle = void *;
struct Guid { U32 a; unsigned short b, c; unsigned char d[8]; };
struct Com { void **v; };
struct AdapterDesc1 {
    wchar_t Description[128];
    U32 VendorId, DeviceId, SubSysId, Revision;
    Size DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    U32 LuidLow;
    I32 LuidHigh;
    U32 Flags;
};
struct Options12 {
    I32 MSPrimitivesPipelineStatisticIncludesCulledPrimitives;
    I32 EnhancedBarriersSupported;
    I32 RelaxedFormatCastingSupported;
};
struct FeatureLevels { U32 Count; const U32 *Requested; U32 MaxSupported; };
struct HeapProperties { U32 Type, CPUPageProperty, MemoryPoolPreference, CreationNodeMask, VisibleNodeMask; };
struct ResourceDesc {
    U32 Dimension;
    U64 Alignment, Width;
    U32 Height;
    unsigned short DepthOrArraySize, MipLevels;
    U32 Format, SampleCount, SampleQuality, Layout, Flags;
};
struct QueueDesc { U32 Type; I32 Priority; U32 Flags, NodeMask; };
struct Range { Size Begin, End; };
// The barrier sync/access types in the official ABI are 32-bit enums, NOT U64.
struct BufferBarrier { U32 SyncBefore, SyncAfter, AccessBefore, AccessAfter; Com *Resource; U64 Offset, Size; };
struct BarrierGroup { U32 Type, Count; const BufferBarrier *Buffers; };
static_assert(sizeof(void *) == 8 && sizeof(wchar_t) == 2, "Windows x64 ABI required");
static_assert(sizeof(Guid) == 16 && sizeof(AdapterDesc1) == 312, "DXGI ABI");
static_assert(sizeof(Options12) == 12 && sizeof(FeatureLevels) == 24, "D3D12 feature ABI");
static_assert(sizeof(ResourceDesc) == 56 && sizeof(HeapProperties) == 20, "D3D12 resource ABI");
static_assert(sizeof(BufferBarrier) == 40 && sizeof(BarrierGroup) == 16, "Enhanced Barriers ABI");

extern "C" {
__declspec(dllimport) Handle __stdcall LoadLibraryW(const wchar_t *);
__declspec(dllimport) void *__stdcall GetProcAddress(Handle, const char *);
__declspec(dllimport) U32 __stdcall GetModuleFileNameW(Handle, wchar_t *, U32);
__declspec(dllimport) U32 __stdcall GetLastError();
__declspec(dllimport) Handle __stdcall GetStdHandle(U32);
__declspec(dllimport) I32 __stdcall WriteFile(Handle, const void *, U32, U32 *, void *);
__declspec(dllimport) I32 __stdcall WideCharToMultiByte(U32, U32, const wchar_t *, I32, char *, I32, const char *, I32 *);
__declspec(dllimport) void __stdcall Sleep(U32);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(U32);
void *memset(void *dst, int value, Size size) {
    auto *p = static_cast<volatile unsigned char *>(dst);
    for (Size i = 0; i < size; ++i) p[i] = static_cast<unsigned char>(value);
    return dst;
}
void *memcpy(void *dst, const void *src, Size size) {
    auto *d = static_cast<unsigned char *>(dst);
    auto *s = static_cast<const unsigned char *>(src);
    for (Size i = 0; i < size; ++i) d[i] = s[i];
    return dst;
}
}

static const Guid IID_Factory1 = {0x770aae78,0xf26f,0x4dba,{0xa8,0x29,0x25,0x3c,0x83,0xd1,0xb3,0x87}};
static const Guid IID_Device = {0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};
static const Guid IID_Allocator = {0x6102dee4,0xaf59,0x4b09,{0xb9,0x99,0xb4,0x4d,0x73,0xf0,0x9b,0x24}};
static const Guid IID_CommandList = {0x5b160d0f,0xac1b,0x4185,{0x8b,0xa8,0xb3,0xae,0x42,0xa5,0xa4,0x55}};
static const Guid IID_CommandList7 = {0xdd171223,0x8b61,0x4769,{0x90,0xe3,0x16,0x0c,0xcd,0xe4,0xe2,0xc1}};
static const Guid IID_Queue = {0x0ec870a6,0x5d7e,0x4c22,{0x8c,0xfc,0x5b,0xaa,0xe0,0x76,0x16,0xed}};
static const Guid IID_Resource = {0x696442be,0xa72e,0x4059,{0xbc,0x79,0x5b,0x5c,0x98,0x04,0x0f,0xad}};
static const Guid IID_Fence = {0x0a753dcf,0xc4d8,0x4b91,{0xad,0xf6,0xbe,0x5a,0x60,0xd9,0x5a,0x76}};

template<typename Fn> static Fn method(Com *p, U32 slot) { return reinterpret_cast<Fn>(p->v[slot]); }
static void release(Com *p) { if (p) method<U32 (__stdcall *)(Com *)>(p, 2)(p); }
static void text(const char *s) {
    U32 n = 0, written = 0;
    while (s[n]) ++n;
    WriteFile(GetStdHandle(static_cast<U32>(-11)), s, n, &written, nullptr);
}
static void number(U64 v) {
    char s[32]; U32 i = 31; s[i] = 0;
    do { s[--i] = '0' + v % 10; v /= 10; } while (v);
    text(s + i);
}
static void hex(U32 v) {
    char s[11] = "0x00000000";
    for (U32 i = 0; i < 8; ++i) s[9-i] = "0123456789abcdef"[(v >> (4*i)) & 15];
    text(s);
}
static void wide(const wchar_t *s) {
    char utf8[2048];
    I32 n = WideCharToMultiByte(65001, 0, s, -1, utf8, sizeof(utf8), nullptr, nullptr);
    if (n > 0) text(utf8); else text("<UTF-16 conversion failed>");
}
static void hr(const char *name, HR value) { text(name); text("="); hex(static_cast<U32>(value)); text("\n"); }
static void module(const char *name, Handle h) {
    wchar_t path[1024]; text(name); text("=");
    if (h && GetModuleFileNameW(h, path, 1024)) wide(path); else text("<not loaded>");
    text("\n");
}

// 4 KiB upload -> GPU default buffer -> readback, with one copy-write to
// copy-read Enhanced Buffer Barrier. Checks only this specific path; even a
// passing result does not validate texture layouts, UAV hazards, split barriers,
// multi-queue synchronization, render passes, or FH6 compatibility.
static bool copy_smoke(Com *device) {
    Com *queue = nullptr, *allocator = nullptr, *list = nullptr, *list7 = nullptr;
    Com *upload = nullptr, *gpu = nullptr, *readback = nullptr, *fence = nullptr;
    bool pass = false;
    QueueDesc q = {0, 0, 0, 0};
    ResourceDesc desc = {1, 0, 4096, 1, 1, 1, 0, 1, 0, 1, 0};
    auto create_buffer = [&](U32 heap_type, U32 state, Com **out) {
        HeapProperties heap = {heap_type, 0, 0, 1, 1};
        return method<HR (__stdcall *)(Com *, const HeapProperties *, U32, const ResourceDesc *, U32, const void *, const Guid *, Com **)>(device, 27)(device, &heap, 0, &desc, state, nullptr, &IID_Resource, out);
    };
    auto need = [&](const char *step, HR h) { hr(step, h); return h >= 0; };
    if (!need("copy_smoke.CreateCommandQueue", method<HR (__stdcall *)(Com *, const QueueDesc *, const Guid *, Com **)>(device, 8)(device, &q, &IID_Queue, &queue))) goto cleanup;
    if (!need("copy_smoke.CreateCommandAllocator", method<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(device, 9)(device, 0, &IID_Allocator, &allocator))) goto cleanup;
    if (!need("copy_smoke.CreateCommandList", method<HR (__stdcall *)(Com *, U32, U32, Com *, Com *, const Guid *, Com **)>(device, 12)(device, 0, 0, allocator, nullptr, &IID_CommandList, &list))) goto cleanup;
    if (!need("copy_smoke.QueryCommandList7", method<HR (__stdcall *)(Com *, const Guid *, Com **)>(list, 0)(list, &IID_CommandList7, &list7))) goto cleanup;
    // GENERIC_READ for UPLOAD, COMMON for DEFAULT, COPY_DEST for READBACK.
    if (!need("copy_smoke.CreateUpload", create_buffer(2, 0xac3, &upload))) goto cleanup;
    if (!need("copy_smoke.CreateDefault", create_buffer(1, 0, &gpu))) goto cleanup;
    if (!need("copy_smoke.CreateReadback", create_buffer(3, 0x400, &readback))) goto cleanup;
    if (!need("copy_smoke.CreateFence", method<HR (__stdcall *)(Com *, U64, U32, const Guid *, Com **)>(device, 36)(device, 0, 0, &IID_Fence, &fence))) goto cleanup;
    {
        void *mapped = nullptr; Range no_read = {0, 0};
        if (!need("copy_smoke.MapUpload", method<HR (__stdcall *)(Com *, U32, const Range *, void **)>(upload, 8)(upload, 0, &no_read, &mapped))) goto cleanup;
        for (U32 i = 0; i < 1024; ++i) static_cast<U32 *>(mapped)[i] = (i * 2654435761u) ^ 0xa5a55a5au;
        Range wrote = {0, 4096};
        method<void (__stdcall *)(Com *, U32, const Range *)>(upload, 9)(upload, 0, &wrote);
        method<void (__stdcall *)(Com *, Com *, U64, Com *, U64, U64)>(list, 15)(list, gpu, 0, upload, 0, 4096);
        BufferBarrier barrier = {0x200, 0x200, 0x400, 0x800, gpu, 0, 4096};
        BarrierGroup group = {2, 1, &barrier}; // official BUFFER type = 2.
        text("copy_smoke.Barrier=calling copy-write to copy-read\n");
        method<void (__stdcall *)(Com *, U32, const BarrierGroup *)>(list7, 80)(list7, 1, &group);
        method<void (__stdcall *)(Com *, Com *, U64, Com *, U64, U64)>(list, 15)(list, readback, 0, gpu, 0, 4096);
        if (!need("copy_smoke.Close", method<HR (__stdcall *)(Com *)>(list, 9)(list))) goto cleanup;
        method<void (__stdcall *)(Com *, U32, Com *const *)>(queue, 10)(queue, 1, &list);
        if (!need("copy_smoke.Signal", method<HR (__stdcall *)(Com *, Com *, U64)>(queue, 14)(queue, fence, 1))) goto cleanup;
        bool completed = false;
        for (U32 attempt = 0; attempt < 500; ++attempt) {
            U64 value = method<U64 (__stdcall *)(Com *)>(fence, 8)(fence);
            if (value == ~static_cast<U64>(0)) { text("copy_smoke.fence=device removed\n"); goto cleanup; }
            if (value >= 1) { completed = true; break; }
            Sleep(10);
        }
        if (!completed) { text("copy_smoke.fence=timeout after 5 seconds\n"); goto cleanup; }
        Range read_range = {0, 4096}; mapped = nullptr;
        if (!need("copy_smoke.MapReadback", method<HR (__stdcall *)(Com *, U32, const Range *, void **)>(readback, 8)(readback, 0, &read_range, &mapped))) goto cleanup;
        pass = true;
        for (U32 i = 0; i < 1024; ++i) if (static_cast<U32 *>(mapped)[i] != ((i * 2654435761u) ^ 0xa5a55a5au)) { pass = false; break; }
        method<void (__stdcall *)(Com *, U32, const Range *)>(readback, 9)(readback, 0, &no_read);
    }
cleanup:
    hr("copy_smoke.DeviceRemovedReason", method<HR (__stdcall *)(Com *)>(device, 37)(device));
    text("copy_smoke.result="); text(pass ? "PASS\n" : "FAIL\n");
    text("copy_smoke.conformance=NOT_TESTED\n");
    release(list7); release(list); release(allocator); release(queue);
    release(fence); release(upload); release(gpu); release(readback);
    return pass;
}

static void probe_device(Com *device) {
    auto check = method<HR (__stdcall *)(Com *, U32, void *, U32)>(device, 13);
    U32 levels[] = {0xc200, 0xc100, 0xc000, 0xb100, 0xb000};
    FeatureLevels feature = {5, levels, 0};
    HR h = check(device, 2, &feature, sizeof(feature)); hr("FEATURE_LEVELS.hresult", h);
    if (h >= 0) { text("FEATURE_LEVELS.maximum="); hex(feature.MaxSupported); text("\n"); }
    U32 shader = 0, requested = 0;
    for (U32 sm = 0x69; sm >= 0x60; --sm) {
        shader = sm; h = check(device, 7, &shader, sizeof(shader));
        if (h >= 0) { requested = sm; break; }
    }
    hr("SHADER_MODEL.hresult", h);
    if (h >= 0) { text("SHADER_MODEL.highest="); hex(shader); text(" requested="); hex(requested); text("\n"); }
    Options12 options = {-1, -1, -1};
    h = check(device, 41, &options, sizeof(options)); hr("OPTIONS12.hresult", h);
    text("OPTIONS12.query_size=12 feature_id=41\n");
    if (h >= 0) {
        text("OPTIONS12.EnhancedBarriersSupported="); number(options.EnhancedBarriersSupported != 0); text("\n");
        text("OPTIONS12.RelaxedFormatCastingSupported="); number(options.RelaxedFormatCastingSupported != 0); text("\n");
    }
    if (h >= 0 && options.EnhancedBarriersSupported) copy_smoke(device);
    else text("copy_smoke.result=SKIPPED because EnhancedBarriersSupported was not successfully reported true\n");
}

extern "C" __declspec(noreturn) void mainCRTStartup() {
    text("D3D12_PROBE_VERSION=1\nABI=Windows x64\nThis capability query and copy smoke test are not conformance tests.\n");
    Handle dxgi = LoadLibraryW(L"dxgi.dll"), d3d12 = LoadLibraryW(L"d3d12.dll");
    module("DXGI.module", dxgi); module("D3D12.module", d3d12);
    if (!dxgi || !d3d12) { text("DLL_LOAD.error="); hex(GetLastError()); text("\n"); ExitProcess(2); }
    auto create_factory = reinterpret_cast<HR (__stdcall *)(const Guid *, Com **)>(GetProcAddress(dxgi, "CreateDXGIFactory1"));
    auto create_device = reinterpret_cast<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(GetProcAddress(d3d12, "D3D12CreateDevice"));
    if (!create_factory || !create_device) { text("EXPORTS.error=missing required export\n"); ExitProcess(3); }
    Com *factory = nullptr; HR h = create_factory(&IID_Factory1, &factory); hr("CreateDXGIFactory1", h);
    if (h < 0) ExitProcess(4);
    U32 successes = 0;
    for (U32 index = 0; index < 16; ++index) {
        Com *adapter = nullptr;
        h = method<HR (__stdcall *)(Com *, U32, Com **)>(factory, 12)(factory, index, &adapter);
        if (static_cast<U32>(h) == 0x887a0002) break;
        if (h < 0) { hr("EnumAdapters1.error", h); break; }
        text("\nADAPTER.index="); number(index); text("\n");
        AdapterDesc1 desc = {};
        h = method<HR (__stdcall *)(Com *, AdapterDesc1 *)>(adapter, 10)(adapter, &desc); hr("GetDesc1", h);
        if (h >= 0) {
            text("ADAPTER.description="); wide(desc.Description); text("\nADAPTER.vendor="); hex(desc.VendorId);
            text(" device="); hex(desc.DeviceId); text(" dedicated_vram_MiB="); number(desc.DedicatedVideoMemory / 1048576); text("\n");
        }
        Com *device = nullptr;
        h = create_device(adapter, 0xb000, &IID_Device, &device); hr("D3D12CreateDevice.FL11_0", h);
        if (h >= 0 && device) {
            auto print = reinterpret_cast<void (__stdcall *)(const char *)>(GetProcAddress(LoadLibraryW(L"kernel32.dll"), "OutputDebugStringA"));
            if (print) print("RHI AMD_RESEARCH_DIAGNOSTIC_CONTROL_ONLY");
            ++successes; probe_device(device); release(device);
        }
        release(adapter);
    }
    release(factory);
    text("\nD3D12.device_creation_successes="); number(successes); text("\n");
    ExitProcess(successes ? 0 : 5);
}
