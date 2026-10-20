#!/usr/bin/env python3
"""Bounded private AMD compiler tests. Never installs a driver or starts a game."""
import argparse, datetime, hashlib, json, os, pathlib, re, subprocess, time
root=pathlib.Path(__file__).resolve().parent
parser=argparse.ArgumentParser()
parser.add_argument('--run',action='store_true')
parser.add_argument('--label',required=True)
parser.add_argument('--suite',choices=['static','memory','vector','aggregate','graphics','bda','descriptors','typed64','typedvec','typedgraphics','geometry','vertexarray'],default='static')
parser.add_argument('--library',type=pathlib.Path)
parser.add_argument('--runtime-trace',action='store_true')
parser.add_argument('--gpu-timeout-trace',action='store_true')
parser.add_argument('--specialized-queues',action='store_true')
parser.add_argument('--fresh-mesh-libraries',action='store_true')
parser.add_argument('--safe-mesh-libraries',action='store_true')
parser.add_argument('--sync-mesh-libraries',action='store_true')
parser.add_argument('--sync-mesh-pipelines',action='store_true')
parser.add_argument('--replay-only',action='store_true')
parser.add_argument('--replay-failed-mesh',action='store_true')
parser.add_argument('--serialize-pipeline-link',action='store_true')
parser.add_argument('--coherent-atomics',action='store_true')
parser.add_argument('--encoder-live-cache',action='store_true')
parser.add_argument('--live-lookup-fast-cache',action='store_true')
parser.add_argument('--descriptor-use-cache',action='store_true')
parser.add_argument('--batch-live-use-resource',action='store_true')
parser.add_argument('--pipeline-cache',type=pathlib.Path)
parser.add_argument('--native-3d-attachments',action='store_true')
parser.add_argument('--binary-archive',type=pathlib.Path)
parser.add_argument('--render-binary-archive',type=pathlib.Path)
parser.add_argument('--mesh-binary-archive',type=pathlib.Path)
parser.add_argument('--binary-archive-flush-interval',type=int,default=64)
parser.add_argument('--binary-archive-trace',action='store_true')
parser.add_argument('--binary-archive-max-bytes',type=int)
parser.add_argument('--compute-archive-dir',type=pathlib.Path)
parser.add_argument('--compute-archive-require-hit',action='store_true')
parser.add_argument('--compute-archive-max-shard-bytes',type=int)
parser.add_argument('--compute-archive-max-total-bytes',type=int)
parser.add_argument('--render-archive-dir',type=pathlib.Path)
parser.add_argument('--render-archive-require-hit',action='store_true')
parser.add_argument('--graphics-blend',action='store_true')
parser.add_argument('--graphics-specialization-layout',choices=['a','b'])
args=parser.parse_args()
if not args.run or not re.fullmatch('[A-Za-z0-9_-]{1,64}',args.label):parser.error('Explicit --run and safe unique label required')
dest=root/'evidence'/args.label;dest.mkdir(exist_ok=False);(dest/'msl').mkdir()
lib=root/'build/moltenvk/MoltenVK/libMoltenVK.1.4.2.dylib'
if args.library:
    lib=args.library.resolve()
    if not lib.is_relative_to(root/'build') or not lib.is_file():raise SystemExit('Existing owned research library required')
if args.native_3d_attachments:
    build=json.loads((root/'evidence/pending-native-3d-attachment.json').read_text());lib=pathlib.Path(build['library'])
    assert hashlib.sha256(lib.read_bytes()).hexdigest()==build['librarySHA256']
