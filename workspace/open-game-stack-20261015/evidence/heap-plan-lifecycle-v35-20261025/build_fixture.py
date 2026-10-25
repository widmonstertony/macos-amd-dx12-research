#!/usr/bin/env python3
"""Compile the extended owned fixture. Does not execute Metal or the fixture."""
import argparse,hashlib,json,subprocess,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OUT=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--library',type=Path,default=ROOT/'build/buffer-read-plan-v35-20261025-probe/libCandidate.dylib');a=p.parse_args()
lib=a.library.resolve();assert lib.is_relative_to(ROOT/'build') and lib.is_file()
assert not (OUT/'build.json').exists(),'Keep previous build proof; use a new evidence directory for rebuilds'
frozen=OUT/'libFixtureCandidate.dylib';shutil.copy2(lib,frozen)
original=json.loads((ROOT/'evidence/residency-plan-control-20261025/native-v31-build-command.json').read_text())
cmd=original[:]
cmd[cmd.index(str(ROOT/'evidence/residency-plan-control-20261025/residency_override_gpu_future.mm'))]=str(OUT/'residency_lifecycle_gpu.mm')
cmd[cmd.index(str(ROOT/'build/moltenvk-bounded-archive/MoltenVK/libMoltenVK.1.4.2.dylib'))]=str(frozen)
binary=OUT/'residency_lifecycle_gpu';cmd[-1]=str(binary)
with (OUT/'build.stdout').open('x') as so,(OUT/'build.stderr').open('x') as se:
 result=subprocess.run(cmd,stdout=so,stderr=se)
proof=dict(command=cmd,exitCode=result.returncode,sourceLibrary=str(lib),sourceLibrarySHA256=hashlib.sha256(lib.read_bytes()).hexdigest(),
 frozenLibrary=str(frozen),frozenLibrarySHA256=hashlib.sha256(frozen.read_bytes()).hexdigest(),GPUExecuted=False,nativeProductionModified=False,
 sourceSHA256=hashlib.sha256((OUT/'residency_lifecycle_gpu.mm').read_bytes()).hexdigest(),
 casesSHA256=hashlib.sha256((OUT/'lifecycle_cases.inc').read_bytes()).hexdigest())
if result.returncode==0:
 install_id=subprocess.check_output(['/usr/bin/otool','-D',str(frozen)],text=True).splitlines()[1].strip()
 subprocess.run(['/usr/bin/install_name_tool','-change',install_id,str(frozen),str(binary)],check=True)
 subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(binary)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 proof.update(binary=str(binary),binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),originalInstallID=install_id)
(OUT/'build.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof,indent=2));raise SystemExit(result.returncode)
