#!/usr/bin/env python3
"""Restart original Steam with its complete backend environment and request logs.

Tencent's native bridge was observed overriding WINEDEBUG with -all. A requested
setting is not proof of active tracing. Use the bounded Wine fault debugger when
the process-specific diagnostics are unavailable; do not keep restarting Steam.
"""
import ast,datetime,json,os,pathlib,subprocess,time,signal
import launch_stellar_deferred_proxy as qualified
root=qualified.ROOT;out=root/'evidence'/('steam-game-seh-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir();guard_record=out/'guard-proxy.trace'
rows=qualified.process_rows();assert not any('SB-Win64-Shipping.exe' in c for _,_,c in rows)
assert not any('sky.exe' in c.lower() or 'skylauncher' in c.lower() for _,_,c in rows)
steam=[(pid,c) for pid,_,c in rows if c.casefold()==str(qualified.STEAM).casefold()];assert len(steam)==1
old_pid,old_comm=steam[0]
tree=ast.parse((root/'tools/launch_stellar_deferred_proxy.py').read_text());main=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main');update=next(n for n in main.body if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Attribute) and isinstance(n.value.func.value,ast.Name) and n.value.func.value.id=='env' and n.value.func.attr=='update')
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','WINE','YYB_','VK_','VKD3D_','DXVK_','MVK_','SteamAppId','SteamGameId'))}
eval(compile(ast.Expression(update.value),'qualified-original-Steam-environment','eval'),qualified.__dict__|{'env':env,'out':out,'guard_record':guard_record})
setting='-all,SB-Win64-Shipping.exe:trace+seh,SB-Win64-Shipping.exe:err+vulkan';env['WINEDEBUG']=setting
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'oldSteamPID':old_pid,'WINEDEBUGRequested':setting,'exceptionLoggingVerified':False,'originalTencentNativeBridge':True,'wineserverStopped':False,'prefixChanged':False,'gameCachesDeleted':False,'clientRestarted':False}
with (out/'shutdown.stdout').open('w') as so,(out/'shutdown.stderr').open('w') as se:
 try:subprocess.run([str(qualified.SUPPORT/'wine-loader'),str(qualified.STEAM),'-shutdown'],cwd=qualified.STEAM.parent,env=env,stdout=so,stderr=se,timeout=15)
 except subprocess.TimeoutExpired:record['shutdownRequestTimedOut']=True
start=time.monotonic()
while time.monotonic()-start<30:
 if not any(pid==old_pid and c==old_comm for pid,_,c in qualified.process_rows()):break
 time.sleep(1)
else:
 assert any(pid==old_pid and c==old_comm for pid,_,c in qualified.process_rows());os.kill(old_pid,signal.SIGTERM);record['oldSteamSIGTERMSent']=True
 for _ in range(10):
  if not any(pid==old_pid for pid,_,_ in qualified.process_rows()):break
  time.sleep(1)
assert not any(c.casefold()==str(qualified.STEAM).casefold() for _,_,c in qualified.process_rows()),'Original Steam did not stop; no duplicate will be launched'
client_env=dict(env)
# Tencent's native launcher owns the Cocoa event pump and prepares its Wine
# internals itself. Standalone wine-loader cannot cold-start the Steam UI.
for name in ['WINEPREFIX','WINELOADER','WINESERVER','WINEDLLPATH','WINEDLLOVERRIDES','YYB_NTDLL_PATH','YYB_WINESERVER_HOST_APP']:
 client_env.pop(name,None)
with (out/'client.stdout').open('w') as so,(out/'client.stderr').open('w') as se:child=subprocess.Popen([str(qualified.CONTENTS/'MacOS/winelauncher'),str(qualified.STEAM)],cwd=qualified.STEAM.parent,env=client_env,stdin=subprocess.DEVNULL,stdout=so,stderr=se,start_new_session=True)
record['clientPID']=child.pid
for _ in range(60):
 found=[pid for pid,_,c in qualified.process_rows() if c.casefold()==str(qualified.STEAM).casefold()]
 if found:
  record['newSteamPIDs']=found
  time.sleep(20)
  record['clientRestarted']=any(pid==found[0] for pid,_,_ in qualified.process_rows())
  record['clientExitCode']=child.poll()
  break
 time.sleep(1)
(out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'directory':str(out),**record}),flush=True);raise SystemExit(0 if record['clientRestarted'] else 2)
