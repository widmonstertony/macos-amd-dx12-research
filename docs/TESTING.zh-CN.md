# 实验包使用说明

[English](TESTING.en.md)

**尚未可玩：此包不是《剑星》一键兼容补丁。** 已知故障包括 GPU 超时、严重低帧率、蓝色矩形和长时间编译。它提供可运行的原生诊断以及研究运行库，供开发者协作，不保证游戏进入场景或持续可玩。

## 独立测试

需要 x86_64 macOS 和 Python 3。当前仅 Radeon Pro 5600M / macOS 26.7.1 有真实测试证据；其他组合未知。探针直接链接包内 MoltenVK，不需要另装 Vulkan Loader、Wine 或游戏。

解压发布包后，在其目录执行：

```sh
python3 runtime.py verify
python3 runtime.py doctor
python3 runtime.py test --stress
```

结果默认写入 `~/Library/Logs/AMDDX12Research/时间戳/`，也可使用 `test --stress --output /新的/结果目录`。`queue-probe` 做 64 轮 GPU 填充、复制、时间线同步和读回；`queue-burst-probe` 做 2,048 轮、每 16 轮才进行 CPU 等待和核对。分别运行默认和独立队列配置，核对实际数据，不只是创建设备。

默认选择真实 AMD GPU；多 GPU 时可使用 `AMD_DX12_DEVICE='5600M' python3 runtime.py test` 指定名称子串。它不模拟显卡，也不覆盖功能位。没有 AMD 或必要功能时会明确失败。

发布包使用 ad-hoc 签名，未公证。若 macOS 阻止下载文件，按系统“隐私与安全性”中的针对该文件的允许操作处理；不需要关闭 SIP、Gatekeeper 或其他系统保护。

## 包内运行库与游戏集成

- `lib/libMoltenVK.dylib`：当前开源 AMD 研究候选库。
- `windows/d3d12.dll`、`d3d12core.dll`：由对应 vkd3d-proton 源码构建的 DLL。
- `wine-version-specific/winemac.so`：只供审计过的应用宝服务版本使用，**不自动安装，不可替换任意 Wine 的同名模块**。
- 本包不包含 DXGI、Steam、游戏或应用宝 / Apple 引擎。必须自行提供与原环境匹配的 DXGI；不能把缺少的其他后端文件当成包已经补齐。

目前没有通用游戏部署 / 启动器；现有历史启动脚本绑定原研究环境。开发者集成前应构建隔离运行目录、重新生成加载代理与路径、确认精确模块版本，运行 GPU / Wine 呈现回归后，再通过正常正版 Steam 启动。参考仓库的 BUILD、RESTORE 和源码，不直接运行 Shipping.exe。

不要把历史恢复包中的旧代理复制进其他机器。实验包不会自动清缓存、改注册表、写入游戏目录或替换原引擎。用户手动集成需要自行保留原文件和存档。

## 分享结果

提交 GPU、macOS、提交 / 包版本及 `report.json`。分享前检查本机路径和个人信息；不要上传账号数据、完整转储或从游戏提取的源码 / 资产。探针通过只能说明被测试的同步和内存读回正确；不能写成游戏兼容报告。
