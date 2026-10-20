#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Relocatable research-kit verification and native GPU tests; no game installer."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

ROOT=Path(__file__).resolve().parent


def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
    return digest.hexdigest()


def verify():
    manifest=json.loads((ROOT/'manifest.json').read_text())
    for item in manifest['files']:
        path=(ROOT/item['path']).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file() or sha(path)!=item['sha256']:
            raise RuntimeError('File verification failed: '+item['path'])
    for name,target in manifest.get('links',{}).items():
        link=ROOT/name
        if not link.is_symlink() or os.readlink(link)!=target or not link.resolve().is_relative_to(ROOT):
            raise RuntimeError('Library alias verification failed: '+name)
    return manifest


def doctor(manifest):
    report={'version':manifest['version'],'platform':platform.system(),
            'architecture':platform.machine(),'macOS':platform.mac_ver()[0],
            'testedGPU':manifest['testedGPU'],'testedOS':manifest['testedOS'],
            'gamePlayable':False,'scope':'Research diagnostics; not a ready-to-play game port',
            'nativeExecutionEligible':platform.system()=='Darwin' and platform.machine()=='x86_64'}
    print(json.dumps(report,indent=2))
    return 0 if report['nativeExecutionEligible'] else 2


def test(manifest,args):
    if platform.system()!='Darwin' or platform.machine()!='x86_64':
        raise RuntimeError('The shipped binaries require x86_64 macOS; other configurations are unverified')
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output=(args.output or Path.home()/'Library/Logs/AMDDX12Research'/stamp).resolve()
    output.mkdir(parents=True,exist_ok=False)
    rows=[]
    fixtures=['queue-probe']+(['queue-burst-probe'] if args.stress else [])
    for fixture in fixtures:
        for mode in ['default','specialized']:
            name=fixture+'-'+mode
            env={key:value for key,value in os.environ.items()
                 if not key.startswith(('DYLD_','VK_','MVK_','MTL_','WINE','YYB_','VKD3D_','DXVK_','GPU_'))}
            env.update(MTL_DEBUG_LAYER='1',MVK_CONFIG_LOG_LEVEL='2',MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',
                       MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES='1' if mode=='specialized' else '0')
            result=output/(name+'.json')
            with (output/(name+'.stdout.log')).open('w') as stdout,(output/(name+'.stderr.log')).open('w') as stderr:
                try:
                    process=subprocess.run([str(ROOT/'bin'/fixture),str(result)],env=env,
                                           stdout=stdout,stderr=stderr,timeout=20)
                    code=process.returncode
                except subprocess.TimeoutExpired:
                    code='bounded-timeout'
            measured=json.loads(result.read_text()) if result.is_file() and result.stat().st_size else {}
            row={'fixture':fixture,'mode':mode,'exitCode':code,'GPUResult':measured,
                 'passed':code==0 and measured.get('passed') is True}
            rows.append(row)
            print(json.dumps(row),flush=True)
            if not row['passed']:break
        if not rows[-1]['passed']:break
    report={'version':manifest['version'],'librarySHA256':sha(ROOT/'lib/libMoltenVK.dylib'),
            'results':rows,'passed':all(row['passed'] for row in rows),'gamePlayable':False,
            'gameStarted':False,'existingEnvironmentChanged':False,
            'limits':'Queue/readback checks only; do not establish shaders, rendering, FSR3, or game compatibility'}
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Report: '+str(output/'report.json'))
    return 0 if report['passed'] else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    sub.add_parser('verify');sub.add_parser('doctor')
    run=sub.add_parser('test');run.add_argument('--stress',action='store_true');run.add_argument('--output',type=Path)
    args=parser.parse_args()
    manifest=verify()
    if args.command=='verify':
        print(json.dumps({'verifiedFiles':len(manifest['files']),'version':manifest['version'],'gamePlayable':False}))
        return 0
    if args.command=='doctor':return doctor(manifest)
    return test(manifest,args)


if __name__=='__main__':
    try:sys.exit(main())
    except (RuntimeError,OSError,ValueError) as error:
        print('Error: '+str(error),file=sys.stderr);sys.exit(1)
