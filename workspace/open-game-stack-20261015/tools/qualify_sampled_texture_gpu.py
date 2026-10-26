#!/usr/bin/env python3
"""Bounded owned Vulkan output/cache controls; never operate the game or prefix."""
import argparse, hashlib, json, os, shutil, subprocess, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--library', type=Path, required=True)
ap.add_argument('--baseline-library', type=Path, required=True)
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--rehydrate-archives', action='store_true',
                help='Exercise actual render archive hits and detached PSO creation on owned output')
args = ap.parse_args()
out = args.output.resolve()
assert out.is_relative_to(ROOT/'evidence') and not out.exists()
out.mkdir()
if args.rehydrate_archives: (out/'owned-render-archives').mkdir()
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def command(argv, label, env=None, timeout=90):
    with (out/(label+'.stdout')).open('x') as so, (out/(label+'.stderr')).open('x') as se:
        result = subprocess.run([str(x) for x in argv], env=env, stdout=so, stderr=se, timeout=timeout)
    if result.returncode: raise RuntimeError(f'{label}: exit {result.returncode}; see owned stderr')

def build(lib, label):
    frozen = out/(label+'.dylib'); shutil.copy2(lib, frozen)
    binary = out/label
    command(['clang++','-x','objective-c++','-std=c++17','-O2','-Wl,-headerpad_max_install_names','-framework','Metal','-framework','Foundation',
        '-I'+str(ROOT/'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include'),
        ROOT/'src/sample_texture_plan_gpu.cpp', '-x','none', frozen, '-o', binary], label+'-build')
    install_id = subprocess.check_output(['otool','-D',str(frozen)],text=True).splitlines()[1].strip()
    command(['install_name_tool','-change',install_id,frozen,binary],label+'-relocate')
    command(['codesign','--force','--sign','-',binary],label+'-sign')
    return binary, frozen

shaders = []
for name in ['fullscreen.vert','sample.frag','fetch.frag','fullscreen-sampled.vert']:
    src = ROOT/'src/sample_texture_plan_shaders'/name
    dst = out/(name+'.spv')
    command(['glslangValidator','-V','--target-env','vulkan1.2',src,'-o',dst],name+'-glsl')
    command(['spirv-val','--target-env','vulkan1.2',dst],name+'-validate')
    shaders.append(dst)
