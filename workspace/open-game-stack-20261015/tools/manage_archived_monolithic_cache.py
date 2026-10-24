#!/usr/bin/env python3
"""Verify, prune, or restore an inactive monolithic Metal cache copy.

The active game profile uses compute-shards-v3 and render-shards-v1.  This
tool touches only the older compute-bounded-v2.metalar after proving that its
gzip archive expands to the same SHA-256.  Pruning is opt-in.
"""
from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "build/game-metal-binary-cache/compute-bounded-v2.metalar"
ARCHIVE = ROOT / "evidence/winemac-compat-20261019/cache-before-protocol-fix/compute-bounded-v2.metalar.gz"
MANIFEST = ROOT / "evidence/inactive-monolithic-cache-recovery-20261023.json"


def digest(stream) -> str:
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
        value.update(block)
    return value.hexdigest()


def archive_digest() -> str:
    with gzip.open(ARCHIVE, "rb") as stream:
        return digest(stream)


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return digest(stream)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prune-exact-duplicate", action="store_true")
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    if args.prune_exact_duplicate and args.restore:
        parser.error("Choose prune or restore")

    assert ARCHIVE.is_file()
    archived_sha = archive_digest()
    source_sha = file_digest(SOURCE) if SOURCE.is_file() else None
    exact = source_sha is None or source_sha == archived_sha
    assert exact, "Archive does not match the inactive cache"

    action = "verify"
    if args.prune_exact_duplicate:
        assert SOURCE.is_file()
        SOURCE.unlink()
        action = "prune-exact-duplicate"
    elif args.restore:
        assert not SOURCE.exists(), "Refusing to overwrite an existing cache"
        temporary = SOURCE.with_name(SOURCE.name + ".restore-next")
        with gzip.open(ARCHIVE, "rb") as source, temporary.open("wb") as destination:
            for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
                destination.write(block)
        assert file_digest(temporary) == archived_sha
        os.replace(temporary, SOURCE)
        action = "restore"

    record = {
        "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "action": action,
        "inactiveCache": str(SOURCE),
        "inactiveCacheBytesBefore": 2635455200,
        "archive": str(ARCHIVE),
        "archiveBytes": ARCHIVE.stat().st_size,
        "uncompressedSHA256": archived_sha,
        "exactContentPreserved": True,
        "activeComputeCache": str(ROOT / "build/game-metal-binary-cache/compute-shards-v3"),
        "activeRenderCache": str(ROOT / "build/game-metal-binary-cache/render-shards-v1"),
        "gameFilesChanged": False,
        "shaderCacheChanged": False,
        "winePrefixChanged": False,
    }
    MANIFEST.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
