#!/usr/bin/env python3
"""Cold-start the original Tencent Steam client with the qualified backend.

This does not create or modify a Wine prefix.  It uses Tencent's native
winelauncher, records the exact candidate hashes, and refuses to create a
duplicate Steam or game process.
"""
import ast
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

import launch_stellar_deferred_proxy as qualified


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    rows = qualified.process_rows()
    assert not any(qualified.is_original_steam_process(c) for _, _, c in rows), "Original Steam is already running"
    assert not any("SB-Win64-Shipping.exe" in c or "/StellarBlade/SB.exe" in c for _, _, c in rows), "Game is already running"
    guard_sha, guard_repaired = qualified.ensure_guard_profile()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = qualified.ROOT / "evidence" / ("original-steam-candidate-start-" + stamp)
    out.mkdir()
    guard_record = out / "guard-proxy.trace"

    tree = ast.parse((qualified.ROOT / "tools/launch_stellar_deferred_proxy.py").read_text())
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "main")
    update = next(n for n in function.body if isinstance(n, ast.Expr)
                  and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Attribute)
                  and isinstance(n.value.func.value, ast.Name) and n.value.func.value.id == "env"
                  and n.value.func.attr == "update")
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("DYLD_", "WINE", "YYB_", "VK_", "VKD3D_", "DXVK_", "MVK_", "SteamAppId", "SteamGameId"))}
    eval(compile(ast.Expression(update.value), "qualified-original-Steam-environment", "eval"),
         qualified.__dict__ | {"env": env, "out": out, "guard_record": guard_record})
    # winelauncher initializes these itself while retaining the selected native
    # graphics libraries and game-scoped cache configuration.
    for name in ("WINEPREFIX", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEDLLOVERRIDES",
                 "YYB_NTDLL_PATH", "YYB_WINESERVER_HOST_APP"):
        env.pop(name, None)

    candidate = Path("/private/tmp/mvk-guard-proxy/libQualifiedCandidateReexport.dylib")
    proxy = Path("/private/tmp/mvk-guard-proxy/libMoltenVKGuard.dylib")
    record = {"timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "originalTencentNativeLauncher": True, "prefixChanged": False,
              "candidate": str(candidate), "candidateSHA256": digest(candidate),
              "proxy": str(proxy), "proxySHA256": digest(proxy),
              "assetGuardProfileSHA256": guard_sha, "assetGuardProfileRepaired": guard_repaired,
              "clientRestarted": False}
    with (out / "client.stdout").open("w") as stdout, (out / "client.stderr").open("w") as stderr:
        child = subprocess.Popen([str(qualified.CONTENTS / "MacOS/winelauncher"), str(qualified.STEAM)],
                                 cwd=qualified.STEAM.parent, env=env, stdin=subprocess.DEVNULL,
                                 stdout=stdout, stderr=stderr, start_new_session=True)
    record["nativeLauncherPID"] = child.pid
    for _ in range(90):
        found = [pid for pid, _, c in qualified.process_rows() if qualified.is_original_steam_process(c)]
        if found:
            record["steamPIDs"] = found
            time.sleep(10)
            record["clientRestarted"] = any(pid == found[-1] for pid, _, _ in qualified.process_rows())
            record["nativeLauncherExitCode"] = child.poll()
            break
        time.sleep(1)
    (out / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"directory": str(out), **record}), flush=True)
    return 0 if record["clientRestarted"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
