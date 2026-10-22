#!/usr/bin/env python3
"""Build from unchanged source content; reject a mixed incremental snapshot."""
import argparse,datetime,hashlib,json,pathlib,re,subprocess,time
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--jobs',type=int,default=4);a=p.parse_args()
if not re.fullmatch('[a-z0-9-]{1,64}',a.label) or not 1<=a.jobs<=6:p.error('Safe label and 1..6 jobs required')
out=root/'evidence'/a.label;out.mkdir(exist_ok=False)
sources=[root/'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93',
         root/'native-vendor/SPIRV-Cross-939b40b33a44443c404c4078823c406e3c94866f']
def snapshot():return {str(f.relative_to(root/'native-vendor')):hashlib.sha256(f.read_bytes()).hexdigest() for source in sources for f in sorted(source.rglob('*')) if f.is_file() and f.suffix in ('.h','.hpp','.m','.mm','.c','.cpp')}
before=snapshot();(out/'source-before.json').write_text(json.dumps(before,indent=2)+'\n');start=time.monotonic()
with (out/'build.log').open('w') as log:r=subprocess.run(['/usr/local/bin/cmake','--build',str(root/'build/moltenvk-bounded-archive'),'--target','MoltenVK','-j'+str(a.jobs)],stdout=log,stderr=subprocess.STDOUT,timeout=1200)
after=snapshot();changed=[k for k in set(before)|set(after) if before.get(k)!=after.get(k)];library=root/'build/moltenvk-bounded-archive/MoltenVK/libMoltenVK.1.4.2.dylib'
result={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'exitCode':r.returncode,'sourceStable':not changed,'changedDuringBuild':changed,'sourceFiles':len(after),'elapsedSeconds':time.monotonic()-start,'library':str(library),'librarySHA256':hashlib.sha256(library.read_bytes()).hexdigest(),'passed':r.returncode==0 and not changed,'gameStarted':False}
(out/'build-proof.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
