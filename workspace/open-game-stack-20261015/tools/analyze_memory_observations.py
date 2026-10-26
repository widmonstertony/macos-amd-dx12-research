"""CPU-only analysis of v38 memory journals and nested snapshot event rings.

``analyze(events, snapshots, limit=128)`` accepts parsed dictionaries.  The
caller owns file selection, JSON parsing, process-start validation and read
health.  Preserve ``_source``, ``_line`` and ``_pid``.  Only attach
``_processStartIdentity`` after validating the source against that process
lifetime; an explicit ``_runID``/``runID`` is also a caller-declared run scope.
Without either, records stay in their individual source files.  In particular,
allocationID alone is never a join key.  This module performs no file, process,
Metal, Wine or Steam operations.
"""

from collections import Counter, defaultdict
import json
from pathlib import PurePath
import re


_COUNTERS = (
    'allocationAttempts', 'allocationCallsCompleted', 'allocationCallsSucceeded',
    'nilOrUnsuccessfulResults', 'rejectedBeforeCall', 'knownByteRequests',
    'unknownByteRequests', 'cumulativeAttemptedRequestedBytes',
    'cumulativeSuccessfulRequestedBytes', 'cumulativeHostAllocationCallNS',
    'largestHostAllocationCallNS', 'failureEventsTotal', 'slowEventsTotal',
    'writerErrorsTotal', 'diagnosticWriterErrors', 'eventJournalWriteErrors',
    'metadataLabelsTruncatedOrSanitized', 'failureJournalOmittedEvents',
    'slowJournalOmittedEvents', 'recentFailureRingOmittedEvents',
    'recentSlowRingOmittedEvents',
)
_EVENT_FIELDS = (
    'schema', 'sequence', 'time', 'allocationID', 'beginMachNS', 'endMachNS',
    'threadMachID', 'ownerSubmission', 'ownerNativeCB', 'ownerFrame',
    'ownerQueueFamily', 'ownerQueueIndex', 'clockDomain', 'resultCodeDomain',
    'kind', 'storageMode', 'storageName', 'requestedBytes', 'requestedBytesKnown',
    'hostCallNS', 'returnedNil', 'rejectedBeforeMetalCall', 'resultCode',
    'limitBytes', 'site', 'reason', 'siteTruncated', 'reasonTruncated',
    'labelSanitized',
)
_FLAGS = ('failureJournalCapped', 'slowJournalCapped', 'historyCapped',
          'eventDetailsTruncated')
_NAME = re.compile(r'^memory-(failures|slow-allocations|current|stats)-(\d+)\.(?:jsonl|json)$')


