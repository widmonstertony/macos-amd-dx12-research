# Resource-state value pointers / 资源状态值指针

Actual v29 scene samples still spend substantial time in retained snapshot replay and the resource-state table. The map used a deque iterator return, while its three hot callers only needed a pointer to the stable value. v30 adds an `emplaceValue` entry point and changes those callers. Storage, hash, collision handling, insertion semantics and resource lifetime remain unchanged. Existing iterator users keep the original API.

v29 实际场景中，已保留快照重放和资源状态表仍占较多 CPU。表接口返回 deque 迭代器，而三个热路径调用者只需要稳定值指针。v30 新增 `emplaceValue` 并改用该接口；存储、哈希、碰撞处理、插入语义和资源生命周期保持不变，原迭代器接口保留。

The CPU control uses 4,096 actual Radeon Metal resource identities and checks 24,580 value/stable-pointer operations, including growth, duplicate insertion, clear and reinsertion. Three runs showed existing-entry lookup/insertion speedups of 1.13–2.02 times across the tested table sizes. This is a local CPU result, not an FPS claim. The earlier extra-hash prototype was rejected because it was slower; libc++ already mixes pointer hashes.

CPU 对照使用 4,096 个真实 Radeon Metal 资源地址，核对 24,580 次值与稳定指针操作，覆盖扩容、重复插入、清空及重插入。三次运行中，已有项路径按表规模快约 1.13–2.02 倍。这是局部 CPU 结果，不是帧率结论。此前额外混合哈希的候选变慢，已排除且未部署；libc++ 本身已混合指针哈希。

The native build, descriptor GPU output, query/graphics output, geometry splitting and original Tencent Wine compute/presentation/cache qualification passed. The exact v30 candidate was launched through the existing original Steam client. Its actual scene FPS is pending at this checkpoint. Caches and graphics settings are preserved; the project remains unplayable and FSR3 is unqualified.

原生构建、描述符 GPU 输出、查询/图形输出、几何切分及原应用宝 Wine 计算/呈现/缓存回归通过。v30 确切候选经现有原 Steam 启动，本检查点实际场景帧率尚待验证。缓存与画质设置保留；项目仍不可正常游玩，FSR3 尚未验证。
