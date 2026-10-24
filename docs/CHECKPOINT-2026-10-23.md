# 2026-10-23 GPU watchdog checkpoint

## 中文

这是可恢复的研究检查点，**不是《剑星》可玩版本**。测试机器为 Intel MacBook Pro、AMD Radeon Pro 5600M、macOS 26.7.1；游戏始终通过应用宝原 Wine 和正版 Windows Steam 正常启动。

### 已经完成并实测

- D3D12 已实际经过 vkd3d-proton → Vulkan → MoltenVK/SPIRV-Cross → Metal；不是设备创建或功能位伪装。
- 正版 Steam 启动、着色器编译、主菜单、真实场景、UI、移动和攻击均已到达，场景画面可以正确显示。
- 缓冲区越界/空资源保护、设备地址、图形阶段、3D 切片、描述符快照、资源持有、分片原生管线缓存和 Wine 窗口协议均有真实 GPU 或原 Wine 对照。
- listener-backed host wait 修复通过正序、逆序和 consumer-first 多队列 GPU 读回，先前的未满足跨队列 timeline wait 未在最新故障缓冲中重现。
- v14 首次把 watchdog 缩到一个 render encoder 内的 `e587 → aa294` 区间。
- v15 在一次连续攻击后的真实故障中取得完整工作环和 GPU 时间戳，把最新故障精确到第 14 个 encoder（从 1 开始）中的唯一 draw：
  - 管线：`obj=mvk_mesh_7bd461a7101cd12a_0; mesh=mvk_mesh_85ac7a829f241719_3; fs=mvk_mesh_aa294ecb68d4e8d6_4`
  - direct indexed draw：61,365 indices、1 instance、15 buffers、4 descriptor sets、7 vertex buffers、1,892,236 vertex bytes。
  - GPU 到达 `aa294` 管线边界，但没有到达下一条 `94c` 管线边界；两者之间只有上述 draw。
- v16 新增单次全 draw 诊断模式：只在外部 marker 武装且命令缓冲命中选择器时启用，容量由 128 增至 512，记录每个管线、每个 draw 和 encoder 尾部的 GPU 时间戳。正常运行时不开启。
- v16 原生 Radeon 对照实际渲染红色三角形，像素 BGRA 为 `[0,0,255,255]`，3 个时间戳包含 draw、无截断；新 MoltenVK 候选完成 8 次真实几何 draw、核对 512 像素、0 差异。

### 当前仍然失败的地方

v15 最新失败的 queue-0 Metal command buffer 执行 **7,208.93 ms**，包含 24 个 encoder（23 render、1 compute）。故障点已经精确到上述 61,365-index draw，但这还不能直接证明该 shader 永久有错：v14 的最后到达边界在前一个 `e587` 管线，v15 则已经越过 `e587` 并停在 `aa294`。故障边界跨运行移动，可能来自资源/描述符状态、同一提交内的累计工作，或 Metal/AMD 对该组合的异常执行。

基础性能也仍不合格。最近可见场景约为 6 FPS，持久瓶颈主要在 CPU 侧命令编码和资源绑定；偶发的 6–7 秒 GPU watchdog 是另一项灾难性故障。修复一个 draw 不等于自动达到可玩帧率。

应用宝 Wine 隔离探针在 Steam 占用共享 Wine 服务时没有进入候选库，60 秒超时；它被记录为启动环境失败，不能算 GPU 回归失败。原生 Metal 和直接 MoltenVK 的真实 GPU 验证已通过。

### 下一步和完成条件

1. 部署 v16 诊断候选，通过同一应用宝 Wine、原 Steam 和原缓存复现一次；一份日志应直接给出最后完成的 draw 和第一个未完成的 draw。
2. 若同一 61,365-index draw 稳定复现，采集其真实资源绑定、索引范围和 shader 输入，再修资源/着色器语义；不能跳过 draw。
3. 若故障点再次移动，实现同一 Vulkan command buffer 内按安全 encoder 边界分段，保留 barriers、queries、visibility buffer、render-pass store/load 和同步语义。
4. 验证菜单、场景移动、连续攻击和服装修理厂，不出现 watchdog、黑屏、显存错误或闪退。
5. 继续优化 CPU 命令编码/资源绑定，取得持续可玩的实际帧率。
6. 基础帧率稳定后，分别恢复并验证 FSR3 超分和帧生成；两项目前都未通过。

关键证据位于 [`release-evidence/watchdog-v14-20261023`](release-evidence/watchdog-v14-20261023/)、[`release-evidence/watchdog-v15-20261023`](release-evidence/watchdog-v15-20261023/) 和 [`release-evidence/all-draw-v16-20261023`](release-evidence/all-draw-v16-20261023/)。恢复包只包含开源候选、诊断代理和 Wine 模块，不包含游戏、Steam、应用宝/Apple 引擎、存档、凭据或着色器缓存。

## English

This is a recoverable research checkpoint, **not a playable Stellar Blade release**. The tested machine is an Intel MacBook Pro with Radeon Pro 5600M on macOS 26.7.1. Game tests use the existing Tencent/YYB Wine environment and the normal licensed Windows Steam launch.

The open path reaches real D3D12 → Vulkan → MoltenVK/SPIRV-Cross → Metal execution, shader compilation, menus, the correctly rendered scene, UI, movement, and attacks. The listener-backed host-wait repair still passes forward, reverse, and consumer-first multi-queue GPU readback controls, and the former unsatisfied cross-queue timeline-wait pattern is absent from the latest failing buffer.

The v15 capture precisely localized the latest watchdog. A queue-0 Metal command buffer ran for **7,208.93 ms** and contained 24 encoders (23 render and one compute). The GPU reached the `aa294` pipeline boundary in the 14th encoder and did not reach the following `94c` boundary. Exactly one command lies between those counters: a direct indexed draw of 61,365 indices and one instance, using 15 buffers, four descriptor sets, seven vertex buffers, and 1,892,236 vertex bytes.

This is exact attribution for that failure, but it is not yet proof of one permanently defective shader. The v14 capture stopped one pipeline earlier, between `e587` and `aa294`; v15 passed `e587` and stopped after `aa294`. The moving boundary points to resource/descriptor state, accumulated work in one submission, or an AMD/Metal execution failure for a changing combination.

v16 adds a bounded one-shot all-draw diagnostic mode. It is active only while an external marker is armed and one command buffer matches the lazy selector. Capacity is 512 timestamps and includes each pipeline boundary, draw boundary, and encoder tail. Normal execution does not enable it. A native Radeon control rendered a red triangle with BGRA `[0,0,255,255]`, produced a valid draw timestamp with no truncation, and released the counter budget. The rebuilt MoltenVK candidate also completed eight real geometry draws and checked 512 pixels with zero mismatches.

The game remains unplayable at roughly 6 FPS. Persistent CPU command encoding/resource binding cost and the occasional 6–7 second GPU watchdog are separate problems. The next normal-Steam run must use v16 to determine whether the exact draw is stable. A stable result leads to resource and shader-state repair; another moving boundary leads to safe intra-Vulkan-command-buffer segmentation at encoder boundaries while preserving render-pass, barrier, query, visibility, and synchronization semantics. Stable gameplay, menu use, repeated attacks, the repair-shop path, sustained frame rate, FSR3 upscaling, and frame generation all remain pending.
