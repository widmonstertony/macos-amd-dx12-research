#!/usr/bin/env python3
"""Restore the last game-proven Tencent Steam environment without launching the game directly."""
import datetime, hashlib, json, os, pathlib, subprocess

p = pathlib.Path(__file__).resolve().parent
lib = p / "build/moltenvk-binary-archive-compute-render/MoltenVK/libMoltenVK.1.4.2.dylib"
expected = "ab6c608cd4b298edf6ec491bde49e3625f2e28738ba8775bf2289f1726f7d02c"
assert hashlib.sha256(lib.read_bytes()).hexdigest() == expected
assert pathlib.Path("/Applications/Steam（Windows）.app/Contents/MacOS/start").is_file()

stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
dest = p / "evidence" / ("tencent-original-app-steam-" + stamp)
dest.mkdir()
(dest / "msl").mkdir()

values = {
    "DXVK_HUD": "0",
    "VKD3D_AMD_PROTECTED_SUBSET": "1",
    "MVK_AMD_REFERENCE_RBA2": "1",
    "MVK_AMD_REFERENCE_RIA2": "1",
    "MVK_AMD_REFERENCE_NULL": "1",
    "MVK_AMD_BYTE_GUARDS": "1",
    "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS": "1",
    "MVK_CONFIG_LOG_LEVEL": "0",
    "MVK_CONFIG_SHADER_DUMP_DIR": str(dest / "msl"),
    "VKD3D_FILTER_DEVICE_NAME": "AMD Radeon Pro 5600M",
    "DXVK_FILTER_DEVICE_NAME": "AMD Radeon Pro 5600M",
    "VKD3D_DEBUG": "none",
    "DXVK_LOG_LEVEL": "none",
    "VKD3D_SHADER_CACHE_PATH": r"Z:\Documents\GitHub\gptk-intel-research-20261011\open-game-stack-20261015\build\private-shader-cache",
    "DXVK_LOG_PATH": "Z:" + str(dest.relative_to(pathlib.Path("/Users/tonytan"))).replace("/", "\\"),
    "MVK_AMD_RUNTIME_REPLAY_ONLY": "1",
    "MVK_AMD_RUNTIME_TRACE": "1",
    "MVK_AMD_REPLAY_FAILED_MESH": "1",
    "MVK_AMD_SERIALIZE_PIPELINE_LINK": "1",
    "MVK_AMD_COHERENT_ATOMICS": "1",
    "MVK_AMD_DESCRIPTOR_USE_CACHE": "1",
    "MVK_AMD_LIVE_LOOKUP_FAST_CACHE": "1",
    "MVK_AMD_ENCODER_LIVE_CACHE": "1",
    "MVK_AMD_TRACE_SLOW_COMPUTE": "1",
    "MVK_AMD_BATCH_LIVE_USE_RESOURCE": "1",
    "MVK_AMD_BINARY_ARCHIVE_PATH": str(p / "build/game-metal-binary-cache/compute.metalar"),
    "MVK_AMD_RENDER_BINARY_ARCHIVE_PATH": str(p / "build/game-metal-binary-cache/render.metalar"),
    "MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL": "512",
    "MVK_AMD_BINARY_ARCHIVE_MAX_BYTES": "1073741824",
    "YYB_OPEN_ENTRY_RECORD": str(dest / "native-entry.json"),
    "YYB_OPEN_STEAM_ENTRY": "1",
    "YYB_OPEN_RUNTIME_TRACE": "1",
    "YYB_OPEN_RUNTIME_REPLAY": "1",
    "YYB_OPEN_LINK_SERIAL": "1",
    "YYB_OPEN_VERTEX_ARRAY": "1",
    "YYB_OPEN_COHERENT_ATOMICS": "1",
    "YYB_OPEN_DESCRIPTOR_USE_CACHE": "1",
    "YYB_OPEN_LIVE_LOOKUP_FAST_CACHE": "1",
    "YYB_OPEN_ENCODER_LIVE_CACHE": "1",
    "YYB_OPEN_BINARY_ARCHIVE_CACHE": "1",
}
cmd = ["/usr/bin/open", "-n"]
for key, value in values.items():
    cmd += ["--env", key + "=" + value]
cmd += ["/Applications/Steam（Windows）.app"]

env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "WINE", "YYB_", "VK_", "VKD3D_", "DXVK_", "MVK_"))}
with (dest / "stdout.log").open("w") as out, (dest / "stderr.log").open("w") as err:
    child = subprocess.Popen(cmd, env=env, stdout=out, stderr=err, start_new_session=True)
record = {
    "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "stage": "original-app-steam",
    "command": cmd,
    "nativeLibrary": str(lib),
    "librarySHA256": expected,
    "prefix": "/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine",
    "engine": "/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents",
    "sameTencentPrefix": True,
    "engineFilesModified": False,
    "normalSteamOnly": True,
    "knownGoodRestore": True,
    "pid": child.pid,
}
(dest / "launch.json").write_text(json.dumps(record, indent=2) + "\n")
(p / "evidence/current-tencent-trial.json").write_text(json.dumps({"directory": str(dest), "pid": child.pid, "stage": "original-app-steam"}, indent=2) + "\n")
print(json.dumps({"directory": str(dest), "pid": child.pid, "librarySHA256": expected}))
