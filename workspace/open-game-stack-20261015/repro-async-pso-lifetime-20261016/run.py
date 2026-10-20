#!/usr/bin/env python3
"""Run only the self-authored PSO stress probe in the existing Tencent Wine.

No Steam/game launch, registry mutation, vendor-library replacement or cache removal.
"""
import argparse, datetime, hashlib, json, os, pathlib, shutil, subprocess

here = pathlib.Path(__file__).resolve().parent
p = here.parent
lib = p / 'build/moltenvk-replay-only/MoltenVK/libMoltenVK.1.4.2.dylib'
parser = argparse.ArgumentParser()
parser.add_argument('--library', type=pathlib.Path)
parser.add_argument('--slow-threshold-ms', type=int)
parser.add_argument('--encoder-live-cache', action='store_true')
parser.add_argument('--live-lookup-fast-cache', action='store_true')
parser.add_argument('--descriptor-use-cache', action='store_true')
parser.add_argument('--probe', choices=('stress', 'device', 'present'), default='stress')
args = parser.parse_args()
if args.library:
    lib = args.library.resolve()
    if not lib.is_relative_to(p / 'build') or not lib.is_file():
        parser.error('Use an existing isolated research build')
if args.slow_threshold_ms is not None and args.slow_threshold_ms < 0:
    parser.error('Slow trace threshold must be nonnegative')
expected = 'cc2535ea504c9a7ebf5f19401df33127b39b03fb1672b18d5dfb086bfd8c286c'
digest = hashlib.sha256(lib.read_bytes()).hexdigest()
if not args.library and digest != expected:
    raise SystemExit('Current qualified baseline library hash changed')
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
dest = p / 'evidence' / ('pso-lifetime-stress-' + stamp)
dest.mkdir()
(dest / 'msl').mkdir()
# The engine has existing per-application native d3d12core preferences for the
# established self-authored compute probe. Reuse that probe identity in a new
# evidence directory; do not write the application registry or replace its probe.
probeName = {'stress':'d3d12_compute_probe.exe','device':'d3d12_probe.exe','present':'d3d12_presentation_probe.exe'}[args.probe]
exe = dest / probeName
source = here/'d3d12_pso_lifetime_stress.exe' if args.probe == 'stress' else p/'probe-app'/probeName
shutil.copy2(source, exe)
for name in ('d3d12.dll', 'd3d12core.dll', 'dxgi.dll'):
    (dest / name).symlink_to(p / 'probe-app' / name)
support = pathlib.Path('/Users/tonytan/Library/Application Support/YYBIntelLauncher')
contents = support / '.runtime/wine-engine.app/Contents'
prefix = pathlib.Path('/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine')
env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'WINE', 'YYB_', 'VK_', 'VKD3D_', 'DXVK_', 'MVK_', 'MTL_', 'D3DM_', 'SteamAppId', 'SteamGameId'))}
env.update(WINEPREFIX=str(prefix), YYB_NTDLL_PATH=str(contents/'SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so'),
    WINELOADER=str(support/'wine-loader'), WINESERVER=str(contents/'MacOS/wineserver'),
    WINEDLLPATH=str(p/'backend/wine')+':'+str(contents/'SharedSupport/wine/lib/wine'),
    GFX_BACKEND_PATH=str(p/'backend/wine'), WINEDEBUG='-all',
    WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n;winemenubuilder.exe=d',
    VKD3D_AMD_PROTECTED_SUBSET='1', MVK_AMD_REFERENCE_RBA2='1', MVK_AMD_REFERENCE_RIA2='1',
    MVK_AMD_REFERENCE_NULL='1', MVK_AMD_BYTE_GUARDS='1', MVK_AMD_COHERENT_ATOMICS='1',
    MVK_AMD_RUNTIME_TRACE='1', MVK_AMD_RUNTIME_REPLAY_ONLY='1', MVK_AMD_REPLAY_FAILED_MESH='1',
    MVK_AMD_SERIALIZE_PIPELINE_LINK='1', MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',
    MVK_CONFIG_LOG_LEVEL='2', MVK_CONFIG_SHADER_DUMP_DIR=str(dest/'msl'),
    VKD3D_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M', DXVK_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M',
    VKD3D_DEBUG='info', DXVK_LOG_LEVEL='info', DXVK_LOG_PATH=str(dest))
