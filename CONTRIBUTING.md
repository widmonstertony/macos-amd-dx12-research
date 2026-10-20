# 参与贡献 / Contributing

欢迎 Issue、复现、分析和 Pull Request。Welcome issues, reproductions, analysis, and pull requests. English and Chinese are welcome.

## 优先事项 / Priorities

1. **GPU timeout**：定位最早未完成的图形信号生产者，记录原生 enqueue/commit/scheduled 顺序。Locate the earliest incomplete graphics producer; capture native submission ordering. Creation-order snapshots do not prove a dependency cycle.
2. **编译与缓存 / Compilation/caches**：区分 MSL、特化、链接和归档耗时；区分加载文件和严格命中。Separate MSL/specialization/link/archive costs and file loading versus strict native hits.
3. **画面 / Rendering**：把蓝色矩形和输出差异缩减成可分享的独立探针。Reduce corruption to redistributable fixtures.
4. **窗口 / Windows**：核对 Cocoa/Win32 尺寸、输入和缩放状态，不影响共享 Wine 服务。Compare window/input state without disrupting shared Wine services.

## 提交内容 / Evidence

Include GPU, macOS, Wine version, commit/runtime SHA-256, reproduction steps, before/after output, and limitations. 请提供精确版本、复现步骤、修复前后输出和限制。

Clearly distinguish device creation, GPU readback, menus, scenes, and sustained gameplay. 请勿把探针通过写成游戏可玩。

Review logs before sharing. Do not upload credentials, Steam user directories, full dumps, or extracted game shaders/assets. 请勿上传凭据、Steam 用户目录、完整转储或游戏提取的着色器/资产；优先使用新编写的最小复现。

Do not fabricate capabilities, swallow GPU errors, return false success, bypass DRM, or patch Apple proprietary binaries. 不接受伪造功能、假成功码或吞掉错误的“修复”。

See [BUILD.md](docs/BUILD.md). Preserve upstream license headers. Modified third-party code follows its component license; new standalone tools/docs follow the root MIT scope.
