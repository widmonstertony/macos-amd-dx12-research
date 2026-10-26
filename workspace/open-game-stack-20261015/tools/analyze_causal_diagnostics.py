"""CPU-only joins for diagnostic batches and presentation lifecycle records.

All joins use observed IDs. Pointer fingerprints are addresses, not object
lifetimes; public command-buffer intervals are not GPU busy measurements.
"""
from collections import Counter, defaultdict
from decimal import Decimal


def analyze(rows, command_buffers, limit=500):
    records=[];seen=set();anchors=defaultdict(list)
    def ident(row):return (row.get('_pid',row.get('pid')),row.get('runID'))
    def source(row):return {k[1:]:row[k] for k in ('_source','_line') if k in row}
    for row in rows:
        if row.get('type')=='clockCalibration':
            before,after=row.get('machBeforeNS'),row.get('machAfterNS')
            if (row.get('clockDomain')=='mach-absolute-nanoseconds' and isinstance(before,int)
                    and isinstance(after,int) and after>=before and row.get('timeCA') is not None):
                anchors[ident(row)].append(row)
        if row.get('type')!='forensics':continue
        key=ident(row)+(row.get('seq'),)
        if row.get('seq') is None:key+=tuple(source(row).values())
        if key in seen:continue
        seen.add(key);records.append(row)
    def group_id(row,field):return ident(row)+(row.get('session'),row.get('fields',{}).get(field))
    def delta(fields,end,start):
        a,b=fields.get(start),fields.get(end)
        return b-a if isinstance(a,int) and isinstance(b,int) and a>0 and b>=a else None
    def ca_to_mach(row,ca):
        if ca is None:return None
        physical=row.get('streamSession') if row.get('streamOwnershipSchema')==2 else row.get('session')
        candidates=[a for a in anchors[ident(row)] if a.get('session')==physical and a.get('timeCA') is not None]
        if not candidates:return None
        a=min(candidates,key=lambda x:abs(x.get('machBeforeNS',0)-row.get('machNS',0)))
        return Decimal(a['machBeforeNS']+a['machAfterNS'])/2+(Decimal(str(ca))-Decimal(str(a['timeCA'])))*1000000000
    batches=defaultdict(dict);presents=defaultdict(dict);terminals=defaultdict(dict);run_cbs={}
    for row in records:
        kind=row.get('kind');f=row.get('fields',{})
        if kind in ('resourceBatchBegin','resourceBatchEnd') and f.get('batchID'):
            batches[group_id(row,'batchID')][kind]=row
        if kind in ('NativeSubmissionTerminalIntentV1','NativeSubmissionEndV1') and f.get('ownerSubmission'):
            terminals[group_id(row,'ownerSubmission')][kind]=row
        if kind and kind.startswith('NativeDrawable') and f.get('presentationID'):
            presents[group_id(row,'presentationID')][kind]=row
        if kind=='NativeCBCompleted' and f.get('ownerNativeCB'):
            run_cbs[ident(row)+(f['ownerNativeCB'],)]=dict(nativeCB=f['ownerNativeCB'],
                logicalSubmit=f.get('ownerSubmit'),split=f.get('split'),nativeStatus=f.get('status'),
                error=f.get('error'),ownerFrame=f.get('ownerFrame'),partialPrefix=f.get('partialPrefix'),phases={'completed':row.get('machNS')},
                gpuEndCA=Decimal(f['gpuEndCANS'])/1000000000 if f.get('gpuEndCANS') else None)
    batch_rows=[];totals=Counter();by_source=defaultdict(Counter);by_fingerprint=defaultdict(Counter)
    for key,phases in batches.items():
        begin,end=phases.get('resourceBatchBegin'),phases.get('resourceBatchEnd')
        b=(begin or {}).get('fields',{});e=(end or {}).get('fields',{})
        wall=e.get('actualAPIWallNS') if end else None
        item=dict(pid=key[0],runID=key[1],ownerSession=key[2],batchID=key[3],
            paired=bool(begin and end),sourceKind=e.get('sourceKind',b.get('sourceKind')),
            resourceCount=e.get('resourceCount',b.get('resourceCount')),actualAPIWallNS=wall,
            actualThreadCPUBracketNS=e.get('actualThreadCPUBracketNS') if e.get('threadCPUKnown') else None,
            hashWallNS=e.get('hashWallNS'),beginWriterWallNS=e.get('beginWriterWallNS'),
            ownerNativeCB=e.get('ownerNativeCB',b.get('ownerNativeCB')),
            vulkanPipeline=e.get('vulkanPipeline',b.get('vulkanPipeline')),
            encoderGeneration=e.get('encoderGeneration',b.get('encoderGeneration')),
            begin=source(begin) if begin else None,end=source(end) if end else None)
        batch_rows.append(item);totals['observedGroups']+=1;totals['paired']+=bool(begin and end)
        totals['beginOnly']+=bool(begin and not end);totals['endOnly']+=bool(end and not begin)
        if isinstance(wall,int):
            totals['summedAPIWallNS']+=wall
            dest=by_source[item['sourceKind']];dest['calls']+=1;dest['APIWallNS']+=wall;dest['resources']+=item['resourceCount'] or 0
            totals['summedBeginWriterWallNS']+=e.get('beginWriterWallNS',0)
            totals['summedHashWallNS']+=e.get('hashWallNS',0)
        if begin and b.get('hashComplete') and b.get('pointerAddressOnly'):
            signature=(key[0],key[1],b.get('sourceKind'),b.get('declarationKind'),b.get('stageMask'),b.get('resourceCount'),b.get('pointerHash1'),b.get('pointerHash2'))
            by_fingerprint[signature]['observations']+=1
            by_fingerprint[signature]['summedAPIWallNS']+=wall or 0
    presentation_rows=[]
    for key,phases in presents.items():
        entry=phases.get('NativeDrawablePresentedEntry');done=phases.get('NativeDrawablePresented')
        call=phases.get('NativeDrawablePresentCall');f=(done or entry or call or next(iter(phases.values()))).get('fields',{})
        # Legacy coarse graph IDs have no runID; never borrow them across a PID
        # restart. Only native completions carrying this exact run qualify.
        cb=run_cbs.get((key[0],key[1],f.get('ownerNativeCB')))
        gpu_end=ca_to_mach(done or entry or call or next(iter(phases.values())),cb.get('gpuEndCA')) if cb else None
        handler=f.get('handlerEntryMachNS')
        join_status='unjoinable-no-exact-run-completion'
        if cb:
            join_status='observed-exact-run-nativeCB'
            if cb.get('nativeStatus')!=4 or cb.get('error')!=0:join_status='unjoinable-failed-completion'
            elif cb.get('partialPrefix'):join_status='unjoinable-partial-prefix'
            elif cb.get('ownerFrame') and f.get('ownerFrame') and cb['ownerFrame']!=f['ownerFrame']:join_status='unjoinable-frame-conflict'
            elif gpu_end is None:join_status='unjoinable-clock-or-GPU-timestamp'
            elif handler and gpu_end>handler:join_status='unjoinable-negative-delay'
        delay=handler-gpu_end if handler and gpu_end is not None and join_status=='observed-exact-run-nativeCB' else None
        presentation_rows.append(dict(pid=key[0],runID=key[1],ownerSession=key[2],presentationID=key[3],
            phases={name:source(row) for name,row in phases.items()},swapchainGeneration=f.get('swapchainGeneration'),
            drawableID=f.get('drawableID'),ownerNativeCB=f.get('ownerNativeCB'),
            nativeTimestampValid=f.get('nativeTimestampValid') if done else None,
            rawPresentedTimeBits=f.get('rawPresentedTimeBits'),handlerEntryMachNS=handler,
            ownerGPUStatus=cb.get('nativeStatus') if cb else None,
            nativeCBJoinStatus=join_status,ownerCBPartialPrefix=cb.get('partialPrefix') if cb else None,
            GPUIntervalEndToHandlerEntryNS=delay,
            entryLoggerNS=delta(f,'handlerEntryLogEndMachNS','handlerEntryLogStartMachNS'),
            detachmentLockWaitNS=delta(f,'lockAcquiredMachNS','lockRequestedMachNS'),
            detachmentLockHoldNS=delta(f,'lockReleasedMachNS','lockAcquiredMachNS'),
            historyLockWaitNS=delta(f,'historyLockAcquiredMachNS','historyLockRequestedMachNS'),
            historyWorkNS=delta(f,'historyWorkEndMachNS','historyLockAcquiredMachNS'),
            detachedAtCallback=f.get('detachedAtCallback')))
    submission_rows=[]
    for key,phases in terminals.items():
        end=phases.get('NativeSubmissionEndV1');intent=phases.get('NativeSubmissionTerminalIntentV1')
        f=(end or intent)['fields'];expected=f.get('expectedSplitCount');last=f.get('lastNativeCB')
        cbs=[v for (pid,run,_),v in run_cbs.items() if pid==key[0] and run==key[1] and v.get('logicalSubmit')==key[3]]
        ordinals=sorted(v.get('split',-1) for v in cbs)
        complete=bool(end and f.get('resultBits')==0 and f.get('nativeCommitReturned') and
            expected and len(cbs)==expected and ordinals==list(range(expected)) and
            any(v.get('nativeCB')==last and v.get('split')==expected-1 for v in cbs) and
            all(v.get('nativeStatus')==4 and v.get('error')==0 and not v.get('partialPrefix') for v in cbs))
        submission_rows.append(dict(pid=key[0],runID=key[1],ownerSession=key[2],logicalSubmission=key[3],
            terminalEndObserved=bool(end),expectedSplitCount=expected,observedSplitCount=len(cbs),
            splitOrdinals=ordinals,lastNativeCB=last,observedSuccessfulCompletedSuffix=complete,
            commitAPIWallNS=delta(f,'commitEndMachNS','commitStartMachNS'),intentLoggerWallNS=f.get('intentLoggerWallNS'),
            end=source(end) if end else None,intent=source(intent) if intent else None))
    batch_rows.sort(key=lambda r:r.get('actualAPIWallNS') or -1,reverse=True)
    presentation_rows.sort(key=lambda r:r.get('GPUIntervalEndToHandlerEntryNS') or -1,reverse=True)
    repeated=[dict(signature=list(key),**dict(value),addressIdentityOnly=True) for key,value in by_fingerprint.items() if value['observations']>1]
    repeated.sort(key=lambda r:r['summedAPIWallNS'],reverse=True)
    return dict(schema=1,allCausesFound=False,resourceBatches=dict(totals),
        resourceBatchBySource=[dict(sourceKind=key,**dict(value)) for key,value in by_source.items()],
        slowestResourceBatches=batch_rows[:limit],repeatedAddressSequences=repeated[:limit],
        presentationChains=presentation_rows[:limit],presentationChainsObserved=len(presents),
        submissionTerminals=submission_rows[:limit],submissionTerminalsObserved=len(terminals),
        outputRankingCapped=any(len(v)>limit for v in (batch_rows,repeated,presentation_rows,submission_rows)),
        limits=['Missing End is an open observation, not proof of a hang without coverage/health checks.',
            'Summed API wall spans may overlap threads and are not elapsed frame time or exclusive driver CPU.',
            'Identical raw address sequences do not prove resource lifetime, contents or redundant declarations.',
            'GPU interval to handler entry includes scheduling and presentation; zero presentedTime does not prove a dropped frame.',
            'Terminal suffix closure is limited to observed successful submission splits; it does not prove the whole capture is complete.',
            'Wine Unix-call NTSTATUS, private driver scheduler, physical scanout and actual GPU clocks remain separate gaps.'])
