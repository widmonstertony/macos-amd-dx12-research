#!/usr/bin/env python3
"""Use the installed Tencent engine, existing prefix and existing Steam login."""
import argparse,datetime,hashlib,json,os,pathlib,subprocess
from pathlib import Path

p=pathlib.Path(__file__).resolve().parent;r=p.parent
ap=argparse.ArgumentParser();ap.add_argument('stage',choices=['steam','device','compute','present','windows','play','warm-steam','warm-play','bridge-steam','bridge-play','selection','titles','errors','guard','shutdown','dock-steam','ls-steam','ls-client-control','original-app-steam','original-app-mvk-control','home-app-steam','home-app-steam-selector']);ap.add_argument('--startup-diagnostics',action='store_true');ap.add_argument('--native-3d-attachments',action='store_true');ap.add_argument('--typed-roots',action='store_true');ap.add_argument('--runtime-trace',action='store_true');ap.add_argument('--replay-failed-mesh',action='store_true');ap.add_argument('--cache-fix',action='store_true');ap.add_argument('--serialize-pipeline-link',action='store_true');ap.add_argument('--vertex-array-input',action='store_true');ap.add_argument('--coherent-atomics',action='store_true');ap.add_argument('--performance',action='store_true');ap.add_argument('--encoder-live-cache',action='store_true');ap.add_argument('--live-lookup-fast-cache',action='store_true');ap.add_argument('--descriptor-use-cache',action='store_true');ap.add_argument('--descriptor-incremental-cache',action='store_true');ap.add_argument('--binary-archive-cache',action='store_true');ap.add_argument('--batch-live-use-resource',action='store_true');ap.add_argument('--launch-stellar',action='store_true');a=ap.parse_args()
if a.launch_stellar and a.stage!='home-app-steam':raise SystemExit('Cold Steam app launch is scoped to the real home App entry')
if a.batch_live_use_resource and not a.binary_archive_cache:raise SystemExit('Live-resource batching retains the qualified binary archive and lifetime stack')
if a.binary_archive_cache and not a.runtime_trace:raise SystemExit('Binary archive candidate requires the trace-qualified native path')
if a.binary_archive_cache and not a.descriptor_use_cache:raise SystemExit('Binary archive candidate retains the qualified descriptor and resource lifetime caches')
if a.descriptor_incremental_cache and not a.descriptor_use_cache:raise SystemExit('Incremental candidate retains all descriptor/lifetime guards')
if a.descriptor_use_cache and not a.live_lookup_fast_cache:raise SystemExit('Descriptor cache retains the qualified resource lifetime guards')
if a.live_lookup_fast_cache and not a.encoder_live_cache:raise SystemExit('Recent lookup cache requires the retained encoder cache')
if a.encoder_live_cache and not a.coherent_atomics:raise SystemExit('Encoder live cache retains all qualified coherent/mesh/vertex fixes')
if a.performance and a.stage!='original-app-steam':raise SystemExit('Performance mode only applies to the protected original Steam App')
if a.performance and not (a.runtime_trace and a.replay_failed_mesh):raise SystemExit('Performance mode retains the qualified mesh replay path')
if a.coherent_atomics and not (a.runtime_trace and a.replay_failed_mesh and a.serialize_pipeline_link and a.vertex_array_input):raise SystemExit('Coherent atomic candidate retains trace, mesh replay, link serialization and vertex-array fixes')
if a.vertex_array_input and not a.serialize_pipeline_link:raise SystemExit('Vertex array candidate retains pipeline serialization')
if a.serialize_pipeline_link and not a.runtime_trace:raise SystemExit('Link serialization requires trace-qualified build')
if a.serialize_pipeline_link and a.cache_fix:raise SystemExit('Select exactly one native experiment')
if a.cache_fix and not a.runtime_trace:raise SystemExit('Cache fix requires trace-qualified build')
if a.replay_failed_mesh and not a.runtime_trace:raise SystemExit('Runtime replay requires the source trace')
if a.startup_diagnostics and a.stage!='original-app-steam':raise SystemExit('Startup diagnostics only apply to the original Steam App')
if a.stage in ['play','warm-play','bridge-play']:
    raise SystemExit('Unqualified legacy game stage disabled: require verified original Steam session and original asset guard before normal Steam game launch')
