#!/usr/bin/env python3
"""Normal Steam request only, against a verified original protected session."""
import argparse,ctypes,datetime,hashlib,json,os,pathlib,subprocess,time

p=pathlib.Path(__file__).resolve().parent;r=p.parent
ap=argparse.ArgumentParser();ap.add_argument('--session',type=pathlib.Path,required=True);args=ap.parse_args()
session=args.session.resolve()
assert session.parent==p/'evidence' and session.name.startswith('tencent-original-app-steam-')
entry=json.loads((session/'native-entry.json').read_text())
assert entry['selfAppliedOriginalAssetGuard'] and entry['originalPrefix']
support=pathlib.Path('/Users/tonytan/Library/Application Support/YYBIntelLauncher')
c=support/'.runtime/wine-engine.app/Contents'
prefix=pathlib.Path('/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine')
steam=prefix/'drive_c/Program Files (x86)/Steam/Steam.exe'
rows=subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines()
candidates=[]
for row in rows:
    fields=row.strip().split(None,2)
    if len(fields)==3 and fields[1]==str(entry['entryPID']) and fields[2].casefold()==str(steam).casefold():candidates.append(int(fields[0]))
assert len(candidates)==1,'Expected one original Steam child of the protected native entry'
steam_pid=candidates[0]
cmdpath=subprocess.check_output(['ps','-p',str(steam_pid),'-o','comm='],text=True).strip()
assert cmdpath.casefold()==str(steam).casefold(), 'Qualified original Steam session no longer exists'
inventory=subprocess.check_output(['ps','-axo','pid=,comm='],text=True)
assert 'SB-Win64-Shipping.exe' not in inventory and '/StellarBlade/SB.exe' not in inventory, 'Game already running'
session_meta=json.loads((session/'launch.json').read_text())
lib=pathlib.Path(session_meta.get('nativeLibrary',str(p/'build/moltenvk/MoltenVK/libMoltenVK.1.4.2.dylib')))
original_lib=p/'build/moltenvk/MoltenVK/libMoltenVK.1.4.2.dylib'
native3d_lib=p/'build/moltenvk-native-3d-attachment/libMoltenVK.1.4.2.dylib'
typed_lib=p/'build/moltenvk-typed-roots/MoltenVK/libMoltenVK.1.4.2.dylib'
trace_lib=p/'build/moltenvk-runtime-trace/MoltenVK/libMoltenVK.1.4.2.dylib'
replay_lib=p/'build/moltenvk-runtime-replay/MoltenVK/libMoltenVK.1.4.2.dylib'
cache_lib=p/'build/moltenvk-cache-r3/MoltenVK/libMoltenVK.1.4.2.dylib'
link_lib=p/'build/moltenvk-link-serialized/MoltenVK/libMoltenVK.1.4.2.dylib'
array_lib=p/'build/moltenvk-vertex-array/MoltenVK/libMoltenVK.1.4.2.dylib'
coherent_lib=p/'build/moltenvk-replay-only/MoltenVK/libMoltenVK.1.4.2.dylib'
live_lib=p/'build/moltenvk-live-dedup/MoltenVK/libMoltenVK.1.4.2.dylib'
recent_lib=p/'build/moltenvk-live-recent/MoltenVK/libMoltenVK.1.4.2.dylib'
descriptor_lib=p/'build/moltenvk-descriptor-use/MoltenVK/libMoltenVK.1.4.2.dylib'
incremental_lib=p/'build/moltenvk-descriptor-incremental/MoltenVK/libMoltenVK.1.4.2.dylib'
archive_lib=p/'build/moltenvk-binary-archive-compute-render/MoltenVK/libMoltenVK.1.4.2.dylib'
signed_archive_lib=p/'build/moltenvk-bounded-archive-signed/MoltenVK/libMoltenVK.1.4.2.dylib'
installed_signed_archive_lib=pathlib.Path('/Applications/Steam（Windows）.app/Contents/Frameworks/MoltenVK/libMoltenVK.1.4.2.dylib')
batch_source_lib=p/'build/moltenvk-live-batch/MoltenVK/libMoltenVK.1.4.2.dylib'
# The original App wrapper selects the deployed archive path when it receives
# YYB_OPEN_BINARY_ARCHIVE_CACHE. The trial record keeps the source candidate
# path for provenance; resolve that record to the path the Steam process
# actually mapped, and require the two files to be byte-identical.
if lib==batch_source_lib:
    assert 'YYB_OPEN_BINARY_ARCHIVE_CACHE=1' in session_meta.get('command',[])
    assert hashlib.sha256(lib.read_bytes()).digest()==hashlib.sha256(archive_lib.read_bytes()).digest()
    lib=archive_lib
