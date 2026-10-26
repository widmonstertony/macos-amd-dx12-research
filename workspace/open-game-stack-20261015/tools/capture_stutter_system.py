#!/usr/bin/env python3
"""Bounded read-only stutter telemetry around one already-running native PID.

No game/Steam/Wine launch, input, registry, cache mutation, debugger injection,
process-memory read, authentication log, or target-process signal. Stack samples
and the existing window observer are optional owned helper processes. The only
launched target in --self-test is an explicitly owned non-game CPU/IO fixture.
"""
from __future__ import annotations
import argparse
import ctypes as C
import datetime as DT
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
from mac_session_state import session_state

ROOT=Path(__file__).resolve().parents[1]
CF_EPOCH=978307200.0


class ConfigurationTracker:
    """Hash only supplied owned configuration files; cache unchanged stat keys."""
    def __init__(self,paths=()):self.paths=tuple(map(Path,paths));self.cache={};self.last=None;self.generation=0
    def poll(self):
        files=[]
        for path in self.paths:
            try:
                state=path.stat();key=(state.st_dev,state.st_ino,state.st_size,state.st_mtime_ns)
                if path not in self.cache or self.cache[path][0]!=key:
                    record={'name':path.name,'available':True,'bytes':state.st_size,'mtimeUnixNS':state.st_mtime_ns,'inode':state.st_ino}
                    if state.st_size<=2*1024**2:
                        raw=path.read_bytes();after=path.stat()
                        if (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)!=key:record.update(available=False,reason='configuration-changed-during-read')
                        else:record['sha256']=hashlib.sha256(raw).hexdigest()
                    else:record.update(available=False,reason='configuration-over-2MiB')
                    self.cache[path]=(key,record)
                files.append(self.cache[path][1])
            except OSError:files.append({'name':path.name,'available':False,'reason':'configuration-unavailable'})
        canonical=[{key:row[key] for key in ('name','available','sha256','reason') if key in row} for row in files]
        digest=hashlib.sha256(json.dumps(canonical,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        if digest!=self.last:self.generation+=1;self.last=digest
        known=bool(files) and all(row.get('sha256') for row in files)
        return {'generation':self.generation,'sha256':digest,'known':known,'files':files,
                'scope':'Supplied configuration bytes only; effective game/runtime state is unmeasured.'}


def process_identity(record,kernel_start=None):
    known=record.get('present') is True and record.get('pid') is not None and bool(record.get('lstart'))
    values={'pid':record.get('pid'),'lstart':record.get('lstart'),'processStartAbstime':kernel_start}
    return values|{'known':known,'key':hashlib.sha256(json.dumps(values,sort_keys=True).encode()).hexdigest() if known else None,
                   'scope':'Observed PID plus process-start identity; no command arguments or environment.'}


class WindowIdentityTracker:
    """CGWindow IDs are scoped to a process generation, never to a drawable."""
    def __init__(self):self.current=None;self.generation=0
    def observe(self,foreground,process):
        wid=foreground.get('windowID') if foreground else None
        known=process.get('known') and type(wid) is int and wid>0 and foreground.get('matchedWindowExists',True)
        key=(process.get('key'),wid) if known else None
        if key is not None and key!=self.current:self.generation+=1;self.current=key
        return {'known':bool(known),'pid':process.get('pid'),'processKey':process.get('key'),'windowID':wid if known else None,
                'generation':self.generation if known else None,
                'key':hashlib.sha256(json.dumps(key).encode()).hexdigest() if known else None,
                'sourceObservationCFAbsoluteTime':foreground.get('time') if foreground else None,'currentWindowStateProved':False,
                'scope':'CGWindow identity only; ID reuse between polls, CAMetalLayer/drawable identity and physical display are unproved.'}


class DisplaySessionSampler:
    def __init__(self,every=2):self.every=every;self.next=0.;self.last=None
    def poll(self,clock):
        sampled=False
        if self.last is None or clock['monotonicSeconds']>=self.next:
            self.last=session_state();self.next=clock['monotonicSeconds']+self.every;sampled=True
        age=clock['unixSeconds']-self.last['observedUnixSeconds']
        return dict(self.last,observationAgeSeconds=age,sampledThisRow=sampled,
                    observationEndAgeSeconds=clock['unixSeconds']-self.last.get('observationEndUnixSeconds',self.last['observedUnixSeconds']),
                    carriedForwardContextOnly=not sampled,intervalStateProved=False)


def observer_cost(usage_delta,collection_seconds):
    return {'collectorCounterDelta':usage_delta,'collectionWallSeconds':collection_seconds,
            'interpretation':'Observer cost measured separately. Never subtract collector time or an estimated FPS from game measurements.'}


ACTION_LABELS=('stable','move','attack','equipment','nanosuit','present')


class HumanActionMarkers:
    """Observe an external whitelist file; never create or operate game input."""
    def __init__(self,path):self.path=Path(path) if path else None;self.last=None;self.sequence=0
    def poll(self,clock):
        if self.path is None:return None
        try:
            state=self.path.stat();key=(state.st_dev,state.st_ino,state.st_size,state.st_mtime_ns)
            if key==self.last:return None
            self.last=key
            if state.st_size>1024:return {'status':'unjoinable','reason':'action-marker-over-1024-bytes'}
            raw=self.path.read_bytes();after=self.path.stat()
            if (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)!=key:return {'status':'unjoinable','reason':'action-marker-changed-during-read'}
            value=json.loads(raw)
            if not isinstance(value,dict) or value.get('action') not in ACTION_LABELS or value.get('phase','start') not in ('start','end'):
                return {'status':'unjoinable','reason':'action-marker-outside-whitelist'}
            self.sequence+=1
            return {'status':'observed','sequence':self.sequence,'action':value['action'],'phase':value.get('phase','start'),
                    'markerMtimeUnixNS':state.st_mtime_ns,'markerMtimeCF':state.st_mtime-CF_EPOCH,
                    'observedClock':clock,'source':'external-human-label-file','gameActionVerified':False,'gameInputGenerated':False}
        except FileNotFoundError:return None
        except (OSError,ValueError):return {'status':'unjoinable','reason':'action-marker-unreadable-or-incomplete'}


def output_bytes(out):
    total=0
    for path in Path(out).rglob('*'):
        try:
            if path.is_file():total+=path.stat().st_size
        except OSError:pass
    return total

class TaskInfo(C.Structure):
    _fields_=[(n,C.c_uint64) for n in ('virtualSize','residentSize','totalUser','totalSystem','threadsUser','threadsSystem')]+[(n,C.c_int32) for n in ('policy','faults','pageins','cowFaults','messagesSent','messagesReceived','machSyscalls','unixSyscalls','contextSwitches','threadCount','runningThreads','priority')]
class ThreadInfo(C.Structure):
    _fields_=[('user',C.c_uint64),('system',C.c_uint64)]+[(n,C.c_int32) for n in ('cpuUsage','policy','runState','flags','sleepSeconds','currentPriority','priority','maximumPriority')]+[('name',C.c_char*64)]
class UsageInfo(C.Structure):
    _fields_=[('uuid',C.c_ubyte*16)]+[(n,C.c_uint64) for n in ('userTime','systemTime','packageIdleWakeups','interruptWakeups','pageins','wiredBytes','residentBytes','physicalFootprintBytes','processStartAbstime','processExitAbstime','childUserTime','childSystemTime','childPackageIdleWakeups','childInterruptWakeups','childPageins','childElapsedAbstime','diskBytesRead','diskBytesWritten')]
class Timebase(C.Structure):
    _fields_=[('numer',C.c_uint32),('denom',C.c_uint32)]

class Kernel:
    def __init__(self):
        self.lib=C.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        self.pidinfo=self.lib.proc_pidinfo;self.pidinfo.argtypes=[C.c_int,C.c_int,C.c_uint64,C.c_void_p,C.c_int];self.pidinfo.restype=C.c_int
        self.rusage=self.lib.proc_pid_rusage;self.rusage.argtypes=[C.c_int,C.c_int,C.c_void_p];self.rusage.restype=C.c_int
        self.system=C.CDLL('/usr/lib/libSystem.B.dylib')
        self.system.mach_absolute_time.restype=C.c_uint64
        tb=Timebase();self.system.mach_timebase_info(C.byref(tb));self.timebase={'numer':int(tb.numer),'denom':int(tb.denom)}
    def task(self,pid):
        obj=TaskInfo();n=self.pidinfo(pid,4,0,C.byref(obj),C.sizeof(obj))
        if n!=C.sizeof(obj):return {'available':False,'errno':C.get_errno(),'bytesReturned':n}
        unsigned={'faults','pageins','cowFaults','messagesSent','messagesReceived','machSyscalls','unixSyscalls','contextSwitches'}
        return {'available':True,**{k:(int(getattr(obj,k))&0xffffffff if k in unsigned else int(getattr(obj,k))) for k,_ in obj._fields_}}
    def usage(self,pid):
        obj=UsageInfo();rc=self.rusage(pid,2,C.byref(obj))
        if rc:return {'available':False,'errno':C.get_errno(),'returnCode':rc}
        return {'available':True,**{k:int(getattr(obj,k)) for k,_ in obj._fields_ if k!='uuid'}}
    def threads(self,pid,max_threads):
        ids=(C.c_uint64*max_threads)();n=self.pidinfo(pid,6,0,ids,C.sizeof(ids));result={}
        if n<=0:return {'available':False,'errno':C.get_errno(),'bytesReturned':n,'threads':{}}
        for handle in ids[:min(n//8,max_threads)]:
            obj=ThreadInfo();size=self.pidinfo(pid,5,handle,C.byref(obj),C.sizeof(obj))
            if size!=C.sizeof(obj):continue
            result[hex(handle)]={k:(getattr(obj,k).decode(errors='replace') if k=='name' else int(getattr(obj,k))) for k,_ in obj._fields_}
        return {'available':True,'listMayBeTruncated':n>=C.sizeof(ids),'threadCount':len(result),'threads':result,
                'identifierKind':'PROC_PIDLISTTHREADS opaque identifier / pthread handle',
                'nativeMachThreadJoin':'unjoinable without an independently measured mapping'}


def stamp(kernel=None):
    unix=time.time();return {'UTC':DT.datetime.fromtimestamp(unix,DT.timezone.utc).isoformat(),'unixSeconds':unix,'CFAbsoluteTime':unix-CF_EPOCH,'monotonicSeconds':time.monotonic(),'machAbsoluteTicks':int(kernel.system.mach_absolute_time()) if kernel else None}

def command(argv,timeout=3,max_chars=6000):
    begin=time.monotonic()
    try:
        p=subprocess.run(argv,text=True,capture_output=True,timeout=timeout,env=os.environ|{'LC_ALL':'C'})
        return {'command':argv,'exitCode':p.returncode,'elapsedSeconds':time.monotonic()-begin,'stdout':p.stdout[:max_chars],'stderr':p.stderr[:1000]}
    except (OSError,subprocess.TimeoutExpired) as ex:return {'command':argv,'available':False,'elapsedSeconds':time.monotonic()-begin,'error':type(ex).__name__+': '+str(ex)[:500]}

def identity(pid):
    p=command(['/bin/ps','-p',str(pid),'-o','lstart=','-o','stat=','-o','comm='])
    lines=p.get('stdout','').splitlines()
    if p.get('exitCode')==1 and not lines and not p.get('stderr'):return {'present':False,'authoritativeMissing':True}
    if p.get('exitCode')!=0 or not lines:return {'present':None,'observationFailure':p}
    line=lines[0].strip();match=re.match(r'(.+?\b\d{4})\s+(\S+)\s+(.+)',line)
    if not match:return {'present':None,'parseFailure':True}
    return {'present':True,'pid':pid,'lstart':match.group(1),'state':match.group(2),'comm':match.group(3)}

def delta(current,previous,keys,unsigned32=False):
    if not current.get('available') or not previous or not previous.get('available'):return {}
    return {k:((current[k]-previous[k])&0xffffffff if unsigned32 else current[k]-previous[k]) for k in keys if k in current and k in previous}

def thread_delta(now,before):
    rows=[];old=before.get('threads',{}) if before else {}
    for handle,row in now.get('threads',{}).items():
        if handle not in old:continue
        user=row['user']-old[handle]['user'];system=row['system']-old[handle]['system']
        if min(user,system)<0:continue
        rows.append({'handle':handle,'name':row['name'],'userCounterDelta':user,'systemCounterDelta':system,'totalCounterDelta':user+system,'runState':row['runState'],'sleepSeconds':row['sleepSeconds'],'priority':row['priority']})
    total=sum(r['totalCounterDelta'] for r in rows)
    for row in rows:row['fractionOfObservedExistingThreadCPU']=row['totalCounterDelta']/total if total else None
    rows.sort(key=lambda r:r['totalCounterDelta'],reverse=True)
    return {'totalExistingThreadCounterDelta':total,'rows':rows,'newThreadHandles':sorted(set(now.get('threads',{}))-set(old)),'exitedThreadHandles':sorted(set(old)-set(now.get('threads',{}))),'counterUnits':'raw kernel CPU counters; normalized fractions are unit-independent; exited-thread CPU is only covered by process totals',
            'identifierKind':'PROC_PIDLISTTHREADS opaque identifier / pthread handle','nativeMachThreadJoin':'unjoinable without an independently measured mapping'}

def host_cpu_snapshot():
    """Public aggregate host ticks; no other process memory or private data."""
    try:
        system=C.CDLL('/usr/lib/libSystem.B.dylib')
        system.mach_host_self.restype=C.c_uint32
        query=system.host_statistics
        query.argtypes=[C.c_uint32,C.c_int,C.c_void_p,C.POINTER(C.c_uint32)]
        query.restype=C.c_int
        ticks=(C.c_uint32*4)();count=C.c_uint32(4)
        code=query(system.mach_host_self(),3,C.byref(ticks),C.byref(count))
        return {'available':code==0 and count.value>=4,'returnCode':code,'logicalCPUs':os.cpu_count(),'loadAverage':list(os.getloadavg()),'ticks':dict(zip(('user','system','idle','nice'),map(int,ticks))),'units':'aggregate host scheduler ticks; use deltas, not raw percentages'}
    except (OSError,AttributeError) as ex:return {'available':False,'error':type(ex).__name__}

def system_snapshot():
    result={'hostCPU':host_cpu_snapshot()};v=command(['/usr/bin/vm_stat']);text=v.get('stdout','');page=re.search(r'page size of (\d+) bytes',text)
    result['vmStat']={'query':v,'pageSizeBytes':int(page.group(1)) if page else None,'counters':{m.group(1):int(m.group(2)) for m in re.finditer(r'^([^:\n]+):\s+(\d+)\.?\s*$',text,re.M)}}
    result['swapUsage']=command(['/usr/sbin/sysctl','vm.swapusage'])
    result['memoryPressureQuery']=command(['/usr/bin/memory_pressure','-Q'])
    result['rawPressureLevel']=command(['/usr/sbin/sysctl','kern.memorystatus_vm_pressure_level'])
    result['diskIO']=command(['/usr/sbin/iostat','-Id','-c','1'])
    result['thermalLimits']=command(['/usr/bin/pmset','-g','therm'])
    # comm only: no command arguments, environment, login state or auth data.
    related=command(['/bin/ps','-axo','pid=,ppid=,%cpu=,rss=,stat=,comm='],max_chars=1024*1024)
    keep=[];all_cpu=[]
    for line in related.get('stdout','').splitlines():
        m=re.match(r'\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(\S+)\s+(.+)',line)
        if m:all_cpu.append({'pid':int(m.group(1)),'OSReportedCPUPercent':float(m.group(3)),'residentKiB':int(m.group(4)),'comm':m.group(6)})
        if m and any(s in m.group(6).lower() for s in ('sb-win64-shipping.exe','/stellarblade/sb.exe','\\stellarblade\\sb.exe','wineserver','steam.exe','steamwebhelper.exe','steam_osx','steam helper','crs-handler.exe','winedbg.exe','werfault.exe','mtlcompilerservice')):
            keep.append({'pid':int(m.group(1)),'ppid':int(m.group(2)),'OSReportedCPUPercent':float(m.group(3)),'residentKiB':int(m.group(4)),'state':m.group(5),'comm':m.group(6)})
    result['topCPUProcesses']=sorted(all_cpu,key=lambda x:x['OSReportedCPUPercent'],reverse=True)[:16]
    result['topCPUProcessLimits']='OS ps CPU estimates only; not an exact same-window CPU share. Names and counters only; no arguments or file contents.'
    result['relatedProcesses']=keep
    result['relatedProcessQueryStatus']={k:related[k] for k in ('exitCode','elapsedSeconds','error') if k in related}
    return result


def file_meta(path):
    try:s=path.stat();return {'name':path.name,'bytes':s.st_size,'mtimeUnix':s.st_mtime,'mtimeCFAbsoluteTime':s.st_mtime-CF_EPOCH}
    except OSError as ex:return {'name':path.name,'available':False,'errno':ex.errno}

def numeric_json(path,cf_now):
    result=file_meta(path)
    try:
        if path.stat().st_size>2*1024*1024:return result|{'notRead':'over 2 MiB bounded payload limit'}
        if path.suffix=='.jsonl':
            with path.open('rb') as f:f.seek(max(0,path.stat().st_size-65536));lines=f.read().decode(errors='replace').splitlines()
            payload=None
            for line in reversed(lines[-3:]):
                try:payload=json.loads(line);break
                except ValueError:pass
            if payload is None:return result|{'transientReadError':'no complete trailing JSON record'}
        else:payload=json.loads(path.read_text())
        scalar={k:v for k,v in payload.items() if isinstance(v,(int,float,bool)) or v is None}
        result['numericFields']=scalar
        if isinstance(payload.get('time'),(float,int)):
            result['sourceCFAbsoluteTime']=payload['time'];result['sourceAgeSeconds']=cf_now-payload['time'];result['sourceFreshWithin15Seconds']=abs(result['sourceAgeSeconds'])<=15
        return result
    except (OSError,ValueError) as ex:return result|{'transientReadError':type(ex).__name__}

class NativeReader:
    def __init__(self,pid,trace,inventory_every=0):
        self.pid=pid;self.trace=trace;self.previous_counts=None;self.previous_faults=set()
        self.inventory_every=inventory_every;self.inventory_at=0;self.cached_inventory=None
    def read(self,cf_now):
        if not self.trace:return {'available':False,'reason':'no trace directory supplied'}
        if self.cached_inventory is not None and time.monotonic()-self.inventory_at<self.inventory_every:
            result=dict(self.cached_inventory)
            result['directoryInventoryAgeSeconds']=time.monotonic()-self.inventory_at
            result['fileCountDelta']=None
            result['newGPUTimeoutFiles']=[]
            if result.get('latestPresent',{}).get('name'):result['latestPresent']=numeric_json(self.trace/result['latestPresent']['name'],cf_now)
            result['queues']=[numeric_json(self.trace/name,cf_now) for name in result.pop('_queueNames',[])]
            for prefix in ('memory-current','resource-use-current','resource-use','residency-cost','shared-snapshot-stats','descriptor-dirty','heap-plan-stats','cpu-stutter-current','forensics-current'):
                for ext in ('.json','.jsonl'):
                    path=self.trace/f'{prefix}-{self.pid}{ext}'
                    if path.is_file():result[prefix]=numeric_json(path,cf_now)
            return result
        names=[];present_candidates=[];latest_present=None;latest_index=-1;counts={'MSLSources':0,'computeMapRecords':0,'slowCommandBuffers':0,'GPUTimeoutFiles':0};faults=[];queue=[];examined=0;inventory_capped=False
        try:
            with os.scandir(self.trace) as scan:
                for entry in scan:
                    examined+=1
                    if examined>100000:inventory_capped=True;break
                    name=entry.name
                    if name.startswith('source-') and name.endswith('.metal'):counts['MSLSources']+=1
                    if name.startswith(f'trace-compute-map-{self.pid}-'):counts['computeMapRecords']+=1
                    if name.startswith(f'trace-slow-command-buffer-{self.pid}-'):counts['slowCommandBuffers']+=1
                    if name.startswith(f'trace-gpu-timeout-{self.pid}-') and name.endswith('.json'):faults.append(Path(entry.path));counts['GPUTimeoutFiles']+=1
                    if name.startswith(f'queue-timing-current-{self.pid}-') and name.endswith('.json'):queue.append(Path(entry.path))
                    m=re.fullmatch(fr'trace-present-progress-{self.pid}-(\d+)\.json',name)
                    if m:
                        present_candidates.append(Path(entry.path))
                        if int(m.group(1))>latest_index:latest_index=int(m.group(1));latest_present=Path(entry.path)
        except OSError as ex:return {'available':False,'errno':ex.errno}
        result={'available':True,'directory':str(self.trace),'directoryInventoryEntriesExamined':min(examined,100000),'directoryInventoryCapped':inventory_capped,'queueSnapshotFileCap':len(queue)>16,'fileCounts':counts,'fileCountDelta':{k:counts[k]-self.previous_counts[k] for k in counts} if self.previous_counts else None,'queues':[numeric_json(p,cf_now) for p in sorted(queue)[:16]]}
        if latest_present:
            result['latestPresent']=numeric_json(latest_present,cf_now)
            # Counters are normally process-global. If a writer was recreated
            # with a lower sequence, select newer metadata rather than falsely
            # diagnosing a frozen present path from an old high filename.
            if not result['latestPresent'].get('sourceFreshWithin15Seconds',False):
                available=[p for p in present_candidates if p.is_file()]
                if available:
                    by_mtime=max(available,key=lambda p:file_meta(p).get('mtimeUnix',0))
                    if by_mtime!=latest_present:
                        alternate=numeric_json(by_mtime,cf_now)
                        if alternate.get('sourceCFAbsoluteTime',0)>result['latestPresent'].get('sourceCFAbsoluteTime',0):
                            result['latestPresent']=alternate;result['presentFilenameSequenceReused']=True
        for prefix in ('memory-current','resource-use-current','resource-use','residency-cost','shared-snapshot-stats','descriptor-dirty','heap-plan-stats','cpu-stutter-current','forensics-current'):
            for ext in ('.json','.jsonl'):
                p=self.trace/f'{prefix}-{self.pid}{ext}'
                if p.is_file():result[prefix]=numeric_json(p,cf_now)
        existing={p.name for p in faults};result['newGPUTimeoutFiles']=sorted(existing-self.previous_faults) if self.previous_counts else []
        result['faultFileMetadata']=[file_meta(p) for p in sorted(faults,key=lambda p:p.name)[-16:]]
        result['limits']='File growth proves observed progress only; no growth does not prove compilation stopped. JSONL writers may be capped; source age is authoritative. Numeric summary omits raw shaders, resource labels and fault payload details.'
        self.previous_faults=existing;self.previous_counts=counts
        self.inventory_at=time.monotonic();self.cached_inventory=dict(result,_queueNames=[p.name for p in sorted(queue)[:16]])
        return result

def crash_metadata(directories,started_unix,comm):
    # Metadata only; no crash contents, register dumps, login or reporter DB.
    stem=comm.replace('\\','/').rsplit('/',1)[-1].split('.')[0].lower()
    prefixes=tuple(x for x in (stem,'wine','stellarblade','sb-win64-shipping','crs-handler','steamwebhelper') if x)
    output=[]
    for directory in directories:
        scanned=0;matches=[]
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    scanned+=1
                    if scanned>10000:break
                    if entry.name.lower().startswith(prefixes) and entry.name.endswith(('.ips','.crash','.hang','.diag')):
                        meta=file_meta(Path(entry.path))
                        if meta.get('mtimeUnix',0)>=started_unix:matches.append(meta)
            output.append({'directory':str(directory),'newRelevantFiles':sorted(matches,key=lambda x:x.get('mtimeUnix',0))[-32:],'entryScanCapped':scanned>10000,'contentsRead':False})
        except OSError as ex:output.append({'directory':str(directory),'available':False,'errno':ex.errno})
    return output

class GraphicsLog:
    KEYS={'warnings':re.compile(rb'\bwarn(?:ing)?\b',re.I),'errors':re.compile(rb'\b(?:err|error|fatal)\b',re.I),'failures':re.compile(rb'\b(?:failed|failure)\b',re.I),'deviceLost':re.compile(rb'VK_ERROR_DEVICE_LOST|DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG',re.I),'memoryError':re.compile(rb'out of (?:video )?memory|VK_ERROR_OUT_OF_(?:DEVICE|HOST)_MEMORY',re.I),'pipelineOrLinkError':re.compile(rb'pipeline.{0,40}(?:failed|error)|link.{0,40}(?:failed|error)',re.I),'assertion':re.compile(rb'assertion failed|assert failed',re.I)}
    def __init__(self,path):self.path=path;self.offset=path.stat().st_size if path and path.is_file() else 0
    def read(self):
        if not self.path:return None
        if not self.path.is_file():return {'available':False,'name':self.path.name}
        size=self.path.stat().st_size;previous=self.offset
        if size<previous:previous=0
        start=max(previous,size-65536)
        with self.path.open('rb') as f:f.seek(start);data=f.read(65536)
        self.offset=size
        return {'name':self.path.name,'fileBytes':size,'newBytes':max(0,size-previous),'bytesSkippedToBound':max(0,start-previous),'newKeywordCounts':{k:len(v.findall(data)) for k,v in self.KEYS.items()},'rawLogContentSaved':False}


def capture(args):
    out=args.output.resolve()
    if not out.is_relative_to(ROOT/'evidence') or out.exists():raise ValueError('New output directory under owned evidence required')
    out.mkdir(parents=True);kernel=Kernel();original=identity(args.pid)
    if original.get('present') is not True:raise RuntimeError('Target identity unavailable: '+json.dumps(original))
    if args.lstart and original['lstart']!=args.lstart:raise RuntimeError('Expected PID+lstart does not match; no capture launched')
    normalized=original['comm'].replace('\\','/').lower()
    if not args.self_test and not (normalized.endswith('/sb-win64-shipping.exe') or '/stellarblade/sb.exe' in normalized):raise RuntimeError('This harness only targets the game; Steam/authentication processes are excluded')
    collector_usage0=kernel.usage(os.getpid());display_sampler=DisplaySessionSampler();configuration=ConfigurationTracker(getattr(args,'configuration',[]));action_markers=HumanActionMarkers(getattr(args,'action_marker',None));window_identity=WindowIdentityTracker()
    usage0=kernel.usage(args.pid);start_identity=usage0.get('processStartAbstime');clock0=stamp(kernel);offset0=clock0['unixSeconds']-clock0['monotonicSeconds']
    metadata={'schema':2,'start':clock0,'target':original,'processIdentity':process_identity(original,start_identity),'configuration':configuration.poll(),'processStartAbstime':start_identity,'timebase':kernel.timebase,'platform':platform.platform(),'requestedSeconds':args.seconds,'intervalSeconds':args.interval,'readOnlyTarget':True,'targetLaunchStopOrInputUsed':False,'processMemoryRead':False,'authDataRead':False,'cacheMutation':False,'rawCPUTimeUnits':'kernel counters retained raw; normalized existing-thread shares do not require a unit assumption','stackSamplingOptIn':args.stack_seconds>0,'limits':['No Windows guest stack unwinding or thread-to-Win32-ID mapping is promised. Native sample may show Wine/vkd3d symbols.','No per-process compressed-page count, allocation contents or hardware GPU counter data is collected.','Global VM/compression/swap counters do not identify one process as their cause. Disk iostat first-snapshot totals are system-wide, not target-only.','Read-only sampling has overhead; row collection durations and bounded native-stack windows are recorded.','Foreground observer reports host visibility only. Actual scene validation still requires user observation and native present timestamps. Active/CGWindowOnscreen do not establish physical display or lock state.','Missing observation is not target exit; only ps authoritative missing or PID start change ends capture.','Display/session metadata is a point snapshot; missing booleans are unknown and never retroactively prove a historical lock.']}
    (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    native=NativeReader(args.pid,args.trace_directory);graphics=GraphicsLog(args.graphics_log);helpers=[];stack_next=0.;stack_number=0
    observer=None
    if args.foreground:
        binary=ROOT/'build/probes/observe_game_activity'
        if binary.is_file():
            observer=subprocess.Popen([str(binary),str(args.pid),str(args.seconds),str(out/'foreground-raw.jsonl')],stdout=(out/'foreground.stdout').open('w'),stderr=(out/'foreground.stderr').open('w'));helpers.append(('foreground',observer))
        else:metadata['foregroundUnavailable']='existing observer binary absent'
    previous_task=None;previous_usage=None;previous_threads=None;previous_system=None;previous_related={};previous_host_cpu=None;system_next=0.;native_next=0.;last_system=None;last_native=None;rows=0;coverage={'usageSamples':0,'taskSamples':0,'threadSamples':0,'truncatedThreadLists':0,'nativePolls':0,'systemPolls':0};warnings=set();errors=[];status='bounded-complete';last_clock=clock0
    detail_disabled=None;observed_context=[];collection_total=0.;logger_total=0.;previous_logger_seconds=0.;reserve_bytes=min(4*1024**2,args.max_output_mib*1024**2//4)
    with (out/'timeline.jsonl').open('x') as f:
        deadline=time.monotonic()+args.seconds;next_sample=time.monotonic()
        while time.monotonic()<deadline:
            if time.monotonic()<next_sample:time.sleep(min(next_sample-time.monotonic(),args.interval))
            began=time.monotonic();clock=stamp(kernel);last_clock=clock;ident=identity(args.pid);config_begin=time.monotonic();config=configuration.poll();config_seconds=time.monotonic()-config_begin;display_begin=time.monotonic();display=display_sampler.poll(clock)
            row={'clock':clock,'pid':args.pid,'identity':ident,'clockOffsetDriftSeconds':clock['unixSeconds']-clock['monotonicSeconds']-offset0,
                'processIdentity':process_identity(ident,start_identity),'configuration':config,'displaySession':display,
                'observerCosts':{'configurationPollWallSeconds':config_seconds,'displaySessionPollWallSeconds':time.monotonic()-display_begin,'previousRowLoggerWallSeconds':previous_logger_seconds}}
            action_marker=action_markers.poll(clock)
            if action_marker:row['actionMarker']=action_marker
            if output_bytes(out)>=args.max_output_mib*1024**2-reserve_bytes:detail_disabled='detail-output-budget-reserved-for-telemetry-tail'
            if shutil.disk_usage(ROOT).free<getattr(args,'min_free_mib',2048)*1024**2:detail_disabled='disk-reserve-detail-stop'
            if detail_disabled:row['detailUndercoverage']=detail_disabled
            if ident.get('authoritativeMissing'):row['terminal']='target-no-longer-present';status='target-exited'
            elif ident.get('present') and ident['lstart']!=original['lstart']:row['terminal']='PID-reused-or-start-changed';status='identity-changed'
            elif ident.get('present') and ident.get('state','').startswith('Z'):row['terminal']='kernel-zombie-exited';status='target-exited'
            if 'terminal' not in row:
                process_sample_begin=time.monotonic()
                usage=kernel.usage(args.pid);task=kernel.task(args.pid);threads=kernel.threads(args.pid,args.max_threads) if not detail_disabled else {'available':False,'reason':detail_disabled,'threads':{}}
                if usage.get('available') and usage.get('processExitAbstime',0):row['terminal']='kernel-process-exited';status='target-exited'
                if usage.get('available') and start_identity is not None and usage['processStartAbstime']!=start_identity:row['terminal']='kernel-process-start-changed';status='identity-changed'
                row.update(usage=usage,task=task,threadCounters=threads,threadCPU=thread_delta(threads,previous_threads))
                coverage['usageSamples']+=bool(usage.get('available'));coverage['taskSamples']+=bool(task.get('available'));coverage['threadSamples']+=bool(threads.get('available'));coverage['truncatedThreadLists']+=bool(threads.get('listMayBeTruncated'))
                if not usage.get('available'):warnings.add('some-process-rusage-observations-unavailable')
                if not task.get('available'):warnings.add('some-task-observations-unavailable')
                if not threads.get('available'):warnings.add('some-thread-observations-unavailable')
                row['usageDelta']=delta(usage,previous_usage,('userTime','systemTime','pageins','diskBytesRead','diskBytesWritten','packageIdleWakeups','interruptWakeups'))
                row['taskCounterDelta']=delta(task,previous_task,('faults','pageins','cowFaults','machSyscalls','unixSyscalls','contextSwitches'),True)
                previous_task,previous_usage,previous_threads=task,usage,threads
                row['observerCosts']['processSamplerWallSeconds']=time.monotonic()-process_sample_begin
            now=time.monotonic()
            if now>=system_next and not detail_disabled:
                system_poll_begin=time.monotonic()
                coverage['systemPolls']+=1;last_system=system_snapshot()
                host_cpu=last_system.get('hostCPU',{})
                if host_cpu.get('available') and previous_host_cpu and previous_host_cpu.get('available'):
                    ticks={k:(host_cpu['ticks'][k]-previous_host_cpu['ticks'][k])&0xffffffff for k in host_cpu['ticks']}
                    total=sum(ticks.values());last_system['hostCPUInterval']={'tickDeltas':ticks,'busyFraction':(total-ticks['idle'])/total if total else None,'limits':'Global host load only; cannot attribute all load to game.'}
                previous_host_cpu=host_cpu
                for related in last_system.get('relatedProcesses',[]):
                    current=kernel.usage(related['pid']);prior=previous_related.get(related['pid']);related['usage']=current
                    if prior and prior.get('processStartAbstime')==current.get('processStartAbstime'):
                        related['usageDelta']=delta(current,prior,('userTime','systemTime','diskBytesRead','diskBytesWritten','pageins'))
                    previous_related[related['pid']]=current
                vm=last_system.get('vmStat',{}).get('counters',{});last_system['vmCounterDelta']={k:v-previous_system.get(k,v) for k,v in vm.items()} if previous_system else None;previous_system=vm;row['system']=last_system;system_next=now+args.system_every
                row['diskFreeBytes']=shutil.disk_usage(ROOT).free
                row['observerCosts']['hostSystemPollWallSeconds']=time.monotonic()-system_poll_begin
            if now>=native_next and not detail_disabled:
                native_poll_begin=time.monotonic()
                coverage['nativePolls']+=1;last_native=native.read(clock['CFAbsoluteTime']);row['native']=last_native
                for key,value in last_native.items():
                    if isinstance(value,dict) and value.get('sourceFreshWithin15Seconds') is False:warnings.add('stale-native-source:'+key)
                for q in last_native.get('queues',[]):
                    if q.get('sourceFreshWithin15Seconds') is False:warnings.add('stale-native-queue:'+q.get('name','unknown'))
                g=graphics.read()
                if g is not None:row['graphicsLog']=g
                row['cacheFiles']=[file_meta(p) for p in args.cache_path]
                row['crashArtifacts']=crash_metadata(args.crash_directory,clock0['unixSeconds'],original['comm'])
                native_next=now+args.trace_every
                row['observerCosts']['nativePollWallSeconds']=time.monotonic()-native_poll_begin
            sample_guard=identity(args.pid) if not detail_disabled and args.stack_seconds and stack_number<args.max_stack_bursts and now>=stack_next and 'terminal' not in row else None
            if sample_guard and sample_guard.get('present') and sample_guard.get('lstart')==original['lstart'] and not sample_guard.get('state','').startswith('Z'):
                path=out/f'sample-{args.pid}-{stack_number:02d}.txt';record={'path':path.name,'start':stamp(kernel),'seconds':args.stack_seconds,'intervalMilliseconds':args.stack_interval_ms};
                with (out/f'sample-{stack_number:02d}.stdout').open('w') as stdout,(out/f'sample-{stack_number:02d}.stderr').open('w') as stderr:
                    child=subprocess.Popen(['/usr/bin/sample',str(args.pid),str(args.stack_seconds),str(args.stack_interval_ms),'-file',str(path)],stdout=stdout,stderr=stderr)
                record['helperPID']=child.pid;helpers.append((record,child));row['stackSampleStarted']=record;stack_number+=1;stack_next=now+args.stack_every
            # Bound helper output too, never the target. Only Popen handles
            # created by this capture can be stopped on a diagnostic quota.
            for name,helper in helpers:
                if isinstance(name,dict) and helper.poll() is None:
                    sample_path=out/name['path']
                    if sample_path.is_file() and sample_path.stat().st_size>24*1024**2:
                        name['stoppedForOwnedSampleFileLimit']=True;helper.terminate()
            row['collectionSeconds']=time.monotonic()-began;collection_total+=row['collectionSeconds'];observed_context.append({'clock':clock,'processIdentity':row['processIdentity'],'configuration':row['configuration'],'displaySession':row['displaySession']})
            logger_begin=time.monotonic();f.write(json.dumps(row,separators=(',',':'))+'\n');f.flush();previous_logger_seconds=time.monotonic()-logger_begin;logger_total+=previous_logger_seconds;rows+=1
            if row.get('terminal'):break
            next_sample=max(next_sample+args.interval,time.monotonic())
    helper_results=[]
    for name,helper in helpers:
        if name=='foreground' and helper.poll() is None:
            try:helper.wait(timeout=2)
            except subprocess.TimeoutExpired:helper.terminate();helper.wait(timeout=3)
        elif helper.poll() is None:
            try:helper.wait(timeout=args.stack_seconds+5)
            except subprocess.TimeoutExpired:helper.terminate();helper.wait(timeout=3)
        result={'helper':name,'exitCode':helper.returncode}
        if isinstance(name,dict):
            p=out/name['path'];text=p.read_text(errors='replace') if p.is_file() and p.stat().st_size<=24*1024**2 else '';result['waitSymbolsPresent']=[s for s in ('__psynch_cvwait','__psynch_mutexwait','semaphore_wait_trap','mach_msg2_trap','__ulock_wait','wine_server_call','WaitForMultipleObjects','kevent') if s in text];result['end']=stamp(kernel)
        helper_results.append(result)
    # Preserve native observer bytes separately; enrichment is an explicitly
    # contextual merged copy, never a claim that a later snapshot was historical.
    raw_foreground=out/'foreground-raw.jsonl'
    if raw_foreground.is_file() and raw_foreground.stat().st_size<=8*1024**2:
        with raw_foreground.open() as source,(out/'foreground.jsonl').open('x') as merged:
            for number,line in enumerate(source,1):
                try:front=json.loads(line)
                except ValueError:continue
                context=min(observed_context,key=lambda row:abs(row['clock']['CFAbsoluteTime']-front.get('time',0))) if observed_context else None
                if context:
                    front.update(processIdentity=context['processIdentity'],configuration=context['configuration'],displaySessionContext=context['displaySession'],contextClock=context['clock'],contextOnlyNotIntervalProof=True,
                                 displaySessionContextMinusWindowSeconds=context['displaySession']['observedUnixSeconds']-front.get('time',0)-CF_EPOCH,
                                 windowIdentity=window_identity.observe(front,context['processIdentity']),rawSource={'file':raw_foreground.name,'line':number})
                merged.write(json.dumps(front,separators=(',',':'))+'\n')
    collector_usage1=kernel.usage(os.getpid());cost_delta=delta(collector_usage1,collector_usage0,('userTime','systemTime','childUserTime','childSystemTime','diskBytesRead','diskBytesWritten'))
    summary={'coverage':coverage,'observabilityWarnings':sorted(warnings),'collectorUsageDelta':cost_delta,'observerCost':observer_cost(cost_delta,collection_total)|{'timelineLoggerWallSeconds':logger_total},'detailUndercoverage':detail_disabled,'outputBytes':output_bytes(out),'telemetryReserveBytes':reserve_bytes,'status':status,'target':original,'captureStart':clock0,'lastObservation':last_clock,'rows':rows,'helperResults':helper_results,'targetModified':False,'cachesPreserved':True,'actualGPUWorkExecutedByHarness':False,'errors':errors}
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');(out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n');return summary


def self_test(args):
    out=args.output.resolve()
    if not out.is_relative_to(ROOT/'evidence') or out.exists():raise ValueError('New self-test output under owned evidence required')
    fixture=out.with_name(out.name+'-fixture')
    if fixture.exists():raise ValueError('Self-test fixture directory already exists')
    fixture.mkdir(parents=True)
    script=fixture/'owned_cpu_io.py';script.write_text('''import pathlib,time,threading,json,os\nr=pathlib.Path(__file__).parent;r.joinpath('ready').write_text(str(os.getpid()));time.sleep(.7);memory=bytearray(32*1024*1024);stop=time.monotonic()+5\ndef worker():\n n=0\n while time.monotonic()<stop:\n  n=(n+7919)%10000019\nthread=threading.Thread(target=worker,name='fixture-cpu');thread.start()\nwith (r/'owned-io.bin').open('wb',buffering=0) as f:\n while time.monotonic()<stop:\n  f.write(memory[:65536]);f.flush();os.fsync(f.fileno());time.sleep(.2)\nthread.join()\n''')
    child=subprocess.Popen([sys.executable,str(script)],stdout=(fixture/'stdout').open('w'),stderr=(fixture/'stderr').open('w'))
    limit=time.monotonic()+3
    while not (fixture/'ready').is_file() and child.poll() is None and time.monotonic()<limit:time.sleep(.01)
    if not (fixture/'ready').is_file():raise RuntimeError('Owned fixture did not start')
    args.pid=child.pid;args.seconds=9;args.interval=1.;args.system_every=3.;args.trace_every=2.;args.foreground=False;args.stack_seconds=1;args.stack_every=30.;args.max_stack_bursts=1;args.trace_directory=None;args.graphics_log=None;args.cache_path=[];args.crash_directory=[];args.lstart=None
    result=capture(args);child.wait(timeout=5);rows=[json.loads(l) for l in (out/'timeline.jsonl').read_text().splitlines()];cpu=sum(sum(x.get('usageDelta',{}).get(k,0) for k in ('userTime','systemTime')) for x in rows);faults=sum(x.get('taskCounterDelta',{}).get('faults',0) for x in rows);disk=sum(x.get('usageDelta',{}).get('diskBytesWritten',0) for x in rows);thread=sum(x.get('threadCPU',{}).get('totalExistingThreadCounterDelta',0) for x in rows)
    checks={'hostAggregateCPUAvailable':all(r.get('system',{}).get('hostCPU',{}).get('available',True) for r in rows),'hostCPUIntervalObserved':any(r.get('system',{}).get('hostCPUInterval',{}).get('busyFraction') is not None for r in rows),'ownedNonGameTarget':str(script).endswith('owned_cpu_io.py'),'samplesAtLeast3':len(rows)>=3 and result['coverage']['usageSamples']>=3 and result['coverage']['threadSamples']>=3,'positiveProcessCPUCounterDelta':cpu>0,'positiveThreadCPUCounterDelta':thread>0,'positivePageFaultDelta':faults>0,'positiveDiskWriteCounterDelta':disk>0,'naturalExitObserved':result['status']=='target-exited','UTC_CF_MonotonicRecorded':all(all(k in x['clock'] for k in ('UTC','CFAbsoluteTime','monotonicSeconds','machAbsoluteTicks')) and abs(x['clock']['unixSeconds']-x['clock']['CFAbsoluteTime']-CF_EPOCH)<1e-6 for x in rows) and all(a['clock']['monotonicSeconds']<=b['clock']['monotonicSeconds'] for a,b in zip(rows,rows[1:])),'noGPUWork':result['actualGPUWorkExecutedByHarness'] is False,'nativeStackSampleSucceeded':any(isinstance(h['helper'],dict) and h['exitCode']==0 for h in result['helperResults'])}
    parser_dir=fixture/'synthetic-parser-only';parser_dir.mkdir();cf=time.time()-CF_EPOCH
    (parser_dir/f'queue-timing-current-{child.pid}-0-0.json').write_text(json.dumps({'time':cf,'hostPrecommitTotalMS':1,'syntheticParserFixtureOnly':True,'nonNumericSentinel':'must not be retained'}))
    (parser_dir/f'resource-use-{child.pid}.jsonl').write_text(json.dumps({'time':cf-120,'calls':7,'syntheticParserFixtureOnly':True})+'\n')
    reader=NativeReader(child.pid,parser_dir);initial=reader.read(cf)
    (parser_dir/f'trace-gpu-timeout-{child.pid}-0.json').write_text('{}')
    later=reader.read(cf);checks['syntheticParserFreshnessAndPrivacy']=initial['queues'][0]['sourceFreshWithin15Seconds'] is True and initial['resource-use']['sourceFreshWithin15Seconds'] is False and 'nonNumericSentinel' not in initial['queues'][0]['numericFields']
    checks['syntheticNewFaultFilenameDetection']=later['newGPUTimeoutFiles']==[f'trace-gpu-timeout-{child.pid}-0.json']
    (out/'synthetic-parser-control.json').write_text(json.dumps({'syntheticParserFixtureOnly':True,'actualGPUWorkExecuted':False,'initial':initial,'later':later},indent=2)+'\n')
    report={'checks':checks,'processCPUCounterDelta':cpu,'existingThreadCPUCounterDelta':thread,'pageFaultDelta':faults,'processDiskBytesWrittenDelta':disk,'actualGameTested':False,'actualGPUWorkExecuted':False,'passed':all(checks.values())};(out/'self-test.json').write_text(json.dumps(report,indent=2)+'\n');return report


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--pid',type=int);p.add_argument('--lstart');p.add_argument('--output',type=Path,required=True);p.add_argument('--seconds',type=int,default=60);p.add_argument('--interval',type=float,default=1);p.add_argument('--system-every',type=float,default=5);p.add_argument('--trace-every',type=float,default=2);p.add_argument('--max-threads',type=int,default=1024);p.add_argument('--trace-directory',type=Path);p.add_argument('--cache-path',type=Path,action='append',default=[]);p.add_argument('--graphics-log',type=Path);p.add_argument('--crash-directory',type=Path,action='append',default=[]);p.add_argument('--foreground',action='store_true');p.add_argument('--stack-seconds',type=int,default=0);p.add_argument('--stack-every',type=float,default=30);p.add_argument('--stack-interval-ms',type=int,default=20);p.add_argument('--max-stack-bursts',type=int,default=3);p.add_argument('--max-output-mib',type=int,default=64);p.add_argument('--self-test',action='store_true')
    p.add_argument('--configuration',type=Path,action='append',default=[]);p.add_argument('--action-marker',type=Path);p.add_argument('--min-free-mib',type=int,default=2048);a=p.parse_args()
    if not a.self_test and (a.pid is None or a.pid<2):p.error('--pid >=2 required')
    if not (5<=a.seconds<=180 and 1<=a.interval<=10 and 2<=a.system_every<=30 and 1<=a.trace_every<=30 and 32<=a.max_threads<=4096 and 0<=a.stack_seconds<=5 and a.stack_every>=20 and 5<=a.stack_interval_ms<=100 and 0<=a.max_stack_bursts<=5 and 4<=a.max_output_mib<=128):p.error('Capture/sample bounds exceeded')
    for path in [a.trace_directory,*a.cache_path,a.graphics_log]:
        if path and not any(path.resolve().is_relative_to(ROOT/n) for n in ('build','evidence')):p.error('Trace/cache/graphics inputs must be owned build/evidence paths')
    for path in [*a.configuration,a.action_marker]:
        if path and not path.resolve().is_relative_to(ROOT/'evidence'):p.error('Configuration/action-marker paths must be owned evidence paths')
    if a.min_free_mib<512:p.error('At least512MiB disk reserve required')
    for directory in a.crash_directory:
        if not directory.resolve().is_relative_to(Path.home()/'Library/Logs/DiagnosticReports') and not any(directory.resolve().is_relative_to(ROOT/n) for n in ('build','evidence')):p.error('Crash metadata is restricted to owned paths or native DiagnosticReports')
    if a.graphics_log and not re.fullmatch(r'vkd3d[^/]*\.log',a.graphics_log.name):p.error('Only explicitly supplied graphics-only vkd3d logs are accepted; Steam/auth/client logs are excluded')
    print(json.dumps(self_test(a) if a.self_test else capture(a),ensure_ascii=False))

if __name__=='__main__':main()
