# Geometry-emulation investigation / 几何阶段模拟排查

Status: experimental source checkpoint. This is **not a playable-game release**. The ordinary-indirect candidate was tested in the original Wine environment; the CPU replay optimization below is separately qualified.

状态：实验性源码检查点，**不是已经能流畅游玩的发布版**。普通间接绘制候选已通过原 Wine 进入场景；下述 CPU 资源复用优化另做独立验证。

## Changes / 修改

- Bound AMD direct object-stage dispatches while preserving global primitive IDs, instance IDs, indexed offsets, strip parity, fan anchors and transform-feedback slots.
- Extend the shared draw-info ABI consistently in CPU code, generated MSL and the GPU indirect converter. Bump the local pipeline-cache revision; retain existing cache files.
- Declare one mesh group per generated object invocation, matching the generated wrapper contract. Declare the serial object/mesh thread bounds explicitly.
- Add opt-in generated-parameter readback for owned probes, plus Vulkan output oracles and separate Metal controls.
- Validate unchanged MoltenVK **and SPIRV-Cross** sources across each native build.

直接派发分批时保留全局图元及实例编号，并统一 CPU、生成代码与 GPU 参数结构；缓存版本更新但不删除原缓存。网格组和线程上限与生成代码的实际行为一致。

## Actual GPU results / 真实 GPU 结果

Tested on AMD Radeon Pro 5600M. The Vulkan oracle checks unique primitive/instance values, three topologies (list, strip, fan), and non-indexed direct, indexed direct, indexed indirect paths. Nonzero indirect first-instance is explicitly requested from the device feature set.

| Primitives per instance / 每实例图元数 | Instances / 实例数 | Direct cases / 直接绘制 | Indirect cases / 间接绘制 |
| --- | --- | --- | --- |
| 64, 85, 86, 128, 256 | 3 | All correct / 全部正确 | All correct / 全部正确 |
| 512, 1024, 1031 | 3 | All correct / 全部正确 | Incorrect / 输出错误 |

At 1,031 primitives, 111,348 components were checked across nine cases: all six direct cases passed; all three indirect cases failed. GPU readback confirmed the generated indirect grid, primitive count, signed vertex offset and first-instance values were correct. An extra blit synchronization did not correct the output.

A small independent Metal direct/indirect control checked 1,536 components with zero mismatches. Earlier fixture coordinate expectations were corrected for Metal's Y direction; the earlier failed result was retained locally.

A separate layered-depth control checked 172,032 output/padding values without errors after declaring the exact mesh-grid bound. Its overlapping identical triangles **do not prove unique output from every input primitive**. The Vulkan oracle supplies that separate coverage.

在较小工作量下九种绘制全部通过；较大工作量下，直接绘制已通过，间接绘制仍会丢失输出。GPU 生成参数正确，额外同步没有解决。尚未证明这是闭源驱动或硬件的固定限制。

## Rejected controls / 未通过的对照

Changing to threadgroup-position coordinates did not help. A GPU-only tiled indirect grid remained incorrect and is excluded from this source checkpoint. The failed controls are not presented as fixes.

切换坐标内建值无改善；GPU 二维网格改写仍错误，未纳入当前源码修复。

## Limits / 尚未完成

No new game FPS result, costume stability result, or FSR3 validation is claimed. No game resolution, assets, saves, credentials or active cache was changed by these probes. Private game-derived shader sources, screenshots and raw diagnostics are excluded from this public checkpoint. Existing downloadable runtimes are unchanged.

本检查点没有新的游戏帧率、换装稳定性或 FSR3 验证结论。未修改游戏分辨率及活动缓存。公开内容仅包含开源修改、自有测试和这份结论；不含游戏派生着色器或私人日志。

Follow-up owned-source control: reducing both vertex/geometry payload layouts from 32 location slots to one did not fix a 1,031-primitive single dispatch. Both direct and indirect raw-Metal controls still missed 12,368 components each. Unused payload capacity alone is therefore insufficient to explain the failure. This control does not establish the exact driver scheduling mechanism.

后续自有着色器对照：生产者和消费者同时缩减为一个位置槽位，大网格仍然错误，不能将未使用的载荷容量认作根因。

## Device boundary / 设备能力障碍

The owned `mesh_icb_capability_gpu.mm` probe requested a mesh pipeline with `supportIndirectCommandBuffers=YES`. Metal rejected the descriptor before GPU execution and terminated the process with this explicit validation message:

> Use of mesh shader pipelines in indirect command buffers is not supported by this device.

