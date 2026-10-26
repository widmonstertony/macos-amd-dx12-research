#!/usr/bin/env python3
"""CPU-only compute/render detached-request lifetime and timeout qualification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OBJECTS = ROOT / 'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects'
SOURCE = ROOT / 'src/controls/detached_pipeline_request_control.mm'
HEADER = OBJECTS / 'MVKDetachedPipelineRequest.h'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    evidence = (ROOT / 'evidence').resolve()
    if out == evidence or not out.is_relative_to(evidence):
        parser.error('--output must be below this checkout\'s evidence/')
    if out.exists() or not out.parent.is_dir():
        parser.error('--output must be new, with an existing parent directory')
    out.mkdir(mode=0o700)
    inputs = [Path(__file__).resolve(), SOURCE, HEADER]
    manifest = [{'path': str(p), 'bytes': p.stat().st_size, 'sha256': digest(p)} for p in inputs]
    commands, results = [], []
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('DYLD_', 'MVK_', 'MTL_', 'VK_', 'ASAN_', 'UBSAN_'))}
    env.update(ASAN_OPTIONS='halt_on_error=1:detect_stack_use_after_return=1',
               UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')

    def command(label, argv):
        run = subprocess.run([str(x) for x in argv], cwd=ROOT, env=env,
                             text=True, capture_output=True, timeout=45)
        (out / (label + '.stdout')).write_text(run.stdout)
        (out / (label + '.stderr')).write_text(run.stderr)
        commands.append({'label': label, 'argv': [str(x) for x in argv], 'exitCode': run.returncode})
        if run.returncode:
            raise RuntimeError(f'{label}: exit {run.returncode}; inspect owned stderr')

    try:
        for label, extra in [('optimized', ['-O2']),
                             ('sanitized', ['-O1', '-g', '-fno-omit-frame-pointer',
                                            '-fsanitize=address,undefined'])]:
            binary = out / label
            command(label + '-build', ['clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-fno-objc-arc', '-fblocks', '-framework', 'Foundation', '-framework', 'Metal',
                    '-I' + str(OBJECTS), *extra, SOURCE, '-o', binary])
            result_path = out / (label + '.json')
            command(label, [binary, result_path])
            result = json.loads(result_path.read_text())
            if not (result['passed'] and result['objectsCreated'] == result['objectsDestroyed']
                    and result['renderAndComputeCases'] == 12
                    and result['expiredBeforeSubmissionCases'] == 4
                    and result['lateCallbacks'] == 4
                    and result['GPUCommandsSubmitted'] == 0):
                raise RuntimeError(label + ': required coverage missing')
            results.append({'label': label, 'result': result, 'binarySHA256': digest(binary)})
        for item in manifest:
            if digest(Path(item['path'])) != item['sha256']:
                raise RuntimeError('input changed during CPU qualification')
        report = {'passed': True, 'CPUOnly': True, 'inputs': manifest, 'commands': commands,
                  'results': results, 'gameOperated': False, 'GPUCommandsSubmitted': 0,
                  'existingNativeFilesModified': False, 'cacheModified': False,
                  'markersModified': False, 'deployed': False,
                  'scope': 'Actual shared-owned request and both helper entry points with NSObject '
                           'device/descriptor/result/error doubles; no real MTLDevice or GPU work. '
                           'Root integration and GPU/archive mapping retention remain separate.'}
    except Exception as exc:
        report = {'passed': False, 'error': str(exc), 'inputs': manifest, 'commands': commands,
                  'results': results, 'gameOperated': False, 'GPUCommandsSubmitted': 0}
    (out / 'qualification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'error': report.get('error'),
                      'output': str(out), 'variants': [x['label'] for x in results]}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
