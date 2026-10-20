#!/usr/bin/env python3
"""Exercise the unmodified official reporter through its 600-second scan.

This uses an independent pipe and a disposable copy of the private database.
No game client is registered. Uploads and analytics are explicitly disabled.
Only the diagnostic reporter is stopped after the bounded observation period.
"""
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import time
from check_crash_metadata import ROOT, OUT, environment, qualified

out = OUT / ('reporter-periodic-' + datetime.datetime.now(datetime.timezone.utc).strftime('%H%M%S'))
out.mkdir()
database = out / 'database'
shutil.copytree(ROOT / 'build/stellar-crash-report-state', database)
# A private, synthetic orphan is safe for the reporter to prune. Its removal
# proves that the periodic database task actually ran, beyond mere survival.
fixture = database / 'reports/11111111-2222-4333-8444-555555555555.dmp'
fixture.write_bytes(b'Diagnostic orphan fixture; not a real crash dump.\n')
os.utime(fixture, (1262304000, 1262304000))
reporter = ROOT.parent / 'stellar-overlay/crs-handler.exe'
win_database = 'Z:' + str(database).removeprefix('/Users/tonytan').replace('/', '\\')
arguments = [str(reporter), '--database=' + win_database,
             '--pipe-name=\\\\.\\pipe\\stellar-crash-db-qualification-' + str(int(time.time())),
             '--no-uploads', '--no-analytics', '--no-identify-client-via-url']
record = {'startUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'unmodifiedOfficialReporterSHA256': hashlib.sha256(reporter.read_bytes()).hexdigest(),
          'arguments': arguments, 'independentDatabase': str(database),
          'gameRestarted': False, 'shaderCacheDeleted': False,
          'periodicTasksEnabled': True, 'uploadsDisabled': True, 'completed': False,
          'syntheticOrphanFixture': str(fixture)}
start = time.monotonic()
with (out / 'stdout.log').open('w') as stdout, (out / 'stderr.log').open('w') as stderr:
    p = subprocess.Popen([str(qualified.SUPPORT / 'wine-loader'), *arguments],
                         cwd=ROOT.parent / 'stellar-overlay', env=environment(),
                         stdout=stdout, stderr=stderr, start_new_session=True)
    record['pid'] = p.pid
    try:
        while p.poll() is None and time.monotonic() - start < 630:
            record['elapsedSeconds'] = round(time.monotonic() - start, 2)
            record['syntheticOrphanPruned'] = not fixture.exists()
            (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
            time.sleep(1)
        record['elapsedSeconds'] = round(time.monotonic() - start, 2)
        record['aliveAfterOriginalFailureInterval'] = p.poll() is None and record['elapsedSeconds'] >= 620
        record['exitCodeBeforeCleanup'] = p.poll()
        record['syntheticOrphanPruned'] = not fixture.exists()
        record['completed'] = True
        print(json.dumps(record, indent=2), flush=True)
    finally:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(timeout=5)
        record['diagnosticReporterStopped'] = True
        (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
