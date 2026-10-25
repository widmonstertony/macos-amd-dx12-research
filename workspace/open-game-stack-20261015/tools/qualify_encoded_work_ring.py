#!/usr/bin/env python3
"""Check ring retention, concurrent snapshots and equivalent draw formatting."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

r = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--label', required=True)
a = p.parse_args()
assert re.fullmatch('[a-z0-9-]{1,64}', a.label)
out = r / 'evidence' / a.label
out.mkdir(exist_ok=False)
header = r / 'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKEncodedWorkRing.h'
files = [header, r / 'src/encoded_work_ring_control.mm', r / 'src/controls/encoded_work_ring_full_allocation.h']
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
before = {str(f.relative_to(r)): sha(f) for f in files}
b = out / 'ring-control'
cmd = ['clang++', '-std=c++17', '-O2', '-I'+str(header.parent), str(files[1]),
       '-framework', 'Foundation', '-o', str(b)]
subprocess.run(cmd, check=True, capture_output=True)
run = subprocess.run([str(b)], capture_output=True, timeout=40)
(out / 'stdout.log').write_bytes(run.stdout)
(out / 'stderr.log').write_bytes(run.stderr)
result = json.loads(run.stdout) if run.stdout else {}
stable = all(sha(r / k) == v for k, v in before.items())
proof = {'sources': before, 'sourceStable': stable, 'command': cmd,
         'exitCode': run.returncode, 'CPUControl': result, 'gameStarted': False,
         'passed': stable and run.returncode == 0 and result.get('passed', False)}
(out / 'run.json').write_text(json.dumps(proof, indent=2)+'\n')
print(json.dumps({'evidence': str(out), 'passed': proof['passed']}))
raise SystemExit(0 if proof['passed'] else 1)
