#!/usr/bin/env python3
"""Stage owned MoltenVK and unchanged asset-guard proxies; never deploy or launch."""
import argparse,datetime,hashlib,json,pathlib,re,shutil,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--resource-stats',action='store_true');p.add_argument('--shared-live-snapshots',action='store_true');p.add_argument('--snapshot-reuse',action='store_true');p.add_argument('--negative-cache',action='store_true');p.add_argument('--cross-snapshot-reuse',action='store_true');p.add_argument('--failure-context',action='store_true');p.add_argument('--registration-delta-cache',action='store_true');p.add_argument('--split-command-buffers',action='store_true',help='Commit between Vulkan command buffers inside one queue submission');p.add_argument('--geometry-command-buffer-batch-limit',type=int,help='Commit and resume a direct geometry draw after this many native mesh batches');p.add_argument('--armed-work-trace',action='store_true');p.add_argument('--continuous-work-trace',action='store_true');p.add_argument('--slow-command-buffer-trace-ms',type=float,help='Dump a bounded completed-command-buffer work record when GPU time meets this threshold');p.add_argument('--gpu-counters',action='store_true',help='Enable only timed, bounded native GPU counter diagnostics');p.add_argument('--gpu-counter-pipeline-label',help='Pipeline-label substring that lazily starts command-buffer GPU timestamps');p.add_argument('--gpu-counter-all-draws',action='store_true',help='Sample every draw boundary in the one lazily selected command buffer');p.add_argument('--geometry-draw-trace-label',help='Geometry pipeline-label substring captured only while timed GPU counters are armed');p.add_argument('--dump-function-substrings',help='Comma-separated generated Metal entry-point substrings whose already-used MSL source is recorded');p.add_argument('--geometry-index-capture-element',type=int,help='First selected indexed-geometry element copied by a one-shot GPU diagnostic');p.add_argument('--geometry-index-capture-count',type=int,help='Number of selected indexed-geometry elements copied by a one-shot GPU diagnostic');p.add_argument('--suppress-archive-trace',action='store_true',help='Keep archive reuse enabled but omit one JSON file per pipeline during focused GPU diagnosis');p.add_argument('--normal-mesh-libraries',action='store_true',help='Use cached shader-module libraries after the unique Metal entry-point fix; disable the old per-pipeline fresh-library diagnostic');p.add_argument('--sharded-shader-cache-locks',action='store_true',help='Protect only the pipeline-cache map globally and serialize compilation per shader module');p.add_argument('--descriptor-write-shards',action='store_true',help='Hold address-striped descriptor locks across writes instead of one per-set lock');p.add_argument('--suppress-link-differential',action='store_true',help='Disable the bounded mesh-link differential trace after its root cause has been verified');a=p.parse_args()
if a.gpu_counters and not a.failure_context:p.error('Timed GPU counters require bounded failure context')
if a.gpu_counter_pipeline_label and not a.gpu_counters:p.error('GPU counter pipeline selection requires timed GPU counters')
if a.gpu_counter_all_draws and (not a.gpu_counters or not a.gpu_counter_pipeline_label):p.error('All-draw GPU counters require timed counters and a lazy pipeline selector')
if a.geometry_draw_trace_label and not a.gpu_counters:p.error('Geometry draw tracing requires timed GPU counters')
if (a.geometry_index_capture_element is None) != (a.geometry_index_capture_count is None):p.error('Geometry index capture requires both element and count')
if a.geometry_index_capture_element is not None and (not a.gpu_counters or not a.gpu_counter_pipeline_label):p.error('Geometry index capture requires timed counters and a pipeline selector')
if a.geometry_index_capture_element is not None and (a.geometry_index_capture_element < 0 or not 1 <= a.geometry_index_capture_count <= 65536):p.error('Unsafe geometry index capture range')
if a.geometry_command_buffer_batch_limit is not None and not 1 <= a.geometry_command_buffer_batch_limit <= 1024:p.error('Geometry command-buffer batch limit must be 1..1024')
if a.continuous_work_trace and (a.armed_work_trace or not a.failure_context):p.error('Continuous bounded work history requires failure context and excludes timed arming')
if a.slow_command_buffer_trace_ms is not None and (not a.continuous_work_trace or not 1 <= a.slow_command_buffer_trace_ms <= 60000):p.error('Slow command-buffer trace requires continuous work trace and a 1..60000 ms threshold')
if not re.fullmatch('[a-z0-9-]{1,64}',a.label):p.error('Safe label required')
evidence=ROOT/'evidence'/a.label;evidence.mkdir(exist_ok=False);(evidence/'msl').mkdir()
template=ROOT/'evidence/effective-submission-profile-20261020/game-trial-config.h'
config=template.read_text().replace(str(template.parent),str(evidence))
# The game is normally requested through a second Steam.exe process, which can
# hand the launch to an already-running client. Keep this correctness switch in
# the game-loaded proxy configuration too instead of relying only on the parent
# Steam process environment.
config=config.replace('    setenv("MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES"',
                      '    setenv("MVK_AMD_CPU_GATE_UNSIGNALED_TIMELINE_WAITS", "1", 1);\n'
                      '    setenv("MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES"')
