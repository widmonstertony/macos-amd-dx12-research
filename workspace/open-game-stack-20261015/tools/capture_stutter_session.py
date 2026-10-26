#!/usr/bin/env python3
"""One bounded observation session. The human alone launches/operates the game.

Only owned read-only observers and diagnostic marker files are controlled here.
No game/Steam/Wine launch, signal, input, cache edit or process-memory access.
"""
from __future__ import annotations
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import capture_stutter_system as system

ROOT=system.ROOT
ARM_ENV={'cpu':'MVK_AMD_STUTTER_CPU_ARM_PATH','native':'MVK_AMD_STUTTER_ARM_PATH',
         'gpu':'MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH','forensics':'MVK_AMD_FORENSICS_ARM_PATH'}
DEFAULT_MARKERS={'cpu':'cpu-stutter.arm','native':'gpu-counter.arm','gpu':'gpu-counter.arm','forensics':'forensics.arm'}


def owned(path):
    path=Path(path).resolve()
    if not path.is_relative_to(ROOT/'evidence'):raise ValueError('Session paths must be owned evidence paths')
    return path


def discover():
    result=system.command(['/bin/ps','-axo','pid=,comm='],max_chars=1024*1024)
    matches=[]
    for line in result.get('stdout','').splitlines():
        fields=line.strip().split(None,1)
        if len(fields)==2 and fields[0].isdigit() and fields[1].replace('\\','/').lower().endswith('/sb-win64-shipping.exe'):
            matches.append(int(fields[0]))
    return matches


def marker_paths(profile):
    text=(profile/'game-trial-config.h').read_text() if (profile/'game-trial-config.h').is_file() else ''
    paths={}
    for name,env in ARM_ENV.items():
        match=re.search(r'setenv\("'+env+r'",\s*("(?:\\.|[^"\\])*")',text)
        path=Path(json.loads(match.group(1))) if match else profile/DEFAULT_MARKERS[name]
        path=owned(path)
        if not path.is_relative_to(profile):raise ValueError('Arm path must stay in the selected profile')
        paths[name]=path
    return paths


def instrumentation_paths(profile,mode='all'):
    paths=marker_paths(profile)
    if mode=='all':return paths
    if mode=='forensics-only':return {'forensics':paths['forensics']}
    raise ValueError('Unknown instrumentation mode')


class MarkerLease:
    def __init__(self,paths):self.paths=paths;self.saved={};self.stamps={}
    def arm(self):
        for path in set(self.paths.values()):
            existed=path.exists();before=path.stat() if existed else None
            if existed and path.stat().st_size>4096:raise ValueError('Unexpected arm marker size')
            self.saved[path]=(before.st_atime_ns,before.st_mtime_ns) if before else None
            path.touch();self.stamps[path]=path.stat().st_mtime_ns
        return {name:{'path':str(path),'mtimeNS':self.stamps[path]} for name,path in self.paths.items()}
    def close(self):
        outcomes=[]
        for path,stamp in self.stamps.items():
            if not path.exists() or path.stat().st_mtime_ns!=stamp:
                outcomes.append(dict(path=str(path),restored=False,reason='externally-changed'));continue
            if self.saved[path] is None:path.unlink()
            else:os.utime(path,ns=self.saved[path])
            outcomes.append(dict(path=str(path),restored=True))
        self.stamps.clear();self.saved.clear();return outcomes


