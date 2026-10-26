# v38 因果诊断：仅源码检查点

v38 在 v37 的行为和性能策略之上补充诊断，用于下一轮取证。它不代表已经提速、达到可玩水平或确认修复。游戏启动、所有操作、退出和重新启动均由用户完成。

## 源码新增内容

| 范围 | 新增证据 | 解释边界 |
|---|---|---|
| 因果与 owner 链 | 有界、成对的软件区间，submission/queue/command buffer 归属，以及预存的 terminal intent/end 记录 | 缺失、抽样和无法关联的记录仍须明确；某操作附近出现耗时，不能单凭时间接近就认定因果。 |
| 呈现身份与生命周期 | swapchain/surface 代际、layer/drawable 身份、呈现 intent/实际调用/回调计时、锁边界及退役/引用生命周期记录 | GPU 成功完成或 fence 已发信号不等于实际上屏；原始呈现时间为零时保留零，回调时刻与呈现时刻分别记录。 |
| 日志流与会话身份 | 进程启动身份、run/session ID、时钟锚点、流代际、序列连续性、writer/copy 丢项与配置指纹 | 句柄复用、arm 切换、轮转和前缀缺失不能被悄悄拼接成完整历史。 |
| 显示与会话上下文 | 仅选定的公开布尔值、显示电源数值、HID idle 和会话元数据，并保留获取时间区间 | 缺失或冲突的值保持未知；这些观察不能证明历史锁屏或显示状态，active/on-screen 窗口标记也不能证明物理上屏。不采集截图、凭据或私有会话身份字段。 |
| 采集保留 | 六类动作与未标注窗口独立分配 raw 配额，保留原始记录；arm 关闭后继续有界采集六秒尾部，并为 telemetry/error tail 预留容量 | 触顶、轮转、磁盘余量不足以及超过尾部时限的迟到记录都属于覆盖不足；有配额不等于完整抓到了所有动作。 |
| 观察成本 | 分别记录 sampler、polling、logger 和采集器的 CPU/墙钟成本 | 不把观察成本换算成 FPS 后从结果中相减；带诊断的结果不是无诊断性能基线。 |

Terminal 诊断会在 commit 或可能销毁 submission 的路径之前保存标量归属信息。之后的 commit/end 记录不需要解引用已经销毁的 submission 或其 queue。这是诊断生命周期保护，不改变呈现行为或同步策略。

## 用户动作标签

外部 marker 仅接受 `stable`、`move`、`attack`、`equipment`、`nanosuit`、`present` 六个标签，以及 `start`/`end` 阶段。例如，用户提供的 `<profile>/diagnostics.action.json` 可以包含：

```json
{"action":"attack","phase":"start"}
```

采集器记录 marker 文件时间戳与收到标签的时钟。标签用于请求或标注诊断窗口，不生成键盘或鼠标输入，也不证明游戏中实际发生了该动作。采集就绪状态、已请求窗口、剩余容量和覆盖缺口仍须分别核对。

## 本检查点的验证

本地 Native 构建证明记录 `exitCode: 0`、`sourceStable: true`、`sourceFiles: 223`、`passed: true`。最终 Python fixture/mock 检查共 55 项通过；terminal ASan/UBSan 的 21 项场景通过。相关私有证据不复制到本次仅源码的公开更新中。

限定的自有 GPU 回归结果：几何控制的 512 pixels / 8,192 primitives 零差异；纹理控制的 6 cases / 12,288 pixels 通过，并确认 v37 旧 cache 的 6 次 shader-stage hits；原 Wine 下自建 compute 与单帧 present 的冷/暖 probe 均通过。这些是小型自有工作负载，不是实际游戏性能或故障根因的证明。

本检查点完成上述限定 GPU 回归，实际游戏尚未验证。实际游戏的呈现、卡顿、崩溃及 FSR3 根因仍未确认。正常画面、持续可玩帧率、装备/纳米服稳定性、FSR3 超分和帧生成仍须由实际游戏证据验证。

## 分析摘要补全

分析器后续补齐了全部已解析记录的等待通知配对、drawable 获取与实际 present 调用耗时，以及分配失败/慢调用 journal 和近期环的明细分析。前 2,000 条仅是展示上限，现与 writer 丢项分开报告。93 项 CPU 工具测试通过；此更新不改 Native、运行库、缓存或正在运行的采集器。

