#!/usr/bin/env python3
"""Submit Stellar Blade through the running licensed Steam client and verify the deferred GPU route."""
from __future__ import annotations

import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from prepare_stellar_crash_state import main as prepare_crash_state

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = Path.home() / "Library/Application Support/YYBIntelLauncher"
CONTENTS = SUPPORT / ".runtime/wine-engine.app/Contents"
PREFIX = Path.home() / "Library/Application Support/com.tencent.yybmac.wine.engine/wine"
STEAM = PREFIX / "drive_c/Program Files (x86)/Steam/Steam.exe"
PROOF = ROOT / "evidence/pending-native-binary-archive-signed.json"
ORIGINAL = Path("/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/StellarBlade/SB.exe")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def process_rows() -> list[tuple[int, int, str]]:
    rows = []
    for line in subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True).splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--proof", type=Path, default=PROOF)
    args = parser.parse_args()
    proof_path = args.proof.resolve()
    assert proof_path.is_relative_to(ROOT / "evidence"), "Owned qualification proof required"
    proof = json.loads(proof_path.read_text())
    deferred = proof["deferredRuntime"]
    proxy = Path(deferred["proxy"])
    candidate = Path(deferred["candidate"])
    assert proof["nativeRegressionPassed"] and proof["originalTencentPresentationPassed"]
    assert proof["deferredGameGuardPassed"] and deferred["presentationPassed"]
    assert sha256(proxy) == deferred["proxySHA256"]
    assert sha256(candidate) == deferred["candidateSHA256"]
    rows = process_rows()
    steam_rows = [(pid, ppid, comm) for pid, ppid, comm in rows if comm.casefold() == str(STEAM).casefold()]
    assert len(steam_rows) == 1, "Expected one running original Steam client"
    assert not any("SB-Win64-Shipping.exe" in comm or "/StellarBlade/SB.exe" in comm for _, _, comm in rows), "Game already running"
    prepare_crash_state()

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = ROOT / "evidence" / f"tencent-normal-game-deferred-{stamp}"
    out.mkdir()
    (out / "msl").mkdir()
    guard_record = out / "guard-proxy.trace"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "WINE", "YYB_", "VK_", "VKD3D_", "DXVK_", "MVK_", "SteamAppId", "SteamGameId"))}
    env.update(
        WINEPREFIX=str(PREFIX),
        YYB_NTDLL_PATH=str(CONTENTS / "SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so"),
        YYB_WINESERVER_HOST_APP=str(SUPPORT / "WineServerHost.app"),
        WINESERVER=str(SUPPORT / "wineserver-wrapper"),
        WINELOADER=str(SUPPORT / "wine-loader"),
        WINEDLLPATH=str(CONTENTS / "SharedSupport/wine/lib/wine"),
        DYLD_LIBRARY_PATH=str(ROOT / "build/winemac-lockfix-leaf-select") + ":/private/tmp/mvk-guard-proxy-select",
        DYLD_FALLBACK_LIBRARY_PATH=str(CONTENTS / "Frameworks"),
        GFX_BACKEND_PATH=str(CONTENTS / "Frameworks/render/dxvk/wine"),
        WINE_RETINA_MODE="1", WINE_RETINA_SCALE="2.0", WINEDEBUG="-all",
        YYB_OPEN_GUARD_RECORD=str(guard_record),
        VKD3D_AMD_PROTECTED_SUBSET="1", VKD3D_FILTER_DEVICE_NAME="AMD Radeon Pro 5600M",
        DXVK_FILTER_DEVICE_NAME="AMD Radeon Pro 5600M", VKD3D_DEBUG="warn",
        MVK_AMD_REFERENCE_RBA2="1", MVK_AMD_REFERENCE_RIA2="1", MVK_AMD_REFERENCE_NULL="1",
        MVK_AMD_BYTE_GUARDS="1", MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS="1", MVK_CONFIG_LOG_LEVEL="1",
        MVK_AMD_RUNTIME_REPLAY_ONLY="1", MVK_AMD_RUNTIME_TRACE="1", MVK_AMD_REPLAY_FAILED_MESH="1",
        MVK_AMD_SERIALIZE_PIPELINE_LINK="1", MVK_AMD_COHERENT_ATOMICS="1",
        MVK_AMD_DESCRIPTOR_USE_CACHE="1", MVK_AMD_LIVE_LOOKUP_FAST_CACHE="1", MVK_AMD_ENCODER_LIVE_CACHE="1",
        MVK_AMD_BINARY_ARCHIVE_PATH=str(ROOT / "build/game-metal-binary-cache/compute-bounded-v2.metalar"),
        MVK_AMD_RENDER_BINARY_ARCHIVE_PATH=str(ROOT / "build/game-metal-binary-cache/render-bounded-v2.metalar"),
        MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL="64", MVK_AMD_BINARY_ARCHIVE_MAX_BYTES=str(256 * 1024 * 1024),
        VKD3D_SHADER_CACHE_PATH="Z:\\Documents\\GitHub\\gptk-intel-research-20261011\\open-game-stack-20261015\\build\\private-shader-cache",
        VKD3D_LOG_FILE="Z:" + str(out / "vkd3d-game.log").replace("/Users/tonytan", "").replace("/", "\\"),
        MVK_CONFIG_SHADER_DUMP_DIR=str(out / "msl"),
    )
    command = [str(SUPPORT / "wine-loader"), str(STEAM), "-applaunch", "3489700", "-dx12", "-windowed", "-ResX=1280", "-ResY=800"]
    stdout = (out / "client-stdout.log").open("w")
    stderr = (out / "client-stderr.log").open("w")
    client = subprocess.Popen(command, cwd=STEAM.parent, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
    record = {
        "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "normalLicensedSteamRequest": True, "existingSteamPID": steam_rows[0][0], "clientPID": client.pid,
        "privateCrashState": str(ROOT / "build/stellar-crash-report-state"),
        "proxySHA256": deferred["proxySHA256"], "candidateSHA256": deferred["candidateSHA256"],
        "command": command, "observed": {}, "verified": False,
    }
    (out / "launch.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"directory": str(out), "clientPID": client.pid, "submitted": True}), flush=True)

    sandbox = ctypes.CDLL("/usr/lib/libsandbox.1.dylib", use_errno=True)
    check = sandbox.sandbox_check
    check.restype = ctypes.c_int
    deadline = time.monotonic() + 90
    last_report = -1
    while time.monotonic() < deadline:
        elapsed = int(90 - (deadline - time.monotonic()))
        alive = []
        for pid, ppid, comm in process_rows():
            if "SB-Win64-Shipping.exe" not in comm and "/StellarBlade/SB.exe" not in comm:
                continue
            alive.append(pid)
            item = record["observed"].setdefault(str(pid), {"pid": pid, "ppid": ppid, "comm": comm, "mappings": []})
            try:
                mapped = subprocess.run(["lsof", "-a", "-p", str(pid), "-Fn"], capture_output=True, text=True, timeout=4).stdout
            except subprocess.TimeoutExpired:
                mapped = ""
            paths = [line[1:] for line in mapped.splitlines() if line.startswith("n") and
                     (line[1:] in (str(candidate), str(proxy)) or
                      any(key in line.lower() for key in ("moltenvk", "vkd3d", "d3d12", "dxgi.dll", "winemac.so", "ntdll.so", "win32u.so")))]
            item["mappings"] = sorted(set(item["mappings"] + paths))
            item["candidateMapped"] = str(candidate) in item["mappings"]
            item["proxyMapped"] = str(proxy) in item["mappings"] or "/tmp/mvk" in item["mappings"]
            item["fixedWindowModuleMapped"] = str(ROOT / "build/winemac-lockfix-leaf-select/winemac.so") in item["mappings"]
            item["originalWriteDenied"] = check(ctypes.c_int(pid), ctypes.c_char_p(b"file-write-data"), ctypes.c_int(1), ctypes.c_char_p(str(ORIGINAL).encode())) == 1
            if item["candidateMapped"] and item["proxyMapped"] and item["fixedWindowModuleMapped"] and item["originalWriteDenied"]:
                record["verified"] = True
        if elapsed // 10 != last_report:
            last_report = elapsed // 10
            print(json.dumps({"elapsedSeconds": elapsed, "gamePIDs": alive, "verified": record["verified"]}), flush=True)
        (out / "launch.json").write_text(json.dumps(record, indent=2) + "\n")
        if record["verified"]:
            print(json.dumps({"verified": True, "directory": str(out), "gamePIDs": alive}), flush=True)
            return 0
        time.sleep(1)
    print(json.dumps({"verified": False, "directory": str(out), "observed": record["observed"]}), flush=True)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
