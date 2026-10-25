#!/usr/bin/env python3
"""Arm bounded diagnostics after observed game foreground; never input/launch/stop it."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--lstart', required=True)
    p.add_argument('--profile', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--wait-seconds', type=int, default=90)
    p.add_argument('--capture-seconds', type=int, default=35)
    a = p.parse_args()
    assert 5 <= a.wait_seconds <= 120 and 10 <= a.capture_seconds <= 45
    out = a.output.resolve()
    profile = a.profile.resolve()
    assert out.is_relative_to(ROOT / 'evidence') and not out.exists()
    assert profile.is_relative_to(ROOT / 'evidence') and profile.is_dir()
    gate = out.with_suffix('.gate')
    gate.mkdir()

    def identity():
        row = subprocess.run(['/bin/ps', '-p', str(a.pid), '-o', 'lstart=,comm='],
                             capture_output=True, text=True, check=True).stdout.strip()
        assert row.startswith(a.lstart) and row.endswith('SB-Win64-Shipping.exe'), row
        return row

    target = identity()
    observer = subprocess.Popen([str(ROOT / 'build/probes/observe_game_activity'),
                                 str(a.pid), str(a.wait_seconds), str(gate / 'foreground.jsonl')],
                                stdout=(gate / 'observer.stdout').open('w'),
                                stderr=(gate / 'observer.stderr').open('w'))
    record = dict(gamePID=a.pid, identity=target, gameInputOrRestart=False,
                  gateObserverPID=observer.pid, captureDirectory=str(out),
                  gateStartedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
    control = out.with_suffix('.control.json')
    control.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(dict(ready=True, gateObserverPID=observer.pid, output=str(out))), flush=True)
    armed = {}
    try:
        deadline = time.monotonic() + a.wait_seconds
        consecutive = 0
        last_time = None
        while time.monotonic() < deadline:
            f = gate / 'foreground.jsonl'
            # The observer writes JSON then its newline. Ignore partial rows.
            try:
                lines = f.read_bytes().split(b'\n')[:-1]
                row = json.loads(lines[-1]) if lines else None
            except (OSError, ValueError):
                row = None
            if row:
                stamp = row.get('time')
                fresh = isinstance(stamp, (float, int)) and 0 <= time.time()-978307200-stamp <= 3
                if stamp != last_time:
                    continuous = last_time is not None and 0 < stamp-last_time <= 2.5 if fresh else False
                    last_time = stamp if fresh else None
                    good = fresh and row.get('foreground') and row.get('visible')
                    consecutive = (consecutive+1 if continuous else 1) if good else 0
                if consecutive >= 3:
                    break
            if observer.poll() is not None:
                raise RuntimeError('Foreground observer ended before trigger')
            time.sleep(0.5)
        else:
            record['status'] = 'foreground-wait-timeout'
            return 2
        identity()
        trace = profile / 'msl'
        record['logOffsets'] = {n: (trace/n).stat().st_size if (trace/n).exists() else 0
                                for n in [f'cpu-stutter-{a.pid}.jsonl', f'stutter-native-{a.pid}.jsonl']}
        for name in ['cpu-stutter.arm', 'gpu-counter.arm']:
            f = profile/name
            f.touch()
            os.utime(f, None)
            armed[name] = f.stat().st_mtime_ns
        record.update(armed=armed, trigger=row,
                      UTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
        control.write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(dict(captureStarted=True, UTC=record['UTC'])), flush=True)
        cmd = [sys.executable, str(ROOT/'tools/capture_stutter_system.py'), '--pid', str(a.pid),
               '--lstart', a.lstart, '--output', str(out), '--seconds', str(a.capture_seconds),
               '--foreground', '--stack-seconds', '2', '--stack-every', '30',
               '--max-stack-bursts', '2', '--trace-every', '3', '--system-every', '5',
               '--max-output-mib', '32', '--trace-directory', str(trace)]
        with gate.joinpath('capture.stdout').open('w') as so, gate.joinpath('capture.stderr').open('w') as se:
            result = subprocess.run(cmd, stdout=so, stderr=se, timeout=a.capture_seconds+15)
        record['collectorExitCode'] = result.returncode
        record['status'] = 'captured' if result.returncode == 0 else 'collector-failed'
        return result.returncode
    finally:
        for name, stamp in armed.items():
            f = profile/name
            if f.exists() and f.stat().st_mtime_ns == stamp:
                f.unlink()
        if observer.poll() is None:
            observer.terminate()  # Only our read-only observer child, never the game.
            observer.wait(timeout=5)
        record['endedUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        control.write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record), flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
