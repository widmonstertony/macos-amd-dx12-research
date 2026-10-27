#!/usr/bin/env python3
"""Build app-local API backport and unchanged AGS forwarders, never launch a game."""
import hashlib, json, pathlib, re, shutil, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/fh6-wine-compat-20261027'
TOOL = ROOT / 'vendor/llvm-mingw-20261006-ucrt-macos-universal/bin'
ORIGINAL = pathlib.Path('/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/ForzaHorizon6/amd_ags_x64.dll')
OUT.mkdir(exist_ok=True)
text = subprocess.check_output([str(TOOL/'x86_64-w64-mingw32-objdump'), '-p', str(ORIGINAL)], text=True)
text = text.split('Export Table:', 1)[1]
wrapped = {'agsInitialize', 'agsDeInitialize', 'agsDriverExtensionsDX12_CreateDevice',
           'agsGetGPUInfo', 'agsDriverExtensionsDX12_DestroyDevice'}
exports = []
for line in text.splitlines():
    match = re.match(r'\s*(\d+)\s+0x[0-9a-f]+\s+(ags\w+)\s*$', line)
    if match:
        ordinal, name = match.groups()
        target = name if name in wrapped else name + '=amd_ags_real.' + name
        exports.append('  ' + target + ' @' + ordinal)
assert len(exports) == 37, 'Review a changed vendor ABI before building'
definition = OUT/'amd_ags_x64.def'
definition.write_text('LIBRARY amd_ags_x64\nEXPORTS\n' + '\n'.join(exports) + '\n')
compiler = TOOL/'x86_64-w64-mingw32-clang++'
common = [str(compiler), '-std=c++17', '-O2', '-Wall', '-Wextra', '-static-libgcc', '-static-libstdc++', '-I'+str(ROOT/'src')]
subprocess.run(common + ['-shared', str(ROOT/'src/fh6_wine_compat.cpp'), str(definition),
                       '-Wl,--out-implib,'+str(OUT/'libagscompat.a'), '-ldxgi', '-ld3d12', '-ldxguid',
                       '-o', str(OUT/'amd_ags_x64.dll')], check=True)
shutil.copy2(ORIGINAL, OUT/'amd_ags_real.dll')
api = OUT/'sysinfo.def'
api.write_text('LIBRARY api-ms-win-core-sysinfo-l1-2-3.dll\nEXPORTS\n GetIntegratedDisplaySize\n')
subprocess.run([str(TOOL/'x86_64-w64-mingw32-dlltool'), '-d', str(api), '-l', str(OUT/'libsysinfo.a')], check=True)
subprocess.run(common + [str(ROOT/'src/fh6_wine_compat_control.cpp'), str(OUT/'libagscompat.a'), str(OUT/'libsysinfo.a'),
                       '-ld3d12', '-ldxguid',
                       '-o', str(OUT/'fh6-wine-compat-control.exe')], check=True)
record = {'originalAGS': str(ORIGINAL), 'originalAGSUnmodified': True, 'preservedVendorExportCount': len(exports),
          'wrappedVendorCalls': sorted(wrapped), 'displayBehavior': 'Wine c68ed23672: E_NOTIMPL, output untouched',
          'baseAGSFallback': 'Actual DXGI enumeration and unchanged D3D12CreateDevice feature-level request',
          'proprietaryDriverExtensionsAdvertised': False,
          'GPUVendorOrFeaturesChanged': False, 'gameFileModified': False}
record['binaries'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [OUT/'amd_ags_x64.dll', OUT/'amd_ags_real.dll', OUT/'fh6-wine-compat-control.exe']}
(OUT/'build.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record, indent=2))
