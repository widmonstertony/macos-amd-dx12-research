#!/usr/bin/env python3
"""CPU-only mocks. No live discovery, Kernel queries, sample, or GPU execution."""
import json
import os
from pathlib import Path
from types import SimpleNamespace
import subprocess
import tempfile
import unittest
from unittest import mock

import watch_render_stall_stacks as recorder

PID = 424242
EPOCH = 1800000000


class FakeSample:
    def __init__(self, runtime, argv, cap):
        self.runtime, self.argv, self.cap = runtime, argv, cap
        self.started = runtime.now
        self.pid = 700000 + len(runtime.samples)
        self.terminated = self.killed = False
        Path(argv[-1]).write_bytes(b'CPU-only mocked stack output\n')

    def poll(self):
        if self.terminated or self.killed:
            return -15 if self.terminated else -9
        if not self.runtime.hanging_sample and self.runtime.now - self.started >= 2:
            return 0
        return None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout):
        if self.runtime.terminate_times_out and not self.killed:
            raise subprocess.TimeoutExpired(self.argv, timeout)
        return self.poll()


class FakeRuntime:
    def __init__(self):
        self.now = 0
        self.kernel = SimpleNamespace(timebase=dict(numer=1, denom=1))
        self.samples = []
        self.hanging_sample = False
        self.terminate_times_out = False
        self.free = 8 * 1024 ** 3
        self.pid = PID
        self.start = 1_000_000_000
        self.lstart = 'Synthetic Jan 1 00:00:00 2027'
        self.discover_fn = lambda: [self.pid]
        self.usage_available = True
        self.on_sleep = lambda: None
        self.fault_rate = 0
        self.identity_available = True

    def monotonic(self):
        return self.now

    def clock(self):
        return dict(UTC='CPU-only-synthetic', unixSeconds=EPOCH + self.now,
                    monotonicSeconds=self.now, CFAbsoluteTime=EPOCH + self.now - recorder.system.CF_EPOCH,
                    machAbsoluteTicks=2_000_000_000 + int(self.now * 1e9))

    def discover(self):
        return self.discover_fn()

    def identity(self, pid):
        if not self.identity_available:
            return dict(present=None)
        return dict(present=True, pid=pid, lstart=self.lstart, state='R',
                    comm='Z:\\owned\\SB-Win64-Shipping.exe')

    def usage(self, pid):
        return dict(available=self.usage_available, processStartAbstime=self.start, processExitAbstime=0)

    def task(self, pid):
        return dict(available=True, faults=int(self.now * self.fault_rate) & 0xffffffff)

    def sleep(self, seconds):
        if seconds < 0:
            raise AssertionError('negative sleep')
        self.now += seconds
        self.on_sleep()

    def free_bytes(self, path):
        return self.free

    def spawn_sample(self, argv, cap):
        if argv[:1] != ['/usr/bin/sample']:
            raise AssertionError('Only an owned sample helper may be spawned')
        helper = FakeSample(self, argv, cap)
        self.samples.append(helper)
        return helper


class RecorderControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='render-stall-cpu-test-', dir=recorder.system.ROOT / 'evidence')
        self.root = Path(self.tmp.name)
        self.profile = self.root / 'profile'
        (self.profile / 'msl').mkdir(parents=True)
        self.runtime = FakeRuntime()
        self.args = SimpleNamespace(profile=self.profile, output=self.root / 'output',
                                    wait_seconds=10, max_seconds=30, interval=2,
                                    max_bursts=8, stall_seconds=12,
                                    fault_delta_per_2s=100000, max_output_mib=128)

    def tearDown(self):
        self.tmp.cleanup()

    def progress(self):
        path = self.profile / 'msl' / f'memory-current-{PID}.json'
        path.write_text('{}\n')
        os.utime(path, (EPOCH, EPOCH))
        return path

    def request(self, value):
        path = self.profile / recorder.REQUEST_NAME
        path.write_text(json.dumps(value))
        # Set deterministic external mtime; the watcher itself never writes it.
        ns = int((EPOCH + self.runtime.now) * 1e9)
        os.utime(path, ns=(ns, ns))
        return path

    def continuous(self):
        self.args.continuous_native_forensics = True
        paths = dict(forensics=self.profile / 'forensics.arm', native=self.profile / 'stutter.arm',
                     cpu=self.profile / 'cpu-stutter.arm', gpu=self.profile / 'gpu-counter.arm')
        text = ''.join('setenv(' + json.dumps(env) + ',' + json.dumps(str(paths[role])) + ',1);\n'
                       for role, env in recorder.session.ARM_ENV.items())
        (self.profile / 'game-trial-config.h').write_text(text)
        return paths

    def raw_sources(self):
        trace = self.profile / 'msl'
        current = trace / f'forensics-current-{PID}.json'
        current.write_text(json.dumps(dict(pid=PID, runID=99, session=111)) + '\n')
        paths = [current]
        for slot in range(4):
            path = trace / f'forensics-{PID}-99-{slot}.jsonl'
            path.write_text(json.dumps(dict(type='clockCalibration', pid=PID, runID=99)) + '\n' + '{"partial":')
            paths.append(path)
        for path in paths:
            os.utime(path, (EPOCH, EPOCH))
        return paths

    def run_mock(self):
        # Any accidental escape from the fake live boundary must fail the test.
        with (mock.patch.object(recorder.system, 'Kernel', side_effect=AssertionError('No live Kernel')),
              mock.patch.object(recorder.session, 'discover', side_effect=AssertionError('No live discovery')),
              mock.patch.object(recorder.system, 'identity', side_effect=AssertionError('No live ps')),
              mock.patch.object(recorder.subprocess, 'Popen', side_effect=AssertionError('No live sample'))):
            return recorder.run(self.args, self.runtime)

    def test_first_verified_discovery_immediately_samples_once(self):
        self.args.max_bursts = 1
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'burst-cap')
        self.assertEqual(len(self.runtime.samples), 1)
        sample = self.runtime.samples[0]
        self.assertEqual(sample.started, 0)
        self.assertEqual(sample.argv[:6], ['/usr/bin/sample', str(PID), '2', '20', '-file', sample.argv[-1]])
        self.assertFalse(sample.terminated)
        self.assertEqual(result['bursts'][0]['outputBytes'], 29)
        self.assertEqual(result['targetIdentity']['processStartAbstime'], self.runtime.start)
        self.assertFalse(result['targetSignalsUsed'])
        self.assertFalse(result['gameLaunchStopOrInputUsed'])

    def test_wait_is_bounded_and_does_not_launch_anything(self):
        self.runtime.discover_fn = lambda: []
        self.args.wait_seconds = 5
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'wait-for-unique-target-duration-cap')
        self.assertEqual(self.runtime.now, 5)
        self.assertEqual(self.runtime.samples, [])

    def test_multiple_instances_stop_before_sample(self):
        self.runtime.discover_fn = lambda: [PID, PID + 1]
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'multiple-shipping-processes')
        self.assertEqual(self.runtime.samples, [])

    def test_kernel_start_required_before_sample(self):
        self.runtime.usage_available = False
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'target-kernel-start-unavailable-or-changed')
        self.assertEqual(self.runtime.samples, [])

    def test_identity_failure_stops_without_retry_or_sample(self):
        self.runtime.identity_available = False
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'target-identity-unavailable-or-exited')
        self.assertEqual(self.runtime.samples, [])

    def test_pid_reuse_during_sample_terminates_only_owned_helper(self):
        self.runtime.on_sleep = lambda: setattr(self.runtime, 'start', 1_500_000_000)
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'target-process-identity-changed')
        self.assertEqual(len(self.runtime.samples), 1)
        self.assertTrue(self.runtime.samples[0].terminated)
        self.assertFalse(result['targetSignalsUsed'])

    def test_changed_lstart_and_multiple_instances_during_sample_stop(self):
        for mutation, reason in [
            (lambda: setattr(self.runtime, 'lstart', 'A different process'), 'target-process-identity-changed'),
            (lambda: setattr(self.runtime, 'discover_fn', lambda: [PID, PID + 1]), 'multiple-shipping-processes'),
        ]:
            self.runtime = FakeRuntime()
            self.args.output = self.root / ('output-' + reason)
            self.runtime.on_sleep = mutation
            result = self.run_mock()
            self.assertEqual(result['stopReason'], reason)
            self.assertTrue(self.runtime.samples[0].terminated)

    def test_exit_stops_without_new_pid_reselection(self):
        self.runtime.discover_fn = lambda: [PID] if self.runtime.now < 4 else []
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'target-exited-or-discovery-unavailable')
        self.assertEqual(len(self.runtime.samples), 1)

    def test_marker_change_waits_for_gap_and_is_consumed_once(self):
        wrote = []
        def external_request():
            if self.runtime.now >= 4 and not wrote:
                wrote.append(self.request({'reason': 'scene'}))
        self.runtime.on_sleep = external_request
        result = self.run_mock()
        self.assertEqual(len(self.runtime.samples), 2)
        self.assertEqual([x['reason'] for x in result['bursts']], ['first-discovery', 'request-scene'])
        self.assertGreaterEqual(self.runtime.samples[1].started - result['bursts'][0]['finishedClock']['monotonicSeconds'], 15)
        self.assertEqual(wrote[0].read_text(), '{"reason": "scene"}')
        self.assertEqual(wrote[0].stat().st_mtime_ns, int((EPOCH + 4) * 1e9))

    def test_preexisting_marker_is_baseline_not_a_trigger(self):
        marker = self.request({'reason': 'stall'})
        before = marker.stat().st_mtime_ns
        result = self.run_mock()
        self.assertEqual(len(result['bursts']), 1)
        self.assertEqual(marker.stat().st_mtime_ns, before)

    def test_marker_whitelist_and_symlink_are_ignored(self):
        reader = recorder.StackRequests(self.profile / recorder.REQUEST_NAME)
        for value in ({'reason': 'launch'}, {'reason': 'scene', 'command': 'anything'}, ['stall']):
            self.request(value)
            self.assertEqual(reader.poll()['status'], 'ignored')
        link = self.profile / recorder.REQUEST_NAME
        link.unlink()
        target = self.root / 'unrelated.txt'
        target.write_text('{"reason":"scene"}')
        link.symlink_to(target)
        self.assertEqual(reader.poll()['status'], 'ignored')
        self.assertEqual(target.read_text(), '{"reason":"scene"}')

    def test_stalled_existing_progress_and_fault_surge_trigger(self):
        self.progress()
        self.runtime.fault_rate = 75000  # 150000 raw increments per two seconds.
        self.args.max_bursts = 2
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'burst-cap')
        self.assertEqual(len(self.runtime.samples), 2)
        trigger = result['bursts'][1]['trigger']
        self.assertEqual(result['bursts'][1]['reason'], 'progress-stall-fault-surge')
        self.assertGreaterEqual(trigger['progress']['observedUnchangedSeconds'], 12)
        self.assertGreaterEqual(trigger['faultChange']['rawDelta'], 100000)
        self.assertFalse(result['allCausesFound'])

    def test_progress_advancing_or_missing_prevents_fault_only_sampling(self):
        for advancing in (False, True):
            self.runtime = FakeRuntime()
            self.runtime.fault_rate = 75000
            self.args.output = self.root / ('advancing' if advancing else 'missing')
            if advancing:
                path = self.progress()
                def update():
                    os.utime(path, (EPOCH + self.runtime.now, EPOCH + self.runtime.now))
                self.runtime.on_sleep = update
            result = self.run_mock()
            self.assertEqual(len(result['bursts']), 1)

    def test_old_pid_progress_and_inventory_failure_are_not_stalls(self):
        path = self.progress()
        tracker = recorder.Progress(path.parent, PID, EPOCH)
        os.utime(path, (EPOCH - 10, EPOCH - 10))
        self.assertFalse(tracker.poll(100, EPOCH + 100, 12)['stalled'])
        path.unlink()
        path.symlink_to(self.root / 'missing')
        self.assertFalse(tracker.poll(100, EPOCH + 100, 12)['available'])

    def test_fault_wrap_or_large_gap_never_triggers(self):
        r = recorder.fault_change(dict(available=True, faults=100), dict(available=True, faults=2**32 - 1), 2, 0, 100000, 2)
        self.assertFalse(r['significant'])
        r = recorder.fault_change(dict(available=True, faults=5000000), dict(available=True, faults=0), 20, 0, 100000, 2)
        self.assertFalse(r['available'])

    def test_disk_reserve_stops_without_any_sample(self):
        self.runtime.free = recorder.DISK_RESERVE - 1
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'disk-reserve')
        self.assertEqual(self.runtime.samples, [])

    def test_hanging_owned_helper_is_terminated_or_killed(self):
        self.runtime.hanging_sample = True
        self.runtime.terminate_times_out = True
        self.args.max_bursts = 1
        result = self.run_mock()
        self.assertTrue(result['bursts'][0]['helperTimeout'])
        self.assertTrue(self.runtime.samples[0].terminated)
        self.assertTrue(self.runtime.samples[0].killed)
        self.assertEqual(result['bursts'][0]['cleanup'], 'killed-owned-sample-helper')

    def test_whole_deadline_stops_active_helper(self):
        self.args.max_seconds = 1
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'whole-duration-cap')
        self.assertTrue(self.runtime.samples[0].terminated)
        self.assertLessEqual(result['observerElapsedSeconds'], 1)

    def test_output_capacity_keeps_control_reserve_and_hard_child_limit(self):
        self.args.max_output_mib = 4
        self.args.max_bursts = 1
        result = self.run_mock()
        sample = self.runtime.samples[0]
        self.assertLess(sample.cap, 4 * recorder.MIB)
        self.assertGreaterEqual(sample.cap, 65536)
        self.assertEqual(result['bursts'][0]['outputHardFileLimitBytes'], sample.cap)
        self.assertLessEqual(sum(p.stat().st_size for p in self.args.output.iterdir()), 4 * recorder.MIB)
        # Inspect Popen configuration without starting even a synthetic process.
        live = recorder.Runtime.__new__(recorder.Runtime)
        with mock.patch.object(recorder.subprocess, 'Popen') as popen:
            live.spawn_sample(['/usr/bin/sample', str(PID), '2', '20', '-file', '/owned/path'], 123456)
            call = popen.call_args
            self.assertEqual(call.kwargs['stdout'], subprocess.DEVNULL)
            with mock.patch.object(recorder.resource, 'setrlimit') as limit:
                call.kwargs['preexec_fn']()
                limit.assert_called_once_with(recorder.resource.RLIMIT_FSIZE, (123456, 123456))

    def test_validation_rejects_unsafe_budgets_and_existing_output(self):
        for field, value in [('max_bursts', 9), ('wait_seconds', 601), ('max_seconds', 1801),
                             ('max_output_mib', 129), ('stall_seconds', 11), ('interval', .1)]:
            old = getattr(self.args, field)
            setattr(self.args, field, value)
            with self.assertRaises(ValueError):
                recorder.validate(self.args)
            setattr(self.args, field, old)
        self.args.output.mkdir()
        with self.assertRaises(ValueError):
            recorder.validate(self.args)

    def test_continuous_lease_refreshes_native20_forensics60_through_ttls(self):
        paths = self.continuous()
        lease = recorder.NonceLease(paths, self.runtime)
        lease.acquire()
        initial = {p: p.stat().st_mtime_ns for p in (paths['native'], paths['forensics'])}
        for second in range(0, 123, 2):
            self.runtime.now = second
            lease.refresh()
            self.assertLess(EPOCH + second - paths['native'].stat().st_mtime, 30)
            self.assertLess(EPOCH + second - paths['forensics'].stat().st_mtime, 120)
            if second == 20:
                self.assertNotEqual(paths['native'].stat().st_mtime_ns, initial[paths['native']])
                self.assertEqual(paths['forensics'].stat().st_mtime_ns, initial[paths['forensics']])
        self.assertTrue(all(x['restored'] for x in lease.close()))
        self.assertFalse(any(p.exists() for p in paths.values()))

    def test_stale_marker_original_saved_once_and_restored_after_refresh(self):
        paths = self.continuous()
        original = paths['native']
        original.write_bytes(b'previous-stale-marker\n')
        original.chmod(0o640)
        os.utime(original, ns=(int((EPOCH - 300) * 1e9), int((EPOCH - 200) * 1e9)))
        before = original.stat()
        lease = recorder.NonceLease(paths, self.runtime)
        lease.acquire()
        saved = next(x['original'] for x in lease.report() if x['role'] == 'native')
        self.runtime.now = 65
        lease.refresh()
        self.assertEqual(next(x['original'] for x in lease.report() if x['role'] == 'native'), saved)
        lease.close()
        self.assertEqual(original.read_bytes(), b'previous-stale-marker\n')
        self.assertEqual(original.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(original.stat().st_mode & 0o777, 0o640)

    def test_external_nonce_or_inode_is_never_refreshed_or_removed(self):
        paths = self.continuous()
        for replace_inode in (False, True):
            lease = recorder.NonceLease(paths, self.runtime)
            lease.acquire()
            path = paths['native']
            if replace_inode:
                path.unlink()
            path.write_text('{"nonce":"external-owner"}')
            external = (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ino)
            self.runtime.now += 20
            with self.assertRaises(recorder.StopWatch):
                lease.refresh()
            outcome = lease.close()
            self.assertFalse(next(x['restored'] for x in outcome if x['role'] == 'native'))
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ino), external)
            path.unlink()  # Fixture cleanup, never performed by the recorder.

    def test_other_live_owner_rejected_and_partial_acquire_is_cleaned(self):
        paths = self.continuous()
        paths['native'].write_text('another-live-collector')
        os.utime(paths['native'], (EPOCH, EPOCH))
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'marker-other-live-or-nonce-owner')
        self.assertFalse(paths['forensics'].exists())
        self.assertEqual(paths['native'].read_text(), 'another-live-collector')
        self.assertEqual(self.runtime.samples, [])

    def test_continuous_rejects_native_gpu_alias_and_preserves_cpu_gpu(self):
        paths = self.continuous()
        for role in ('cpu', 'gpu'):
            paths[role].write_text('external-' + role)
        before = {role: (paths[role].read_bytes(), paths[role].stat().st_mtime_ns) for role in ('cpu', 'gpu')}
        self.args.max_bursts = 1
        result = self.run_mock()
        self.assertEqual(len(result['bursts']), 1)
        self.assertEqual(before, {role: (paths[role].read_bytes(), paths[role].stat().st_mtime_ns) for role in ('cpu', 'gpu')})
        header = self.profile / 'game-trial-config.h'
        header.write_text(header.read_text().replace(str(paths['native']), str(paths['gpu'])))
        with self.assertRaises(ValueError):
            recorder.continuous_paths(self.profile)

    def test_raw_tail_freeze_four_slots_hashes_partial_tail_and_deduplicates(self):
        paths = self.raw_sources()
        out = self.root / 'raw-output'
        out.mkdir()
        evidence = recorder.Evidence(out, 128 * recorder.MIB, 2 * recorder.RAW_BANK_MAX)
        identity = recorder.checked_identity(self.runtime)
        tail = recorder.RawTail(self.profile / 'msl', identity, evidence)
        first = tail.freeze('stall')
        self.assertEqual(len(first['files']), 5)
        self.assertFalse(first['nativeSessionEqualsForensicsSessionAssumed'])
        self.assertTrue(all(x['incompleteTailBytes'] > 0 for x in first['files'] if x['source'].endswith('.jsonl')))
        self.assertEqual(tail.freeze('exit')['status'], 'unchanged-not-copied')
        with paths[-1].open('ab') as handle:
            handle.write(b'2}\n')
        os.utime(paths[-1], (EPOCH + 1, EPOCH + 1))
        second = tail.freeze('exit')
        self.assertEqual(second['bank'], 1)
        self.assertLessEqual(evidence.size(), 2 * recorder.RAW_BANK_MAX)
        self.assertEqual(paths[-1].read_bytes(), Path(second['files'][-1]['destination']).read_bytes())

    def test_raw_tail_truncation_is_explicit_and_bounded(self):
        paths = self.raw_sources()
        with paths[-1].open('ab') as handle:
            handle.seek(0)
            handle.write(b'x' * (recorder.SLOT_MAX + 17))
        os.utime(paths[-1], (EPOCH + 1, EPOCH + 1))
        out = self.root / 'raw-output'
        out.mkdir()
        evidence = recorder.Evidence(out, 128 * recorder.MIB)
        tail = recorder.RawTail(self.profile / 'msl', recorder.checked_identity(self.runtime), evidence)
        result = tail.freeze('stall')
        copied = result['files'][-1]
        self.assertEqual(copied['bytes'], recorder.SLOT_MAX)
        self.assertIn('source-truncated-to-bounded-copy', copied['warnings'])
        self.assertGreater(copied['sourceBytesAtOpen'], copied['bytes'])

    def test_regular_quota_cannot_consume_two_raw_tail_banks(self):
        self.continuous()
        self.raw_sources()
        out = self.root / 'quota-output'
        out.mkdir()
        evidence = recorder.Evidence(out, 128 * recorder.MIB, 2 * recorder.RAW_BANK_MAX)
        for index in range(8):
            try:
                cap = evidence.sample_capacity(self.runtime.free)
            except recorder.StopWatch as error:
                self.assertEqual(error.reason, 'sample-output-quota')
                break
            with (out / f'mock-sample-{index}').open('wb') as handle:
                handle.seek(cap - 1)
                handle.write(b'x')
        else:
            self.fail('sample quota should be exhausted before consuming raw-tail reserve')
        tail = recorder.RawTail(self.profile / 'msl', recorder.checked_identity(self.runtime), evidence)
        self.assertEqual(tail.freeze('quota-full-stall')['status'], 'frozen-live-prefix')
        evidence.finish(dict(status='mock-only'))
        self.assertLessEqual(evidence.size(), 128 * recorder.MIB)

    def test_continuous_terminal_freezes_tail_and_only_own_helper_cleanup(self):
        paths = self.continuous()
        self.raw_sources()
        self.runtime.discover_fn = lambda: [PID] if self.runtime.now < 1 else []
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'target-exited-or-discovery-unavailable')
        self.assertTrue(self.runtime.samples[0].terminated)
        self.assertEqual(len(result['rawTailBanks']), 1)
        self.assertFalse(paths['forensics'].exists())
        self.assertFalse(paths['native'].exists())

    def test_acquire_faults_at_each_mutation_restore_owned_inode_or_remove_new(self):
        paths = self.continuous()
        operations = ('write', 'ftruncate', 'utime', 'fstat')
        for existing in (False, True):
            for operation in operations:
                with self.subTest(existing=existing, operation=operation):
                    for path in (paths['forensics'], paths['native']):
                        path.unlink(missing_ok=True)
                    original = paths['forensics']
                    if existing:
                        original.write_bytes(b'original-stale-marker\n')
                        os.utime(original, ns=(int((EPOCH - 300) * 1e9), int((EPOCH - 200) * 1e9)))
                        saved = (original.read_bytes(), original.stat().st_mtime_ns, original.stat().st_ino)
                    lease = recorder.NonceLease(paths, self.runtime)
                    actual = getattr(recorder.os, operation)
                    hits = []
                    def fail_once(*args, **kwargs):
                        # fstat #2 is after all content/mtime mutations; #1 is
                        # separately exercised below for exclusive-create cleanup.
                        hits.append(1)
                        fail_at = 2 if operation == 'fstat' else 1
                        if len(hits) == fail_at:
                            if operation == 'write':
                                actual(args[0], args[1][:7])  # Partial mutation before failure.
                            elif operation in ('ftruncate', 'utime'):
                                actual(*args, **kwargs)  # Mutation succeeded, reporting failed.
                            raise OSError('injected-' + operation)
                        return actual(*args, **kwargs)
                    with mock.patch.object(recorder.os, operation, side_effect=fail_once):
                        with self.assertRaises(recorder.StopWatch):
                            lease.acquire()
                    self.assertFalse(lease.held)
                    if existing:
                        self.assertEqual((original.read_bytes(), original.stat().st_mtime_ns, original.stat().st_ino), saved)
                    else:
                        self.assertFalse(original.exists())
                    self.assertFalse(paths['native'].exists())
        paths['forensics'].unlink(missing_ok=True)
        lease = recorder.NonceLease(paths, self.runtime)
        with mock.patch.object(recorder.os, 'fstat', side_effect=OSError('initial-fstat-failed')):
            with self.assertRaises(recorder.StopWatch):
                lease.acquire()
        self.assertFalse(paths['forensics'].exists())

    def test_acquire_fault_after_external_nonce_or_inode_preserves_external_file(self):
        paths = self.continuous()
        for new_inode in (False, True):
            lease = recorder.NonceLease(paths, self.runtime)
            actual = recorder.os.utime
            changed = []
            def external_then_fail(fd, **kwargs):
                if not changed:
                    changed.append(True)
                    path = paths['forensics']
                    if new_inode:
                        path.unlink()
                    path.write_bytes(b'{"nonce":"another-owner"}\n')
                    raise OSError('external-owner-during-acquire')
                return actual(fd, **kwargs)
            with mock.patch.object(recorder.os, 'utime', side_effect=external_then_fail):
                with self.assertRaises(recorder.StopWatch):
                    lease.acquire()
            self.assertEqual(paths['forensics'].read_bytes(), b'{"nonce":"another-owner"}\n')
            paths['forensics'].unlink()

    def test_raw_low_disk_or_output_cleanup_preserves_old_bank_without_copy(self):
        paths = self.raw_sources()
        out = self.root / 'raw-budget-output'
        out.mkdir()
        evidence = recorder.Evidence(out, 128 * recorder.MIB, 2 * recorder.RAW_BANK_MAX)
        tail = recorder.RawTail(self.profile / 'msl', recorder.checked_identity(self.runtime), evidence, self.runtime.free_bytes)
        first = tail.freeze('initial-stall')
        old = {p: p.read_bytes() for p in tail.owned_paths[first['bank']]}
        paths[-1].write_bytes(b'changed-raw-source\n')
        self.runtime.free = recorder.DISK_RESERVE + 1024
        with mock.patch.object(tail, 'read', side_effect=AssertionError('No raw copy on low disk')):
            result = tail.freeze('observer-terminal:disk-reserve')
        self.assertEqual(result['status'], 'skipped-disk-reserve')
        self.assertEqual(old, {p: p.read_bytes() for p in old})
        self.runtime.free = 8 * 1024 ** 3
        evidence.max_bytes = evidence.size() + evidence.control_cap
        with mock.patch.object(tail, 'read', side_effect=AssertionError('No raw copy beyond quota')):
            result = tail.freeze('observer-terminal:output-cap')
        self.assertEqual(result['status'], 'skipped-output-quota')
        self.assertEqual(old, {p: p.read_bytes() for p in old})

    def test_run_low_disk_finally_skips_raw_copy_and_cleans_nonce(self):
        paths = self.continuous()
        self.raw_sources()
        def disk_drops_during_owned_sample():
            self.runtime.free = recorder.DISK_RESERVE - 1
        self.runtime.on_sleep = disk_drops_during_owned_sample
        result = self.run_mock()
        self.assertEqual(result['stopReason'], 'disk-reserve')
        self.assertFalse(result['rawTailBanks'])
        self.assertFalse(list(self.args.output.glob('raw-tail-*')))
        self.assertFalse(paths['forensics'].exists())
        self.assertFalse(paths['native'].exists())
        self.assertTrue(self.runtime.samples[0].terminated)


if __name__ == '__main__':
    unittest.main()