内存 journal 每类保留前 128 条，snapshot 每类保留近期 32 条；两者可能重叠，省略数不能相加。分配没有持久 Begin，未返回调用的具体 ID/site 仍未知，attempts/completed 差不能直接判挂死或 OOM。完整事件加载须核对 PID、kernel start 与观察到的 Mach 时间边界。Wine `vkQueueSubmit2` 断言检查外层 NTSTATUS，和内层 VkResult 分开；静态调用链核对不能替代故障现场的状态值。

## 公开备份边界

## RenderThread 超时取证

最新一次用户运行触发了 UE4 的 120 秒 RenderThread 等待超时；具体阻塞调用仍未定位。该次图形进度在场景采样前已经停止，不能用空的阶段记录证明渲染路径正常。现有分组计划的独立 GPU 控制通过，也没有证明实际游戏成功应用；本地已发布统计尚未观察到成功应用计数。

新增 `watch_render_stall_stacks.py`：等待用户启动唯一游戏进程，核对 PID、启动时间和 kernel start，再用系统 `sample` 做有界线程栈采样；进度停滞与 raw VM fault 增长只用作取证触发，不直接判定根因。可选连续模式使用独立的 native/forensics 标记，分别按 20/60 秒刷新；CPU/GPU 计数器标记保持独立。最多 8 次、每次 2 秒、总输出 128 MiB，并保留两组末尾原始流；nonce/inode 所有权、低磁盘和退出清理都有明确边界。

33 项 CPU mock 控制与两项独立审查修复通过，尚未证明实际游戏中的栈展开质量、触发灵敏度或性能改善。此更新只改变取证工具与诊断路径，图形库和性能配置未变；原始日志、崩溃文件和栈内容不公开。

本次只复制源码，不包含私有检查点、原始游戏日志、着色器、二进制或运行包，也不创建新 release。历史检查点数据保持不变；原有历史结果仍按各自的证据范围解释，新增诊断不会追认其已经通过。

## v39：精确回退的堆身份修复（2026-10-26）

本轮实际游戏的线程栈与提交链定位到开源资源分组路径：`queuePreciseRead` 因 retained heap identity 不一致抛出 `logic_error`，当前 native command buffer 尚未 commit，其他队列和上层渲染线程随后等待。这是新增分组优化中的回归，不能外推为所有历史 OOM 或帧率问题的唯一原因。

`nilHeapResources` 这个历史名称下也存放实际有 heap、但必须精确声明的纹理（例如 writable、attachment、view 或 placement overlap）。调用者错误地传入 nil 并设置 `heapKnown=true`。修复改为 `addPrecise(resource, resource.heap)`，保持精确 residency、stage/write 重放与真实 heap 身份变化检查。Native 构建的 223 个源文件中仅此调用文件发生变化。

验证结果：

- 旧库在真实 helper 中重现同一异常。反向顺序的旧库虽然像素正确，heap 元数据和 write 重放仍错误，按失败保留。
- 新库两种顺序共读回 1,290 个 GPU 像素/word，零差异；包含 128 个 bulk eligible 纹理和一个实际 heap-backed 的 writable 排除项，覆盖 Vertex/Fragment、reset 与 write 重放。
- CPU 新回归 12,368 checks；既有 ledger 1,292,945 checks；10 个真实 heap 身份变化负例仍被拒绝。
- 现有纹理、几何及原应用宝 Wine 自有 compute/present 回归通过；旧 Vulkan fixture cache 保持不变。

上一轮已发布 stats 的零 applications 是旧报告窗口：真实 heap API 应用发生在最后 stats 之后。现场另有实际 heap 调用记录，不能再把旧窗口的零值解释为计划从未生效。原始取证有 writer 丢项，连续已写序号不等于完整覆盖；具体卡死判定同时依据重复线程栈和提交归属。

修复库已在本机换入，游戏操作仍由用户完成。实际场景帧率改善、攻击/装备/纳米服稳定性、呈现延迟和 FSR3 两项功能仍待验证。公开更新只备份源码与复现工具，下载运行包未更新，也不声明已可玩。

复现 CPU 控制：