support=pathlib.Path('/Users/tonytan/Library/Application Support/YYBIntelLauncher')
contents=support/'.runtime/wine-engine.app/Contents'
prefix=pathlib.Path('/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine')
steam=prefix/'drive_c/Program Files (x86)/Steam/Steam.exe'
lib=p/'build/moltenvk/MoltenVK/libMoltenVK.1.4.2.dylib'
if sum([a.typed_roots,a.native_3d_attachments,a.runtime_trace])>1:raise SystemExit('Select one qualified native build')
if a.runtime_trace:
    native_build=json.loads((p/('evidence/pending-native-live-batch.json' if a.batch_live_use_resource else 'evidence/pending-native-binary-archive-signed.json' if a.binary_archive_cache else 'evidence/pending-native-descriptor-incremental.json' if a.descriptor_incremental_cache else 'evidence/pending-native-descriptor-use.json' if a.descriptor_use_cache else 'evidence/pending-native-live-recent.json' if a.live_lookup_fast_cache else 'evidence/pending-native-encoder-live-cache.json' if a.encoder_live_cache else 'evidence/pending-native-coherent-atomics.json' if a.coherent_atomics else 'evidence/pending-native-vertex-array.json' if a.vertex_array_input else 'evidence/pending-native-link-serialized.json' if a.serialize_pipeline_link else 'evidence/pending-native-cache-r3.json' if a.cache_fix else 'evidence/pending-native-runtime-replay.json' if a.replay_failed_mesh else 'evidence/pending-native-runtime-trace.json')).read_text());lib=Path(native_build['library'])
elif a.typed_roots:
    native_build=json.loads((p/'evidence/pending-native-typed-roots.json').read_text());lib=Path(native_build['library'])
elif a.native_3d_attachments:
    native_build=json.loads((p/'evidence/pending-native-3d-attachment.json').read_text());lib=Path(native_build['library'])
digest=hashlib.sha256(lib.read_bytes()).hexdigest()
proof=json.loads((p/'evidence/verification-summary.json').read_text())
if a.native_3d_attachments or a.typed_roots or a.runtime_trace:
    if digest!=native_build['librarySHA256'] or not native_build.get('nativeRegressionPassed'):raise SystemExit('Exact native attachment regression proof required')
    # original-app-steam establishes the Tencent Cocoa/Wine GUI host needed by
    # the presentation probe.  It cold-starts plain Steam only; the separate
    # qualified game launcher still refuses to submit -applaunch until the
    # exact signed candidate passes device, compute and presentation.
    if a.binary_archive_cache and a.stage not in ['device','compute','present','original-app-mvk-control','original-app-steam'] and not native_build.get('originalTencentPresentationPassed'):raise SystemExit('Exact archive candidate still needs original Tencent Wine presentation qualification')
elif a.stage!='shutdown' and (digest!=proof['librarySHA256'] or not all(x['passed']for x in proof['GPUchecks'])):raise SystemExit('Qualified exact compiler required')
guard=p/'tencent-normal-original-guard.sb'
guard.write_text((r/'stellar-original-write-guard.sb').read_text()+'''
; Original launcher may rebuild its verified byte-identical native-loader cache.
; Normal original-environment use is user-authorized; full cache backup retained.
; Original normal launcher hard-links its native loader: file-write* on the
; source prevents even link creation. Do not add that incompatible experiment
; rule here. Engine content is not edited; exact hashes are recorded separately.
; Original game guard above is unchanged; old complete-copy guard is unchanged.
''')
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
dest=p/'evidence'/('tencent-'+a.stage+'-'+stamp);dest.mkdir();(dest/'msl').mkdir()
env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','WINE','YYB_','VK_','VKD3D_','DXVK_','MVK_','GPU_ADAPTER_','D3DM_','SteamAppId','SteamGameId'))}
env.update(WINEPREFIX=str(prefix),YYB_NTDLL_PATH=str(contents/'SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so'),
    WINELOADER=str(support/'wine-loader'),WINESERVER=str(contents/'MacOS/wineserver'),WINEDLLPATH=str(contents/'SharedSupport/wine/lib/wine'),
    GFX_BACKEND_PATH=str(contents/'Frameworks/render/dxvk/wine'),WINEDEBUG='-all',WINE_RETINA_MODE='1',WINE_RETINA_SCALE='2.0',
    DXVK_HUD='0',MTL_HUD_ENABLED='0',D3DM_ENABLE_METALFX='0')
