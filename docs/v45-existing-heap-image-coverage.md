# v45: Image coverage inside existing heap plans / 已有堆计划中的图像覆盖

This is a generic MoltenVK resource-management rule, not a game/shader-name workaround. Stellar Blade supplies the observed workload and integration regression. v44 reduced normalized scene ResourceGroup self time from approximately 715 to 548 ns per precise reference (about 23%); live resource layouts differ, so this is not a controlled FPS comparison. The human reports improvement but still substantial stutter. Native AMD indirect-resource declaration remains expensive.

这是 MoltenVK 通用资源管理规则，按资源属性工作。剑星用于定位瓶颈和集成验证。v44 场景采样中，按逐个登记资源量归一的 ResourceGroup 自耗时约从 715 降至 548 ns/项，约下降 23%；两轮资源布局不同，不能视为严格帧率对照。用户反馈有所改善但仍明显卡顿，AMD 原生间接资源登记仍是热点。

v45 allows validated private 2D/2D-array image views, including writable/attachment-capable images in readonly bindings, to share heaps that the original plan already selected. Original baseline group sizes determine group eligibility and the 128-child admission gate. Additional images cannot introduce a heap or promote an ineligible group. Parent allocation identity, known placement ranges, non-overlap, storage/usage and alias exclusions remain checked; actual writable bindings remain precise and writes replay after heap reads.

v45 让符合条件的私有二维图像及视图，在只读绑定时复用原计划已经选中的堆。分组和 128 项准入仍按原始合格资源数决定，额外图像不能新增堆或使不合格分组越过门槛。父分配身份、已知范围、非重叠、存储及别名条件继续校验；实际写入绑定保持逐个登记，写入使用信息在堆读取声明后重放。

A direct Metal rendered-image/view control checked 32,768 outputs, including an active attachment and unused rendered images in the same heap. Output was correct, but a placement/extra-attachment variant had worse GPU timing (871,204 versus 195,695 ns median). Timing was collected with Metal validation enabled, not as a game benchmark. This negative result is retained; v45 therefore extends coverage only without adding heap declarations.

独立 Metal 用例验证了已渲染图像及其视图，包括同堆活动附件和额外附件，32,768 个输出无差异。但一个 placement 堆额外附件变体的 GPU 时间变差，保留了该负面结果；计时启用了 Metal 验证，不能当游戏基准。v45 因而限制为不新增堆声明的覆盖扩展。

Actual-helper GPU controls checked 6,168 values: a 128-baseline/128-additional-image case kept two render heap declarations and one compute heap declaration; a 127-baseline case emitted no heap declarations. Vertex/fragment stages, writes before and after reads, encoder resets and precise fallback passed. Existing texel-buffer helper checked 3,096 values, mixed-texture/old-cache regression 24,576 pixels, and geometry 512 pixels/8,192 primitives, all with zero differences. CPU negative controls preserve gate, heap, overlap, unknown-range and storage rejection.

实际 helper 的 GPU 对照检查了 6,168 个值：128 个基准资源加 128 个额外图像时，渲染堆声明仍为两次、计算堆声明一次；127 个基准资源时不发堆声明。顶点/片元、读前读后写入、编码器重置及逐个回退通过；原有缓冲区纹理、混合纹理与旧缓存、几何回归也无差异。CPU 反例继续验证门槛、堆、重叠、未知范围及存储限制。

An initial owned helper control retained a 129-item compute bound after expanding its table to 257 items. Exactly the unwritten 129..256 tail differed in both compute readbacks; render output was correct. The test bound was fixed and all four cases then passed without changing the native candidate. Historical failure evidence remains local. No game assets, resolution, FSR settings, cache format, proprietary driver or device feature claims changed. Actual v45 game performance remains pending.

初版自有 helper 用例扩成 257 项后漏改了 129 项计算上限，两次计算回读的未写尾部精确对应全部差异，渲染输出正确。修正测试上限后四个用例全部通过，原生候选未变；历史失败证据保留在本地。游戏素材、分辨率、FSR 设置、缓存格式、闭源驱动及设备功能声明均未改。v45 实际游戏性能尚待验证。
