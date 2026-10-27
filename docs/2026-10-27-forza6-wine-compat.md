# App-local Wine API backport for FH6

This experiment combines the existing qualified vkd3d-proton/MoltenVK renderer with the behavior of Wine c68ed23672 / Highball patch 0017. It leaves the original Tencent engine, other apps and original game executable unchanged. The main process import slot for the one missing `GetIntegratedDisplaySize` API receives an app-local `E_NOTIMPL` implementation, preserving the output argument. It does nothing if kernelbase already exports that function. Scope is the exact FH6 executable basename or the owned control executable. No game file on disk is patched.

The app-local AMD AGS DLL forwards all 37 vendor exports, preserving ordinals, to a byte-identical `amd_ags_real.dll` runtime dependency. The three imported initialization/device/cleanup calls log their actual results unchanged. A bounded first-chance access-violation observer logs CPU fault addresses and module offsets, then returns `EXCEPTION_CONTINUE_SEARCH`. It does not suppress errors or claim unsupported driver extensions. No GPU identity changes are applied.

Build with `tools/build_fh6_wine_compat.py` in the restored research tree. It needs the user's installed AGS runtime; proprietary binaries are neither committed nor redistributed. The owned control passed in the original Tencent Wine session: exact E_NOTIMPL, sentinel output unchanged, null output accepted, and the forwarded version matches the original AGS DLL. On this host the original AGS initialization returns code 6 with a null context and zero GPUs; it is preserved, not converted to success. Actual game diagnosis is pending.

References: [Highball patch 0017](https://github.com/gauthierpiarrette/highball-engine/blob/main/patches/0017-kernelbase-getintegrateddisplaysize-stub.patch), [AMD AGS SDK header](https://github.com/GPUOpen-LibrariesAndSDKs/AGS_SDK/blob/master/ags_lib/inc/amd_ags.h). The AMD header retains its complete MIT license notice. The API behavior backport does not copy or edit Apple's binaries.

此实验只对地平线进程补缺失的 Windows API，图形路径保持现有开源 DX12 转换。原 AGS 调用结果照实转发，故障观察器不吞异常。控制程序通过不代表游戏已兼容。恢复时，游戏退出后把独立启动目录的 amd_ags_x64.dll 恢复为指向原安装文件的链接，并移除该游戏的新增 AGS DLL 覆盖项即可；不要删除原游戏或缓存。

## Second phase: real base-service fallback

The diagnostic game run reproduced FHE21 immediately after two original `agsInitialize` calls returned `AGS_NO_AMD_DRIVER_INSTALLED`, with no valid AGS context. The observer recorded the same null-read address and module offset as the game's original crash report. The failed run was stopped without restarting Steam or its Wine server.

`fh6_ags_dxgi.h` now implements the AGS 6.3 base contract only when the original library reports that missing Windows driver. It obtains names, PCI IDs and memory sizes from the actual DXGI adapters, keeps opaque contexts alive until deinitialization, and delegates device creation to D3D12CreateDevice with the caller's feature-level request unchanged. AMD-only extension flags remain zero; unknown architecture/clock/driver metadata is not invented. Non-fallback contexts retain vendor forwarding. The implementation architecture follows [Proton's AGS module](https://github.com/ValveSoftware/wine/blob/proton_11.0/dlls/amd_ags_x64/amd_ags_x64_main.c); the new base adapter file is LGPL-2.1-or-later. This is scoped to FH6, not a complete general AGS replacement.

The real-GPU control passed: AMD Radeon Pro 5600M, PCI vendor 1002/device 7360, actual DXGI VRAM size, a real FL11_0 D3D12 device, and 64 GPU copy/readback values with zero mismatches. The FL12_0 negative control is retained: the current protected renderer does not expose that complete feature level. A first control also selected Wine's builtin D3D12; this is recorded and resolved using the same per-application native-module configuration as existing fixtures. It is not counted as a renderer failure.

The next normal original-Steam game launch crossed the prior AGS crash site. Its two base-service initializations now have valid contexts; two actual FL11_0 D3D12 device creations returned success. The game queried a maximum shader model of 6.10 and received the renderer's actual 6.0 ceiling. Its feature-level query also found no matching level in one requested list. This is a remaining renderer capability limitation, not evidence of playability. The request was not lowered or spoofed. Actual window confirmation is pending.

第二阶段已捕获原 FHE21 与 AMD Windows 驱动缺失返回值的关系，并用真实 DXGI 基础服务处理该分支。GPU 拷贝读回通过；实际游戏也越过了此前崩溃点，但当前图形层仍报告 FL11_0／SM6.0 的限制。没有据此宣称游戏已可玩，没有改功能位。