class WindowPolicy:
    """A pure state machine; GPU marker mtime stays fixed within each window."""
    def __init__(self,window=20,every=120,cooldown=6,maximum=20):
        self.window=window;self.every=every;self.cooldown=cooldown;self.maximum=maximum
        self.started=None;self.last_end=None;self.count=0;self.good=[]
    def observe(self,foreground):
        if foreground is not None:
            stamp=foreground.get('time');good=bool(foreground.get('foreground') and foreground.get('visible'))
            if isinstance(stamp,(int,float)) and (not self.good or stamp!=self.good[-1][0]):
                self.good.append((stamp,good));self.good=self.good[-3:]
    def poll(self,now,foreground=None,pinned=False,cf_now=None):
        self.observe(foreground)
        fresh=bool(self.good) and (cf_now is None or 0<=cf_now-self.good[-1][0]<=2.5)
        stable=fresh and len(self.good)==3 and all(g for _,g in self.good) and 0<self.good[-1][0]-self.good[0][0]<=5
        if self.started is not None and now-self.started>=self.window:
            self.started=None;self.last_end=now;return 'end'
        if self.started is not None or self.count>=self.maximum:return None
        due=self.last_end is None or now-self.last_end>=self.every
        cooled=self.last_end is None or now-self.last_end>=self.cooldown
        if cooled and (pinned or self.count==0 or due and stable):
            self.started=now;self.count+=1;return 'manual-pin' if pinned else 'startup' if self.count==1 else 'periodic-foreground'
        return None