icd=dest/'icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_','GPU_ADAPTER_','R2_'))}
env.update(PATH='/nonexistent',VK_ICD_FILENAMES=str(icd),MTL_DEBUG_LAYER='1',MVK_CONFIG_LOG_LEVEL='2',MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',MVK_AMD_REFERENCE_RBA2='1',MVK_AMD_REFERENCE_RIA2='1',MVK_AMD_REFERENCE_NULL='1',MVK_AMD_BYTE_GUARDS='1',MVK_CONFIG_SHADER_DUMP_DIR=str(dest/'msl'))
if args.runtime_trace:env['MVK_AMD_RUNTIME_TRACE']='1'
if args.gpu_timeout_trace:env['MVK_AMD_GPU_TIMEOUT_TRACE']='1'
if args.specialized_queues:env['MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES']='1'
if args.fresh_mesh_libraries:env['MVK_AMD_FRESH_MESH_LIBRARIES']='1'
if args.safe_mesh_libraries:
    if not args.fresh_mesh_libraries:parser.error('--safe-mesh-libraries requires fresh libraries')
    env['MVK_AMD_SAFE_MESH_LIBRARIES']='1'
if args.sync_mesh_libraries:
    if not args.safe_mesh_libraries:parser.error('--sync-mesh-libraries requires safe mesh libraries')
    env['MVK_AMD_SYNC_MESH_LIBRARIES']='1'
if args.sync_mesh_pipelines:env['MVK_AMD_SYNC_MESH_PIPELINES']='1'
if args.replay_only:
    if not args.runtime_trace or not args.replay_failed_mesh:parser.error('--replay-only requires runtime trace and mesh replay')
    env['MVK_AMD_RUNTIME_REPLAY_ONLY']='1'
if args.replay_failed_mesh:env['MVK_AMD_REPLAY_FAILED_MESH']='1'
if args.serialize_pipeline_link:env['MVK_AMD_SERIALIZE_PIPELINE_LINK']='1'
if args.coherent_atomics:env['MVK_AMD_COHERENT_ATOMICS']='1'
if args.encoder_live_cache:env['MVK_AMD_ENCODER_LIVE_CACHE']='1'
if args.descriptor_use_cache:env['MVK_AMD_DESCRIPTOR_USE_CACHE']='1'
if args.batch_live_use_resource:env['MVK_AMD_BATCH_LIVE_USE_RESOURCE']='1'
if args.live_lookup_fast_cache:
    if not args.encoder_live_cache:parser.error('--live-lookup-fast-cache requires --encoder-live-cache')
    env['MVK_AMD_LIVE_LOOKUP_FAST_CACHE']='1'
if args.pipeline_cache:
    cache=args.pipeline_cache.resolve()
    if not (cache.is_relative_to(root/'evidence') or cache.is_relative_to(root/'build')):raise SystemExit('Owned research cache path required')
    env['GPU_PIPELINE_CACHE_FILE']=str(cache)
if args.binary_archive:
    archive=args.binary_archive.resolve()
    if not (archive.is_relative_to(root/'evidence') or archive.is_relative_to(root/'build')):raise SystemExit('Owned research binary archive path required')
    if args.binary_archive_flush_interval < 1:raise SystemExit('Positive binary archive flush interval required')
    archive.parent.mkdir(parents=True,exist_ok=True)
    env['MVK_AMD_BINARY_ARCHIVE_PATH']=str(archive)
    env['MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL']=str(args.binary_archive_flush_interval)
for archive_arg, environment_name in ((args.render_binary_archive,'MVK_AMD_RENDER_BINARY_ARCHIVE_PATH'),
                                      (args.mesh_binary_archive,'MVK_AMD_MESH_BINARY_ARCHIVE_PATH')):
    if archive_arg:
        archive=archive_arg.resolve()
        if not (archive.is_relative_to(root/'evidence') or archive.is_relative_to(root/'build')):raise SystemExit('Owned research binary archive path required')
        if args.binary_archive_flush_interval < 1:raise SystemExit('Positive binary archive flush interval required')
        archive.parent.mkdir(parents=True,exist_ok=True)
        env[environment_name]=str(archive)
        env['MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL']=str(args.binary_archive_flush_interval)
if args.binary_archive_trace:env['MVK_AMD_BINARY_ARCHIVE_TRACE']='1'
if args.binary_archive_max_bytes is not None:
    if args.binary_archive_max_bytes < 1:parser.error('Positive binary archive byte limit required')
    env['MVK_AMD_BINARY_ARCHIVE_MAX_BYTES']=str(args.binary_archive_max_bytes)
if args.compute_archive_dir:
    directory=args.compute_archive_dir.resolve()
    if not (directory.is_relative_to(root/'evidence') or directory.is_relative_to(root/'build')):
        parser.error('Owned research compute archive directory required')
    directory.mkdir(parents=True,exist_ok=True)
    env['MVK_AMD_COMPUTE_ARCHIVE_DIR']=str(directory)
    env['MVK_AMD_COMPUTE_ARCHIVE_TRACE']='1'
    if args.compute_archive_require_hit:env['MVK_AMD_COMPUTE_ARCHIVE_REQUIRE_HIT']='1'
    for value,name in [(args.compute_archive_max_shard_bytes,'MVK_AMD_COMPUTE_ARCHIVE_MAX_SHARD_BYTES'),
                       (args.compute_archive_max_total_bytes,'MVK_AMD_COMPUTE_ARCHIVE_MAX_TOTAL_BYTES')]:
        if value is not None:
            if value<1:parser.error('Positive compute archive limit required')
            env[name]=str(value)
elif args.compute_archive_require_hit:
    parser.error('--compute-archive-require-hit requires --compute-archive-dir')
if args.render_archive_dir:
    directory=args.render_archive_dir.resolve()
    if not (directory.is_relative_to(root/'evidence') or directory.is_relative_to(root/'build')):
        parser.error('Owned research render archive directory required')
    directory.mkdir(parents=True,exist_ok=True)
    env['MVK_AMD_RENDER_ARCHIVE_DIR']=str(directory)
    env['MVK_AMD_RENDER_ARCHIVE_TRACE']='1'
    if args.render_archive_require_hit:env['MVK_AMD_RENDER_ARCHIVE_REQUIRE_HIT']='1'
elif args.render_archive_require_hit:
    parser.error('--render-archive-require-hit requires --render-archive-dir')
if args.graphics_blend:env['GPU_GRAPHICS_BLEND']='1'
if args.graphics_specialization_layout:env['GPU_GRAPHICS_SPEC_LAYOUT']=args.graphics_specialization_layout
reference=root.parent/'robustness2-reference-20261015'
if args.suite=='vertexarray':cmd=[root/'repro-geometry-interface-20261015/vertex_array_gpu',root/'repro-geometry-interface-20261015/array-shaders',dest/'output.json']
elif args.suite=='geometry':cmd=[root/'repro-geometry-interface-20261015/geometry_gpu',root/'repro-geometry-interface-20261015/shaders',dest/'output.json']
elif args.suite=='static':cmd=[root/'build/probes/static_cbv',root/'build/probes/static_cbv.spv',dest/'output.json']
elif args.suite=='vector':cmd=[reference/'build/vector_tail',reference/'build/spv',dest/'output.json']
elif args.suite=='memory':
    shader=root.parent/'robustness2-amd-20261014/build/memory-original.spv'
    cmd=[reference/'build/reference_memory',shader,shader,dest/'output.json']
elif args.suite=='graphics':
    shader='guard-cache-spec' if args.graphics_specialization_layout else 'guard'
    cmd=[root/'build/probes/graphics_probe',root/'build/probes'/f'{shader}.vert.spv',root/'build/probes'/f'{shader}.frag.spv',dest/'output.json']
elif args.suite=='bda':cmd=[root/'build/probes/bda_probe',root/'build/probes/bda.spv',dest/'output.json']
elif args.suite=='typed64':cmd=[root/'build/probes/bda_probe',root/'build/probes/typed-bda.spv',dest/'output.json']
elif args.suite=='typedvec':cmd=[root/'build/probes/bda_probe',root/'build/probes/typed-uvec2.spv',dest/'output.json']
elif args.suite=='typedgraphics':cmd=[root/'build/probes/graphics_typed_roots',root/'build/probes/typed.vert.spv',root/'build/probes/typed.frag.spv',dest/'output.json']
elif args.suite=='descriptors':
    cmd=[root/'build/probes/descriptor_probe',root/'build/probes/variable-array.spv',dest/'output.json'];env['R2_VARIABLE_COUNT']='3'
else:cmd=[reference/'build/reference_robust_access',reference/'build/spv']
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'librarySHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'command':[str(a)for a in cmd],'suite':args.suite,'gameStarted':False,'featureBitsModified':False,'privateCompilerOptionsOnly':True,'serializePipelineLink':args.serialize_pipeline_link,'coherentAtomics':args.coherent_atomics,'encoderLiveCache':args.encoder_live_cache}
record['specializedQueues']=args.specialized_queues
record['freshMeshLibraries']=args.fresh_mesh_libraries
record['safeMeshLibraries']=args.safe_mesh_libraries
record['syncMeshLibraries']=args.sync_mesh_libraries
record['syncMeshPipelines']=args.sync_mesh_pipelines
record['failedMeshReplayEnabled']=args.replay_failed_mesh
record['gpuTimeoutTrace']=args.gpu_timeout_trace
record['liveLookupFastCache']=args.live_lookup_fast_cache
record['descriptorUseCache']=args.descriptor_use_cache
record['batchLiveUseResource']=args.batch_live_use_resource
started=time.monotonic()
try:
    r=subprocess.run([str(a)for a in cmd],env=env,capture_output=True,text=True,timeout=50);record['exitCode']=r.returncode;out,err=r.stdout,r.stderr
except subprocess.TimeoutExpired as e:
    record['timeout']=True;out=e.stdout.decode(errors='replace') if isinstance(e.stdout,bytes) else e.stdout or '';err=e.stderr.decode(errors='replace') if isinstance(e.stderr,bytes) else e.stderr or ''
record['elapsedSeconds']=time.monotonic()-started
record['binaryArchive']=str(args.binary_archive.resolve()) if args.binary_archive else None
record['renderBinaryArchive']=str(args.render_binary_archive.resolve()) if args.render_binary_archive else None
record['meshBinaryArchive']=str(args.mesh_binary_archive.resolve()) if args.mesh_binary_archive else None
record['computeArchiveDirectory']=str(args.compute_archive_dir.resolve()) if args.compute_archive_dir else None
record['computeArchiveHitRequired']=args.compute_archive_require_hit
record['renderArchiveDirectory']=str(args.render_archive_dir.resolve()) if args.render_archive_dir else None
record['renderArchiveHitRequired']=args.render_archive_require_hit
record['graphicsBlendVariant']=args.graphics_blend
record['graphicsSpecializationLayout']=args.graphics_specialization_layout
(dest/'stdout.log').write_text(out);(dest/'stderr.log').write_text(err)
if (dest/'output.json').exists():record['results']=json.loads((dest/'output.json').read_text())
record['metalValidationEnabled']='Metal API Validation Enabled'in err
record['passed']=record.get('exitCode')==0 and (record.get('results',{}).get('passed',False) if args.suite!='aggregate' else 'GPU_RESULT_CHECKS_COMPLETE failures=0'in out)
(dest/'run.json').write_text(json.dumps(record,indent=2)+'\n');print(out[:4000]);print(err[:6000]);print('Full evidence:',dest)
raise SystemExit(0 if record['passed'] else 1)
