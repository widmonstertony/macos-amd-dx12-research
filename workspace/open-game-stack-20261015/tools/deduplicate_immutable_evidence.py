#!/usr/bin/env python3
"""Deduplicate immutable copied runtime DLLs while preserving every evidence path."""
from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "evidence"
MINIMUM_BYTES = 4096
ACTIVE_BUILD_DIRECTORIES = {
    "game-metal-binary-cache",
    "private-shader-cache",
    "moltenvk-bounded-archive",
    "descriptor-range-version-20261023-game",
    "descriptor-range-version-20261023-probe",
    "probes",
    "vkd3d",
    "upstream-control",
    "winemac-lockfix-leaf-select",
}


def candidates() -> list[Path]:
    """Return only immutable evidence and one-shot profile artifacts.

    Active game/shader caches and CMake outputs are intentionally excluded:
    those files may be updated in place and therefore must never share an
    inode with a historical copy.
    """
    paths = [path for path in EVIDENCE.rglob("*")
             if path.is_file() and not path.is_symlink() and path.stat().st_size >= MINIMUM_BYTES]
    for directory in ROOT.joinpath("build").glob("*"):
        if not directory.is_dir() or directory.name in ACTIVE_BUILD_DIRECTORIES:
            continue
        paths.extend(path for path in directory.rglob("*")
                     if path.is_file() and not path.is_symlink() and
                     path.stat().st_size >= MINIMUM_BYTES)
    return sorted(paths)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main() -> int:
    groups: dict[tuple[str, int, int, str], list[Path]] = {}
    for path in candidates():
        stat = path.stat()
        key = (stat.st_size, stat.st_mode & 0o777, digest(path))
        groups.setdefault(key, []).append(path)

    rows = []
    estimated = 0
    for (size, mode, sha256), paths in groups.items():
        # Existing hard links already share an inode and need no replacement.
        canonical = paths[0]
        canonical_inode = canonical.stat().st_ino
        duplicates = [path for path in paths[1:] if path.stat().st_ino != canonical_inode]
        if not duplicates:
            continue
        rows.append({
            "name": canonical.name,
            "bytes": size,
            "mode": oct(mode),
            "sha256": sha256,
            "canonical": str(canonical.relative_to(ROOT)),
            "duplicates": [str(path.relative_to(ROOT)) for path in duplicates],
        })
        estimated += size * len(duplicates)

    out = EVIDENCE / "immutable-content-dedup-20261023-r2.json"
    manifest = {
        "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "method": "atomic hard-link replacement of byte-identical immutable evidence copies",
        "groups": rows,
        "estimatedBytesFreed": estimated,
        "pathsRemoved": 0,
        "gameCacheChanged": False,
        "winePrefixChanged": False,
    }
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    assert json.loads(out.read_text())["groups"] == rows

    replaced = 0
    for row in rows:
        canonical = ROOT / row["canonical"]
        for relative in row["duplicates"]:
            path = ROOT / relative
            temporary = path.with_name(path.name + ".dedup-next")
            if temporary.exists():
                temporary.unlink()
            os.link(canonical, temporary)
            assert temporary.stat().st_size == row["bytes"]
            assert digest(temporary) == row["sha256"]
            os.replace(temporary, path)
            assert path.exists() and digest(path) == row["sha256"]
            replaced += 1

    manifest["replacedCopies"] = replaced
    manifest["verified"] = all(
        digest(ROOT / relative) == row["sha256"]
        for row in rows for relative in [row["canonical"], *row["duplicates"]]
    )
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({
        "manifest": str(out),
        "replacedCopies": replaced,
        "estimatedBytesFreed": estimated,
        "verified": manifest["verified"],
    }))
    return 0 if manifest["verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
