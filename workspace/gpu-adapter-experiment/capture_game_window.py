#!/usr/bin/env python3
"""Capture only the unique exact Steam-owned Stellar Blade window with existing permission."""
import subprocess,json,datetime
from pathlib import Path
project=Path(__file__).resolve().parent.parent
expected=r"Z:\Documents\GitHub\gptk-intel-research-20261011\SteamClient\steamapps\common\StellarBlade\SB\Binaries\Win64\SB-Win64-Shipping.exe"
rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True,errors='replace').splitlines()
pids=[int(l.strip().split(None,1)[0]) for l in rows if l.strip().split(None,1)[-1]==expected]
assert len(pids)==1,'No unique exact existing game process'
m=json.loads(subprocess.check_output([str(project/'gpu-adapter-experiment/game_window_metadata'),str(pids[0])],text=True))
assert m['screenCaptureAlreadyAllowed'],'Screen permission not already granted; do not request/bypass'
assert len(m['windows'])==1 and m['windows'][0]['ownerPID']==pids[0],'No unique exact game window'
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S');out=project/f'yyb-game-window-{stamp}.png'
subprocess.run(['/usr/sbin/screencapture','-x','-o','-l'+str(m['windows'][0]['id']),str(out)],check=True)
out.with_suffix('.json').write_text(json.dumps(m,indent=2)+'\n')
print(json.dumps({'path':str(out),'pid':pids[0],'scope':'Only exact game window; no desktop/login/other-app capture'}))