if args.slow_threshold_ms is not None:
    env.update(MVK_AMD_TRACE_SLOW_COMPUTE='1', MVK_AMD_SLOW_COMPUTE_MS=str(args.slow_threshold_ms))
if args.encoder_live_cache:
    env['MVK_AMD_ENCODER_LIVE_CACHE'] = '1'
if args.descriptor_use_cache:
    env['MVK_AMD_DESCRIPTOR_USE_CACHE'] = '1'
if args.live_lookup_fast_cache:
    if not args.encoder_live_cache: parser.error('--live-lookup-fast-cache requires --encoder-live-cache')
    env['MVK_AMD_LIVE_LOOKUP_FAST_CACHE'] = '1'
cmd = ['/usr/bin/sandbox-exec', '-f', str(p/'tencent-normal-original-guard.sb'), '/usr/bin/env',
    'DYLD_LIBRARY_PATH='+str(lib.parent), 'DYLD_FALLBACK_LIBRARY_PATH='+str(contents/'Frameworks'),
    'DYLD_PRINT_LIBRARIES=1', 'MTL_DEBUG_LAYER=1', str(support/'wine-loader'), str(exe)]
record = dict(timeUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(), command=cmd,
    gameStarted=False, steamRestarted=False, prefix=str(prefix), library=str(lib), librarySHA256=digest,
    threads=8, iterationsPerThread=64, expectedPSOCreations=512)
record['encoderLiveCache'] = args.encoder_live_cache
record['liveLookupFastCache'] = args.live_lookup_fast_cache
record['descriptorUseCache'] = args.descriptor_use_cache
record['probe'] = args.probe
with (dest/'stdout.log').open('w') as out, (dest/'stderr.log').open('w') as err:
    child = subprocess.Popen(cmd, env=env, cwd=exe.parent, stdout=out, stderr=err)
    record['pid'] = child.pid
    (dest/'launch.json').write_text(json.dumps(record, indent=2)+'\n')
    try:
        record['exitCode'] = child.wait(timeout=150)
    except subprocess.TimeoutExpired:
        child.terminate()
        record['timeout'] = True
        record['exitCode'] = child.wait(timeout=10)
out = (dest/'stdout.log').read_text(errors='replace')
err = (dest/'stderr.log').read_text(errors='replace')
record['expectedLibraryMapped'] = str(lib) in err
markers = {'stress':'stress.result=PASS', 'device':'copy_smoke.result=PASS', 'present':'presentation.gpu_api_result=PASS'}
record['passed'] = record['exitCode'] == 0 and record['expectedLibraryMapped'] and markers[args.probe] in out
if args.probe == 'stress':
    record['passed'] = record['passed'] and 'compute.compared_words=1024 mismatches=0' in out
else:
    for key in ('threads', 'iterationsPerThread', 'expectedPSOCreations'):
        record.pop(key)
if args.slow_threshold_ms is not None:
    traces = [json.loads(f.read_text()) for f in (dest/'msl').glob('trace-slow-compute-*.json')]
    record['slowTraceThresholdMilliseconds'] = args.slow_threshold_ms
    record['slowComputeTraceCount'] = len(traces)
    record['slowTracePhaseSumsValid'] = all(abs(t['totalMilliseconds'] - t['functionMilliseconds'] - t['pipelineMilliseconds']) < .001 for t in traces)
    record['slowTraceRecordsCreated'] = all(t['created'] and t['configurationResult'] == 0 for t in traces)
    if args.slow_threshold_ms == 0:
        record['passed'] = record['passed'] and bool(traces) and record['slowTracePhaseSumsValid'] and record['slowTraceRecordsCreated']
(dest/'run.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record, indent=2))
print(out[-5000:])
print('Evidence:', dest)
raise SystemExit(0 if record['passed'] else 1)
