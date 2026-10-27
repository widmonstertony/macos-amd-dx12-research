# v44: Encoder ledger lookup cost / 编码器资源账本查找开销

The human-confirmed v43 scene remains slow. A 20.41-second capture measured ResourceGroup self wall time of 4.457 s, native read registration 2.083 s and native write registration 1.308 s across threads. These are instrumented work spans, not utilization or physical FPS. An additional sample with detailed tracing disabled still finds ledger node allocation and AMD indirect resource registration. The earlier texel-buffer change did not remove the overall bottleneck. The v42 and v43 captures have different live resource layouts, so their totals are not a controlled FPS comparison.

v43 场景仍存在卡顿。20.41 秒采样中，资源整理自耗时为 4.457 秒，原生读取登记 2.083 秒、写入登记 1.308 秒；这是跨线程埋点工作时间，不是利用率或实际帧率。关闭详细日志后抓栈，仍可见账本节点分配和 AMD 间接资源登记热点。上一版没有解决整体卡顿，且前后资源布局不同，不能把两轮采样当作严格帧率对照。

v44 replaces only the three encoder-local identity indexes with reusable dense tables. Mixed hashing handles aligned native pointers; generation clearing invalidates every identity at encoder reset without freeing a node per resource. Ordered heap/read/write state vectors, membership epochs, native declaration order, stage union, write replay, error checks and ownership remain unchanged.

v44 仅将三个编码器内的身份索引换成可复用的紧凑表。散列混合处理对象指针对齐，按代清空使每次编码器重置失效全部身份，减少逐资源节点分配。原有堆、读、写状态向量的顺序、成员代号、阶段合并、写入重放、错误检查及所有权保持不变。

A synthetic scene-scale CPU comparison (not a game trace replay) reduced allocations from 933,888 to 287,744 and elapsed time from 248.183 ms to 128.826 ms. 1,200,128 emitted declaration events matched in order and content. Adversarial collision, duplicate, growth and reset cases passed, including ASan/UBSan; existing identity/ledger controls also passed. Actual helper GPU readback checked 3,096 values; mixed-texture regression checked 24,576 pixels including old-cache reuse; geometry regression checked 512 pixels with 8,192 primitives. No output mismatches occurred. Actual game FPS improvement is still unverified.

接近场景规模的合成 CPU 对照（并非游戏轨迹重放）将分配次数从 933,888 降至 287,744，耗时从 248.183 ms 降至 128.826 ms；1,200,128 次登记输出的顺序和内容一致。碰撞、重复、扩容、重置、内存检查及原有账本回归通过。实际 helper、混合纹理与几何绘制的 GPU 回读均无差异。尚未验证实际游戏帧率改善；需要换入后测同一场景。

Owned CPU comparison source: `workspace/open-game-stack-20261015/src/controls/encoder_resource_index_control.cpp`; the prior implementation is retained as an open-source differential control, not a spare runtime library. No game files, shader cache format, resolution or FSR settings change.
