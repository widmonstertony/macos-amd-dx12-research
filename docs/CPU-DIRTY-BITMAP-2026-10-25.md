# Precise fragmented descriptor invalidation / 精确跟踪分散描述符更新

The previous cache widened more than 32 separate dirty ranges into a single bounding interval, comparing unchanged gaps on every rebuild. v29 keeps interval tracking for small cases and switches to a bounded bitmap at larger fragmentation. One bit represents 32 slots. Rebuilds visit marked blocks only; full-table writes still cover the complete table. Existing resource lifetime tracking, version checks, and reader/writer locks remain in force.

旧缓存超过 32 段分散更新后，会合成一个大区间，重建时重复比较中间未变化的槽位。v29 小规模继续使用区间，多段更新改用有界位图，每位表示 32 槽，只访问已标记区块；整表更新仍完整覆盖。资源生命周期、版本检查和读写锁保持有效。

The CPU control passed 2,080 independent identity-set checks, including contiguous/strided layouts, overlapping views, partial tails, complete clearing, full-table rewrites and two concurrent writers. Sparse rebuilding improved by roughly 2–85 times depending on workload; dense updates were broadly similar. These are local CPU timings, not game FPS.

CPU 对照通过 2,080 次独立资源集合核验，覆盖连续/跨距布局、重叠视图、尾部、清空、整表改写和两个并发写线程。分散更新的重建耗时按负载降低约 2–85 倍；密集更新总体相近。这是局部 CPU 测量，不是游戏帧率。

Real Radeon output passed a 500,000-slot control with 100 narrow fragmented writes, plus 25,600 query/output words, 5,120 graphics pixels and a 512-pixel geometry split control. Original Tencent Wine compute, presentation, strict warm-cache reuse and asset guard qualification passed. Actual game performance validation is pending at this checkpoint. The candidate additionally records bitmap rebuilds and visited slots versus the bounding span, so actual game use can be verified rather than assumed. Caches are preserved.

真实 Radeon 输出通过 50 万槽、100 次分散小写入对照，以及 25,600 个查询/输出值、5,120 图形像素和 512 像素几何切分对照。原应用宝 Wine 的计算、呈现、严格暖缓存复用及原游戏写保护验证已通过；本检查点实际游戏性能验证尚待完成。候选增加位图重建次数、实际访问槽数及对应包围区间计数，用于核实游戏是否命中，不能凭独立对照推断。缓存保留。

## Actual game result / 实际游戏结果

Through the original Tencent Wine and Steam, v29 reached the normal scene. Foreground native presentation measured 8.33 FPS initially and 9.69 FPS in a warmed interval, versus 7.92 FPS for v28 and 6.57 FPS for v26. Existing window size and graphics settings were preserved. During eight warm-scene telemetry windows the bitmap visited 13,760,256 slots instead of a combined 5,282,709,088-slot bounding span. This is a reduction in that scan path, not a proportional reduction of total frame time. No GPU watchdog record appeared in this run at the checkpoint. Gameplay remains too slow; attack stability and both FSR3 features are unverified.

v29 经原应用宝 Wine 与 Steam 进入正常场景。前台原生呈现首次为 8.33 FPS，稳定区间为 9.69 FPS；v28 为 7.92，v26 为 6.57。原窗口大小和图形设置保持不变。稳定场景八段计数里，位图访问 13,760,256 槽，原包围区间合计会覆盖 5,282,709,088 槽。这只是此扫描路径的减少，不是整帧耗时同比降低。本检查点这一轮未出现 GPU watchdog 记录。游戏仍太慢，攻击稳定性与 FSR3 两项未验证。

The next CPU hotspot is retained live-snapshot replay and resource-state bookkeeping, followed by native heap/read/write declarations. A suspected aligned-pointer hash collision was tested with 4,096 actual Metal identities and rejected: libc++ already mixes pointer hashes, and extra mixing made lookup slower. That rejected candidate was not deployed.

新的 CPU 热点是已保留资源快照的逐项重放、状态记录，以及原生 heap/read/write 声明。曾怀疑对齐指针导致哈希碰撞，用 4,096 个真实 Metal 地址对照后已排除：libc++ 原本就混合指针哈希，额外混合反而变慢。该候选没有部署。
