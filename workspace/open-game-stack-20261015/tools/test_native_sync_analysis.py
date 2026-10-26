import unittest
from analyze_native_sync import analyze


def event(kind,fields,seq,session=10,stream=10,pid=123,run=1):
    return dict(type='forensics',kind=kind,pid=pid,runID=run,session=session,
        streamSession=stream,streamOwnershipSchema=2,seq=seq,fields=fields,_source='fixture',_line=seq)


def complete_wait(registration=1,session=10):
    identity=dict(waitRegistrationID=registration,event=55,semaphore=66,requestedValue=7,
        waiterThreadMachID=99,waiterSubmission=4,waiterNativeCB=0)
    return [
        event('NativeWaitRegistration',dict(identity,registrationStartMachNS=100,registrationEndMachNS=200,
            registrationDisposition=2,listenerInstalled=1,observedValue=0),1,session),
        event('NativeWaitRegistrationPublished',dict(waitRegistrationID=registration,intentWriterStartMachNS=201,
            intentWriterEndMachNS=301,intentWriterWallNS=100),2,session),
        event('NativeWaitNotifyEntry',dict(identity,callbackEntryMachNS=500,callbackEvent=55,observedValue=7),3,session,20),
        event('NativeWaitNotify',dict(identity,callbackEntryMachNS=500,callbackEvent=55,observedValue=7,
            releaseBeforeMachNS=650,releaseAfterMachNS=660,entryWriterWallNS=100,
            sitterSignaled=1,signalOriginKnown=0),4,session,20)]


class NativeSyncTests(unittest.TestCase):
    def test_late_cross_arm_keeps_logical_owner(self):
        r=analyze(complete_wait());w=r['waits'][0]
        self.assertTrue(w['registrationAndNotificationObserved'])
        self.assertEqual(w['ownerSession'],10)
        self.assertEqual(w['registrationAPIWallNS'],100)
        self.assertEqual(w['registrationWriterWallNS'],100)
        self.assertEqual(w['releaseAPIWallNS'],10)
        self.assertEqual(w['callbackEntryToReleaseBeforeNS'],150)
        self.assertEqual(w['entryWriterWallNS'],100)
        self.assertIsNone(w['exactMutexWaitNS']);self.assertIsNone(w['waiterReturned']);self.assertIsNone(w['actualSignalProducer'])

    def test_pid_run_and_logical_session_never_cross_pair(self):
        for field,value in [('pid',999),('runID',2),('session',20)]:
            rows=complete_wait();rows[2][field]=value;rows[3][field]=value
            r=analyze(rows)
            self.assertEqual(r['waitCounts']['groups'],2)
            self.assertEqual(r['waitCounts']['registrationAndNotificationObserved'],0)
            self.assertEqual(r['waitCounts']['installedWithoutObservedEntry'],1)

    def test_zero_bad_timestamp_unknown(self):
        rows=complete_wait();rows[0]['fields']['registrationStartMachNS']=0
        rows[3]['fields']['releaseAfterMachNS']=649;rows[3]['fields']['entryWriterWallNS']=0
        w=analyze(rows)['waits'][0]
        self.assertIsNone(w['registrationAPIWallNS']);self.assertIsNone(w['releaseAPIWallNS']);self.assertIsNone(w['entryWriterWallNS'])

    def test_concurrent_callback_before_registration_returns(self):
        rows=complete_wait();rows[0]['fields']['registrationEndMachNS']=600
        w=analyze(rows)['waits'][0]
        self.assertEqual(w['callbackMinusRegistrationReturnNS'],-100)
        self.assertTrue(w['callbackBeforeRegistrationReturn'])

    def test_ready_duplicate_are_not_open_missing_callbacks(self):
        rows=[]
        for index,disposition in enumerate((1,3),1):
            rows.append(event('NativeWaitRegistration',dict(waitRegistrationID=index,
                registrationDisposition=disposition,listenerInstalled=0),index))
        r=analyze(rows)
        self.assertEqual(r['waitCounts']['openObservation'],0)
        self.assertEqual(r['waitDispositionCounts'],{'already-ready':1,'duplicate-sitter':1})

    def test_entry_without_end_and_sitter_removed(self):
        rows=complete_wait()[:-1];r=analyze(rows)
        self.assertEqual(r['waitCounts']['entryWithoutEnd'],1)
        self.assertIsNone(r['openWaits'][0]['releaseAPIWallNS'])
        rows=complete_wait();rows[-1]['fields'].update(sitterSignaled=0,releaseBeforeMachNS=0,releaseAfterMachNS=0)
        w=analyze(rows)['waits'][0]
        self.assertEqual(w['sitterSignaled'],0);self.assertIsNone(w['releaseAPIWallNS']);self.assertIsNone(w['waiterReturned'])

    def test_identity_conflict_not_paired(self):
        rows=complete_wait();rows[-1]['fields']['callbackEvent']=999
        w=analyze(rows)['waits'][0]
        self.assertFalse(w['registrationAndNotificationObserved']);self.assertIn('callbackEvent',w['identityConflicts'])

    def test_copied_window_dedup_conflict_not_last_wins(self):
        rows=complete_wait();duplicate=dict(rows[0],_source='other-window')
        r=analyze(rows+[duplicate]);self.assertEqual(r['input']['duplicateCopies'],1)
        changed=dict(duplicate,fields=dict(duplicate['fields'],event=999))
        w=analyze(rows+[changed])['waits'][0]
        self.assertTrue(w['ambiguousPhaseCopies']);self.assertFalse(w['registrationAndNotificationObserved'])

    def test_host_signal_api_writer_and_open(self):
        identity=dict(operationID=8,event=55,requestedValue=7,signalSource=1,signalThreadMachID=90)
        begin=event('NativeHostSignalBegin',dict(identity,intentMachNS=100),1)
        end=event('NativeHostSignal',dict(identity,callStartMachNS=400,callEndMachNS=430,
            intentWriterWallNS=300,setterReturned=1,observedValueAvailable=0),2,stream=20)
        r=analyze([begin,end]);s=r['hostSignals'][0]
        self.assertTrue(s['paired']);self.assertEqual(s['callAPIWallNS'],30);self.assertEqual(s['intentWriterWallNS'],300)
        self.assertIsNone(s['actualSignalObserved']);self.assertIsNone(s['waiterReturned'])
        self.assertEqual(analyze([begin])['signalCounts']['openObservation'],1)

    def test_missing_identity_unknown_not_fake_join(self):
        rows=complete_wait();rows[0]['runID']=None
        r=analyze(rows);self.assertEqual(r['input']['invalidIdentityRecords'],1)
        self.assertFalse(r['waits'][0]['registrationAndNotificationObserved'])

    def test_counts_cover_rows_beyond_bounded_ranking(self):
        rows=[]
        for number in range(1,8):
            row=complete_wait(number)[0];row['seq']=number;rows.append(row)
        r=analyze(rows,limit=2)
        self.assertEqual(len(r['waits']),2);self.assertEqual(len(r['openWaits']),2)
        self.assertEqual(r['waitCounts']['groups'],7);self.assertTrue(r['outputRankingCapped'])
        self.assertFalse(r['allCausesFound'])


if __name__=='__main__':unittest.main()
