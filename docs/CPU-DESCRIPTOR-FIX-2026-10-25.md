# Descriptor interior filtering / 描述符中间区块筛选

Actual game CPU samples identified the scalar identity comparison in
`MVKDescriptorUseCache::resourcesImpl<true>` as a hot spot. Coalesced dirty ranges
can change at both ends while most interior identities remain unchanged. Existing
edge trimming then leaves the complete interior to the scalar updater.

实际游戏 CPU 采样命中了 `resourcesImpl<true>` 的逐项身份比较。合并后的脏区间可能
两端有变化，中间大片身份未变；原有边缘裁剪在这种情况下仍留下完整的中间标量扫描。

The candidate adds a separate bounded pre-pass for sparse contiguous ranges.
It removes only byte-identical blocks, keeps every differing block and partial
tail, and retains the original scalar membership/count/delta updater. Dense and
strided tables keep that updater. More than 256 filtered fragments aborts the
pre-pass without changing the original dirty ranges. Descriptor range locks,
resource liveness and GPU read/write declarations remain in place.

候选修复对稀疏连续区间增加有界预处理：仅剔除字节完全相同的区块，保留所有不同区块
与尾部；成员集合、引用次数和增量更新仍使用原标量更新器。密集及非连续表保留原更新
路径。若筛选产生超过 256 个片段，则保留原区间完整回退。描述符锁、资源存活检查和
GPU 读写声明继续生效。

The frozen previous header and a standalone comparison are included. Independent
set-oracle checks passed 2,880 ordinary cases and 960 fragmentation cases. Sparse
contiguous cases improved about 1.35–2x in this CPU control; this is **not a game
FPS improvement claim**. Earlier variants with dense/strided regressions were not
deployed.

已保存前一版头文件与独立对照。普通场景 2,880 次、碎片场景 960 次集合核验均通过。
CPU 对照中的稀疏连续场景约快 1.35–2 倍，**不代表游戏帧率提升同样倍数**。先前导致
密集/非连续布局明显倒退的写法未部署。

Real Radeon tests passed a 500,000-slot descriptor scenario (including changes at
both ends and the middle, removal and late registration), query output and
geometry splitting. Original Tencent Wine compute, presentation and cold/warm
archive qualification passed for the exact candidate.

真实 Radeon 对照通过 50 万槽位描述符场景（两端和中间同时改变、移除、晚注册）、
查询输出及几何切分；确切候选库通过原应用宝 Wine 的计算、呈现和冷暖缓存回归。

At this checkpoint, the candidate has been deployed and launched through the
existing licensed Steam client. **Actual scene performance after this change is
still awaiting verification. The game is not declared playable.** Both FSR3
features remain unverified. No resolution reduction or feature disabling is part
of this change.

当前检查点已部署候选并经原正版 Steam 启动，**修复后的实际场景性能仍待验证，尚未
宣称游戏可玩**。FSR3 两项仍未验证。本改动没有通过降低分辨率或关闭功能来算作修复。
