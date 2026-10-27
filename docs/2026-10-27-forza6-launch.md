# Forza Horizon 6 launch connection / 启动接入

Steam AppID 2483190 was read from the installed Steam manifest, not inferred from a title. Existing assets are linked into a separate research Steam install directory. Only the overlay uses the previously GPU-qualified vkd3d-proton/DXGI libraries; original game files and OptiScaler installation are retained. The normal licensed Windows Steam client owns launch and authentication. No direct executable launch is used.

Deferred original-asset protection now also recognizes ForzaHorizon6 and denies writes to its original installation, preserving the existing Stellar Blade restrictions. The qualified MoltenVK candidate is unchanged. Wine DLL overrides are scoped to forzahorizon6.exe (d3d12, d3d12core, dxgi = native,builtin).

启动清单来自现有 Steam 安装。研究目录通过链接复用游戏资产，原始游戏不改；图形库仅放在独立启动目录，原 OptiScaler 文件保留。原 Steam 正常验证和启动；没有直接执行游戏程序。保护规则增加地平线安装路径，未放宽剑星保护。此提交只表示接入准备完成，不代表已验证兼容或帧率。

Rollback: revert this commit for source. To disconnect, first exit the game and Steam, then remove only the imported research manifest/common link and the newly created overlay, and remove only the forzahorizon6.exe Wine AppDefaults DLL overrides. Do not delete original assets or caches. Rebuild the guard proxy from the reverted source using the existing v46 game profile.

## Short path / 短路径

The first actual game launch exited with “Installation path is too long.” An attempted F: mapping was not mounted by the already-running Wine session; Steam reported that library unavailable and showed its install dialog. No new game download was started.

Use a directory link under the existing C: drive instead: `C:\FH` points to the owned ForzaSteam research library, giving the short install path `C:\FH\steamapps\common\ForzaHorizon6`. Only the imported research manifest/common link moved; original assets and the existing Stellar Blade library path remain unchanged. The unused F: link was removed. Windows path visibility is checked before another normal Steam launch. Steam library metadata is edited only after its client exits normally; the Wine server is not restarted.

首次真实启动报告路径过长。新增 F: 映射未被当前 Wine 会话挂载，Steam 因而显示安装对话框，没有启动重新下载。改用现有 C: 下的 `C:\FH` 目录链接；先在 Windows 命名空间验证清单可见，再通过原 Steam 启动。原始文件与剑星路径保持不变。恢复时，在游戏与 Steam 退出后移除新增库配置和 `drive_c/FH` 链接即可。

## Actual result and Highball comparison / 实测与 Highball 对照

The C: library was recognized by the original Steam client. Steam launched `forzahorizon6.exe` from the short path normally. The game then exited with its FHE21 dialog. Selected local crash fields report `ACCESS_VIOLATION_READ` at address `0x10`, build 461691, before graphics adapter names were populated; graphics backend initialization has not been proven. This is not a playable result.

The [Highball recipe](https://github.com/gauthierpiarrette/highball-db/blob/main/recipes/games/forza-horizon-6.json) was checked after this error. It uses an x64 Wine 11 engine, D3DMetal 4, and NVIDIA adapter identity overrides; its actual test was Apple M4 on macOS 27. It documents an AMD-only initialization branch causing FHE21. That matches a possible failure category, not proof that our null read has the same caller. Apple's [Metal support table](https://support.apple.com/102894) lists Apple silicon for Metal 4 on Mac, so the complete verified recipe cannot be directly applied to an Intel Mac with Radeon Pro 5600M. It is not an AMD GPU backend replacement.

Highball's [patch 0017](https://github.com/gauthierpiarrette/highball-engine/blob/main/patches/0017-kernelbase-getintegrateddisplaysize-stub.patch) adds the upstream `GetIntegratedDisplaySize` stub returning `E_NOTIMPL`. The local game imports this name, and Tencent's installed kernelbase lacks it. This is a concrete additional API gap, not yet proof of the current exception's cause. No vendor-ID override, feature-bit override, proprietary binary modification or game-executable modification was applied.

实测已经越过路径过长，原 Steam 确实启动了游戏，但随后 FHE21 退出，尚未进入可玩画面。Highball 配方可用于研究 Windows API 和 AMD 初始化兼容性，不能把其 M4 的 D3DMetal 4 实测当成 5600M 支持。当前保存故障证据，停止无依据的参数重启。

The owned guard source change is commit `0dcc3e4`; revert that commit to restore the pre-Forza guard source, then rebuild its proxy using the existing v46 profile. Later commits only update these findings.
