"""Read-only joins for native sync diagnostics; no producer/return inference."""
from collections import Counter, defaultdict
import json

WAIT_KINDS = ('NativeWaitRegistration', 'NativeWaitRegistrationPublished',
              'NativeWaitNotifyEntry', 'NativeWaitNotify')
SIGNAL_KINDS = ('NativeHostSignalBegin', 'NativeHostSignal')


def analyze(rows, limit=500):
    if not isinstance(limit, int) or limit < 1:
        raise ValueError('positive output ranking limit required')
    counts = Counter(); kinds = Counter(); waits = defaultdict(lambda: defaultdict(list))
    signals = defaultdict(lambda: defaultdict(list)); seen = {}; conflicts = set()
    invalid = []

    def positive(value):
        return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None

    def reference(row):
        return {key[1:]: row[key] for key in ('_source', '_line') if key in row}

    def pid(row):
        return positive(row.get('_pid')) or positive(row.get('pid'))

    def interval(fields, start, end):
        a, b = positive(fields.get(start)), positive(fields.get(end))
        return b-a if a is not None and b is not None and b >= a else None

    def reported(fields, name):
        return positive(fields.get(name))

    for row in rows:
        counts['inputRows'] += 1
        kind = row.get('kind')
        if row.get('type') != 'forensics' or kind not in WAIT_KINDS + SIGNAL_KINDS:
            continue
        fields = row.get('fields')
        if not isinstance(fields, dict):
            counts['invalidFields'] += 1
            continue
        sequence = positive(row.get('seq'))
        identity = (pid(row), positive(row.get('runID')), positive(row.get('session')))
        record_id = positive(fields.get('waitRegistrationID' if kind in WAIT_KINDS else 'operationID'))
        if None in identity or record_id is None:
            counts['invalidIdentityRecords'] += 1
            if len(invalid) < limit:
                invalid.append(dict(kind=kind,identity=list(identity),recordID=record_id,source=reference(row)))
            continue
        # Sequence is process-run global. Repeated copied windows are the same
        # row; conflicting copies invalidate phase uniqueness, never last-win.
        if sequence is not None:
            key = identity[:2] + (sequence,)
            payload = json.dumps({k:v for k,v in row.items() if not k.startswith('_')},sort_keys=True,default=str)
            if key in seen:
                if seen[key] == payload:
                    counts['duplicateCopies'] += 1
                    continue
                conflicts.add(key);counts['conflictingSequenceCopies'] += 1
            else:
                seen[key] = payload
        else:
            counts['recordsWithoutSequence'] += 1
        counts['uniqueRelevantRecords'] += 1;kinds[kind] += 1
        destination = waits if kind in WAIT_KINDS else signals
        destination[identity + (record_id,)][kind].append(row)

    def phase(phases, kind):
        values = phases.get(kind, [])
        return values[0].get('fields', {}) if len(values) == 1 else {}

    def ambiguous(phases):
        if any(len(values) != 1 for values in phases.values()):
            return True
        return any((pid(r),r.get('runID'),r.get('seq')) in conflicts for values in phases.values() for r in values)

    def identity_conflicts(phases):
        result=[]
        for name in ('semaphore','event','requestedValue','waiterThreadMachID','waiterSubmission','waiterNativeCB',
                     'callbackEntryMachNS','signalSource','signalThreadMachID'):
            values={r['fields'][name] for records in phases.values() for r in records if name in r.get('fields',{})}
            if len(values)>1:result.append(name)
        for records in phases.values():
            for r in records:
                f=r['fields']
                if f.get('callbackEvent') and f.get('event') and f['callbackEvent']!=f['event']:
                    result.append('callbackEvent')
        return sorted(set(result))

    def base(key, phases, id_name):
        return dict(pid=key[0],runID=key[1],ownerSession=key[2],**{id_name:key[3]},
            ambiguousPhaseCopies=ambiguous(phases),identityConflicts=identity_conflicts(phases),
            phases={name:[dict(source=reference(r),seq=r.get('seq'),session=r.get('session'),
                streamSession=r.get('streamSession'),threadMachID=r.get('threadMachID'),fields=r.get('fields',{}))
                for r in values] for name,values in phases.items()})

    wait_rows=[];dispositions=Counter();wait_counts=Counter({key:0 for key in (
        'groups','registrationAndNotificationObserved','entryWithoutEnd','installedWithoutObservedEntry',
        'openObservation','ambiguousPhaseCopies','identityConflictGroups')})
    for key, phases in waits.items():
        reg=phase(phases,'NativeWaitRegistration');pub=phase(phases,'NativeWaitRegistrationPublished')
        entry=phase(phases,'NativeWaitNotifyEntry');end=phase(phases,'NativeWaitNotify')
        item=base(key,phases,'waitRegistrationID')
        disposition=reg.get('registrationDisposition')
        name={1:'already-ready',2:'listener-installed',3:'duplicate-sitter'}.get(disposition,'unknown')
        dispositions[name]+=1
        item.update(registrationObserved=bool(reg),publicationObserved=bool(pub),
            notifyEntryObserved=bool(entry),notifyEndObserved=bool(end),registrationDisposition=disposition,
            dispositionName=name,listenerInstalled=reg.get('listenerInstalled'),
            registrationAPIWallNS=interval(reg,'registrationStartMachNS','registrationEndMachNS'),
            registrationWriterWallNS=interval(pub,'intentWriterStartMachNS','intentWriterEndMachNS'),
            entryWriterWallNS=reported(end,'entryWriterWallNS'),
            releaseAPIWallNS=interval(end,'releaseBeforeMachNS','releaseAfterMachNS'),
            callbackEntryToReleaseBeforeNS=interval(end,'callbackEntryMachNS','releaseBeforeMachNS'),
            callbackEntryToReleaseBeforeIncludesWriter=True,
            exactMutexWaitNS=None,waiterReturned=None,actualSignalProducer=None,
            sitterSignaled=end.get('sitterSignaled'),signalOriginKnown=end.get('signalOriginKnown'),
            event=reg.get('event',end.get('event',entry.get('event'))),
            requestedValue=reg.get('requestedValue',end.get('requestedValue',entry.get('requestedValue'))),
            callbackObservedValue=end.get('observedValue',entry.get('observedValue')),
            waiterSubmission=reg.get('waiterSubmission',end.get('waiterSubmission',entry.get('waiterSubmission'))),
            waiterThreadMachID=reg.get('waiterThreadMachID',end.get('waiterThreadMachID',entry.get('waiterThreadMachID'))))
        begin=positive(reg.get('registrationEndMachNS'));callback=positive(end.get('callbackEntryMachNS')) or positive(entry.get('callbackEntryMachNS'))
        # The callback can run concurrently before registration returns. Preserve
        # that signed observation instead of calling it a negative clock error.
        item['callbackMinusRegistrationReturnNS']=callback-begin if callback and begin else None
        item['callbackBeforeRegistrationReturn']=bool(callback and begin and callback<begin)
        coherent=not item['ambiguousPhaseCopies'] and not item['identityConflicts']
        item['unexpectedNotificationForDisposition']=bool(disposition in (1,3) and (entry or end))
        coherent=coherent and not item['unexpectedNotificationForDisposition']
        item['registrationAndNotificationObserved']=bool(reg and entry and end and coherent)
        item['entryWithoutEnd']=bool(entry and not end)
        item['installedWithoutObservedEntry']=bool(disposition==2 and not entry)
        item['openObservation']=item['entryWithoutEnd'] or item['installedWithoutObservedEntry']
        wait_counts['groups']+=1
        for flag in ('registrationAndNotificationObserved','entryWithoutEnd','installedWithoutObservedEntry','openObservation','ambiguousPhaseCopies'):
            wait_counts[flag]+=bool(item[flag])
        wait_counts['identityConflictGroups']+=bool(item['identityConflicts'])
        wait_rows.append(item)

    signal_rows=[];signal_counts=Counter({key:0 for key in ('groups','paired','openObservation','ambiguousPhaseCopies','identityConflictGroups')})
    for key,phases in signals.items():
        begin=phase(phases,'NativeHostSignalBegin');end=phase(phases,'NativeHostSignal')
        item=base(key,phases,'operationID');f=end or begin
        item.update(beginObserved=bool(begin),endObserved=bool(end),openObservation=bool(begin and not end),
            paired=bool(begin and end and not item['ambiguousPhaseCopies'] and not item['identityConflicts']),
            callAPIWallNS=interval(end,'callStartMachNS','callEndMachNS'),
            intentWriterWallNS=reported(end,'intentWriterWallNS'),setterReturned=end.get('setterReturned'),
            observedValueAvailable=end.get('observedValueAvailable'),event=f.get('event'),
            requestedValue=f.get('requestedValue'),signalSource=f.get('signalSource'),
            signalSourceName={1:'Vulkan-host-timeline-signal',2:'import-signaled-sync-fd-minus-one'}.get(f.get('signalSource'),'unknown'),
            actualSignalObserved=None,waiterReturned=None)
        signal_counts['groups']+=1
        for flag in ('paired','openObservation','ambiguousPhaseCopies'):signal_counts[flag]+=bool(item[flag])
        signal_counts['identityConflictGroups']+=bool(item['identityConflicts']);signal_rows.append(item)

    wait_rows.sort(key=lambda r:max(r.get('callbackEntryToReleaseBeforeNS') or -1,r.get('registrationAPIWallNS') or -1),reverse=True)
    signal_rows.sort(key=lambda r:r.get('callAPIWallNS') or -1,reverse=True)
    open_waits=[r for r in wait_rows if r['openObservation']]
    open_signals=[r for r in signal_rows if r['openObservation']]
    return dict(schema=1,allCausesFound=False,input=dict(counts),kinds=dict(kinds),
        waitCounts=dict(wait_counts),waitDispositionCounts=dict(dispositions),signalCounts=dict(signal_counts),
        waits=wait_rows[:limit],hostSignals=signal_rows[:limit],openWaits=open_waits[:limit],openHostSignals=open_signals[:limit],
        invalidIdentityRecords=invalid,invalidIdentityOutputCapped=counts['invalidIdentityRecords']>len(invalid),
        outputRankingCapped=any(len(x)>limit for x in (wait_rows,signal_rows,open_waits,open_signals)),
        limits=['Missing phases are open observations until capture boundaries, drops and tail coverage are audited; they do not prove a hang.',
            'sitterSignaled and setterReturned do not prove waiter return, GPU completion or the actual producer.',
            'Callback entry to release includes logger time and lock/scheduling; no exact mutex wait is measured here.',
            'Zero or invalid timestamp brackets are unknown. Registration callbacks can precede registration return concurrently.',
            'Observed event/value equality does not identify object lifetime or a unique host/GPU signal producer.',
            'Rankings are bounded; counts cover every unique provided relevant row, not every runtime operation.'])
