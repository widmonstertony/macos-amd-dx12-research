# v37 sampled read plan / 采样纹理读计划

This is an experimental source checkpoint. **Stellar Blade performance, historical crashes and FSR3 remain unvalidated.** No new playable release is claimed.

这是实验源码检查点。**尚未证明《剑星》的实际帧率、历史闪退或 FSR3 已修复。** 本次没有发布新的可玩成品包。

## Changes / 修改

- Native runtime shader-access metadata now combines a conservative SPIR-V whitelist, resolved SPIRV-Cross image operands and final MSL access checks. Unknown access falls back. Serialized cache layout, UUID and generated MSL remain unchanged. Old cached MSL is requalified once and must match regenerated source exactly; optional qualification failure falls back to precise preparation.
- Eligible owned 2D/2DArray private sampled textures can use immutable heap plans. Shader writes, render targets, views, buffer textures, unsupported types and unknown/overlapping placement ranges retain precise declarations. `isAliasable` alone does not prove actual overlap in an explicit-placement heap; automatic aliasable heaps remain excluded.
- Encoder-local precise reads are deduplicated only while coverage remains valid. Heap stage/membership changes replay precise read and write exceptions. New encoders reset coverage. Same-binding sample-to-fetch pipeline changes invalidate the weaker preparation decision.
- Presentation changes add bounded request/call/callback identity and lock timing. They **do not change scheduling or claim to fix presentation delay**.

对应中文说明：原生转换路径加入保守的采样访问资格；只对满足 shader、纹理属性、所有权和非重叠条件的资源使用 heap 计划。精确读取、写入、阶段升级、encoder 重置及未知情况保留正确回退。呈现部分只补身份和时间证据，尚无确定根因修复。

## Owned validation / 独立验证

| Check / 检查 | Result / 结果 |
|---|---|
| Stable full Native build | Passed; no source changed during compilation |
| Authored conversion fixtures | 15 converted; 6 safe cases eligible, unsafe cases fell back; MSL byte-identical to v36 |
| Private cache-prefix shader sample | 64 converted; 27 eligible fragment modules; all 64 MSL outputs byte-identical. This is not game-weighted coverage |
| Encoder ledger CPU controls | 1,292,945 checks; ASan/UBSan passed; prior actual-header control also passed |
| Public Vulkan → Metal texture output | Six bounded cases, 2,048 pixels each; BC1 UNORM contract allows channel error ≤1; no mismatches under that contract |
| Same-binding pipeline transition | Sample → texelFetch → vertex-heap-stage upgrade + fragment fetch → sample, four requested render encoders; output passed, precise fetch preparation retained |
| Owned v36 Vulkan cache → v37 | Six actual shader-stage cache-hit feedback flags; correct output and actual texture-plan application |
| Sample-only declaration control | 512 precise child-read declarations → 0, replaced with 4 heap declarations; correct output. This is an API-work reduction, **not a game FPS ratio** |
| Existing buffer lifecycle GPU oracle | 776 exact values, zero mismatches on the final library |
| Existing geometry→mesh split control | 512 pixels / 8,192 primitives, zero component mismatches |
| Original Tencent Wine D3D12 controls | Compute and presentation passed; strict native compute/render archive reuse passed using a private candidate, without replacing the live backend during qualification |

RGBA8 sampled images with Vulkan TRANSFER_DST usage acquired Metal `ShaderRead | RenderTarget` usage in the control. They correctly retained precise preparation. The BC1 case covers a legal read-only compressed-texture class; it does not justify removing RenderTarget flags or extending heap preparation to every texture.

RGBA8 上传纹理控制实际带有 Metal RenderTarget 标记，继续走精确声明。BC1 控制证明的是合法只读压缩纹理类别，不能据此删除其他纹理需要的标记或宣称所有纹理都已加速。

The private Native candidate before deployment signing has SHA-256:

```text
c59bda0e03ada19d88c9fec391260bfcbbba7e680ed9728cff13b69a0e42e613
```

## Remaining / 未完成

Actual game FPS/frame times and the eligible resource mix still need a human-operated scene run. Presentation delays, the historical asynchronous PSO fault, Wine Submit2 assertion, equipment watchdog and enabled FSR3 upscaling/frame generation have not been closed. The six legacy forced-off Engine.ini overrides were backed up and removed on the test host; saved user menu choices were preserved. This is not successful feature-support validation. No game resolution reduction is part of this change.

仍需真实游戏日志确认帧率和资源类别覆盖；不能把组件测试通过当成全部问题已修好。游戏操作和测试由用户执行。公开仓库只加入开源代码、作者自建控制及汇总；不上传游戏着色器、原始客户端日志、存档或登录状态。
