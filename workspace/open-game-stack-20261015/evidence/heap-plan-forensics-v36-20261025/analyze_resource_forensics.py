"""Read-only typed aggregation of owned direct-helper forensic records."""
import hashlib,json
from pathlib import Path

COUNT_FIELDS=set('''pipelineChanges pipelineRows pipelineRowsDropped bindingCalls bindingSkippedSlots
readBufferSlots readTextureSlots writeBufferSlots writeTextureSlots unknownReadSlots unknownWriteSlots
snapshotCalls snapshotWords bindFlushes immediateCalls planRejectDisabled planRejectTexture planRejectWrite
planRejectSmall planRejectLeaseMissing planRejectLeaseLarge planRejectHeapSmall planAppliedChildren
planEligibleChildren planPreciseChildren planCoveredSkips planGroups usedReplayVisits usedNewNodes
usedNewGeneration usedUpgrades usedCompatible pendingQueued pendingSuperseded warmReplayChildren
coldReplayChildren deltaReplayChildren snapshotCoveredSkips readCalls readResources readWallNS
writeCalls writeResources writeWallNS heapCalls heapObjects heapWallNS heapRegroupVisits
heapCollapsedChildren descriptorFastHits descriptorMisses descriptorCacheClears snapshotCacheClears
heapPlanCacheClears leaseRefreshes registrationQueries registrationRelated registrationUnrelated
liveCacheHits liveLookups liveFound absentHits ownedResourceRetains lifetimeClears clearNoCrossEncoder
clearMapBound'''.split())
MAX_FIELDS=set('''readMaxWallNS writeMaxWallNS heapMaxWallNS usedNodesAtEnd heldResourcesAtEnd
heldLeasesAtEnd heldSnapshotEntriesAtEnd'''.split())
UNION_FIELDS={'readStageUnion','writeStageUnion','heapStageUnion'}
IDENTITY_FIELDS=set('''ownerSession encoder encoderGeneration ownerNativeCB ownerSubmission ownerFrame
ownerQueueFamily ownerQueueIndex partialPrefix partialSuffix endReason localComplete encoderKind
firstPipeline lastPipeline encoderResetsBefore heapPlansEnabled resourceTracker'''.split())
REQUIRED=('snapshotCalls','snapshotWords','planAppliedChildren','planEligibleChildren','heapCalls','writeCalls')

def _strict_pairs(pairs):
 result={}
 for key,value in pairs:
  if key in result:raise ValueError('duplicate JSON key '+key)
  result[key]=value
 return result

def read_json(raw):return json.loads(raw,object_pairs_hook=_strict_pairs)