This blocks the proposed GPU-generated batched mesh ICB route on the tested 5600M/current macOS Metal implementation. No support bit was overridden and no closed driver was modified. This device restriction does not by itself identify the root cause of every game timeout or exclude every alternative translation design.

自有能力测试在管线描述符校验阶段被 Metal 明确拒绝，尚未执行 GPU 工作。当前设备不支持网格管线的间接命令缓冲，所以这条 GPU 分批方案停止。未伪造支持或修改闭源驱动。该限制本身不能证明游戏所有超时的根因。

An alternative compute-based or CPU-mediated path requires a separate engineering and performance assessment. The incomplete native candidate remains undeployed; no new playable-game claim is made.


## Ordinary-indirect alternative / 普通间接绘制替代方案

The mesh-ICB restriction does not block every batching strategy. A new source checkpoint expands Vulkan geometry indirect arguments on the GPU into ordinary Metal indirect mesh commands. It uses no mesh ICB, no CPU readback, and no shader/draw skip.

The bounded prefix follows instance-major primitive order, and generated wrappers restore original primitive IDs, instance IDs, strip parity and per-instance vertex fetches. The last two commands retain the remaining current instance and all subsequent instances. The encoding budget cannot silently drop remainder geometry. Very large remainders may still hit the original large-grid issue; this is not a full resolution of every workload.

GPU results on the 5600M:

- All 12 cases passed at both 1,031 and 4,096 primitives per instance, three instances. Coverage includes list/strip/fan and direct, indexed direct, non-indexed indirect and indexed indirect. Total output components: **738,288; zero mismatches**.
- The actual native parameter-conversion kernel passed **675** combinations of topology, instance count, primitive count and batch budget, checking **9,990** generated commands and **713,610** fields. This checks empty draws, large integer arithmetic, continuous primitive coverage and complete remainder retention; it does not rasterize enormous remainders.
- Original Tencent Wine compute/presentation and warm-cache controls passed. Qualified library SHA-256: `1e327d32fc53ce70fc7b0d0dd7fe991cce6d43486a4bda334289945f8807083c`.
- The qualified library has been deployed for a normal original-Steam game test. Actual scene FPS, attack stability and equipment-menu stability remain pending. No playable-game release claim is made.

已实现不依赖 mesh ICB 的普通间接绘制分批。两档规模的十二种绘制全部通过，另通过 675 组 GPU 参数覆盖检查。尾部保留所有剩余内容；超大尾部仍可能遇到旧的大网格问题。原应用宝 Wine 的计算、呈现和缓存复用回归通过，已进入原 Steam 游戏实测；实际场景帧率和攻击、装备菜单稳定性尚未验证。

The normal-Steam launcher no longer forces a window mode or resolution. Existing game caches and user graphics settings are retained.

Additional upstream references examined for implementation alternatives:

