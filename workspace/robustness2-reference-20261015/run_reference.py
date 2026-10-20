#!/usr/bin/env python3
"""Bounded AMD-only reference GPU probe, private compiler experiment, not R2 conformance."""
import argparse, datetime, hashlib, json, os, pathlib, re, subprocess

root = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--run', action='store_true')
parser.add_argument('--label', required=True)
parser.add_argument('--suite', choices=['compiler', 'memory', 'vector'], default='compiler')
args = parser.parse_args()
if not args.run or not re.fullmatch('[A-Za-z0-9_-]{1,64}', args.label):
    parser.error('--run and a safe unique --label are required')
dest = root / 'evidence' / args.label
dest.mkdir(exist_ok=False)
library = root / 'build/driver/MoltenVK/libMoltenVK.1.4.2.dylib'
icd = dest / 'icd.json'
icd.write_text(json.dumps({'file_format_version': '1.0.0', 'ICD': {
    'library_path': str(library), 'api_version': '1.4.0', 'is_portability_driver': True}}))
env = {k: v for k, v in os.environ.items() if not k.startswith(
    ('DYLD_', 'VK_', 'MVK_', 'MTL_', 'GPU_ADAPTER_', 'R2_'))}
env.update(PATH='/nonexistent', VK_ICD_FILENAMES=str(icd),
           MVK_CONFIG_LOG_LEVEL='2', MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',
           MVK_AMD_REFERENCE_RBA2='1', MTL_DEBUG_LAYER='1',
           MVK_AMD_REFERENCE_RIA2='1', MVK_AMD_REFERENCE_NULL='1',
           MVK_CONFIG_SHADER_DUMP_DIR=str(dest / 'msl'))
(dest / 'msl').mkdir()
command = [str(root / 'build/reference_robust_access'), str(root / 'build/spv')]
if args.suite == 'memory':
    shader = root.parent / 'robustness2-amd-20261014/build/memory-original.spv'
    command = [str(root / 'build/reference_memory'), str(shader), str(shader), str(dest / 'output.json')]
elif args.suite == 'vector':
    command = [str(root / 'build/vector_tail'), str(root / 'build/spv'), str(dest / 'output.json')]
record = {'timeUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'librarySHA256': hashlib.sha256(library.read_bytes()).hexdigest(),
          'command': command, 'suite': args.suite, 'gameStarted': False, 'privateCompilerOptionOnly': True}
try:
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=45)
    record.update(exitCode=result.returncode)
    stdout, stderr = result.stdout, result.stderr
except subprocess.TimeoutExpired as e:
    record.update(timeout=True)
    stdout = e.stdout.decode(errors='replace') if isinstance(e.stdout, bytes) else e.stdout or ''
    stderr = e.stderr.decode(errors='replace') if isinstance(e.stderr, bytes) else e.stderr or ''
(dest / 'stdout.log').write_text(stdout)
(dest / 'stderr.log').write_text(stderr)
record['metalValidationEnabled'] = 'Metal API Validation Enabled' in stderr
if (dest / 'output.json').exists():
    record['results'] = json.loads((dest / 'output.json').read_text())
success = ('GPU_RESULT_CHECKS_COMPLETE failures=0' in stdout) if args.suite == 'compiler' else record.get('results', {}).get('passed', False)
record['passed'] = record.get('exitCode') == 0 and success
(dest / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
print(stdout)
print(stderr)
raise SystemExit(0 if record['passed'] else 1)
