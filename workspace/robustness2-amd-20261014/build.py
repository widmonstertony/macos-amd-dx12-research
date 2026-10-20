#!/usr/bin/env python3
"""Rebuild isolated sources and compiler checks. Does not run GPU workloads."""
import hashlib
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
BUILD = ROOT / 'build'
EVIDENCE = ROOT / 'evidence'
BUILD.mkdir(exist_ok=True)
EVIDENCE.mkdir(exist_ok=True)

with (EVIDENCE / 'final-build.log').open('w') as log:
    def run(args):
        log.write('$ ' + ' '.join(map(str, args)) + '\n')
        log.flush()
        p = subprocess.run(list(map(str, args)), cwd=ROOT, text=True,
                           stdout=log, stderr=subprocess.STDOUT)
        log.flush()
        if p.returncode:
            raise SystemExit('Build failed; see evidence/final-build.log')

    run(['/usr/local/bin/glslc', '-O0', '--target-env=vulkan1.1',
         'shaders/memory.comp', '-o', 'build/memory-original.spv'])
    run([sys.executable, 'src/r2_lower.py', 'build/memory-original.spv',
         'build/memory-robust.spv'])
    (BUILD / 'descriptor-counts.json').write_text('{"0:0":3}\n')
    for runtime in (False, True):
        stem = 'array-runtime' if runtime else 'array-fixed'
        run(['/usr/local/bin/glslc', '-O0', '--target-env=vulkan1.1'] +
            (['-DRUNTIME_DESCRIPTORS=1'] if runtime else []) +
            ['shaders/descriptor-array.comp', '-o', f'build/{stem}-original.spv'])
        run([sys.executable, 'src/r2_lower.py', f'build/{stem}-original.spv',
             f'build/{stem}-robust.spv', '--descriptor-counts',
             'build/descriptor-counts.json'])

    def header(stem, filename, prefix, count):
        m = json.loads((BUILD / (stem + '.json')).read_text())
        slots = [-1] * count
        for r in m['resources'].values():
            if r['set'] != 0 or r['binding'] >= count:
                raise ValueError('Unexpected test resource binding')
            slots[r['binding']] = r['slot']
        (BUILD / filename).write_text(
            '#pragma once\n' +
            f'static constexpr int {prefix}_SLOT_COUNT={m["metadataSlots"]};\n' +
            f'static constexpr int {prefix}_SLOTS[{count}]={{' +
            ','.join(map(str, slots)) + '};\n')

    header('memory-robust', 'manifest.hpp', 'R2', 32)
    header('array-fixed-robust', 'array-manifest.hpp', 'ARRAY', 3)
    # Both array modules must use the same binding-to-metadata layout.
    fixed = json.loads((BUILD / 'array-fixed-robust.json').read_text())
    runtime = json.loads((BUILD / 'array-runtime-robust.json').read_text())
    def layout(m):
        return sorted((r['set'], r['binding'], r['slot'], r['count'])
                      for r in m['resources'].values())
    assert layout(fixed) == layout(runtime)
    run([sys.executable, 'src/compiler_checks.py'])
    # SPIR-V 1.3 and 1.5 also need an identical host metadata layout.
    v15 = json.loads((BUILD / 'memory-v15-robust.json').read_text())
    normal = json.loads((BUILD / 'memory-robust.json').read_text())
    assert layout(v15) == layout(normal)
    for name in ('gpu_probe', 'array_probe'):
        run(['/usr/bin/clang++', '-std=c++17', '-O2', '-Wall', '-Wextra',
             '-Wno-missing-field-initializers', '-I/usr/local/include', '-Ibuild',
             f'src/{name}.cpp', '-L/usr/local/lib', '-lvulkan',
             '-Wl,-rpath,/usr/local/lib', '-o', f'build/{name}'])

files = [ROOT / 'build.py', ROOT / 'run_gpu.py']
files += list((ROOT / 'src').glob('*.*')) + list((ROOT / 'shaders').glob('*'))
files += list(BUILD.glob('*.spv')) + [BUILD / 'gpu_probe', BUILD / 'array_probe']
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in files if p.is_file()}
(EVIDENCE / 'final-build-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
print('Build and compiler boundary checks passed. GPU workloads were not run.')
