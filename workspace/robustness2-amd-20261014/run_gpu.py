#!/usr/bin/env python3
"""Run only isolated, headless native GPU probes; never starts Wine or a game."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent
BASE_EVIDENCE = ROOT / 'evidence'
parser = argparse.ArgumentParser()
parser.add_argument('--run', action='store_true', help='explicitly execute native GPU probes')
parser.add_argument('--metal-validation', action='store_true', help='enable Metal API validation for these subprocesses only')
parser.add_argument('--label', help='unique label for a new, preserved evidence/runs subdirectory')
args = parser.parse_args()
if not args.run:
    parser.error('Explicit --run required. No workload was started.')
hashes = json.loads((BASE_EVIDENCE / 'final-build-sha256.json').read_text())
for name, expected in hashes.items():
    if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
        raise SystemExit('Source/build changed; rebuild before GPU validation: ' + name)
EVIDENCE = BASE_EVIDENCE
if args.label:
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', args.label):
        parser.error('Label must be a short alphanumeric name')
    EVIDENCE = BASE_EVIDENCE / 'runs' / args.label
    EVIDENCE.mkdir(parents=True, exist_ok=False)
env = {k: v for k, v in os.environ.items()
       if not k.startswith(('DYLD_', 'VK_', 'MVK_', 'GPU_ADAPTER_', 'MTL_DEBUG_'))}
env.update(VK_ICD_FILENAMES='/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json',
           MVK_CONFIG_LOG_LEVEL='2')
if args.metal_validation:
    env['MTL_DEBUG_LAYER'] = '1'
suite = []
cases = [
    ('memory-final-v13', ['build/gpu_probe', 'build/memory-original.spv', 'build/memory-robust.spv']),
    ('memory-final-v15', ['build/gpu_probe', 'build/memory-v15-original.spv', 'build/memory-v15-robust.spv']),
    ('array-fixed-final', ['build/array_probe', 'build/array-fixed-robust.spv']),
    ('array-runtime-final', ['build/array_probe', 'build/array-runtime-robust.spv']),
]
for stem, command in cases:
    output = EVIDENCE / (stem + '-results.json')
    # A stale success file must never masquerade as this execution's output.
    if output.exists():
        raise SystemExit('Evidence already exists; choose a new evidence directory/run label.')
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        p = subprocess.run(command + [str(output)], cwd=ROOT, env=env,
                           capture_output=True, text=True, timeout=50)
    except subprocess.TimeoutExpired as exc:
        (EVIDENCE / (stem + '.timeout.txt')).write_text(str(exc))
        raise SystemExit('Native probe timeout; stopped the suite: ' + stem)
    (EVIDENCE / (stem + '.stdout.log')).write_text(p.stdout)
    (EVIDENCE / (stem + '.stderr.log')).write_text(p.stderr)
    entry = {'case': stem, 'command': command, 'startedUTC': started,
             'exitCode': p.returncode, 'metalAPIValidationRequested': args.metal_validation}
    if output.exists():
        entry['results'] = json.loads(output.read_text())
    suite.append(entry)
    (EVIDENCE / 'final-gpu-suite.json').write_text(json.dumps(suite, indent=2) + '\n')
    print(stem + ': ' + ('PASS' if p.returncode == 0 else 'FAIL'), flush=True)
    if p.returncode or not entry.get('results', {}).get('passed'):
        raise SystemExit('Stopped on native GPU failure; original logs retained.')
print('All isolated GPU suites passed; native robustness2 feature bits unchanged.')
