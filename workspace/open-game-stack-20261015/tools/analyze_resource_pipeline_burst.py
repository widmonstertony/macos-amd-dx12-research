#!/usr/bin/env python3
"""Offline joins of frozen resource batches and timestamp pipeline labels.

No game, process, GPU or cache operations. Label attribution is conservative
across the measured per-stream CF calibration bracket; raw nanosecond domains
are never mixed. Address-sequence repeats do not establish redundant use calls.
"""
from pathlib import Path
from collections import Counter,defaultdict
import argparse,bisect,json,statistics,datetime,re
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
a=parser.parse_args();F=a.capture.resolve();OUT=a.output.resolve()
if OUT.exists():parser.error('output must be new')
OUT.mkdir(parents=True)
raw=json.loads((F/'arm-record.json').read_text());PID=raw['gamePID']
ARM={'armed':{k:{'mtimeNS':raw[k]['mtimeNS']} for k in ['forensics','gpu']}}
SID=ARM['armed']['forensics']['mtimeNS']
anchors={};rows=[];old=Counter()
for path in sorted(F.glob(f'forensics-{PID}-*.jsonl')):
 for no,line in enumerate(path.open(),1):
  r=json.loads(line);r['_file']=path.name;r['_line']=no
  if r['type']=='clockCalibration':anchors[r['streamGeneration']]=r
  elif r.get('session')==SID:rows.append(r)
  else:old[str(r.get('session'))]+=1
rows.sort(key=lambda r:r['seq'])
def cf(r):
 a=anchors[r['streamGeneration']]
 return a['timeCF']+(r['machNS']-(a['machBeforeNS']+a['machAfterNS'])*.5)/1e9
def cfBounds(r):
 a=anchors[r['streamGeneration']]
 return (a['timeCF']+(r['machNS']-a['machAfterNS'])/1e9,
         a['timeCF']+(r['machNS']-a['machBeforeNS'])/1e9)
def quant(values):
 if not values:return None
 v=sorted(values);return {'min':v[0],'p50':statistics.median(v),'p95':v[int((len(v)-1)*.95)],'max':v[-1]}
def write(n,x):(OUT/n).write_text(json.dumps(x,indent=2)+'\n')
work=defaultdict(list);allwork=defaultdict(list);cbs={};coverage=Counter();sessionMax={};kinds=Counter();valid=Counter();sampletimes=[];workcounts=[];nativePSOLabel=defaultdict(set)
for path in sorted(F.glob('trace-gpu-timestamps-*.json')):
 r=json.loads(path.read_text());cb=r['nativeCBID'];assert cb not in cbs;cbs[cb]=r
 g=r['gpuTimestamps'];assert g['captureSession']['armSignature']==ARM['armed']['gpu']['mtimeNS']
 for k in ['truncated','nativeCompleted','CPUResolveSucceeded','allDraws']:coverage[k+':'+str(g[k])]+=1
 coverage['truncatedWorkEvents:'+str(r['truncatedWorkEvents'])]+=1
 for k in ['captureStartedMidCommandBuffer','mayHaveUnsampledSuffix','capHit','samplingPointSupportMask']:coverage[k+':'+str(g['coverage'][k])]+=1
 for k in ['commandBuffersCreatedWhileArmed','nativeIntervalOnlyCompleted','commandBuffersObserved','commandBuffersAllocated','commandBuffersCompleted','commandBuffersDroppedCap','commandBuffersDroppedInFlight','commandBuffersDroppedDuration','commandBuffersUnsupported','allocationFailures','eventsOffered','samplesEncoded','eventsDroppedCapacity','eventsDroppedSampleBudget','eventsDroppedLiveBudget','eventsDroppedDuration','eventsDroppedUnsupportedPoint']:
  sessionMax[k]=max(sessionMax.get(k,0),g['captureSession'][k])
 for e in r['workEvents']:
  key=(cb,int(e['encoder'],16));e=dict(e,_file=path.name);allwork[key].append(e);kinds['work:'+e['kind']]+=1
  if e['kind'] in ('graphics-pipeline','compute-pipeline'):work[key].append(e)
  if e['kind'] in ('dispatch','dispatch-indirect'):
   m=re.search(r';pipeline=(.*?);nativePSO=(0x[0-9a-f]+);',e['label'])
   if m:nativePSOLabel[(cb,int(e['encoder'],16),int(m[2],16))].add(m[1])
 for e in g['samples']:
  kinds['sample:'+e['kind']]+=1;valid[str(e['valid'])]+=1;sampletimes.append(e['encodedCF'])
 workcounts.append(len(r['workEvents']))
