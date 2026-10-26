#!/usr/bin/env python3
"""Owned CPU/filesystem fixtures only; never execute a collector or game."""
import json
from decimal import Decimal as D
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock
import capture_stutter_session as session
import capture_stutter_system as system
import analyze_stutter_capture as analysis
from capture_foreground_stutter import foreground_intervals

PID=424242

def header(g=1,run=1,session_id=7,domain='mach-absolute-nanoseconds'):
    return dict(schema=1,type='clockCalibration',pid=PID,runID=run,streamGeneration=g,session=session_id,
                machBeforeNS=1000000000,machAfterNS=1000000100,timeCF=100,clockDomain=domain)
def event(seq=1,run=1,kind='resourceEncoderEnd'):
    return dict(schema=1,type='forensics',kind=kind,pid=PID,runID=run,seq=seq,session=7,
        machNS=2000000000,threadMachID=99,context=dict(domain=1,queueFamily=0,queueIndex=0,logicalSubmit=3,nativeCB=2,frame=4,shader=5),
        fields={'calls':100},payload={'ownerPipeline':123})
def lines(*rows):return b''.join((json.dumps(r)+'\n').encode() for r in rows)
def fg(t,good=True,available=True):return dict(time=t,pid=PID,foreground=good,visible=good,active=good,frontmostPID=PID if good else 1,allWindowListAvailable=available,nativeApplicationStateAvailable=available)

