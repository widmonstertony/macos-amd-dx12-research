// Concurrent D3D12 compute PSO creation and COM lifetime stress probe.
// Reuses the exact DXIL and ABI declarations from the established compute probe.
#define D3D12_COMPUTE_PROBE_NO_MAIN 1
#include "../../compute-probe/d3d12_compute_probe.cpp"

using ThreadProc = U32 (__stdcall *)(void *);
using CreateThreadFn = Handle (__stdcall *)(void *, Size, ThreadProc, void *, U32, U32 *);
using WaitForMultipleObjectsFn = U32 (__stdcall *)(U32, const Handle *, I32, U32);
using CloseHandleFn = I32 (__stdcall *)(Handle);

struct StressContext {
    Com *device;
    Com *root;
    U32 iterations;
    volatile U32 created;
    volatile U32 failed;
    volatile U32 refcountFailures;
};

static U32 __stdcall stressWorker(void *opaque) {
    auto *ctx = static_cast<StressContext *>(opaque);
    ComputePipelineDesc desc = {};
    desc.RootSignature = ctx->root;
    desc.Shader = {compute_shader_dxil, sizeof(compute_shader_dxil)};
    auto create = method<HR (__stdcall *)(Com *, const ComputePipelineDesc *, const Guid *, Com **)>(ctx->device, 11);
    for (U32 i = 0; i < ctx->iterations; ++i) {
        Com *pso = nullptr;
        HR result = create(ctx->device, &desc, &IID_PipelineState, &pso);
        if (result < 0 || !pso) {
            __atomic_fetch_add(&ctx->failed, 1u, __ATOMIC_RELAXED);
            continue;
        }
        __atomic_fetch_add(&ctx->created, 1u, __ATOMIC_RELAXED);
        auto addRef = method<U32 (__stdcall *)(Com *)>(pso, 1);
        auto releaseRef = method<U32 (__stdcall *)(Com *)>(pso, 2);
        U32 afterAdd[4];
        for (U32 j = 0; j < 4; ++j) afterAdd[j] = addRef(pso);
        for (U32 j = 0; j < 4; ++j) {
            U32 afterRelease = releaseRef(pso);
            if (afterRelease + 1 != afterAdd[3 - j]) {
                __atomic_fetch_add(&ctx->refcountFailures, 1u, __ATOMIC_RELAXED);
            }
        }
        releaseRef(pso);
    }
    return 0;
}

static bool makeRoot(Com *device, Handle d3d12, Com **root) {
    auto serialize = reinterpret_cast<HR (__stdcall *)(const RootSignatureDesc *, U32, Com **, Com **)>(
        GetProcAddress(d3d12, "D3D12SerializeRootSignature"));
    if (!serialize) return false;
    RootParameter parameters[2] = {};
    parameters[0].ParameterType = 4;
    parameters[0].Descriptor = {0, 0};
    parameters[1].ParameterType = 1;
    parameters[1].Constants = {0, 0, 2};
    RootSignatureDesc rootDesc = {2, parameters, 0, nullptr, 0};
    Com *blob = nullptr, *errors = nullptr;
    HR result = serialize(&rootDesc, 1, &blob, &errors);
    if (result >= 0 && blob) {
        const void *data = method<void *(__stdcall *)(Com *)>(blob, 3)(blob);
        Size bytes = method<Size (__stdcall *)(Com *)>(blob, 4)(blob);
        result = method<HR (__stdcall *)(Com *, U32, const void *, Size, const Guid *, Com **)>(device, 16)(device, 0, data, bytes, &IID_RootSignature, root);
    }
    release(errors);
    release(blob);
    return result >= 0 && *root;
}

