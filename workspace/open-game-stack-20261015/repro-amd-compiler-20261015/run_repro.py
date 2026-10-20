import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parent
name, fragment, *rest = sys.argv[1:]
math_mode = rest[0] if rest else 'safe'
out = root / 'evidence' / name
out.mkdir(exist_ok=False)
reports = Path.home() / 'Library/Logs/DiagnosticReports'
before = set(reports.glob('MTLCompilerService-*.ips'))
args = [str(root / 'build/pipeline_repro'), str(root / 'input/shader-vs-40f012fa5dc390cb.metal'), str(Path(fragment).resolve()), math_mode]
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
tick = time.monotonic()
with (out / 'stdout.txt').open('w') as stdout, (out / 'stderr.txt').open('w') as stderr:
    try:
        p = subprocess.run(args, stdout=stdout, stderr=stderr, timeout=45)
        status = {'returncode': p.returncode, 'timeout': False}
    except subprocess.TimeoutExpired:
        status = {'returncode': None, 'timeout': True}
status.update(timeUTC=started, elapsedSeconds=time.monotonic()-tick, args=args,
              fragmentSHA256=hashlib.sha256(Path(fragment).read_bytes()).hexdigest(),
              gameStarted=False, originalEnvironmentModified=False, closedBinariesModified=False)
(out / 'run.json').write_text(json.dumps(status, indent=2)+'\n')
new = []
for path in sorted(set(reports.glob('MTLCompilerService-*.ips')) - before):
    try:
        body = json.loads(path.read_text().split('\n', 1)[1])
        frames = body['threads'][body['faultingThread']]['frames'][:16]
        new.append(dict(report=str(path), captureTime=body.get('captureTime'),
                        exception=body.get('exception'), termination=body.get('termination'),
                        frames=[{k:f[k] for k in ('symbol','symbolLocation') if k in f} | {'image':body['usedImages'][f['imageIndex']].get('name')} for f in frames]))
    except (ValueError, KeyError, IndexError):
        pass
(out / 'crashes.json').write_text(json.dumps(new, indent=2)+'\n')
print(json.dumps(status, indent=2))
print((out / 'stdout.txt').read_text())
print((out / 'stderr.txt').read_text())
print('fresh compiler crash reports immediately available:', len(new))
