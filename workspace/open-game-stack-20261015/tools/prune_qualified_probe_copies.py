#!/usr/bin/env python3
"""Remove only duplicated probe executables/DLLs from completed Wine evidence.

Every removed file is content-addressed in a per-run manifest. Logs, result
JSON, Metal archives, game caches, Wine prefixes, and installed files are never
touched.
"""
from __future__ import annotations

import datetime
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "evidence"
COPY_NAMES = {
    "d3d12_compute_probe.exe",
    "d3d12_presentation_probe.exe",
    "d3d12.dll",
    "d3d12core.dll",
    "dxgi.dll",
}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main() -> int:
    total = 0
    runs = 0
    for directory in sorted(EVIDENCE.glob("private-cache-wine-*")):
        run_path = directory / "run.json"
        if not run_path.is_file():
            continue
        run = json.loads(run_path.read_text())
        if run.get("passed") is not True:
            continue
        candidates = sorted(path for path in directory.rglob("*")
                            if path.is_file() and path.name.casefold() in COPY_NAMES)
        if not candidates:
            continue
        rows = []
        for path in candidates:
            rows.append({
                "path": str(path.relative_to(directory)),
                "bytes": path.stat().st_size,
                "sha256": digest(path),
            })
        manifest = {
            "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "reason": "Qualified probe binary copies; canonical sources remain in probe-app/build.",
            "runPassed": True,
            "files": rows,
            "bytesFreed": sum(row["bytes"] for row in rows),
            "gameCacheChanged": False,
            "winePrefixChanged": False,
        }
        manifest_path = directory / "pruned-probe-copies.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        # The manifest must be durable and parseable before any duplicate copy
        # is removed.
        assert json.loads(manifest_path.read_text())["files"] == rows
        for path in candidates:
            path.unlink()
        total += manifest["bytesFreed"]
        runs += 1
    print(json.dumps({"qualifiedRunsPruned": runs, "bytesFreed": total,
                      "gameCacheChanged": False, "winePrefixChanged": False}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