if a.stage in ['steam','play','warm-steam','warm-play','bridge-steam','bridge-play']:
    target=r/'wine-yyb10-gptk4-isolated.app/Contents/MacOS/tencent-open-steam-bridge' if a.stage.startswith('bridge-') else support/'wine-loader' if a.stage.startswith('warm-') else contents/'MacOS/winelauncher';args=[str(steam)]
    if a.stage.startswith('bridge-'):args+=['-cef-disable-gpu','-cef-disable-gpu-compositing','-cef-disable-occlusion']
    if a.stage in ['play','warm-play','bridge-play']:args+=['-applaunch','3489700','-dx12','-windowed','-ResX=1280','-ResY=800']
elif a.stage in ['dock-steam','ls-steam','ls-client-control','original-app-steam','original-app-mvk-control','home-app-steam','home-app-steam-selector']:
    target=p/'TencentSteamResearch.app/Contents/MacOS/start';args=[]
elif a.stage=='shutdown':
    target=support/'wine-loader';args=[str(steam),'-shutdown']
else:
    target=support/'wine-loader'
    programs={'device':p/'probe-app/d3d12_probe.exe','compute':p/'probe-app/d3d12_compute_probe.exe','present':p/'probe-app/d3d12_presentation_probe.exe','windows':r/'yyb_window_state_probe.exe','selection':p/'probe-app/tencent_loader_selection.exe','titles':p/'probe-app/tencent_window_titles.exe','errors':p/'probe-app/tencent_error_text.exe','guard':p/'probe-app/tencent_asset_guard_probe.exe'}
    args=[str(programs[a.stage])]
if a.stage.startswith('bridge-'):env['YYB_RESEARCH_OPEN_ROOT']=str(p)
if a.stage in ['steam','bridge-steam','dock-steam','ls-steam','ls-client-control','original-app-steam','original-app-mvk-control','home-app-steam','home-app-steam-selector'] and not a.performance:
    env['VKD3D_LOG_FILE']=('Z:'+chr(92))+str((dest/'vkd3d-game.log').relative_to(Path('/Users/tonytan'))).replace('/',chr(92))
    env['DYLD_PRINT_LIBRARIES']='1'
