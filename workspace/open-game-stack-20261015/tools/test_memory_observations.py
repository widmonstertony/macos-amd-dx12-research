"""Synthetic negative controls plus a read-only replay of saved CPU mocks."""

import copy
import json
from pathlib import Path
import unittest

from analyze_memory_observations import analyze


def event(sequence=1, category='failure', **changes):
    result = dict(schema=2, sequence=sequence, allocationID=sequence,
        _pid=123, _runID='mock-run', _source='mock/memory-%s-123.jsonl' % (
            'failures' if category == 'failure' else 'slow-allocations'), _line=sequence,
        clockDomain='mach-absolute-nanoseconds', beginMachNS=1000 + sequence * 10,
        endMachNS=1005 + sequence * 10, hostCallNS=5, time=99.5,
        threadMachID=7, ownerSubmission=8, ownerNativeCB=9, ownerFrame=10,
        ownerQueueFamily=0, ownerQueueIndex=1, kind='buffer', storageName='private',
        storageMode=2, requestedBytes=4096, requestedBytesKnown=True,
        returnedNil=category == 'failure', rejectedBeforeMetalCall=False,
        resultCode=-77 if category == 'failure' else 0,
        resultCodeDomain='caller-supplied', limitBytes=0,
        site='synthetic-site', reason='synthetic-result',
        siteTruncated=False, reasonTruncated=False, labelSanitized=False)
    result.update(changes)
    return result


def snapshot(failures=0, slow=0, **changes):
    result = dict(schema=2, pid=123, _pid=123, _runID='mock-run',
        _source='mock/memory-current-123.json', _line=1, reportIndex=0,
        monotonicNS=2000, clockDomain='mach-absolute-nanoseconds',
        allocationIDScope='process-local', allocationAttempts=failures + slow,
        allocationCallsCompleted=failures + slow, failureEventsTotal=failures,
        slowEventsTotal=slow, recentFailures=[], recentSlowAllocationCalls=[],
        failureJournalCapped=failures > 128, slowJournalCapped=slow > 128,
        failureJournalOmittedEvents=max(0, failures - 128),
        slowJournalOmittedEvents=max(0, slow - 128),
        recentFailureRingOmittedEvents=max(0, failures - 32),
        recentSlowRingOmittedEvents=max(0, slow - 32),
        writerErrorsTotal=0, diagnosticWriterErrors=0, eventJournalWriteErrors=0,
        metadataLabelsTruncatedOrSanitized=0)
    result.update(changes)
    return result


def nested(row):
    return {key: value for key, value in row.items() if not key.startswith('_')}


