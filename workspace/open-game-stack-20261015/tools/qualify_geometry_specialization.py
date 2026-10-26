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
    ap.add_argument('--shared-live-snapshots',action='store_true')
    ap.add_argument('--encoder-heap-plans',action='store_true',help='Exercise the existing buffer read-plan/precise write backend')
    ap.add_argument('--sampled-texture-heap-plans',action='store_true')
    ap.add_argument('--safe-math', action='store_true')
    ap.add_argument('--normal-mesh-libraries', action='store_true')
    ap.add_argument('--sharded-shader-cache-locks', action='store_true')
    ap.add_argument('--sync-mesh-libraries', action='store_true')
    ap.add_argument('--sync-mesh-pipelines', action='store_true')
    ap.add_argument('--mesh-link-differential', action='store_true')
    ap.add_argument('--parameter-readback', action='store_true')
    ap.add_argument('--geometry-draw-trace-label',
                    help='Timed metadata-only geometry draw trace selector; use * for owned probes')
    ap.add_argument('--gpu-counter-all-draws', action='store_true',
                    help='Capture bounded GPU timestamps for all draws and internal geometry batches')
    ap.add_argument('--gpu-counter-pipeline-label',
                    help='Lazily begin timestamps at this pipeline substring; targeted mode uses 4096 slots')
    ap.add_argument('--dump-function-substrings',
                    help='Comma-separated generated Metal entry-point substrings to copy for source inspection')
    ap.add_argument('--geometry-command-buffer-batch-limit', type=int,
                    help='Opt-in AMD geometry batch count before a native command-buffer split')
    ap.add_argument('--split-stress', action='store_true',
                    help='Use the owned 8192-primitive indexed geometry draw')
    ap.add_argument('--dump-work-records', action='store_true',
                    help='Verify CPU work metadata on completed owned-probe submissions')
    ap.add_argument('--stutter-coverage',action='store_true',help='Qualify opt-in CPU/native provenance on the owned GPU workload')
    ap.add_argument('--gpu-counter-burst',action='store_true',help='Bounded multi-CB/all-queue counter qualification')
    ap.add_argument('--gpu-counter-burst-max-cbs',type=int,help='Owned-control cap used to close a short session for clock validation')
    ap.add_argument('--probe-binary',type=Path,default=ROOT/'build/probes/geometry_specialization_gpu')
    ap.add_argument('--full-forensics',action='store_true',help='Qualify bounded native causal logs on owned GPU output')
    args = ap.parse_args()
    if args.gpu_counter_burst and not args.gpu_counter_all_draws:ap.error('--gpu-counter-burst requires --gpu-counter-all-draws')
    if args.gpu_counter_burst_max_cbs is not None and (not args.gpu_counter_burst or not 1<=args.gpu_counter_burst_max_cbs<=512):ap.error('Bounded burst cap requires burst mode and 1..512')
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
    if args.normal_mesh_libraries:
        env.pop('MVK_AMD_FRESH_MESH_LIBRARIES', None)
    if args.sharded_shader_cache_locks:
        env['MVK_AMD_SHARDED_SHADER_CACHE_LOCKS'] = '1'
    env['MVK_AMD_ENCODER_HEAP_PLANS'] = '1' if args.encoder_heap_plans else '0'
    if args.sampled_texture_heap_plans:
        if not args.encoder_heap_plans:ap.error('Sampled texture plans require encoder heap plans')
        env['MVK_AMD_SAMPLED_TEXTURE_HEAP_PLANS']='1'
    if args.shared_live_snapshots:
        env.update(MVK_AMD_SHARED_LIVE_SNAPSHOTS="1",MVK_AMD_ENCODER_LIVE_CACHE="1",MVK_AMD_CROSS_ENCODER_LIVE_CACHE="1",MVK_AMD_DESCRIPTOR_SNAPSHOT_REUSE="1",MVK_AMD_CROSS_ENCODER_SNAPSHOT_REUSE="1",MVK_AMD_BATCH_LIVE_USE_RESOURCE="1")
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
    if args.stutter_coverage:
        env.update(MVK_AMD_STUTTER_COVERAGE='1',MVK_AMD_STUTTER_DETAIL='1')
        arm=out/'gpu-counter.arm';arm.touch();env['MVK_AMD_STUTTER_ARM_PATH']=str(arm)
    if args.full_forensics:
        marker=out/'forensics.arm';marker.touch();env.update(MVK_AMD_FORENSICS_ARM_PATH=str(marker),MVK_AMD_CPU_FINE_SAMPLE_EVERY='64')
    if args.gpu_counter_burst:env['MVK_AMD_GPU_COUNTER_BURST']='1'
    if args.gpu_counter_burst_max_cbs is not None:env['MVK_AMD_GPU_COUNTER_BURST_MAX_CBS']=str(args.gpu_counter_burst_max_cbs)
    if args.geometry_draw_trace_label or args.gpu_counter_all_draws:
        arm = out / 'gpu-counter.arm'
        arm.touch()
        env['MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH'] = str(arm)
    if args.geometry_draw_trace_label:
        assert len(args.geometry_draw_trace_label) <= 128
        env['MVK_AMD_GEOMETRY_DRAW_TRACE_LABEL'] = args.geometry_draw_trace_label
    if args.gpu_counter_all_draws:
        env['MVK_AMD_GPU_COUNTER_PIPELINE_LABEL'] = args.gpu_counter_pipeline_label or '*'
        env['MVK_AMD_GPU_COUNTER_ALL_DRAWS'] = '1'
    if args.dump_function_substrings:
        assert len(args.dump_function_substrings) <= 384
        assert re.fullmatch(r'[A-Za-z0-9_,.-]+', args.dump_function_substrings)
        env['MVK_AMD_DUMP_FUNCTION_SUBSTRINGS'] = args.dump_function_substrings
    if args.geometry_command_buffer_batch_limit is not None:
        assert 1 <= args.geometry_command_buffer_batch_limit <= 1024
        env['MVK_AMD_GEOMETRY_COMMAND_BUFFER_BATCH_LIMIT'] = str(args.geometry_command_buffer_batch_limit)
    if args.split_stress:
        assert args.geometry_command_buffer_batch_limit is not None
        env['MVK_OWNED_GEOMETRY_SPLIT_STRESS'] = '1'
    if args.dump_work_records:
        env['MVK_AMD_QUEUE_DEPENDENCY_DUMP_ALL'] = '1'
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
           'failedMeshReplayEnabled': False, 'freshMeshLibraries': not args.normal_mesh_libraries, 'safeMeshLibraries': args.safe_math, 'syncMeshLibraries': args.sync_mesh_libraries, 'syncMeshPipelines': args.sync_mesh_pipelines, 'meshLinkDifferential': args.mesh_link_differential,
           'metalValidationEnabled': 'Metal API Validation Enabled' in p.stderr}
    row['shardedShaderCacheLocks'] = args.sharded_shader_cache_locks
    row['passed'] = p.returncode == 0 and result.get('passed', False)
    row['parameterReadback'] = args.parameter_readback
    row['geometryDrawTraceLabel'] = args.geometry_draw_trace_label
    geometry_traces = sorted((out / 'msl').glob('trace-geometry-draw-*.json'))
    row['geometryDrawTraceFiles'] = [str(p.relative_to(ROOT)) for p in geometry_traces]
    if args.geometry_draw_trace_label:
        row['geometryDrawTracePassed'] = bool(geometry_traces)
        row['passed'] = row['passed'] and row['geometryDrawTracePassed']
    row['sharedLiveSnapshots'] = args.shared_live_snapshots
    row['encoderHeapPlans'] = args.encoder_heap_plans
    gpu_timestamp_traces = sorted((out / 'msl').glob('trace-gpu-timestamps-*.json'))
    row['gpuCounterAllDraws'] = args.gpu_counter_all_draws
    row['gpuCounterPipelineLabel'] = args.gpu_counter_pipeline_label or ('*' if args.gpu_counter_all_draws else None)
    row['dumpFunctionSubstrings'] = args.dump_function_substrings
    row['geometryCommandBufferBatchLimit'] = args.geometry_command_buffer_batch_limit
    row['dumpWorkRecords'] = args.dump_work_records
    if args.dump_work_records:
        records = [json.loads(path.read_text()) for path in (out / 'msl').glob('trace-queue-dependencies-*.json')]
        kinds = {event['kind'] for record in records for event in record.get('workEvents', [])}
        row['workRecordKinds'] = sorted(kinds)
        row['geometryGridMetadataVerified'] = 'geometry-grid' in kinds
        row['geometrySplitMetadataVerified'] = 'geometry-cb-split' in kinds
        row['passed'] = row['passed'] and row['geometryGridMetadataVerified']
        if args.split_stress:
            row['passed'] = row['passed'] and row['geometrySplitMetadataVerified']
    row['splitStressRequested'] = args.split_stress
    row['splitStressPassed'] = (not args.split_stress or
                                (result.get('splitStress') is True and result.get('stressPrimitives') == 8192))
    row['passed'] = row['passed'] and row['splitStressPassed']
    row['selectedFunctionSources'] = [str(p.relative_to(ROOT)) for p in sorted((out / 'msl').glob('selected-source-*.metal'))]
    if args.dump_function_substrings:
        row['selectedFunctionSourcePassed'] = bool(row['selectedFunctionSources'])
        row['passed'] = row['passed'] and row['selectedFunctionSourcePassed']
    row['gpuTimestampTraceFiles'] = [str(p.relative_to(ROOT)) for p in gpu_timestamp_traces]
    if args.gpu_counter_all_draws:
        timestamp_records = [json.loads(p.read_text()) for p in gpu_timestamp_traces]
        samples = [sample for record in timestamp_records for sample in record.get('gpuTimestamps', {}).get('samples', [])]
        row['geometryBatchTimestampCount'] = sum(sample.get('kind') == 'geometry-batch' for sample in samples)
        row['gpuCounterAllDrawsPassed'] = bool(gpu_timestamp_traces) and row['geometryBatchTimestampCount'] > 0
        row['passed'] = row['passed'] and row['gpuCounterAllDrawsPassed']
    row['stutterCoverageRequested']=args.stutter_coverage
    row['gpuCounterBurstRequested']=args.gpu_counter_burst
    row['gpuCounterBurstMaxCBs']=args.gpu_counter_burst_max_cbs
    row['GPUClockSidecars']=[str(p.relative_to(ROOT)) for p in (out/'msl').glob('gpu-counter-clock-sessions-*.jsonl')]
    if args.stutter_coverage:
        native_rows=[]
        for path in (out/'msl').glob('stutter-native-*.jsonl'):
            native_rows.extend(json.loads(line) for line in path.read_text().splitlines() if line.strip())
        cpu_paths=sorted((out/'msl').glob('cpu-stutter-current-*.json'))
        completed=[r for r in native_rows if r.get('type')=='nativeCB' and r.get('phase')=='completed']
        row['nativeProvenanceRows']=len(native_rows)
        row['nativeCompletedWithLogicalID']=sum(r.get('logicalSubmit',0)>0 and r.get('committedCA',0)>0 for r in completed)
        row['CPUReports']=[str(p.relative_to(ROOT)) for p in cpu_paths]
        row['stutterIntegrationPassed']=bool(completed) and row['nativeCompletedWithLogicalID']==len(completed) and bool(cpu_paths)
        row['passed']=row['passed'] and row['stutterIntegrationPassed']
    (out / 'run.json').write_text(json.dumps(row, indent=2) + '\n')
    print(json.dumps(row))
    return 0 if row['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
