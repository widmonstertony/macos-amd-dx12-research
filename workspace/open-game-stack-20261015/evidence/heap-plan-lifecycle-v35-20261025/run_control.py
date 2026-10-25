#!/usr/bin/env python3
"""Run ONLY after root coordinates the one bounded headless GPU control."""
import argparse,hashlib,json,os,subprocess,time
from pathlib import Path
OUT=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=OUT/'gpu-output.json');a=p.parse_args()
report=a.output.resolve();assert report.is_relative_to(OUT) and not report.exists(),'Use a new owned report path'
assert not report.with_suffix('.run.json').exists()
proof=json.loads((OUT/'build.json').read_text());lib=Path(proof['frozenLibrary']);binary=Path(proof['binary'])
assert hashlib.sha256(lib.read_bytes()).hexdigest()==proof['frozenLibrarySHA256']
assert hashlib.sha256(binary.read_bytes()).hexdigest()==proof['binarySHA256']
env={k:v for k,v in os.environ.items() if not k.startswith(('MVK_','MTL_','VK_','DYLD_'))}
for name in ('ENCODER_LIVE_CACHE','CROSS_ENCODER_LIVE_CACHE','DESCRIPTOR_USE_CACHE','DESCRIPTOR_SNAPSHOT_REUSE','CROSS_ENCODER_SNAPSHOT_REUSE','BATCH_LIVE_USE_RESOURCE','BATCH_ARGUMENT_HEAPS','ENCODER_HEAP_PLANS','SHARED_LIVE_SNAPSHOTS','RESOURCE_USE_STATS'):
 env['MVK_AMD_'+name]='1'
env.update(MVK_AMD_ARGUMENT_HEAP_THRESHOLD='2',MTL_DEBUG_LAYER='1',MVK_FIXTURE_EXPECTED_LIBRARY=str(lib))
started=time.monotonic()
with report.with_suffix('.stdout').open('x') as so,report.with_suffix('.stderr').open('x') as se:
 r=subprocess.run([str(binary),str(report)],env=env,stdout=so,stderr=se,timeout=60)
record=dict(exitCode=r.returncode,elapsedSeconds=time.monotonic()-started,report=str(report),
 candidateSHA256=proof['frozenLibrarySHA256'],nativeOnly=True,gameOperated=False)
if report.exists():
 try:record['output']=json.loads(report.read_text())
 except ValueError:record['incompleteJSON']=True
report.with_suffix('.run.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items() if k!='output'},indent=2));raise SystemExit(r.returncode)
