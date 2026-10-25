import collections, json, math
from pathlib import Path
root = Path(__file__).resolve().parent
manifest = json.loads((root / 'run.stdout.json').read_text())
rows = [json.loads(line) for line in Path(manifest['logFile']).read_text().splitlines()]
checks = {}
def check(name, truth):
    checks[name] = bool(truth)
check('GPU_values_exact', manifest['GPUValuesChecked'] == 64 and manifest['GPUValueMismatches'] == 0)
check('concurrent_metadata_coherent', manifest['metadataIncoherentReads'] == 0 and manifest['handlersCompleted'])
check('rearm_changes_identity', manifest['oldSession'] != manifest['newSession'])
check('old_record_keeps_session', manifest['producerSession'] == manifest['oldSession'])
check('new_record_gets_session', manifest['consumerSession'] == manifest['newSession'])
check('late_capture_marked_partial', manifest['latePartialPrefix'])
for native_id, parent, split, frame, family, index in [(manifest['nativeA'],42,1,901,2,0),(manifest['nativeB'],43,2,902,3,1)]:
    subset = [r for r in rows if r['type']=='nativeCB' and r['nativeCB']==native_id]
    associated = [r for r in subset if r['phase']!='created']
    check(f'{native_id}_parent_metadata', all((r['logicalSubmit'],r['split'],r['presentFrame'],r['family'],r['index']) == (parent,split,frame,family,index) for r in associated))
    phases = {r['phase'] for r in subset}
    check(f'{native_id}_all_native_phases', {'created','associated','commitRequested','scheduled','completed'} <= phases)
    end = [r for r in subset if r['phase']=='completed']
    check(f'{native_id}_GPU_time_valid', len(end)==1 and end[0]['nativeStatus']==4 and 0<end[0]['gpuStartCA']<end[0]['gpuEndCA'])
signal = [r for r in rows if r['type']=='event' and r['phase']=='signal-encoded']
wait = [r for r in rows if r['type']=='event' and r['phase']=='wait-encoded']
check('shared_event_edge_identifies_same_value', len(signal)==len(wait)==1 and signal[0]['event']==wait[0]['event'] and signal[0]['requested']==wait[0]['requested']==7)
observed = [r for r in rows if r['type']=='event' and r['phase']=='completion-observed']
check('shared_event_satisfied_on_completion', len(observed)==2 and all(r['observed']>=7 and r['satisfied'] for r in observed))
check('GPU_dependency_execution_order', manifest['producerGPUEnd'] <= manifest['consumerGPUStart'])
calibrations = [r for r in rows if r['type']=='clockCalibration']
check('each_session_calibrated', {r['session'] for r in calibrations} == {manifest['oldSession'],manifest['newSession']})
cf_ca_offsets = [r['timeCF']-r['timeCA'] for r in calibrations]
mono_ca_offsets = [r['monotonicNS']/1e9-r['timeCA'] for r in calibrations]
check('three_clocks_have_consistent_anchors', len(calibrations)==2 and max(cf_ca_offsets)-min(cf_ca_offsets)<0.001 and max(mono_ca_offsets)-min(mono_ca_offsets)<0.001)
loss = [r for r in rows if r['type']=='coverageLoss']
check('cap_loss_visible', [r['droppedRowsLowerBound'] for r in loss]==[1,1024] and all(r['complete'] is False and r['reason']=='native-row-cap' and r['rowCap']==200000 for r in loss))
present=[r for r in rows if r['type']=='present']
check('headless_present_explicitly_synthetic', manifest['syntheticPresentFormattingOnly'] and len(present)==2 and not any(p['nativeTimestampValid'] for p in present))
check('cap_boundary_explicitly_injected', manifest['syntheticBudgetBoundaryRowsInjected']==200000)
host_wait = [r for r in rows if r['type']=='event' and r['phase'].startswith('hostWait')]
check('host_wait_fixed_session_after_rearm', len(host_wait)==2 and all(r['session']==manifest['oldSession'] and r['outsideArm'] for r in host_wait))
check('late_present_explicitly_partial', len(present)==2 and present[1]['partialPrefix'] and present[1]['nativeCB']==manifest['nativeB'])
check('true_commit_marker_published_later', all(r['committedCA']>0 and r['committedCA']>=r['createdCA'] for r in rows if r['type']=='nativeCB' and r['phase']=='completed'))
summary={'allChecksPassed':all(checks.values()),'checks':checks,'parsedRows':len(rows),'rowKinds':dict(collections.Counter(r['type'] for r in rows)),'graphCoverageComplete':not loss,'coverageIncompleteExpectedReason':'Synthetic admission-counter boundary test at end; not missing GPU work.','clockAnchorMaxSpreadSeconds':{'CF_minus_CA':max(cf_ca_offsets)-min(cf_ca_offsets),'monotonic_minus_CA':max(mono_ca_offsets)-min(mono_ca_offsets)},'actualPresentationVerified':False}
(root/'parser-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
raise SystemExit(not summary['allChecksPassed'])