if lib==signed_archive_lib:
    assert installed_signed_archive_lib.is_file(), 'Signed archive library is not deployed in the protected App'
    assert hashlib.sha256(lib.read_bytes()).digest()==hashlib.sha256(installed_signed_archive_lib.read_bytes()).digest(), 'Deployed archive library differs from the GPU-qualified binary'
    lib=installed_signed_archive_lib
assert lib in [installed_signed_archive_lib,archive_lib,incremental_lib,descriptor_lib,recent_lib,live_lib,original_lib,native3d_lib,typed_lib,trace_lib,replay_lib,cache_lib,link_lib,array_lib,coherent_lib]
proof_name=('evidence/pending-native-known-good-ab6.json' if lib==archive_lib and session_meta.get('knownGoodRestore') else
    'evidence/pending-native-binary-archive-signed.json' if lib==installed_signed_archive_lib else
    'evidence/pending-native-binary-archive.json' if lib==archive_lib else
    'evidence/pending-native-descriptor-incremental.json' if lib==incremental_lib else
    'evidence/pending-native-descriptor-use.json' if lib==descriptor_lib else
    'evidence/pending-native-live-recent.json' if lib==recent_lib else
    'evidence/pending-native-encoder-live-cache.json' if lib==live_lib else
    'evidence/pending-native-coherent-atomics.json' if lib==coherent_lib else
    'evidence/pending-native-vertex-array.json' if lib==array_lib else
    'evidence/pending-native-link-serialized.json' if lib==link_lib else
    'evidence/pending-native-cache-r3.json' if lib==cache_lib else
    'evidence/pending-native-runtime-replay.json' if lib==replay_lib else
    'evidence/pending-native-runtime-trace.json' if lib==trace_lib else
    'evidence/pending-native-typed-roots.json' if lib==typed_lib else
    'evidence/pending-native-3d-attachment.json' if lib==native3d_lib else
    'evidence/verification-summary.json')
