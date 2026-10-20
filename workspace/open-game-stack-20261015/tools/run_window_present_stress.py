#!/usr/bin/env python3
"""Use the original Tencent runtime without altering it or the live game."""
import ast
import datetime
import json
import os
from pathlib import Path
import subprocess
import shutil
import time
import sys
import qualify_late_guard as qualified

ROOT=qualified.ROOT
OUT=ROOT/'evidence/window-present-lock-20261019'
# Reuse exactly the qualified runtime configuration, without executing its
# main(), recreating links, or running its other probes.
tree=ast.parse((ROOT/'tools/qualify_late_guard.py').read_text())
main=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main')
update=next(n for n in main.body if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call)
            and isinstance(n.value.func,ast.Attribute) and n.value.func.attr=='update')
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','WINE','YYB_','VK_','VKD3D_','DXVK_','MVK_'))}
env.update(eval(compile(ast.Expression(update.value),'qualified-environment','eval'),qualified.__dict__|{'env':env}) or {})
results={}
for mode in (sys.argv[1:] or ('control','resize')):
    variant=mode.removeprefix('source-').removeprefix('prod-').removeprefix('original-').removeprefix('leaf-').removeprefix('protocol-')
    if variant in ('native-blocking','native-fixed'): variant='native'
    if variant in ('resize-blocking','resize-fixed'): variant='resize'
    out=OUT/mode
    out.mkdir(exist_ok=True)
    # Use the existing probe AppDefaults selection. Tencent's engine ignores
    # environment-only overrides for new executable names. No registry edits.
    executable={'device':'d3d12_probe.exe','compute':'d3d12_compute_probe.exe'}.get(variant,'d3d12_presentation_probe.exe')
    program=out/executable
    if variant in ('ui','ui32'):
        shutil.copy2(OUT/f'{variant}.exe',program)
    elif variant in ('device','compute'):
        shutil.copy2(Path('/private/tmp/yyb-probe-app')/executable,program)
    else:
        shutil.copy2(OUT/('control.exe' if variant in ('native','geometry') else f'{variant}.exe'),program)
    for dll in ('d3d12.dll','d3d12core.dll','dxgi.dll'):
        shutil.copy2(Path('/private/tmp/yyb-probe-app')/dll,out/dll)
    (out/'msl').mkdir(exist_ok=True)
    test_env=env|{'YYB_OPEN_GUARD_FORCE':'1','YYB_OPEN_GUARD_RECORD':str(out/'guard.trace'),
                  'MVK_CONFIG_SHADER_DUMP_DIR':str(out/'msl'),
                  'VKD3D_LOG_FILE':'Z:'+str(out/'vkd3d.log').replace('/Users/tonytan','').replace('/','\\')}
    if variant=='native':
        test_env['DYLD_INSERT_LIBRARIES']=str(OUT/'libPresentNativeResize.dylib')
    if variant=='geometry':
        test_env['DYLD_INSERT_LIBRARIES']=str(OUT/'libPresentGeometry.dylib')
        test_env['WINEDEBUG']='-all,+macdrv'
    if mode.startswith(('source-','prod-')):
        overlay=ROOT/'build/winemac-lockfix-overlay'
        test_env['WINEDLLPATH']=str(overlay)+':'+str(overlay/'x86_64-unix')+':'+str(overlay/'x86_64-windows')+':'+env['WINEDLLPATH']
        test_env['YYB_NTDLL_PATH']=str(overlay/'x86_64-unix/ntdll.so')
        test_env['WINE_MACDRV_LOCK_DIAGNOSTICS']='1'
        if mode in ('source-native-blocking','source-native-fixed'):
            test_env['WINE_MACDRV_TEST_RETAIN_FRAME_LOCK']='1'
        if mode=='source-native-blocking':
            test_env['WINE_MACDRV_TEST_BLOCKING_SURFACES']='1'
        if mode in ('source-resize-blocking','source-resize-fixed'):
            test_env['WINE_MACDRV_TEST_RETAIN_POSITION_LOCK']='1'
        if mode=='source-resize-blocking':
            test_env['WINE_MACDRV_TEST_BLOCKING_SURFACES']='1'
    if mode.startswith('leaf-'):
        test_env['DYLD_LIBRARY_PATH']=str(ROOT/'build/winemac-lockfix-leaf-select')+':'+env['DYLD_LIBRARY_PATH']
        test_env['WINE_MACDRV_LOCK_DIAGNOSTICS']='1'
    if mode.startswith('protocol-'):
        test_env['DYLD_LIBRARY_PATH']=str(ROOT/'build/winemac-lockfix-protocol-select')+':'+env['DYLD_LIBRARY_PATH']
        test_env['WINE_MACDRV_LOCK_DIAGNOSTICS']='1'
    start=time.monotonic()
    with (out/'stdout.log').open('w') as stdout,(out/'stderr.log').open('w') as stderr:
        p=subprocess.Popen([str(qualified.SUPPORT/'wine-loader'),str(program)],cwd=out,env=test_env,stdout=stdout,stderr=stderr,start_new_session=True)
        (out/'pid').write_text(str(p.pid))
        timeout=False
        try: code=p.wait(timeout=35)
        except subprocess.TimeoutExpired:
            timeout=True
            subprocess.run(['sample',str(p.pid),'2','10','-file',str(out/'hang-sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            subprocess.run([sys.executable,str(ROOT/'tools/inspect_wine_surface_deadlock.py'),str(p.pid),str(out/'lock-ownership.txt')],timeout=40,check=False)
            # Only the isolated probe is stopped; never touch Steam or game.
            p.terminate()
            try: code=p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill();code=p.wait(timeout=5)
    log=(out/'stdout.log').read_text(errors='replace')
    mapped=(out/'stderr.log').read_text(errors='replace')
    results[mode]={'pid':p.pid,'exitCode':code,'timeout':timeout,'seconds':round(time.monotonic()-start,2),
                   'realPixelsPassed':'presentation.backbuffer_pixels=4096 mismatches=0' in log,
                   'stressPassed':'presentation.gpu_api_result=PASS' in log,
                   'candidateMapped':str(qualified.CANDIDATE) in mapped}
    results[mode]['sourceWinemacMapped']=any(path in mapped for path in ('winemac-lockfix-overlay/x86_64-unix/winemac.so','winemac-lockfix-leaf-select/winemac.so','winemac-lockfix-protocol-select/winemac.so'))
    if variant=='geometry':
        results[mode]['nativeMetalCoversClient']='native_geometry.metal_covers_client=PASS' in mapped and 'native_geometry.metal_covers_client=FAIL' not in mapped
    results[mode]['postContentionPixelsPassed']='stress.after_contention_pixels=PASS' in log
    marker={'device':'copy_smoke.result=PASS','compute':'compute.result=PASS','ui':'window_ui.result=PASS','ui32':'ui32.result=PASS'}.get(variant,'presentation.gpu_api_result=PASS')
    results[mode]['actualOutputPassed']=code==0 and marker in log
    if variant=='geometry':
        results[mode]['actualOutputPassed'] = results[mode]['actualOutputPassed'] and results[mode]['nativeMetalCoversClient']
    print(json.dumps({mode:results[mode]}),flush=True)
    if timeout: break
summary={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'gamePIDPreserved':4103,'gameRestarted':False,'cacheDeleted':False,'results':results}
(OUT/('run-'+ '-'.join(sys.argv[1:])+'.json' if sys.argv[1:] else 'run.json')).write_text(json.dumps(summary,indent=2)+'\n')
