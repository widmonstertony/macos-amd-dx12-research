#!/usr/bin/env python3
"""Prepare owned mixed-dimensional Vulkan controls; GPU runs require --execute."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/eligible_2d_access_gpu.cpp'
SHADERS = ROOT / 'src/eligible_2d_access_shaders'
NAMES = ['fullscreen.vert', 'sample.frag', 'mixed.frag', 'fetch-query-negative.frag', 'fullscreen-mixed.vert']

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-library', required=True, type=Path)
    parser.add_argument('--library', type=Path, help='Integrated candidate; required with --execute')
    parser.add_argument('--validator-library', type=Path, help='Real optional SPIRV-Tools dylib; required with --execute')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--execute', action='store_true', help='Explicitly execute bounded owned GPU controls')
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() or not out.is_relative_to(ROOT / 'evidence') or not out.parent.is_dir():
        parser.error('output must be new below evidence, with an existing parent')
    if args.execute and not args.library: parser.error('--execute requires an integrated --library')
    if args.execute and not args.validator_library: parser.error('--execute requires an explicit --validator-library')
    out.mkdir(mode=0o700)
    commands, results = [], []
    sources = [SOURCE, Path(__file__).resolve(), *(SHADERS / name for name in NAMES)]
    inputs = [{'path': str(p), 'sha256': digest(p)} for p in sources]
    libs = {'baseline': args.baseline_library.resolve(), 'candidate': (args.library or args.baseline_library).resolve()}
    library_inputs = [{'path': str(p), 'sha256': digest(p)} for p in dict.fromkeys(libs.values())]
    validator = None
    if args.validator_library:
        original_validator = args.validator_library.resolve()
        library_inputs.append({'path': str(original_validator), 'sha256': digest(original_validator)})
        validator = out / 'owned-spirv-validator.dylib'; shutil.copy2(original_validator, validator)

    def command(label, argv, env=None, timeout=90):
        with (out / (label + '.stdout')).open('x') as stdout, (out / (label + '.stderr')).open('x') as stderr:
            result = subprocess.run([str(x) for x in argv], cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=timeout)
        commands.append({'label': label, 'argv': [str(x) for x in argv], 'exitCode': result.returncode})
        if result.returncode: raise RuntimeError(label + ': failed; inspect owned stderr')

    try:
        spirv = []
        for name in NAMES:
            source, binary = SHADERS / name, out / (name + '.spv')
            command(name + '-glsl', ['/usr/local/bin/glslangValidator', '-V', '--target-env', 'vulkan1.2', source, '-o', binary])
            command(name + '-validate', ['/usr/local/bin/spirv-val', '--target-env', 'vulkan1.2', binary])
            command(name + '-disassemble', ['/usr/local/bin/spirv-dis', binary, '-o', out / (name + '.spvasm')])
            spirv.append(binary)
        # CPU proof that the mixed shader still contains all required accesses.
        mixed = (out / 'mixed.frag.spvasm').read_text()
        negative = (out / 'fetch-query-negative.frag.spvasm').read_text()
        if not all(word in mixed for word in ['OpImageSampleExplicitLod', 'OpImageFetch', ' 2D ', ' 3D ', ' Buffer ']):
            raise RuntimeError('mixed fixture lost an authored image kind/access')
        if mixed.count('OpImageFetch') != 2 or negative.count('OpImageFetch') != 3 or 'OpImageQuerySizeLod' not in negative:
            raise RuntimeError('expected positive/negative fetch/query operations missing')
        builds = {}
        for label, library in libs.items():
            frozen = out / (label + '.dylib'); shutil.copy2(library, frozen)
            binary = out / label
            command(label + '-build', ['clang++', '-x', 'objective-c++', '-std=c++17', '-O2', '-fno-objc-arc',
                '-Wl,-headerpad_max_install_names', '-framework', 'Metal', '-framework', 'Foundation',
                '-I' + str(ROOT / 'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include'),
                SOURCE, '-x', 'none', frozen, '-o', binary])
            install_id = subprocess.check_output(['otool', '-D', str(frozen)], text=True).splitlines()[1].strip()
            command(label + '-relocate', ['install_name_tool', '-change', install_id, frozen, binary])
            command(label + '-sign', ['codesign', '--force', '--sign', '-', binary])
            builds[label] = (binary, frozen)

        def run(label, build, plans, workload, cache_in=None, cache_out=None, proof=True):
            binary, library = builds[build]
            folder = out / label; folder.mkdir(); msl = folder / 'msl'; msl.mkdir()
            arm = folder / 'forensics.arm'; arm.touch()
            env = {k: v for k, v in os.environ.items() if not k.startswith(('MVK_', 'MTL_', 'VK_', 'DYLD_', 'OWNED_'))}
            for key in ['ENCODER_LIVE_CACHE', 'CROSS_ENCODER_LIVE_CACHE', 'LIVE_LOOKUP_FAST_CACHE',
                'BATCH_LIVE_USE_RESOURCE', 'BATCH_ARGUMENT_HEAPS', 'ENCODER_HEAP_PLANS', 'DESCRIPTOR_USE_CACHE',
                'DESCRIPTOR_SNAPSHOT_REUSE', 'CROSS_ENCODER_SNAPSHOT_REUSE', 'SHARED_LIVE_SNAPSHOTS',
                'RESOURCE_USE_STATS', 'REGISTRATION_DELTA_CACHE']:
                env['MVK_AMD_' + key] = '1'
            env.update(MVK_AMD_SAMPLED_TEXTURE_HEAP_PLANS=str(int(plans)), MVK_AMD_ARGUMENT_HEAP_THRESHOLD='2',
                MVK_CONFIG_USE_MTLHEAP='2', MVK_CONFIG_SHADER_DUMP_DIR=str(msl), MVK_AMD_FORENSICS_ARM_PATH=str(arm),
                MVK_FIXTURE_EXPECTED_LIBRARY=str(library), MTL_DEBUG_LAYER='1', OWNED_ELIGIBLE_WORKLOAD=workload,
                MVK_AMD_ELIGIBLE_2D_READ_CONTRACT='1')
            if proof: env['MVK_AMD_SPIRV_VALIDATOR_LIBRARY'] = str(validator)
            argv = [binary, *spirv, folder / 'output.json']
            if cache_in: argv += ['--pipeline-cache-in', cache_in]
            if cache_out: argv += ['--pipeline-cache-out', cache_out]
            started = time.monotonic(); command(label, argv, env, timeout=60)
            row = json.loads((folder / 'output.json').read_text())
            records = []
            for path in msl.glob('forensics-*-*.jsonl'):
                for line in path.read_text().splitlines():
                    try: records.append(json.loads(line))
                    except ValueError: pass
            ends = [x.get('values', x.get('fields', x)) for x in records if x.get('kind') == 'resourceEncoderEnd']
            totals = {key: sum(int(x.get(key, 0)) for x in ends) for key in ['planAppliedChildren', 'planCoveredSkips', 'readResources', 'readCalls', 'heapObjects', 'heapCalls']}
            row.update(label=label, workload=workload, texturePlansEnabled=plans, optionalValidatorSelected=proof,
                elapsedSeconds=time.monotonic() - started,
                librarySHA256=digest(library), fixtureSourceSHA256=digest(SOURCE), binarySHA256=digest(binary),
                resourceTotals=totals, encoderEndRows=len(ends), forensicRecords=len(records), gameFPSClaimed=False)
            if not (row['passed'] and row['physical2DPropertiesChecked'] == 128 and row['actual3DTextureProven'] and row['actualBufferBackedTexelTextureProven']):
                raise RuntimeError(label + ': GPU output or physical-resource proof missing')
            if plans and proof and workload != 'negative' and not totals['planAppliedChildren']:
                raise RuntimeError(label + ': output passed without actual 2D texture plan application')
            if (workload == 'negative' or (plans and not proof)) and totals['planAppliedChildren']:
                raise RuntimeError(label + ': forbidden 2D fetch/query used a texture plan')
            if workload != 'sampler' and not totals['readResources']:
                raise RuntimeError(label + ': non2D precise-read declarations not observed')
            if cache_in and row.get('shaderStageCacheHits') != 8:
                raise RuntimeError(label + ': all eight owned pipeline shader-stage cache hits not proven')
            # Aggregate read counters establish precise work exists; exported
            # identities are preserved for an independent per-resource review.
            row['non2DIdentityPreservedForReview'] = True
            row['perResourcePreciseIdentityTraceProven'] = False
            (folder / 'qualified-output.json').write_text(json.dumps(row, indent=2) + '\n')
            results.append(row)

        if args.execute:
            cache = out / 'baseline-owned.pipeline-cache'
            run('baseline-seed', 'baseline', False, 'switch', cache_out=cache)
            cache_sha = digest(cache)
            run('candidate-disabled', 'candidate', False, 'switch')
            for workload in ['sampler', 'mixed', 'negative', 'stage', 'switch']:
                run('candidate-' + workload, 'candidate', True, workload)
            run('candidate-validator-unavailable', 'candidate', True, 'mixed', proof=False)
            run('candidate-mixed-old-cache', 'candidate', True, 'mixed', cache_in=cache)
            if digest(cache) != cache_sha: raise RuntimeError('owned baseline cache changed')
        for item in inputs + library_inputs:
            if digest(Path(item['path'])) != item['sha256']: raise RuntimeError('input changed during preparation/qualification')
        report = {'prepared': True, 'GPUExecuted': args.execute, 'GPUQualificationPassed': all(x['passed'] for x in results) if args.execute else None,
            'candidateProvided': bool(args.library), 'inputs': inputs, 'libraryInputs': library_inputs, 'commands': commands,
            'optionalValidatorFrozenSHA256': digest(validator) if validator else None,
            'results': results, 'existingNativeFilesModified': False, 'gameOperated': False, 'rawOutputUploaded': False,
            'separateBindingsFor2D3DBuffer': True, 'perResourcePreciseIdentityTraceProven': False,
            'scope': 'Preparation validates shaders and compiles/signs without running the executable. Explicit execution verifies owned GPU output, actual Metal texture properties, plan counters and old-cache behavior; aggregate read counters do not alone prove each non2D identity was declared precisely.'}
    except Exception as exc:
        report = {'prepared': False, 'error': str(exc), 'GPUExecuted': args.execute, 'results': results, 'inputs': inputs,
            'libraryInputs': library_inputs, 'commands': commands, 'gameOperated': False}
    (out / 'qualification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'prepared': report['prepared'], 'GPUExecuted': args.execute, 'error': report.get('error'), 'output': str(out)}, indent=2))
    return 0 if report['prepared'] else 1

if __name__ == '__main__': raise SystemExit(main())
