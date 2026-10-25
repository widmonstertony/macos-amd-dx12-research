#!/usr/bin/env python3
"""Reproduce the exact-header CPU comparison; no game launch or deployment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--label', required=True)
p.add_argument('--fragmented-only', action='store_true')
a = p.parse_args()
assert re.fullmatch('[a-z0-9-]{1,64}', a.label)
out = root / 'evidence' / a.label
out.mkdir(exist_ok=False)
header = root / 'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKDescriptorUseCache.h'
baseline = root / 'src/controls/descriptor_pre_interior_filter.h'
source = root / 'src/descriptor_interior_blocks_control.mm'
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
before = {str(f.relative_to(root)): sha(f) for f in [header, baseline, source]}
binary = out / 'descriptor-control'
cmd = ['clang++', '-std=c++17', '-O3', '-DNDEBUG', '-I'+str(header.parent),
       str(source), '-framework', 'Foundation', '-framework', 'Metal', '-o', str(binary)]
subprocess.run(cmd, check=True, capture_output=True)
env = os.environ.copy()
env['MVK_AMD_DESCRIPTOR_WRITE_SHARDS'] = '1'
if a.fragmented_only:
    env['INTERIOR_FRAGMENTED_ONLY'] = '1'
else:
    env.pop('INTERIOR_FRAGMENTED_ONLY', None)
r = subprocess.run([str(binary), str(out / 'output.json')], env=env,
                   capture_output=True, timeout=90)
(out / 'stdout.log').write_bytes(r.stdout)
(out / 'stderr.log').write_bytes(r.stderr)
result = json.loads((out / 'output.json').read_text()) if (out / 'output.json').exists() else {}
stable = all(sha(root / key) == value for key, value in before.items())
proof = {'sources': before, 'sourceStable': stable, 'command': cmd,
         'exitCode': r.returncode, 'fragmentedOnly': a.fragmented_only,
         'CPUComparison': result, 'gameStarted': False,
         'GPUOutputTest': False,
         'passed': stable and r.returncode == 0 and result.get('passed', False)}
(out / 'run.json').write_text(json.dumps(proof, indent=2)+'\n')
print(json.dumps({'evidence': str(out), 'passed': proof['passed']}))
raise SystemExit(0 if proof['passed'] else 1)
