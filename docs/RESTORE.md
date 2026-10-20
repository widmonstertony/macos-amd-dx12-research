# 恢复步骤与边界

## 1. 先校验，再恢复到新目录

```sh
python3 scripts/restore_snapshot.py --verify-only
python3 scripts/restore_snapshot.py --target /新的空目录/gptk-intel-research-restored
```

脚本核对每个源码文件、压缩包和运行库的 SHA-256，并重建保存过的内部源码依赖链接。目标目录必须不存在；它不会覆盖原工作目录，不会改应用宝、Steam、存档或缓存。`snapshot-manifest.json` 是此次备份内容的权威清单。

## 2. 同机恢复代码

保留现有原始研究目录作为独立副本。对比恢复目录与原目录后，只恢复所需源码或使用恢复目录继续构建。保存的历史脚本、JSON 和配置中存在 `/Users/tonytan/...` 绝对路径；应重新生成当前机器配置，而非批量替换二进制中的路径。

原生候选库自身可重新构建：

```sh
bash scripts/build_native.sh /恢复后的研究根目录
```

此入口不部署、不启动游戏。原生依赖固定源码已保存，CPM 引导脚本也已保存。工具链 / SDK 的不同可能改变二进制哈希；重新构建后必须重跑真实 GPU 回归，不能复用旧哈希的资格结论。

## 3. Wine 窗口模块与 D3D12

完整 Wine / CrossOver 基线来自 `https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz`。本仓库保存了涉及的修改模块、头文件、基线归档哈希、配置参数和累计补丁。需要重建时取得同一归档，校验 `docs/UPSTREAM.json`，使用源码快照覆盖相应路径，并在独立构建目录配置原参数后构建 `dlls/winemac.drv`。不要把研究模块安装覆盖到应用宝原引擎中。

窗口模块的服务器请求编号映射仅对当时审计过的应用宝服务适用。若应用宝升级，先重新审计；旧证据中的服务哈希和请求编号不能套用到新版本。

vkd3d-proton、DXIL/DXBC 转换器源码和 Meson 参数已保存。Windows 工具链是 llvm-mingw `20261006-ucrt-macos-universal`，原始下载归档未打进 Git；需要重新安装或下载同版本，并重新生成 `cross-x86_64.ini` 的编译器 / widl 路径。保存的 `build/vkd3d/meson-info/intro-buildoptions.json` 记录构建选项。

## 4. 同机恢复运行库选择

运行库压缩包包含独立候选文件，不包含应用宝 / Apple 闭源引擎。加载代理内含当时的绝对候选路径，因此移动目录后必须用已保存的 `src/mvk_guard_proxy.c`、`build/mvk-queue-dependencies-game/build.json` 中的编译命令和 `game-trial-config.h` 在新路径重新编译并签名。新代理的哈希会变化，需要重新资格检查。

当时使用的选择入口为 `/private/tmp/mvk` 和 `/private/tmp/mvk-guard-proxy-select/libMoltenVK{,.1,.1.4.2}.dylib`，均指向研究目录中的独立代理。临时目录可能在重启后消失。**只在确认无目标游戏运行且完成资格检查后**重建这些软链接；不覆盖正在映射的库文件，不重置应用宝原前缀，不修改安装引擎。此前选择目标保存在 `evidence/queue-dependency-trial-preview-20261020/selector-before.json`。

原来的 DXGI 提供者来自已存在的 macOS DXVK 环境，未在本仓库重新分发；依赖文件的路径和哈希单独记录在 `docs/local-runtime-dependencies.json`。正常 Steam、合法游戏安装、原有 Wine 前缀和引擎仍是外部前提。

## 5. 缓存与游戏状态

缓存没有被删除，也没有上传到 Git：游戏派生的着色器和大型归档留在原研究目录的 `open-game-stack-20261015/build/private-shader-cache` 与 `build/game-metal-binary-cache`。它们是可重建的加速数据；本备份不保证重装系统后还能免编译。存档应由用户自己的本机 / Steam 云备份保管。

每次通过 `tools/launch_stellar_deferred_proxy.py` 走正常 Steam 请求，先核对精确候选哈希、真实 GPU / 窗口回归和游戏映射及原资产写保护。保存的 `launch-proof.json` 是历史证据，不是对新路径、新编译库的自动批准。
