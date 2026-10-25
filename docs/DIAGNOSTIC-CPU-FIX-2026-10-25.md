# Reduce diagnostic CPU overhead / 减少诊断自身的 CPU 开销

Actual scene sampling found drawing metadata formatting at roughly one tenth of
the graphics command-encoding samples. The work history also allocated 589,840
payload bytes for every command buffer, including very short ones.

实际场景采样中，绘制元数据格式化约占图形命令编码采样的一成；每个命令缓冲区还会
分配 589,840 字节历史记录载荷，即使只记录很少事件。

The candidate initially allocates 64 events (36,888 payload bytes) and lazily
allocates a separately owned 960-event overflow at event 65. The data owner is
never resized. Snapshot copies and writes use the same stable lock. Maximum
retention remains 1,024 events: first 64 and the rolling last 960.

候选改为先分配 64 条记录（36,888 字节），第 65 条时再按需分配由原数据对象持有的
960 条溢出区。原数据对象不扩容、不移动；写入和快照继续使用同一稳定锁。总保留量
仍为 1,024 条：前 64 条和最近 960 条。

Ordinary draw labels use bounded C formatting instead of allocating a formatted
Foundation string per draw. Armed GPU-counter records retain the original full
string path. Shader execution, Metal commands and synchronization are unchanged.

普通绘制标签改用有界 C 格式化，避免逐次分配 Foundation 格式字符串；开启 GPU
计数器时保留原完整字符串路径。不改变着色器执行、Metal 命令或同步。

The CPU control checked ten retention boundaries, 100,000 concurrent writes with
snapshots, overflow timing, and byte-identical draw labels. On this host, 10,000
short-buffer allocations changed from about 285 ms to 19 ms; 100,000 formatted
draw records changed from about 783 ms to 126 ms. These are diagnostic workload
measurements, **not game FPS**.

CPU 对照检查十种保留边界、10 万次并发写入与快照、溢出区分配时机及标签字节一致性。
本机 1 万次短缓冲分配约从 285 ms 降到 19 ms，10 万次格式化绘制记录约从 783 ms
降到 126 ms。这是诊断负载测量，**不是游戏帧率结果**。

Real Radeon query/graphics output, geometry splitting and armed GPU counters
passed, followed by original Tencent Wine compute/presentation/cold-warm-cache
qualification. The exact candidate has been deployed and launched through the
original licensed Steam client; its actual scene FPS is still pending at this
checkpoint. Caches remain intact; neither FSR3 feature is declared validated.

真实 Radeon 查询/图形输出、几何切分及 GPU 计数器对照通过，随后原应用宝 Wine 的
计算、呈现、冷暖缓存回归通过。确切候选已部署并经原正版 Steam 启动，本检查点尚待
实际场景帧率验证。缓存保留，FSR3 两项仍不宣称通过。

The normal Steam launcher now waits up to 20 seconds for Steam to clear the old
game tracking entry after the native game PID exits. This avoids a proven race
where the client silently ignored an immediate relaunch. It also normalizes Wine
path separators when checking existing game processes. It does not alter Steam's
state or launch the game executable directly.

正常 Steam 启动工具现在会在原生游戏 PID 退出后，最多等待 20 秒让 Steam 清除旧的
游戏跟踪状态，避免已复现的“立即重启请求被忽略”竞态；并统一 Wine 路径分隔符以
检查残留实例。不修改 Steam 状态，也不直接启动游戏可执行文件。

## Actual scene result / 实际场景结果

The v28 foreground scene measured 7.19 FPS initially and 7.92 FPS after warming, compared with 6.57 FPS in v26 and 7.29 FPS in v27. All intervals used the existing 363×263-point Wine window, without a resolution setting change. Diagnostic formatting samples fell, but resource binding and descriptor snapshot rebuilding still dominated the serial graphics encoder. This remains unplayable. Neither FSR3 feature has been validated.

v28 前台场景首次测得 7.19 FPS，稳定后 7.92 FPS；v26 为 6.57，v27 稳定后为 7.29。各次保留原有 363×263 点 Wine 窗口，未修改分辨率设置。诊断格式化采样占比降低，但资源绑定与描述符快照重建仍占据串行图形编码线程的主要时间。目前仍不可正常游玩，FSR3 两项均未验证。
