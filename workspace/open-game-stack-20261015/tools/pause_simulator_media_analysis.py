#!/usr/bin/env python3
"""Use only after user approval: pause one simulator analyzer for <=10 minutes.

Never shuts down a simulator or deletes data. SIGTERM/interrupt and timeout
restore the same process, guarded against PID reuse.
"""
import argparse,datetime,json,os,pathlib,re,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--pid',type=int,required=True);p.add_argument('--label',required=True);a=p.parse_args()
r=pathlib.Path(__file__).resolve().parents[1]
assert a.pid>1 and re.fullmatch('[a-z0-9-]{1,64}',a.label)
def identity():
    comm=subprocess.check_output(['ps','-p',str(a.pid),'-o','comm='],text=True).strip()
    born=subprocess.check_output(['ps','-p',str(a.pid),'-o','lstart='],text=True).strip()
    return comm,born
original=identity()
assert '/CoreSimulator/' in original[0] and '.simruntime/' in original[0] and original[0].endswith('/MediaAnalysis.framework/mediaanalysisd')
stat=subprocess.check_output(['ps','-p',str(a.pid),'-o','stat='],text=True).strip();assert 'T'not in stat,'Target was already stopped'
out=r/'evidence'/a.label;out.mkdir(exist_ok=False)
def interrupt(signum,frame):raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupt);signal.signal(signal.SIGINT,interrupt)
stopped=False
try:
    os.kill(a.pid,signal.SIGSTOP);stopped=True
    start={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'targetPID':a.pid,'controllerPID':os.getpid(),'identity':original,'paused':True,'maxSeconds':600,'dataDeleted':False}
    (out/'start.json').write_text(json.dumps(start,indent=2));print(json.dumps(start),flush=True)
    with(out/'samples.jsonl').open('w')as f:
        for n in range(20):
            raw=subprocess.check_output(['pmset','-g','therm'],text=True)
            row={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'limits':{k:int(v)for k,v in re.findall(r'(CPU_\w+)\s*=\s*(\d+)',raw)}}
            f.write(json.dumps(row)+'\n');f.flush();time.sleep(30)
finally:
    resumed=False
    if stopped:
        try:
            if identity()==original:os.kill(a.pid,signal.SIGCONT);resumed=True
        except (ProcessLookupError,subprocess.CalledProcessError):pass
    end={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'targetPID':a.pid,'originalProcessResumeSent':resumed,'dataDeleted':False,'simulatorShutdown':False}
    (out/'resume.json').write_text(json.dumps(end,indent=2));print(json.dumps(end),flush=True)