baseline, oldlib = build(args.baseline_library.resolve(), 'baseline')
candidate, newlib = build(args.library.resolve(), 'candidate')
results = []
cache = out/'v36-owned.pipeline-cache'
def run(label, binary, lib, sampled, cache_in=None, cache_out=None, sample_only=False):
    folder=out/label;folder.mkdir();msl=folder/'msl';msl.mkdir()
    arm=folder/'forensics.arm';arm.touch()
    env={k:v for k,v in os.environ.items() if not k.startswith(('MVK_','MTL_','VK_','DYLD_'))}
    for key in ['ENCODER_LIVE_CACHE','CROSS_ENCODER_LIVE_CACHE','LIVE_LOOKUP_FAST_CACHE',
                'BATCH_LIVE_USE_RESOURCE','BATCH_ARGUMENT_HEAPS','ENCODER_HEAP_PLANS',
                'DESCRIPTOR_USE_CACHE','DESCRIPTOR_SNAPSHOT_REUSE','CROSS_ENCODER_SNAPSHOT_REUSE',
                'SHARED_LIVE_SNAPSHOTS','RESOURCE_USE_STATS','REGISTRATION_DELTA_CACHE']:
        env['MVK_AMD_'+key]='1'
    env.update(MVK_AMD_SAMPLED_TEXTURE_HEAP_PLANS=str(int(sampled)),
               MVK_AMD_ARGUMENT_HEAP_THRESHOLD='2', MVK_CONFIG_USE_MTLHEAP='2',
               MVK_CONFIG_SHADER_DUMP_DIR=str(msl),
               MVK_AMD_FORENSICS_ARM_PATH=str(arm), MVK_FIXTURE_EXPECTED_LIBRARY=str(lib),
               MTL_DEBUG_LAYER='1')
    if sample_only: env['OWNED_FIXTURE_SAMPLE_ONLY']='1'
    if args.rehydrate_archives:
        env.update(MVK_AMD_RENDER_ARCHIVE_DIR=str(out/'owned-render-archives'),
                   MVK_AMD_RENDER_ARCHIVE_REHYDRATE='1')
    argv=[binary,*shaders,folder/'output.json']
    if cache_in: argv += ['--pipeline-cache-in',cache_in]
    if cache_out: argv += ['--pipeline-cache-out',cache_out]
    start=time.monotonic();command(argv,label,env=env,timeout=60)
    row=json.loads((folder/'output.json').read_text())
    row['stageUpgradeReplayExercised']=not sample_only
    records=[]
    for path in msl.glob('forensics-*-*.jsonl'):
        for line in path.read_text().splitlines():
            try: records.append(json.loads(line))
            except ValueError: pass
    ends=[x for x in records if x.get('kind')=='resourceEncoderEnd']
    values=[x.get('values',x.get('fields',x)) for x in ends]
    totals={key:sum(int(x.get(key,0)) for x in values) for key in
            ['planAppliedChildren','planCoveredSkips','readResources','readCalls','heapObjects','heapCalls']}
    row.update(label=label,elapsedSeconds=time.monotonic()-start,librarySHA256=digest(lib),
               fixtureSourceSHA256=digest(ROOT/'src/sample_texture_plan_gpu.cpp'),binarySHA256=digest(binary),
               forensicRecords=len(records),encoderEndRows=len(ends),resourceTotals=totals,
               gameOperated=False,gameFPSClaimed=False)
    if args.rehydrate_archives:
        row['strictRenderArchiveHits']=sum(x.get('kind')=='render-archive-native' and
            x.get('fields',x).get('phase')==1 and x.get('fields',x).get('outcome')==1 for x in records)
        row['successfulDetachedRehydrations']=sum(x.get('kind')=='archive-rehydrate' and
            x.get('fields',x).get('phase')==1 and x.get('fields',x).get('outcome')==1 for x in records)
        if label != 'v36-cache-seed' and not (
            row['strictRenderArchiveHits'] and row['successfulDetachedRehydrations']):
            raise RuntimeError(label+': GPU output passed but archive hit/detached recreation not proven')
    (folder/'qualified-output.json').write_text(json.dumps(row,indent=2)+'\n')
    results.append(row)
    if sampled and not totals['planAppliedChildren']:
        raise RuntimeError(label+': output passed but no actual texture heap-plan application; qualification rejected')
    if cache_in and row.get('shaderStageCacheHits') != 6:
        raise RuntimeError(label+': old cache loaded but all six shader-stage cache hits were not proven')

try:
    run('v36-cache-seed',baseline,oldlib,False,cache_out=cache)
    old_cache_sha=digest(cache)
    run('v37-disabled',candidate,newlib,False)
    run('v37-enabled-cold',candidate,newlib,True)
    run('v37-enabled-v36-cache',candidate,newlib,True,cache_in=cache)
    run('v37-sample-only-disabled',candidate,newlib,False,sample_only=True)
    run('v37-sample-only-enabled',candidate,newlib,True,sample_only=True)
    assert digest(cache)==old_cache_sha
    report=dict(passed=all(x['passed'] for x in results),results=results,ownedOldCacheUnchanged=True,
                actualGamePerformanceValidated=False,gameOperated=False)
except Exception as exc:
    report=dict(passed=False,error=str(exc),results=results,gameOperated=False)
(out/'qualification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'passed':report['passed'],'output':str(out),'error':report.get('error')},indent=2))
raise SystemExit(0 if report['passed'] else 1)
