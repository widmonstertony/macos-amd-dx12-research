#!/usr/bin/env python3
"""Stage owned MoltenVK and unchanged asset-guard proxies; never deploy or launch."""
import argparse,datetime,hashlib,json,pathlib,re,shutil,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--resource-stats',action='store_true');p.add_argument('--snapshot-reuse',action='store_true');p.add_argument('--negative-cache',action='store_true');p.add_argument('--cross-snapshot-reuse',action='store_true');p.add_argument('--failure-context',action='store_true');a=p.parse_args()
if not re.fullmatch('[a-z0-9-]{1,64}',a.label):p.error('Safe label required')
evidence=ROOT/'evidence'/a.label;evidence.mkdir(exist_ok=False);(evidence/'msl').mkdir()
template=ROOT/'evidence/effective-submission-profile-20261020/game-trial-config.h'
config=template.read_text().replace(str(template.parent),str(evidence))
if a.cross_snapshot_reuse and not a.snapshot_reuse:p.error('Cross-encoder snapshot reuse requires snapshot reuse')
for name,value in [('MVK_AMD_QUEUE_FAILURE_CONTEXT',a.failure_context),('MVK_AMD_RESOURCE_USE_STATS',a.resource_stats),('MVK_AMD_DESCRIPTOR_SNAPSHOT_REUSE',a.snapshot_reuse),('MVK_AMD_NEGATIVE_LIVE_CACHE',a.negative_cache),('MVK_AMD_CROSS_ENCODER_SNAPSHOT_REUSE',a.cross_snapshot_reuse)]:
 config=config.replace('    setenv("MVK_AMD_QUEUE_TIMING"',f'    setenv("{name}", "{int(value)}", 1);\n    setenv("MVK_AMD_QUEUE_TIMING"')
header=evidence/'game-trial-config.h';header.write_text(config)
built=ROOT/'build/moltenvk-bounded-archive/MoltenVK/libMoltenVK.1.4.2.dylib'
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
records=[]
for kind in ['probe','game']:
 folder=ROOT/'build'/f'{a.label}-{kind}';folder.mkdir(exist_ok=False)
 candidate=folder/'libCandidate.dylib';shutil.copy2(built,candidate)
 proxy=folder/'libProbeGuard.dylib'
 cmd=['clang','-dynamiclib','-O2','-Wl,-headerpad_max_install_names',str(ROOT/'src/mvk_guard_proxy.c'),f'-DMVK_GUARD_CANDIDATE_PATH="{candidate}"','-Wl,-reexport_library,'+str(candidate),'-o',str(proxy)]
 if kind=='game':cmd.append(f'-DMVK_GUARD_GAME_CONFIG_HEADER="{header}"')
 subprocess.run(cmd,check=True)
 subprocess.run(['install_name_tool','-change','@rpath/libMoltenVK.1.dylib',str(candidate),str(proxy)],check=True)
 subprocess.run(['codesign','--force','--sign','-',str(proxy)],check=True)
 record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'candidate':str(candidate),'candidateSHA256':sha(candidate),'proxy':str(proxy),'proxySHA256':sha(proxy),'profileHeader':str(header) if kind=='game' else None,'resourceStatistics':a.resource_stats,'snapshotReuse':a.snapshot_reuse,'negativeCache':a.negative_cache,'crossEncoderSnapshotReuse':a.cross_snapshot_reuse,'failureContext':a.failure_context,'deployed':False}
 (folder/'build.json').write_text(json.dumps(record,indent=2)+'\n');records.append(record)
(evidence/'build.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(records,indent=2))
