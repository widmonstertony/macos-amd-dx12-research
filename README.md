# Intel / AMD macOS DX12 研究恢复快照

这是 2026-10-20 的代码和运行库备份。目标环境是 Intel Mac、AMD Radeon Pro 5600M、macOS，以及应用宝原来的 Wine / Windows Steam。**当前没有达到稳定可玩**：已进入过《剑星》场景，但仍有低帧率、蓝色矩形遮挡和 GPU 超时，最新版本正在正常 Steam 启动链中验证。

## 已保存的内容

- `workspace/open-game-stack-20261015/native-vendor/`：修改后的完整 MoltenVK、SPIRV-Cross 及固定版本依赖源码，包括保护规则、资源绑定、缓存、队列和超时诊断。
- `workspace/open-game-stack-20261015/vendor/`：修改后的 vkd3d-proton、DXIL/DXBC 转换器源码，以及窗口修复涉及的 Wine 模块和头文件。
- `workspace/` 中的原生 / Windows GPU 探针、构建和资格检查脚本、正常 Steam 启动脚本、原始游戏写保护配置及较早的 D3DMetal 研究源码。
- `patches/`：与固定上游源码比较生成的累计补丁；历史实验补丁留在对应 `evidence` 路径，**不能把全部历史补丁依次应用**。
- `artifacts/runtime-20261020.tar.gz`：当前及上一轮研究候选库、对应加载代理、窗口修复模块和本研究源码构建的 D3D12 DLL。逐文件哈希在 `snapshot-manifest.json`。
- `docs/STATE.md`、`docs/RESTORE.md`：最后状态、依赖边界、恢复步骤与已知问题。

游戏资产、Steam 客户端和登录信息、Wine 用户前缀、存档、Apple / 应用宝闭源引擎、原始崩溃转储以及大体积游戏着色器缓存未上传。原有本机缓存保留在原路径；此备份可恢复代码和列出的运行库，**不包含完整可迁移游戏环境**。

## 校验与恢复

```sh
python3 scripts/restore_snapshot.py --verify-only
python3 scripts/restore_snapshot.py --target /新的空目录/gptk-intel-research-restored
```

目标必须尚不存在，恢复脚本不会覆盖现有工作，不会启动游戏、切换运行库或修改应用宝环境。恢复后需要按照 [恢复说明](docs/RESTORE.md) 重新生成本机路径和加载代理；不要把原机器的绝对路径直接用于另一台机器。

## 构建与许可

原生编译入口是 `scripts/build_native.sh`。需要 macOS、Xcode Command Line Tools 和 CMake；独立 Windows 组件还需要 Meson / Ninja、固定 llvm-mingw 和 Wine 的 widl。恢复文件及构建配置已保存，完整跨机器重建不在此次备份验证范围内。

这是混合许可源码快照，不为整个仓库重新指定统一许可。各第三方源码原有 LICENSE / COPYING / NOTICE 文件保留；组件来源和固定版本见 [依赖清单](docs/UPSTREAM.json)。备份不代表完整 Vulkan / DX12 合规，也不代表 FSR3 或其他游戏已通过。
