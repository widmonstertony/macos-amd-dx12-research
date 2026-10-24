#!/usr/bin/env python3
"""Arm bounded work and GPU timestamp traces for one existing game process.

This controller does not launch the game or send input.  It keeps both native
diagnostic markers fresh, stops after the first new GPU timeout, and copies the
fault record into a unique evidence directory.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def process_identity(pid):
    return subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart=,comm="],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--seconds", type=int, default=180)
    args = parser.parse_args()
    assert 10 <= args.seconds <= 600
    assert all(re.fullmatch(r"[a-z0-9-]{1,80}", value)
               for value in (args.profile, args.label))

    folder = ROOT / "evidence" / args.profile
    build = json.loads((folder / "build.json").read_text())[-1]
    assert build["armedWorkTrace"] and build["timedGPUCounters"]
    trace = folder / "msl"
    work_marker = folder / "gpu-work-trace.arm"
    counter_marker = folder / "gpu-counter.arm"
    output = ROOT / "evidence" / args.label
    output.mkdir(exist_ok=False)

    identity = process_identity(args.pid)
    assert "SB-Win64-Shipping.exe" in identity
    assert shutil.disk_usage(ROOT).free >= 3 * 1024**3
    before = {path.name for path in trace.glob(
        f"trace-gpu-timeout-{args.pid}-*.json")}
    nonce = f"stage-fault-{args.pid}-{os.getpid()}-{uuid.uuid4().hex}"
    record = {
        "startUTC": utc_now(),
        "gamePID": args.pid,
        "controllerPID": os.getpid(),
        "profile": args.profile,
        "maximumSeconds": args.seconds,
        "refreshSeconds": 5,
        "workMarkerMaximumNativeAgeSeconds": 30,
        "gpuCounterMarkerMaximumNativeAgeSeconds": 30,
        "preexistingFailureFiles": sorted(before),
        "inputSent": False,
        "cacheDeleted": False,
        "refreshes": 0,
    }

    # Refuse to overwrite another live controller's work marker.
    with work_marker.open("x") as stream:
        stream.write(nonce + "\n")
    counter_marker.touch(exist_ok=True)
    print(json.dumps({"armed": True, "pid": args.pid,
                      "output": str(output)}), flush=True)

    try:
        started = time.monotonic()
        while time.monotonic() - started < args.seconds:
            try:
                if process_identity(args.pid) != identity:
                    record["finished"] = "game-exited-or-identity-changed"
                    break
            except subprocess.CalledProcessError:
                record["finished"] = "game-exited-or-identity-changed"
                break
            if (not work_marker.exists()
                    or work_marker.read_text().strip() != nonce):
                record["finished"] = "work-marker-ownership-changed"
                break
            os.utime(work_marker, None)
            counter_marker.touch(exist_ok=True)
            record["refreshes"] += 1
            new_faults = [path for path in trace.glob(
                f"trace-gpu-timeout-{args.pid}-*.json")
                if path.name not in before]
            if new_faults:
                copied = []
                for path in new_faults:
                    target = output / path.name
                    shutil.copy2(path, target)
                    copied.append(target.name)
                record["faultFiles"] = sorted(copied)
                record["finished"] = "new-gpu-timeout-captured"
                break
            time.sleep(5)
        else:
            record["finished"] = "bounded-capture-expired"
    finally:
        if (work_marker.exists()
                and work_marker.read_text().strip() == nonce):
            work_marker.unlink()
            record["workMarkerRemoved"] = True
        if counter_marker.exists():
            expired = time.time() - 60
            os.utime(counter_marker, (expired, expired))
            record["counterMarkerExpired"] = True
        record["endUTC"] = utc_now()
        (output / "result.json").write_text(
            json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)


if __name__ == "__main__":
    main()
