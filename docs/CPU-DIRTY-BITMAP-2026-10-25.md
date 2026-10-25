# Precise fragmented descriptor invalidation / 精确跟踪分散描述符更新

The previous cache widened more than 32 separate dirty ranges into a single bounding interval, comparing unchanged gaps on every rebuild. v29 keeps interval tracking for small cases and switches to a bounded bitmap at larger fragmentation. One bit represents 32 slots. Rebuilds visit marked blocks only; full-table writes still cover the complete table. Existing resource lifetime tracking, version checks, and reader/writer locks remain in force.

旧缓存超过 32 段分散更新后，会合成一个大区间，重建时重复比较中间未变化的槽位。v29 小规模继续使用区间，多段更新改用有界位图，每位表示 32 槽，只访问已标记区块；整表更新仍完整覆盖。资源生命周期、版本检查和读写锁保持有效。

The CPU control passed 2,080 independent identity-set checks, including contiguous/strided layouts, overlapping views, partial tails, complete clearing, full-table rewrites and two concurrent writers. Sparse rebuilding improved by roughly 2–85 times depending on workload; dense updates were broadly similar. These are local CPU timings, not game FPS.

CPU 对照通过 2,080 次独立资源集合核验，覆盖连续/跨距布局、重叠视图、尾部、清空、整表改写和两个并发写线程。分散更新的重建耗时按负载降低约 2–85 倍；密集更新总体相近。这是局部 CPU 测量，不是游戏帧率。

Real Radeon output passed a 500,000-slot control with 100 narrow fragmented writes, plus 25,600 query/output words, 5,120 graphics pixels and a 512-pixel geometry split control. Original Tencent Wine compute, presentation, strict warm-cache reuse and asset guard qualification passed. Actual game performance validation is pending at this checkpoint. The candidate additionally records bitmap rebuilds and visited slots versus the bounding span, so actual game use can be verified rather than assumed. Caches are preserved.

真实 Radeon 输出通过 50 万槽、100 次分散小写入对照，以及 25,600 个查询/输出值、5,120 图形像素和 512 像素几何切分对照。原应用宝 Wine 的计算、呈现、严格暖缓存复用及原游戏写保护验证已通过；本检查点实际游戏性能验证尚待完成。候选增加位图重建次数、实际访问槽数及对应包围区间计数，用于核实游戏是否命中，不能凭独立对照推断。缓存保留。
