# Intel / AMD macOS DX12 Research

**中文** · [English](README.en.md)

面向 Intel Mac / AMD GPU 的开源 D3D12 → Vulkan → Metal 兼容研究，以正版 Windows Steam《剑星》为主要复现案例。欢迎协助着色器转换、GPU 同步、缓存、Wine 窗口与性能分析。

> **实验项目，尚未可玩。** 曾进入可操作场景，但仍有严重低帧率、蓝色矩形遮挡和 GPU 超时；最近的完整游戏回放失败。下载包是开发者测试包，**不是能让所有 Mac 直接玩《剑星》的成品**。探针通过不代表游戏兼容、FSR3 或其他 DX12 游戏可用。

最新源码、精确候选哈希与实测限制见 [当前研究状态](docs/STATE.md)。公开下载包仍是实验基线，尚不承诺《剑星》可玩。

## 下载与测试

[实验版本下载](https://github.com/widmonstertony/macos-amd-dx12-research/releases/tag/v0.1.0-experimental) · [测试说明](docs/TESTING.zh-CN.md) · [已知问题](docs/KNOWN_ISSUES.zh-CN.md) · [参与贡献](CONTRIBUTING.md)

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
| 最新游戏完整回放 | 计算 / 图形队列 GPU timeout | 已确定具体致错着色器或驱动 |

详细事实见 [STATE.md](docs/STATE.md)。优先任务是定位最早未完成的图形信号生产者、原生提交顺序、资源声明开销和蓝色遮挡。不能仅修改 feature bit 或只验证 device 创建。

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
