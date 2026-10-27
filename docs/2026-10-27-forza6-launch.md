# Forza Horizon 6 launch connection / 启动接入

Steam AppID 2483190 was read from the installed Steam manifest, not inferred from a title. Existing assets are linked into a separate research Steam install directory. Only the overlay uses the previously GPU-qualified vkd3d-proton/DXGI libraries; original game files and OptiScaler installation are retained. The normal licensed Windows Steam client owns launch and authentication. No direct executable launch is used.

Deferred original-asset protection now also recognizes ForzaHorizon6 and denies writes to its original installation, preserving the existing Stellar Blade restrictions. The qualified MoltenVK candidate is unchanged. Wine DLL overrides are scoped to forzahorizon6.exe (d3d12, d3d12core, dxgi = native,builtin).

启动清单来自现有 Steam 安装。研究目录通过链接复用游戏资产，原始游戏不改；图形库仅放在独立启动目录，原 OptiScaler 文件保留。原 Steam 正常验证和启动；没有直接执行游戏程序。保护规则增加地平线安装路径，未放宽剑星保护。此提交只表示接入准备完成，不代表已验证兼容或帧率。

Rollback: revert this commit for source. To disconnect, first exit the game and Steam, then remove only the imported research manifest/common link and the newly created overlay, and remove only the forzahorizon6.exe Wine AppDefaults DLL overrides. Do not delete original assets or caches. Rebuild the guard proxy from the reverted source using the existing v46 game profile.

## Short path / 短路径

The first actual game launch exited with “Installation path is too long.” An attempted F: mapping was not mounted by the already-running Wine session; Steam reported that library unavailable and showed its install dialog. No new game download was started.

Use a directory link under the existing C: drive instead: `C:\FH` points to the owned ForzaSteam research library, giving the short install path `C:\FH\steamapps\common\ForzaHorizon6`. Only the imported research manifest/common link moved; original assets and the existing Stellar Blade library path remain unchanged. The unused F: link was removed. Windows path visibility is checked before another normal Steam launch. Steam library metadata is edited only after its client exits normally; the Wine server is not restarted.

首次真实启动报告路径过长。新增 F: 映射未被当前 Wine 会话挂载，Steam 因而显示安装对话框，没有启动重新下载。改用现有 C: 下的 `C:\FH` 目录链接；先在 Windows 命名空间验证清单可见，再通过原 Steam 启动。原始文件与剑星路径保持不变。恢复时，在游戏与 Steam 退出后移除新增库配置和 `drive_c/FH` 链接即可。
