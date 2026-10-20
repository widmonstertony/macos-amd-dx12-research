# Third-party notices / 第三方声明

This is a mixed-license research tree. The root MIT scope does not relicense third-party or derived code. 本仓库不将所有上游代码重新许可为 MIT。

| Component | Source and license |
|---|---|
| MoltenVK | Pinned utmapp fork in `workspace/open-game-stack-20261015/native-vendor/`; Apache-2.0; original license retained |
| SPIRV-Cross | Pinned utmapp fork; Apache-2.0 license retained |
| Vulkan / SPIR-V headers | Original notices/licenses retained in their source trees |
| cereal | Original BSD notices/license retained |
| vkd3d-proton and derived DLLs | LGPL-2.1-or-later; COPYING/AUTHORS and full license text retained |
| DXIL / DXBC translators | Original component license and authorship notices retained in `vendor/` |
| Wine window module | LGPL-2.1-or-later; Wine LICENSE, COPYING.LIB, AUTHORS retained in `LICENSES/` |

Exact versions, baseline hashes, and cumulative changes are in `docs/UPSTREAM.json` and `patches/`. The current source snapshot contains modifications; do not assume the upstream commit alone produces the distributed binaries. Original file notices apply to derived changes. 历史补丁也包含弃用实验，不应全部叠加。

For the distributed Wine module, the release also supplies the complete fixed public baseline `crossover-sources-26.3.0.tar.gz`; combine it with the saved modified module/header tree, cumulative patch, and build configuration. The source is available alongside the binary download. No proprietary Tencent/Apple engine is included. The module is version-specific, not a generic Wine replacement.

Historical baseline source archives for MoltenVK, SPIRV-Cross, vkd3d-proton and translators are included in the repository. Public release source is the release tag's full source archive, including build scripts. Native probes are newly authored fixtures and contain no extracted game shader code.

No game assets, DRM components, Steam account state, or DXGI binary are included in the public test kit. Names of games, companies, and APIs identify compatibility targets and do not imply endorsement.