- [DXMT geometry pipeline](https://github.com/3Shain/dxmt/blob/main/src/d3d11/d3d11_pipeline_gs.cpp)
- [DXMT geometry conversion](https://github.com/3Shain/dxmt/blob/main/src/airconv/dxbc_converter_gs.cpp)
- [Tempest compute/vertex mesh conversion](https://github.com/Try/Tempest/blob/master/Engine/gapi/spirv/meshconverter.cpp)
- [MoltenVK indexed/indirect geometry work](https://github.com/KhronosGroup/MoltenVK/pull/2812)

DXMT-style explicit payload capacity and a SIMD-sized object group did not fix the owned large-grid control. A mesh-only diagnostic also did not pass both paths. These controls are not deployed fixes. The ordinary-indirect GPU fan-out above is the alternative that passed the native output oracle.


## CPU resource replay / CPU 资源复用

The ordinary-indirect candidate reached the camp scene with correct visible geometry. A foreground native-presentation interval measured **8.90 FPS**, at the existing 363×263-point window (726×470 content pixels). This remains unplayable. No full-resolution performance or attack/equipment stability claim is made. Shader compiler services were idle. Queue timing and CPU samples identify host-side resource tracking before submission as the next bottleneck.

普通间接绘制候选已进入营地并显示场景，但沿用的小窗口中仍只有约 **8.90 FPS**，没有达到可玩水平。编译服务已空闲，采样主要落在提交前的 CPU 资源登记。尚未证实攻击和装备菜单稳定，也未验证全屏性能。

The next source change caches stable `ResourceInfo` handles alongside validated, retained snapshot resources. Replay avoids rehashing those already-owned identities. Every new Metal encoder still gets the required resource declaration; shader-stage coverage, write upgrades, registry invalidation and descriptor removal remain enforced. Handles are discarded before references or map nodes are released. No shader cache revision, resolution or feature support bit changes.

已验证并持有引用的快照资源附带稳定节点，重复使用时跳过再次查表；仍逐编码器声明资源，并保留阶段、写权限、新注册和描述符删除规则。先销毁快照句柄，再释放引用和节点。没有改分辨率、功能支持位或缓存版本。

- Alternating three-pair CPU control: median **111.862 ms → 19.5033 ms**, **5.74×** for the isolated replay workload. This is not an FPS multiplier.
- Actual AMD GPU: resource-stage/write and registry/descriptor controls checked **275** values with zero mismatches. Twelve geometry cases checked **148,464** components with zero mismatches under Metal API Validation.
- Pointer-hash collision hypothesis rejected: libc++ already mixes pointer keys. The new CPU control records this; no hash modification was deployed.
- New library: `885f999c637f39eadb947b9ae490ffe4d8e6c2d02aa0deba2be46fa9996e7fef`. Original Tencent Wine compute/presentation and strict warm-cache controls passed. The qualified candidate is deployed for a normal original-Steam game run; actual scene FPS remains pending.

单项对照中位耗时减少约 83%，不能据此声称游戏帧率提升 5.74 倍。真实 GPU 资源与几何回归通过；这个新候选的原 Wine 计算、呈现和严格缓存命中回归也已通过，已部署供原 Steam 游戏实测，实际场景帧率待测。FSR3 超分、帧生成和持续流畅游玩均未验证。本次仅备份源码，现有下载包不代表新的可玩发布版。


### Actual replay-only candidate outcome / 第一项复用优化实测

The `885f999c…` candidate completed compilation and reached the camp. The foreground scene measured **7.50 FPS** at the inherited window size; the view differed from the prior interval, and no game FPS improvement is established. Opening inventory worked, but switching three tabs toward equipment reproduced a GPU timeout. The failed game was stopped after preserving evidence; original Steam and caches remained. Resource replay speed and equipment GPU stability are separate unresolved issues.

第一项候选已编译完成并进场景，但实测仍只有约 **7.50 FPS**，不能声称游戏加速。背包能打开，连续切向装备页仍复现 GPU 超时。失败证据保留后仅结束了游戏，原 Steam 和缓存保留。CPU 单项快不等于装备页稳定。

### Shared registry validation / 跨命令缓冲共享验证

The next opt-in source candidate shares immutable, owned validation results across command buffers. It caches at most 16 snapshots and 16,384 retained identities per registry. Registrations change the version; removing the last registration promptly evicts cached owners. Readers hold independent shared leases, so cache eviction cannot destroy an in-flight resource. Every new encoder still receives stage/access declarations. Concurrent mutation prevents publishing a mixed registry observation.

新的可选路径让多个命令缓冲共享验证结果，每个注册表最多 16 个快照、16,384 个资源引用。新注册使版本失效；最后一项注册移除时立即清掉缓存引用。执行中的读者持有独立引用，逐编码器的权限声明仍保留。并发变更期间的混合观察不会发布进缓存。

- Real AMD GPU controls: **283** resource output values, zero mismatches, across registry/descriptor/stage tests; **148,464** geometry components, zero mismatches.
- Six independent helpers verified shared validation, registration removal, surviving borrowed leases and prompt cache ownership release. **1,000** concurrent mutation iterations passed.
- Same native library and same resources, three alternating CPU pairs: **164.309 ms → 62.9491 ms** median, **2.61×** for 128 helpers × four encoders. External CPU load produced visible timing variance; this is not an FPS multiplier.
- Original Tencent Wine D3D12 descriptor-UAV output, compute/presentation and strict warm-cache controls passed.
- Library SHA-256: `5f47d2fdf977f5fbab6c2ea45bbb18c639ba978d539d3c5d8862c70b9a3bdd50`. Deployed for a normal original-Steam run. Actual scene FPS and equipment timeout behavior are pending for this candidate.

共享验证已通过真实 GPU、并发寿命、原应用宝 Wine 与缓存回归；已部署供原 Steam 实测，游戏效果仍待验证。不开启计数采样测基础帧率，再单独限时采集装备页故障。未修改分辨率、缓存版本、闭源驱动或游戏文件。仍没有可玩或 FSR3 全功能通过的发布声明。
