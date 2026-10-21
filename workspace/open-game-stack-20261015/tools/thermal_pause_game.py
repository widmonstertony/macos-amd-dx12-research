#!/usr/bin/env python3
"""Bounded, resumable load-reduction control for one verified game process."""
import argparse,datetime,json,os,pathlib,re,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--pid',type=int,required=True);p.add_argument('--label',required=True);a=p.parse_args()
r=pathlib.Path(__file__).resolve().parents[1]
assert re.fullmatch('[a-z0-9-]{1,64}',a.label) and a.pid>1
identity=subprocess.check_output(['ps','-p',str(a.pid),'-o','comm='],text=True).strip()
assert 'SB-Win64-Shipping.exe' in identity
out=r/'evidence'/a.label;out.mkdir(exist_ok=False)
def interrupt(signum,frame):raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupt);signal.signal(signal.SIGINT,interrupt)
stopped=False
try:
    os.kill(a.pid,signal.SIGSTOP);stopped=True
    print(json.dumps({'pid':a.pid,'paused':True,'resumeAfterSeconds':120,'cacheDeleted':False}),flush=True)
    with(out/'samples.jsonl').open('w')as f:
        for sample in range(9):
            raw=subprocess.check_output(['pmset','-g','therm'],text=True)
            state=json.loads(subprocess.check_output([str(r/'build/read-thermal-state')],text=True))
            state.update(timeUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),sample=sample,
                         limits={k:int(v)for k,v in re.findall(r'(CPU_\w+)\s*=\s*(\d+)',raw)})
            f.write(json.dumps(state)+'\n');f.flush()
            if sample<8:time.sleep(15)
finally:
    if stopped:
        try:os.kill(a.pid,signal.SIGCONT)
        except ProcessLookupError:pass
        record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'pid':a.pid,'resumeSent':True,'cacheDeleted':False,'powerSettingsChanged':False}
        (out/'resume.json').write_text(json.dumps(record,indent=2));print(json.dumps(record),flush=True)
