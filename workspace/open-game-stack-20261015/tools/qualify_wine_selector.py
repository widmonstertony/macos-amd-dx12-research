#!/usr/bin/env python3
"""Qualify the late-sandbox MoltenVK selector on Tencent's real Wine GPU path."""
from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SUPPORT = Path.home() / "Library/Application Support/YYBIntelLauncher"
CONTENTS = SUPPORT / ".runtime/wine-engine.app/Contents"
PREFIX = Path.home() / "Library/Application Support/com.tencent.yybmac.wine.engine/wine"
SELECTOR = ROOT / "build/wine-mvk-selector"
PROXY = ROOT / "build/mvk-guard-proxy/libMoltenVKGuard.dylib"
CANDIDATE = ROOT / "build/moltenvk-bounded-archive/MoltenVK/libMoltenVK.1.4.2.dylib"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_root = ROOT / "evidence" / f"wine-selector-gpu-{stamp}"
    out_root.mkdir()
    tmp_proxy = Path("/tmp/mvk")
    tmp_proxy.unlink(missing_ok=True)
    tmp_proxy.symlink_to(PROXY.resolve())

    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("DYLD_", "WINE", "YYB_", "VK_", "VKD3D_", "DXVK_", "MVK_"))
    }
    env.update(
        WINEPREFIX=str(PREFIX),
        YYB_NTDLL_PATH=str(SELECTOR / "x86_64-unix/ntdll.so"),
        WINELOADER=str(SUPPORT / "wine-loader"),
        WINESERVER=str(CONTENTS / "MacOS/wineserver"),
        WINEDLLPATH=f"{SELECTOR / 'x86_64-unix'}:{CONTENTS / 'SharedSupport/wine/lib/wine/x86_64-unix'}:{CONTENTS / 'SharedSupport/wine/lib/wine/x86_64-windows'}",
        GFX_BACKEND_PATH=str(ROOT / "backend/wine"),
        WINEDEBUG="-all,err+all,+loaddll",
        WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n",
        DYLD_PRINT_LIBRARIES="1",
        VKD3D_AMD_PROTECTED_SUBSET="1",
        VKD3D_FILTER_DEVICE_NAME="AMD Radeon Pro 5600M",
        DXVK_FILTER_DEVICE_NAME="AMD Radeon Pro 5600M",
        VKD3D_DEBUG="info",
        MVK_AMD_REFERENCE_RBA2="1",
        MVK_AMD_REFERENCE_RIA2="1",
        MVK_AMD_REFERENCE_NULL="1",
        MVK_AMD_BYTE_GUARDS="1",
        MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS="1",
        MVK_CONFIG_LOG_LEVEL="2",
        MVK_AMD_RUNTIME_TRACE="1",
        VKD3D_AMD_RUNTIME_TRACE="1",
        MVK_AMD_REPLAY_FAILED_MESH="1",
        MVK_AMD_SERIALIZE_PIPELINE_LINK="1",
        MVK_AMD_COHERENT_ATOMICS="1",
        MVK_AMD_ENCODER_LIVE_CACHE="1",
        MVK_AMD_LIVE_LOOKUP_FAST_CACHE="1",
        MVK_AMD_DESCRIPTOR_USE_CACHE="1",
        MVK_AMD_BATCH_LIVE_USE_RESOURCE="1",
        MVK_AMD_BINARY_ARCHIVE_PATH=str(ROOT / "build/game-metal-binary-cache/compute-bounded-v2.metalar"),
        MVK_AMD_RENDER_BINARY_ARCHIVE_PATH=str(ROOT / "build/game-metal-binary-cache/render-bounded-v2.metalar"),
        MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL="64",
        MVK_AMD_BINARY_ARCHIVE_MAX_BYTES=str(256 * 1024 * 1024),
    )
    probes = {
        "device": (ROOT / "probe-app/d3d12_probe.exe", "copy_smoke.result=PASS"),
        "compute": (ROOT / "probe-app/d3d12_compute_probe.exe", "compute.result=PASS"),
        "present": (ROOT / "probe-app/d3d12_presentation_probe.exe", "presentation.gpu_api_result=PASS"),
    }
    summary = {
        "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "candidate": str(CANDIDATE),
        "candidateSHA256": sha256(CANDIDATE),
        "selector": str(SELECTOR / "x86_64-unix/win32u.so"),
        "selectorSHA256": sha256(SELECTOR / "x86_64-unix/win32u.so"),
        "proxy": str(PROXY),
        "proxySHA256": sha256(PROXY),
        "dyldLibraryPathUsed": False,
        "results": {},
    }
    for name, (program, marker) in probes.items():
        probe_dir = out_root / name
        probe_dir.mkdir()
        probe_env = env | {
            "YYB_OPEN_GUARD_RECORD": str(probe_dir / "guard.trace"),
            "VKD3D_LOG_FILE": "Z:" + str(probe_dir / "vkd3d.log").replace("/Users/tonytan", "").replace("/", "\\"),
            "MVK_CONFIG_SHADER_DUMP_DIR": str(probe_dir / "msl"),
        }
        (probe_dir / "msl").mkdir()
        run = subprocess.run(
            [str(SUPPORT / "wine-loader"), str(program)],
            cwd=program.parent,
            env=probe_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
        )
        (probe_dir / "stdout.log").write_text(run.stdout)
        (probe_dir / "stderr.log").write_text(run.stderr)
        guard_text = (probe_dir / "guard.trace").read_text(errors="replace") if (probe_dir / "guard.trace").exists() else ""
        result = {
            "exitCode": run.returncode,
            "actualOutputPassed": run.returncode == 0 and marker in run.stdout,
            "selectorMapped": str(SELECTOR / "x86_64-unix/win32u.so") in run.stderr,
            "proxyMapped": str(PROXY) in run.stderr or "/tmp/mvk" in run.stderr,
            "candidateMapped": str(CANDIDATE) in run.stderr,
            "guardReady": "step=guard-ready" in guard_text,
            "marker": marker,
        }
        summary["results"][name] = result
        if not all((result["actualOutputPassed"], result["selectorMapped"], result["candidateMapped"], result["guardReady"])):
            (out_root / "run.json").write_text(json.dumps(summary, indent=2) + "\n")
            print(json.dumps({"directory": str(out_root), "passed": False, "failed": name, "result": result}))
            return 1
    summary["passed"] = True
    (out_root / "run.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"directory": str(out_root), "passed": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
