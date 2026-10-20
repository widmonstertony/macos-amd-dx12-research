#!/usr/bin/env python3
"""Record exact-library qualification for the AMD archived render callback fix."""

import datetime
import hashlib
import json
from pathlib import Path


root = Path(__file__).resolve().parents[1]
proof_path = root / "evidence/pending-native-binary-archive.json"
library = root / "build/moltenvk-binary-archive-compute-render/MoltenVK/libMoltenVK.1.4.2.dylib"

checks = [
    ("vector", "sync-render-vector-real-20261016/run.json"),
    ("memory", "sync-render-memory-real-20261016/run.json"),
    ("descriptors", "sync-render-descriptors-real-20261016/run.json"),
    ("graphics", "sync-render-graphics-real-20261016/run.json"),
    ("graphics-warm-archive", "sync-render-graphics-warm-real-20261016/run.json"),
    ("typedgraphics", "sync-render-typedgraphics-real-20261016/run.json"),
    ("geometry", "sync-render-geometry-real-20261016/run.json"),
    ("specializer-timeout-lifetime", "specializer-timeout-20261016T222148Z/run.json"),
    ("compute-concurrency-cache", "compute-concurrency-20261016T222133Z/run.json"),
]

tencent_checks = [
    ("Tencent-device-copy", "tencent-device-20261016T222802Z/run.json"),
    ("Tencent-compute", "tencent-compute-20261016T222854Z/run.json"),
    ("Tencent-present", "tencent-present-20261016T222955Z/run.json"),
]

records = []
digest = hashlib.sha256(library.read_bytes()).hexdigest()
for suite, relative in checks:
    run = json.loads((root / "evidence" / relative).read_text())
    run_digest = run.get("librarySHA256", run.get("sha256"))
    if run_digest != digest or not run.get("passed"):
        raise SystemExit(f"unqualified exact-library result: {relative}")
    records.append({
        "suite": suite,
        "passed": True,
        "evidence": relative,
        "results": run.get("results", {}),
    })

for suite, relative in tencent_checks:
    run = json.loads((root / "evidence" / relative).read_text())
    if run.get("librarySHA256") != digest or not run.get("actualOutputPassed"):
        raise SystemExit(f"unqualified exact-library Tencent result: {relative}")
    records.append({
        "suite": suite,
        "passed": True,
        "evidence": relative,
        "results": {
            "exactLibraryLoaded": True,
            "actualOutputPassed": True,
            "exitCode": run.get("exitCode"),
        },
    })

proof = json.loads(proof_path.read_text())
proof.update({
    "timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "librarySHA256": digest,
    "qualified": True,
    "qualifiedForControlledTrial": True,
    "qualificationScope": (
        "Exact candidate passed isolated AMD Radeon Pro 5600M GPU readback for compute, "
        "descriptors, graphics, typed graphics, geometry, warm Metal archive reload, "
        "timeout recovery and concurrency/cache tests, followed by original Tencent Wine "
        "D3D12 device/copy, compute and standard HWND/DXGI presentation probes."
    ),
    "nativeRegressionPassed": True,
    "originalTencentPresentationPassed": True,
    "gameTransitionBlockedUntilWineQualification": False,
    "GPUchecks": records,
    "blockedReason": None,
    "gamePlayable": False,
})
proof_path.write_text(json.dumps(proof, indent=2) + "\n")
print(json.dumps({"proof": str(proof_path), "librarySHA256": digest, "checks": len(records)}, indent=2))
