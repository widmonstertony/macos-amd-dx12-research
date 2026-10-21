#!/usr/bin/env python3
"""Bounded public libproc CPU counters for the actual game; no process memory."""
import argparse
import ctypes as C
import datetime
import json
from pathlib import Path
import subprocess
import time

class ThreadInfo(C.Structure):
    _fields_ = [("user", C.c_uint64), ("system", C.c_uint64),
                ("cpu", C.c_int32), ("policy", C.c_int32),
                ("state", C.c_int32), ("flags", C.c_int32),
                ("sleep", C.c_int32), ("current_priority", C.c_int32),
                ("priority", C.c_int32), ("maximum_priority", C.c_int32),
                ("name", C.c_char * 64)]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert 1 <= args.seconds <= 20
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    assert output.is_relative_to(root / "evidence") and not output.exists()
    identity = lambda: subprocess.check_output(["ps", "-p", str(args.pid), "-o", "lstart=,comm="], text=True).strip()
    original = identity()
    assert "SB-Win64-Shipping.exe" in original
    lib = C.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    query = lib.proc_pidinfo
    query.argtypes = [C.c_int, C.c_int, C.c_uint64, C.c_void_p, C.c_int]
    query.restype = C.c_int

    def snapshot():
        ids = (C.c_uint64 * 2048)()
        size = query(args.pid, 6, 0, ids, C.sizeof(ids))  # PROC_PIDLISTTHREADS
        assert 0 < size < C.sizeof(ids) and size % 8 == 0
        result = {}
        for tid in ids[:size // 8]:
            info = ThreadInfo()
            # LISTTHREADS supplies pthread handles, not numeric kernel IDs.
            if query(args.pid, 5, tid, C.byref(info), C.sizeof(info)) == C.sizeof(info):
                result[tid] = {"user": info.user, "system": info.system,
                               "name": info.name.decode(errors="replace"),
                               "state": info.state, "priority": info.priority}
        return result

    before = snapshot()
    start = time.monotonic()
    time.sleep(args.seconds)
    after = snapshot()
    assert identity() == original
    rows = []
    for tid, current in after.items():
        if tid not in before:
            continue
        user = current["user"] - before[tid]["user"]
        system = current["system"] - before[tid]["system"]
        if user >= 0 and system >= 0:
            rows.append({"threadHandle": hex(tid), "name": current["name"],
                         "userCounterDelta": user, "systemCounterDelta": system,
                         "totalCounterDelta": user + system})
    total = sum(r["totalCounterDelta"] for r in rows)
    assert total > 0
    for row in rows:
        row["fractionOfObservedThreadCPU"] = row["totalCounterDelta"] / total
    rows.sort(key=lambda r: r["totalCounterDelta"], reverse=True)
    record = {"timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "gamePID": args.pid, "wallSeconds": time.monotonic()-start,
              "processMemoryRead": False, "gameSuspended": False,
              "threads": rows}
    output.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({**{k:v for k,v in record.items() if k != "threads"}, "topThreads": rows[:10]}))

if __name__ == "__main__":
    main()
