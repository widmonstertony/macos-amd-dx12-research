#!/usr/bin/env python3
"""Reproduce the precise-fallback heap identity CPU regression; never use a GPU.

All generated files, including the legacy caller source mutation, stay in one
new directory under this checkout's evidence/. Native sources remain read-only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK'
COMMANDS = NATIVE / 'Commands'
OBJECTS = NATIVE / 'GPUObjects'
SOURCE = ROOT / 'src/controls/heap_plan_precise_identity_control.mm'
CALLER = COMMANDS / 'MVKCommandEncoderState.mm'
EXISTING = ROOT / 'src/controls/encoder_heap_ledger_control.cpp'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path,
                        help='A new directory under this checkout\'s evidence/')
    args = parser.parse_args()
    out = args.output.resolve()
    evidence = (ROOT / 'evidence').resolve()
    if out == evidence or not out.is_relative_to(evidence):
        parser.error('--output must be a new directory below this checkout\'s evidence/')
    if out.exists() or not out.parent.is_dir():
        parser.error('--output must not exist and its parent directory must already exist')
    out.mkdir(mode=0o700)

    inputs = [Path(__file__).resolve(), SOURCE, CALLER,
              COMMANDS / 'MVKEncoderHeapLedger.h',
              COMMANDS / 'MVKEncoderResourceIndex.h',
              OBJECTS / 'MVKBufferHeapReadPlan.h', EXISTING]
    manifest = []
    commands = []
    # Property doubles need neither runtime overrides nor injected libraries.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('DYLD_', 'MVK_', 'MTL_', 'VK_'))}

    def command(label, argv, expected=0):
        result = subprocess.run([str(x) for x in argv], cwd=ROOT, env=env,
                                text=True, capture_output=True, timeout=45)
        (out / (label + '.stdout')).write_text(result.stdout)
        (out / (label + '.stderr')).write_text(result.stderr)
        commands.append({'label': label, 'argv': [str(x) for x in argv],
                         'exitCode': result.returncode,
                         'expectedExitCode': expected})
        if result.returncode != expected:
            raise RuntimeError(f'{label}: exit {result.returncode}; expected {expected}')
        return result

    try:
        manifest = [{'path': str(p), 'bytes': p.stat().st_size, 'sha256': digest(p)}
                    for p in inputs]
        command('build', ['clang++', '-std=c++17', '-O2', '-Wall', '-Wextra',
                         '-Werror', '-fno-objc-arc', '-framework', 'Foundation',
                         '-framework', 'Metal', '-I' + str(COMMANDS),
                         '-I' + str(OBJECTS), SOURCE, '-o', out / 'control'])
        command('corrected-caller', [out / 'control', out / 'result.json', CALLER])
        result = json.loads((out / 'result.json').read_text())
        if not (result['passed'] and result['actualCallerUsesResourceHeap']
                and result['correctedOrderAndResetCases'] == 4
                and result['genuineHeapChangeRejections'] == 10):
            raise RuntimeError('corrected caller regression coverage incomplete')

        # The actual source is inspected by the control. Revert only this owned
        # copy to prove the regression rejects the historical caller argument.
        caller_text = CALLER.read_text()
        needle = 'addPrecise(resource,resource.heap)'
        if caller_text.count(needle) != 1:
            raise RuntimeError('expected exactly one corrected caller argument')
        mutant = out / 'legacy-caller.source-mutant.mm'
        mutant.write_text(caller_text.replace(needle, 'addPrecise(resource,nil)', 1))
        legacy = command('legacy-caller-must-fail',
                         [out / 'control', out / 'unexpected-legacy-result.json', mutant], 2)
        if legacy.stderr.strip() != 'retained resource changed heap identity':
            raise RuntimeError('legacy mutation did not reproduce the exact logic_error')

        command('existing-ledger-build',
                ['clang++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
                 '-I' + str(COMMANDS), EXISTING, '-o', out / 'existing-ledger-control'])
        command('existing-ledger',
                [out / 'existing-ledger-control', out / 'existing-ledger-result.json'])
        existing = json.loads((out / 'existing-ledger-result.json').read_text())
        if not existing['passed'] or existing['mismatches'] != 0:
            raise RuntimeError('existing ledger control failed')
        for item in manifest:
            if digest(Path(item['path'])) != item['sha256']:
                raise RuntimeError('input changed during CPU control: ' + item['path'])
        report = {
            'passed': True, 'CPUOnly': True, 'commands': commands, 'inputs': manifest,
            'newRegression': result, 'existingLedger': existing,
            'legacySourceMutationRejectedWithExactError': True,
            'nativeSourcesUnchangedByControl': True, 'MetalDevicesCreated': 0,
            'GPUCommandsSubmitted': 0, 'gameOperated': False, 'cacheModified': False,
            'deployed': False,
            'limitations': 'Actual portable ledger and actual Objective-C plan headers '
                          'execute using CPU property doubles; caller metadata boundary '
                          'modeled with actual caller source guard; full native helper '
                          'and Metal driver not executed.'}
    except Exception as exc:
        report = {'passed': False, 'error': str(exc), 'commands': commands,
                  'inputs': manifest, 'CPUOnly': True, 'gameOperated': False,
                  'GPUCommandsSubmitted': 0}
    (out / 'qualification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'error': report.get('error'),
                      'output': str(out), 'commands': len(commands),
                      'newChecks': report.get('newRegression', {}).get('checks'),
                      'existingChecks': report.get('existingLedger', {}).get('checks')},
                     indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
