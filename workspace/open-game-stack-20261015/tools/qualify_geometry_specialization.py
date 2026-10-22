#!/usr/bin/env python3
"""Owned geometry/fragment-specialization GPU readback, with no mesh retry."""
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
    ap.add_argument('--library', type=Path, required=True)
    ap.add_argument('--label', required=True)
    ap.add_argument('--shaders', type=Path, required=True)
    ap.add_argument('--safe-math', action='store_true')
    ap.add_argument('--sync-mesh-libraries', action='store_true')
    ap.add_argument('--sync-mesh-pipelines', action='store_true')
    ap.add_argument('--mesh-link-differential', action='store_true')
    ap.add_argument('--parameter-readback', action='store_true')
    ap.add_argument('--probe-binary',type=Path,default=ROOT/'build/probes/geometry_specialization_gpu')
    args = ap.parse_args()
    lib, shaders = args.library.resolve(), args.shaders.resolve()
    assert lib.is_relative_to(ROOT / 'build') and lib.is_file()
    assert shaders.is_relative_to(ROOT) and shaders.is_dir()
    assert re.fullmatch(r'[A-Za-z0-9_-]{1,64}', args.label)
    out = ROOT / 'evidence' / args.label
    out.mkdir()
    (out / 'msl').mkdir()
    icd = out / 'icd.json'
    icd.write_text(json.dumps({'file_format_version': '1.0.0', 'ICD': {
        'library_path': str(lib), 'api_version': '1.4.0', 'is_portability_driver': True}}))
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('DYLD_', 'VK_', 'MVK_', 'MTL_', 'R2_'))}
    env.update(VK_ICD_FILENAMES=str(icd), MTL_DEBUG_LAYER='1', MVK_CONFIG_LOG_LEVEL='2',
               MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1', MVK_AMD_REFERENCE_RBA2='1',
               MVK_AMD_REFERENCE_RIA2='1', MVK_AMD_REFERENCE_NULL='1', MVK_AMD_BYTE_GUARDS='1',
               MVK_AMD_RUNTIME_TRACE='1', MVK_AMD_GPU_TIMEOUT_TRACE='1',
               MVK_CONFIG_SHADER_DUMP_DIR=str(out / 'msl'),
               MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES='1', MVK_AMD_FRESH_MESH_LIBRARIES='1',
               MVK_AMD_SERIALIZE_PIPELINE_LINK='1')
    if args.safe_math:
        env['MVK_AMD_SAFE_MESH_LIBRARIES'] = '1'
    if args.sync_mesh_libraries:
        assert args.safe_math, 'Synchronous mesh control requires conservative mesh mode'
        env['MVK_AMD_SYNC_MESH_LIBRARIES'] = '1'
    if args.sync_mesh_pipelines:
        env['MVK_AMD_SYNC_MESH_PIPELINES'] = '1'
    if args.mesh_link_differential:
        env['MVK_AMD_LINK_DIFFERENTIAL_CAPTURE'] = '1'
    if args.parameter_readback:
        env['MVK_OWNED_GEOMETRY_PARAMETER_READBACK'] = '1'
    probe=args.probe_binary.resolve()
    assert probe.is_relative_to(ROOT/'build/probes') and probe.is_file()
    command = [str(probe), str(shaders), str(out / 'output.json')]
    start = time.monotonic()
    p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=35)
    (out / 'stdout.log').write_text(p.stdout)
    (out / 'stderr.log').write_text(p.stderr)
    result = json.loads((out / 'output.json').read_text()) if (out / 'output.json').exists() else {}
    row = {'command': command, 'exitCode': p.returncode, 'elapsedSeconds': time.monotonic() - start,
           'candidateSHA256': hashlib.sha256(lib.read_bytes()).hexdigest(), 'result': result,
           'failedMeshReplayEnabled': False, 'freshMeshLibraries': True, 'safeMeshLibraries': args.safe_math, 'syncMeshLibraries': args.sync_mesh_libraries, 'syncMeshPipelines': args.sync_mesh_pipelines, 'meshLinkDifferential': args.mesh_link_differential,
           'metalValidationEnabled': 'Metal API Validation Enabled' in p.stderr}
    row['passed'] = p.returncode == 0 and result.get('passed', False)
    row['parameterReadback'] = args.parameter_readback
    (out / 'run.json').write_text(json.dumps(row, indent=2) + '\n')
    print(json.dumps(row))
    return 0 if row['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