if a.stage not in ['windows','titles','guard','shutdown']:
    env.update(VKD3D_AMD_PROTECTED_SUBSET='1',MVK_AMD_REFERENCE_RBA2='1',MVK_AMD_REFERENCE_RIA2='1',MVK_AMD_REFERENCE_NULL='1',MVK_AMD_BYTE_GUARDS='1',
        MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',MVK_CONFIG_LOG_LEVEL='2',MVK_CONFIG_SHADER_DUMP_DIR=str(dest/'msl'),
        VKD3D_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M',DXVK_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M',
        WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d',VKD3D_DEBUG='info',DXVK_LOG_LEVEL='info',VKD3D_SHADER_CACHE_PATH=('Z:'+chr(92))+str((p/'build/private-shader-cache').relative_to(Path('/Users/tonytan'))).replace('/',chr(92)),DXVK_LOG_PATH=('Z:'+chr(92))+str(dest.relative_to(Path('/Users/tonytan'))).replace('/',chr(92)))
if a.performance:
    env.update(MVK_CONFIG_LOG_LEVEL='0',VKD3D_DEBUG='none',DXVK_LOG_LEVEL='none',MVK_AMD_RUNTIME_REPLAY_ONLY='1')
if a.stage in ['device','compute','present','selection']:env.update(GFX_BACKEND_PATH=str(p/'backend/wine'),WINEDLLPATH=str(p/'backend/wine')+':'+str(contents/'SharedSupport/wine/lib/wine'),WINEDEBUG='-all,err+all,+loaddll',WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n')
if a.runtime_trace:env['MVK_AMD_RUNTIME_TRACE']='1'
if a.runtime_trace and not a.performance:env['VKD3D_AMD_RUNTIME_TRACE']='1'
if a.replay_failed_mesh:env['MVK_AMD_REPLAY_FAILED_MESH']='1'
if a.serialize_pipeline_link:env['MVK_AMD_SERIALIZE_PIPELINE_LINK']='1'
if a.coherent_atomics:env['MVK_AMD_COHERENT_ATOMICS']='1'
if a.descriptor_use_cache:env['MVK_AMD_DESCRIPTOR_USE_CACHE']='1'
if a.live_lookup_fast_cache:env['MVK_AMD_LIVE_LOOKUP_FAST_CACHE']='1'
if a.encoder_live_cache:env.update(MVK_AMD_ENCODER_LIVE_CACHE='1',MVK_AMD_TRACE_SLOW_COMPUTE='1')
if a.batch_live_use_resource:env['MVK_AMD_BATCH_LIVE_USE_RESOURCE']='1'
if a.binary_archive_cache:
    archive_root=p/'build/game-metal-binary-cache';archive_root.mkdir(parents=True,exist_ok=True)
    # The original compute.metalar reached 1.70 GB.  Merely opening it peaks at
    # 5.68 GB RSS on the Radeon Pro 5600M, before the game allocates anything.
    # Keep it intact as evidence and start a bounded cache generation instead.
    env.update(MVK_AMD_BINARY_ARCHIVE_PATH=str(archive_root/'compute-bounded-v2.metalar'),MVK_AMD_RENDER_BINARY_ARCHIVE_PATH=str(archive_root/'render-bounded-v2.metalar'),MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL='64',MVK_AMD_BINARY_ARCHIVE_MAX_BYTES=str(256*1024*1024))
loader=['DYLD_LIBRARY_PATH='+str(lib.parent),
        'DYLD_FALLBACK_LIBRARY_PATH='+str(contents/'Frameworks')]
if a.stage in ['device','compute','present']:loader+=['DYLD_PRINT_LIBRARIES=1','MTL_DEBUG_LAYER=1']
cmd=['/usr/bin/sandbox-exec','-f',str(guard),'/usr/bin/env',*loader,str(target),*args]
if a.stage in ['ls-steam','ls-client-control','original-app-steam','original-app-mvk-control','home-app-steam','home-app-steam-selector']:
    env['YYB_OPEN_ENTRY_RECORD']=str(dest/'native-entry.json')
    if a.stage=='ls-client-control':env['YYB_OPEN_CLIENT_CONTROL_ONLY']='1'
    if a.stage in ['original-app-steam','original-app-mvk-control','home-app-steam']:env['YYB_OPEN_STEAM_ENTRY']='1'
    if a.stage in ['original-app-steam','home-app-steam']:
        env['YYB_OPEN_LATE_ASSET_GUARD']='1'
        env['YYB_OPEN_GUARD_RECORD']=str(dest/'guard-proxy.trace')
    if a.stage=='home-app-steam':
        if a.launch_stellar:env['YYB_OPEN_STEAM_APP_ID']='3489700'
    if a.stage=='original-app-mvk-control':env['YYB_OPEN_BASIC_MOLTENVK']='1'
    if a.stage=='home-app-steam-selector':
        # Keep Tencent's proven shell/winelauncher lifecycle byte-for-byte.
        # The dyld proxy defers the asset sandbox for Steam and applies it only
        # after the actual Stellar Blade argv is visible in the child process.
        # This route passed device, compute and presentation on the same GUI
        # host; the older win32u replacement did not map and is no longer used.
        deferred=native_build.get('deferredRuntime',{})
        proxy=Path(deferred.get('proxy',''))
        candidate=Path(deferred.get('candidate',''))
        proxy_dir=Path('/private/tmp/mvk-guard-proxy-select')
        if not proxy.is_file() or not candidate.is_file() or not proxy_dir.is_dir():raise SystemExit('Qualified deferred MoltenVK proxy is missing')
        if hashlib.sha256(proxy.read_bytes()).hexdigest()!=deferred.get('proxySHA256') or hashlib.sha256(candidate.read_bytes()).hexdigest()!=deferred.get('candidateSHA256'):raise SystemExit('Deferred MoltenVK proxy or candidate differs from qualification')
        env['YYB_OPEN_GUARD_RECORD']=str(dest/'guard-proxy.trace')
    assert all(isinstance(k,str) and isinstance(v,str) for k,v in env.items()), 'Invalid environment key/value before launch'
    forward={k:v for k,v in env.items() if k.startswith(('MVK_','VKD3D_','DXVK_')) or k in ['WINEDLLPATH','YYB_OPEN_GUARD_RECORD','YYB_OPEN_LATE_ASSET_GUARD','YYB_OPEN_ENTRY_RECORD','YYB_OPEN_CLIENT_CONTROL_ONLY','YYB_OPEN_STEAM_ENTRY','YYB_OPEN_BASIC_MOLTENVK','YYB_OPEN_STEAM_APP_ID']}
    if a.stage=='home-app-steam-selector':forward['DYLD_LIBRARY_PATH']='/private/tmp/mvk-guard-proxy-select'
    if a.startup_diagnostics:forward['WINEDEBUG']='-all,err+all,+seh,+debugstr'
    if a.native_3d_attachments:forward['YYB_OPEN_NATIVE_3D_ATTACHMENT']='1'
    if a.typed_roots:forward['YYB_OPEN_TYPED_ROOTS']='1'
    if a.runtime_trace:forward['YYB_OPEN_RUNTIME_TRACE']='1'
    if a.replay_failed_mesh:forward['YYB_OPEN_RUNTIME_REPLAY']='1'
    if a.cache_fix:forward['YYB_OPEN_CACHE_FIX']='1'
    if a.serialize_pipeline_link:forward['YYB_OPEN_LINK_SERIAL']='1'
    if a.vertex_array_input:forward['YYB_OPEN_VERTEX_ARRAY']='1'
    if a.coherent_atomics:forward['YYB_OPEN_COHERENT_ATOMICS']='1'
    if a.descriptor_incremental_cache:forward['YYB_OPEN_DESCRIPTOR_INCREMENTAL']='1'
    if a.descriptor_use_cache:forward['YYB_OPEN_DESCRIPTOR_USE_CACHE']='1'
    if a.live_lookup_fast_cache:forward['YYB_OPEN_LIVE_LOOKUP_FAST_CACHE']='1'
    if a.encoder_live_cache:forward['YYB_OPEN_ENCODER_LIVE_CACHE']='1'
    if a.binary_archive_cache:forward['YYB_OPEN_BINARY_ARCHIVE_CACHE']='1'
    cmd=['/usr/bin/open','-n']
    for key,value in forward.items():cmd+=['--env',key+'='+value]
    app_target=(Path('/Users/tonytan/Applications/Steam（Windows）.app') if a.stage=='home-app-steam' else Path('/Applications/Steam（Windows）.app') if a.stage in ['original-app-steam','original-app-mvk-control','home-app-steam-selector'] else p/'TencentSteamResearch.app')
    cmd+=[str(app_target)]
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'stage':a.stage,'command':cmd,'nativeLibrary':str(lib),'librarySHA256':digest,'prefix':str(prefix),'engine':str(contents),'sameTencentPrefix':True,'engineFilesModified':False,'normalSteamOnly':True,'performanceMode':a.performance,'graphicsEvidenceDirectory':str(dest)}
with (dest/'stdout.log').open('w')as out,(dest/'stderr.log').open('w')as err:
    child=subprocess.Popen(cmd,env=env,cwd=steam.parent,stdout=out,stderr=err,start_new_session=True)
record['pid']=child.pid
if a.stage in ['device','compute','present','windows','titles','errors','selection','guard','shutdown']:
    try:record['exitCode']=child.wait(timeout=55)
    except subprocess.TimeoutExpired:
        record['timeout']=True;child.terminate()
    output=(dest/'stdout.log').read_text(errors='replace')
    markers={'device':'copy_smoke.result=PASS','compute':'compute.result=PASS','present':'presentation.gpu_api_result=PASS','guard':'asset.write_access_denied=PASS'}
    if a.stage in markers:record['actualOutputPassed']=markers[a.stage] in output and record.get('exitCode')==0
    (dest/'run.json').write_text(json.dumps(record,indent=2)+'\n')
(dest/'launch.json').write_text(json.dumps(record,indent=2)+'\n')
(p/'evidence/current-tencent-trial.json').write_text(json.dumps({'directory':str(dest),'pid':child.pid,'stage':a.stage},indent=2)+'\n')
print(json.dumps({'directory':str(dest),'pid':child.pid,'stage':a.stage,'sameTencentPrefix':True}))
