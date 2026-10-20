# Recovery guide

The snapshot preserves source, selected evidence, pinned baseline archives, and the runtime files listed in `snapshot-manifest.json`. It is not a complete transferable game environment.

```sh
python3 scripts/restore_snapshot.py --verify-only
python3 scripts/restore_snapshot.py --target /new/nonexistent/research-restored
```

The target must not exist. The tool checks hashes, restores source/runtime files and internal source links, and does not overwrite existing work or start any application.

Historical paths refer to the original machine. Regenerate local build/proxy/launch configuration instead of editing binary strings. The path-bound proxies in `artifacts/runtime-20261020.tar.gz` must be rebuilt for a new location. A new hash needs fresh qualification; historical launch-proof JSON is not an approval for a changed library/environment.

Rebuild native code with `scripts/build_native.sh /restored/research/root`. Windows components require the pinned llvm-mingw toolchain, Meson/Ninja, matching widl, and regenerated cross-file paths. Wine window code is based on the fixed CrossOver 26.3.0 source archive; verify its hash in `UPSTREAM.json`, overlay the saved module/headers, and use the saved configure options. Re-audit server request IDs if the Tencent engine changes.

The original game used research selector symlinks under `/private/tmp`; those can disappear on reboot. Do not overwrite mapped libraries or modify an installed engine. Recreate selectors only after module qualification and after the target game exits. Launch licensed games normally through Steam.

Game files, saves, credentials, Steam clients, proprietary engines, raw dumps, and large game-derived caches are excluded. Existing caches remain at the original local paths and are rebuildable. DXGI remains an external environment-specific dependency. Preserve your own game saves separately.