class MemoryObservationsTests(unittest.TestCase):
    def test_first128_and_recent32_recover142_without_adding_omissions(self):
        events = [event(i) for i in range(1, 129)]
        snap = snapshot(142, recentFailures=[nested(event(i)) for i in range(111, 143)])
        report = analyze(events, [snap])
        self.assertEqual(report['summary']['failureDetailsObserved'], 142)
        self.assertEqual(report['reportedCumulativeTotalsByIdentityGroupSum']['failureEventsTotal'], 142)
        self.assertEqual(report['inputCounts']['duplicateEvents'], 18)
        coverage = report['processGroups'][0]['coverage']['failure']
        self.assertEqual(coverage['journalOmittedEvents'], 14)
        self.assertEqual(coverage['recentRingOmittedEvents'], 110)
        self.assertEqual(coverage['missingSequenceCount'], 0)
        self.assertTrue(coverage['detailCoverageCompleteForReportedSequences'])
        self.assertTrue(report['outputRankingCapped'])
        self.assertEqual(report['outputDetailsOmitted']['failures'], 14)
        self.assertEqual(report['bySite'][0]['observedDetails'], 142)
        self.assertFalse(report['allCausesFound'])

    def test_nested_slow_and_result_owner_request_are_retained(self):
        item = event(2, 'slow', requestedBytesKnown=False, requestedBytes=0,
                     hostCallNS=3000000, endMachNS=3001020)
        report = analyze([], [snapshot(0, 2, recentSlowAllocationCalls=[nested(item)])])
        detail = report['slowAllocationCalls'][0]
        for key in ('site', 'ownerSubmission', 'ownerNativeCB', 'ownerFrame',
                    'requestedBytesKnown', 'resultCode', 'resultCodeDomain'):
            self.assertEqual(detail[key], item[key])
        self.assertEqual(detail['observedHostCallWallNS'], 3000000)
        self.assertIsNone(detail['requestedBytesForAnalysis'])
        self.assertEqual(report['bySite'][0]['unknownByteRequests'], 1)
        self.assertEqual(report['processGroups'][0]['coverage']['slow']['missingSequenceRanges'], [[1, 1]])

    def test_attempts_minus_completed_never_invents_pending_allocation(self):
        report = analyze([], [snapshot(allocationAttempts=8, allocationCallsCompleted=5)])
        pending = report['processGroups'][0]['pending']
        self.assertEqual(pending['attemptsMinusCompleted'], 3)
        self.assertIsNone(pending['allocationID'])
        self.assertIsNone(pending['site'])
        self.assertIn('in-flight-or-unwound', pending['interpretation'])
        self.assertFalse(report['allCausesFound'])
        self.assertNotIn('oom', report)
        self.assertNotIn('hang', report)

    def test_same_pid_and_allocation_id_never_join_different_runs(self):
        first, second = event(), event(_runID='next-run')
        report = analyze([first, second], [snapshot(1), snapshot(2, _runID='next-run')])
        self.assertEqual(len(report['processGroups']), 2)
        self.assertEqual(report['summary']['failureDetailsObserved'], 2)
        self.assertEqual(report['reportedCumulativeTotalsByIdentityGroupSum']['failureEventsTotal'], 3)
        self.assertFalse(report['reportedGroupSumIsDistinctValidatedProcesses'])

    def test_process_start_disambiguates_same_pid_same_declared_run(self):
        report = analyze([event(_processStartIdentity='start-a'), event(_processStartIdentity='start-b')], [])
        self.assertEqual(len(report['processGroups']), 2)
        self.assertEqual(report['summary']['failureDetailsObserved'], 2)

    def test_different_run_tags_for_one_kernel_start_not_distinct_processes(self):
        report = analyze([event(_processStartIdentity='same-start'),
                          event(_processStartIdentity='same-start', _runID='next-run')], [])
        self.assertEqual(len(report['processGroups']), 2)
        self.assertFalse(report['reportedGroupSumIsDistinctValidatedProcesses'])

    def test_validated_process_start_allows_different_sources(self):
        item = event(_processStartIdentity='kernel-start')
        item.pop('_runID')
        snap = snapshot(1, _processStartIdentity='kernel-start', recentFailures=[nested(item)])
        snap.pop('_runID')
        report = analyze([item], [snap])
        self.assertEqual(len(report['processGroups']), 1)
        self.assertEqual(report['summary']['failureDetailsObserved'], 1)
        self.assertTrue(report['reportedGroupSumIsDistinctValidatedProcesses'])

    def test_no_lifetime_identity_stays_source_local_even_with_same_ids(self):
        item = event()
        item.pop('_runID')
        snap = snapshot(1, recentFailures=[nested(item)])
        snap.pop('_runID')
        report = analyze([item], [snap])
        self.assertEqual(len(report['processGroups']), 2)
        self.assertEqual(report['summary']['failureDetailsObserved'], 2)
        self.assertFalse(report['reportedGroupSumIsDistinctValidatedProcesses'])
        self.assertIn('process-lifetime-unverified-no-cross-source-join', report['gaps'])

    def test_unknown_pid_cannot_use_shared_run_to_join_sources(self):
        item = event()
        item.pop('_pid')
        snap = snapshot(1, recentFailures=[nested(item)])
        snap.pop('_pid')
        snap.pop('pid')
        report = analyze([item], [snap])
        self.assertEqual(len(report['processGroups']), 2)

    def test_filename_or_header_pid_mismatch_is_isolated(self):
        for item in (event(_pid=456), event(pid=456)):
            report = analyze([item, event()], [snapshot(1)])
            self.assertEqual(len(report['processGroups']), 2)
            self.assertIn('pid-or-run-identity-conflict', report['gaps'])

    def test_conflicting_explicit_run_tags_are_isolated(self):
        report = analyze([event(runID='different-run'), event()], [])
        self.assertEqual(len(report['processGroups']), 2)
        self.assertIn('pid-or-run-identity-conflict', report['gaps'])

    def test_cumulative_snapshot_counters_not_summed(self):
        report = analyze([], [snapshot(100, reportIndex=0), snapshot(142, reportIndex=1, monotonicNS=3000)])
        self.assertEqual(report['reportedCumulativeTotalsByIdentityGroupSum']['failureEventsTotal'], 142)
        self.assertEqual(report['summary']['failureDetailsMissingFromReportedSequences'], 142)

    def test_sequence_payload_conflict_not_silently_deduplicated(self):
        report = analyze([event(), event(site='other-site')], [snapshot(1)])
        self.assertEqual(report['summary']['failureDetailsObserved'], 2)
        self.assertTrue(report['processGroups'][0]['coverage']['failure']['sequenceConflicts'])
        self.assertFalse(report['processGroups'][0]['coverage']['failure']['detailCoverageCompleteForReportedSequences'])

    def test_gap_after_journal_and_ring_caps_is_measured_by_union(self):
        report = analyze([event(i) for i in range(1, 129)], [snapshot(200,
            recentFailures=[nested(event(i)) for i in range(169, 201)])], limit=1000)
        coverage = report['processGroups'][0]['coverage']['failure']
        self.assertEqual(coverage['missingSequenceCount'], 40)
        self.assertEqual(coverage['missingSequenceRanges'], [[129, 168]])
        self.assertEqual(coverage['distinctDetailsObserved'], 160)
        self.assertFalse(coverage['detailCoverageCompleteForReportedSequences'])

    def test_writer_and_label_errors_are_visible_without_oom_conclusion(self):
        report = analyze([event(siteTruncated=True)], [snapshot(1,
            writerErrorsTotal=3, diagnosticWriterErrors=3, eventJournalWriteErrors=2,
            metadataLabelsTruncatedOrSanitized=1, historyCapped=True)])
        group = report['processGroups'][0]
        self.assertEqual(group['counterPeaks']['eventJournalWriteErrors'], 2)
        for gap in ('observed-diagnostic-writer-errors', 'metadata-labels-truncated-or-sanitized',
                    'event-label-truncated-or-sanitized', 'snapshot-history-capped-at-1024-reports'):
            self.assertIn(gap, report['gaps'])

    def test_absent_snapshot_is_unknown_coverage_and_unhealthy_flag_is_preserved(self):
        report = analyze([event()], [])
        self.assertEqual(report['summary']['identitiesWithoutReportedFailureTotal'], 1)
        self.assertIsNone(report['processGroups'][0]['coverage']['failure']['missingSequenceCount'])
        self.assertFalse(report['processGroups'][0]['coverage']['failure']['detailCoverageCompleteForReportedSequences'])
        report = analyze([], [snapshot(diagnosticOutputAvailableWithoutObservedWriteError=False)])
        self.assertIn('diagnostic-output-reported-unhealthy', report['gaps'])

    def test_invalid_clock_never_uses_wall_utc_to_construct_duration(self):
        for changes in (dict(clockDomain='other'), dict(endMachNS=1000),
                        dict(beginMachNS=None), dict(beginMachNS=True)):
            report = analyze([event(**changes)], [])
            self.assertIsNone(report['failures'][0]['observedHostCallWallNS'])
            self.assertFalse(report['failures'][0]['intervalValid'])
        report = analyze([event(hostCallNS=700)], [])
        self.assertFalse(report['failures'][0]['hostDurationConsistent'])
        self.assertIn('event-host-duration-clock-mismatch', report['gaps'])

    def test_pre_call_rejection_is_preserved_separately_from_nil(self):
        report = analyze([event(returnedNil=False, rejectedBeforeMetalCall=True,
            limitBytes=100, requestedBytes=200, reason='max-buffer-length')], [snapshot(1)])
        detail = report['failures'][0]
        self.assertFalse(detail['returnedNil'])
        self.assertTrue(detail['rejectedBeforeMetalCall'])
        self.assertEqual(detail['limitBytes'], 100)
        self.assertEqual(report['bySite'][0]['returnedNil'], 0)
        self.assertEqual(report['bySite'][0]['rejectedBeforeMetalCall'], 1)

    def test_unknown_bytes_and_metal_allocated_are_not_free_or_resident(self):
        report = analyze([event(requestedBytesKnown=False, requestedBytes=0)], [snapshot(1,
            currentAllocatedSizeAvailable=True, currentAllocatedSizeBytes=123456,
            recommendedMaxWorkingSetSizeAvailable=True, recommendedMaxWorkingSetSizeBytes=456789)])
        self.assertIsNone(report['failures'][0]['requestedBytesForAnalysis'])
        device = report['processGroups'][0]['latestDeviceMemory']
        self.assertEqual(device['currentAllocatedSizeBytes'], 123456)
        self.assertNotIn('freeBytes', device)
        self.assertNotIn('residentBytes', device)
        self.assertTrue(any('not free or physically resident VRAM' in text for text in report['semantics']))

    def test_limit_zero_preserves_all_counts_and_aggregates_are_not_input_caps(self):
        report = analyze([event(1), event(2)], [snapshot(2)], limit=0)
        self.assertEqual(report['summary']['failureDetailsObserved'], 2)
        self.assertEqual(report['reportedCumulativeTotalsByIdentityGroupSum']['failureEventsTotal'], 2)
        self.assertEqual(report['failures'], [])
        self.assertEqual(report['bySite'], [])
        self.assertEqual(report['outputDetailsOmitted']['failures'], 2)
        self.assertTrue(report['outputRankingCapped'])

    def test_invalid_limits_and_input_shapes(self):
        for value in (-1, None, 1.5, True):
            with self.assertRaises(ValueError):
                analyze([], [], value)
        report = analyze([None, {}, dict(allocationID=1, hostCallNS=3000000)], [None,
            snapshot(recentFailures=[None], recentSlowAllocationCalls={})])
        self.assertEqual(report['inputCounts']['invalidRows'], 3)
        self.assertEqual(report['inputCounts']['unclassifiedEvents'], 2)
        self.assertIn('invalid-nested-event-ring', report['gaps'])

    def test_analyzer_does_not_mutate_input(self):
        events = [event()]
        snapshots = [snapshot(1, recentFailures=[nested(events[0])])]
        original = copy.deepcopy((events, snapshots))
        analyze(events, snapshots)
        self.assertEqual((events, snapshots), original)

    def test_saved_cpu_mock_replay_is_not_a_gpu_reproduction(self):
        folder = Path(__file__).resolve().parents[1] / 'evidence/causal-coverage-diagnostics-20261026/cpu-controls'
        events, snapshots = [], []
        for name, target in (('memory-failures-2451.jsonl', events),
                             ('memory-current-2451.json', snapshots),
                             ('memory-stats-2451.jsonl', snapshots)):
            path = folder / name
            for line, text in enumerate(path.read_text().splitlines(), 1):
                row = json.loads(text)
                # The saved qualification documents this as one CPU mock run.
                # This tag does not claim a kernel start identity or GPU work.
                row.update(_pid=2451, _runID='saved-cpu-mock-control-2451', _source=str(path), _line=line)
                target.append(row)
        report = analyze(events, snapshots, limit=1000)
        self.assertEqual(report['summary']['failureDetailsObserved'], 142)
        self.assertEqual(report['summary']['slowDetailsObserved'], 0)
        group = report['processGroups'][0]
        self.assertEqual(group['coverage']['failure']['journalOmittedEvents'], 14)
        self.assertEqual(group['coverage']['failure']['recentRingOmittedEvents'], 110)
        self.assertEqual(group['coverage']['failure']['missingSequenceCount'], 0)
        self.assertEqual(group['pending']['attemptsMinusCompleted'], 0)
        self.assertFalse(group['latestDeviceMemory']['deviceAvailable'])
        failed = next(item for item in report['failures'] if item['site'] == 'mock-failed-buffer')
        self.assertEqual((failed['allocationID'], failed['ownerSubmission'], failed['ownerNativeCB'],
                          failed['ownerFrame'], failed['resultCode']), (1, 77, 88, 99, -77))
        rejected = next(item for item in report['failures'] if item['site'] == 'mock-reject')
        self.assertTrue(rejected['rejectedBeforeMetalCall'])
        self.assertFalse(rejected['returnedNil'])
        self.assertFalse(report['reportedGroupSumIsDistinctValidatedProcesses'])


if __name__ == '__main__':
    unittest.main()
