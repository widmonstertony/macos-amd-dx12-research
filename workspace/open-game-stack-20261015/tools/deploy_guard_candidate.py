#!/usr/bin/env python3
"""Atomically deploy an owned, already-qualified MoltenVK game candidate."""
import argparse,datetime,hashlib,json,os,pathlib,shutil,subprocess

ROOT=pathlib.Path(__file__).resolve().parents[1]
DEST=pathlib.Path('/private/tmp/mvk-guard-proxy')

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

p=argparse.ArgumentParser()
p.add_argument('--candidate-directory',type=pathlib.Path,required=True)
p.add_argument('--label',required=True)
p.add_argument('--native-evidence',type=pathlib.Path,required=True)
p.add_argument('--geometry-evidence',type=pathlib.Path,required=True)
a=p.parse_args()
source=a.candidate_directory.resolve()
assert source.is_relative_to(ROOT/'build')
candidate=source/'libCandidate.dylib';proxy=source/'libProbeGuard.dylib'
assert candidate.is_file() and proxy.is_file()
native=a.native_evidence.resolve();geometry=a.geometry_evidence.resolve()
assert native.is_relative_to(ROOT/'evidence') and geometry.is_relative_to(ROOT/'evidence')
assert json.loads(native.read_text()).get('passed') is True
assert json.loads(geometry.read_text()).get('passed') is True

DEST.mkdir(parents=True,exist_ok=True)
candidate_next=DEST/'libQualifiedCandidateReexport.dylib.next'
proxy_next=DEST/'libMoltenVKGuard.dylib.next'
shutil.copy2(candidate,candidate_next);shutil.copy2(proxy,proxy_next)
dependencies=subprocess.check_output(['otool','-L',str(proxy_next)],text=True).splitlines()[1:]
old_candidates=[line.strip().split(' (',1)[0] for line in dependencies if 'libCandidate.dylib' in line]
assert len(old_candidates)==1
deployed_candidate=DEST/'libQualifiedCandidateReexport.dylib'
deployed_proxy=DEST/'libMoltenVKGuard.dylib'
subprocess.run(['install_name_tool','-change',old_candidates[0],str(deployed_candidate),str(proxy_next)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(candidate_next)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(proxy_next)],check=True)
subprocess.run(['codesign','--verify','--strict',str(candidate_next)],check=True)
subprocess.run(['codesign','--verify','--strict',str(proxy_next)],check=True)
os.replace(candidate_next,deployed_candidate);os.replace(proxy_next,deployed_proxy)

selector=pathlib.Path('/private/tmp/mvk-guard-proxy-select');selector.mkdir(exist_ok=True)
for name in ('libMoltenVK.dylib','libMoltenVK.1.dylib','libMoltenVK.1.4.2.dylib'):
    link=selector/name;temporary=selector/(name+'.next')
    temporary.unlink(missing_ok=True);temporary.symlink_to(deployed_proxy);os.replace(temporary,link)

record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'label':a.label,'sourceCandidate':str(candidate),'sourceCandidateSHA256':sha(candidate),
        'deployedCandidate':str(deployed_candidate),'deployedCandidateSHA256':sha(deployed_candidate),
        'deployedProxy':str(deployed_proxy),'deployedProxySHA256':sha(deployed_proxy),
        'nativeEvidence':str(native),'geometryEvidence':str(geometry),
        'codesignVerified':True,'atomicReplacement':True,'gameStarted':False}
out=ROOT/'evidence'/(a.label+'-deployment.json');out.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
