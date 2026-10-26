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

## 公开备份边界

本次只复制源码，不包含私有检查点、原始游戏日志、着色器、二进制或运行包，也不创建新 release。历史检查点数据保持不变；原有历史结果仍按各自的证据范围解释，新增诊断不会追认其已经通过。