extern "C" __declspec(noreturn) void mainCRTStartup() {
    text("D3D12_PSO_LIFETIME_STRESS_VERSION=1\n");
    Handle kernel = LoadLibraryW(L"kernel32.dll");
    Handle dxgi = LoadLibraryW(L"dxgi.dll");
    Handle d3d12 = LoadLibraryW(L"d3d12.dll");
    module("stress.DXGI.module", dxgi);
    module("stress.D3D12.module", d3d12);
    auto createThread = reinterpret_cast<CreateThreadFn>(GetProcAddress(kernel, "CreateThread"));
    auto waitAll = reinterpret_cast<WaitForMultipleObjectsFn>(GetProcAddress(kernel, "WaitForMultipleObjects"));
    auto closeHandle = reinterpret_cast<CloseHandleFn>(GetProcAddress(kernel, "CloseHandle"));
    auto createFactory = reinterpret_cast<HR (__stdcall *)(const Guid *, Com **)>(GetProcAddress(dxgi, "CreateDXGIFactory1"));
    auto createDevice = reinterpret_cast<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(GetProcAddress(d3d12, "D3D12CreateDevice"));
    if (!createThread || !waitAll || !closeHandle || !createFactory || !createDevice) ExitProcess(2);

    Com *factory = nullptr, *adapter = nullptr, *device = nullptr, *root = nullptr;
    if (createFactory(&IID_Factory1, &factory) < 0) ExitProcess(3);
    for (U32 i = 0; i < 16; ++i) {
        Com *candidate = nullptr;
        HR result = method<HR (__stdcall *)(Com *, U32, Com **)>(factory, 12)(factory, i, &candidate);
        if (result < 0) break;
        AdapterDesc1 desc = {};
        result = method<HR (__stdcall *)(Com *, AdapterDesc1 *)>(candidate, 10)(candidate, &desc);
        hr("stress.GetDesc1", result);
        text("stress.adapter="); wide(desc.Description); text(" vendor="); hex(desc.VendorId); text("\n");
        if (result >= 0 && desc.VendorId == 0x1002) { adapter = candidate; break; }
        release(candidate);
    }
    if (!adapter) { text("stress.error=no AMD adapter\n"); ExitProcess(4); }
    HR createResult = createDevice(adapter, 0xb000, &IID_Device, &device);
    hr("stress.D3D12CreateDevice", createResult);
    if (createResult < 0 || !makeRoot(device, d3d12, &root)) ExitProcess(4);

    constexpr U32 threadCount = 8;
    constexpr U32 iterations = 64;
    StressContext context = {device, root, iterations, 0, 0, 0};
    Handle threads[threadCount] = {};
    U32 launched = 0;
    for (; launched < threadCount; ++launched) {
        threads[launched] = createThread(nullptr, 0, stressWorker, &context, 0, nullptr);
        if (!threads[launched]) break;
    }
    U32 waitResult = launched ? waitAll(launched, threads, 1, 120000) : 0xffffffffu;
    // Worker contexts and device/root must outlive every worker even on timeout.
    if (waitResult != 0) {
        text("stress.wait_failed="); hex(waitResult); text("\n");
        ExitProcess(6);
    }
    for (U32 i = 0; i < launched; ++i) closeHandle(threads[i]);
    text("stress.threads="); number(launched);
    text(" iterations_per_thread="); number(iterations);
    text(" created="); number(context.created);
    text(" failed="); number(context.failed);
    text(" refcount_failures="); number(context.refcountFailures);
    text(" wait_result="); hex(waitResult); text("\n");
    HR removed = method<HR (__stdcall *)(Com *)>(device, 37)(device);
    hr("stress.DeviceRemovedReason", removed);
    bool pass = launched == threadCount && waitResult == 0 && context.created == threadCount * iterations && context.failed == 0 && context.refcountFailures == 0 && removed >= 0;
    if (pass) pass = compute_smoke(device, d3d12);
    text("stress.result="); text(pass ? "PASS\n" : "FAIL\n");
    release(root); release(device); release(adapter); release(factory);
    ExitProcess(pass ? 0 : 5);
}
