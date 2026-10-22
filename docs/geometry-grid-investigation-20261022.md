# Geometry-emulation investigation / 几何阶段模拟排查

Status: experimental source checkpoint. This is **not a playable-game release**. The new native library has not been deployed to the original Wine environment.

状态：实验性源码检查点，**不是已经能流畅游玩的发布版**。本次原生库尚未部署到原 Wine 环境。

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
