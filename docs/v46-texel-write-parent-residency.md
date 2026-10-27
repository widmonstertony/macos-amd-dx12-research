# v46: Coalesce texel-buffer write residency / 合并缓冲区纹理写入登记

The human-confirmed v45 scene applied up to 300 additional images per plan. Approximately 20-second windows saw precise read references drop from 5,748,348 to 1,947,244 and NativeRead self time from 3.092 to 1.074 seconds. Workload layouts differ; this is not a controlled FPS comparison. The human still reports obvious stutter. Remaining NativeWrite self time was 1.672 seconds, and ResourceGroup self time 4.874 seconds. Code optimization remains the priority; no hardware or power settings were changed.

v45 实际场景中，每个计划最多新增覆盖 300 个图像。两次约 20 秒窗口的逐个读取登记从 5,748,348 降至 1,947,244，NativeRead 自耗时从 3.092 降至 1.074 秒；资源布局不同，不能当严格帧率对照。用户仍反馈明显卡顿，写入登记自耗时 1.672 秒，资源整理 4.874 秒。继续优先修代码，未更改硬件或电源设置。

v46 keeps logical resource identities, stage union, heap identity validation and replay in the encoder ledger. Only the final native write declaration uses the exact MTLBuffer parent of qualified private, heap-backed, writable texture-buffer views. Identical parents are deduplicated within one stage batch and explicitly retained. Different buffer objects never merge by heap/range; ordinary images, shared/heapless resources, atomics and mismatched parents keep their original declaration. A test-only helper switch permits same-library before/after comparison. Game runtime configuration, caches, resolution and FSR settings remain unchanged.

v46 保留账本中的逻辑视图身份、阶段合并、堆身份校验和重放，仅在最终原生写入登记中，对合格的私有缓冲区纹理视图使用其精确 MTLBuffer 父对象；同阶段同父对象去重并显式持有。不同缓冲区不会因堆相同或范围相似而合并，普通图像、共享/无堆、原子和父对象不匹配仍走原路径。helper 中的测试开关支持同一库对照；游戏配置、缓存、分辨率和 FSR 设置均保留。

Direct Metal controls use 128 indirectly writable views (without direct texture binding), automatic/placement heaps, shared/distinct parents and cross-format aliases. Actual-helper controls compare identical output with logical versus canonical writes: 257 native write references become 3, while two write API calls and one heap call remain unchanged. Combined GPU controls and image/old-cache/geometry regressions checked 45,640 values/pixels with zero differences. CPU controls, including ASan/UBSan, preserve identity errors, logical read/write supersession, stage coverage, reset and failure retry.

独立 Metal 用例通过参数缓冲区间接写入 128 个视图，覆盖自动/placement 堆、共享/不同父对象和跨格式别名，不直接绑定写入纹理。实际 helper 对照中，写入登记从 257 项降至 3 项，两次写入 API 和一次堆调用保持一致，GPU 输出相同。合并全部 GPU、图像、旧缓存及几何回归共比较 45,640 个输出，零差异。CPU 及内存检查保留身份错误检测、逻辑读写覆盖、阶段、重置和失败重试。

Current ledger snapshots distinguish `logicalPreciseWriteReferences`, `nativePreciseWriteReferences` and `texelParentWriteRequests`. Actual game parent-sharing frequency and FPS improvement are not yet verified. This is a generic MoltenVK rule validated on Radeon Pro 5600M, not a game-name/shader-hash workaround or a claim of complete DX12/FSR compatibility.

运行日志新增区分逻辑写入数、实际原生写入数和父缓冲区转换请求数；游戏里的实际共享父对象比例和帧率收益仍待验证。这是已在 5600M 验证的通用 MoltenVK 规则，不依赖游戏名或着色器哈希，也不代表完整 DX12/FSR 兼容已经完成。
