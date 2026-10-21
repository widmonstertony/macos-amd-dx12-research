"""Bounded argument-only sampling at our open-source descriptor-cache entry.

No descriptor contents, expressions, driver breakpoints or changed arguments.
This diagnostic interval must never be used for FPS comparisons.
"""
import datetime
import json
from pathlib import Path
import signal
import time
import lldb

_samples = []


def hit(frame, location, internal_dict):
    if len(_samples) < 64:
        _samples.append({
            # shared_ptr is a non-trivial return: SysV inserts its sret pointer
            # before this/src/count/stride. No descriptor contents are read.
            'slots': frame.FindRegister('rcx').GetValueAsUnsigned() & 0xffffffff,
            'stride': frame.FindRegister('r8').GetValueAsUnsigned(),
        })
    if len(_samples) >= 64:
        location.GetBreakpoint().SetEnabled(False)
    return False


def watch(debugger, pid, destination):
    global _samples
    _samples = []
    root = Path(__file__).resolve().parents[1]
    output = Path(destination).resolve()
    assert output.is_relative_to(root / 'evidence') and not output.exists()
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    assert process.GetProcessID() == pid
    assert 'SB-Win64-Shipping.exe' in target.GetExecutable().GetFilename()
    bp = target.BreakpointCreateByName(
        'MVKDescriptorUseCache::resources(char const*, unsigned int, unsigned long)',
        'libCandidate.dylib')
    assert bp.GetNumLocations() == 1, 'One exact open-source cache entry required'
    # Break at the entry instruction, before argument registers can be reused.
    address = bp.GetLocationAtIndex(0).GetAddress()
    symbol = address.GetSymbol()
    start_address = symbol.GetStartAddress().GetLoadAddress(target)
    target.BreakpointDelete(bp.GetID())
    bp = target.BreakpointCreateByAddress(start_address)
    bp.SetScriptCallbackFunction(__name__ + '.hit')
    signals = process.GetUnixSignals()
    old = (signals.GetShouldStop(signal.SIGUSR1), signals.GetShouldSuppress(signal.SIGUSR1),
           signals.GetShouldNotify(signal.SIGUSR1))
    signals.SetShouldStop(signal.SIGUSR1, False)
    signals.SetShouldSuppress(signal.SIGUSR1, False)
    signals.SetShouldNotify(signal.SIGUSR1, False)
    record = {'gamePID': pid, 'gameFPSValid': False, 'descriptorContentsRead': False,
              'argumentsChanged': False, 'startUTC': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    debugger.SetAsync(True)
    try:
        error = process.Continue()
        assert error.Success(), str(error)
        deadline = time.monotonic() + 5
        while len(_samples) < 64 and time.monotonic() < deadline:
            if process.GetState() in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
                break
            time.sleep(.05)
    finally:
        if process.GetState() == lldb.eStateRunning:
            process.Stop()
        target.BreakpointDelete(bp.GetID())
        signals.SetShouldStop(signal.SIGUSR1, old[0])
        signals.SetShouldSuppress(signal.SIGUSR1, old[1])
        signals.SetShouldNotify(signal.SIGUSR1, old[2])
        error = process.Detach()
        record.update(detached=error.Success(), samples=_samples,
                      endUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
        output.write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record), flush=True)
