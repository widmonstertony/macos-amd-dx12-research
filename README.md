# Intel / AMD macOS DX12 Research

**中文** · [English](README.en.md)

面向 Intel Mac / AMD GPU 的开源 D3D12 → Vulkan → Metal 兼容研究，以正版 Windows Steam《剑星》为主要复现案例。欢迎协助着色器转换、GPU 同步、缓存、Wine 窗口与性能分析。

> **实验项目，尚未可玩。** 2026-10-25 的原应用宝 Wine / 正常 Steam 场景对照：v26 约 6.57 FPS，减少诊断开销后 v28 约 7.92 FPS，精确描述符脏区间后 v29 约 9.69 FPS；v30 资源表微优化约 9.63 FPS，未进一步提高整帧性能。画面可正常显示，但性能、攻击稳定性及 FSR3 仍未达到发布标准。下载包是开发者测试包，**不是能让所有 Mac 直接玩《剑星》的成品**。

当前 CPU 瓶颈与实测见 [2026-10-25 位图修复](docs/CPU-DIRTY-BITMAP-2026-10-25.md) 和 [诊断开销修复](docs/DIAGNOSTIC-CPU-FIX-2026-10-25.md)。历史源码、精确候选哈希与实测限制见 [2026-10-23 检查点](docs/CHECKPOINT-2026-10-23.md) 和 [完整研究状态](docs/STATE.md)。公开下载包仍是实验基线，尚不承诺《剑星》可玩。

当前 v36 以 v35 行为为基线，补齐已知 D3D12 请求、资源、编译、队列、GPU 与呈现诊断。构建、自有 CPU/GPU 和原 Wine 回归通过，**尚无实际游戏帧率改善结论**。游戏由用户操作；采样可在同一进程内重新开启。历史覆盖见 [记录](docs/STUTTER-COVERAGE-2026-10-25.md)。

同一轮诊断计划：先覆盖已知提交、资源、编译、GPU 和呈现路径，再由用户开一次游戏；采样可在原进程内重开。见 [中文说明](docs/ONE-RUN-DIAGNOSTICS.zh-CN.md)。v36 公开内容为源码与诊断工具；现有下载包未替换，不代表可玩性结论。

## 下载与测试

[最新诊断版本下载](https://github.com/widmonstertony/macos-amd-dx12-research/releases/tag/v0.2.0-watchdog-diagnostic) · [测试说明](docs/TESTING.zh-CN.md) · [已知问题](docs/KNOWN_ISSUES.zh-CN.md) · [参与贡献](CONTRIBUTING.md)

实验包包含可移动目录的研究运行库、原生 GPU 读回探针、环境检查和校验工具。不包含游戏、Steam、应用宝 / Apple 引擎、存档或登录状态。探针独立运行；游戏集成仍需要正版游戏和兼容 Wine 环境，目前不提供一键游戏安装器。

```sh
tar -xzf amd-dx12-macos-x86_64-v0.1.0-experimental.tar.gz
cd amd-dx12-macos-x86_64-v0.1.0-experimental
python3 runtime.py verify
python3 runtime.py doctor
python3 runtime.py test --stress
```

需要 Python 3 和 x86_64 macOS。唯一实际验证过的 GPU / 系统组合是 Radeon Pro 5600M / macOS 26.7.1。欢迎其他 AMD GPU 提交实验结果，但不承诺兼容。包内工具不会修改 Wine、Steam、游戏资产或现有缓存。

## 实现与范围

```mermaid
flowchart LR
  A[正版 Windows Steam 游戏 / D3D12] --> B[vkd3d-proton / DXIL-DXBC 转换]
  B --> C[Vulkan / SPIR-V]
  C --> D[MoltenVK + SPIRV-Cross / MSL]
  D --> E[Metal / macOS AMD 驱动]
  F[Wine 窗口与输入] -.-> A
```

- 固定上游版本与修改见 [UPSTREAM.json](docs/UPSTREAM.json)、`patches/`。
- 工作涉及部分越界 / 空资源保护、设备地址和图形阶段、3D 切片、资源绑定、分片缓存及多队列诊断，采用真实 GPU 输出验证。
- 私有保护约定不是完整 Robustness2、Vulkan CTS 或 DX12 合规声明；没有伪报硬件功能。
- Wine 请求编号修复只针对审计过的应用宝引擎，不能随意替换其他版本模块。
- 未修改或分发 Apple / 应用宝闭源引擎，不提供 DRM 绕过；游戏测试使用正常正版 Steam 启动。

## 证据与限制

| 检查 | 结果 | 不能据此得出的结论 |
|---|---|---|
| 单队列 / 三独立队列读回 | 每模式 2,048 轮、8,388,608 words、0 差异 | 游戏全部同步正确 |
| 计算 / 图形保护探针 | 有 GPU 读回及像素核对 | 完整 DX12 / Robustness2 合规 |
| 计算归档 | 独立 Wine 探针 33 次严格命中 | 游戏不再重复编译 |
| 正常 Steam 启动和场景进入 | 曾达到；帧率和画面异常 | 《剑星》已稳定可玩 |
| 历史游戏故障回放 | 第 14 个 encoder 后 watchdog，后续确认累计几何工作是原因之一 | 该 draw 是所有运行中固定根因 |
| 当前 CPU 场景对照 | v26 6.57 → v28 7.92 → v29 9.69 FPS；缓存保留 | 已正常可玩，或 FSR3 已通过 |

历史故障见 [2026-10-23 检查点](docs/CHECKPOINT-2026-10-23.md)，后续诊断和修复见 [2026-10-25 记录](docs/DIAGNOSTICS-2026-10-25.md)。当前重点是 CPU 资源绑定与缓存重建成本；所有性能结论以真实游戏测量为准。

## 源码、构建和恢复

`workspace/` 保留研究源码结构；历史脚本和证据包含原机器路径，不是公众入口。`public/` 是可移动实验包工具。`artifacts/runtime-20261020.tar.gz` 为历史恢复包，代理内有旧绝对路径，不能直接作为公众安装包部署。

```sh
python3 scripts/restore_snapshot.py --verify-only
python3 scripts/restore_snapshot.py --target /新的空目录/research-restored
bash scripts/build_native.sh /恢复后的研究根目录
```

[恢复说明](docs/RESTORE.md) · [English recovery guide](docs/RESTORE.en.md) · [双语构建说明](docs/BUILD.md)。文件恢复和 CMake 配置已验证，完整跨机器构建与可玩性没有被验证。

## 许可与致谢

上游许可保持不变，不是把全部代码统一改成 MIT。新增公开工具和文档为 MIT，第三方衍生代码沿用各自许可。详见 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 `LICENSES/`。发布时提供对应源码及固定 Wine 基线源码。

感谢上游项目和 fxgl/steamac 的公开研究。Apple Silicon 试玩版先例不代表此 Intel / AMD 正式版已通过。项目与游戏发行商、Apple、腾讯、Valve 无隶属关系。
