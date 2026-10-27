# Forza Horizon 6 launch connection / 启动接入

Steam AppID 2483190 was read from the installed Steam manifest, not inferred from a title. Existing assets are linked into a separate research Steam install directory. Only the overlay uses the previously GPU-qualified vkd3d-proton/DXGI libraries; original game files and OptiScaler installation are retained. The normal licensed Windows Steam client owns launch and authentication. No direct executable launch is used.

Deferred original-asset protection now also recognizes ForzaHorizon6 and denies writes to its original installation, preserving the existing Stellar Blade restrictions. The qualified MoltenVK candidate is unchanged. Wine DLL overrides are scoped to forzahorizon6.exe (d3d12, d3d12core, dxgi = native,builtin).

启动清单来自现有 Steam 安装。研究目录通过链接复用游戏资产，原始游戏不改；图形库仅放在独立启动目录，原 OptiScaler 文件保留。原 Steam 正常验证和启动；没有直接执行游戏程序。保护规则增加地平线安装路径，未放宽剑星保护。此提交只表示接入准备完成，不代表已验证兼容或帧率。

Rollback: revert this commit for source. To disconnect, first exit the game and Steam, then remove only the imported research manifest/common link and the newly created overlay, and remove only the forzahorizon6.exe Wine AppDefaults DLL overrides. Do not delete original assets or caches. Rebuild the guard proxy from the reverted source using the existing v46 game profile.

## Short path / 短路径

The first actual game launch exited with “Installation path is too long.” The separate library is therefore mapped as F: in the existing Wine prefix, with the Steam install path `F:\steamapps\common\ForzaHorizon6` (33 characters). Only the imported research manifest and common-directory link were moved into this library; original assets were not moved. Steam library metadata was edited only after its client exited normally. The previous Stellar Blade library path is unchanged.

首次真实启动明确报告安装路径过长。地平线使用单独的 F: Steam 游戏库，剑星原库路径保持不变；只移动研究目录中的清单和链接，未移动原游戏文件。恢复时可在游戏与 Steam 都退出后移除这条新增库配置和 Wine 的 f: 链接。
