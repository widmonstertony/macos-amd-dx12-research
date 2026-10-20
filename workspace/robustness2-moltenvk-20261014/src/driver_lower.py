#!/usr/bin/env python3
"""Development compiler invoked by isolated MoltenVK, never by the test caller."""
import json, pathlib, subprocess, sys
from r2_lower import Lower
inp, out, counts = map(pathlib.Path, sys.argv[1:4])
text = subprocess.check_output(['/usr/local/bin/spirv-dis','--raw-id',str(inp)],text=True)
assert 'OpEntryPoint GLCompute' in text, 'Research driver currently accepts compute only'
asm, manifest = Lower(text,0,json.loads(counts.read_text()),metadata_set=31).lower()
assert manifest['metadataSlots'] <= 256, 'Metadata setBytes limit exceeded; refusing pipeline'
minor = (int.from_bytes(inp.read_bytes()[4:8],'little')>>8)&255
assert 3 <= minor <= 6
out.with_suffix('.spvasm').write_text(asm)
subprocess.run(['/usr/local/bin/spirv-as','--target-env',f'spv1.{minor}',str(out.with_suffix('.spvasm')),'-o',str(out)],check=True)
subprocess.run(['/usr/local/bin/spirv-val','--target-env','vulkan1.1' if minor==3 else 'vulkan1.2' if minor<6 else 'vulkan1.3',str(out)],check=True)
out.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
