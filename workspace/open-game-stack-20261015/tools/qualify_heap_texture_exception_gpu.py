#!/usr/bin/env python3
"""Owned helper/GPU regression; never operates game, Steam, Wine or prefixes."""
import argparse
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--library', type=pathlib.Path)
p.add_argument('--baseline-library', type=pathlib.Path)
p.add_argument('--prepare-only', action='store_true')
p.add_argument('--run-prepared', action='store_true')
a = p.parse_args()
if a.run_prepared and (a.prepare_only or a.library or a.baseline_library):
    p.error('--run-prepared cannot be combined with preparation arguments')
out = a.output.resolve()
assert out.is_relative_to(ROOT/'evidence')
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()


def command(argv, label, timeout=120, env=None):
    with (out/(label+'.stdout')).open('w') as so, (out/(label+'.stderr')).open('w') as se:
        result = subprocess.run([str(x) for x in argv], stdout=so, stderr=se, timeout=timeout, env=env)
    return result.returncode


if not a.run_prepared:
    assert not out.exists() and a.library and a.baseline_library
    out.mkdir()
    flags = (ROOT/'build/moltenvk-bounded-archive/MoltenVK/CMakeFiles/MoltenVK.dir/flags.make').read_text()
    defines = {line.split(' = ', 1)[0]:line.split(' = ', 1)[1] for line in flags.splitlines() if ' = ' in line}
    plist = out/'high-performance-gpu.plist'
    plist.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
                     '<key>CFBundleIdentifier</key><string>org.open-game-stack.precise-heap-regression</string>'
                     '<key>CFBundlePackageType</key><string>APPL</string>'
                     '<key>NSSupportsAutomaticGraphicsSwitching</key><false/>'
                     '</dict></plist>\n')
    builds = []
    for label, source in [('baseline', a.baseline_library.resolve()), ('candidate', a.library.resolve())]:
        assert source.is_file() and source.is_relative_to(ROOT/'build')
        frozen = out/(label+'.dylib')
        shutil.copy2(source, frozen)
        binary = out/label
        cmd = ['clang++', '-std=c++17', '-O2', '-DNDEBUG', '-DMVK_USE_METAL_PRIVATE_API=0',
               '-DMVK_EXCLUDE_SPIRV_TOOLS=1', '-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross',
               '-Wl,-headerpad_max_install_names', '-Wl,-sectcreate,__TEXT,__info_plist,'+str(plist),
               *shlex.split(defines['OBJCXX_INCLUDES']), ROOT/'src/heap_texture_exception_gpu.mm', frozen,
               '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore', '-o', binary]
        assert command(cmd, label+'-build') == 0, 'build failed: '+label
        install_id = subprocess.check_output(['otool', '-D', str(frozen)], text=True).splitlines()[1].strip()
        assert command(['install_name_tool', '-change', install_id, frozen, binary], label+'-relocate') == 0
        assert command(['codesign', '--force', '--sign', '-', binary], label+'-sign') == 0
        builds.append({'label': label, 'sourceLibrary': str(source), 'frozenLibrary': str(frozen),
                       'librarySHA256': sha(frozen), 'binary': str(binary), 'binarySHA256': sha(binary),
                       'command': [str(x) for x in cmd]})
    plan = {'fixture': str(ROOT/'src/heap_texture_exception_gpu.mm'),
            'fixtureSHA256': sha(ROOT/'src/heap_texture_exception_gpu.mm'), 'builds': builds,
            'gameOperated': False, 'preparedOnly': a.prepare_only}
    (out/'build.json').write_text(json.dumps(plan, indent=2)+'\n')
    if a.prepare_only:
        print(json.dumps({'prepared': True, 'output': str(out)}, indent=2))
        raise SystemExit(0)

plan = json.loads((out/'build.json').read_text())
assert pathlib.Path(plan['fixture']).resolve() == ROOT/'src/heap_texture_exception_gpu.mm'
assert sha(ROOT/'src/heap_texture_exception_gpu.mm') == plan['fixtureSHA256']
assert sorted(b['label'] for b in plan['builds']) == ['baseline', 'candidate']
results = []
env = {k:v for k,v in os.environ.items() if not k.startswith(('MVK_', 'MTL_', 'VK_', 'DYLD_'))}
env['MTL_DEBUG_LAYER'] = '1'
env['MVK_AMD_SHARED_LIVE_SNAPSHOTS'] = '1'
env['MVK_AMD_ENCODER_HEAP_PLANS'] = '1'
for build in plan['builds']:
    assert sha(pathlib.Path(build['frozenLibrary'])) == build['librarySHA256']
    assert sha(pathlib.Path(build['binary'])) == build['binarySHA256']
    for order in ['fetch-first', 'sample-first']:
        label = build['label']+'-'+order
        report = out/(label+'.json')
        start = time.monotonic()
        code = command([build['binary'], report, order], label, timeout=60, env=env)
        row = json.loads(report.read_text()) if report.exists() else {'passed': False, 'error': 'no report'}
        row.update(label=label, returncode=code, librarySHA256=build['librarySHA256'],
                   elapsedSeconds=time.monotonic()-start, gameOperated=False)
        results.append(row)

old = [r for r in results if r['label'].startswith('baseline-')]
new = [r for r in results if r['label'].startswith('candidate-')]
assert sorted(r['label'] for r in results) == [
    'baseline-fetch-first', 'baseline-sample-first',
    'candidate-fetch-first', 'candidate-sample-first']
old_throw = any(r.get('error') == 'retained resource changed heap identity' and not r['passed'] for r in old)
new_gpu = all(r['returncode'] == 0 and r['passed'] and r.get('mismatches') == 0
              and r.get('fixturePlanVerified') and r.get('excludedResourceVerified')
              and r.get('exceptionHeapMetadataCorrect') and r.get('encoderResetExercised')
              and r.get('pixelsOrWordsChecked') == 645 and r.get('renderGPUCompleted')
              and r.get('writeSampleGPUCompleted') and r.get('actualRenderHeapDeclarations', 0) >= 1
              and r.get('actualComputeHeapDeclarations', 0) >= 1
              and r.get('actualComputeWriteCalls', 0) >= 2 for r in new)
report = {'passed': old_throw and new_gpu, 'baselineRealHelperThrowReproduced': old_throw,
          'candidateActualGPUReadbackPassed': new_gpu, 'results': results, 'gameOperated': False,
          'actualGamePerformanceValidated': False}
(out/'qualification.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
