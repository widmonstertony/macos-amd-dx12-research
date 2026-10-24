# Intel / AMD macOS DX12 Research

[中文](README.md) · **English**

Open-source D3D12 → Vulkan → Metal compatibility research for Intel Macs with AMD GPUs. The primary reproduction target is the licensed Windows Steam edition of **Stellar Blade**. Contributions on shaders, synchronization, caches, Wine windows, and performance are welcome.

> **Experimental; not yet playable.** The latest game run reached correctly rendered output at about 6 FPS. One real fault is now localized to the only 61,365-index draw in the 14th encoder, while the Metal command buffer still ran for 7.21 seconds and triggered the AMD GPU watchdog. Downloads are developer test kits, **not a finished solution that lets every Mac run Stellar Blade**. Probe success does not establish game compatibility, FSR3 support, or support for other games/GPUs.

See the [2026-10-23 checkpoint](docs/CHECKPOINT-2026-10-23.md) and [full research state](docs/STATE.md) for exact candidate hashes, tests, and limitations. The public download remains an experimental baseline without a playable-game claim.

## Download and test

[Latest diagnostic download](https://github.com/widmonstertony/macos-amd-dx12-research/releases/tag/v0.2.0-watchdog-diagnostic) · [Testing](docs/TESTING.en.md) · [Known issues](docs/KNOWN_ISSUES.en.md) · [Contributing](CONTRIBUTING.md)

The relocatable kit contains research libraries, native GPU readback probes, environment inspection, and file verification. It includes no game, Steam client, Apple/Tencent engine, saves, or login state. Probes run independently. Game integration requires your own licensed game and compatible Wine environment; there is no one-click game installer.

```sh
tar -xzf amd-dx12-macos-x86_64-v0.1.0-experimental.tar.gz
cd amd-dx12-macos-x86_64-v0.1.0-experimental
python3 runtime.py verify
python3 runtime.py doctor
python3 runtime.py test --stress
```

Python 3 and x86_64 macOS are required. Radeon Pro 5600M on macOS 26.7.1 is the only GPU/system combination actually validated so far. Other AMD results are welcome but unverified. The kit does not modify Wine, Steam, game assets, or existing caches.

## Architecture and scope

Licensed Windows game → vkd3d-proton / DXIL-DXBC translation → Vulkan/SPIR-V → MoltenVK + SPIRV-Cross/MSL → Metal → macOS AMD driver. Wine window/input behavior is a separate integration layer.

- Revisions and changes: [UPSTREAM.json](docs/UPSTREAM.json), `patches/`.
- Work covers a subset of bounds/null-resource protection, device-address and graphics paths, 3D slices, resource binding, sharded archives, and queue diagnostics with actual GPU output validation.
- The private protection contract is not complete Robustness2, Vulkan CTS, or DX12 conformance. Hardware capabilities are not fabricated.
- The Wine request-number fix applies only to the audited Tencent engine. Do not install it into arbitrary Wine versions.
- Apple/Tencent proprietary engines are neither modified nor redistributed. Game tests use normal licensed Steam launch; no DRM bypass is provided.

## Evidence and limits

| Check | Observed result | Does not establish |
|---|---|---|
| Single / three-queue readback | 2,048 rounds, 8,388,608 words per mode, zero mismatches | Correctness of all game synchronization |
| Compute / graphics fixtures | GPU readback and pixel comparisons | Complete DX12 / Robustness2 support |
| Compute archives | 33 strict hits in an isolated Wine fixture | Elimination of game recompilation |
| Steam launch and scene entry | Reached earlier; serious defects | Stable gameplay |
| Latest fault replay | About 6 FPS; a 24-encoder command buffer watchdog followed the sole 61,365-index draw in encoder 14 | That draw is the invariant cause, or safe segmentation is complete |

See the [latest checkpoint](docs/CHECKPOINT-2026-10-23.md). v16 adds a one-shot 512-sample all-draw GPU timestamp mode. The next normal-Steam failure will establish whether the exact draw is stable before an evidence-based resource/shader or intra-command-buffer segmentation repair. Feature-bit changes and device creation alone are not valid compatibility evidence.

## Source, build, recovery

`workspace/` preserves the research layout. Historical scripts/evidence contain machine-specific paths and are not public entry points. `public/` contains the relocatable kit tools. The historical recovery archive under `artifacts/` has old path-bound proxies and must not be installed as a general-purpose runtime.

```sh
python3 scripts/restore_snapshot.py --verify-only
python3 scripts/restore_snapshot.py --target /new/nonexistent/research-restored
bash scripts/build_native.sh /restored/research/root
```

[Build](docs/BUILD.md) · [Recovery](docs/RESTORE.en.md). File restoration and native CMake configuration were verified; a complete cross-machine build and playable installation were not.

## License and acknowledgments

Upstream licenses remain in force. New public tools/docs are MIT; derived third-party code retains its own license. See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and `LICENSES/`. Releases provide corresponding source and the fixed Wine baseline alongside binaries.

Thanks to the upstream projects and fxgl/steamac research. An Apple Silicon demo precedent does not establish Intel/AMD retail-game compatibility. This project is not affiliated with the game publishers, Apple, Tencent, or Valve.
