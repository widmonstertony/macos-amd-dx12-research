# FH6 Wine compatibility and remaining renderer gaps / 当前状态

**Not playable.** The original Steam client launches the existing installation through the short `C:\FH` library. The app-local Wine/AGS changes crossed the prior FHE21 null-read location, but the user then confirmed the blocking compatibility dialog FH201, FH204, FH206, plus missing driver-version warning FH302. No capability promotion or another game restart was used to hide it.

## Implemented

* Missing `GetIntegratedDisplaySize`: app-local import fallback matching Wine c68ed23672 / Highball patch 0017 (`E_NOTIMPL`, output untouched). A real native export, if present, stays unchanged. Only FH6 or the exact owned control basename is affected. Game executable files and the Tencent engine are not patched.
* AGS base services: the vendor library is preferred. Only `AGS_NO_AMD_DRIVER_INSTALLED` invokes an owned AGS 6.3 base implementation, using actual DXGI names, PCI IDs and memory sizes, valid context lifetimes, and D3D12CreateDevice with the caller's feature-level request unchanged. No NVIDIA identity, Windows AMD driver version, architecture/clock estimates or proprietary extension support is invented.
* All 37 original vendor export ordinals are preserved. Unwrapped calls retain vendor forwarding; this is scoped to FH6 and does not claim a complete general AGS replacement. The private byte-identical vendor runtime dependency is not redistributed.
* A bounded access-violation observer logs CPU addresses/module offsets and returns `EXCEPTION_CONTINUE_SEARCH`, without suppressing faults. GPU and Wine diagnostic paths are scoped to the game.

The original diagnostic run reproduced FHE21 after two vendor AGS failures with invalid/empty outputs, at the same game module offset as the original report. With base compatibility enabled, both initializations produced valid contexts and the actual game created two D3D12 devices at FL11_0 without that prior access violation. This is progress, not a gameplay result.

## Measured boundaries

The real-GPU AGS control passed: genuine Radeon Pro 5600M identity, a real D3D12 device, and 64 GPU copy/readback values with zero mismatches. The negative FL12_0 control is retained. A separate earlier control accidentally selected builtin Wine D3D12; its failure is preserved and corrected through app-specific native DLL configuration, not counted as a renderer failure.

Actual game queries received FL11_0 / SM6.0, TiledResourcesTier 0, ResourceBindingTier 3, ResourceHeapTier 1 and ROV support. Querying shader-model maximum 6.10 does **not** by itself establish a 6.10 minimum. The official [Forza FAQ](https://steamcommunity.com/app/2483190/discussions/5/839502231284876908/) categorizes the FH20x codes as missing required DX12 features; it does not publish a unique per-code feature mapping. Do not assign one without additional evidence.

The current source prevents full FL11_1 when output-merger logic operations are unavailable. Complete FL12_0 additionally needs at least tiled resources tier 2, suitable binding and typed UAV-load support. Native MoltenVK does not currently implement the required sparse-resource contract on this route. This is a major renderer feature gap, not something Wine API stubs provide.

SM6.2 promotion in the current vkd3d code requires float32 denorm preservation and flush controls. The local MoltenVK properties expose neither. The owned `float_denorm_controls_gpu.mm` tested 16 actual GPU arithmetic cases in each of three public Metal modes: legacy fastMath off, fastMath on, and Safe + Precise with invariant preservation. **Every mode had 14 preservation mismatches and zero flush-to-zero mismatches.** This rules out those tested public compiler settings as a simple denorm-preservation fix. It does not establish impossibility of software lowering or full floating-point conformance. Full float emulation, sparse mapping and logic-operation semantics require separate implementation and performance validation; do not merely raise capability bits.

See [measured aggregate data](2026-10-27-float-control-gpu-result.json). No game shaders, protected executable contents or private login material are included.

## References and recovery

Architecture references: [Highball patch 0017](https://github.com/gauthierpiarrette/highball-engine/blob/main/patches/0017-kernelbase-getintegrateddisplaysize-stub.patch), [Proton AGS](https://github.com/ValveSoftware/wine/blob/proton_11.0/dlls/amd_ags_x64/amd_ags_x64_main.c), [AMD public AGS header](https://github.com/GPUOpen-LibrariesAndSDKs/AGS_SDK/blob/master/ags_lib/inc/amd_ags.h). The header retains its MIT notice; the owned DXGI base adapter is LGPL-2.1-or-later. Apple's closed binaries remain unchanged.

Build app-local compatibility with `tools/build_fh6_wine_compat.py` in the restored research tree. To undo it, first exit the game, restore only the overlay's amd_ags_x64.dll as a link to the untouched original, and remove only the new FH6 AGS DLL override. Original assets and caches must remain. Source commits ec76454 and 7ded0ff preserve the display/diagnostic phase and the real base-service implementation.

## 中文

启动阶段的 Wine/AGS 修复已经接入，并在原 Steam 启动中越过此前 FHE21 空指针位置。真实 GPU 拷贝读回通过，但本次游戏仍被 FH201、FH204、FH206 拒绝，另有 FH302 驱动版本警告，尚未可玩。当前后端报告 FL11_0／SM6.0，稀疏资源等级为 0。

新增 GPU 实测排除了已测三种公开 Metal 编译模式作为非正规数保留的简单修复：每种 16 项中有 14 项保留语义不符。若继续补齐，已进入真实图形后端的软件浮点、稀疏资源及逻辑操作实现，不能靠添加 Wine DLL、修改显卡名称或提高功能位解决。具体错误码与特性尚未一一对应，未宣称硬件永久无法实现，也未宣称软件模拟一定足够快。本轮没有为绕过警告而重启游戏。
