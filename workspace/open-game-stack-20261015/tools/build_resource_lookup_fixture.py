#!/usr/bin/env python3
"""Build a probe against the actual source helper and an owned exact candidate."""
import argparse,hashlib,json,pathlib,shlex,subprocess
r=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--library',type=pathlib.Path,required=True);p.add_argument('--descriptor-delta',action='store_true');p.add_argument('--snapshot-stages',action='store_true');p.add_argument('--pending-batches',action='store_true');p.add_argument('--queue-chain',action='store_true');p.add_argument('--shared-registry',action='store_true');p.add_argument('--clean-blocks',action='store_true');p.add_argument('--header-override',type=pathlib.Path);a=p.parse_args();lib=a.library.resolve()
assert sum([a.descriptor_delta,a.snapshot_stages,a.pending_batches,a.queue_chain,a.clean_blocks,a.shared_registry])<=1
header=a.header_override.resolve() if a.header_override else None
assert not header or header.is_relative_to(r/'evidence') and (header/'MVKCommandEncoderState.h').is_file()
assert lib.is_file() and lib.is_relative_to(r/'build')
flags=(r/'build/moltenvk-bounded-archive/MoltenVK/CMakeFiles/MoltenVK.dir/flags.make').read_text();d={l.split(' = ',1)[0]:l.split(' = ',1)[1] for l in flags.splitlines() if ' = ' in l}
name='shared_snapshot_registry_gpu' if a.shared_registry else 'descriptor_clean_blocks_gpu' if a.clean_blocks else 'queued_resource_declarations_gpu' if a.queue_chain else 'pending_declaration_batches_gpu' if a.pending_batches else 'snapshot_stage_coverage_gpu' if a.snapshot_stages else 'descriptor_membership_delta_gpu' if a.descriptor_delta else 'resource_lookup_epoch_gpu'
out=r/'build/probes'/name
gpu_plist=r/'build/probes/high-performance-gpu.plist'
gpu_plist.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
                     '<key>CFBundleIdentifier</key><string>org.open-game-stack.amd-gpu-probe</string>'
                     '<key>CFBundleName</key><string>AMD GPU Probe</string>'
                     '<key>CFBundlePackageType</key><string>APPL</string>'
                     '<key>NSSupportsAutomaticGraphicsSwitching</key><false/>'
                     '<key>NSHighResolutionCapable</key><true/>'
                     '</dict></plist>\n')
cmd=['clang++','-Wl,-headerpad_max_install_names',f'-Wl,-sectcreate,__TEXT,__info_plist,{gpu_plist}','-std=c++17','-O2','-DNDEBUG','-DMVK_USE_METAL_PRIVATE_API=0','-DMVK_EXCLUDE_SPIRV_TOOLS=1','-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross']+(['-I'+str(header)] if header else [])+(['-DMVK_PENDING_BATCH_CONTROL=1'] if a.pending_batches and not header else [])+shlex.split(d['OBJCXX_INCLUDES'])+[str(r/'src'/(name+'.mm')),str(lib),'-framework','Foundation','-framework','Metal','-framework','QuartzCore','-o',str(out)]
subprocess.run(cmd,check=True)
subprocess.run(['install_name_tool','-change','@rpath/libMoltenVK.1.dylib',str(lib),str(out)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(out)],check=True)
(out.with_suffix('.build.json')).write_text(json.dumps({'candidate':str(lib),'candidateSHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'command':cmd},indent=2)+'\n')
print(out)