def analyze(trace_dir):
 trace_dir=Path(trace_dir);sums={};maxima={};unions={};distinct={};unclassified={}
 rows=0;parse_errors=[];sources=[];end_records=[];states=[];boundary_tuples=set();latest_by_writer={};generations={}
 for file in sorted(trace_dir.glob('forensics-*.jsonl')):
  data=file.read_bytes();sources.append(dict(path=str(file),bytes=len(data),SHA256=hashlib.sha256(data).hexdigest()))
  if data and not data.endswith(b'\n'):parse_errors.append(dict(path=str(file),reason='unterminated final row'))
  for line_no,line in enumerate(data.splitlines(),1):
   try:row=read_json(line)
   except ValueError as error:parse_errors.append(dict(path=str(file),line=line_no,reason=str(error)));continue
   if row.get('type')=='forensics':
    writer=(row.get('pid'),row.get('runID'));latest_by_writer[writer]=max(latest_by_writer.get(writer,0),row.get('seq',0))
    generations.setdefault(writer,set()).add(row.get('streamGeneration'))
   if row.get('kind')!='resourceEncoderEnd':continue
   fields=row.get('fields',{});rows+=1
   boundary_tuples.add(tuple(fields.get(key)for key in ('ownerSession','resourceTracker','encoder','encoderGeneration')))
   provenance={key:row.get(key)for key in ('pid','runID','seq','session','machNS','threadMachID','streamGeneration')}
   provenance.update(source=str(file),sourceLine=line_no,fields=fields);end_records.append(provenance)
   for key,value in fields.items():
    if not isinstance(value,int):unclassified.setdefault(key,[]).append(value);continue
    if key in COUNT_FIELDS:sums[key]=sums.get(key,0)+value
    elif key in MAX_FIELDS:maxima[key]=max(maxima.get(key,value),value)
    elif key in UNION_FIELDS:unions[key]=unions.get(key,0)|value
    elif key in IDENTITY_FIELDS:distinct.setdefault(key,set()).add(value)
    else:unclassified.setdefault(key,[]).append(value)
 status_sources=[]
 for file in sorted(trace_dir.glob('forensics-current-*.json')):
  data=file.read_bytes();status_sources.append(dict(path=str(file),bytes=len(data),SHA256=hashlib.sha256(data).hexdigest()))
  try:states.append(read_json(data))
  except ValueError as error:parse_errors.append(dict(path=str(file),reason=str(error)))
 required={name:sums.get(name,0)for name in REQUIRED}
 observed_loss=any(state.get('dropped',0)or state.get('IOFailures',0)or state.get('serializationFailures',0)for state in states)
 status_comparisons=[]
 for state in states:
  writer=(state.get('pid'),state.get('runID'));latest=latest_by_writer.get(writer,0)
  status_comparisons.append(dict(pid=writer[0],runID=writer[1],statusWritten=state.get('written',0),
   latestProvidedSequence=latest,statusBehindProvidedTail=latest>state.get('written',0),
   statusMachNS=state.get('machNS'),statusCanLagItsOwnIO=state.get('writerHostNSSnapshotMayLagCurrentIO',True)))
 reasons=['current sidecar is sampled, not an explicit final loss-counter/status record; zero sampled loss is not zero-loss proof']
 if any(comparison['statusBehindProvidedTail']for comparison in status_comparisons):reasons.append('current status written counter lags provided raw record tail')
 if not states:reasons.append('no common writer current status supplied')
 if parse_errors:reasons.append('provided raw/status JSON parse or termination failures')
 if observed_loss:reasons.append('provided current status already reports diagnostic loss/failure')
 for writer,seen in generations.items():
  if seen and min(seen)>1:reasons.append('provided rolling stream lacks its initial generations for writer '+str(writer))
  if seen and sorted(seen)!=list(range(min(seen),max(seen)+1)):reasons.append('provided rolling stream has generation gaps for writer '+str(writer))
 return dict(path=str(trace_dir),encoderEndRows=rows,distinctBoundaryIdentityTuples=len(boundary_tuples),
  identityTupleLimitation='resourceTracker/encoder are reusable addresses; tuples are not independently proven unique encoder lifetimes',
  actualAggregatedFields=sums,maximumObservedFields=maxima,stageUnionOR=unions,
  identityOwnerFlagAndEnumDistinct={key:sorted(value)for key,value in distinct.items()},unclassifiedNotAggregated=unclassified,
  aggregationRules={'actualAggregatedFields':'explicit count/cumulative-per-encoder wall-time delta whitelist: sum across supplied End records',
   'maximumObservedFields':'MaxWallNS maxima and AtEnd inventory gauges: max, never sum',
   'stageUnionOR':'bitwise OR',
   'identityOwnerFlagAndEnumDistinct':'distinct observed values, never sum; encoderResetsBefore is cumulative boundary metadata, not a delta',
   'unknownFields':'preserved, not guessed or summed'},
  perEncoderEndRecords=end_records,requiredNonzeroCounters=required,
  counterCoveragePassed=bool(rows and all(value>0 for value in required.values())and not parse_errors),parseErrors=parse_errors,
  commonWriterStates=states,commonWriterLossObserved=observed_loss,commonWriterStatusComparisons=status_comparisons,
  completeTailLossStatistics=False,noLossProven=False,coverageComplete=False,coverageIncompleteReasons=reasons,
  sources=sources,statusSources=status_sources,
  scope='direct-helper fixture explicitly calls diagnostic reset/observe/finish; counters are native helper increments, never injected hit/count values; does not prove real game binder wiring',
  interpretation='required nonzero counters qualify observed diagnostic plumbing only; snapshotCalls/Words cover replay entry and warm/cold/used loops may be bypassed by a successful heap plan')
