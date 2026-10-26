import json
from pathlib import Path
import tempfile
import unittest
from decimal import Decimal
from analyze_causal_diagnostics import analyze
from analyze_stutter_capture import Analyzer, ROOT


def row(kind,fields,seq=1,session=10,stream=20):
    return dict(schema=1,type='forensics',kind=kind,pid=123,_pid=123,runID=4,seq=seq,
        session=session,streamSession=stream,streamOwnershipSchema=2,machNS=1200,fields=fields)


def anchor(session=20):
    return dict(type='clockCalibration',schema=1,_pid=123,pid=123,runID=4,session=session,
        clockDomain='mach-absolute-nanoseconds',machBeforeNS=1000,machAfterNS=1000,
        timeCF=Decimal('10'),timeCA=Decimal('20'))


class CausalDiagnosticsTests(unittest.TestCase):
    def test_physical_clock_logical_owner(self):
        a=Analyzer(target_pid=123);a.forensic_rows=[anchor(),row('NativeDrawablePresentedEntry',dict(presentationID=1))]
        r=a.forensics_report();item=r['records'][0]
        self.assertEqual(item['session'],10);self.assertEqual(item['streamSession'],20)
        self.assertTrue(item['lateLogicalOwner']);self.assertTrue(item['calibrationSessionMatched'])
        self.assertEqual(item['timeCF'],Decimal('10.0000002'))
        self.assertNotIn('forensics-clock-session-mismatch',a.issue_counts)

    def test_wrong_physical_clock_never_borrowed(self):
        a=Analyzer(target_pid=123);a.forensic_rows=[anchor(10),row('anything',{})]
        r=a.forensics_report();self.assertIsNone(r['records'][0]['timeCF'])
        self.assertEqual(a.issue_counts['forensics-clock-session-mismatch'],1)

    def test_legacy_clock(self):
        a=Analyzer(target_pid=123);event=row('anything',{});event.pop('streamOwnershipSchema');event.pop('streamSession')
        a.forensic_rows=[anchor(10),event]
        self.assertTrue(a.forensics_report()['records'][0]['calibrationSessionMatched'])

    def test_complete_terminal_and_prefix_gap(self):
        f=dict(ownerSubmission=9,expectedSplitCount=2,lastNativeCB=42,resultBits=0,nativeCommitReturned=1,
            commitStartMachNS=100,commitEndMachNS=105)
        def cb(cbid,split,seq,**extra):
            return row('NativeCBCompleted',dict(ownerNativeCB=cbid,ownerSubmit=9,split=split,status=4,error=0,partialPrefix=0,**extra),seq)
        cbs=[cb(41,0,2),cb(42,1,3)];terminal=row('NativeSubmissionEndV1',f)
        r=analyze([terminal,*cbs],{})
        self.assertTrue(r['submissionTerminals'][0]['observedSuccessfulCompletedSuffix'])
        self.assertEqual(r['submissionTerminals'][0]['commitAPIWallNS'],5)
        cbs[0]['fields']['partialPrefix']=1
        self.assertFalse(analyze([terminal,*cbs],{})['submissionTerminals'][0]['observedSuccessfulCompletedSuffix'])
        cbs[0]['fields']['partialPrefix']=0;cbs[0]['fields']['status']=5
        self.assertFalse(analyze([terminal,*cbs],{})['submissionTerminals'][0]['observedSuccessfulCompletedSuffix'])
        cbs[0]['fields']['status']=4;cbs[0]['runID']=3
        self.assertFalse(analyze([terminal,*cbs],{})['submissionTerminals'][0]['observedSuccessfulCompletedSuffix'])

    def test_resource_api_not_logger_and_open_begin(self):
        b=dict(batchID=1,sourceKind=2,resourceCount=512,hashComplete=1,pointerAddressOnly=1,pointerHash1=5,pointerHash2=6)
        e=dict(b,actualAPIWallNS=500,beginWriterWallNS=3000000,hashWallNS=40,threadCPUKnown=0,actualThreadCPUBracketNS=0)
        rows=[row('resourceBatchBegin',b,1),row('resourceBatchEnd',e,2),row('resourceBatchBegin',dict(b,batchID=2),3)]
        r=analyze(rows,{})
        self.assertEqual(r['resourceBatches']['summedAPIWallNS'],500)
        self.assertEqual(r['resourceBatches']['beginOnly'],1)
        self.assertIsNone(r['slowestResourceBatches'][0]['actualThreadCPUBracketNS'])
        self.assertTrue(r['repeatedAddressSequences'][0]['addressIdentityOnly'])
        self.assertFalse(r['allCausesFound'])

    def test_presentation_raw_entry_and_lock(self):
        f=dict(presentationID=8,ownerNativeCB=42,handlerEntryMachNS=5000,
            lockRequestedMachNS=5100,lockAcquiredMachNS=5400,lockReleasedMachNS=5500,
            handlerEntryLogStartMachNS=5001,handlerEntryLogEndMachNS=5099,
            rawPresentedTimeBits=0,nativeTimestampValid=0)
        cb=row('NativeCBCompleted',dict(ownerNativeCB=42,gpuEndCANS=20000001000,status=4,error=0,partialPrefix=0),2)
        r=analyze([anchor(),row('NativeDrawablePresented',f),cb],{})['presentationChains'][0]
        self.assertEqual(r['GPUIntervalEndToHandlerEntryNS'],3000)
        self.assertEqual(r['detachmentLockWaitNS'],300);self.assertEqual(r['entryLoggerNS'],98)
        self.assertEqual(r['nativeTimestampValid'],0)
        cb['runID']=3
        self.assertIsNone(analyze([anchor(),row('NativeDrawablePresented',f),cb],{})['presentationChains'][0]['GPUIntervalEndToHandlerEntryNS'])

    def test_invalid_clock_bracket_is_unjoinable(self):
        f=dict(presentationID=8,ownerNativeCB=42,handlerEntryMachNS=5000)
        cb=row('NativeCBCompleted',dict(ownerNativeCB=42,gpuEndCANS=20000001000,status=4),2)
        for bad in (dict(anchor(),machAfterNS=999),dict(anchor(),clockDomain='steady'),dict(anchor(),machAfterNS=None)):
            r=analyze([bad,row('NativeDrawablePresented',f),cb],{})['presentationChains'][0]
            self.assertIsNone(r['GPUIntervalEndToHandlerEntryNS'])

    def test_overlapping_raw_windows_dedup(self):
        e=row('resourceBatchBegin',dict(batchID=3))
        r=analyze([e,dict(e,_source='other-window')],{})
        self.assertEqual(r['resourceBatches']['observedGroups'],1)

    def test_display_prefix_cap_not_misreported_as_raw_writer_loss(self):
        a=Analyzer(target_pid=123)
        a.forensic_rows=[anchor()]+[row('resourceSynthetic',{},i+1) for i in range(2001)]
        report=a.forensics_report()
        self.assertTrue(report['recordsTruncated'])
        self.assertEqual(report['kinds']['resourceSynthetic'],2001)
        self.assertTrue(report['recordsDisplayLimitIsNotWriterLoss'])
        stage=next(x for x in report['stageMatrix'] if x['stage']=='resource-heap-descriptors')
        self.assertNotIn('capped',stage['statuses'])

    def test_acquisition_and_present_api_not_lost_after_detail_prefix(self):
        acquire=dict(imageGeneration=3,acquisitionAttemptID=7,startMachNS=100,
            layerGetStartMachNS=400,layerGetEndMachNS=420,endMachNS=500,drawableReturned=1,drawableID=8)
        request=dict(presentationID=9,imageGeneration=3,acquisitionAttemptID=7,requestObserved=1)
        call=dict(presentationID=9,callStartMachNS=800,callEndMachNS=810,
            intentStartMachNS=600,intentEndMachNS=780,requestMachNS=550,scheduledHandlerEntryMachNS=580,
            displaySyncEnabled=0,maximumDrawableCount=3)
        rows=[row('unrelated',{},i+100) for i in range(2001)]
        rows += [row('NativeDrawableAcquire',dict(acquire,phase=0),1,session=10),
            row('NativeDrawableAcquire',dict(acquire,phase=1),2,session=10),
            row('NativeDrawablePresentRequest',request,3,session=11),
            row('NativeDrawablePresentCall',call,4,session=11)]
        report=analyze(rows,{})
        self.assertEqual(report['drawableAcquisitionsObserved'],1)
        a=report['drawableAcquisitions'][0];p=report['presentationChains'][0]
        self.assertEqual((a['diagnosticLeadInWallNS'],a['layerWrapperWallNS'],a['nextDrawableAndRetainWallNS']),(300,20,80))
        self.assertEqual(p['actualPresentAPIWallNS'],10);self.assertEqual(p['presentIntentLoggerWallNS'],180)
        self.assertEqual(p['acquisition']['ownerSession'],10);self.assertEqual(p['ownerSession'],11)
        self.assertEqual(p['effectiveLayer']['displaySyncEnabled'],0)

    def test_acquisition_open_and_output_limit_explicit(self):
        rows=[row('NativeDrawableAcquire',dict(phase=0,imageGeneration=3,acquisitionAttemptID=i,startMachNS=100),i) for i in range(1,4)]
        report=analyze(rows,{},limit=1)
        self.assertEqual(report['drawableAcquisitionsObserved'],3)
        self.assertTrue(report['outputRankingCapped'])
        self.assertFalse(report['drawableAcquisitions'][0]['paired'])
        self.assertIsNone(report['drawableAcquisitions'][0]['nextDrawableAndRetainWallNS'])

    def test_capture_subdirectories_loaded_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);folder=root/'raw-window-0001-scene';folder.mkdir()
            path=folder/'forensics-123-run-4-generation-2.jsonl'
            event=row('resourceBatchBegin',dict(batchID=3));event.pop('_pid')
            path.write_text(json.dumps(event)+'\n')
            (root/'metadata.json').write_text(json.dumps(dict(target=dict(pid=123))))
            (root/'summary.json').write_text(json.dumps(dict(rawForensicsPaths=[str(path)])))
            (root/'timeline.jsonl').write_text('')
            a=Analyzer(target_pid=123);a.load_session(root)
            self.assertEqual(len(a.forensic_rows),1)
            self.assertEqual(a.forensics_report()['causalDiagnostics']['resourceBatches']['beginOnly'],1)

    def test_session_memory_journal_preserves_nested_events_with_lifetime_guard(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'evidence',prefix='memory-loader-cpu-') as temporary:
            root=Path(temporary);profile=root/'profile';trace=profile/'msl';trace.mkdir(parents=True)
            capture=root/'capture';capture.mkdir()
            metadata=dict(target=dict(pid=123),profile=str(profile),processStartAbstime=99,
                processStartMachNS=100,processStartUnixEstimate=1,timebase=dict(numer=1,denom=1))
            (capture/'metadata.json').write_text(json.dumps(metadata));(capture/'summary.json').write_text('{}')
            (capture/'timeline.jsonl').write_text(json.dumps(dict(clock=dict(machAbsoluteTicks=500,CFAbsoluteTime=1)))+'\n')
            event=dict(schema=2,allocationID=1,sequence=1,beginMachNS=200,endMachNS=220,
                clockDomain='mach-absolute-nanoseconds',site='owned-control',returnedNil=True,hostCallNS=20)
            (trace/'memory-failures-123.jsonl').write_text(json.dumps(event)+'\n'+json.dumps(dict(event,allocationID=2,beginMachNS=50,endMachNS=60))+'\n')
            (trace/'memory-current-123.json').write_text(json.dumps(dict(pid=123,monotonicNS=400,failureEventsTotal=1,recentFailures=[event])))
            a=Analyzer(target_pid=123);a.load_session(capture);report=a.memory_report()
            self.assertEqual(len(a.memory_events),1);self.assertEqual(len(a.memory_snapshots),1)
            self.assertEqual(a.memory_events[0]['site'],'owned-control')
            self.assertEqual(a.memory_events[0]['_processStartIdentity'],'99')
            self.assertEqual(report['unassignedTargetLifetimeCount'],1)
            self.assertEqual(report['summary']['failureDetailsObserved'],1)
            self.assertTrue(any(x['kind']=='memory-events' and x.get('sha256') for x in a.sources))


if __name__=='__main__':unittest.main()