class Controls(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='session-cpu-',dir=system.ROOT/'evidence');self.root=Path(self.tmp.name)
        self.trace=self.root/'trace';self.out=self.root/'out';self.trace.mkdir();self.out.mkdir()
    def tearDown(self):self.tmp.cleanup()
    def slot(self,g=1,run=1,slot=0,data=None):
        path=self.trace/f'forensics-{PID}-{run}-{slot}.jsonl';path.write_bytes(data or lines(header(g,run),event(g,run)));return path
    def test_foreground_no_tail_or_transition_guess(self):
        r=foreground_intervals([fg(D('100')),fg(D('101')),fg(D('102'),False),fg(D('103'),False),fg(D('110'))])
        self.assertEqual([(x['startCF'],x['endCF'],x['state']) for x in r['intervals']],[(D(100),D(101),'foreground'),(D(101),D(102),'unknown'),(D(102),D(103),'background'),(D(103),D(110),'unknown')])
        self.assertFalse(r['tailExtrapolated']);self.assertEqual(r['lastObservationCF'],110)
        a=analysis.Analyzer(target_pid=PID);a.foreground=[fg(100),fg(101)];a.ca_to_cf=lambda v,*args:v
        report=a._frame_system(PID,D(102),D(103),7)
        self.assertEqual(report['foregroundContinuity'],[]);self.assertTrue(report['lastForegroundObservation']['contextOnlyNotIntervalProof'])
    def test_unavailable_foreground_is_unknown(self):
        r=foreground_intervals([fg(1,False,False),fg(2,False,False)])
        self.assertEqual(r['intervals'][0]['state'],'unknown')
    def test_window_rearm_and_stale_foreground(self):
        p=session.WindowPolicy(window=10,every=20,cooldown=6,maximum=3)
        self.assertEqual(p.poll(0), 'startup');self.assertIsNone(p.poll(9));self.assertEqual(p.poll(10),'end')
        for t in [10,11,12]:p.observe(fg(t))
        self.assertIsNone(p.poll(31,cf_now=50))
        self.assertEqual(p.poll(31,pinned=True,cf_now=50),'manual-pin');self.assertEqual(p.poll(41),'end')
        self.assertIsNone(p.poll(44,pinned=True));self.assertEqual(p.poll(48,pinned=True),'manual-pin');self.assertEqual(p.poll(58),'end');self.assertIsNone(p.poll(70,pinned=True))
    def test_marker_lease_restore_and_external_change(self):
        p=self.root/'cpu.arm';p.write_text('keep');old=p.stat().st_mtime_ns
        lease=session.MarkerLease({'cpu':p,'native':p});lease.arm();self.assertEqual(len(lease.stamps),1);lease.close()
        self.assertEqual(p.read_text(),'keep');self.assertEqual(p.stat().st_mtime_ns,old)
        lease.arm();p.write_text('external');result=lease.close();self.assertFalse(result[0]['restored']);self.assertEqual(p.read_text(),'external')
    def test_spool_preserves_complete_bytes_and_partial_tail(self):
        data=lines(header(),event());path=self.slot(data=data[:-1]);spool=session.ForensicsSpool(PID,self.trace,self.out)
        r=spool.poll();self.assertFalse(r['capped']);self.assertEqual(sum(p.stat().st_size for p in spool.targets.values()),len(lines(header())))
        with path.open('ab') as f:f.write(b'\n')
        spool.poll();saved=b''.join(p.read_bytes() for p in spool.targets.values());self.assertEqual(saved,data)
    def test_per_poll_budget_does_not_end_total_capture(self):
        data=lines(header(),event(1),event(2));self.slot(data=data)
        spool=session.ForensicsSpool(PID,self.trace,self.out,max_bytes=4096,per_poll=400)
        for _ in range(5):r=spool.poll()
        self.assertFalse(r['capped']);self.assertEqual(b''.join(p.read_bytes() for p in spool.targets.values()),data)
    def test_overwrite_and_generation_gap_are_explicit(self):
        path=self.slot(data=lines(header(),event(),event(2)));spool=session.ForensicsSpool(PID,self.trace,self.out,per_poll=300)
        spool.poll();path.write_bytes(lines(header(5),event(9)));result=spool.poll()
        reasons={e.get('reason') for e in result['events']}
        self.assertIn('slot-overwritten-before-drain',reasons);self.assertIn('unobserved-stream-generations',reasons)
    def test_run_id_selects_current_and_keeps_identity(self):
        self.slot(run=1);self.slot(run=2);(self.trace/f'forensics-current-{PID}.json').write_text(json.dumps({'runID':2}))
        spool=session.ForensicsSpool(PID,self.trace,self.out);spool.poll()
        self.assertEqual(spool.run_id,2);self.assertTrue(all('-run-2-' in p.name for p in spool.targets.values()))
    def test_copy_total_budget_visible(self):
        self.slot();spool=session.ForensicsSpool(PID,self.trace,self.out,max_bytes=len(lines(header())))
        r=spool.poll();self.assertTrue(r['capped']);self.assertLessEqual(spool.saved,spool.max_bytes)
    def test_forensics_clock_context_and_missing_pipeline(self):
        p=self.root/f'forensics-{PID}-fixture.jsonl';p.write_bytes(lines(header(),event()))
        a=analysis.Analyzer(target_pid=PID);a.load_forensics([p]);a.cbs[(PID,2)]={'logicalSubmit':3}
        r=a.forensics_report();record=r['records'][0]
        self.assertEqual(record['timeCF'],D('100.99999995'));self.assertEqual(record['calibrationBracketHalfNS'],50)
        self.assertTrue(record['nativeGraphJoined']);self.assertEqual(record['pipeline'],123);self.assertNotIn('pipeline',record['context'])
        self.assertIn('unjoinable',next(x for x in r['stageMatrix'] if x['stage']=='thread-counter-to-native-thread')['statuses'])
    def test_steady_clock_is_never_mapped_as_mach(self):
        p=self.root/f'forensics-{PID}-badclock.jsonl';p.write_bytes(lines(header(domain='std-steady'),event()))
        a=analysis.Analyzer(target_pid=PID);a.load_forensics([p]);r=a.forensics_report();self.assertIsNone(r['records'][0]['timeCF'])
        self.assertIn('unjoinable',next(x for x in r['stageMatrix'] if x['stage']=='resource-heap-descriptors')['statuses'])
    def test_caps_and_unknown_driver_coverage(self):
        p=self.root/f'forensics-current-{PID}.json';p.write_text(json.dumps({'runID':1,'dropped':2,'IOFailures':1}))
        a=analysis.Analyzer(target_pid=PID);a.forensic_rows=[header(),event(1),event(3)]
        for row in a.forensic_rows:row.update(_pid=PID)
        a.load_forensics(current=[p]);r=a.forensics_report()
        self.assertTrue(r['sequenceGaps']);self.assertTrue(r['nativeCounterPrefixUnknown']);self.assertFalse(r['allCausesFound'])
        self.assertEqual(r['nativeCounterPrefixUnknown'][0]['alreadyNonzeroAtFirstSnapshot'],dict(dropped=2,IOFailures=1))
        self.assertFalse(r['nativeCounterWindows'][0]['observedDelta'])
        self.assertEqual(next(x for x in r['stageMatrix'] if x['stage']=='closed-driver-internals')['statuses'],['missing','unjoinable'])
    def test_no_game_process_launch_for_discovery_or_cpu_join(self):
        with mock.patch.object(session.system,'command',return_value={'stdout':'42 C:/x/SB-Win64-Shipping.exe\n43 C:/Steam.exe\n'}),mock.patch.object(session.subprocess,'Popen',side_effect=AssertionError('No process may launch in this fixture')):
            self.assertEqual(session.discover(),[42])
        r=system.thread_delta({'threads':{'0x63':{'name':'same name','user':5,'system':2,'runState':1,'sleepSeconds':0,'priority':1}}},{'threads':{'0x63':{'user':1,'system':1}}})
        self.assertIn('unjoinable',r['nativeMachThreadJoin']);self.assertEqual(r['rows'][0]['handle'],'0x63')
    def guest_header(self):
        return dict(schema=1,type='clockCalibration',windowsPID=77,runID=8,streamGeneration=1,session=116444736000000007,
                    qpcBefore=1000,qpcAfter=1002,qpcFrequency=1000,fileTimeUTC100ns=116444736000000000+(system.CF_EPOCH+100)*10000000,clockDomain='windows-qpc')
    def guest_event(self,seq=1,phase=0,qpc=1901,args=None):
        return dict(schema=1,type='event',windowsPID=77,runID=8,streamGeneration=1,session=116444736000000007,
                    seq=seq,qpc=qpc,windowsThreadID=99,kind=5,phase=phase,id=12,parent=11,args=args or [0]*8)
    def test_guest_rolling_namespace_and_original_bytes(self):
        data=lines(self.guest_header(),self.guest_event())
        (self.trace/'vkd3d-forensics-77-8-0.jsonl').write_bytes(data)
        current=lines({'windowsPID':77,'runID':8})
        (self.trace/'vkd3d-forensics-current-77-8.json').write_bytes(current)
        spool=session.GuestSpool(self.trace,self.out,4096,0);r=spool.poll()
        self.assertTrue(r['available']);self.assertFalse(r['capped']);self.assertIn('unjoinable',r['hostPIDJoin'])
        self.assertEqual(Path(spool.raw_paths()[0]).read_bytes(),data)
        self.assertEqual((self.out/'vkd3d-forensics-current-snapshots.jsonl').read_bytes(),current)
    def test_guest_qpc_and_body_envelope_are_separate(self):
        a=analysis.Analyzer(target_pid=PID)
        a.guest_rows=[self.guest_header(),self.guest_event(),self.guest_event(2,1,2001,[1,2,3,80,(1<<64)-4,1,0,1921])]
        a.guest_current=[{'windowsPID':77,'runID':8}]
        r=a.guest_report();end=r['records'][1];span=r['pairedSoftwareSpans'][0]
        self.assertEqual(end['timeCF'],101);self.assertEqual(end['guestPID'],77);self.assertEqual(end['sessionUnixNS'],700)
        self.assertEqual(span['envelopeElapsedMs'],100);self.assertEqual(span['actualBodyElapsedMs'],80);self.assertEqual(span['originalSignedResult'],-4)
        self.assertIn('unjoinable',r['statuses']);self.assertNotIn('missing',r['statuses'])
    def test_guest_missing_calibration_session_and_metadata_are_visible(self):
        a=analysis.Analyzer(target_pid=PID);row=self.guest_event();row.pop('session');a.guest_rows=[row]
        r=a.guest_report();self.assertEqual(r['clockUnjoinable'],1);self.assertIn('missing',r['statuses']);self.assertIsNone(r['records'][0]['timeCF'])
        self.assertIn('guest-current-metadata-not-observed',{x['reason'] for x in r['missingMetadata']})
    def test_guest_copy_cumulative_differences_across_sessions(self):
        a=analysis.Analyzer(target_pid=PID)
        a.guest_rows=[dict(type='copyCumulative',runID=8,shardIndex=2,session=10,qpc=1,offeredCalls=100,offeredDescriptors=1000,sampledCalls=2,sampledWallQPC=30,samplePeriod=64,nonAtomicCumulativeSnapshot=True),
                      dict(type='copyCumulative',runID=8,shardIndex=2,session=20,qpc=2,offeredCalls=120,offeredDescriptors=1500,sampledCalls=3,sampledWallQPC=35,samplePeriod=64,nonAtomicCumulativeSnapshot=True)]
        d=a.guest_report()['copyDescriptorCumulativeDeltas'][0]
        self.assertEqual(d['measuredCumulativeDelta'],dict(offeredCalls=20,offeredDescriptors=500,sampledCalls=1,sampledWallQPC=5));self.assertFalse(d['extrapolated']);self.assertEqual((d['fromSession'],d['toSession']),(10,20))
    def test_cpu_sampled_scopes_are_not_extrapolated(self):
        a=analysis.Analyzer(target_pid=PID)
        a.cpu_reports=[dict(schema=1,pid=PID,captureEnabled=True,detailedEnabled=True,fineScopeTimingsSampled=True,
            fineScopeSampling=[dict(domain=1,stage=2,scopeSampleEvery=64,offeredAtScopeBegin=101)],
            rows=[dict(domain=1,stage=2,name='DescriptorCacheLock',kind='Wait',count=2,selfWallNS=200,inclusiveWallNS=250,threadCPUCount=1,inclusiveThreadCPUNS=50)],submissions=[],
            slowSpans=[dict(domain=1,stage=2,thread=99,tag=123,submission=3,startNS=100,endNS=200,threadCPUNS=50)],inFlight=[])]
        r=a.report();phase=r['CPUPhaseRanking'][0]
        self.assertEqual((phase['count'],phase['selfWallNS'],phase['samplingEvery']),(2,200,64));self.assertFalse(phase['extrapolated'])
        self.assertEqual(r['CPUFineScopeSampling'][0]['offeredAtScopeBegin'],101)
        self.assertEqual((phase['threadCPUCount'],phase['inclusiveThreadCPUNS']),(1,50));self.assertEqual(r['CPUObservedSpans'][0]['measured']['tag'],123)
        self.assertIn('sampled',next(x for x in r['coverage']['matrix'] if x['layer']=='cpu-fine-scopes')['statuses'])
    def test_one_run_primes_before_discovery_and_cleans_only_mock_helper(self):
        profile=self.root/'profile';profile.mkdir();out=self.root/'session'
        args=SimpleNamespace(output=out,profile=profile,max_seconds=3,wait_seconds=2,interval=1,system_every=5,trace_every=2,
            arm_seconds=20,arm_every=120,max_windows=2,pin_marker='diagnostics.pin',max_threads=32,max_output_mib=128,forensics_mib=64,
            guest_forensics_mib=32,cpu_current_mib=64,d3d_directory=None,min_free_mib=512,max_collection_fraction=.5,overhead_grace_rows=15)
        kernel=mock.Mock();kernel.timebase=dict(numer=1,denom=1);kernel.usage.return_value=dict(available=True,processStartAbstime=1000,userTime=0,systemTime=0)
        kernel.task.return_value=dict(available=False);kernel.threads.return_value=dict(available=True,threads={})
        clock=dict(UTC='synthetic',CFAbsoluteTime=100,unixSeconds=system.CF_EPOCH+100,machAbsoluteTicks=2000,monotonicSeconds=1)
        ticks=iter(x/2 for x in range(100));helper=mock.Mock();helper.poll.return_value=None
        def discover_primed():
            self.assertTrue((profile/'forensics.arm').is_file());return [PID]
        with (mock.patch.object(session.system,'Kernel',return_value=kernel),mock.patch.object(session.system,'stamp',return_value=clock),mock.patch.object(session.system,'identity',return_value=dict(pid=PID,present=True,lstart='synthetic')),
             mock.patch.object(session,'discover',side_effect=discover_primed),mock.patch.object(session.time,'monotonic',side_effect=lambda:next(ticks)),mock.patch.object(session.time,'sleep'),mock.patch.object(session.shutil,'disk_usage',return_value=SimpleNamespace(free=3*1024**3)),
             mock.patch.object(session.system,'system_snapshot',return_value={}),mock.patch.object(session.subprocess,'Popen',return_value=helper) as popen):
            result=session.run(args)
        self.assertFalse(result['targetLaunchStopOrInputUsed']);self.assertFalse(list(profile.glob('*.arm')))
        self.assertEqual(json.loads((out/'metadata.json').read_text())['processStartAbstime'],1000)
        self.assertTrue(all(Path(call.args[0][0]).name=='observe_game_activity' for call in popen.call_args_list))
    def test_cached_inventory_refreshes_known_present_contents(self):
        path=self.trace/f'trace-present-progress-{PID}-3.json';path.write_text(json.dumps({'time':100,'count':1}))
        reader=system.NativeReader(PID,self.trace,inventory_every=15);reader.read(100)
        path.write_text(json.dumps({'time':101,'count':2}));r=reader.read(102)
        self.assertIsNone(r['fileCountDelta']);self.assertEqual(r['latestPresent']['numericFields']['count'],2)
        self.assertEqual(r['latestPresent']['sourceAgeSeconds'],1)
    def test_cpu_current_status_archive_preserves_bytes_and_caps(self):
        raw=lines({'schema':1,'rows':[],'windowEndNS':2});source=self.trace/f'cpu-stutter-current-{PID}.json';source.write_bytes(raw)
        status=lines({'schema':1,'historyRowsSkipped':3});(self.trace/f'cpu-stutter-status-{PID}.json').write_bytes(status)
        spool=session.CPUSnapshotSpool(PID,self.trace,self.out,len(raw)+len(status));first=spool.poll()
        self.assertFalse(first['capped']);self.assertEqual(spool.paths['cpu-stutter-current'].read_bytes(),raw)
        source.write_bytes(lines({'schema':1,'windowEndNS':3}));self.assertTrue(spool.poll()['capped'])
        self.assertEqual(source.read_bytes(),lines({'schema':1,'windowEndNS':3}))
    def test_native_scope_and_ca_coarse_gpu_are_not_mach(self):
        a=analysis.Analyzer(target_pid=PID);h=header();h['timeCA']=10
        begin=event(1,kind='QueueExecute');begin['fields']=dict(spanID=5,phase=0,startMachNS=1500000000,elapsedWallNS=0)
        end=event(2,kind='QueueExecute');end['fields']=dict(spanID=5,phase=1,startMachNS=1500000000,elapsedWallNS=500000000)
        complete=event(3,kind='NativeCBCompleted');complete['fields']=dict(ownerNativeCB=2,ownerSubmit=3,gpuStartCANS=12000000000,gpuEndCANS=12200000000)
        present=event(4,kind='NativePresentedFrame');present['fields']=dict(frame=4,nativeTimestampCANS=12210000000,nativeTimestampValid=1)
        a.forensic_rows=[h,begin,end,complete,present];r=a.forensics_report()
        self.assertTrue(r['slowSoftwareScopes'][0]['pairedBeginObserved']);self.assertEqual(r['slowSoftwareScopes'][0]['elapsedWallNS'],500000000)
        self.assertEqual(r['coarseCommandBuffers'][0]['gpuStartCF'],102);self.assertEqual(r['coarsePresents'][0]['nativeTimestampCF'],D('102.21'))
    def test_cumulative_drop_deltas_do_not_poison_later_arms(self):
        rows=[dict(windowsPID=77,runID=8,session=1,ringDrops=9),dict(windowsPID=77,runID=8,session=2,ringDrops=9),dict(windowsPID=77,runID=8,session=3,ringDrops=11)]
        first=analysis.cumulative_counter_windows(rows[:2],('ringDrops',),'windowsPID')[0]
        self.assertEqual(first['alreadyNonzeroAtFirstSnapshot'],dict(ringDrops=9));self.assertEqual(first['observedDelta'],{})
        self.assertEqual(analysis.cumulative_counter_windows(rows,('ringDrops',),'windowsPID')[0]['observedDelta'],dict(ringDrops=2))
        sessions=analysis.cumulative_counter_sessions(rows,('ringDrops',),'windowsPID')
        self.assertEqual(sessions[1]['statuses'],['observed']);self.assertEqual(sessions[2]['boundaryUnassignedIncreases'],dict(ringDrops=2))
    def test_saved_encoder_owner_wins_after_native_split(self):
        a=analysis.Analyzer(target_pid=PID);row=event();row['context']['nativeCB']=2
        row['fields']=dict(ownerNativeCB=1,ownerSubmission=3,ownerQueueFamily=0,ownerQueueIndex=0,vulkanPipeline=44,nativePipeline=55)
        h=header();h['_pid']=PID;row['_pid']=PID
        a.forensic_rows=[h,row];a.cbs[(PID,1)]={'logicalSubmit':3}
        r=a.forensics_report()['records'][0]
        self.assertEqual(r['context']['nativeCB'],2);self.assertEqual(r['savedOwnerContext']['nativeCB'],1)
        self.assertTrue(r['nativeGraphJoined']);self.assertEqual((r['linkedNativeCB'],r['pipeline'],r['nativePipeline']),(1,44,55))
    def test_resource_api_cumulative_operation_shards_and_final_boundary(self):
        a=analysis.Analyzer(target_pid=PID)
        a.guest_rows=[dict(type='resourceAPICumulative',runID=8,shardIndex=2,session=10,qpc=1,operation=1,offeredCalls=10,offeredUnits=10,sampledCalls=0,sampledWallQPC=0,samplePeriod=64,nonAtomicCumulativeSnapshot=True),
                      dict(type='resourceAPICumulative',runID=8,shardIndex=2,session=20,qpc=2,operation=1,offeredCalls=74,offeredUnits=74,sampledCalls=1,sampledWallQPC=5,samplePeriod=64,finalBoundary=1,nonAtomicCumulativeSnapshot=True),
                      dict(type='resourceAPICumulative',runID=8,shardIndex=2,session=20,qpc=2,operation=2,offeredCalls=3,offeredUnits=3,sampledCalls=0,sampledWallQPC=0,samplePeriod=64,finalBoundary=1)]
        r=a.guest_report();d=r['resourceAPICumulativeDeltas'][0]
        self.assertEqual(d['operationName'],'ResourceMap');self.assertEqual(d['measuredCumulativeDelta'],dict(offeredCalls=64,offeredUnits=64,sampledCalls=1,sampledWallQPC=5));self.assertFalse(d['extrapolated'])
        self.assertTrue(d['finalBoundaryAtEnd']);self.assertEqual(len(r['cumulativeStreams']),2);self.assertEqual(r['copyDescriptorCumulativeDeltas'],[])
        self.assertEqual(r['cumulativeStreams'][1]['operationName'],'ResourceUnmap');self.assertTrue(r['cumulativeStreams'][1]['finalBoundaryBySession']['20'])
    def test_resource_memory_kind_classification_and_unsampled_failure(self):
        a=analysis.Analyzer(target_pid=PID);failure=self.guest_event(1,2,2001,[10,(1<<64)-3,7,1,1,0,0,0]);failure['kind']=28
        memory=self.guest_event(2,2,2002,[90,4096,3,0,0,0,0,0]);memory['kind']=26
        ctor=self.guest_event(3,0,2003);ctor['kind']=21
        a.guest_rows=[self.guest_header(),failure,memory,ctor];a.guest_current=[dict(windowsPID=77,runID=8)]
        r=a.guest_report();self.assertEqual(r['records'][0]['kindName'],'ResourceMap');self.assertEqual(r['records'][0]['unsampledFailureDetail']['originalSignedResult'],-3)
        self.assertTrue(r['records'][0]['unsampledFailureDetail']['timedSampleNotImplied']);self.assertEqual(r['records'][1]['memoryHandleDetail']['allocationSizeBytes'],4096)
        self.assertEqual(r['resourceKindCounts'],dict(ResourceMap=1,VkDeviceMemoryHandle=1,createCommittedResource=1))
    def test_guest_vulkan_details_join_same_id_across_generations(self):
        a=analysis.Analyzer(target_pid=PID);begin=self.guest_event(1,0,1901);begin.update(id=78,parent=77,streamGeneration=2)
        detail=self.guest_event(2,2,1902,[10,20,30,40,0,1,0,0]);detail.update(kind=6,id=78,parent=77,streamGeneration=2)
        end=self.guest_event(3,1,2001,[0,0,0,90,0,1,0,1911]);end.update(id=78,parent=77,streamGeneration=3)
        a.guest_rows=[self.guest_header(),begin,detail,end];r=a.guest_report();scope=r['vulkanScopeDetails'][0]
        self.assertTrue(scope['paired']);self.assertEqual(scope['id'],78);self.assertEqual(scope['outerParent'],77)
        self.assertEqual(scope['details'][0]['kindName'],'waitSemaphoreEdge');self.assertEqual(r['unresolvedVulkanScopeDetailCount'],0)

if __name__=='__main__':unittest.main()
