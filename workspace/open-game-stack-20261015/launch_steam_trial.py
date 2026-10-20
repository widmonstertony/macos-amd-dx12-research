#!/usr/bin/env python3
"""Normal Steam launch only, with original assets and vendor data write-protected."""
import datetime, hashlib, json, os, pathlib, shutil, subprocess

p=pathlib.Path(__file__).resolve().parent
r=p.parent
lib=p/'build/moltenvk/MoltenVK/libMoltenVK.1.4.2.dylib'
digest=hashlib.sha256(lib.read_bytes()).hexdigest()
present=json.loads((p/'evidence/windows-present-explicit-loader/run.json').read_text())
text=(p/'evidence/windows-present-explicit-loader/stdout.log').read_text()
if present.get('librarySHA256')!=digest or not present.get('loadedExpectedMoltenVK') or 'presentation.gpu_api_result=PASS' not in text:
    raise SystemExit('Expected protected library and actual presentation qualification required')
qualified=set()
for f in (p/'evidence').glob('amd-*/run.json'):
    j=json.loads(f.read_text())
    if j.get('librarySHA256')==digest and j.get('passed') and j.get('metalValidationEnabled'): qualified.add(j.get('suite'))
if not set(['static','memory','vector','aggregate','graphics','bda','descriptors']).issubset(qualified):
    raise SystemExit('Native GPU qualification missing')
wine=pathlib.Path('/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/Wine Staging.app/Contents/Resources/wine')
prefix=r/'prefix-open-dx12'
steam=r/'SteamClient/steam.exe'
overlay=r/'stellar-overlay/SB/Binaries/Win64'
guard=p/'isolated-no-vendor-write.sb'
if not all(x.exists() for x in [steam,overlay,prefix/'system.reg',guard]): raise SystemExit('Owned trial prerequisites unavailable')
# Never overwrite or follow an existing game DLL symlink.
sources={'d3d12.dll':p/'build/vkd3d/libs/d3d12/d3d12.dll','d3d12core.dll':p/'build/vkd3d/libs/d3d12core/d3d12core.dll','dxgi.dll':r/'vkd3d-proton-macos/dxgi.dll'}
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
dest=p/'evidence'/('steam-normal-'+stamp)
dest.mkdir();(dest/'msl').mkdir()
for name,source in sources.items():
    target=overlay/name
    if target.is_symlink(): raise SystemExit('Refusing DLL symlink: '+str(target))
    if target.exists():
        if hashlib.sha256(target.read_bytes()).digest()==hashlib.sha256(source.read_bytes()).digest(): continue
        backup=dest/'previous-overlay-dlls';backup.mkdir(exist_ok=True);shutil.copy2(target,backup/name)
    shutil.copy2(source,target)
icd=dest/'icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','VKD3D_','DXVK_','MVK_','MTL_','WINE'))}
env.update(WINEPREFIX=str(prefix),WINEARCH='win64',WINESERVER=str(wine/'bin/wineserver'),WINELOADER=str(wine/'bin/wine'),PATH=str(wine/'bin')+':/usr/bin:/bin',
    VK_ICD_FILENAMES=str(icd),VKD3D_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M',DXVK_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M',
    VKD3D_AMD_PROTECTED_SUBSET='1',MVK_AMD_REFERENCE_RBA2='1',MVK_AMD_REFERENCE_RIA2='1',MVK_AMD_REFERENCE_NULL='1',MVK_AMD_BYTE_GUARDS='1',
    MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',MVK_CONFIG_LOG_LEVEL='2',MVK_CONFIG_SHADER_DUMP_DIR=str(dest/'msl'),
    WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d',WINEDEBUG='-all',VKD3D_DEBUG='info',DXVK_LOG_LEVEL='info',DXVK_LOG_PATH=str(dest),VKD3D_SHADER_CACHE_PATH=str(p/'build/private-shader-cache'))
# Normal Steam owns licensing, prerequisites and the game process. No direct
# game executable mode and no feature-level/installation-state overrides.
cmd=['/usr/bin/sandbox-exec','-f',str(guard),'/usr/bin/env','DYLD_LIBRARY_PATH='+str(lib.parent)+':/usr/local/opt/vulkan-loader/lib:'+str(wine/'lib'),str(wine/'bin/wine'),str(steam),'-applaunch','3489700','-windowed','-ResX=1280','-ResY=800']
with (dest/'stdout.log').open('w')as out,(dest/'stderr.log').open('w')as err:
    child=subprocess.Popen(cmd,env=env,cwd=steam.parent,stdout=out,stderr=err,start_new_session=True)
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'pid':child.pid,'command':cmd,'librarySHA256':digest,'normalSteamOnly':True,'guard':str(guard),'prefix':str(prefix),'gamePlayable':False,'binaries':{name:hashlib.sha256(source.read_bytes()).hexdigest()for name,source in sources.items()}}
(dest/'launch.json').write_text(json.dumps(record,indent=2)+'\n')
(p/'evidence/current-steam-trial.json').write_text(json.dumps({'directory':str(dest),'pid':child.pid},indent=2)+'\n')
print(json.dumps({'trial':str(dest),'pid':child.pid,'normalSteamOnly':True}))
