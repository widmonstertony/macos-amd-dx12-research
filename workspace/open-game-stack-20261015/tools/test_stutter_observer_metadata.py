#!/usr/bin/env python3
"""Pure/mocked metadata and append-only retention checks; no live sampler."""
import json
import os
from contextlib import ExitStack
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import capture_stutter_system as system
import capture_stutter_session as session
import mac_session_state as mac


class ObserverMetadata(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve()
    def tearDown(self):self.temp.cleanup()
    def test_missing_and_conflicting_session_flags_remain_unknown(self):
        selected={key:None for key in mac.SESSION_KEYS};selected.update(kCGSessionOnConsoleKey=True,kCGSSessionOnConsoleKey=False)
        nodes=[{'available':True,'node':{'IOPowerManagement':{'CurrentPowerState':4,'UnselectedSecret':'omit'},'UserName':'omit'}},
               {'available':True,'node':{'HIDIdleTime':123,'Password':'omit'}}]
        with mock.patch.object(mac,'_session_booleans',return_value={'available':True,'selected':selected}),mock.patch.object(mac,'_ioreg_node',side_effect=nodes):result=mac.session_state()
        self.assertIsNone(result['screenLocked']);self.assertFalse(result['lockStateKnown']);self.assertIsNone(result['onConsole'])
        self.assertFalse(result['historicalStateKnown']);self.assertFalse(result['physicalDisplayVisibilityKnown'])
        self.assertEqual(result['displayPower']['selected'],{'CurrentPowerState':4});self.assertEqual(result['idle']['HIDIdleTimeNS'],123)
        self.assertNotIn('omit',json.dumps(result));self.assertFalse(result['privateSessionFieldsRead'])
    def test_ioreg_timeout_has_no_raw_error_or_identity_payload(self):
        with mock.patch.object(mac.subprocess,'run',side_effect=subprocess.TimeoutExpired(['ioreg'],1,output=b'private')):
            result=mac._ioreg_node('IOHIDSystem')
        self.assertFalse(result['available']);self.assertNotIn('private',json.dumps(result))
    def test_explicit_false_lock_is_preserved_and_idle_never_overrides_it(self):
        selected={key:None for key in mac.SESSION_KEYS};selected['CGSSessionScreenIsLocked']=False
        with mock.patch.object(mac,'_session_booleans',return_value={'available':True,'selected':selected}),mock.patch.object(mac,'_ioreg_node',return_value={'available':False}):result=mac.session_state()
        self.assertTrue(result['lockStateKnown']);self.assertIs(result['screenLocked'],False)
    def test_configuration_hash_caches_stat_key_and_generations_follow_content(self):
        path=self.root/'game-trial-config.h';path.write_text('first')
        tracker=system.ConfigurationTracker([path]);original=Path.read_bytes
        with mock.patch.object(Path,'read_bytes',autospec=True,side_effect=lambda file:original(file)) as read:
            first=tracker.poll();same=tracker.poll();self.assertEqual(read.call_count,1)
            state=path.stat();os.utime(path,ns=(state.st_atime_ns,state.st_mtime_ns+1))
            touched=tracker.poll();self.assertEqual(read.call_count,2)
            path.write_text('second');changed=tracker.poll();self.assertEqual(read.call_count,3)
        self.assertTrue(first['known']);self.assertEqual(first['generation'],same['generation']);self.assertEqual(first['generation'],touched['generation'])
        self.assertEqual(changed['generation'],first['generation']+1);self.assertNotEqual(first['sha256'],changed['sha256'])
        self.assertNotIn('first',json.dumps(first))
    def test_process_and_window_identity_are_scoped_to_start_generation(self):
        first=system.process_identity(dict(pid=42,present=True,lstart='first'),100)
        second=system.process_identity(dict(pid=42,present=True,lstart='second'),200)
        tracker=system.WindowIdentityTracker();window=dict(windowID=7,matchedWindowExists=True,time=100)
        one=tracker.observe(window,first);two=tracker.observe(window,second);missing=tracker.observe({},second)
        self.assertNotEqual(first['key'],second['key']);self.assertNotEqual(one['key'],two['key']);self.assertEqual(two['generation'],2)
        self.assertFalse(missing['known']);self.assertIsNone(missing['windowID']);self.assertFalse(one['currentWindowStateProved'])
    def test_display_cache_exposes_point_age_without_interval_proof(self):
        snapshot=dict(observedUnixSeconds=100,observedMonotonicSeconds=10,screenLocked=None,lockStateKnown=False,historicalStateKnown=False)
        sampler=system.DisplaySessionSampler(every=2)
        with mock.patch.object(system,'session_state',return_value=snapshot) as query:
            first=sampler.poll(dict(unixSeconds=100,monotonicSeconds=10));later=sampler.poll(dict(unixSeconds=101,monotonicSeconds=11))
        self.assertEqual(query.call_count,1);self.assertTrue(first['sampledThisRow']);self.assertTrue(later['carriedForwardContextOnly'])
        self.assertEqual(later['observationAgeSeconds'],1);self.assertFalse(later['intervalStateProved']);self.assertIsNone(later['screenLocked'])
    def test_human_action_marker_whitelist_timestamps_and_no_extra_payload(self):
        path=self.root/'diagnostics.action.json';path.write_text(json.dumps(dict(action='attack',phase='start',password='never-retain')))
        reader=system.HumanActionMarkers(path);clock=dict(unixSeconds=100,monotonicSeconds=10)
        event=reader.poll(clock);self.assertIsNone(reader.poll(clock))
        self.assertEqual((event['action'],event['phase']),('attack','start'));self.assertIn('markerMtimeUnixNS',event)
        self.assertEqual(event['observedClock'],clock);self.assertFalse(event['gameInputGenerated']);self.assertFalse(event['gameActionVerified'])
        self.assertNotIn('never-retain',json.dumps(event));path.write_text('{"action":"typed-command"}');self.assertEqual(reader.poll(clock)['status'],'unjoinable')
    def test_action_quota_cannot_consume_future_action_or_telemetry_reserve(self):
        retention=session.ActionRetention({'forensics':700,'cpu':1400})
        self.assertEqual(retention.remaining('forensics','attack'),100);retention.charge('forensics',None,100)
        self.assertEqual(retention.remaining('forensics',None),0);self.assertEqual(retention.remaining('forensics','attack'),100)
        retention.charge('forensics','attack',100);self.assertEqual(retention.remaining('forensics','equipment'),100)
        self.assertFalse(retention.report()['rawCapacityVerifiedForActionDuration'])
    def test_action_windows_keep_raw_bytes_after_previous_window_caps(self):
        trace=self.root/'trace';trace.mkdir();out1=self.root/'first';out1.mkdir();out2=self.root/'second';out2.mkdir()
        calibration={'schema':1,'type':'clockCalibration','runID':1,'streamGeneration':1,'machAfterNS':1}
        header=(json.dumps(calibration)+'\n').encode();record=b'{"type":"forensics","seq":1}\n'
        (trace/'forensics-42-1-0.jsonl').write_bytes(header+record)
        one=session.ForensicsSpool(42,trace,out1,max_bytes=len(header));self.assertTrue(one.poll()['capped'])
        preserved=next(iter(one.targets.values())).read_bytes();two=session.ForensicsSpool(42,trace,out2,max_bytes=4096);self.assertFalse(two.poll()['capped'])
        self.assertEqual(preserved,header);self.assertEqual(next(iter(one.targets.values())).read_bytes(),header)
        self.assertEqual(next(iter(two.targets.values())).read_bytes(),header+record)
    def test_selected_arm_ignores_old_ring_bytes_and_copies_new_arm_verbatim(self):
        trace=self.root/'trace';trace.mkdir();out=self.root/'out';out.mkdir()
        def payload(generation,arm):return (json.dumps(dict(schema=1,type='clockCalibration',runID=1,streamGeneration=generation,session=arm,machAfterNS=1))+'\n{"seq":'+str(generation)+'}\n').encode()
        old=payload(1,100);new=payload(2,200)
        (trace/'forensics-42-1-0.jsonl').write_bytes(old)
        spool=session.ForensicsSpool(42,trace,out,max_bytes=4096,selected_session=200)
        before=spool.poll();self.assertFalse(before['matchingSessionObserved']);self.assertEqual(spool.saved,0)
        (trace/'forensics-42-1-1.jsonl').write_bytes(new);after=spool.poll()
        self.assertTrue(after['matchingSessionObserved']);self.assertEqual(spool.saved,len(new))
        self.assertEqual(b''.join(path.read_bytes() for path in spool.targets.values()),new)
    def test_guest_selected_arm_uses_measured_filetime_without_host_pid_guess(self):
        trace=self.root/'trace';trace.mkdir();out=self.root/'out';out.mkdir()
        selected=116444736000000000+123456789//100
        old=(json.dumps(dict(schema=1,type='clockCalibration',windowsPID=77,runID=8,streamGeneration=1,session=selected-1))+'\n').encode()
        new=(json.dumps(dict(schema=1,type='clockCalibration',windowsPID=77,runID=8,streamGeneration=2,session=selected))+'\n').encode()
        (trace/'vkd3d-forensics-77-8-0.jsonl').write_bytes(old);(trace/'vkd3d-forensics-77-8-1.jsonl').write_bytes(new)
        spool=session.GuestSpool(trace,out,4096,0,selected_session=selected);result=spool.poll()
        self.assertTrue(result['guests'][0]['matchingSessionObserved']);self.assertIn('unjoinable',result['hostPIDJoin'])
        self.assertEqual(b''.join(Path(path).read_bytes() for path in spool.raw_paths()),new)
    def test_retired_window_drains_delayed_owner_end_through_six_second_grace(self):
        trace=self.root/'trace';trace.mkdir();out=self.root/'out';out.mkdir();now=[0.]
        header=(json.dumps(dict(schema=1,type='clockCalibration',runID=1,streamGeneration=1,session=7,machAfterNS=1))+'\n').encode()
        begin=b'{"seq":1,"session":7,"kind":"Begin"}\n';end=b'{"seq":2,"session":7,"kind":"End"}\n'
        source=trace/'forensics-42-1-0.jsonl';source.write_bytes(header+begin)
        retention=session.ActionRetention({'forensics':70000,'cpu':70000});spool=session.ForensicsSpool(42,trace,out,max_bytes=10000,selected_session=7)
        group=dict(index=1,label='attack',directory=str(out),spool=spool,cpu=session.CPUSnapshotSpool(42,trace,out,10000),guest=None,charged={'forensics':0,'cpu':0,'guest':0},coverageWarnings=[])
        with mock.patch.object(session.time,'monotonic',side_effect=lambda:now[0]):
            session.poll_raw_group(group,retention,lambda:100000,{'monotonicSeconds':0});session.retire_raw_group(group,{'monotonicSeconds':0})
            now[0]=3;source.write_bytes(header+begin+end);session.drain_retired_groups([group],retention,lambda:100000,{'monotonicSeconds':3})
            self.assertFalse(group['tailGraceComplete']);now[0]=6;session.drain_retired_groups([group],retention,lambda:100000,{'monotonicSeconds':6})
        self.assertTrue(group['tailGraceComplete']);self.assertEqual(group['lastDrainClock']['monotonicSeconds'],6)
        self.assertEqual(next(iter(spool.targets.values())).read_bytes(),header+begin+end);self.assertEqual(retention.used['forensics']['attack'],len(header+begin+end))
    def test_physical_stream_keeps_old_logical_owner_and_excluded_generations_are_not_loss(self):
        trace=self.root/'trace';trace.mkdir();out=self.root/'out';out.mkdir()
        def payload(generation,physical,owner):
            return (json.dumps(dict(schema=1,type='clockCalibration',runID=1,streamGeneration=generation,session=physical,machAfterNS=1))+'\n'+json.dumps(dict(seq=generation,session=owner,streamSession=physical))+'\n').encode()
        (trace/'forensics-42-1-0.jsonl').write_bytes(payload(1,7,7));new=payload(2,8,7);(trace/'forensics-42-1-1.jsonl').write_bytes(new)
        spool=session.ForensicsSpool(42,trace,out,max_bytes=4096,selected_session=8);spool.poll()
        (trace/'forensics-42-1-2.jsonl').write_bytes(payload(3,7,7));next_stream=payload(4,8,8);(trace/'forensics-42-1-3.jsonl').write_bytes(next_stream);result=spool.poll()
        self.assertFalse(any(event.get('missingCount') for event in result['events']))
        self.assertEqual(b''.join(path.read_bytes() for path in spool.targets.values()),new+next_stream)
    def test_observer_cost_is_reported_without_fps_arithmetic(self):
        result=system.observer_cost({'userTime':123},.5)
        self.assertEqual(result['collectorCounterDelta'],{'userTime':123});self.assertEqual(result['collectionWallSeconds'],.5)
        self.assertFalse(any('FPS' in key or 'fps' in key for key in result))
    def mock_session(self,free_bytes=3*1024**3,reported_output_bytes=None):
        evidence=self.root/'evidence';evidence.mkdir();profile=evidence/'profile';profile.mkdir();(profile/'game-trial-config.h').write_text('synthetic configuration')
        out=evidence/'session';now=[0.]
        args=SimpleNamespace(output=out,profile=profile,max_seconds=6,wait_seconds=5,interval=1,system_every=5,trace_every=2,
            arm_seconds=10,arm_every=30,max_windows=10,pin_marker='diagnostics.pin',max_threads=32,max_output_mib=16,
            forensics_mib=0,cpu_current_mib=1,guest_forensics_mib=1,d3d_directory=None,min_free_mib=512,max_collection_fraction=.5,overhead_grace_rows=15)
        kernel=mock.Mock();kernel.timebase=dict(numer=1,denom=1);kernel.usage.return_value=dict(available=True,processStartAbstime=1000,userTime=0,systemTime=0)
        kernel.task.return_value=dict(available=False);kernel.threads.return_value=dict(available=True,threads={})
        def clock(*_):return dict(UTC='synthetic',CFAbsoluteTime=100+now[0],unixSeconds=system.CF_EPOCH+100+now[0],machAbsoluteTicks=2000+int(now[0]*1e9),monotonicSeconds=now[0])
        def snapshot():return dict(observedUnixSeconds=clock()['unixSeconds'],observedMonotonicSeconds=now[0],screenLocked=None,lockStateKnown=False,historicalStateKnown=False)
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(session,'ROOT',self.root));stack.enter_context(mock.patch.object(system,'Kernel',return_value=kernel))
            stack.enter_context(mock.patch.object(system,'stamp',side_effect=clock));stack.enter_context(mock.patch.object(system,'session_state',side_effect=snapshot))
            stack.enter_context(mock.patch.object(system,'identity',return_value=dict(pid=42,present=True,lstart='synthetic')))
            stack.enter_context(mock.patch.object(session,'discover',return_value=[42]));stack.enter_context(mock.patch.object(session.time,'monotonic',side_effect=lambda:now[0]))
            stack.enter_context(mock.patch.object(session.time,'sleep',side_effect=lambda seconds:now.__setitem__(0,now[0]+seconds)))
            stack.enter_context(mock.patch.object(session.shutil,'disk_usage',return_value=SimpleNamespace(free=free_bytes)))
            stack.enter_context(mock.patch.object(system,'system_snapshot',return_value={}))
            stack.enter_context(mock.patch.object(session.subprocess,'Popen',side_effect=AssertionError('No helper/process launch allowed in this fixture')))
            stack.enter_context(mock.patch('builtins.print'))
            if reported_output_bytes is not None:stack.enter_context(mock.patch.object(system,'output_bytes',return_value=reported_output_bytes))
            result=session.run(args)
        return result,[json.loads(line) for line in (out/'timeline.jsonl').read_text().splitlines()],out
    def test_raw_quota_cap_keeps_timeline_and_later_error_tail(self):
        result,rows,out=self.mock_session()
        self.assertEqual(result['status'],'bounded-complete');self.assertEqual(len(rows),6)
        self.assertTrue(any(row.get('forensicsCopy',{}).get('capped') for row in rows));self.assertIsNone(result['diagnosticsDisabledReason'])
        self.assertEqual(rows[-1]['clock']['monotonicSeconds'],5);self.assertGreater(result['rawCoverageWarningCount'],0)
        self.assertTrue((out/'readiness.json').is_file());self.assertFalse(result['targetLaunchStopOrInputUsed'])
        self.assertIn(0,[window['index'] for window in result['rawCoverageByWindow']])
        self.assertTrue(all(window['tailGraceComplete'] for window in result['rawCoverageByWindow']))
    def test_total_output_cap_keeps_terminal_tail_and_reports_undercoverage(self):
        result,rows,_=self.mock_session(reported_output_bytes=16*1024**2)
        self.assertEqual(len(rows),1);self.assertIsNotNone(result['detailUndercoverage']);self.assertIsNotNone(result['diagnosticsDisabledReason'])
        self.assertEqual(rows[-1]['terminal'],'collector-total-output-cap');self.assertTrue(all('detailUndercoverage' in row for row in rows))
    def test_low_disk_records_terminal_row_and_releases_owned_marker(self):
        result,rows,out=self.mock_session(free_bytes=100*1024**2)
        self.assertEqual(result['status'],'disk-reserve-stop');self.assertEqual(len(rows),1);self.assertEqual(rows[0]['terminal'],'disk-reserve-stop')
        self.assertFalse(list((out.parent/'profile').glob('*.arm')));self.assertTrue((out/'summary.json').is_file())


if __name__=='__main__':unittest.main()
