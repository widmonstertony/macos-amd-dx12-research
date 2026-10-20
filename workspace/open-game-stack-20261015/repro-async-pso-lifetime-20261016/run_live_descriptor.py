#!/usr/bin/env python3
"""Bounded A/B GPU checks of an encoder-scoped retained resource cache."""
import datetime, hashlib, json, os, pathlib, re, subprocess
here = pathlib.Path(__file__).resolve().parent
p = here.parent
lib = p/'build/moltenvk-compute-timing/MoltenVK/libMoltenVK.1.4.2.dylib'
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
dest = p/'evidence'/('live-descriptor-ab-'+stamp)
dest.mkdir()
icd = dest/'icd.json'
icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
rows = []
for enabled in (False, True):
    env = {k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','VKD3D_','MVK_','MTL_','GPU_ADAPTER_','R2_'))}
    env.update(VK_ICD_FILENAMES=str(icd), MTL_DEBUG_LAYER='1', MVK_CONFIG_LOG_LEVEL='2',
        MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1', MVK_AMD_REFERENCE_RBA2='1', MVK_AMD_REFERENCE_RIA2='1',
        MVK_AMD_REFERENCE_NULL='1', MVK_AMD_BYTE_GUARDS='1', MVK_AMD_COHERENT_ATOMICS='1',
        MVK_AMD_ENCODER_LIVE_CACHE='1' if enabled else '0', MVK_AMD_TRACE_LIVE_CACHE='1')
    label = 'enabled' if enabled else 'disabled'
    report = dest/(label+'.json')
    cmd = [str(here/'live_descriptor_gpu'), str(p/'build/probes/variable-array.spv'), str(report)]
    try:
        child = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=50)
        out, err, code = child.stdout, child.stderr, child.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors='replace') if isinstance(e.stdout, bytes) else e.stdout or ''
        err = e.stderr.decode(errors='replace') if isinstance(e.stderr, bytes) else e.stderr or ''
        code = -1
    (dest/(label+'.stdout.log')).write_text(out)
    (dest/(label+'.stderr.log')).write_text(err)
    stats = [tuple(map(int,m)) for m in re.findall(r'MVK_LIVE_CACHE enabled=(\d+) lookups=(\d+) reused=(\d+) retained=(\d+)',err)]
    result = json.loads(report.read_text()) if report.exists() else {}
    row = dict(enabled=enabled, exitCode=code, command=cmd, result=result,
        liveLookups=sum(x[1]for x in stats), reused=sum(x[2]for x in stats),
        maxRetained=max((x[3]for x in stats),default=0), statsCount=len(stats),
        metalValidationEnabled='Metal API Validation Enabled' in err)
    rows.append(row)
    print(json.dumps(row, indent=2), flush=True)
    if code or not result.get('passed'):
        print(err[-4000:]); break
passed = len(rows)==2 and all(r['result'].get('passed') and r['metalValidationEnabled'] and r['statsCount'] for r in rows)
passed = passed and rows[1]['liveLookups'] < rows[0]['liveLookups'] and rows[1]['reused'] > 0
summary = dict(library=str(lib), librarySHA256=hashlib.sha256(lib.read_bytes()).hexdigest(),
    gameStarted=False, rows=rows, passed=passed, scope='Synthetic descriptor alias workload; timings do not predict game FPS')
(dest/'run.json').write_text(json.dumps(summary,indent=2)+'\n')
print('Evidence:',dest)
raise SystemExit(0 if passed else 1)
