# 卡顿覆盖采集 / Stutter coverage capture — 2026-10-25

当前优先级是先找到实际卡顿的位置，再选择优化；不是继续换参数试启动。
The priority is attribution of observed stalls before further optimization.

**游戏仍不可正常游玩 / The game is not yet playable.** 上一轮 v30 实际前台场景约 9.63 FPS。v31 heap-plan 优化仅在隔离控制通过，没有部署或帧率结论。v32 为诊断候选，首轮 heap-plan 关闭，保留 v30 运行行为与现有缓存。

## 本次覆盖 / Coverage added

| 环节 / Area | 记录 / Records | 限制 / Limits |
|---|---|---|
| CPU 编码与资源 / Encoding, descriptors, residency | 75 phase names, nested inclusive/self wall time, coarse thread CPU, bounded logical-submission details and in-flight spans | Self time is a same-thread partition, not summed process utilization. Detailed thread/context budgets are explicit. |
| 编译和缓存 / Compilation, cache | Stable module/MSL/pipeline tags; actual lookup/file/native-hit branches where observable; conversion, library and PSO compilation, lock/monitor waits | Normal compute archive loading does not prove native cache hit. Closed compiler internals remain opaque. |
| 原生队列 / Native queues | All-queue native CB IDs, logical submissions, split indexes, enqueue/request/true commit/scheduled/completed timestamps | Logger I/O precedes the no-I/O true commit marker. Missing producers/completion and partial prefixes invalidate complete attribution. |
| 帧和依赖 / Presents and dependencies | Actual drawable timestamps, present IDs and cross-queue event/value edges; fixed-session host waits | Callback time is not substituted for actual native presentation. Rearm and late captures are explicitly partial. |
| GPU 工作 / GPU work | Bounded multi-CB burst across queue families, draw/geometry/direct+indirect dispatch boundaries | No-barrier counter boundaries are not exclusive draw durations. Caps, unsupported sampling and missing suffixes remain visible. |
| GPU 时钟 / GPU clock | Public device CPU/GPU paired anchors, finalized sidecar per session | Raw GPU ticks, C++ steady clock, Mach absolute CPU clock, CF and CA are distinct domains. No cross-domain subtraction without anchors. |
| 内存与系统 / Memory and system | Actual buffer/heap/texture/host allocation attempts and nil/rejection results, Metal memory counters, process/thread CPU, VM/swap/I/O, host load and background CPU estimates | Allocated/recommended memory is not free VRAM. No global allocator hook or private driver memory reads. |
| 日志本身 / Observer | DiagnosticPublish/WorkTrace scopes, collector usage, cold allocation counts, cap/drop/stale/unavailable markers | Same-process tracing off/on comparison is required before using instrumented FPS as a baseline. |

## 已完成验证 / Validation completed

- CPU timer: 48,000 concurrent events; nesting, in-flight work, arm changes, allocation failure isolation and errno checks passed. Empty-scope measurements are local microbenchmarks, not game FPS.
- Analyzer: 40 synthetic cases passed, including clock precision, missing graph edges, history deduplication, partial presents and unsampled GPU suffixes.
- Native graph: real 5600M cross-queue copy checked 64 bytes, zero mismatches; calibration/identity/rearm checks passed. Headless present-format and row-cap boundary checks are explicitly synthetic.
- Found and reproduced a diagnostic lifecycle bug: removing an arm marker could prevent counter cleanup and block a later capture. The candidate completes both GPU readbacks and resolves/releases both captures.
- Native diagnostic build passed with unchanged source during the build; the first build's missing include failure is retained separately.
- Integrated geometry stress: 8 draws / 8 concurrent pipeline requests / 8,192 primitives / 512 checked pixels, zero mismatches; CPU report and 9 completed native-CB identities were emitted. Query/graphics control checked 25,600 words and 5,120 pixels, zero mismatches.

实际游戏采集和日志开销对照仍待完成。以上不能证明已找到所有卡顿，也不能证明装备、攻击或 FSR3 可用。
Actual-game scenario captures and observer-overhead comparison remain pending. Probe success does not establish playability, attack/equipment stability or FSR3 support.

## 下一步 / Next

Finish original Tencent Wine compute/presentation/cache qualification; deploy the exact diagnostic candidate; launch through original licensed Steam; capture startup/cache, warmed scene, movement/attack and equipment/nano-suit separately in the same run where possible. Preserve caches and settings. Rank CPU self costs and the observed dependency graph; keep measured, suspected and unobserved contributors separate.

原生 macOS Steam 的统一入口另有准备工具；目前仅《剑星》原应用宝/正版 Steam 启动链可准备，盘上其他六款需先完成正常客户端登记及各自启动器验证。NotProton 当前核心 ARM64、Intel stub 和 NTFS 限制不能忽略。它是启动入口问题，不是 GPU 兼容或帧率修复。
A native macOS Steam shortcut is a separate launcher integration. It does not replace the verified Wine engine, graphics path or licensing flow, and does not establish that the other six disk games run.

Additional qualification remains open: a resource-helper run produced correct GPU values but aborted at process teardown; this is not counted as a passed suite. Its fixture-specific historical scan-count assertions are being separated from actual late-resource and write-stage correctness checks. No game deployment has happened.