for es in work.values():es.sort(key=lambda e:(e['time'],e['index']))
# Observe bind records are emitted after pipeline trace work and carry exact native PSO.
# An unchanged native pipeline may leave an earlier work label active; use temporal state.
bindmap={};bindout=[];reasons=Counter();deltas=[];labels=defaultdict(set);evidence=defaultdict(list)
for r in rows:
 if r['kind']!='resourcePipelineBind':continue
 f=r['fields'];key=(f['ownerNativeCB'],f['encoder']);es=work.get(key,[]);when=cf(r)
 p=(f['vulkanPipeline'],f['nativePipeline']);bk=(f['ownerNativeCB'],f['encoder'],f['ordinal'],*p)
 item={'seq':r['seq'],'CB':key[0],'encoder':key[1],'encoderGeneration':f['encoderGeneration'],'ordinal':f['ordinal'],'vulkanPipeline':p[0],'nativePipeline':p[1],'bindCF':when}
 if key[0] not in cbs:reason='no-counter-CB'
 elif not es:reason='no-pipeline-work-for-same-encoder'
 else:
  idx=bisect.bisect_right([e['time'] for e in es],cfBounds(r)[0])-1
  if idx<0:reason='no-certainly-preceding-pipeline-work'
  elif idx+1<len(es) and es[idx+1]['time']<=cfBounds(r)[1]:reason='clock-bracket-pipeline-change-ambiguous'
  else:
   e=es[idx];delta=round((when-e['time'])*1e9)
   # Work event and bind are in the same encoder lifetime and monotonic command buffer event sequence.
   item.update(label=e['label'],pipelineKind=e['kind'],workCF=e['time'],workIndex=e['index'],deltaNS=delta,workSource=e['_file'])
   direct=nativePSOLabel.get((key[0],key[1],p[1]),set())
   if e['kind']=='compute-pipeline' and direct and e['label'] not in direct:reason='compute-nativePSO-label-conflict'
   else:
    reason='joined';deltas.append(delta);labels[p].add(e['label']);bindmap[bk]=item
    if len(evidence[p])<3:evidence[p].append(item)
 item['status']=reason;reasons[reason]+=1;bindout.append(item)
# Every batch must have the same CB, encoder, ordinal, Vk and native PSO bind.
# Do not backfill from old pointers or cross-encoder mappings.
cost=defaultdict(Counter);batchreasons=defaultdict(Counter);batchlabels=defaultdict(set);ends=[];total=Counter();unmapped=[];windowseq=[];begin={};repeat=Counter();refsig={}
for r in rows:
 f=r.get('fields',{})
 if r['kind']=='resourceBatchBegin':begin[(r['session'],f['batchID'])]=r
 if r['kind']=='resourceEncoderEnd':ends.append(r)
 if r['kind']!='resourceBatchEnd' or f['declarationKind']!=1:continue
 p=(f['vulkanPipeline'],f['nativePipeline']);d=cost[p]
 for k,v in [('calls',1),('resources',f['resourceCount']),('wallNS',f['actualAPIWallNS']),('threadCPUNS',f.get('actualThreadCPUBracketNS',0)),('beginWriterWallNS',f.get('beginWriterWallNS',0))]:d[k]+=v;total[k]+=v
 bk=(f['ownerNativeCB'],f['encoder'],f['pipelineBindOrdinal'],*p);b=bindmap.get(bk)
 if b and b['bindCF']<=cf(r):
  reason='exact-CB-encoder-ordinal-PSO-bind';batchlabels[p].add(b['label']);d['joinedCalls']+=1;d['joinedResources']+=f['resourceCount'];d['joinedWallNS']+=f['actualAPIWallNS']
 else:
  reason='no-exact-bind'
  if f['ownerNativeCB'] not in cbs:reason='no-counter-CB'
  if len(unmapped)<20:unmapped.append({'seq':r['seq'],**{k:f[k] for k in ['ownerNativeCB','encoder','encoderGeneration','pipelineBindOrdinal','vulkanPipeline','nativePipeline']},'reason':reason})
 batchreasons[reason].update(calls=1,resources=f['resourceCount'],wallNS=f['actualAPIWallNS'])
 br=begin.get((r['session'],f['batchID']))
 if br and br['fields'].get('hashComplete'):
  bf=br['fields'];sig=(f['ownerNativeCB'],f['encoder'],f['encoderGeneration'],f['stageMask'],f['resourceCount'],bf['pointerHash1'],bf['pointerHash2']);repeat[sig]+=1;refsig[sig]=f['resourceCount']