```sh
python3 tools/qualify_heap_plan_precise_identity.py --output evidence/owned-precise-identity
```

GPU 对照工具为 `tools/qualify_heap_texture_exception_gpu.py`，需要先构建正确的新/旧 Native 库；仅运行自有资源与着色器，不启动游戏。

## v39 实际场景与 v40 离线修复

用户随后确认已进入场景但仍严重卡顿。同一 v39 进程的原生映像 UUID 与部署库一致。39.413 秒实际前台观察中，软件有效 present 序列约 1.210 Hz；该值不是物理显示帧率。GPU 公开执行区间并集为该窗口的 8.71%，也不是硬件利用率。35.737 秒完整 CPU 明细窗内 NativeRead self 为 17.749 秒、ResourceGroup self 为 7.185 秒，未见场景编译忙。说明逐项 Metal 资源声明和资源整理仍是主要已测贡献，不能说 v39 已解决卡顿。不同分辨率、场景和诊断状态的历史 FPS 不构成速度对照。

启动编译另有具体问题：缓存命中后的第二次 detached PSO 创建持有整个 MTLDevice monitor，阻塞其他工作线程。v40 保留这次重建以避免归档映射长期留存，改为锁内提交异步 Metal 请求、锁外等待，保持原 pipeline fallback 和配置中的编译时限。共享 request 拥有 descriptor/device/result；超时和晚回调不访问父 compiler，日志保持原 session。已 admission 的 Metal API 入口本身仍可能阻塞，不能取消驱动工作或承诺全路径短时结束。

离线验证已通过：

- 稳定 224 文件 Native 构建；optimized 与 ASan/UBSan 各 100 项 CPU 检查、60/60 对象释放。
- 新库 5 组实际纹理 GPU 测试共 10,240 pixels，零差异；15 次严格 render archive hits 和 15 次 detached 重建成功。
- 原应用宝 Wine 的无窗口自有 compute 冷/暖 GPU 控制通过，严格 compute archive hit 已验证。

v40 **尚未部署到游戏**；游戏仍由用户操作，同一轮和缓存保留。尚未证明实际启动提速、真实归档映射释放数量或游戏帧率提升。纹理访问分类正在进一步调查：代表性 shader 的 3D/buffer read 会令整个 stage 回退，可能连带阻止纯采样 2D 分组；严格 2D 合同尚未集成，不能凭 MSL 关键字或按 binding 整体放开。剩余 PSO 映射覆盖不足，不能推算总体收益。

## v41：减少只读纹理逐项登记

v39 实际场景确认资源读取登记和分组是主要 CPU 开销。此前把整支着色器限制为只能采样，导致其中出现 Buffer/3D/2D fetch 时，即使物理 2D 纹理只读也全部退回逐项登记。这项限制超过 Metal `useHeaps` 的只读访问契约。5600M 的真实 GPU 对照确认，readonly heap 登记也支持 texture.read；不需要重写着色器。

v41 在只读绑定上采用现有资源分组，仍保留原来的物理资源排除条件和写入升级/重放。可写纹理、附件、视图、buffer-backed 纹理及未知/重叠范围不因此进入批量路径。原着色器代码和缓存格式不变。旧内部 sampled/sampleOnly 名称保留，仅为兼容；不再代表仅采样。独立 typed-2D 分类器原型保留，但未启用，也不要求额外 validator。

验证结果：混合 Vulkan GPU 控制的 8 个用例共 24,576 像素零差异，覆盖 BC1 采样/fetch/query、真实 3D 和 texel-buffer、阶段切换及 encoder 重置。相同 switch 负载逐项只读引用从 1,040 降到 16，另有 8 次 heap 调用；这不是游戏 FPS 提升倍数。旧缓存读入证明 8 个着色阶段命中。既有纹理/归档、heap-backed 写入例外及 8,192 图元几何回归通过。

v41 包含此前离线通过的 v40 异步 detached PSO 修复，已换入本机原启动链。游戏由用户操作，缓存保留。应用宝 Wine 无窗口 D3D12 探针在候选图形库加载前超时，保留失败，不能算通过或归因为该图形修复。实际 Steam 启动、游戏帧率、战斗/装备稳定性及 FSR3 两项功能尚待用户验证。公开更新仅包含源代码和工具，未发布新的可玩运行时。
