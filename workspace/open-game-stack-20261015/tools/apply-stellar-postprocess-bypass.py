#!/usr/bin/env python3
"""Apply a reversible Stellar Blade FSR3/post-processing bypass in the YYB prefix."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import pathlib
import shutil


ROOT = pathlib.Path("/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011")
STACK = ROOT / "open-game-stack-20261015"
CONFIG = pathlib.Path(
    "/Users/tonytan/Library/Application Support/"
    "com.tencent.yybmac.wine.engine/wine/drive_c/users/tencentyyb/"
    "AppData/Local/SB/Saved/Config/WindowsNoEditor"
)


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def replace_key(text: str, key: str, value: str) -> str:
    lines = text.splitlines()
    replacement = f"{key}={value}"
    found = False
    for i, line in enumerate(lines):
        if line.startswith(key + "="):
            lines[i] = replacement
            found = True
    if not found:
        raise RuntimeError(f"required setting is missing: {key}")
    return "\r\n".join(lines) + "\r\n"


def main() -> None:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    evidence = STACK / "evidence" / f"tencent-postprocess-bypass-{stamp}"
    evidence.mkdir(parents=True)

    game = CONFIG / "GameUserSettings.ini"
    engine = CONFIG / "Engine.ini"
    shutil.copy2(game, evidence / "GameUserSettings.before.ini")
    shutil.copy2(engine, evidence / "Engine.before.ini")

    game_text = game.read_text(encoding="utf-8")
    changes = {
        "AmdFSR3": "SB_GAMEUSERSETTINGS_OFF",
        "AmdFrameInterpolation": "SB_GAMEUSERSETTINGS_OFF",
        "UpscalerType": "SB_GAMEUSERSETTINGS_OFF",
        "bUseDynamicResolution": "False",
        "ResolutionSizeX": "1280",
        "ResolutionSizeY": "800",
        "FullscreenMode": "2",
        "PreferredFullscreenMode": "2",
        "DesiredScreenWidth": "1280",
        "DesiredScreenHeight": "800",
    }
    for key, value in changes.items():
        game_text = replace_key(game_text, key, value)
    game.write_bytes(game_text.encode("utf-8"))

    engine_text = engine.read_text(encoding="utf-8").splitlines()
    cvars = {
        "r.FidelityFX.FSR3.Enabled": "0",
        "r.FidelityFX.FI.Enabled": "0",
        "r.FidelityFX.FI.OverrideSwapChainDX12": "0",
        "r.FidelityFX.FI.AllowAsyncWorkloads": "0",
        "r.FidelityFX.FSR3.UseNativeDX12": "0",
        "r.FidelityFX.FSR3.UseRHI": "0",
        "r.DynamicRes.OperationMode": "0",
        "r.ScreenPercentage": "100",
    }
    section = None
    seen: set[str] = set()
    out: list[str] = []
    insert_at = None
    for line in engine_text:
        if line.startswith("[") and line.endswith("]"):
            if section == "SystemSettings" and insert_at is None:
                insert_at = len(out)
            section = line[1:-1]
        if section == "SystemSettings" and "=" in line:
            key = line.split("=", 1)[0]
            if key in cvars:
                line = f"{key}={cvars[key]}"
                seen.add(key)
        out.append(line)
    if section == "SystemSettings" and insert_at is None:
        insert_at = len(out)
    if insert_at is None:
        out.extend(["", "[SystemSettings]"])
        insert_at = len(out)
    missing = [f"{key}={value}" for key, value in cvars.items() if key not in seen]
    out[insert_at:insert_at] = missing
    engine.write_bytes(("\r\n".join(out) + "\r\n").encode("utf-8"))

    shutil.copy2(game, evidence / "GameUserSettings.after.ini")
    shutil.copy2(engine, evidence / "Engine.after.ini")
    manifest = {
        "timeUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "purpose": "Bypass the FSR3/frame-interpolation post-processing path implicated by the RenderPostProcessing access violation.",
        "reversible": True,
        "gameFilesModified": False,
        "shaderCacheModified": False,
        "settings": changes,
        "systemSettings": cvars,
        "files": {
            "GameUserSettings.ini": sha256(game),
            "Engine.ini": sha256(engine),
        },
    }
    (evidence / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(evidence)


if __name__ == "__main__":
    main()
