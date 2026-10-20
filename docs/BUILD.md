# 构建 / Build

## 原生库 / Native library

Requires macOS, Xcode Command Line Tools, CMake, and the pinned source snapshot. 需要 macOS、Xcode 命令行工具、CMake 和固定源码。

```sh
python3 scripts/restore_snapshot.py --target /new/research-restored
bash scripts/build_native.sh /new/research-restored
```

Set `BUILD_JOBS=2` to limit CPU load. `NATIVE_CONFIGURE_ONLY=1` configures without compiling. 构建不部署、不启动游戏。This does not deploy or launch a game. New binary hashes require new GPU qualification; do not reuse historical proofs for a rebuilt library.

## 公开实验包 / Public kit

```sh
python3 scripts/build_public_release.py --output /new/release-build
```

The builder verifies the historical artifact hashes, selects only redistributable research libraries, compiles probes linked directly to the included MoltenVK with `@executable_path/../lib`, and creates a checksummed archive. 不分发旧的硬编码路径代理；不会修改现有应用宝、Wine、Steam 或游戏。

The public queue helper selects an actual AMD device and only requests features used by the fixture. It does not replace the research compiler or claim extra hardware support. Source probes are copied into a separate build directory so quoted includes cannot accidentally select the old machine-specific helper.

Before publishing, extract into a different directory, run `verify`, `doctor`, and `test --stress`, then record the exact library hash and output. This validates the kit's probes, not game compatibility. 发布前需换目录解包验证；探针成功不等于游戏成功。

## Windows 与 Wine / Windows and Wine

Use the saved vkd3d-proton Meson options, pinned llvm-mingw toolchain, and matching widl. Regenerate the machine-specific cross file. 对应源码在 `workspace/open-game-stack-20261015/vendor`，构建选项在历史 `build/vkd3d/meson-info/intro-buildoptions.json`。

Wine window-module rebuilding requires the fixed complete CrossOver public-source baseline plus our patch/overlay and configuration. Releases provide the baseline archive as a separate source asset. The server request mapping is engine-specific; re-audit before deploying to a different version. See [RESTORE.md](RESTORE.md) / [RESTORE.en.md](RESTORE.en.md).

Existing build scripts have historical absolute paths. They are preserved for reproducibility/context, not automatically executed by the public kit. Do not bulk-apply all experimental patches: use the full source snapshot or the component's cumulative patch against its exact baseline.
