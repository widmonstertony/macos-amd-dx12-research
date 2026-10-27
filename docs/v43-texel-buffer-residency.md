# v43: Reduce readonly texel-buffer registration cost / 降低只读缓冲区纹理登记开销

Actual v42 scene evidence found 1,176–1,320 writable-capable, non-attachment buffer-backed texture views in large readonly tables, with only seven resources eligible for heap preparation. The runtime spent substantial CPU time registering individual resources. Capability flags alone do not describe binding access.

实际 v42 场景的大型只读表包含 1,176–1,320 个具备写入能力、非渲染附件的缓冲区纹理视图，而只有 7 个资源能走批量登记。CPU 大量耗在逐个资源登记。具备写入能力不等于当前绑定正在写入。

The change admits private, single-sample native texture-buffer views with matching backing-buffer heaps into readonly heap plans. Multiple views of the same physical buffer validate one allocation range. Different overlapping placement allocations, unknown ranges, render targets, atomics, parent-image views and unsupported storage stay precise. Actual writable bindings remain precise; the existing encoder ledger replays write declarations after readonly heap preparation. No resolution, FSR setting, shader, cache format or advertised device feature changes.

修复让符合条件的私有缓冲区纹理视图走只读批量登记；同一物理缓冲区的多个视图只校验一次分配范围。不同物理分配的重叠、未知范围、渲染附件、原子访问和不支持的存储方式仍走逐个登记。实际写入绑定保留原有登记及写入重放。没有修改分辨率、FSR 设置、着色器、缓存格式或设备功能声明。

On Radeon Pro 5600M, real GPU readback passed: 4,096 direct Metal values; 3,096 values through the actual MoltenVK resource helper including readonly/writable table ordering; 24,576 mixed texture pixels including unchanged old-cache reuse; 512 geometry pixels with 8,192 split primitives. All comparisons passed. CPU negative controls retain overlap, storage and heap-identity rejection. These qualify correctness of the covered cases, not game FPS.

5600M 的真实 GPU 回读通过了直接 Metal、实际 MoltenVK helper 的读写顺序、混合纹理、旧缓存复用和几何绘制回归，比较结果无差异。CPU 反例继续拒绝重叠分配、错误存储和错误堆身份。以上证明覆盖用例的正确性；尚未证明实际游戏帧率改善。下一步测原 Wine/Steam 同场景资源登记数量与 CPU 成本。