rank=[]
for p,d in sorted(cost.items(),key=lambda kv:kv[1]['wallNS'],reverse=True):
 rank.append(dict(vulkanPipeline=p[0],nativePipeline=p[1],**dict(d),nativeReadWallFraction=d['wallNS']/total['wallNS'],labels=sorted(batchlabels[p]),bindLabelCount=len(labels[p]),labelJoinEvidence=evidence[p]))
endtot=Counter();single=defaultdict(Counter)
fields=['readCalls','readResources','readWallNS','planEligibleChildren','planAppliedChildren','planPreciseChildren','planRejectTexture','planRejectWrite','planRejectSmall','planRejectHeapSmall','planCoveredSkips','planGroups','usedReplayVisits','usedNewGeneration','usedCompatible','pendingQueued','warmReplayChildren','coldReplayChildren','deltaReplayChildren','heapCalls','heapObjects','pipelineChanges','pipelineRows','pipelineRowsDropped','bindingCalls','writeCalls','writeResources','writeWallNS','resourceBatchesOffered','resourceBatchesEnded','resourceBatchesUnfinished']
for r in ends:
 f=r['fields']
 for k in fields:endtot[k]+=f.get(k,0)
 if f['pipelineChanges']==1 and f['firstPipeline']==f['lastPipeline']:
  d=single[f['firstPipeline']];d['encoderEnds']+=1
  for k in fields:d[k]+=f.get(k,0)
seqs=[r['seq'] for r in rows];gaps=[(a,b,b-a-1) for a,b in zip(seqs,seqs[1:]) if b>a+1]
result=dict(PID=PID,session=SID,eventCF=[cf(rows[0]),cf(rows[-1])],seq=[seqs[0],seqs[-1]],rowCount=len(rows),excludedOlderSessionRows=dict(old),nativeReadTotals=dict(total),rankings=rank,bindStatus=dict(reasons),batchJoinStatus={k:dict(v) for k,v in batchreasons.items()},bindToWorkDeltaNS=quant(deltas),sequenceGaps=gaps,unmappedExamples=unmapped,encoderEndRows=len(ends),encoderCounters=dict(endtot),singlePipelineEncoderCounters={str(k):dict(v) for k,v in single.items()},identicalAddressSequenceObservations=dict(hashMatchedCalls=sum(repeat.values()),repeatCalls=sum(max(0,n-1) for n in repeat.values()),hashMatchedReferences=sum(n*refsig[s] for s,n in repeat.items()),repeatReferences=sum(max(0,n-1)*refsig[s] for s,n in repeat.items()),limits='Array address-sequence repeats do not prove redundant native calls; heap declaration may require read-exception/write replay.'),limits=['Costs cover only recorded readBatchEnd calls in this bounded session; dropped rows bias completeness.','Per-PSO labels require exact same CB+encoder+ordinal+Vk/native PSO bind and temporal pipeline work; no old-pointer-only labels.','Unique labels may be associated with a PSO only through rows in this same burst; unjoined calls are retained in totals and explicitly counted.','MSL potential is an upper bound on recorded costs, not actual resources removable or FPS.'])
write('pipeline-ranking.json',result);write('bind-join-evidence.json',bindout)
clock=[json.loads(l) for l in (F/f'gpu-counter-clock-sessions-{PID}.jsonl').open()]
meta=dict(files=len(cbs),coverage=dict(coverage),sessionMaxSnapshots=sessionMax,closedClockSidecar=clock,kinds=dict(kinds),sampleValidity=dict(valid),sampleCFRange=[min(sampletimes),max(sampletimes)],workEventsPerCB=quant(workcounts),limits=['Counter snapshots precede final completion accounting; inspect sidecar and truncated/drop coverage rather than inferring complete sampling.','ALL_DRAWS does not add ordinary indirect per-draw labels; pipeline-change state remains usable. Geometry-grid is filtered from counter samples but retained in complete workEvents.','encodedMonotonicNS uses a different monotonic domain from forensics machNS; joins use per-stream CF calibration and work-event CF, never raw nanosecond equality.'])
write('counter-coverage.json',meta)
print(json.dumps({'nativeReadTotals':dict(total),'PSOs':len(rank),'bindStatus':dict(reasons),'batchJoinStatus':result['batchJoinStatus'],'bindDelta':result['bindToWorkDeltaNS'],'seqGaps':gaps,'counterFiles':len(cbs),'samples':sum(valid.values()),'endCounters':dict(endtot)},indent=2))