class ForensicsSpool:
    """Follow four rolling slots; preserve complete original lines verbatim."""
    def __init__(self,pid,trace,out,max_bytes=64*1024**2,per_poll=4*1024**2,not_before_unix=0,minimum_mach_ns=0,namespace='forensics'):
        self.prefix=namespace
        self.pid=pid;self.trace=Path(trace);self.out=Path(out);self.max_bytes=max_bytes;self.per_poll=per_poll
        self.states={};self.seen=set();self.maximum=None;self.saved=0;self.capped=False;self.run_id=None;self.not_before_unix=not_before_unix;self.minimum_mach_ns=minimum_mach_ns
        self.targets={};self.index=self.out/(self.prefix+'-copy-index.jsonl')
        self.current_snapshots=self.out/(self.prefix+'-current-snapshots.jsonl');self.current_last=None
    def poll(self):
        if self.capped:return dict(savedBytes=self.saved,capped=True,events=[],rawPaths=[str(p) for p in self.targets.values()],rawLinesUnmodified=True)
        events=[];budget=min(self.per_poll,self.max_bytes-self.saved);observed=[]
        current=self.trace/f'{self.prefix}-current-{self.pid}.json';expected=None
        current_candidates=[]
        for path in self.trace.glob(f'{self.prefix}-current-{self.pid}-*.json'):
            try:
                if path.stat().st_mtime>=self.not_before_unix:current_candidates.append(path)
            except OSError:events.append(dict(status='unjoinable',reason='current-candidate-stat-failed'))
        if current_candidates:current=max(current_candidates,key=lambda p:p.stat().st_mtime)
        if current.is_file() and current.stat().st_mtime>=self.not_before_unix:
            try:
                raw=current.read_bytes();expected=json.loads(raw).get('runID')
                if raw!=self.current_last and raw.endswith(b'\n'):
                    with self.current_snapshots.open('ab') as stream:stream.write(raw)
                    self.current_last=raw
            except (ValueError,OSError):events.append(dict(status='unjoinable',reason='current-metadata-unavailable'))
        candidates=[]
        source_paths=[]
        for path in self.trace.glob(f'{self.prefix}-{self.pid}-*-*.jsonl'):
            try:
                if path.stat().st_mtime>=self.not_before_unix:source_paths.append(path)
            except OSError:events.append(dict(status='unjoinable',reason='candidate-stat-failed'))
        source_paths.sort(key=lambda p:p.name)
        if len(source_paths)>64:events.append(dict(status='capped',reason='source-candidate-file-cap',offered=len(source_paths),limit=64))
        for path in source_paths[:64]:
            try:slot=int(path.stem.rsplit('-',1)[-1]);stat=path.stat()
            except (ValueError,OSError):continue
            if slot not in range(4) or stat.st_mtime<self.not_before_unix:continue
            with path.open('rb') as stream:first=stream.readline(65537)
            try:header=json.loads(first)
            except (ValueError,UnicodeError):
                events.append(dict(slot=slot,status='unjoinable',reason='missing-complete-generation-header'));continue
            if header.get('type')!='clockCalibration' or header.get('schema')!=1:
                events.append(dict(slot=slot,status='unjoinable',reason='missing-generation-clock-header'));continue
            run=header.get('runID')
            if not isinstance(run,(int,str)) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}',str(run)):
                events.append(dict(slot=slot,status='unjoinable',reason='invalid-runID'));continue
            if header.get('machAfterNS',0)<self.minimum_mach_ns:continue
            if expected is not None and run!=expected:continue
            candidates.append((slot,path,stat,first,header))
        runs={item[4]['runID'] for item in candidates}
        if len(runs)>1:
            events.append(dict(status='unjoinable',reason='multiple-runIDs-without-current'));candidates=[]
        if runs and len(runs)==1 and self.run_id not in (None,next(iter(runs))):
            events.append(dict(status='missing',reason='native-runID-changed',previous=self.run_id));self.states={};self.seen=set();self.maximum=None
        if len(runs)==1:self.run_id=next(iter(runs))
        for slot,path,stat,first,header in candidates:
            generation=header.get('streamGeneration')
            if not isinstance(generation,int):
                events.append(dict(slot=slot,status='unjoinable',reason='missing-streamGeneration'));continue
            observed.append(generation);key=(stat.st_dev,stat.st_ino,header['runID'],generation)
            previous=self.states.get(slot);offset=previous['offset'] if previous and previous['key']==key else 0
            if previous and previous['key']!=key:
                if previous['offset']<previous['size']:events.append(dict(slot=slot,status='capped',reason='slot-overwritten-before-drain',lostAtLeastBytes=previous['size']-previous['offset']))
                else:events.append(dict(slot=slot,status='unjoinable',reason='rotated-final-tail-unobserved',previousGeneration=previous['key'][-1]))
            if stat.st_size<offset:offset=0;events.append(dict(slot=slot,status='missing',reason='same-generation-truncated'))
            if budget<=0:
                self.capped=self.saved>=self.max_bytes
                events.append(dict(slot=slot,status='capped',reason='copy-byte-budget' if self.capped else 'poll-byte-budget'))
                self.states[slot]=dict(key=key,offset=offset,size=stat.st_size);continue
            with path.open('rb') as stream:stream.seek(offset);data=stream.read(min(budget,stat.st_size-offset))
            end=data.rfind(b'\n')+1;complete=data[:end]
            if complete:
                # Re-check generation/inode after read; never mislabel overwritten data.
                current=path.stat()
                with path.open('rb') as stream:again=stream.readline(65537)
                if (current.st_dev,current.st_ino)!=(stat.st_dev,stat.st_ino) or again!=first:
                    events.append(dict(slot=slot,status='missing',reason='rotation-during-read'));continue
                target_path=self.targets.setdefault((header['runID'],generation,stat.st_ino),self.out/f'{self.prefix}-{self.pid}-run-{header["runID"]}-generation-{generation:08d}-inode-{stat.st_ino}.jsonl')
                with target_path.open('ab') as target:destination=target.tell();target.write(complete)
                events.append(dict(slot=slot,runID=header['runID'],streamGeneration=generation,inode=stat.st_ino,status='observed',destinationFile=target_path.name,sourceOffset=offset,bytes=len(complete),destinationOffset=destination))
                offset+=len(complete);self.saved+=len(complete);budget-=len(complete)
            elif data:
                total_remaining=self.max_bytes-self.saved
                if total_remaining<=self.per_poll and len(data)>=total_remaining:
                    self.capped=True
                    events.append(dict(slot=slot,status='capped',reason='copy-budget-cannot-fit-next-complete-line',remainingBytes=total_remaining,nextLineMinimumBytes=len(data)+1))
                elif len(data)>=self.per_poll:
                    events.append(dict(slot=slot,status='capped',reason='line-over-copy-window'))
            self.states[slot]=dict(key=key,offset=offset,size=stat.st_size)
        if observed:
            highest=max(observed)
            if self.maximum is not None:
                lo=self.maximum+1;known={g for g in set(observed)|self.seen if lo<=g<=highest}
                missing=[g for g in range(lo,min(highest+1,lo+64)) if g not in known]
                missing_count=max(0,highest-lo+1-len(known))
                if missing_count:events.append(dict(status='missing',reason='unobserved-stream-generations',generations=missing,missingCount=missing_count,truncated=missing_count>len(missing)))
            elif min(observed)>1:events.append(dict(status='missing',reason='prefix-before-collector',firstGeneration=min(observed)))
            self.maximum=highest if self.maximum is None else max(self.maximum,highest);self.seen.update(observed)
        if self.saved>=self.max_bytes:self.capped=True
        if events:
            with self.index.open('a') as target:
                for event in events:target.write(json.dumps(dict(pid=self.pid,namespace=self.prefix,timeCF=time.time()-system.CF_EPOCH,**event))+'\n')
        return dict(savedBytes=self.saved,capped=self.capped,events=events,rawPaths=[str(p) for p in self.targets.values()],rawLinesUnmodified=True)