proof=json.loads((p/proof_name).read_text())
if lib in [installed_signed_archive_lib,archive_lib,incremental_lib,descriptor_lib,recent_lib,live_lib,native3d_lib,typed_lib,trace_lib,replay_lib,cache_lib,link_lib,array_lib,coherent_lib]:assert proof['qualified'] and proof['nativeRegressionPassed'] and proof['originalTencentPresentationPassed']
assert hashlib.sha256(lib.read_bytes()).hexdigest()==proof['librarySHA256']
assert all(x['passed'] for x in proof['GPUchecks']) and proof['originalTencentPresentationPassed']
maps=subprocess.check_output(['lsof','-a','-p',str(steam_pid),'-Fn'],text=True)
steam_mapped='n'+str(lib) in maps.splitlines()
steam_environment=subprocess.check_output(['ps','eww','-p',str(steam_pid)],text=True)
steam_selected=('DYLD_LIBRARY_PATH='+str(lib.parent)) in steam_environment and 'MVK_AMD_COHERENT_ATOMICS=1' in steam_environment
# Wine's Windows steam.exe strips its Unix bootstrap environment after startup.
# The native wineloader/wineserver descendants retain the dyld selection that
# creates the actual game process, so include that lineage in the preflight.
session_selected=steam_selected
if session_meta.get('knownGoodRestore'):
    parent_of={}; all_pids=[]
    for row in subprocess.check_output(['ps','-axo','pid=,ppid='],text=True).splitlines():
        fields=row.split()
        if len(fields)==2:
            pid,ppid=map(int,fields);parent_of[pid]=ppid;all_pids.append(pid)
    descendants=[]
    for pid in all_pids:
        cursor=pid
        while cursor in parent_of and cursor not in (0,1):
            if cursor==entry['entryPID']:
                descendants.append(pid);break
            cursor=parent_of[cursor]
    for pid in descendants:
        process_env=subprocess.run(['ps','eww','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
        if ('DYLD_LIBRARY_PATH='+str(lib.parent)) in process_env and 'MVK_AMD_COHERENT_ATOMICS=1' in process_env:
            session_selected=True
            break
assert steam_mapped or (lib in [coherent_lib,live_lib,recent_lib,descriptor_lib,incremental_lib,archive_lib,installed_signed_archive_lib] and session_selected), 'Original Steam session neither mapped nor selected qualified MoltenVK'
sandbox=ctypes.CDLL('/usr/lib/libsandbox.1.dylib',use_errno=True)
check=sandbox.sandbox_check;check.restype=ctypes.c_int
original='/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/StellarBlade/SB.exe'
def policy(path):
    return check(ctypes.c_int(steam_pid),ctypes.c_char_p(b'file-write-data'),ctypes.c_int(1),ctypes.c_char_p(str(path).encode()))
assert policy(original)==1 and policy(p/'cross-x86_64.ini')==0, 'Actual Steam protection policy does not match'
expected={'d3d12.dll':'526ed60c3edd558748968ab4d3ce5d774c662a70f135b65d5907ca30d46a53d6','d3d12core.dll':'9fa9ef3f91c161a0857866abcfa046cd46b81d24592360862e9895bb5b5bdeb6'}
qualification=json.loads((p/('evidence/pending-vkd3d-runtime-trace.json' if lib in [archive_lib,incremental_lib,descriptor_lib,recent_lib,live_lib,trace_lib,replay_lib,cache_lib,link_lib,array_lib,coherent_lib] else 'evidence/pending-vkd3d-observer-build.json')).read_text())
if lib in [installed_signed_archive_lib,archive_lib,incremental_lib,descriptor_lib,recent_lib,live_lib,trace_lib,replay_lib,cache_lib,link_lib,array_lib,coherent_lib]:expected=qualification['binaries']
assert qualification['qualified'] and qualification['binaries']==expected
for name,digest in expected.items():
    f=r/'stellar-overlay/SB/Binaries/Win64'/name
    assert f.is_file() and not f.is_symlink() and hashlib.sha256(f.read_bytes()).hexdigest()==digest
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
d=p/'evidence'/('tencent-normal-game-'+stamp);d.mkdir()
game_log=session/'vkd3d-game.log'
if game_log.exists():
    (d/'previous-vkd3d-game.log').write_bytes(game_log.read_bytes())
    game_log.write_text('')
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','WINE','YYB_','MVK_','VK_','VKD3D_','DXVK_','SteamAppId','SteamGameId'))}
env.update(WINEPREFIX=str(prefix),YYB_NTDLL_PATH=str(c/'SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so'),YYB_WINESERVER_HOST_APP=str(support/'WineServerHost.app'),
    WINESERVER=str(support/'wineserver-wrapper'),WINELOADER=str(support/'wine-loader'),WINEDLLPATH=str(c/'SharedSupport/wine/lib/wine'),
    GFX_BACKEND_PATH=str(c/'Frameworks/render/dxvk/wine'),WINE_RETINA_MODE='1',WINE_RETINA_SCALE='2.0',WINEDEBUG='-all')
# Mirror the original launch-windows-app steam-game client request. Existing
# protected Steam owns licensing, prerequisites, launch environment and child.
command=['/usr/bin/sandbox-exec','-f',str(p/'tencent-normal-original-guard.sb'),'/usr/bin/env','DYLD_FALLBACK_LIBRARY_PATH='+str(c/'Frameworks'),
    str(support/'wine-loader'),str(steam),'-applaunch','3489700','-dx12','-windowed','-ResX=1280','-ResY=800']
with (d/'client-stdout.log').open('w')as out,(d/'client-stderr.log').open('w')as err:
    child=subprocess.Popen(command,env=env,cwd=steam.parent,stdout=out,stderr=err,start_new_session=True)
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'clientPID':child.pid,'existingSteamPID':steam_pid,'session':str(session),
    'normalSteamOnly':True,'originalEngine':True,'originalPrefix':True,'originalSteamActualGuardVerified':True,'qualifiedMoltenVKActuallyLoadedInSteam':steam_mapped,
    'qualifiedMoltenVKSelectedInSteamEnvironment':steam_selected,
    'qualifiedMoltenVKSelectedInSessionLineage':session_selected,
    'librarySHA256':proof['librarySHA256'],'binaries':expected,'command':command,'gameStarted':False,'gamePlayable':False,
    'next':'Verify actual game process, exact game native library, device minFL and sparse traces; no inference from client exit0.'}
(d/'launch.json').write_text(json.dumps(record,indent=2)+'\n')
(p/'evidence/current-original-game-trial.json').write_text(json.dumps({'directory':str(d),'existingSteamPID':steam_pid,'clientPID':child.pid},indent=2)+'\n')
print(json.dumps({'directory':str(d),'clientPID':child.pid,'normalSteamOnly':True}),flush=True)
# Observe only process identity and graphics file mappings. Capture immediately
# because a failing game may exit before a separate interactive check runs.
observed={};deadline=time.monotonic()+45;last_alive=None
while time.monotonic()<deadline:
    rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
    alive=[]
    for row in rows:
        fields=row.strip().split(None,1)
        if len(fields)!=2 or 'SB-Win64-Shipping.exe' not in fields[1]:continue
        pid=int(fields[0]);alive.append(pid);last_alive=time.monotonic()
        item=observed.setdefault(str(pid),{'pid':pid,'comm':fields[1],'graphicsMappings':[]})
        mapped=subprocess.run(['lsof','-a','-p',str(pid),'-Fn'],capture_output=True,text=True).stdout
        paths=[x[1:] for x in mapped.splitlines() if x.startswith('n') and any(k in x.lower() for k in ('moltenvk','vkd3d','d3d12','dxgi.dll','d3dmetal'))]
        item['graphicsMappings']=sorted(set(item['graphicsMappings']+paths))
        item['qualifiedMoltenVKActuallyLoaded']=str(lib) in item['graphicsMappings']
        item['originalAssetWritePolicy']=check(ctypes.c_int(pid),ctypes.c_char_p(b'file-write-data'),ctypes.c_int(1),ctypes.c_char_p(original.encode()))
        (d/'game-process-mappings.json').write_text(json.dumps(observed,indent=2)+'\n')
    if observed and not alive and time.monotonic()-last_alive>2:break
    time.sleep(.3)
record['gameStarted']=bool(observed)
record['observedGameProcesses']=observed
record['observationEndedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat()
record['gameStillRunningAtObservationEnd']=bool(alive)
if observed:
    invalid=[item for item in observed.values() if not item['qualifiedMoltenVKActuallyLoaded'] or item['originalAssetWritePolicy']!=1]
    if invalid:
        for item in invalid:
            try:os.kill(item['pid'],15)
            except ProcessLookupError:pass
        raise AssertionError('Actual game did not load the qualified library or original asset guard')
if game_log.exists():(d/'vkd3d-game.log').write_bytes(game_log.read_bytes())
(d/'launch.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'gameStarted':bool(observed),'gameStillRunning':bool(alive),'directory':str(d)}),flush=True)
