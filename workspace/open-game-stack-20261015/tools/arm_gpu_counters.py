#!/usr/bin/env python3
"""Refresh a timed GPU-counter marker for one bounded, verified game capture."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def capture_window(*, seconds, wait_seconds, minimum_records, identity_ok,
                   disk_ok, compute_records, arm, clock=time.monotonic,
                   sleep=time.sleep):
    """Warmup and capture have separate, finite budgets; no process signals."""
    start = clock()
    armed_at = None
    result = {'refreshes': 0, 'maximumCaptureSeconds': seconds,
              'maximumWarmupSeconds': wait_seconds,
              'maximumTotalSeconds': wait_seconds + seconds,
              'minimumComputeRecords': minimum_records}
    while True:
        now = clock()
        if not identity_ok():
            result['finished'] = 'game-exited-or-identity-changed'
            break
        if not disk_ok():
            result['finished'] = 'disk-reserve-stop-capture'
            break
        if armed_at is None:
            observed = compute_records() if minimum_records else 0
            if observed < minimum_records:
                remaining = wait_seconds - (now - start)
                if remaining <= 0:
                    result['finished'] = 'bounded-warmup-expired-without-capture'
                    break
                sleep(min(10, remaining))
                continue
            armed_at = clock()
            result['armedUTC'] = utc_now()
            result['warmupElapsedSeconds'] = armed_at - start
            result['computeRecordsAtArming'] = observed
        remaining = seconds - (clock() - armed_at)
        if remaining <= 0:
            result['finished'] = 'bounded-capture-expired'
            break
        arm()
        result['refreshes'] += 1
        sleep(min(10, remaining))
    result['elapsedSeconds'] = clock() - start
    result['captureElapsedSeconds'] = 0 if armed_at is None else clock() - armed_at
    return result


def expire(marker):
    if marker.exists():
        expired = time.time() - 60
        os.utime(marker, (expired, expired))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--launch-record', type=Path, required=True)
    parser.add_argument('--profile', required=True)
    parser.add_argument('--seconds', type=int, default=300,
                        help='Capture duration AFTER warmup, at most 600 seconds')
    parser.add_argument('--wait-seconds', type=int, default=600,
                        help='Separate maximum warmup wait, at most 1200 seconds')
    parser.add_argument('--after-compute-records', type=int, default=0)
    args = parser.parse_args()
    assert args.after_compute_records >= 0
    assert 10 <= args.seconds <= 600 and 10 <= args.wait_seconds <= 1200
    assert re.fullmatch('[a-z0-9-]{1,64}', args.profile)
    source = args.launch_record.resolve()
    assert source.is_relative_to(ROOT / 'evidence')
    launch = json.loads(source.read_text())
    assert launch['verified'] and launch['normalLicensedSteamRequest']
    games = [v for v in launch['observed'].values()
             if v.get('candidateMapped') and v.get('originalWriteDenied')]
    assert len(games) == 1
    pid = games[0]['pid']
    folder = ROOT / 'evidence' / args.profile
    marker = folder / 'gpu-counter.arm'
    header = (folder / 'game-trial-config.h').read_text()
    assert f'setenv("MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH", "{marker}", 1)' in header

    def identity():
        return subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,comm='],
                              capture_output=True, text=True, check=True).stdout.strip()

    original = identity()
    assert 'SB-Win64-Shipping.exe' in original

    def identity_ok():
        try:
            return identity() == original
        except subprocess.CalledProcessError:
            return False

    def arm():
        marker.touch()
        if 'armedUTC' not in record:
            record['armedUTC'] = utc_now()
            print(json.dumps({'armed': True, 'gamePID': pid,
                              'maximumCaptureSeconds': args.seconds}), flush=True)

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = folder / f'counter-arm-{stamp}.json'
    assert not out.exists()
    record = {'gamePID': pid, 'startUTC': utc_now(), 'refreshSeconds': 10,
              'signalSent': False, 'cacheDeleted': False}
    expire(marker)
    try:
        record.update(capture_window(
            seconds=args.seconds, wait_seconds=args.wait_seconds,
            minimum_records=args.after_compute_records, identity_ok=identity_ok,
            disk_ok=lambda: shutil.disk_usage(ROOT).free >= 3 * 1024**3,
            compute_records=lambda: sum(1 for _ in (folder / 'msl').glob(
                f'trace-compute-archive-{pid}-*.json')), arm=arm))
    except BaseException as error:
        record['finished'] = 'interrupted-or-failed'
        record['exceptionType'] = type(error).__name__
        raise
    finally:
        expire(marker)
        record['endUTC'] = utc_now()
        out.write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record), flush=True)


if __name__ == '__main__':
    main()