class GuestSpool:
    def __init__(self,directory,out,max_bytes,not_before_unix):
        self.directory=Path(directory);self.out=out;self.max_bytes=max_bytes;self.not_before=not_before_unix
        self.children={};self.capped=False
    def poll(self):
        paths=[]
        for path in self.directory.glob('vkd3d-forensics-*-*-*.jsonl'):
            try:
                if path.stat().st_mtime>=self.not_before:paths.append(path)
            except OSError:continue
        for path in paths[:64]:
            match=re.match(r'vkd3d-forensics-(\d+)-',path.name)
            if match and path.stat().st_mtime>=self.not_before:
                pid=int(match.group(1))
                if pid not in self.children:self.children[pid]=ForensicsSpool(pid,self.directory,self.out,max_bytes=self.max_bytes,not_before_unix=self.not_before,namespace='vkd3d-forensics')
        results=[]
        for child in self.children.values():
            remaining=max(0,self.max_bytes-sum(c.saved for c in self.children.values()))
            child.max_bytes=min(child.max_bytes,child.saved+remaining)
            results.append(dict(guestPID=child.pid,**child.poll()))
        self.capped=any(c.capped for c in self.children.values())
        return dict(available=bool(self.children),capped=self.capped,guests=results,sourceCandidateFileCap=len(paths)>64,hostPIDJoin='unjoinable without a measured guest/host process map')
    def raw_paths(self):return [str(p) for c in self.children.values() for p in c.targets.values()]


class CPUSnapshotSpool:
    """Archive changed current/status bytes even after native history fills."""
    def __init__(self,pid,trace,out,max_bytes,not_before_unix=0):
        self.pid=pid;self.trace=trace;self.out=out;self.max_bytes=max_bytes;self.saved=0;self.last={};self.paths={};self.capped=False
        self.not_before_unix=not_before_unix
    def poll(self):
        events=[]
        for prefix in ('cpu-stutter-current','cpu-stutter-status'):
            path=self.trace/f'{prefix}-{self.pid}.json'
            if not path.is_file():continue
            try:
                state=path.stat()
                if state.st_mtime<self.not_before_unix:continue
                if state.st_size>self.max_bytes-self.saved:
                    self.capped=True;events.append(dict(status='capped',reason='cpu-current-copy-byte-budget',prefix=prefix));continue
                raw=path.read_bytes();json.loads(raw)
                if raw==self.last.get(prefix):continue
                if not raw.endswith(b'\n'):
                    events.append(dict(status='unjoinable',reason='incomplete-current-line',prefix=prefix));continue
                if self.saved+len(raw)>self.max_bytes:
                    self.capped=True;events.append(dict(status='capped',reason='cpu-current-copy-byte-budget',prefix=prefix));continue
                target=self.out/f'{prefix}-{self.pid}-snapshots.jsonl'
                with target.open('ab') as stream:offset=stream.tell();stream.write(raw)
                self.saved+=len(raw);self.last[prefix]=raw;self.paths[prefix]=target
                events.append(dict(status='observed',prefix=prefix,destinationFile=target.name,destinationOffset=offset,bytes=len(raw),sourceMtimeUnixNS=state.st_mtime_ns))
            except (OSError,ValueError):events.append(dict(status='unjoinable',reason='cpu-current-read-error',prefix=prefix))
        if events:
            with (self.out/'cpu-snapshot-copy-index.jsonl').open('a') as stream:
                for event in events:stream.write(json.dumps(dict(timeCF=time.time()-system.CF_EPOCH,**event))+'\n')
        return dict(savedBytes=self.saved,capped=self.capped,events=events,rawPaths=[str(p) for p in self.paths.values()],rawLinesUnmodified=True)