def _integer(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _scalar_identity(value):
    return value if isinstance(value, (str, int)) and not isinstance(value, bool) and str(value) not in ('', '0') else None


def _ref(row, ring=None, index=None):
    result = {key[1:]: row[key] for key in ('_source', '_line') if key in row}
    if ring is not None:
        result.update(ring=ring, index=index)
    return result


def _fingerprint(row, fields=None):
    values = {key: row[key] for key in (fields or row.keys())
              if key in row and not key.startswith('_')}
    return json.dumps(values, sort_keys=True, separators=(',', ':'), default=str)


def _identity(row, ordinal):
    source = str(row.get('_source', ''))
    name = _NAME.match(PurePath(source).name)
    pid = _integer(row.get('_pid', row.get('pid')))
    declared_pid = _integer(row.get('pid'))
    filename_pid = int(name.group(2)) if name else None
    pid_values = {value for value in (pid, declared_pid, filename_pid) if value is not None}
    run = _scalar_identity(row.get('_runID', row.get('runID')))
    run_conflict = ('_runID' in row and 'runID' in row and row['_runID'] != row['runID'])
    start = _scalar_identity(row.get('_processStartIdentity'))
    conflict = len(pid_values) > 1 or run_conflict
    scope = source or 'unprovenanced-record-%d' % ordinal
    if conflict:
        key = ('identity-conflict', scope, ordinal)
        confidence = 'identity-conflict-isolated'
    elif pid is not None and start is not None:
        key = ('process-start', pid, str(start), type(run).__name__, str(run))
        confidence = 'caller-validated-process-start'
    elif pid is not None and run is not None:
        key = ('declared-run', pid, type(run).__name__, str(run))
        confidence = 'caller-declared-run'
    else:
        key = ('source-only', pid, scope)
        confidence = 'source-only-process-lifetime-unverified'
    return key, dict(pid=pid, runID=run, processStartIdentity=start,
                     identityConfidence=confidence,
                     sourceScope=scope if confidence.startswith('source-only') or conflict else None,
                     allocationIDScope='process-local'), conflict


def _category(row):
    explicit = row.get('_memoryEventKind')
    if explicit in ('failure', 'slow'):
        return explicit
    name = _NAME.match(PurePath(str(row.get('_source', ''))).name)
    if name and name.group(1) in ('failures', 'slow-allocations'):
        return 'failure' if name.group(1) == 'failures' else 'slow'
    if row.get('returnedNil') is True or row.get('rejectedBeforeMetalCall') is True:
        return 'failure'
    # The slow journal is the success-only >=2 ms path; no duration-based
    # inference is made for unlabelled, potentially unrelated input rows.
    return None


def _missing_ranges(sequences, total, limit):
    if total is None:
        return None, []
    previous = 0
    count = 0
    ranges = []
    for sequence in sorted(value for value in sequences if 0 < value <= total) + [total + 1]:
        if sequence > previous + 1:
            count += sequence - previous - 1
            if len(ranges) < limit:
                ranges.append([previous + 1, sequence - 1])
        previous = sequence
    return count, ranges


def analyze(events, snapshots, limit=128):
    """Return bounded detail lists and unbounded-input counts, without I/O.

    The returned totals are reported cumulative counter maxima *per identity
    group*, never sums of repeated snapshots.  Source-only groups cannot be
    safely summed as distinct process runs.  ``limit`` caps displayed details,
    aggregates and missing-sequence ranges, never the underlying counts.
    """
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
        raise ValueError('limit must be a non-negative integer')
    groups = {}
    input_counts = Counter(events=0, snapshots=0, nestedEvents=0, invalidRows=0,
                           unclassifiedEvents=0, duplicateEvents=0, duplicateSnapshots=0)

    def get_group(row, ordinal):
        key, identity, conflict = _identity(row, ordinal)
        if key not in groups:
            groups[key] = dict(identity=identity, snapshots=[], snapshotSeen=set(),
                               events={'failure': {}, 'slow': {}}, sources=set(),
                               gaps=set(), sequencePayloads=defaultdict(set))
        group = groups[key]
        if row.get('_source'):
            group['sources'].add(str(row['_source']))
        if conflict:
            group['gaps'].add('pid-or-run-identity-conflict')
        if identity['identityConfidence'].startswith('source-only'):
            group['gaps'].add('process-lifetime-unverified-no-cross-source-join')
        return group

    def add_event(group, row, category, reference):
        signature = _fingerprint(row, _EVENT_FIELDS)
        bucket = group['events'][category]
        if signature in bucket:
            input_counts['duplicateEvents'] += 1
            if reference not in bucket[signature]['observations']:
                bucket[signature]['observations'].append(reference)
            return
        item = {key: row[key] for key in _EVENT_FIELDS if key in row}
        begin, end, host = (_integer(row.get(key)) for key in ('beginMachNS', 'endMachNS', 'hostCallNS'))
        valid = row.get('clockDomain') == 'mach-absolute-nanoseconds' and begin is not None and begin > 0 and end is not None and end >= begin
        duration = end - begin if valid else None
        item.update(eventCategory=category, observations=[reference],
                    intervalValid=valid, observedHostCallWallNS=duration,
                    hostDurationConsistent=duration == host if valid and host is not None else None,
                    returnedObservationOnly=True,
                    ownerJoinStatus='captured-owner-ids-only-no-external-owner-join',
                    requestedBytesForAnalysis=_integer(row.get('requestedBytes')) if row.get('requestedBytesKnown') is True else None)
        if not valid:
            group['gaps'].add('event-mach-interval-unavailable-or-invalid')
        if valid and host is not None and host != duration:
            group['gaps'].add('event-host-duration-clock-mismatch')
        if category == 'slow' and (row.get('returnedNil') is True or row.get('rejectedBeforeMetalCall') is True):
            group['gaps'].add('slow-source-conflicts-with-failure-flags')
        for flag in ('siteTruncated', 'reasonTruncated', 'labelSanitized'):
            if row.get(flag) is True:
                group['gaps'].add('event-label-truncated-or-sanitized')
        sequence = _integer(row.get('sequence'))
        if sequence:
            group['sequencePayloads'][(category, sequence)].add(signature)
        bucket[signature] = item

    ordinal = 0
    for row in events:
        ordinal += 1
        input_counts['events'] += 1
        if not isinstance(row, dict):
            input_counts['invalidRows'] += 1
            continue
        category = _category(row)
        if category is None:
            input_counts['unclassifiedEvents'] += 1
            continue
        add_event(get_group(row, ordinal), row, category, _ref(row))
    for row in snapshots:
        ordinal += 1
        input_counts['snapshots'] += 1
        if not isinstance(row, dict):
            input_counts['invalidRows'] += 1
            continue
        group = get_group(row, ordinal)
        signature = _fingerprint(row)
        if signature in group['snapshotSeen']:
            input_counts['duplicateSnapshots'] += 1
            continue
        group['snapshotSeen'].add(signature)
        group['snapshots'].append(row)
        for ring, category in (('recentFailures', 'failure'), ('recentSlowAllocationCalls', 'slow')):
            nested = row.get(ring, [])
            if not isinstance(nested, list):
                group['gaps'].add('invalid-nested-event-ring')
                continue
            for index, event in enumerate(nested):
                input_counts['nestedEvents'] += 1
                if not isinstance(event, dict):
                    input_counts['invalidRows'] += 1
                    continue
                add_event(group, event, category, _ref(row, ring, index))

    process_groups = []
    detail_lists = {'failure': [], 'slow': []}
    by_site = defaultdict(Counter)
    summary = Counter(failureDetailsObserved=0, slowDetailsObserved=0,
                      failureDetailsMissingFromReportedSequences=0,
                      slowDetailsMissingFromReportedSequences=0,
                      identitiesWithReportedFailureTotal=0,
                      identitiesWithReportedSlowTotal=0,
                      identitiesWithoutReportedFailureTotal=0,
                      identitiesWithoutReportedSlowTotal=0)
    reported_totals = Counter()
    for group_number, group in enumerate(groups.values(), 1):
        identity = dict(group['identity'], group=group_number)
        rows = group['snapshots']
        peaks = {field: max((_integer(row.get(field)) for row in rows if _integer(row.get(field)) is not None), default=None)
                 for field in _COUNTERS}
        flags = {field: any(row.get(field) is True for row in rows) for field in _FLAGS}
        latest = max(rows, key=lambda row: (_integer(row.get('monotonicNS')) or 0,
                                            _integer(row.get('reportIndex')) or 0,
                                            _integer(row.get('_line')) or 0), default={})
        previous = None
        for row in sorted(rows, key=lambda r: (_integer(r.get('monotonicNS')) or 0, _integer(r.get('reportIndex')) or 0)):
            if previous and any(_integer(previous.get(field)) is not None and _integer(row.get(field)) is not None
                                and row[field] < previous[field] for field in _COUNTERS):
                group['gaps'].add('counter-decrease-or-source-lifetime-ambiguity')
            previous = row
        attempts, completed = (_integer(latest.get(field)) for field in ('allocationAttempts', 'allocationCallsCompleted'))
        pending_count = attempts - completed if attempts is not None and completed is not None and attempts >= completed else None
        if attempts is not None and completed is not None and attempts < completed:
            group['gaps'].add('noncoherent-attempt-completed-counters')
        if pending_count:
            group['gaps'].add('attempts-minus-completed-in-flight-or-unwound-only')
        if not rows:
            group['gaps'].add('no-cumulative-memory-snapshot')
        writer_errors = max((peaks.get(field) or 0 for field in ('writerErrorsTotal', 'diagnosticWriterErrors')), default=0)
        if writer_errors or peaks['eventJournalWriteErrors']:
            group['gaps'].add('observed-diagnostic-writer-errors')
        if any(row.get('diagnosticOutputAvailableWithoutObservedWriteError') is False for row in rows):
            group['gaps'].add('diagnostic-output-reported-unhealthy')
        if peaks['metadataLabelsTruncatedOrSanitized']:
            group['gaps'].add('metadata-labels-truncated-or-sanitized')
        if flags['historyCapped']:
            group['gaps'].add('snapshot-history-capped-at-1024-reports')
        coverage = {}
        for category, prefix, total_field, count_key in (
                ('failure', 'failure', 'failureEventsTotal', 'failureDetailsObserved'),
                ('slow', 'slow', 'slowEventsTotal', 'slowDetailsObserved')):
            items = list(group['events'][category].values())
            total = peaks[total_field]
            sequences = {_integer(item.get('sequence')) for item in items}
            sequences.discard(None)
            missing_count, missing_ranges = _missing_ranges(sequences, total, limit)
            ambiguous = any(len(payloads) > 1 for (kind, _), payloads in group['sequencePayloads'].items() if kind == category)
            if ambiguous:
                group['gaps'].add(category + '-sequence-reused-with-different-payload')
            if missing_count:
                group['gaps'].add(category + '-event-detail-sequences-missing')
            journal_omitted = peaks[prefix + 'JournalOmittedEvents']
            ring_omitted = peaks['recent' + ('Failure' if category == 'failure' else 'Slow') + 'RingOmittedEvents']
            if flags[prefix + 'JournalCapped'] or journal_omitted:
                group['gaps'].add(category + '-journal-capped-at-128-events')
            if ring_omitted:
                group['gaps'].add(category + '-recent-ring-omits-older-events')
            coverage[category] = dict(reportedEventsTotal=total, distinctDetailsObserved=len(items),
                observedSequenceCount=len(sequences), missingSequenceCount=missing_count,
                missingSequenceRanges=missing_ranges, sequenceConflicts=ambiguous,
                journalCapped=flags[prefix + 'JournalCapped'], journalOmittedEvents=journal_omitted,
                recentRingOmittedEvents=ring_omitted,
                detailCoverageCompleteForReportedSequences=bool(total is not None and not missing_count and not ambiguous
                    and all(_integer(item.get('sequence')) for item in items)
                    and all(0 < value <= total for value in sequences)))
            summary[count_key] += len(items)
            summary[prefix + 'DetailsMissingFromReportedSequences'] += missing_count or 0
            if total is not None:
                reported_totals[total_field] += total
                summary['identitiesWithReported' + ('Failure' if category == 'failure' else 'Slow') + 'Total'] += 1
            else:
                summary['identitiesWithoutReported' + ('Failure' if category == 'failure' else 'Slow') + 'Total'] += 1
            for item in items:
                item.update(identity)
                detail_lists[category].append(item)
                site_key = (group_number, category, str(item.get('site', '')), str(item.get('kind', '')), str(item.get('storageName', '')))
                aggregate = by_site[site_key]
                aggregate['observedDetails'] += 1
                aggregate['returnedNil'] += item.get('returnedNil') is True
                aggregate['rejectedBeforeMetalCall'] += item.get('rejectedBeforeMetalCall') is True
                known = item['requestedBytesForAnalysis']
                aggregate['knownByteRequests'] += known is not None
                aggregate['unknownByteRequests'] += known is None
                aggregate['summedKnownRequestedBytes'] += known or 0
                duration = item['observedHostCallWallNS']
                if duration is not None:
                    aggregate['summedObservedHostCallWallNS'] += duration
                    aggregate['largestObservedHostCallWallNS'] = max(aggregate['largestObservedHostCallWallNS'], duration)
        process_groups.append(dict(identity, sources=sorted(group['sources']), snapshotsObserved=len(rows),
            latestSnapshot=_ref(latest) if latest else None, counterPeaks=peaks, observedFlags=flags,
            coverage=coverage, gaps=sorted(group['gaps']),
            pending=dict(attemptsMinusCompleted=pending_count, allocationID=None, site=None,
                         interpretation='in-flight-or-unwound; no durable Begin exists, so the pending allocation ID/site is unknown'),
            latestDeviceMemory={field: latest.get(field) for field in (
                'deviceAvailable', 'currentAllocatedSizeAvailable', 'currentAllocatedSizeBytes',
                'recommendedMaxWorkingSetSizeAvailable', 'recommendedMaxWorkingSetSizeBytes',
                'hasUnifiedMemoryAvailable', 'hasUnifiedMemory', 'maxBufferLengthAvailable', 'maxBufferLengthBytes')}))
    for items in detail_lists.values():
        items.sort(key=lambda item: (-(item.get('observedHostCallWallNS') or 0), item['group'], _integer(item.get('sequence')) or 0))
    aggregates = [dict(group=key[0], eventCategory=key[1], site=key[2], kind=key[3], storageName=key[4], **dict(value))
                  for key, value in by_site.items()]
    aggregates.sort(key=lambda row: (-row['observedDetails'], -row.get('summedObservedHostCallWallNS', 0), row['group'], row['site']))
    unverified = sum(group['identityConfidence'] != 'caller-validated-process-start' for group in process_groups)
    distinct_starts = {(group['pid'], str(group['processStartIdentity'])) for group in process_groups}
    gaps = sorted({gap for group in process_groups for gap in group['gaps']})
    if input_counts['unclassifiedEvents']:
        gaps.append('unclassified-event-input')
    if input_counts['invalidRows']:
        gaps.append('invalid-input-rows')
    return dict(schema=1, allCausesFound=False, analysisKind='read-only-cpu-memory-observations',
        inputCounts=dict(input_counts), summary=dict(summary),
        reportedCumulativeTotalsByIdentityGroupSum=dict(reported_totals),
        reportedGroupSumIsDistinctValidatedProcesses=bool(process_groups and not unverified
            and len(distinct_starts) == len(process_groups)),
        processGroups=process_groups, failures=detail_lists['failure'][:limit],
        slowAllocationCalls=detail_lists['slow'][:limit], bySite=aggregates[:limit],
        outputLimit=limit, outputRankingCapped=any(len(items) > limit for items in (*detail_lists.values(), aggregates)),
        outputDetailsOmitted=dict(failures=max(0, len(detail_lists['failure']) - limit),
                                  slowAllocationCalls=max(0, len(detail_lists['slow']) - limit),
                                  bySite=max(0, len(aggregates) - limit)), gaps=gaps,
        semantics=[
            'Failure and slow event details are observations after a call returned, or after a pre-call rejection; no durable allocation Begin is recorded.',
            'Attempts minus completed means in-flight or unwound exceptions only. Pending allocation ID/site is unknown; it does not establish a hang, OOM, or GPU fault.',
            'Nil/unsuccessful result and caller-supplied resultCode do not independently identify OOM; pre-call rejection is not a failed Metal allocation call.',
            'allocationID and captured owner IDs are process-local. No external owner chain or cross-run allocation join is inferred.',
            'Only validated process start or an explicit caller-declared run permits cross-source deduplication; source-only group sums may count aliases of one process.',
            'Cumulative counters use per-group maxima, not snapshot sums. Journal and ring omission counts overlap and must not be added.',
            'The failure/slow journals retain their first 128 events; snapshot rings retain their recent 32. Missing journal rows can be recovered by rings, but cap flags remain evidence of journal omission.',
            'currentAllocatedSize is Metal API allocated resources, not free or physically resident VRAM. recommendedMaxWorkingSetSize is a performance threshold, not free capacity.',
            'Requested bytes are cumulative API requests, not live bytes; heaps and placed children may share backing. Unknown requested bytes remain unknown.',
            'Mach intervals are host-observed call wall time, not exclusive CPU, GPU busy time or frame cost. No interval end is reconstructed from wall UTC.',
            'Parsed input cannot establish file read completeness or unseen writer failures; the caller must retain source hashes and loader health.',
        ])
