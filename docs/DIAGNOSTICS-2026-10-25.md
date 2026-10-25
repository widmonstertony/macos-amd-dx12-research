# 2026-10-25 diagnostic checkpoint / 诊断检查点

The game is still too slow to call playable. This update adds attribution, not
a claimed performance repair. FSR3 upscaling and frame generation remain unverified.

游戏仍明显卡顿，尚不能宣称可玩。本次补齐定位信息，不宣称已经修复性能。
FSR3 超分和帧生成仍未验证。

## Native instrumentation / 原生诊断

- Query traces now identify timestamp producers, counter slots, resolve ranges,
  destination offsets and actual allocation lengths.
- Geometry traces record primitive/instance grids and actual native command-buffer
  split boundaries, including indirect draw parameter ranges.
- Slow submissions record GPU start/end, host encoding and submit-to-start time.
- Resource statistics separately time native heap, read-resource and write-resource
  declarations. Calls exceeding 2 ms enter the bounded work history.

查询记录补齐生产者、计数槽、解析范围、目标偏移及分配长度；几何记录补齐实际规模、
间接参数范围及切分点；慢提交补齐 CPU/GPU 时间；资源声明分别统计整堆、只读和可写
路径的 CPU 耗时。诊断不改变着色器结果、资源声明覆盖或提交顺序。

Owned Radeon Pro 5600M controls passed query output (25,600 words, 5,120 pixels),
geometry splitting (512 pixels), resource lifetime/read-write declarations, and
original Tencent Wine D3D12 compute/presentation with cold/warm archive checks.
These controls do not prove game compatibility or acceptable frame rate.

真实 5600M 查询、几何切分、资源生命周期及读写声明对照通过，原应用宝 Wine 的
D3D12 计算、呈现、冷暖缓存对照通过。这些结果不等于实际游戏通过。

An owned compute residency benchmark rejected a tempting optimization: replacing
repeated heap declarations with precise child declarations was slower on this GPU.
No such production behavior change was made. Render-stage and actual game costs
must be measured independently.

独立计算对照否定了“重复整堆声明换成逐资源声明会更快”的猜测，后者在这张显卡上
反而更慢，因此没有据此修改游戏路径；图形阶段和实际游戏仍须独立测量。

## Wine window control / Wine 窗口控制

The macOS Computer Use inventory did not expose the Wine game as an application.
The running game had no bundle identifier, while its PID and accessibility window
were available. The installed Computer Use package is proprietary and exposes no
local application-resolution implementation to patch. Its internal `Invalid app`
error is **not fixed by this repository**.

macOS 电脑插件未列出 Wine 游戏；该游戏进程没有 bundle identifier，但辅助功能能按
PID 找到窗口。已安装插件为闭源包，没有可修改的本地匹配实现；本仓库**没有修好
插件内部的 Invalid app**。

The user explicitly authorized AppleScript control. The supplied fallback,
`tools/control_stellar_pid.applescript`, targets an already-running PID, validates
the game window title, and requires its observed process start time before input
to reject PID reuse. Run it directly from the authorized controlling application.
Do not assume a child interpreter inherits the same Accessibility access.

经用户明确授权提供 AppleScript 备用控制：只操作已运行的 PID，验证窗口标题，输入前
核对启动时间防止 PID 复用；从已授权控制端直接调用。不要假定经其他解释器转调仍有
相同的辅助功能权限。该脚本不启动、缩放或修改游戏，也不修改 Wine/Steam。

```sh
osascript tools/control_stellar_pid.applescript OBSERVED_PID state
# Copy the exact observed process start string into the last argument:
osascript tools/control_stellar_pid.applescript OBSERVED_PID return 'OBSERVED_START'
```

A successfully sent key is not proof of a completed UI action. Observe the window
after each action; low frame rate can delay or miss short key presses.

按键发送成功不等于界面操作成功，必须重新观察画面；低帧率可能造成响应延迟或漏掉
很短的按键。