def latest_observer(path):
    if not path.is_file():return None
    with path.open('rb') as stream:stream.seek(max(0,path.stat().st_size-8192));lines=stream.read().split(b'\n')[:-1]
    if not lines:return None
    try:return json.loads(lines[-1])
    except ValueError:return None


def run(args):
    out=owned(args.output);profile=owned(args.profile)
    mode=getattr(args,'instrumentation_mode','all')
    if out.exists() or not profile.is_dir():raise ValueError('New session output and existing profile required')
    out.mkdir(parents=True);kernel=system.Kernel();begin=time.monotonic();initial=system.stamp(kernel)
    metadata=dict(schema=2,start=initial,timebase=kernel.timebase,target={},requestedSeconds=args.max_seconds,
        instrumentationMode=mode,intentionalCoverageGaps=(['CPU/GPU detailed arms are not held; runtime off state must be observed, never assumed from mode alone.'] if mode=='forensics-only' else []),
        userOwnsAllGameActions=True,targetLaunchStopOrInputUsed=False,profile=str(profile),observerIntervalSeconds=1,
        budgets=vars(args)|{'output':str(out),'profile':str(profile)})
    # Paths in argparse state are serialized explicitly, no process environment/auth.
    metadata['budgets']={k:str(v) if isinstance(v,Path) else v for k,v in metadata['budgets'].items()}
    target=None;original=None;usage0=None;previous_usage=None;previous_task=None;previous_threads=None;previous_system=0;previous_native=0
    reader=None;spool=None;guest_spool=None;cpu_spool=None;observer=None;observer_file=None;observer_chunks=[];foreground_seen=set();observer_offsets={};diagnostics_disabled=None;markers=None;policy=WindowPolicy(args.arm_seconds,args.arm_every,6,args.max_windows)
    status='bounded-complete';windows=[];current_window=None;last_front=None;rows=0;collection_total=0.;recent_costs=[];collector0=kernel.usage(os.getpid());last_clock=initial
    waiting_markers=None;waiting_refresh=0;waiting_record=None
    paths=instrumentation_paths(profile,mode);pin=owned(profile/args.pin_marker);owned_helpers=[]
    (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    try:
        with (out/'timeline.jsonl').open('x') as timeline,(out/'segments.jsonl').open('x') as segments,(out/'foreground.jsonl').open('x') as frontlog:
            waiting_markers=MarkerLease(paths);waiting_refresh=time.monotonic()
            waiting_record=dict(reason='waiting-for-user-launch',start=initial,arms=waiting_markers.arm(),preLaunchRefreshEverySeconds=15)
            print(json.dumps(dict(ready=True,waitingForUserGame=True,output=str(out),gameActions='human only',pinMarker=str(pin),preLaunchDiagnosticsArmed=True,instrumentationMode=mode)),flush=True)
            while time.monotonic()-begin<args.max_seconds:
                tick=time.monotonic();clock=system.stamp(kernel);last_clock=clock;row=dict(clock=clock,userOwnsAllGameActions=True)
                if shutil.disk_usage(ROOT).free<args.min_free_mib*1024**2:status='disk-reserve-stop';break
                if sum(p.stat().st_size for p in out.iterdir() if p.is_file())>=args.max_output_mib*1024**2:status='collector-output-cap';break
                if target is None:
                    if waiting_markers is not None and tick-waiting_refresh>=15:
                        waiting_record.update(end=clock,markerRestore=waiting_markers.close());segments.write(json.dumps(waiting_record)+'\n');segments.flush()
                        waiting_markers=MarkerLease(paths);waiting_refresh=tick;waiting_record=dict(reason='waiting-for-user-launch',start=clock,arms=waiting_markers.arm(),preLaunchRefreshEverySeconds=15)
                    matches=discover();row['gameDiscovery']=dict(matches=matches)
                    if len(matches)==1:
                        candidate=system.identity(matches[0])
                        if candidate.get('present'):
                            target=matches[0];original=candidate;usage0=kernel.usage(target);reader=system.NativeReader(target,profile/'msl',inventory_every=15)
                            start_ticks=usage0.get('processStartAbstime');scale=kernel.timebase['numer']/kernel.timebase['denom']
                            start_unix=clock['unixSeconds']-(clock['machAbsoluteTicks']-start_ticks)*scale/1e9 if start_ticks is not None else clock['unixSeconds']
                            spool=ForensicsSpool(target,profile/'msl',out,max_bytes=args.forensics_mib*1024**2,not_before_unix=start_unix-.2,minimum_mach_ns=int(start_ticks*scale) if start_ticks else 0)
                            cpu_spool=CPUSnapshotSpool(target,profile/'msl',out,args.cpu_current_mib*1024**2,start_unix-.2)
                            metadata.update(target=original,processStartAbstime=usage0.get('processStartAbstime'),processStartUnixEstimate=start_unix,processStartMachNS=int(start_ticks*scale) if start_ticks else None)
                            if args.d3d_directory:guest_spool=GuestSpool(owned(args.d3d_directory),out,args.guest_forensics_mib*1024**2,start_unix-.2)
                            (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
                            if waiting_markers is not None:
                                waiting_record.update(end=clock,markerRestore=waiting_markers.close(),targetObserved=target);segments.write(json.dumps(waiting_record)+'\n');segments.flush();waiting_markers=None
                    if target is None and tick-begin>=args.wait_seconds:status='user-start-wait-timeout';break
                if target is not None:
                    ident=system.identity(target);row.update(pid=target,identity=ident)
                    if ident.get('authoritativeMissing') or ident.get('state','').startswith('Z'):status='target-exited';row['terminal']=status
                    elif ident.get('present') and ident.get('lstart')!=original['lstart']:status='identity-changed';row['terminal']=status
                    usage=kernel.usage(target)
                    if usage.get('available') and usage0.get('processStartAbstime')!=usage.get('processStartAbstime'):status='kernel-start-identity-changed';row['terminal']=status
                    task=kernel.task(target);threads=kernel.threads(target,args.max_threads);row.update(usage=usage,task=task,threadCounters=threads,threadCPU=system.thread_delta(threads,previous_threads),usageDelta=system.delta(usage,previous_usage,('userTime','systemTime','diskBytesRead','diskBytesWritten','pageins')),
                        taskCounterDelta=system.delta(task,previous_task,('faults','pageins','cowFaults','machSyscalls','unixSyscalls','contextSwitches'),True))
                    previous_usage,previous_task,previous_threads=usage,task,threads
                    if observer is None or observer.poll() is not None:
                        observer_file=out/f'foreground-chunk-{len(observer_chunks):04d}.jsonl';observer_chunks.append(observer_file)
                        binary=ROOT/'build/probes/observe_game_activity'
                        if binary.is_file():
                            observer=subprocess.Popen([str(binary),str(target),'120',str(observer_file)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);owned_helpers.append(observer)
                    for chunk in observer_chunks:
                        if not chunk.is_file():continue
                        offset=observer_offsets.get(chunk,0)
                        with chunk.open('rb') as stream:stream.seek(offset);data=stream.read(65536)
                        complete=data[:data.rfind(b'\n')+1];observer_offsets[chunk]=offset+len(complete)
                        for line in complete.splitlines():
                            try:latest=json.loads(line)
                            except ValueError:continue
                            if latest.get('time') not in foreground_seen:
                                foreground_seen.add(latest['time']);frontlog.write(line.decode()+'\n');last_front=latest;policy.observe(latest)
                        frontlog.flush()
                    action=policy.poll(tick-begin,None,pin.exists(),cf_now=clock['CFAbsoluteTime']) if not diagnostics_disabled else None
                    if action=='end':
                        restored=markers.close() if markers else [];current_window.update(end=clock,markerRestore=restored);segments.write(json.dumps(current_window)+'\n');segments.flush();markers=None;current_window=None
                    elif action:
                        markers=MarkerLease(paths)
                        label_path=profile/'diagnostics.label';label=label_path.read_text()[:80].strip() if label_path.is_file() and label_path.stat().st_size<=512 else None
                        log_names=[f'cpu-stutter-{target}.jsonl',f'stutter-native-{target}.jsonl',f'gpu-counter-clock-sessions-{target}.jsonl']
                        offsets={name:(profile/'msl'/name).stat().st_size if (profile/'msl'/name).is_file() else None for name in log_names}
                        current_window=dict(index=policy.count,reason=action,userLabel=label,start=clock,arms=markers.arm(),logOffsetsBeforeArm=offsets,armPollLeadInSeconds=6,meaning='Requested marker window; actual native capture start/completion must be observed in logs');windows.append(current_window)
                    if tick-previous_native>=args.trace_every:
                        def remaining_output():return max(0,args.max_output_mib*1024**2-1024**2-sum(p.stat().st_size for p in out.iterdir() if p.is_file()))
                        row['native']=reader.read(clock['CFAbsoluteTime'])
                        spool.max_bytes=min(spool.max_bytes,spool.saved+remaining_output());row['forensicsCopy']=spool.poll()
                        cpu_spool.max_bytes=min(cpu_spool.max_bytes,cpu_spool.saved+remaining_output());row['cpuSnapshotCopy']=cpu_spool.poll();previous_native=tick
                        if guest_spool:
                            guest_spool.max_bytes=min(guest_spool.max_bytes,sum(c.saved for c in guest_spool.children.values())+remaining_output());row['guestForensicsCopy']=guest_spool.poll()
                        if (spool.capped or cpu_spool.capped or guest_spool and guest_spool.capped) and not diagnostics_disabled:
                            diagnostics_disabled='raw-diagnostic-copy-cap';row['diagnosticsDisabled']=diagnostics_disabled
                            if markers:
                                current_window.update(end=clock,markerRestore=markers.close(),endReason=diagnostics_disabled);segments.write(json.dumps(current_window)+'\n');segments.flush();markers=None;current_window=None
                if tick-previous_system>=args.system_every:row['system']=system.system_snapshot();row['diskFreeBytes']=shutil.disk_usage(ROOT).free;previous_system=tick
                elapsed=time.monotonic()-tick;collection_total+=elapsed;recent_costs.append((tick,elapsed));recent_costs=recent_costs[-30:];row['collectionSeconds']=elapsed;row['recentCollectionWallFraction']=sum(v for _,v in recent_costs)/max(args.interval,tick-recent_costs[0][0]+args.interval);row['collectorUsage']=kernel.usage(os.getpid());timeline.write(json.dumps(row,separators=(',',':'))+'\n');timeline.flush();rows+=1
                if row.get('terminal'):break
                if rows>=args.overhead_grace_rows and row['recentCollectionWallFraction']>args.max_collection_fraction:status='collection-overhead-cap';break
                time.sleep(max(0,args.interval-(time.monotonic()-tick)))
    except Exception as exc:
        status='collector-exception:'+type(exc).__name__
        raise
    finally:
        if waiting_markers:
            waiting_record.update(end=system.stamp(kernel),markerRestore=waiting_markers.close(),endReason=status)
            with (out/'segments.jsonl').open('a') as stream:stream.write(json.dumps(waiting_record)+'\n')
        if markers:
            restored=markers.close()
            if current_window:
                current_window.update(end=system.stamp(kernel),markerRestore=restored,endReason=status)
                with (out/'segments.jsonl').open('a') as stream:stream.write(json.dumps(current_window)+'\n')
        for helper in owned_helpers:
            if helper.poll() is None:helper.terminate();helper.wait(timeout=5)  # owned observer only
        summary=dict(status=status,rows=rows,target=original,captureStart=initial,lastObservation=last_clock,
            collectorUsageDelta=system.delta(kernel.usage(os.getpid()),collector0,('userTime','systemTime','childUserTime','childSystemTime','diskBytesRead','diskBytesWritten')),
            collectionSeconds=collection_total,windows=len(windows),userOwnsAllGameActions=True,
            instrumentationMode=mode,
            targetLaunchStopOrInputUsed=False,cachesPreserved=True,threadIDJoin='unjoinable: pthread handles are not native Mach IDs',
            rawLogsPreserved=True,diagnosticsDisabledReason=diagnostics_disabled,rawCPUCurrentPaths=[str(p) for p in cpu_spool.paths.values()] if cpu_spool else [],rawForensicsPaths=[str(p) for p in spool.targets.values()] if spool else [],rawGuestForensicsPaths=guest_spool.raw_paths() if guest_spool else [],
            rawLogReferences=[str(profile/'msl'/name) for name in [f'cpu-stutter-{target}.jsonl',f'stutter-native-{target}.jsonl',f'forensics-current-{target}.json'] if (profile/'msl'/name).exists()],limits=['Host polls are coarse. Marker edges do not prove GPU capture completion.','The collector output/free-space bounds cannot stop baseline native logging; only owned arms/helpers are released.','Forensics ring coverage is partial if overwritten, capped, unreadable or copied after generation changes.','No scene correctness/playable FPS/all-causes-found claim.'])
        (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    return summary


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--profile',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--instrumentation-mode',choices=('all','forensics-only'),default='all')
    p.add_argument('--max-seconds',type=int,default=1800);p.add_argument('--wait-seconds',type=int,default=300);p.add_argument('--interval',type=float,default=2);p.add_argument('--system-every',type=float,default=10);p.add_argument('--trace-every',type=float,default=2)
    p.add_argument('--arm-seconds',type=int,default=20);p.add_argument('--arm-every',type=int,default=120);p.add_argument('--max-windows',type=int,default=20);p.add_argument('--pin-marker',default='diagnostics.pin');p.add_argument('--max-threads',type=int,default=512)
    p.add_argument('--d3d-directory',type=Path);p.add_argument('--guest-forensics-mib',type=int,default=32)
    p.add_argument('--max-output-mib',type=int,default=192);p.add_argument('--forensics-mib',type=int,default=64);p.add_argument('--cpu-current-mib',type=int,default=64);p.add_argument('--min-free-mib',type=int,default=2048);p.add_argument('--max-collection-fraction',type=float,default=.35);p.add_argument('--overhead-grace-rows',type=int,default=15)
    a=p.parse_args()
    if not(30<=a.max_seconds<=3600 and 5<=a.wait_seconds<=a.max_seconds and 1<=a.interval<=10 and 5<=a.system_every<=60 and 1<=a.trace_every<=15 and 10<=a.arm_seconds<=45 and a.arm_every>=a.arm_seconds+6 and 1<=a.max_windows<=40 and 32<=a.max_threads<=1024 and 8<=a.max_output_mib<=256 and 4<=a.forensics_mib<=a.max_output_mib and a.min_free_mib>=512 and .05<=a.max_collection_fraction<=.5 and a.overhead_grace_rows>=5):p.error('Session bounds exceeded')
    if not 4<=a.cpu_current_mib<=128:p.error('CPU current budget exceeded')
    if a.forensics_mib+a.cpu_current_mib+(a.guest_forensics_mib if a.d3d_directory else 0)>a.max_output_mib-4:p.error('Raw stream budgets must leave at least4MiB for other collector data')
    if not 4<=a.guest_forensics_mib<=128:p.error('Guest stream budget exceeded')
    if Path(a.pin_marker).name!=a.pin_marker:p.error('Pin marker must be a basename inside profile')
    print(json.dumps(run(a),indent=2))
if __name__=='__main__':main()
