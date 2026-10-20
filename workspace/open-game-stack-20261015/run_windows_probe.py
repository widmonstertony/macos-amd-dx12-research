#!/usr/bin/env python3
"""Private source-built AMD contract, self-authored probes only. No game mode."""
import argparse, datetime, hashlib, json, os, pathlib, shutil, signal, subprocess

p = pathlib.Path(__file__).resolve().parent
r = p.parent
ap = argparse.ArgumentParser()
ap.add_argument('--probe', choices=['device', 'compute', 'graphics', 'present'], required=True)
ap.add_argument('--label', required=True)
a = ap.parse_args()
if not a.label.replace('-', '').replace('_', '').isalnum():
    ap.error('Safe unique label required')
lib = p/'build/moltenvk/MoltenVK/libMoltenVK.1.4.2.dylib'
digest = hashlib.sha256(lib.read_bytes()).hexdigest()
required = ['static', 'memory', 'vector', 'aggregate', 'graphics', 'bda', 'descriptors']
qualified = {}
for suite in required:
    for file in sorted((p/'evidence').glob('amd-*/run.json')):
        j = json.loads(file.read_text())
        if j.get('suite') == suite and j.get('librarySHA256') == digest and j.get('passed') and j.get('metalValidationEnabled'):
            qualified[suite] = str(file)
if set(qualified) != set(required):
    raise SystemExit('Refusing unqualified private compiler: missing GPU evidence for ' + str(set(required)-set(qualified)))
dest = p/'evidence'/a.label
dest.mkdir(exist_ok=False)
(dest/'msl').mkdir()
icd = dest/'icd.json'
icd.write_text(json.dumps({'file_format_version': '1.0.0', 'ICD': {'library_path': str(lib), 'api_version': '1.4.0', 'is_portability_driver': True}}))
wine = pathlib.Path('/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/Wine Staging.app/Contents/Resources/wine')
prefix = r/'prefix-open-dx12'
if not (prefix/'system.reg').is_file():
    raise SystemExit('Expected existing isolated stock Wine prefix unavailable')
(p/'build/private-shader-cache').mkdir(exist_ok=True)
app = p/'probe-app'
app.mkdir(exist_ok=True)
sources = {'device': r/'d3d12_probe.exe', 'compute': r/'compute-probe/d3d12_compute_probe.exe', 'graphics': r/'dxbc-probe/d3d12_dxbc_graphics_probe.exe', 'present': r/'presentation-probe/d3d12_presentation_probe.exe'}
exe = app/sources[a.probe].name
shutil.copy2(sources[a.probe], exe)
for dll in ['d3d12', 'd3d12core']:
    shutil.copy2(p/f'build/vkd3d/libs/{dll}/{dll}.dll', app/f'{dll}.dll')
# Existing native DXGI provider previously enumerated this AMD on stock Wine.
# Its provenance is explicitly separate from the newly source-built D3D12 pair.
shutil.copy2(r/'vkd3d-proton-macos/dxgi.dll', app/'dxgi.dll')
guard = p/'isolated-no-vendor-write.sb'
guard.write_text((r/'stellar-original-write-guard.sb').read_text()+'''
(deny file-write*
    (subpath "/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine")
    (subpath "/Users/tonytan/Library/Application Support/YYBIntelLauncher")
    (subpath "/Users/tonytan/Public/links"))
''')
env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'VK_', 'VKD3D_', 'DXVK_', 'MVK_', 'MTL_', 'WINE'))}
env.update(WINEPREFIX=str(prefix), WINEARCH='win64', WINESERVER=str(wine/'bin/wineserver'), WINELOADER=str(wine/'bin/wine'),
    DYLD_PRINT_LIBRARIES='1', PATH=str(wine/'bin')+':/usr/bin:/bin', DYLD_LIBRARY_PATH=str(lib.parent)+':/usr/local/opt/vulkan-loader/lib:'+str(wine/'lib'),
    VK_ICD_FILENAMES=str(icd), VKD3D_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M', DXVK_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M',
    VKD3D_AMD_PROTECTED_SUBSET='1', MVK_AMD_REFERENCE_RBA2='1', MVK_AMD_REFERENCE_RIA2='1', MVK_AMD_REFERENCE_NULL='1', MVK_AMD_BYTE_GUARDS='1',
    MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1', MVK_CONFIG_LOG_LEVEL='2', MVK_CONFIG_SHADER_DUMP_DIR=str(dest/'msl'), MTL_DEBUG_LAYER='1',
    WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d', WINEDEBUG='-all', VKD3D_DEBUG='info', DXVK_LOG_LEVEL='info', DXVK_LOG_PATH=str(dest),
    VKD3D_SHADER_CACHE_PATH=str(p/'build/private-shader-cache'))
# Apple's protected sandbox launcher strips DYLD variables. Set research
# loader paths inside the already-active sandbox, preserving all write guards.
loader = ['DYLD_LIBRARY_PATH='+env.pop('DYLD_LIBRARY_PATH'), 'DYLD_PRINT_LIBRARIES='+env.pop('DYLD_PRINT_LIBRARIES')]
cmd = ['/usr/bin/sandbox-exec', '-f', str(guard), '/usr/bin/env', *loader, str(wine/'bin/wine'), str(exe)]
record = {'timeUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'command': cmd, 'librarySHA256': digest,
    'qualification': qualified, 'probe': a.probe, 'gameStarted': False, 'privateSubsetNotConformance': True,
    'binaries': {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in app.glob('*.dll')}}
with (dest/'stdout.log').open('w') as out, (dest/'stderr.log').open('w') as err:
    child = subprocess.Popen(cmd, env=env, cwd=app, stdout=out, stderr=err, start_new_session=True)
    record['pid'] = child.pid
    try:
        record['exitCode'] = child.wait(timeout=55)
    except subprocess.TimeoutExpired:
        record['timeout'] = True
        os.killpg(child.pid, signal.SIGTERM)
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL)
logs=(dest/'stderr.log').read_text(errors='replace')
record['loadedExpectedMoltenVK']=str(lib) in logs
record['loadedLibraryLines']=[line for line in logs.splitlines() if 'libMoltenVK' in line or 'libvulkan.' in line]
(dest/'run.json').write_text(json.dumps(record, indent=2)+'\n')
print('Evidence:', dest)
print((dest/'stdout.log').read_text(errors='replace')[-6500:])
print((dest/'stderr.log').read_text(errors='replace')[-7500:])
raise SystemExit(record.get('exitCode', 1))
