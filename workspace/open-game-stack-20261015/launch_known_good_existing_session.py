#!/usr/bin/env python3
"""Submit licensed Stellar Blade to an already protected known-good Tencent Wine session."""
import ctypes, datetime, hashlib, json, os, pathlib, subprocess, time

p = pathlib.Path(__file__).resolve().parent
r = p.parent
lib = p / "build/moltenvk-binary-archive-compute-render/MoltenVK/libMoltenVK.1.4.2.dylib"
proof = json.loads((p / "evidence/pending-native-known-good-ab6.json").read_text())
assert hashlib.sha256(lib.read_bytes()).hexdigest() == proof["librarySHA256"]
assert proof["qualified"] and proof["nativeRegressionPassed"] and proof["originalTencentPresentationPassed"]
assert all(x["passed"] for x in proof["GPUchecks"])

support = pathlib.Path("/Users/tonytan/Library/Application Support/YYBIntelLauncher")
contents = support / ".runtime/wine-engine.app/Contents"
prefix = pathlib.Path("/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine")
steam = prefix / "drive_c/Program Files (x86)/Steam/Steam.exe"

rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines()
assert not any("SB-Win64-Shipping.exe" in row for row in rows), "Game already running"
session_pids = []
for row in rows:
    fields = row.strip().split(None, 1)
    if len(fields) != 2 or not any(x in fields[1] for x in ("/MacOS/wineloader", "/MacOS/wineserver")):
        continue
    pid = int(fields[0])
    env_text = subprocess.run(["ps", "eww", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    if str(lib.parent) in env_text and "MVK_AMD_COHERENT_ATOMICS=1" in env_text:
        session_pids.append(pid)
assert session_pids, "No persistent Tencent Wine session selected the known-good library"

sandbox = ctypes.CDLL("/usr/lib/libsandbox.1.dylib", use_errno=True)
check = sandbox.sandbox_check
check.restype = ctypes.c_int
original = "/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/StellarBlade/SB.exe"
assert all(check(pid, b"file-write-data", 1, original.encode()) == 1 for pid in session_pids), "Known-good session lost original asset protection"

qualification = json.loads((p / "evidence/pending-vkd3d-runtime-trace.json").read_text())
assert qualification["qualified"]
for name, digest in qualification["binaries"].items():
    candidate = r / "stellar-overlay/SB/Binaries/Win64" / name
    assert candidate.is_file() and hashlib.sha256(candidate.read_bytes()).hexdigest() == digest

stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
dest = p / "evidence" / ("tencent-normal-game-known-good-" + stamp)
dest.mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "WINE", "YYB_", "MVK_", "VK_", "VKD3D_", "DXVK_", "SteamAppId", "SteamGameId"))}
env.update(
    WINEPREFIX=str(prefix),
    YYB_NTDLL_PATH=str(contents / "SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so"),
    YYB_WINESERVER_HOST_APP=str(support / "WineServerHost.app"),
    WINESERVER=str(support / "wineserver-wrapper"),
    WINELOADER=str(support / "wine-loader"),
    WINEDLLPATH=str(contents / "SharedSupport/wine/lib/wine"),
    GFX_BACKEND_PATH=str(contents / "Frameworks/render/dxvk/wine"),
    WINE_RETINA_MODE="1", WINE_RETINA_SCALE="2.0", WINEDEBUG="-all",
)
command = [
    "/usr/bin/sandbox-exec", "-f", str(p / "tencent-normal-original-guard.sb"),
    "/usr/bin/env", "DYLD_FALLBACK_LIBRARY_PATH=" + str(contents / "Frameworks"),
    str(support / "wine-loader"), str(steam), "-applaunch", "3489700", "-dx12",
    "-windowed", "-ResX=1280", "-ResY=800",
]
with (dest / "client-stdout.log").open("w") as out, (dest / "client-stderr.log").open("w") as err:
    child = subprocess.Popen(command, env=env, cwd=steam.parent, stdout=out, stderr=err, start_new_session=True)
record = {
    "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "clientPID": child.pid,
    "sessionPIDs": session_pids,
    "normalSteamOnly": True,
    "originalEngine": True,
    "originalPrefix": True,
    "originalAssetGuardVerified": True,
    "librarySHA256": proof["librarySHA256"],
    "binaries": qualification["binaries"],
    "command": command,
    "gameStarted": False,
    "gamePlayable": False,
}
(dest / "launch.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps({"directory": str(dest), "clientPID": child.pid}), flush=True)

observed = {}
deadline = time.monotonic() + 60
alive = []
last_alive = None
while time.monotonic() < deadline:
    process_rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines()
    alive = []
    for row in process_rows:
        fields = row.strip().split(None, 1)
        if len(fields) != 2 or "SB-Win64-Shipping.exe" not in fields[1]:
            continue
        pid = int(fields[0]); alive.append(pid); last_alive = time.monotonic()
        item = observed.setdefault(str(pid), {"pid": pid, "comm": fields[1], "graphicsMappings": []})
        mapped = subprocess.run(["lsof", "-a", "-p", str(pid), "-Fn"], capture_output=True, text=True).stdout
        paths = [x[1:] for x in mapped.splitlines() if x.startswith("n") and any(k in x.lower() for k in ("moltenvk", "d3d12", "dxgi.dll"))]
        item["graphicsMappings"] = sorted(set(item["graphicsMappings"] + paths))
        item["qualifiedMoltenVKActuallyLoaded"] = str(lib) in item["graphicsMappings"]
        item["originalAssetWritePolicy"] = check(pid, b"file-write-data", 1, original.encode())
        (dest / "game-process-mappings.json").write_text(json.dumps(observed, indent=2) + "\n")
    if observed and not alive and last_alive and time.monotonic() - last_alive > 2:
        break
    time.sleep(0.3)

record["gameStarted"] = bool(observed)
record["observedGameProcesses"] = observed
record["gameStillRunningAtObservationEnd"] = bool(alive)
record["observationEndedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
(dest / "launch.json").write_text(json.dumps(record, indent=2) + "\n")
invalid = [x for x in observed.values() if not x["qualifiedMoltenVKActuallyLoaded"] or x["originalAssetWritePolicy"] != 1]
if invalid:
    for item in invalid:
        try: os.kill(item["pid"], 15)
        except ProcessLookupError: pass
    raise AssertionError("Actual game did not load the known-good library or original asset guard")
print(json.dumps({"gameStarted": bool(observed), "gameStillRunning": bool(alive), "directory": str(dest)}), flush=True)
