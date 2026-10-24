#!/usr/bin/env python3
"""Build a probe against the actual source helper and an owned exact candidate."""
import argparse,hashlib,json,pathlib,shlex,subprocess
r=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--library',type=pathlib.Path,required=True);a=p.parse_args();lib=a.library.resolve()
assert lib.is_file() and lib.is_relative_to(r/'build')
flags=(r/'build/moltenvk-bounded-archive/MoltenVK/CMakeFiles/MoltenVK.dir/flags.make').read_text();d={l.split(' = ',1)[0]:l.split(' = ',1)[1] for l in flags.splitlines() if ' = ' in l}
out=r/'build/probes/heap_write_declaration_gpu'
gpu_plist=r/'build/probes/high-performance-gpu.plist'
gpu_plist.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
                     '<key>CFBundleIdentifier</key><string>org.open-game-stack.amd-gpu-probe</string>'
                     '<key>CFBundleName</key><string>AMD GPU Probe</string>'
                     '<key>CFBundlePackageType</key><string>APPL</string>'
                     '<key>NSSupportsAutomaticGraphicsSwitching</key><false/>'
                     '<key>NSHighResolutionCapable</key><true/>'
                     '</dict></plist>\n')
cmd=['clang++','-Wl,-headerpad_max_install_names',f'-Wl,-sectcreate,__TEXT,__info_plist,{gpu_plist}','-std=c++17','-O2','-DNDEBUG','-DMVK_USE_METAL_PRIVATE_API=0','-DMVK_EXCLUDE_SPIRV_TOOLS=1','-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross']+shlex.split(d['OBJCXX_INCLUDES'])+[str(r/'src/heap_write_declaration_gpu.mm'),str(lib),'-framework','Foundation','-framework','Metal','-framework','QuartzCore','-o',str(out)]
subprocess.run(cmd,check=True)
subprocess.run(['install_name_tool','-change','@rpath/libMoltenVK.1.dylib',str(lib),str(out)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(out)],check=True)
(out.with_suffix('.build.json')).write_text(json.dumps({'candidate':str(lib),'candidateSHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'command':cmd},indent=2)+'\n')
print(out)
