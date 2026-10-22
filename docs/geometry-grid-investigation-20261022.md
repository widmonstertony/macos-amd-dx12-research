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

Next investigation: compare compact shared vertex-payload layouts with matched vertex/geometry interfaces, then re-run the unique-output large indirect oracle. Do not deploy a failed control or call this complete based on device creation.
