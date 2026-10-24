# 2026-10-23 GPU watchdog checkpoint

## 中文

这是可恢复的研究检查点，**不是《剑星》可玩版本**。测试机器为 Intel MacBook Pro、AMD Radeon Pro 5600M、macOS 26.7.1；游戏始终通过应用宝原 Wine 和正版 Windows Steam 正常启动。

### 已经完成并实测

- D3D12 已实际经过 vkd3d-proton → Vulkan → MoltenVK/SPIRV-Cross → Metal；不是设备创建或功能位伪装。
- 正版 Steam 启动、着色器编译、主菜单、真实场景、UI、移动和攻击都曾到达。
- 缓冲区越界/空资源保护、设备地址、图形阶段、3D 切片、描述符快照、资源持有、分片原生管线缓存和 Wine 窗口协议均有真实 GPU 或原 Wine 对照。
- v12 用 MoltenVK listener-backed host wait 替换了无效的直接 shared-event 等待，并在主机等待满足后省略重复 Metal wait。正序、逆序和 consumer-first 双队列控制每组 1,024 轮、4,194,304 words，均为 0 差异。
- 原先的跨队列未满足 timeline wait 模式在最新失败缓冲中没有再次出现。

### 当前仍然失败的地方

v12 实际游戏在菜单/场景过渡前约为 6.5 FPS，进程物理占用约 7.6 GiB。随后队列 0 的一个 Metal command buffer 执行 **6,343.73 ms** 并触发 AMD macOS GPU watchdog：

- 22 个 render encoder；
- 1 个 compute encoder；
- 23 个 encoder 都记录为 completed；
- 失败缓冲本身没有 semaphore/event dependency；
- 现有“在 Vulkan command buffer 之间分段”已经启用，因此这批工作位于同一个 Vulkan command buffer 内，现有分段无法处理。

这说明当前问题不同于已修复的跨队列等待。仍需区分：某一次 draw/dispatch 异常慢、资源绑定放大了工作量，或同一 Vulkan command buffer 需要在安全的 encoder 边界继续分段。现有证据还不能指认具体着色器。

### 当前 v13 诊断轮

- Source candidate SHA-256: `11e1412231c0f6ad8d8e8d05414f0a50b56072da4b2a31b1bc09df918caf1781`
- Deployed diagnostic proxy SHA-256: `145c0febc0e1800fb5beaec2053995f6849697c2074380f0ba1463fe1e905202`
- 正常运行时不启用逐绘制追踪；外部 marker 仅开启最多 30 秒的有界工作环。
- 下一次目标不是再次确认“GPU timeout”，而是取得故障 command buffer 内具体 draw/dispatch、管线标签和顺序。

### 完成条件与待办

1. 精确定位 23 个 encoder 中导致 6.34 秒 command buffer 的 draw/dispatch。
2. 根据证据修复具体着色器/资源绑定，或实现保留 Vulkan 顺序、屏障、查询、可见性缓冲和同步语义的 command-buffer 内安全分段。
3. 用同一应用宝 Wine、原 Steam、原缓存验证菜单开关、场景移动、连续攻击和服装修理厂，不得出现 watchdog、黑屏或显存错误。
4. 测得持续可玩的实际帧率后，再恢复并分别验证 FSR3 超分和帧生成。两项目前都未通过。
5. 扩展到其他 DX12 游戏前，需要按游戏逐项验证；本项目还不是通用 DX12 驱动。

关键证据位于 [`release-evidence/watchdog-v13-20261023`](release-evidence/watchdog-v13-20261023/)。恢复包只包含开源候选、诊断代理和 Wine 模块，不包含游戏、Steam、应用宝/Apple 引擎、存档、凭据或着色器缓存。

## English

This is a recoverable research checkpoint, **not a playable Stellar Blade release**. The tested machine is an Intel MacBook Pro with Radeon Pro 5600M on macOS 26.7.1. Game tests use the existing Tencent/YYB Wine environment and the normal licensed Windows Steam launch.

The open path now reaches real D3D12 → Vulkan → MoltenVK/SPIRV-Cross → Metal execution, shader compilation, menus, the rendered scene, UI, movement, and attacks. v12 replaced an ineffective direct shared-event wait with MoltenVK's listener-backed host wait and removes the redundant Metal wait after the host condition is satisfied. Forward, reverse, and consumer-first two-queue controls each completed 1,024 rounds and checked 4,194,304 words with zero mismatches.

The game is still unplayable. Immediately before the latest failure it presented at about 6.5 FPS and used about 7.6 GiB of physical memory. A queue-0 Metal command buffer then ran for **6,343.73 ms** and hit the AMD macOS GPU watchdog. It contained 22 render encoders and one compute encoder; all encoder states were reported completed and the failing buffer had no semaphore/event dependency. Splitting between Vulkan command buffers was already enabled, so the remaining pathological work is inside one Vulkan command buffer.

The bounded v13 diagnostic profile is designed to capture the exact draw/dispatch, pipeline label, and order for one reproducing failure. Per-draw tracing is normally off and can be armed externally for at most 30 seconds. The next change must follow that evidence: repair a specific shader/resource binding or implement safe intra-command-buffer segmentation while preserving barriers, queries, visibility state, and synchronization.

Playability requires stable menus, scene traversal, repeated attacks, and the repair-shop path through the same Wine/Steam/cache state without watchdogs, black output, or video-memory errors. FSR3 upscaling and frame generation remain unvalidated and are separate acceptance requirements.

