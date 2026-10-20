# Experimental kit guide

[中文](TESTING.zh-CN.md)

**Not yet playable: this is not a one-click Stellar Blade compatibility patch.** Known problems include GPU timeouts, very low frame rates, blue rectangles, and lengthy compilation. The kit provides runnable native diagnostics and research libraries for collaboration, not guaranteed game startup or sustained gameplay.

## Standalone checks

Requires x86_64 macOS and Python 3. Only Radeon Pro 5600M / macOS 26.7.1 has actual validation evidence. Probes directly link the included MoltenVK; no Vulkan Loader, Wine, or game installation is required.

From the extracted kit directory:

```sh
python3 runtime.py verify
python3 runtime.py doctor
python3 runtime.py test --stress
```

Reports default to `~/Library/Logs/AMDDX12Research/timestamp/`. Use `test --stress --output /new/report/directory` to choose a new directory. The smoke fixture performs 64 fill/copy/timeline/readback rounds. The burst fixture performs 2,048 rounds with sixteen rounds queued before each host wait/readback. Both default and specialized queue modes are checked using actual GPU data.

A real AMD GPU is selected. On multi-GPU systems, optionally use `AMD_DX12_DEVICE='5600M' python3 runtime.py test`. This is a name filter, not an adapter or capability override. Missing hardware/features result in an explicit failure.

Binaries are ad-hoc signed and not notarized. If macOS blocks downloaded files, use its file-specific Privacy & Security approval flow. Do not disable SIP, Gatekeeper, or other system protections.

## Libraries and game integration

- `lib/libMoltenVK.dylib`: the current open-source AMD research candidate.
- `windows/d3d12.dll` and `d3d12core.dll`: built from the corresponding vkd3d-proton source.
- `wine-version-specific/winemac.so`: specific to the audited Tencent server. **Not installed automatically; never replace arbitrary Wine modules with it.**
- DXGI, Steam, game assets, and Apple/Tencent engines are not included. Supply a DXGI provider matching your own environment; this package does not solve those external prerequisites.

There is currently no general game deployment/launch tool. Historical launch scripts are tied to the original research environment. Integration requires an isolated runtime directory, regenerated proxy/path configuration, matching module versions, and native/Wine GPU/presentation qualification before a normal licensed Steam launch. See the repository's BUILD/RESTORE guides and source. Do not run Shipping.exe directly.

Do not install old path-bound proxies from the historical recovery archive onto another machine. The kit does not clear existing caches, edit the registry, write game directories, or replace installed engines. Back up original files and saves before manual integration.

## Share results

Include GPU, macOS, commit/package version, and `report.json`. Review paths/personal information before sharing. Do not upload account data, full dumps, or extracted game shaders/assets. Passing these fixtures establishes only the tested synchronization/readback behavior, not game compatibility.
