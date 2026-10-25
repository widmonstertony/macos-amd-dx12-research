# 卡顿覆盖采集 / Stutter coverage capture — 2026-10-25

当前优先级是先找到实际卡顿的位置，再选择优化；不是继续换参数试启动。
The priority is attribution of observed stalls before further optimization.

**尚无正常可玩或帧率提升结论 / Playability and an FPS improvement have not been established.** v32 已完成实际场景和装备界面采集，卡顿问题仍在。v33 已部署缓存配额提前准入修复及三项诊断修正；构建和自有探针通过，实际游戏效果待用户测试。现有缓存保留。

v32 actual-scene and equipment captures are complete. v33 is deployed with cache pre-admission and three diagnostic corrections. Its build and owned probes passed; actual-game effects await user testing with the existing caches preserved.

## 本次覆盖 / Coverage added

| 环节 / Area | 记录 / Records | 限制 / Limits |
|---|---|---|
| CPU 编码与资源 / Encoding, descriptors, residency | 75 phase names, nested inclusive/self wall time, coarse thread CPU, bounded logical-submission details and in-flight spans | Detail storage is owned by stable domains, with explicit capacity/overflow and mixed-thread provenance. Submission self totals are cumulative work, not single-thread elapsed time or a critical path. |
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
- v33 native build and owned probes passed. Earlier build and fixture failures remain recorded separately; they do not substitute for actual-game validation.
- Integrated geometry stress: 8 draws / 8 concurrent pipeline requests / 8,192 primitives / 512 checked pixels, zero mismatches; CPU report and 9 completed native-CB identities were emitted. Query/graphics control checked 25,600 words and 5,120 pixels, zero mismatches.

v32 实际采集已暴露明细预算和诊断成本方面的问题；v33 对应修正已部署。仍需用户验证游戏效果，并在可比条件下确认诊断开销。以上不能证明已找到所有卡顿，也不能证明装备、攻击或 FSR3 稳定可用。
v32 captures exposed detail-budget and diagnostic-cost defects addressed in deployed v33. User testing and comparable observer-overhead checks remain necessary. Probe success does not establish playability, attack/equipment stability or FSR3 support.

## 下一步 / Next

The user tests the deployed v33 through the original Tencent Wine and licensed Steam, preserving caches and settings. The user alone starts, operates, restarts and reproduces issues in the game. The agent prepares instrumentation, analyzes the resulting startup, scene, attack and equipment logs, and fixes code. Keep measured, suspected and unobserved contributors separate. A startup-cache improvement must not be presented as a warmed-scene FPS improvement.

原生 macOS Steam 的统一入口另有准备工具；目前仅《剑星》原应用宝/正版 Steam 启动链可准备，盘上其他六款需先完成正常客户端登记及各自启动器验证。NotProton 当前核心 ARM64、Intel stub 和 NTFS 限制不能忽略。它是启动入口问题，不是 GPU 兼容或帧率修复。
A native macOS Steam shortcut is a separate launcher integration. It does not replace the verified Wine engine, graphics path or licensing flow, and does not establish that the other six disk games run.

An earlier resource-helper teardown/fixture failure remains in the historical record. The current v33 build and owned probes passed, and v33 is deployed. Its actual-game stability and performance remain unverified until user testing.

## Focused follow-up / 聚焦修正

Game starts, input, fullscreen changes and reproduction are now performed by the human tester. The agent prepares instrumentation, analyzes logs and fixes code; it does not autonomously operate or restart the game.

Deployed v33 fixes three measurement defects: stable domain-owned CPU detail storage survives worker-thread migration; GPU sample buffers are allocated lazily only for eligible events; full successful slow-CB snapshots require an active capture and are limited to 4/second and 64/arm, before dependency payload construction. Compact armed queue timing and fault evidence remain separate. These corrections must be checked before treating instrumented timing as a game-performance baseline.

Archive publication now reserves bounded process-local capacity before creating/adding/serializing a Metal archive. Existing cache keys and files are retained. Successful atomic publication settles actual bytes; failed work releases the reservation. Admission conservatively leaves a tail smaller than one maximum shard, and the existing cross-process limitation remains. No FPS improvement is claimed before human-run validation.

由用户负责开游戏和复现；新版修正线程明细预算、空提交采样预算和慢日志风暴。满额缓存的无效构建改为提前拒绝，保留已有缓存和 key。实际游戏效果仍待用户验证。

## Foreground follow-up / 前台归因后续

A human-operated foreground scene capture confirmed diagnostic contention: events without a logical submission still acquired the shared detail-domain lock. Their event count and self total now drain together from the existing thread aggregate shard, while real submission details retain domain ownership. Concurrent drain and arm-transition controls pass without lost counts; unattributed work still marks detailed coverage incomplete. This is an observer-overhead fix, not a playable-FPS claim. Native write declarations are retained: the observed call pattern tracks encoder creation, and there is no evidence that required declarations can safely be dropped.

由用户操作的前台采集已完成。修复把无 submission 的诊断计数放回已有线程分片，消除共享日志锁争用，保留无归属和覆盖不完整标记；并发 drain、arm 边界与原控制通过。真实资源写声明尚无安全省略证据，保持原有覆盖。新采集工具检测到持续前台才启动有界采样，不会启动、停止或操作游戏；启动时详细 CPU 采样改为显式选择。游戏主性能问题仍未解决，实际帧率改善待用户验证。

## Resource replay integration / 资源重放优化接入

The next measured target is warm snapshot identity replay followed by rebuilding heap groups for each encoder. v35 enables the existing lease-owned buffer read-plan implementation before that per-resource loop. It admits only sufficiently large, validated buffer snapshots and eligible heap groups; textures and ineligible buffers fall back, and writes remain precise. The native implementation is reused from v34; the authored portable profile records the one functional configuration change.

New native-only GPU controls cover the same buffer changing from grouped read to precise write, one helper across multiple encoders, and a separately scoped defensive lease-retention case. CPU-encoding helper lifetime is not GPU-completion lifetime: normal Vulkan resource owners use the existing all-queue deferred-release chain. No new fences, events or resource-lifetime shortcuts were introduced. Original Wine compute/presentation/cache and geometry controls pass. Human-run plan eligibility and warmed scene performance remain unverified; runtime shader conversion and host CPU limits must be separated in comparisons.

v35 把已有分组算法接入实际游戏配置，保留逐资源写声明和不满足条件时的回退。新增跨 encoder、同资源读后写及限定 scope 的保活 GPU 测试。后续采集会记录 bulkChildren、nativeHeapCalls、preciseChildren、priorWriteReplays，判断游戏里是否真正命中，不能仅凭配置开启推断提帧。原生 Steam 入口、着色器功能和实际可玩性仍是各自独立的验证范围。

Portable build options: `workspace/open-game-stack-20261015/profiles/buffer-read-plan-v35.json`. This is an experimental profile, not a new playable release.
