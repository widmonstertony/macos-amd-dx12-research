import pathlib,subprocess,json
root=pathlib.Path(__file__).resolve().parents[2];out=root/'evidence/full-forensics-v36-20261025'
cases=[('timing','evidence/stutter-coverage-cpu-20261025/timing_control.cpp'),('domain','evidence/cpu-detail-domain-fix-20261025/domain_control.cpp'),('unattributed','evidence/cpu-unattributed-shards-20261025/unattributed_control.cpp')]
rows=[]
for name,source in cases:
 folder=out/name;folder.mkdir(exist_ok=True);binary=folder/'control'
 with (folder/'build.stderr').open('w')as err:
  c=subprocess.run(['clang++','-std=c++17','-O2','-pthread','-DCPU_UNATTRIBUTED_BASELINE=0','-I'+str(root/'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects'),str(root/source),'-o',str(binary)],stderr=err)
 row={'case':name,'compileExit':c.returncode}
 if not c.returncode:
  p=subprocess.run([str(binary),str(folder)],capture_output=True,text=True,timeout=60);row['runExit']=p.returncode;(folder/'stdout').write_text(p.stdout);(folder/'stderr').write_text(p.stderr)
 rows.append(row)
(out/'existing-cpu-controls.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows))
raise SystemExit(0 if all(r.get('runExit')==0 for r in rows)else 1)
