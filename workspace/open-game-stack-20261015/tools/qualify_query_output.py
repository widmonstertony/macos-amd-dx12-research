#!/usr/bin/env python3
"""Bounded owned occlusion/timestamp output test; never launches a game."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--label', required=True)
    ap.add_argument('--library', type=Path, required=True)
    ap.add_argument('--timestamps', action='store_true')
    args = ap.parse_args()
    assert re.fullmatch(r'[A-Za-z0-9_-]{1,64}', args.label)
    library = args.library.resolve()
    assert library.is_relative_to(ROOT / 'build') and library.is_file()
    out = ROOT / 'evidence' / args.label
    out.mkdir()
    (out / 'msl').mkdir()
    icd = out / 'icd.json'
    icd.write_text(json.dumps({'file_format_version': '1.0.0', 'ICD': {
        'library_path': str(library), 'api_version': '1.4.0',
        'is_portability_driver': True}}))
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('DYLD_', 'VK_', 'MVK_', 'MTL_', 'R2_'))}
    env.update(VK_ICD_FILENAMES=str(icd), MTL_DEBUG_LAYER='1',
               MVK_CONFIG_LOG_LEVEL='2', MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',
               MVK_AMD_REFERENCE_RBA2='1', MVK_AMD_REFERENCE_RIA2='1',
               MVK_AMD_REFERENCE_NULL='1', MVK_AMD_BYTE_GUARDS='1',
               MVK_CONFIG_SHADER_DUMP_DIR=str(out / 'msl'),
               MVK_AMD_RUNTIME_TRACE='1', MVK_AMD_GPU_TIMEOUT_TRACE='1',
               MVK_AMD_QUEUE_DEPENDENCY_DUMP_ALL='1',
               MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES='1',
               MVK_AMD_REPLAY_FAILED_MESH='1', MVK_AMD_SERIALIZE_PIPELINE_LINK='1')
    probe = 'query_timestamp_probe' if args.timestamps else 'occlusion_probe'
    command = [str(ROOT / 'build/probes' / probe),
               str(ROOT / 'build/probes/guard.vert.spv'),
               str(ROOT / 'build/probes/guard.frag.spv'), str(out / 'output.json')]
    start = time.monotonic()
    timed_out = False
    try:
        p = subprocess.run(command, env=env, capture_output=True, timeout=25)
        code, stdout, stderr = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as ex:
        timed_out = True
        code, stdout, stderr = None, ex.stdout or b'', ex.stderr or b''
    (out / 'stdout.log').write_bytes(stdout)
    (out / 'stderr.log').write_bytes(stderr)
    traces = [json.loads(f.read_text()) for f in
              (out / 'msl').glob('trace-queue-dependencies-*.json')]
    output = json.loads((out / 'output.json').read_text()) if (out / 'output.json').exists() else {}
    summary = {'command': command, 'librarySHA256': hashlib.sha256(library.read_bytes()).hexdigest(),
               'exitCode': code, 'timedOut': timed_out,
               'elapsedSeconds': time.monotonic() - start,
               'timestamps': args.timestamps, 'GPUOutput': output,
               'completedRecords': len(traces),
               'workKinds': sorted({w['kind'] for t in traces for w in t.get('workEvents', [])}),
               'metalValidationEnabled': b'Metal API Validation Enabled' in stderr,
               'gamePlayable': False}
    summary['passed'] = code == 0 and output.get('passed', False)
    (out / 'run.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(stdout.decode(errors='replace'))
    print(json.dumps(summary, indent=2))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
