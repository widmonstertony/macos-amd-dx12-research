"""Bounded debugger capture of a native Wine fault with our GPU library on stack.

Import inside LLDB, then call watch(debugger, pid, output_directory, seconds).
No target expressions, changed return values, signal suppression, or driver
breakpoints. Detach after the first matching fault, process exit, or timeout.
This is a fault diagnostic, never a valid FPS measurement.
"""
import datetime
import json
from pathlib import Path
import struct
import time
import lldb

_state = None


def fault(frame, location, internal_dict):
    global _state
    thread = frame.GetThread()
    frames = []
    matching = False
    for f in thread:
        module = f.GetModule().GetFileSpec().GetFilename() or ""
        name = f.GetFunctionName() or f.GetSymbol().GetName() or ""
        frames.append({"pc": hex(f.GetPC()), "module": module, "function": name})
        matching |= module in ("libCandidate.dylib", "libProbeGuard.dylib") or "vkQueueSubmit2" in name
        if len(frames) == 96:
            break
    if not matching:
        _state["nonMatchingFaults"] += 1
        return False
    error = lldb.SBError()
    address = frame.FindRegister("rsi").GetValueAsUnsigned()
    raw = thread.GetProcess().ReadMemory(address, 152, error)
    record = {"timeUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "threadID": thread.GetThreadID(), "frames": frames,
              "recordAddress": hex(address), "readError": str(error)}
    if error.Success() and len(raw) >= 32:
        code, flags, next_record, fault_address, count = struct.unpack_from("<IIQQI", raw)
        record.update(code=hex(code), flags=hex(flags), faultAddress=hex(fault_address),
                      information=[hex(v) for v in struct.unpack_from("<" + "Q" * min(count, 15), raw, 32)])
    _state["fault"] = record
    (_state["directory"] / "native-fault.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"nativeGPUStackFaultCaptured": True, "code": record.get("code"),
                      "threadID": thread.GetThreadID()}), flush=True)
    return True


def watch(debugger, pid, directory, seconds=1200):
    global _state
    root = Path(__file__).resolve().parents[1]
    directory = Path(directory).resolve()
    assert directory.is_relative_to(root / "evidence")
    assert 10 <= seconds <= 1800
    directory.mkdir(exist_ok=False)
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    assert process.GetProcessID() == pid
    assert "SB-Win64-Shipping.exe" in target.GetExecutable().GetFilename()
    _state = {"directory": directory, "fault": None, "nonMatchingFaults": 0}
    bp = target.BreakpointCreateByName("handle_syscall_fault", "ntdll.so")
    assert bp.GetNumLocations() == 1, "Exact open-source Wine handler required"
    bp.SetScriptCallbackFunction(__name__ + ".fault")
    debugger.SetAsync(True)
    record = {"gamePID": pid, "maximumSeconds": seconds, "gameFPSValid": False,
              "cacheDeleted": False, "targetReturnValuesChanged": False,
              "startUTC": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    start = time.monotonic()
    try:
        error = process.Continue()
        assert error.Success(), str(error)
        while time.monotonic() - start < seconds:
            if _state["fault"] is not None:
                record["finished"] = "matching-native-fault"
                break
            state = process.GetState()
            if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
                record["finished"] = "game-exited-or-detached"
                break
            # Stop on an unexpected debugger event; do not suppress signals.
            if state in (lldb.eStateStopped, lldb.eStateCrashed) and time.monotonic() - start > 2:
                record["finished"] = "other-debugger-stop"
                record["stopReasons"] = [t.GetStopReason() for t in process]
                break
            time.sleep(.25)
        else:
            record["finished"] = "bounded-timeout"
    finally:
        target.BreakpointDelete(bp.GetID())
        if process.GetState() not in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
            if process.GetState() == lldb.eStateRunning:
                process.Stop()
            error = process.Detach()
            record["detached"] = error.Success()
            record["detachError"] = str(error)
        record["nonMatchingFaults"] = _state["nonMatchingFaults"]
        record["faultCaptured"] = _state["fault"] is not None
        record["endUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (directory / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)
