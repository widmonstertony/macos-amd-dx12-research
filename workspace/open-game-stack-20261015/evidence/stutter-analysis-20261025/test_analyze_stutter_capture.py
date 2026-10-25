#!/usr/bin/env python3
"""CPU-only fixture qualification. No game, Wine, native GPU or process input."""
from __future__ import annotations
from copy import deepcopy
from decimal import Decimal as D
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("stutter_analyzer", ROOT / "tools/analyze_stutter_capture.py")
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
PID = 424242
SESSION = 1792950173981942001
OFFSET = D(799999900)


def write(path, value, jsonl=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if jsonl:
        path.write_text("\n".join(json.dumps(M.json_ready(v)) for v in value) + "\n")
    else:
        M.dump(path, value)


def stamp(ca):
    return dict(timeCA=ca, timeCF=ca + OFFSET, session=SESSION)


def cb(cbid, submission, frame, created, commit, start, end, queue=0):
    rows = []
    phases = [("created", created), ("associated", created + D(".000000001")),
              ("enqueue", commit - D(".000000001")), ("commit", commit),
              ("scheduled", start), ("completed", end + D(".000000001"))]
    for phase, time in phases:
        rows.append(dict(type="nativeCB", phase=phase, nativeCB=cbid, logicalSubmit=submission,
                         split=cbid - 1, presentFrame=frame, family=queue, index=0,
                         createdCA=created, committedCA=commit if phase in ("commit", "scheduled", "completed") else 0,
                         scheduledCA=start if phase in ("scheduled", "completed") else 0,
                         gpuStartCA=start if phase == "completed" else 0,
                         gpuEndCA=end if phase == "completed" else 0,
                         nativeStatus=4 if phase == "completed" else 2,
                         partialPrefix=False, counterSession=0, counterSkip=0,
                         counterAllocated=False, counterMidCB=False, droppedRows=0, **stamp(time)))
    return rows


def fixture(work_ms=1, gpu_ms=2, wait_ms=0, interval_ms=D("16.666667")):
    present = D(100) + interval_ms / 1000
    commit = D(100) + D(str(work_ms + wait_ms)) / 1000
    start = commit + D(".0001")
    end = start + D(str(gpu_ms)) / 1000
    if end > present:
        present = end + D(".001")
    rows = [dict(type="clockCalibration", monotonicNS=100000000000,
                 rowCap=200000, armMaxSeconds=30, **stamp(D(100)))]
    rows += cb(1, 1, 1001, D("99.990"), D("99.991"), D("99.992"), D("99.994"))
    rows += [dict(type="present", presentFrame=1001, swapchain=7, appPresentId=1001,
                  nativeTimestampCA=D(100), nativeTimestampValid=True, droppedRows=0, **stamp(D("100.0001")))]
    rows += cb(2, 2, 1002, D(100), commit, start, end)
    rows += [dict(type="submission", phase=phase, logicalSubmit=2, family=0, index=0,
                  createdMonotonicNS=100000000000, droppedRows=0, **stamp(t))
             for phase, t in (("created", D(100)), ("queued", D(100)), ("executing", D(100)))]
    rows += [dict(type="present", presentFrame=1002, swapchain=7, appPresentId=1002,
                  nativeTimestampCA=present, nativeTimestampValid=True, droppedRows=0, **stamp(present + D(".0001")))]
    phases = [dict(stage=1, count=1, inclusiveWallNS=500000000, selfWallNS=int(work_ms * 1000000),
                   maxInclusiveNS=500000000, maxSelfNS=int(work_ms * 1000000), failures=0)]
    if wait_ms:
        phases.append(dict(stage=2, count=1, inclusiveWallNS=int(wait_ms * 1000000), selfWallNS=int(wait_ms * 1000000),
                           maxInclusiveNS=int(wait_ms * 1000000), maxSelfNS=int(wait_ms * 1000000), failures=0))
    cpu = dict(schema=1, captureEnabled=True, time=present + OFFSET,
               unixTimeNS=1792950173981942001, windowStartNS=99900000000,
               windowEndNS=int((present + D(".001")) * M.NS),
               windowAssignment="span completion", selfMeaning="same-thread measured-child subtraction",
               diagnosticOverheadNotSubtracted=True, slowSpansDropped=0, invalidIDs=0,
               badNesting=0, depthOverflow=0, publicationFailures=0, slowSpans=[], inFlight=[],
               detailedEnabled=True, detailedArmEpoch=11, detailedArmStartNS=99900000000,
               detailedCapacityPerThread=1024, detailedOverflowEvents=0,
               detailedUnattributedEvents=0, detailedUnattributedSelfNS=0,
               detailedColdAllocations=0, detailedColdAllocationNS=0, detailedUnpreparedEvents=0,
               rows=[dict(domain=0, stage=1, name="NativeRead", kind="work", count=1,
                          selfWallNS=int(work_ms * 1000000), inclusiveWallNS=500000000),
                     dict(domain=0, stage=2, name="HostSemaphoreWait", kind="wait", count=1 if wait_ms else 0,
                          selfWallNS=int(wait_ms * 1000000), inclusiveWallNS=int(wait_ms * 1000000))],
               submissions=[dict(domain=0, queueFamily=0, queueIndex=0, submission=2, thread=222,
                                 startNS=100000000000, endNS=int(commit * M.NS), firstNativeCB=2, lastNativeCB=2,
                                 mixedNativeCB=False, firstFrame=1002, lastFrame=1002, mixedFrame=False,
                                 armEpoch=11, mixedArm=False, beganBeforeArm=False,
                                 beganBeforeWindow=False, openAtReport=False, phases=phases)])
    metadata = dict(schema=1, target=dict(pid=PID, lstart="Sun Oct 25 10:00:00 2026", comm="synthetic-non-game"),
                    processStartAbstime=999, timebase=dict(numer=1, denom=1),
                    rawCPUTimeUnits="synthetic fixture counters")
    system = [dict(clock=dict(CFAbsoluteTime=t + OFFSET, unixSeconds=t + OFFSET + M.CF_UNIX_OFFSET,
                              monotonicSeconds=t, machAbsoluteTicks=int(t * M.NS)), pid=PID,
                   identity=dict(pid=PID, lstart=metadata["target"]["lstart"], present=True),
                   usage=dict(available=True, processStartAbstime=999, residentBytes=1234, physicalFootprintBytes=2345),
                   usageDelta=dict(userTime=10, systemTime=2, diskBytesRead=100),
                   taskCounterDelta=dict(faults=2, pageins=1),
                   threadCounters=dict(available=True, listMayBeTruncated=False),
                   threadCPU=dict(rows=[dict(handle="0x1", name="test-thread", userCounterDelta=10,
                                             systemCounterDelta=2, totalCounterDelta=12)])) for t in (D("99.9"), present)]
    foreground = [dict(time=t["clock"]["CFAbsoluteTime"], pid=PID, alive=True, active=True,
                       frontmostPID=PID, visible=True, pointWidth=1280, pointHeight=800) for t in system]
    return dict(native=rows, cpu=cpu, metadata=metadata, system=system, foreground=foreground)


def analyze(out, name, data, reference=None, max_rows=M.MAX_INPUT_ROWS):
    directory = out / name
    directory.mkdir()
    native = directory / f"stutter-native-{PID}.jsonl"
    cpu = directory / f"cpu-stutter-{PID}.jsonl"
    current = directory / f"cpu-stutter-current-{PID}.json"
    write(native, data["native"], True)
    write(cpu, [data["cpu"]], True)
    write(current, data["cpu"])
    system = directory / "system"
    write(system / "metadata.json", data["metadata"])
    write(system / "summary.json", dict(observabilityWarnings=[], errors=[], coverage={}))
    write(system / "timeline.jsonl", data["system"], True)
    write(system / "foreground.jsonl", data["foreground"], True)
    analyzer = M.Analyzer(target_pid=PID, max_rows=max_rows)
    analyzer.load_system(system)
    analyzer.load_native([native])
    analyzer.load_cpu([cpu, current])
    if reference is not None:
        analyzer.reference_cf = reference
    report = analyzer.report()
    M.dump(directory / "analysis.json", report)
    (directory / "analysis.md").write_text(M.markdown(report))
    return analyzer, report


def run_tests(out):
    checks, metrics = {}, {}
    data = fixture()
    a, normal = analyze(out, "normal", data)
    frame = normal["frames"][-1]
    checks["normalPresentWithinTarget"] = not frame["slowComparedWithTarget"] and abs(frame["intervalMs"] - D("16.666667")) < D(".000001")
    checks["cpuInclusiveNeverAdded"] = frame["CPU"]["workSelfWallMs"] == 1 and frame["CPU"]["phaseRanking"][0]["inclusiveWallNS"] == 500000000
    checks["historyCurrentDeduplicated"] = normal["CPUPhaseRanking"][0]["selfWallNS"] == 1000000
    checks["queueDAGEdgeAndNativeSplit"] = any(e["kind"] == "queue-order" for e in frame["dependencyEdges"]) and any(c["split"] == 1 and c["logicalSubmit"] == 2 for c in frame["GPU"]["commandBuffers"])
    checks["sessionIntegerPrecision"] = normal["clockCorrelation"][0]["session"] == SESSION and json.loads(json.dumps(M.json_ready(normal)))["clockCorrelation"][0]["session"] == SESSION
    checks["neverClaimsAllCausesFound"] = normal["allCausesFound"] is False and normal["coverage"]["complete"] is False
    _, cpu = analyze(out, "cpu-bound", fixture(work_ms=40, interval_ms=D(50)))
    checks["cpuBoundRanking"] = cpu["frames"][-1]["observedContributors"][0]["category"] == "CPU measured work" and cpu["frames"][-1]["slowComparedWithTarget"]
    _, gpu = analyze(out, "gpu-bound", fixture(gpu_ms=40, interval_ms=D(50)))
    checks["gpuBoundRanking"] = gpu["frames"][-1]["observedContributors"][0]["category"] == "GPU execution interval union"
    wait_data = fixture(wait_ms=40, interval_ms=D(50))
    wait_data["native"] += [dict(type="event", phase=phase, nativeCB=0, logicalSubmit=2, event=123,
                                  requested=7, observed=7 if phase == "hostWaitEnd" else 0,
                                  satisfied=phase == "hostWaitEnd", droppedRows=0, **stamp(t))
                            for phase, t in (("hostWaitBegin", D("100.001")), ("hostWaitEnd", D("100.041")))]
    _, wait = analyze(out, "wait-bound", wait_data)
    checks["waitBoundRanking"] = wait["frames"][-1]["observedContributors"][0]["category"] == "CPU measured waits" and wait["frames"][-1]["hostWaits"]["clippedIntervalUnionMs"] == 40
    missing = fixture()
    missing["native"].append(dict(type="event", phase="wait-encoded", nativeCB=2, logicalSubmit=2, event=1234,
                                   requested=700, observed=0, satisfied=False, droppedRows=0, **stamp(D("100.0005"))))
    _, report = analyze(out, "missing-producer", missing)
    checks["missingProducerExplicitlyIncomplete"] = "external-or-ambiguous-event-producer" in report["coverage"]["issueCounts"]
    cap = fixture()
    cap["native"].append(dict(type="coverageLoss", reason="native-row-cap", rowCap=200000,
                               emittedRows=200000, droppedRowsLowerBound=4, complete=False, **stamp(D("100.010"))))
    cap["cpu"]["detailedOverflowEvents"] = 5
    cap["cpu"]["diagnosticAllocationDrops"] = 1
    cap["cpu"]["detailedThreadBudgetDropEvents"] = 2
    cap["cpu"]["aggregateCoverageIncomplete"] = True
    _, report = analyze(out, "caps", cap)
    checks["nativeAndCPUCapExplicitlyIncomplete"] = all(k in report["coverage"]["issueCounts"] for k in ("native-coverage-loss", "cpu-detailedOverflowEvents"))
    checks["diagnosticAllocationAndThreadBudgetLossExplicit"] = all(k in report["coverage"]["issueCounts"] for k in ("cpu-diagnosticAllocationDrops", "cpu-detailedThreadBudgetDropEvents", "cpu-aggregateCoverageIncomplete"))
    stale = fixture()
    stale["cpu"]["time"] -= 120
    stale["system"][-1]["native"] = {"memory-current": {"name": "memory-current-test.json", "numericFields": {}, "sourceFreshWithin15Seconds": False, "sourceAgeSeconds": 120}}
    _, report = analyze(out, "stale", stale, reference=D(100) + OFFSET + 120)
    checks["staleCPUAndNativeAndNumericExplicit"] = all(k in report["coverage"]["issueCounts"] for k in ("cpu-report-stale", "native-clock-anchor-stale", "system-native-snapshot-stale"))
    missing_end = fixture()
    missing_end["native"] = [r for r in missing_end["native"] if not (r.get("nativeCB") == 2 and r.get("phase") == "completed")]
    _, report = analyze(out, "missing-completion", missing_end)
    checks["missingCompletionExplicit"] = "native-completion-missing" in report["coverage"]["issueCounts"]
    disabled = fixture()
    disabled["cpu"]["captureEnabled"] = False
    disabled["cpu"]["detailedEnabled"] = False
    _, report = analyze(out, "disabled", disabled)
    checks["disabledInstrumentationExplicit"] = all(k in report["coverage"]["issueCounts"] for k in ("cpu-instrumentation-disabled", "cpu-detail-disabled"))
    invalid_present = fixture()
    invalid_present["native"][-1]["nativeTimestampValid"] = False
    invalid_present["native"][-1]["nativeTimestampCA"] = 0
    _, report = analyze(out, "invalid-present", invalid_present)
    checks["callbackNeverUsedAsNativePacing"] = report["frames"][-1]["intervalMs"] is None and "native-present-timestamp-unavailable" in report["coverage"]["issueCounts"]
    partial_present = fixture()
    partial_present["native"][-1].update(nativeCB=2, partialPrefix=True)
    for row in partial_present["native"]:
        if row.get("nativeCB") == 2 and row.get("type") == "nativeCB":
            row["presentFrame"] = 0
    _, report = analyze(out, "partial-present-prefix", partial_present)
    checks["partialPresentPrefixExplicitlyIncomplete"] = "native-present-partial-prefix" in report["coverage"]["issueCounts"] and report["frames"][-1]["partialPrefix"] is True and not report["frames"][-1]["GPU"]["criticalPath"]["observedCoverageComplete"]
    checks["explicitPresentNativeCBUsedForAttribution"] = report["frames"][-1]["nativeCB"] == 2 and f"{PID}:2" in report["frames"][-1]["targetCommandBuffers"]
    event_data = fixture()
    event_data["native"] += [dict(type="event", phase="signal-encoded", nativeCB=1, logicalSubmit=1, event=123,
                                  requested=9, observed=0, satisfied=False, droppedRows=0, **stamp(D("99.9911"))),
                             dict(type="event", phase="wait-encoded", nativeCB=2, logicalSubmit=2, event=123,
                                  requested=7, observed=0, satisfied=False, droppedRows=0, **stamp(D("100.0001")))]
    _, report = analyze(out, "event-value", event_data)
    checks["eventThresholdProducerMapped"] = any(e["kind"] == "event-value" and e["requested"] == 7 and e["producerSignalValue"] == 9 and e["before"].endswith(":1") for e in report["frames"][-1]["dependencyEdges"])
    event_data["native"] += [dict(type="event", phase=phase, nativeCB=0, logicalSubmit=2, event=123,
                                  requested=7, observed=7, satisfied=phase == "hostWaitEnd", droppedRows=0, **stamp(t))
                            for phase, t in (("hostWaitBegin", D("100.00001")), ("hostWaitEnd", D("100.00002")))]
    _, report = analyze(out, "host-wait-producer", event_data)
    checks["hostWaitProducerMappedToLogicalSubmission"] = any(e["kind"] == "host-wait-producer" and e["before"].endswith(":1") and e["after"].endswith(":2") for e in report["frames"][-1]["dependencyEdges"])
    requested = fixture(work_ms=10, gpu_ms=2, interval_ms=D(30))
    for row in requested["native"]:
        if row.get("phase") == "commit":
            row["phase"] = "commitRequested"
            row["timeCA"] -= D(".005")
            row["timeCF"] -= D(".005")
            row["committedCA"] = 0
    _, report = analyze(out, "actual-commit-vs-requested", requested)
    current_cb = next(c for c in report["frames"][-1]["GPU"]["commandBuffers"] if c["nativeCB"].endswith(":2"))
    checks["commitRequestedNeverUsedAsActualCommit"] = current_cb["commitToGPUStartMs"] == D(".1") and current_cb["commitRequestedToActualCommitMs"] == 5
    checks["actualCommitDoesNotRequireSynchronousCommitPhase"] = not any(x["code"] == "native-phases-missing" for x in report["coverage"]["issues"])
    no_actual = deepcopy(requested)
    for row in no_actual["native"]:
        if row.get("nativeCB") == 2:
            row["committedCA"] = 0
    _, report = analyze(out, "requested-without-actual-commit", no_actual)
    current_cb = next(c for c in report["frames"][-1]["GPU"]["commandBuffers"] if c["nativeCB"].endswith(":2"))
    checks["missingActualCommitExplicitNoRequestedFallback"] = current_cb["committedCA"] is None and current_cb["commitToGPUStartMs"] is None and any("actual committedCA>0" in x.get("phases", []) for x in report["coverage"]["issues"])
    outside_arm = deepcopy(event_data)
    for row in outside_arm["native"]:
        if row.get("phase") == "hostWaitEnd":
            row["outsideArm"] = True
    _, report = analyze(out, "host-wait-outside-arm", outside_arm)
    checks["hostWaitOutsideArmRetainsBeginSession"] = report["frames"][-1]["hostWaits"]["records"][0]["session"] == SESSION and report["frames"][-1]["hostWaits"]["records"][0]["endOutsideArm"] is True
    checks["criticalPathCoverageExplicit"] = "observedCoverageComplete" in report["frames"][-1]["GPU"]["criticalPath"] and report["frames"][-1]["GPU"]["criticalPath"]["observedCoverageComplete"] is False
    # An old history window must not swamp current frame/window CPU totals.
    historical = deepcopy(data["cpu"])
    historical.update(time=D(10) + OFFSET, windowStartNS=9000000000, windowEndNS=10000000000, unixTimeNS=17)
    historical["rows"][0]["selfWallNS"] = 999000000000
    historical_path = out / "normal" / f"cpu-history-old-{PID}.jsonl"
    write(historical_path, [historical], True)
    old_a = M.Analyzer(target_pid=PID)
    old_a.load_system(out / "normal/system")
    old_a.load_native([out / "normal" / f"stutter-native-{PID}.jsonl"])
    old_a.load_cpu([historical_path, out / "normal" / f"cpu-stutter-{PID}.jsonl"])
    report = old_a.report()
    checks["historicalCPUWindowsExcludedWithoutProrating"] = report["CPUHistoricalReportWindowsSkipped"] == 1 and report["CPUPhaseRanking"][0]["selfWallNS"] == 1000000
    checks["oldQueuePrefixCPUNotChargedToNewFrame"] = all(x["submission"] == 2 for x in normal["frames"][-1]["CPU"]["submissionRecords"]) and not any(x["presentFrame"] == 1002 and x["code"] == "frame-cpu-submissions-unattributed" for x in normal["coverage"]["issues"] if "presentFrame" in x)
    _, report = analyze(out, "input-cap", fixture(), max_rows=8)
    checks["analyzerInputCapExplicit"] = "input-row-cap" in report["coverage"]["issueCounts"]
    base = 9007199254740993
    gpu_raw = 18014398509481987
    pair = dict(available=True,
                before=dict(cpuRaw=base, gpuRaw=gpu_raw, cpuDomain="mach-absolute-ticks",
                            hostBeforeMachTicks=base - 10, hostAfterMachTicks=base + 10,
                            hostBeforeCA=D("999.999999990"), hostAfterCA=D("1000.000000010")),
                after=dict(cpuRaw=base + 1000, gpuRaw=gpu_raw + 1000, cpuDomain="mach-absolute-ticks",
                           hostBeforeMachTicks=base + 990, hostAfterMachTicks=base + 1010,
                           hostBeforeCA=D("1000.000000990"), hostAfterCA=D("1000.000001010")))
    conversion, error = M.convert_gpu_clock(gpu_raw + 1, pair, dict(numer=1, denom=1))
    checks["largeIntegerSubNanosecondClockPrecision"] = error is None and conversion["timeCA"] == D("1000.000000001")
    checks["clockBracketUncertaintyExplicit"] = conversion["hostBracketUncertaintyNS"] == 20 and conversion["hardwareClockAccuracyGuaranteed"] is False
    checks["missingTimebaseNeverGuessed"] = M.convert_gpu_clock(gpu_raw + 1, pair, None)[1] == "explicit-mach-timebase-unavailable"
    checks["outsideClockBracketNeverExtrapolated"] = M.convert_gpu_clock(gpu_raw - 1, pair, dict(numer=1, denom=1))[1] == "sample-outside-calibration-bracket"
    bad_pair = deepcopy(pair)
    bad_pair["after"]["cpuDomain"] = "nanoseconds"
    checks["mismatchedClockDomainRejected"] = M.convert_gpu_clock(gpu_raw + 1, bad_pair, dict(numer=1, denom=1))[1] == "cpu-clock-domain-unrecognized-or-mismatched"
    gpu_dir = out / "gpu-clock-sidecar"
    gpu_dir.mkdir()
    sidecar = gpu_dir / f"gpu-counter-clock-sessions-{PID}.jsonl"
    artifact = gpu_dir / "snapshot.json"
    write(sidecar, [dict(type="gpuCounterSessionClock", sessionID=1, armSignature=SESSION,
                         closed=True, physicalDeviceConflict=False, clockCalibration=pair)], True)
    write(artifact, dict(enabled=True, nativeCompleted=True, CPUResolveSucceeded=True,
                         invalidSamples=0, truncated=False, coverage=dict(sessionID=1, nativeCBID=2,
                         logicalSubmissionID=2, nativeSplitIndex=1, presentFrameID=1002),
                         captureSession=dict(armSignature=SESSION, sessionID=1),
                         samples=[dict(index=0, kind="dispatch", label="test", valid=True, timestamp=gpu_raw + 1),
                                  dict(index=1, kind="dispatch-end", label="test", valid=True, timestamp=gpu_raw + 10)]))
    gpu_a = M.Analyzer(target_pid=PID)
    gpu_a.timebase = dict(numer=1, denom=1)
    gpu_a.load_gpu([artifact], [sidecar])
    gpu_result = gpu_a.gpu_report()
    M.dump(gpu_dir / "analysis.json", gpu_result)
    checks["GPUCounterSidecarJoinAndBoundaryNonexclusive"] = len(gpu_result["artifacts"][0]["boundaryIntervals"]) == 1 and gpu_result["artifacts"][0]["boundaryIntervals"][0]["exclusiveShaderDuration"] is False
    checks["unmatchedGPUNativeSessionExplicitlyIncomplete"] = all(k in gpu_a.issue_counts for k in ("gpu-native-session-unmatched", "gpu-native-command-buffer-unmatched"))
    suffix_artifact = gpu_dir / "snapshot-unsampled-suffix.json"
    suffix = json.loads(artifact.read_text())
    suffix["mayHaveUnsampledSuffix"] = True
    suffix["coverage"]["mayHaveUnsampledSuffix"] = True
    write(suffix_artifact, suffix)
    suffix_a = M.Analyzer(target_pid=PID)
    suffix_a.timebase = dict(numer=1, denom=1)
    suffix_a.load_gpu([suffix_artifact], [sidecar])
    suffix_report = suffix_a.gpu_report()
    checks["unsampledSuffixAtTopAndCoverageExplicitlyIncomplete"] = suffix_a.issue_counts["gpu-may-have-unsampled-suffix"] == 2 and suffix_report["artifacts"][0]["mayHaveUnsampledSuffix"] is True
    wrapper_path = gpu_dir / f"trace-gpu-timestamps-{PID}-1.json"
    wrapper_snapshot = json.loads(artifact.read_text())
    wrapper_snapshot["coverage"].update(createdMonotonicNS=79170103100796, nativeCommitMonotonicNS=79170109549159)
    wrapper_snapshot["captureSession"].update(startedMonotonicNS=79170103000000, deadlineMonotonicNS=79175103000000)
    wrapper_snapshot["samples"][0]["encodedMonotonicNS"] = 79170107501680
    wrapper_snapshot["samples"][1]["encodedMonotonicNS"] = 79170107763225
    write(wrapper_path, dict(gpuTimestamps=wrapper_snapshot, nativeCBID=2, logicalSubmissionID=2))
    wrapper_a = M.Analyzer()
    wrapper_a.timebase = dict(numer=1, denom=1)
    wrapper_a.load_gpu([wrapper_path], [sidecar])
    wrapper_result = wrapper_a.gpu_report()
    M.dump(gpu_dir / "actual-wrapper-analysis.json", wrapper_result)
    checks["actualNativeGpuTimestampsWrapperParsed"] = len(wrapper_result["artifacts"]) == 1 and not wrapper_result["unparsed"] and wrapper_result["artifacts"][0]["pid"] == PID and len(wrapper_result["artifacts"][0]["boundaryIntervals"]) == 1
    raw_clock = wrapper_result["artifacts"][0]["counterHostClockRaw"]
    checks["counterSteadyMonotonicRetainedRawNeverMappedToMach"] = raw_clock["createdMonotonicNS"] == 79170103100796 and raw_clock["nativeCommitMonotonicNS"] == 79170109549159 and raw_clock["samples"][0]["encodedMonotonicNS"] == 79170107501680 and raw_clock["comparableToCPUTraceMonotonicNS"] is False and raw_clock["mappedToCPUTrace"] is False
    checks["counterRawGPUMappedOnlyThroughOwnPairedClock"] = wrapper_result["artifacts"][0]["boundaryIntervals"][0]["startCA"] == D("1000.000000001")
    checks["CPUGPUIntervalsNotAdded"] = "exclusiveFrameCost" in normal["frames"][-1]["observedContributors"][0] and not normal["frames"][-1]["observedContributors"][0]["exclusiveFrameCost"]
    metrics["normalFrameIntervalMs"] = frame["intervalMs"]
    metrics["cpuBoundTop"] = cpu["frames"][-1]["observedContributors"][0]
    metrics["gpuBoundTop"] = gpu["frames"][-1]["observedContributors"][0]
    metrics["waitBoundTop"] = wait["frames"][-1]["observedContributors"][0]
    metrics["precisionConvertedCAExact"] = conversion["timeCAExactDecimal"]
    result = dict(passed=all(checks.values()), checks=checks, metrics=metrics,
                  syntheticOnly=True, actualGameTested=False, actualGPUWorkExecuted=False,
                  gameOrWineLaunched=False, productionSourceModified=False,
                  rawInputsPreserved=True)
    M.dump(out / "self-test.json", result)
    return result