if a.suppress_archive_trace:
 config=config.replace('setenv("MVK_AMD_RENDER_ARCHIVE_TRACE", "1", 1);','unsetenv("MVK_AMD_RENDER_ARCHIVE_TRACE");')
 config=config.replace('setenv("MVK_AMD_COMPUTE_ARCHIVE_TRACE", "1", 1);','unsetenv("MVK_AMD_COMPUTE_ARCHIVE_TRACE");')
if a.normal_mesh_libraries:
 for name in ('MVK_AMD_FRESH_MESH_LIBRARIES','MVK_AMD_SAFE_MESH_LIBRARIES','MVK_AMD_SYNC_MESH_LIBRARIES'):
  config=config.replace(f'setenv("{name}", "1", 1);',f'unsetenv("{name}");')
if a.suppress_link_differential:
 config=config.replace('setenv("MVK_AMD_LINK_DIFFERENTIAL_CAPTURE", "1", 1);','unsetenv("MVK_AMD_LINK_DIFFERENTIAL_CAPTURE");')
if a.shared_live_snapshots and not a.cross_snapshot_reuse:p.error('Shared snapshots require retained snapshot reuse')
if a.cross_snapshot_reuse and not a.snapshot_reuse:p.error('Cross-encoder snapshot reuse requires snapshot reuse')
if a.registration_delta_cache and not a.cross_snapshot_reuse:p.error('Registration delta cache requires cross snapshot reuse')
for name,value in [('MVK_AMD_SHARED_LIVE_SNAPSHOTS',a.shared_live_snapshots),('MVK_AMD_REGISTRATION_DELTA_CACHE',a.registration_delta_cache),('MVK_AMD_QUEUE_FAILURE_CONTEXT',a.failure_context),('MVK_AMD_RESOURCE_USE_STATS',a.resource_stats),('MVK_AMD_DESCRIPTOR_SNAPSHOT_REUSE',a.snapshot_reuse),('MVK_AMD_NEGATIVE_LIVE_CACHE',a.negative_cache),('MVK_AMD_CROSS_ENCODER_SNAPSHOT_REUSE',a.cross_snapshot_reuse),('MVK_AMD_SPLIT_VULKAN_COMMAND_BUFFERS',a.split_command_buffers),('MVK_AMD_SHARDED_SHADER_CACHE_LOCKS',a.sharded_shader_cache_locks),('MVK_AMD_DESCRIPTOR_WRITE_SHARDS',a.descriptor_write_shards)]:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("{name}", "{int(value)}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.armed_work_trace:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_GPU_WORK_TRACE_ARM_PATH", "{evidence}/gpu-work-trace.arm", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.gpu_counters:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH", "{evidence}/gpu-counter.arm", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.gpu_counter_pipeline_label:
 if len(a.gpu_counter_pipeline_label)>128 or '"' in a.gpu_counter_pipeline_label or '\\' in a.gpu_counter_pipeline_label:p.error('Unsafe GPU counter pipeline label')
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_GPU_COUNTER_PIPELINE_LABEL", "{a.gpu_counter_pipeline_label}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.gpu_counter_all_draws:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"','    setenv("MVK_AMD_GPU_COUNTER_ALL_DRAWS", "1", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.geometry_draw_trace_label:
 if len(a.geometry_draw_trace_label)>128 or '"' in a.geometry_draw_trace_label or '\\' in a.geometry_draw_trace_label:p.error('Unsafe geometry trace label')
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_GEOMETRY_DRAW_TRACE_LABEL", "{a.geometry_draw_trace_label}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.dump_function_substrings:
 if len(a.dump_function_substrings)>384 or not re.fullmatch('[a-zA-Z0-9_,.-]+',a.dump_function_substrings):p.error('Unsafe function-source selector')
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_DUMP_FUNCTION_SUBSTRINGS", "{a.dump_function_substrings}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.geometry_index_capture_element is not None:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_GEOMETRY_INDEX_CAPTURE_ELEMENT", "{a.geometry_index_capture_element}", 1);\n    setenv("MVK_AMD_GEOMETRY_INDEX_CAPTURE_COUNT", "{a.geometry_index_capture_count}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
if a.geometry_command_buffer_batch_limit is not None:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_GEOMETRY_COMMAND_BUFFER_BATCH_LIMIT", "{a.geometry_command_buffer_batch_limit}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
header=evidence/'game-trial-config.h';header.write_text(config)
if a.continuous_work_trace:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"','    setenv("MVK_AMD_GPU_TIMEOUT_TRACE", "1", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
 header.write_text(config)
if a.slow_command_buffer_trace_ms is not None:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("MVK_AMD_SLOW_COMMAND_BUFFER_TRACE_MS", "{a.slow_command_buffer_trace_ms:g}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
 header.write_text(config)
built=ROOT/'build/moltenvk-bounded-archive/MoltenVK/libMoltenVK.1.4.2.dylib'
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
records=[]
for kind in ['probe','game']:
 folder=ROOT/'build'/f'{a.label}-{kind}';folder.mkdir(exist_ok=False)
 candidate=folder/'libCandidate.dylib';shutil.copy2(built,candidate)
 proxy=folder/'libProbeGuard.dylib'
 cmd=['clang','-dynamiclib','-O2','-Wl,-headerpad_max_install_names',str(ROOT/'src/mvk_guard_proxy.c'),f'-DMVK_GUARD_CANDIDATE_PATH="{candidate}"','-Wl,-reexport_library,'+str(candidate),'-o',str(proxy)]
 if kind=='game':cmd.append(f'-DMVK_GUARD_GAME_CONFIG_HEADER="{header}"')
 subprocess.run(cmd,check=True)
 subprocess.run(['install_name_tool','-change','@rpath/libMoltenVK.1.dylib',str(candidate),str(proxy)],check=True)
 subprocess.run(['codesign','--force','--sign','-',str(proxy)],check=True)
 if kind=='probe':
  select=folder/'select';select.mkdir()
  for name in ('libMoltenVK.dylib','libMoltenVK.1.dylib','libMoltenVK.1.4.2.dylib'):
   (select/name).symlink_to(proxy)
 record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'candidate':str(candidate),'candidateSHA256':sha(candidate),'proxy':str(proxy),'proxySHA256':sha(proxy),'profileHeader':str(header) if kind=='game' else None,'resourceStatistics':a.resource_stats,'snapshotReuse':a.snapshot_reuse,'negativeCache':a.negative_cache,'crossEncoderSnapshotReuse':a.cross_snapshot_reuse,'failureContext':a.failure_context,'registrationDeltaCache':a.registration_delta_cache,'armedWorkTrace':a.armed_work_trace,'workCaptureMaximumSeconds':30 if a.armed_work_trace else None,'deployed':False}
 record['sharedLiveSnapshots']=a.shared_live_snapshots
 record['splitVulkanCommandBuffers']=a.split_command_buffers
 record['continuousBoundedWorkTrace']=a.continuous_work_trace
 record['slowCommandBufferTraceMilliseconds']=a.slow_command_buffer_trace_ms
 record['timedGPUCounters']=a.gpu_counters
 record['gpuCounterPipelineLabel']=a.gpu_counter_pipeline_label
 record['gpuCounterAllDraws']=a.gpu_counter_all_draws
 record['geometryDrawTraceLabel']=a.geometry_draw_trace_label
 record['dumpFunctionSubstrings']=a.dump_function_substrings
 record['geometryIndexCaptureElement']=a.geometry_index_capture_element
 record['geometryIndexCaptureCount']=a.geometry_index_capture_count
 record['geometryCommandBufferBatchLimit']=a.geometry_command_buffer_batch_limit
 record['archiveTraceSuppressed']=a.suppress_archive_trace
 record['normalMeshLibraries']=a.normal_mesh_libraries
 record['shardedShaderCacheLocks']=a.sharded_shader_cache_locks
 record['descriptorWriteShards']=a.descriptor_write_shards
 record['linkDifferentialSuppressed']=a.suppress_link_differential
 (folder/'build.json').write_text(json.dumps(record,indent=2)+'\n');records.append(record)
(evidence/'build.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(records,indent=2))
