# App-local Wine API backport for FH6

This experiment combines the existing qualified vkd3d-proton/MoltenVK renderer with the behavior of Wine c68ed23672 / Highball patch 0017. It leaves the original Tencent engine, other apps and original game executable unchanged. The main process import slot for the one missing `GetIntegratedDisplaySize` API receives an app-local `E_NOTIMPL` implementation, preserving the output argument. It does nothing if kernelbase already exports that function. Scope is the exact FH6 executable basename or the owned control executable. No game file on disk is patched.

The app-local AMD AGS DLL forwards all 37 vendor exports, preserving ordinals, to a byte-identical `amd_ags_real.dll` runtime dependency. The three imported initialization/device/cleanup calls log their actual results unchanged. A bounded first-chance access-violation observer logs CPU fault addresses and module offsets, then returns `EXCEPTION_CONTINUE_SEARCH`. It does not suppress errors or claim unsupported driver extensions. No GPU identity changes are applied.

Build with `tools/build_fh6_wine_compat.py` in the restored research tree. It needs the user's installed AGS runtime; proprietary binaries are neither committed nor redistributed. The owned control passed in the original Tencent Wine session: exact E_NOTIMPL, sentinel output unchanged, null output accepted, and the forwarded version matches the original AGS DLL. On this host the original AGS initialization returns code 6 with a null context and zero GPUs; it is preserved, not converted to success. Actual game diagnosis is pending.

References: [Highball patch 0017](https://github.com/gauthierpiarrette/highball-engine/blob/main/patches/0017-kernelbase-getintegrateddisplaysize-stub.patch), [AMD AGS SDK header](https://github.com/GPUOpen-LibrariesAndSDKs/AGS_SDK/blob/master/ags_lib/inc/amd_ags.h). The AMD header retains its complete MIT license notice. The API behavior backport does not copy or edit Apple's binaries.

此实验只对地平线进程补缺失的 Windows API，图形路径保持现有开源 DX12 转换。原 AGS 调用结果照实转发，故障观察器不吞异常。控制程序通过不代表游戏已兼容。恢复时，游戏退出后把独立启动目录的 amd_ags_x64.dll 恢复为指向原安装文件的链接，并移除该游戏的新增 AGS DLL 覆盖项即可；不要删除原游戏或缓存。
