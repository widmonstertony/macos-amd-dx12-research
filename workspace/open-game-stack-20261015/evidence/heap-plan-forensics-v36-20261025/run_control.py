#!/usr/bin/env python3
"""Root-coordinated bounded headless GPU control. This file is not run by its preparer."""
import argparse,hashlib,json,os,subprocess,time
from pathlib import Path
OUT=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=OUT/'gpu-output.json');p.add_argument('--forensics',action='store_true');a=p.parse_args()
report=a.output.resolve();assert report.is_relative_to(OUT) and not report.exists(),'Use a new owned report path'
assert not report.with_suffix('.run.json').exists()
proof=json.loads((OUT/'build.json').read_text());lib=Path(proof['frozenLibrary']);binary=Path(proof['binary'])
abi=json.loads((OUT/'abi-check.json').read_text());assert abi['matchedNativeHeaderManifest']
assert hashlib.sha256(lib.read_bytes()).hexdigest()==proof['frozenLibrarySHA256']==abi['nativeCandidateSHA256']
assert hashlib.sha256(binary.read_bytes()).hexdigest()==proof['binarySHA256']
env={k:v for k,v in os.environ.items() if not k.startswith(('MVK_','MTL_','VK_','DYLD_'))}
for name in ('ENCODER_LIVE_CACHE','CROSS_ENCODER_LIVE_CACHE','DESCRIPTOR_USE_CACHE','DESCRIPTOR_SNAPSHOT_REUSE','CROSS_ENCODER_SNAPSHOT_REUSE','BATCH_LIVE_USE_RESOURCE','BATCH_ARGUMENT_HEAPS','ENCODER_HEAP_PLANS','SHARED_LIVE_SNAPSHOTS','RESOURCE_USE_STATS'):
 env['MVK_AMD_'+name]='1'
env.update(MVK_AMD_ARGUMENT_HEAP_THRESHOLD='2',MTL_DEBUG_LAYER='1',MVK_FIXTURE_EXPECTED_LIBRARY=str(lib))
traceDir=None
if a.forensics:
 traceDir=OUT/(report.stem+'-forensics');traceDir.mkdir(exist_ok=False)
 marker=traceDir/'forensics.arm';marker.write_text('owned direct-helper fixture\n')
 env.update(MVK_AMD_FORENSICS_ARM_PATH=str(marker),MVK_CONFIG_SHADER_DUMP_DIR=str(traceDir),
            MVK_AMD_STUTTER_COVERAGE='1',MVK_AMD_CPU_FINE_SAMPLE_EVERY='64',MVK_FIXTURE_FORENSICS='1')
 # No GPU timestamp capture/repair interposition or shader-validation env added.
started=time.monotonic()
with report.with_suffix('.stdout').open('x') as so,report.with_suffix('.stderr').open('x') as se:
 r=subprocess.run([str(binary),str(report)],env=env,stdout=so,stderr=se,timeout=60)
record=dict(exitCode=r.returncode,elapsedSeconds=time.monotonic()-started,report=str(report),
 candidateSHA256=proof['frozenLibrarySHA256'],nativeOnly=True,gameOperated=False,forensicsRequested=a.forensics,
 directHelperFixture=True,explicitDiagnosticObserveReset=True,realGameBinderWiringValidated=False,
 nativeHeaderManifestMatched=True,expectedGPUValues=776)
if report.exists():
 try:record['output']=json.loads(report.read_text())
 except ValueError:record['incompleteJSON']=True
output=record.get('output',{})
record['originalGPUOraclePassed']=bool(r.returncode==0 and output.get('GPUOutputPassed') and output.get('GPUValuesChecked')==776 and
 output.get('nativeOnly') and output.get('strictNativeOnly') and output.get('nativeCandidateOnly') and not output.get('repairInterpositionEnabled') and
 output.get('mismatches')==0 and output.get('baselineContractPassed'))
if traceDir:
 from analyze_resource_forensics import analyze
 record['resourceForensics']=analyze(traceDir)
 details=record['resourceForensics']
 record['resourceForensicsPassed']=details['counterCoveragePassed'] and not details['commonWriterLossObserved']
 record['resourceForensicsQualificationScope']='observed required nonzero counters; not complete tail statistics or proof of real game binder wiring'
report.with_suffix('.run.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items()if k not in ('output','resourceForensics')},indent=2))
raise SystemExit(r.returncode or (0 if record['originalGPUOraclePassed'] and (not a.forensics or record['resourceForensicsPassed']) else 7))
