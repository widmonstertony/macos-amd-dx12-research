#!/usr/bin/env python3
"""Real GPU A/B, retained cache constant; only the recent lookup shortcut varies."""
import argparse, datetime, hashlib, json, os, pathlib, re, subprocess
parser = argparse.ArgumentParser()
parser.add_argument('--descriptor-cache', action='store_true')
args = parser.parse_args()
p = pathlib.Path(__file__).resolve().parent.parent
here = pathlib.Path(__file__).resolve().parent
lib = p/'build/moltenvk-compute-timing/MoltenVK/libMoltenVK.1.4.2.dylib'
dest = p/'evidence'/(('descriptor-table-ab-' if args.descriptor_cache else 'recent-descriptor-ab-')+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
dest.mkdir()
icd = dest/'icd.json'
icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
rows = []
for many_unused in (False, True):
    for enabled in (False, True):
        env = {k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','VKD3D_','MVK_','MTL_','GPU_ADAPTER_','R2_'))}
        env.update(VK_ICD_FILENAMES=str(icd), MTL_DEBUG_LAYER='1', MVK_CONFIG_LOG_LEVEL='2',
            MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1', MVK_AMD_REFERENCE_RBA2='1', MVK_AMD_REFERENCE_RIA2='1',
            MVK_AMD_REFERENCE_NULL='1', MVK_AMD_BYTE_GUARDS='1', MVK_AMD_COHERENT_ATOMICS='1',
            MVK_AMD_ENCODER_LIVE_CACHE='1', MVK_AMD_TRACE_LIVE_CACHE='1', MVK_AMD_LIVE_LOOKUP_FAST_CACHE='1' if enabled else '0')
        if many_unused: env['MVK_LIVE_STRESS_DEAD_ALIASES']='1'
        if args.descriptor_cache:
            env.update(MVK_AMD_LIVE_LOOKUP_FAST_CACHE='1',MVK_AMD_DESCRIPTOR_USE_CACHE='1' if enabled else '0',MVK_AMD_TRACE_DESCRIPTOR_CACHE='1')
        label = ('unused-' if many_unused else 'live-')+('on' if enabled else 'off')
        report = dest/(label+'.json')
        cmd = [str(here/'live_descriptor_gpu'),str(p/'build/probes/variable-array.spv'),str(report)]
        try:
            child = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=50)
            out, err, code = child.stdout, child.stderr, child.returncode
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b'').decode(errors='replace') if isinstance(e.stdout,bytes) else e.stdout or ''
            err = (e.stderr or b'').decode(errors='replace') if isinstance(e.stderr,bytes) else e.stderr or ''
            code = -1
        (dest/(label+'.stdout.log')).write_text(out)
        (dest/(label+'.stderr.log')).write_text(err)
        stats = [tuple(map(int,x)) for x in re.findall(r'MVK_LIVE_CACHE enabled=(\d+) lookups=(\d+) reused=(\d+) retained=(\d+)',err)]
        recent = [tuple(map(int,x)) for x in re.findall(r'MVK_LIVE_RECENT retainedHits=(\d+) absentHits=(\d+)',err)]
        tables = [tuple(map(int,x)) for x in re.findall(r'MVK_DESCRIPTOR_CACHE hits=(\d+) rebuilds=(\d+) invalidations=(\d+) scanned=(\d+) emitted=(\d+)',err)]
        row = dict(manyUnused=many_unused,enabled=enabled,exitCode=code,command=cmd,
            result=json.loads(report.read_text()) if report.exists() else {},
            liveLookups=sum(x[1] for x in stats),retainedHits=sum(x[0] for x in recent),absentHits=sum(x[1] for x in recent),
            tableCacheHits=sum(x[0] for x in tables),tableRebuilds=sum(x[1] for x in tables),tableScanned=sum(x[3] for x in tables),tableEmitted=sum(x[4] for x in tables),
            metalValidationEnabled='Metal API Validation Enabled' in err,validationErrors=bool(re.search(r'Validation Error|failed assertion',err,re.I)))
        rows.append(row)
        print(json.dumps(row),flush=True)
passed = len(rows)==4 and all(r['exitCode']==0 and r['result'].get('passed') and r['metalValidationEnabled'] and not r['validationErrors'] for r in rows)
if args.descriptor_cache:
    passed = passed and all(rows[i]['tableCacheHits']>0 and rows[i]['tableScanned']>rows[i]['tableEmitted'] for i in [1,3])
else:
    passed = passed and rows[1]['retainedHits']>0 and rows[3]['absentHits']>0 and rows[3]['liveLookups']<rows[2]['liveLookups']
summary = dict(library=str(lib),librarySHA256=hashlib.sha256(lib.read_bytes()).hexdigest(),descriptorCacheExperiment=args.descriptor_cache,gameStarted=False,rows=rows,passed=passed,scope='Synthetic descriptor aliases. Concurrent game remains on preserved older library; timings are not game FPS or an isolated system benchmark.')
(dest/'run.json').write_text(json.dumps(summary,indent=2)+'\n')
print('Evidence:',dest,flush=True)
raise SystemExit(0 if passed else 1)
