#!/usr/bin/env python3
"""Read-only correlation of the bounded MVK stutter captures, never a game runner.

Only explicitly named JSON/JSONL inputs and the capture harness's known files are
read. No process, Wine, GPU, cache, debugger, or authentication access is used.
An observed contributor is not proof of an exclusive shader cost or root cause.
Use --self-test --output NEW_DIRECTORY for CPU-only synthetic qualification.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict, deque
from decimal import Decimal, localcontext
import hashlib
import heapq
import json
from pathlib import Path
import re
import time
from capture_foreground_stutter import foreground_intervals

ROOT = Path(__file__).resolve().parents[1]
D = Decimal
NS = D(1000000000)
CF_UNIX_OFFSET = D(978307200)
MAX_INPUT_BYTES = 512 * 1024 * 1024
MAX_INPUT_ROWS = 400000


def dec(value, default=None):
    if value is None:
        return default
    try:
        out = value if isinstance(value, D) else D(str(value))
        return out if out.is_finite() else default
    except (ValueError, TypeError, ArithmeticError):
        return default


def number(value, default=0):
    out = dec(value)
    return float(out) if out is not None else default


def positive(value):
    out = dec(value)
    return out if out is not None and out > 0 else None


def integer(value, default=0):
    try:
        return int(value) if value is not None else default
    except (ValueError, TypeError, ArithmeticError):
        return default


def json_ready(obj):
    if isinstance(obj, D):
        return float(obj)
    if isinstance(obj, dict):
        return {str(k): json_ready(v) for k, v in obj.items()}
    if isinstance(obj, (tuple, list)):
        return [json_ready(v) for v in obj]
    return obj


def dump(path, obj):
    path.write_text(json.dumps(json_ready(obj), indent=2, allow_nan=False) + "\n")


def interval_union(intervals):
    pairs = sorted((a, b) for a, b in intervals if a is not None and b is not None and b >= a)
    total = D(0)
    start = end = None
    for a, b in pairs:
        if start is None:
            start, end = a, b
        elif a <= end:
            end = max(end, b)
        else:
            total += end - start
            start, end = a, b
    return total + (end - start if start is not None else D(0))


def overlap(a, b, c, d):
    return a is not None and b is not None and c is not None and d is not None and b >= c and d >= a


def clip(a, b, lo, hi):
    if None in (a, b, lo, hi) or b < a:
        return None
    start, end = max(a, lo), min(b, hi)
    return (start, end) if end >= start else None


def ref(row):
    return {k[1:]: row[k] for k in ("_source", "_line") if k in row}


def true_field_paths(obj, field, prefix=""):
    """Compatibility with bounded GPU snapshots whose suffix flag moved levels."""
    if isinstance(obj, dict):
        for key, value in obj.items():
            path = prefix + "/" + str(key)
            if key == field and value is True:
                yield path
            yield from true_field_paths(value, field, path)
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            yield from true_field_paths(value, field, prefix + "/" + str(index))


def cumulative_counter_windows(rows, fields, pid_key):
    """Run counters never reset on arm; initial nonzero is unknown prefix."""
    groups=defaultdict(list)
    for row in rows:groups[(row.get(pid_key),row.get('runID'))].append(row)
    result=[]
    for (pid,run),values in groups.items():
        first,last=values[0],values[-1]
        delta={k:integer(last.get(k))-integer(first.get(k)) for k in fields}
        result.append(dict(pid=pid,runID=run,sourceBegin=ref(first),sourceEnd=ref(last),snapshots=len(values),
            observedDelta={k:v for k,v in delta.items() if v>0},nonmonotonic=[k for k,v in delta.items() if v<0],
            alreadyNonzeroAtFirstSnapshot={k:integer(first.get(k)) for k in fields if integer(first.get(k))},
            meaning='Run-cumulative counters; positive deltas apply between observed metadata snapshots. Initial nonzero counters are an unknown prefix, never charged to every later arm.'))
    return result


def cumulative_counter_sessions(rows, fields, pid_key):
    previous={};sessions={}
    for row in rows:
        run=(row.get(pid_key),row.get('runID'));key=run+(row.get('session'),)
        dest=sessions.setdefault(key,dict(pid=run[0],runID=run[1],session=key[-1],snapshots=0,withinSessionIncreases=Counter(),boundaryUnassignedIncreases=Counter(),initialPrefixUnknown={},nonmonotonic=[]))
        dest['snapshots']+=1;before=previous.get(run)
        if before is None:dest['initialPrefixUnknown']={k:integer(row.get(k)) for k in fields if integer(row.get(k))}
        else:
            for field in fields:
                change=integer(row.get(field))-integer(before.get(field))
                if change>0:dest['withinSessionIncreases' if before.get('session')==row.get('session') else 'boundaryUnassignedIncreases'][field]+=change
                elif change<0:dest['nonmonotonic'].append(field)
        previous[run]=row
    return [dict(v,withinSessionIncreases=dict(v['withinSessionIncreases']),boundaryUnassignedIncreases=dict(v['boundaryUnassignedIncreases']),
                 statuses=['observed']+(['capped'] if v['withinSessionIncreases'] else [])+(['unjoinable'] if v['boundaryUnassignedIncreases'] or v['initialPrefixUnknown'] or v['nonmonotonic'] else []),
                 meaning='Metadata intervals grouped by observed arm session, not counter resets. Boundary increases/late tails are not charged exclusively to either user stage.') for v in sessions.values()]


class Analyzer:
    def __init__(self, *, target_pid=None, freshness_seconds=15, target_fps=30,
                 max_bytes=MAX_INPUT_BYTES, max_rows=MAX_INPUT_ROWS):
        self.pid = target_pid
        self.freshness = D(str(freshness_seconds))
        self.target_fps = D(str(target_fps))
        self.max_bytes, self.max_rows = max_bytes, max_rows
        self.bytes_read = self.rows_read = 0
        self.sources = []
        self.issues = []
        self.issue_counts = Counter()
        self._issue_keys = set()
        self.native_rows, self.cpu_reports, self.gpu_artifacts, self.gpu_clocks = [], [], [], []
        self.system_rows, self.foreground = [], []
        self.system_metadata, self.system_summary = {}, {}
        self.calibrations = defaultdict(list)
        self.cbs, self.edges, self.host_waits = {}, [], []
        self.presents, self.submission_rows = [], []
        self.cpu_details, self.cpu_aggregate = [], []
        self.system_interval = None
        self.reference_cf = None
        self.timebase = None
        self.cpu_historical_skipped = 0
        self.event_alias_counts = Counter()
        self.cpu_report_provenance = []
        self.forensic_rows, self.forensic_current, self.forensic_copy_index = [], [], []
        self.guest_rows, self.guest_current, self.guest_copy_index, self.cpu_fine_sampling = [], [], [], []
        self.cpu_spans=[];self.cpu_span_count=0
        self.cpu_status=[];self.cpu_copy_index=[]
        self.requested_windows=[]
        self.memory_events=[];self.memory_snapshots=[];self.memory_unassigned=[]

    def issue(self, code, *, scope="global", severity="incomplete", **details):
        record = dict(code=code, scope=scope, severity=severity, **details)
        key = json.dumps(json_ready(record), sort_keys=True)
        if key in self._issue_keys:
            return
        self._issue_keys.add(key)
        self.issue_counts[code] += 1
        if len(self.issues) < 2000:
            self.issues.append(record)

    def read(self, path, kind):
        path = Path(path).resolve()
        source = dict(path=str(path), kind=kind, rows=0, readComplete=False)
        self.sources.append(source)
        try:
            state = path.stat()
            source.update(bytes=state.st_size, mtimeUnixNS=state.st_mtime_ns)
            if state.st_size + self.bytes_read > self.max_bytes:
                self.issue("input-byte-cap", source=str(path), inputBytes=state.st_size, cap=self.max_bytes)
                return []
            raw = path.read_bytes()
            self.bytes_read += len(raw)
            source["sha256"] = hashlib.sha256(raw).hexdigest()
            if len(raw) != state.st_size:
                self.issue("source-mutated-during-read", source=str(path))
            pid = re.search(r"(?:stutter-native|cpu-stutter(?:-current)?|gpu-counter-clock-sessions|trace-gpu-timestamps|forensics(?:-current)?|memory-(?:failures|slow-allocations|current|stats))-(\d+)", path.name)
            source["pidFromName"] = int(pid.group(1)) if pid else None
            rows = []
            if path.suffix == ".jsonl":
                chunks = enumerate(raw.splitlines(), 1)
            else:
                chunks = [(1, raw)]
            for line, chunk in chunks:
                if not chunk.strip():
                    continue
                if self.rows_read >= self.max_rows:
                    self.issue("input-row-cap", source=str(path), cap=self.max_rows)
                    break
                try:
                    item = json.loads(chunk, parse_float=D)
                except (ValueError, UnicodeError) as exc:
                    self.issue("input-json-invalid", source=str(path), line=line, error=type(exc).__name__)
                    continue
                if not isinstance(item, dict):
                    self.issue("input-object-required", source=str(path), line=line)
                    continue
                item.update(_source=str(path), _line=line,
                            _pid=source["pidFromName"] if source["pidFromName"] is not None else self.pid)
                rows.append(item)
                self.rows_read += 1
            source["rows"] = len(rows)
            source["readComplete"] = not any(x.get("source") == str(path) for x in self.issues)
            return rows
        except OSError as exc:
            self.issue("source-unavailable", source=str(path), errno=exc.errno)
            return []

    def load_system(self, directory):
        directory = Path(directory)
        for name, attr in (("metadata.json", "system_metadata"), ("summary.json", "system_summary")):
            rows = self.read(directory / name, "system-" + name)
            if rows:
                setattr(self, attr, rows[0])
        target = self.system_metadata.get("target", {})
        target_pid = target.get("pid")
        if self.pid is not None and target_pid is not None and self.pid != target_pid:
            self.issue("system-target-pid-mismatch", expected=self.pid, observed=target_pid)
        if self.pid is None and target_pid is not None:
            self.pid = integer(target_pid)
        self.timebase = self.system_metadata.get("timebase")
        self.system_rows += self.read(directory / "timeline.jsonl", "system-timeline")
        chunks = sorted(directory.glob('foreground-chunk-*.jsonl'))
        if chunks:
            for chunk in chunks:self.foreground += self.read(chunk, 'foreground')
        elif (directory / "foreground.jsonl").exists():
            self.foreground += self.read(directory / "foreground.jsonl", "foreground")
        clocks = [dec(r.get("clock", {}).get("CFAbsoluteTime")) for r in self.system_rows]
        clocks = [x for x in clocks if x is not None]
        if clocks:
            self.system_interval = (min(clocks), max(clocks))
            self.reference_cf = max(clocks)

    def load_native(self, paths):
        for path in paths:
            self.native_rows += self.read(path, "native-graph")

    def load_cpu(self, paths):
        for path in paths:
            self.cpu_reports += self.read(path, "cpu-report")

    def load_forensics(self, paths=(), current=(), copy_index=()):
        for path in paths:self.forensic_rows += self.read(path, 'forensics')
        for path in current:self.forensic_current += self.read(path, 'forensics-current')
        for path in copy_index:self.forensic_copy_index += self.read(path, 'forensics-copy-index')

    def load_guest(self, paths=(), current=(), copy_index=()):
        for path in paths:self.guest_rows += self.read(path,'guest-d3d12')
        for path in current:self.guest_current += self.read(path,'guest-d3d12-current')
        for path in copy_index:self.guest_copy_index += self.read(path,'guest-d3d12-copy-index')

    def load_memory(self, paths=(), snapshots=()):
        for path in paths:self.memory_events+=self.read(path,'memory-events')
        for path in snapshots:self.memory_snapshots+=self.read(path,'memory-snapshot')

    def load_session(self, directory):
        self.load_system(directory)
        directory=Path(directory)
        if (directory/'segments.jsonl').exists():self.requested_windows+=self.read(directory/'segments.jsonl','requested-diagnostic-windows')
        # Raw action windows are append-only subdirectories. Include retired
        # owner tails across all windows; never join only the newest arm.
        def captured_paths(pattern, summary_key=None):
            found={p.resolve() for p in directory.rglob(pattern)}
            for text in self.system_summary.get(summary_key, []) if summary_key else []:
                path=Path(text).resolve()
                if path.is_relative_to(directory.resolve()):found.add(path)
                else:self.issue('session-raw-reference-outside-capture',source=str(path))
            return sorted(found)
        self.load_cpu(captured_paths('cpu-stutter-current-*-snapshots.jsonl','rawCPUCurrentPaths'))
        for path in captured_paths('cpu-stutter-status-*-snapshots.jsonl'):self.cpu_status+=self.read(path,'cpu-history-status')
        for path in captured_paths('cpu-snapshot-copy-index.jsonl'):self.cpu_copy_index+=self.read(path,'cpu-copy-index')
        self.load_forensics(captured_paths('forensics-*-run-*-generation-*.jsonl','rawForensicsPaths'),
                            current=captured_paths('forensics-current-snapshots.jsonl','rawForensicsCurrentPaths'),
                            copy_index=captured_paths('forensics-copy-index.jsonl'))
        self.load_guest(captured_paths('vkd3d-forensics-*-run-*-generation-*.jsonl','rawGuestForensicsPaths'),
                        current=captured_paths('vkd3d-forensics-current-snapshots.jsonl'),
                        copy_index=captured_paths('vkd3d-forensics-copy-index.jsonl'))
        for text in self.system_summary.get('rawLogReferences', []):
            path=Path(text).resolve()
            if not path.is_relative_to(ROOT/'evidence'):
                self.issue('session-log-reference-outside-owned-evidence', scope='global');continue
            if path.name.startswith('cpu-stutter-'):self.load_cpu([path])
            elif path.name.startswith('stutter-native-'):self.load_native([path])
            elif path.name.startswith('forensics-current-'):self.load_forensics(current=[path])
        profile=self.system_metadata.get('profile')
        if profile and Path(profile).resolve().is_relative_to(ROOT/'evidence'):
            trace=Path(profile)/'msl';minimum=number(self.system_metadata.get('processStartUnixEstimate'),number(self.system_metadata.get('start',{}).get('unixSeconds')))-.2
            # Allocation journals are append-only with independent 128-event
            # caps, not members of the rotating forensics stream. Read their
            # complete records, never the scalar-only polling projection.
            if self.pid:
                low=integer(self.system_metadata.get('processStartMachNS'))
                ticks=[integer(r.get('clock',{}).get('machAbsoluteTicks')) for r in self.system_rows]
                ticks=[t for t in ticks if t]
                tb=self.timebase or {};numer,denom=integer(tb.get('numer')),integer(tb.get('denom'))
                high=max(ticks)*numer//denom if ticks and numer and denom else None
                start_identity=self.system_metadata.get('processStartAbstime')
                for prefix,destination in (('memory-failures',self.memory_events),('memory-slow-allocations',self.memory_events),('memory-current',self.memory_snapshots)):
                    ext='.json' if prefix=='memory-current' else '.jsonl';path=trace/f'{prefix}-{self.pid}{ext}'
                    if not path.is_file():continue
                    if path.stat().st_mtime<minimum:
                        self.issue('memory-source-before-target-start',scope='memory',source=str(path));continue
                    for record in self.read(path,'memory-snapshot' if prefix=='memory-current' else 'memory-events'):
                        begin=integer(record.get('beginMachNS',record.get('monotonicNS')))
                        end=integer(record.get('endMachNS',record.get('monotonicNS')))
                        valid=bool(low and high and low<=begin<=end<=high and start_identity)
                        if not valid:
                            self.memory_unassigned.append(dict(source=ref(record),beginMachNS=begin,endMachNS=end,reason='outside-or-missing-observed-target-lifetime'))
                            continue
                        record['_processStartIdentity']=str(start_identity)
                        record['_targetLifetimeVerified']=True;destination.append(record)
            artifacts=[p for p in trace.glob(f'trace-gpu-timestamps-{self.pid}-*.json') if p.stat().st_mtime>=minimum]
            clocks=[p for p in trace.glob(f'gpu-counter-clock-sessions-{self.pid}*.jsonl') if p.stat().st_mtime>=minimum]
            self.load_gpu(artifacts[:256],clocks[:16])
            guest_dir=self.system_metadata.get('budgets',{}).get('d3d_directory')
            if guest_dir and Path(guest_dir).resolve().is_relative_to(ROOT/'evidence'):
                self.load_guest(current=list(Path(guest_dir).glob('vkd3d-forensics-current-*.json'))[:64])
            if len(artifacts)>256:self.issue('session-gpu-input-file-cap',scope='gpu-counters',count=len(artifacts))

    def load_gpu(self, artifacts=(), clocks=()):
        for path in artifacts:
            self.gpu_artifacts += self.read(path, "gpu-artifact")
        for path in clocks:
            self.gpu_clocks += self.read(path, "gpu-clock-sidecar")

    def _pid_for(self, row):
        pid = row.get("_pid")
        if pid is None:
            self.issue("source-pid-unavailable", source=row.get("_source"))
            return "unknown:" + str(row.get("_source"))
        if self.pid is not None and pid != self.pid:
            self.issue("input-pid-mismatch", source=row.get("_source"), expected=self.pid, observed=pid)
        return pid

    def calibration(self, pid, session=None):
        if session is not None and self.calibrations.get((pid, session)):
            return self.calibrations[(pid, session)][0]
        all_rows = [r for (p, _), rows in self.calibrations.items() if p == pid for r in rows]
        return all_rows[0] if all_rows else None

    def mono_to_ca(self, ns, pid, session=None):
        c = self.calibration(pid, session)
        value = dec(ns)
        if c is None or value is None:
            return None
        return value / NS + dec(c["timeCA"]) - D(integer(c["monotonicNS"])) / NS

    def ca_to_cf(self, ca, pid, session=None):
        c = self.calibration(pid, session)
        return None if c is None or ca is None else ca + dec(c["timeCF"]) - dec(c["timeCA"])

    def _clock_report(self):
        rows = []
        for (pid, session), calibrations in sorted(self.calibrations.items(), key=lambda pair: str(pair[0])):
            offsets_cf = [dec(c["timeCF"]) - dec(c["timeCA"]) for c in calibrations]
            offsets_mono = [dec(c["timeCA"]) - D(integer(c["monotonicNS"])) / NS for c in calibrations]
            row = dict(pid=pid, session=session, anchors=len(calibrations),
                       CFMinusCASecondsExact=str(offsets_cf[0]),
                       CAMinusMonotonicSecondsExact=str(offsets_mono[0]),
                       observedCFOffsetSpreadNS=(max(offsets_cf) - min(offsets_cf)) * NS,
                       observedMonotonicOffsetSpreadNS=(max(offsets_mono) - min(offsets_mono)) * NS,
                       calibrationReadBracketAvailable=False,
                       accuracyBoundNS=None, nativeCAIsPublicHostClock=True,
                       limits="CF/CA/monotonic reads are sequential, not bracketed; offset spread is not an accuracy guarantee.")
            rows.append(row)
            if self.reference_cf is not None:
                age = self.reference_cf - max(dec(c["timeCF"]) for c in calibrations)
                row["initialAnchorAgeAtReferenceSeconds"] = age
                latest = max((dec(r.get("timeCF"), D(0)) for r in self.native_rows
                              if r.get("_pid", self.pid) == pid and integer(r.get("session")) == session), default=D(0))
                row["lastSessionRecordAgeAtReferenceSeconds"] = self.reference_cf - latest
                # The arm intentionally lasts 30s with one initial anchor. A
                # 20s-old anchor is not a stale writer if its rows remain fresh.
                if self.reference_cf - latest > self.freshness:
                    self.issue("native-clock-anchor-stale", scope="clock", pid=pid, session=session,
                               ageSeconds=self.reference_cf - latest)
        return rows

    def build_native(self):
        seen = set()
        event_rows = []
        for row in self.native_rows:
            pid = self._pid_for(row)
            kind, session = row.get("type"), integer(row.get("session"))
            dedup = (pid, json.dumps(json_ready({k: v for k, v in row.items() if not k.startswith("_")}), sort_keys=True))
            if dedup in seen:
                continue
            seen.add(dedup)
            if integer(row.get("droppedRows")):
                self.issue("native-dropped-rows", scope="native", pid=pid, session=session,
                           droppedRowsLowerBound=integer(row["droppedRows"]))
            if kind == "clockCalibration":
                if all(dec(row.get(k)) is not None for k in ("timeCF", "timeCA", "monotonicNS")):
                    self.calibrations[(pid, session)].append(row)
                else:
                    self.issue("native-calibration-invalid", scope="clock", **ref(row))
            elif kind == "nativeCB":
                cbid = integer(row.get("nativeCB"))
                if not cbid:
                    self.issue("native-cb-id-missing", scope="native", **ref(row))
                    continue
                key = (pid, cbid)
                cb = self.cbs.setdefault(key, dict(pid=pid, nativeCB=cbid, phases={},
                                                 phaseRefs={}, sessions=set(), partialPrefix=False))
                cb["sessions"].add(session)
                phase = row.get("phase", "unknown")
                stamp = dec(row.get("timeCA"))
                if stamp is not None and (phase not in cb["phases"] or stamp < cb["phases"][phase]):
                    cb["phases"][phase] = stamp
                    cb["phaseRefs"][phase] = ref(row)
                for name in ("logicalSubmit", "presentFrame", "createdCA", "committedCA", "scheduledCA", "gpuStartCA", "gpuEndCA"):
                    if positive(row.get(name)) is not None:
                        cb[name] = row[name]
                for name in ("family", "index", "split"):
                    if name in row and (phase == "associated" or name not in cb):
                        cb[name] = integer(row[name])
                if phase == "completed" or "nativeStatus" not in cb:
                    cb["nativeStatus"] = integer(row.get("nativeStatus"))
                counter_fields = ("counterSession", "counterSkip", "counterAllocated", "counterMidCB", "nativeIntervalOnly", "counterReadbackExpected")
                if any(name in row for name in counter_fields) and (phase == "completed" or "counterNativeObservation" not in cb):
                    cb["counterNativeObservation"] = {name: row.get(name) for name in counter_fields}
                    cb["counterNativeObservation"]["source"] = ref(row)
                    cb["counterNativeObservation"]["phase"] = phase
                cb["partialPrefix"] |= bool(row.get("partialPrefix"))
                cb["counterMidCB"] = cb.get("counterMidCB", False) or bool(row.get("counterMidCB"))
            elif kind == "event":
                aliases = {"signal": "signal-encoded", "wait": "wait-encoded"}
                if row.get("phase") in aliases:
                    self.event_alias_counts[row["phase"]] += 1
                    row = dict(row, phase=aliases[row["phase"]], _originalEventPhase=row["phase"])
                event_rows.append((pid, row))
            elif kind == "submission":
                self.submission_rows.append(dict(row, _pid=pid))
            elif kind == "present":
                self.presents.append(dict(row, _pid=pid))
            elif kind == "coverageLoss":
                self.issue("native-coverage-loss", scope="native", pid=pid, session=session,
                           reason=row.get("reason"), droppedRowsLowerBound=integer(row.get("droppedRowsLowerBound")), **ref(row))
            else:
                self.issue("native-row-type-unparsed", scope="native", type=kind, **ref(row))
        if self.reference_cf is None:
            values = [dec(r.get("timeCF")) for r in self.native_rows]
            values = [x for x in values if x is not None]
            self.reference_cf = max(values) if values else None
        for key, cb in self.cbs.items():
            cb["key"] = str(cb["pid"]) + ":" + str(cb["nativeCB"])
            cb["queue"] = (cb["pid"], cb.get("family"), cb.get("index"))
            for phase, field in (("created", "createdCA"), ("scheduled", "scheduledCA")):
                if field not in cb and phase in cb["phases"]:
                    cb[field] = cb["phases"][phase]
            if cb["partialPrefix"]:
                self.issue("native-partial-prefix", scope="native", nativeCB=cb["key"])
            missing = [p for p in ("created", "enqueue", "scheduled", "completed") if p not in cb["phases"]]
            if positive(cb.get("committedCA")) is None:
                # commitRequested is recorded before diagnostic I/O. Only the
                # no-I/O actual commit marker, later published in callbacks, can
                # establish the true commit-to-GPU-start interval.
                missing.append("actual committedCA>0")
            if missing:
                self.issue("native-phases-missing", scope="native", nativeCB=cb["key"], phases=missing)
            if "completed" not in cb["phases"]:
                self.issue("native-completion-missing", scope="native", nativeCB=cb["key"])
            elif cb.get("nativeStatus") != 4:
                self.issue("native-completion-error", scope="native", nativeCB=cb["key"], status=cb.get("nativeStatus"))
            if not cb.get("logicalSubmit"):
                self.issue("native-logical-submission-missing", scope="native", nativeCB=cb["key"])
            start, end = positive(cb.get("gpuStartCA")), positive(cb.get("gpuEndCA"))
            if start is None or end is None:
                self.issue("native-gpu-interval-missing", scope="native", nativeCB=cb["key"])
            elif end < start:
                self.issue("native-gpu-interval-invalid", scope="clock", nativeCB=cb["key"])
            if self.calibration(cb["pid"], next(iter(cb["sessions"]), None)) is None:
                self.issue("native-clock-calibration-missing", scope="clock", pid=cb["pid"])
        self._queue_edges()
        self._event_edges(event_rows)
        self._check_dag()

    def _edge(self, before, after, kind, **details):
        if before == after:
            return
        self.edges.append(dict(before=before, after=after, kind=kind, **details))

    def _queue_edges(self):
        queues = defaultdict(list)
        for key, cb in self.cbs.items():
            queues[cb["queue"]].append((key, cb))
        for queue, cbs in queues.items():
            use_enqueue = all("enqueue" in cb["phases"] for _, cb in cbs)
            field = "enqueue" if use_enqueue else "committedCA"
            usable = [(key, cb) for key, cb in cbs if ("enqueue" in cb["phases"] if use_enqueue else positive(cb.get("committedCA")) is not None)]
            if not use_enqueue:
                self.issue("queue-order-commit-fallback", scope="native", queue=list(queue),
                           limits="Missing enqueue order; commit call timestamps do not prove exact concurrent enqueue order.")
            def order_time(cb):
                return cb["phases"]["enqueue"] if use_enqueue else dec(cb["committedCA"])
            usable.sort(key=lambda pair: (order_time(pair[1]), pair[0][1]))
            for (a, x), (b, y) in zip(usable, usable[1:]):
                if order_time(x) == order_time(y):
                    self.issue("queue-order-timestamp-tie", scope="native", queue=list(queue))
                self._edge(a, b, "queue-order", evidence=field)

    def _event_edges(self, rows):
        signals = defaultdict(list)
        host_open = defaultdict(deque)
        for pid, row in rows:
            if row.get("phase") == "signal-encoded":
                signals[(pid, integer(row.get("event")))].append(row)
        for pid, row in sorted(rows, key=lambda pair: dec(pair[1].get("timeCA"), D(0))):
            phase = row.get("phase")
            key = (pid, integer(row.get("event")), integer(row.get("requested")), integer(row.get("logicalSubmit")), integer(row.get("session")))
            if phase == "hostWaitBegin":
                host_open[key].append(row)
            elif phase == "hostWaitEnd":
                if not host_open[key]:
                    self.issue("host-wait-begin-missing", scope="wait", event=key[1], logicalSubmit=key[3], **ref(row))
                    continue
                begin = host_open[key].popleft()
                a, b = dec(begin.get("timeCA")), dec(row.get("timeCA"))
                duration = b - a if None not in (a, b) and b >= a else None
                self.host_waits.append(dict(pid=pid, event=key[1], requested=key[2], logicalSubmit=key[3],
                                            session=key[4], beginOutsideArm=bool(begin.get("outsideArm")),
                                            endOutsideArm=bool(row.get("outsideArm")),
                                            startCA=a, endCA=b, durationSeconds=duration,
                                            satisfied=bool(row.get("satisfied")), begin=ref(begin), end=ref(row)))
                if duration is None or not row.get("satisfied"):
                    self.issue("host-wait-unsatisfied-or-invalid", scope="wait", event=key[1], logicalSubmit=key[3])
            elif phase == "wait-encoded":
                self._resolve_wait(pid, row, signals)
            elif phase not in ("signal-encoded", "completion-observed"):
                self.issue("event-phase-unparsed", scope="wait", phase=phase, **ref(row))
        for key, pending in host_open.items():
            for row in pending:
                self.issue("host-wait-end-missing", scope="wait", pid=key[0], event=key[1], logicalSubmit=key[3], **ref(row))
        for wait in self.host_waits:
            candidates = []
            for signal in signals.get((wait["pid"], wait["event"]), []):
                producer = (wait["pid"], integer(signal.get("nativeCB")))
                cb = self.cbs.get(producer)
                end = positive(cb.get("gpuEndCA")) if cb else None
                if (integer(signal.get("requested")) >= wait["requested"] and end is not None
                        and wait["endCA"] is not None and end <= wait["endCA"]):
                    candidates.append((end, producer, signal))
            if not candidates:
                self.issue("external-or-missing-host-wait-producer", scope="wait", pid=wait["pid"],
                           event=wait["event"], requested=wait["requested"], logicalSubmit=wait["logicalSubmit"])
                continue
            _, producer, signal = min(candidates, key=lambda x: (x[0], x[1][1]))
            wait["producerNativeCB"] = self.cbs[producer]["key"]
            wait["producerSignalValue"] = integer(signal.get("requested"))
            targets = [(k, cb) for k, cb in self.cbs.items() if cb["pid"] == wait["pid"]
                       and integer(cb.get("logicalSubmit")) == wait["logicalSubmit"]
                       and positive(cb.get("committedCA")) is not None
                       and wait["endCA"] is not None and positive(cb["committedCA"]) >= wait["endCA"]]
            for target, _ in targets:
                self._edge(producer, target, "host-wait-producer", event=wait["event"], requested=wait["requested"],
                           producerSignalValue=wait["producerSignalValue"], evidence="completed-capable-producer-before-host-wait-end")

    def _resolve_wait(self, pid, row, signals):
        event, requested = integer(row.get("event")), integer(row.get("requested"))
        consumer = (pid, integer(row.get("nativeCB")))
        consumer_cb = self.cbs.get(consumer)
        if consumer_cb is None:
            self.issue("event-consumer-missing", scope="wait", pid=pid, nativeCB=consumer[1], event=event, **ref(row))
            return
        consumer_start = positive(consumer_cb.get("gpuStartCA"))
        wait_ca = dec(row.get("timeCA"))
        candidates, proven = [], []
        for signal in signals.get((pid, event), []):
            if integer(signal.get("requested")) < requested:
                continue
            producer = (pid, integer(signal.get("nativeCB")))
            cb = self.cbs.get(producer)
            if cb is None:
                continue
            end = positive(cb.get("gpuEndCA"))
            candidates.append((producer, signal))
            # A completion before consumer execution proves this producer was capable,
            # not that the entire CB's interval was an exclusive semaphore stall.
            limit = wait_ca if integer(row.get("observed")) >= requested else consumer_start
            if end is not None and limit is not None and end <= limit:
                proven.append((end, producer, signal))
        if proven:
            _, producer, signal = min(proven, key=lambda x: (x[0], x[1][1]))
            self._edge(producer, consumer, "event-value", event=event, requested=requested,
                       producerSignalValue=integer(signal.get("requested")), evidence="completed-capable-producer",
                       wait=ref(row), signal=ref(signal), alreadySatisfiedWhenEncoded=integer(row.get("observed")) >= requested)
        elif len(candidates) == 1:
            producer, signal = candidates[0]
            self._edge(producer, consumer, "event-value-candidate", event=event, requested=requested,
                       producerSignalValue=integer(signal.get("requested")), wait=ref(row), signal=ref(signal))
            self.issue("event-producer-order-unproven", scope="wait", event=event, requested=requested,
                       consumer=consumer_cb["key"])
        else:
            self.issue("external-or-ambiguous-event-producer", scope="wait", event=event, requested=requested,
                       observed=integer(row.get("observed")), consumer=consumer_cb["key"], candidates=len(candidates),
                       alreadySatisfiedWhenEncoded=integer(row.get("observed")) >= requested)

    def _check_dag(self):
        incoming = Counter()
        unique = set()
        cleaned = []
        for e in self.edges:
            k = (e["before"], e["after"], e["kind"], e.get("event"), e.get("requested"))
            if k not in unique:
                unique.add(k)
                cleaned.append(e)
        self.edges = cleaned
        adjacency = defaultdict(set)
        for e in self.edges:
            adjacency[e["before"]].add(e["after"])
        for neighbors in adjacency.values():
            incoming.update(neighbors)
        ready = deque(k for k in self.cbs if not incoming[k])
        order = []
        while ready:
            k = ready.popleft()
            order.append(k)
            for neighbor in adjacency[k]:
                incoming[neighbor] -= 1
                if not incoming[neighbor]:
                    ready.append(neighbor)
        self.topological = order
        if len(order) != len(self.cbs):
            self.issue("dependency-cycle-or-order-conflict", scope="native", nodesNotOrdered=len(self.cbs) - len(order))

    def build_cpu(self):
        if not self.cpu_reports:
            self.issue("cpu-reports-unavailable", scope="cpu")
            return
        seen = set()
        for report in self.cpu_reports:
            pid = self._pid_for(report)
            if report.get("coverageUnavailable"):
                self.issue("cpu-coverage-unavailable", scope="cpu", reason=report.get("reason"), **ref(report))
                continue
            key = (pid, report.get("windowStartNS"), report.get("windowEndNS"), report.get("unixTimeNS"))
            if key in seen:
                continue
            seen.add(key)
            if integer(report.get("schema")) != 1:
                self.issue("cpu-schema-unparsed", scope="cpu", schema=report.get("schema"), **ref(report))
                continue
            # A history contains many older windows. Do not let an old, large
            # CPU total dominate a new capture, and never fractionally slice a
            # completion-assigned aggregate into the requested interval.
            if self.system_interval is not None:
                start_ca = self.mono_to_ca(report.get("windowStartNS"), pid)
                end_ca = self.mono_to_ca(report.get("windowEndNS"), pid)
                start_cf, end_cf = self.ca_to_cf(start_ca, pid), self.ca_to_cf(end_ca, pid)
                if None not in (start_cf, end_cf) and not overlap(start_cf, end_cf, *self.system_interval):
                    self.cpu_historical_skipped += 1
                    continue
            if not report.get("captureEnabled"):
                self.issue("cpu-instrumentation-disabled", scope="cpu", **ref(report))
            if not report.get("detailedEnabled"):
                self.issue("cpu-detail-disabled", scope="cpu", **ref(report))
            self.cpu_report_provenance.append(dict(report=ref(report), pid=pid,
                detailDomains=report.get("detailDomains"), detailedTotalCellBudget=report.get("detailedTotalCellBudget"),
                detailedOpenOverflowContexts=report.get("detailedOpenOverflowContexts"),
                meaning="Domain/submission detail may aggregate multiple threads; preserve first/last/mixed thread provenance."))
            for name in ("slowSpansDropped", "invalidIDs", "badNesting", "depthOverflow", "publicationFailures",
                         "detailedOverflowEvents", "detailedUnattributedEvents", "detailedUnattributedSelfNS", "detailedUnpreparedEvents",
                         "diagnosticAllocationDrops", "diagnosticSuppressedEvents", "diagnosticUnavailableThreads", "detailedThreadBudgetDropEvents"):
                if integer(report.get(name)):
                    self.issue("cpu-" + name, scope="cpu", count=integer(report[name]), **ref(report))
            for name in ("aggregateCoverageIncomplete", "detailedCoverageIncomplete"):
                if report.get(name):
                    self.issue("cpu-" + name, scope="cpu", **ref(report))
            when = dec(report.get("time"))
            if when is not None and self.reference_cf is not None and self.reference_cf - when > self.freshness:
                self.issue("cpu-report-stale", scope="cpu", ageSeconds=self.reference_cf - when, **ref(report))
            if self.system_interval is not None and when is not None and when < self.system_interval[0] - self.freshness:
                self.issue("cpu-outside-system-capture", scope="cpu", **ref(report))
            sampling={(integer(x.get('domain')),integer(x.get('stage'))):x for x in report.get('fineScopeSampling',[])}
            for sample in sampling.values():self.cpu_fine_sampling.append(dict(report=ref(report),**sample,fineScopeTimingsSampled=report.get('fineScopeTimingsSampled'),
                extrapolated=False,meaning='Offered is counted at scope begin; timing count/NS are completed measured samples. Unsampled child work remains in parent scope.'))
            stage_info = {}
            for row in report.get("rows", []):
                stage_info[(integer(row.get("domain")), integer(row.get("stage")))] = (row.get("name", "unknown"), row.get("kind", "unknown"))
                self.cpu_aggregate.append(dict(pid=pid, domain=integer(row.get("domain")), stage=integer(row.get("stage")),
                                               name=row.get("name", "unknown"), kind=row.get("kind", "unknown"),
                                               selfWallNS=integer(row.get("selfWallNS")), inclusiveWallNS=integer(row.get("inclusiveWallNS")),
                                               threadCPUCount=integer(row.get('threadCPUCount')),inclusiveThreadCPUNS=integer(row.get('inclusiveThreadCPUNS')),
                                               count=integer(row.get("count")), samplingEvery=integer(sampling.get((integer(row.get("domain")),integer(row.get("stage"))),{}).get("scopeSampleEvery"),1), report=ref(report),
                                               windowStartNS=integer(report.get("windowStartNS")), windowEndNS=integer(report.get("windowEndNS"))))
            for sub in report.get("submissions", []):
                for flag in ("mixedNativeCB", "mixedFrame", "mixedArm", "beganBeforeArm", "beganBeforeWindow", "openAtReport"):
                    if sub.get(flag):
                        # Multiple CB/frame values are valid and represented, but exact
                        # per-frame splitting of aggregate self time is not available.
                        self.issue("cpu-submission-" + flag, scope="cpu", submission=integer(sub.get("submission")), **ref(report))
                detail = dict(pid=pid, domain=integer(sub.get("domain")), submission=integer(sub.get("submission")),
                              queueFamily=integer(sub.get("queueFamily")), queueIndex=integer(sub.get("queueIndex")),
                              thread=integer(sub.get("thread")), startNS=integer(sub.get("startNS")), endNS=integer(sub.get("endNS")),
                              firstThread=integer(sub.get("firstThread", sub.get("thread"))),
                              lastThread=integer(sub.get("lastThread", sub.get("thread"))),
                              mixedThread=bool(sub["mixedThread"]) if "mixedThread" in sub else None,
                              threadFieldMeaning="Legacy/first thread identity; this domain/submission record is not guaranteed to be single-threaded.",
                              firstNativeCB=integer(sub.get("firstNativeCB")), lastNativeCB=integer(sub.get("lastNativeCB")),
                              firstFrame=integer(sub.get("firstFrame")), lastFrame=integer(sub.get("lastFrame")),
                              report=ref(report), phases=[], flags=[k for k in ("mixedThread", "mixedNativeCB", "mixedFrame", "mixedArm", "beganBeforeArm", "beganBeforeWindow", "openAtReport") if sub.get(k)])
                for phase in sub.get("phases", []):
                    name, kind = stage_info.get((detail["domain"], integer(phase.get("stage"))), ("unknown", "unknown"))
                    if name == "unknown":
                        self.issue("cpu-stage-name-or-kind-missing", scope="cpu", stage=integer(phase.get("stage")), **ref(report))
                    detail["phases"].append(dict(stage=integer(phase.get("stage")), name=name, kind=kind,
                                                  selfWallNS=integer(phase.get("selfWallNS")),
                                                  inclusiveWallNS=integer(phase.get("inclusiveWallNS")),
                                                  count=integer(phase.get("count")), failures=integer(phase.get("failures")),
                                                  samplingEvery=integer(sampling.get((detail["domain"],integer(phase.get("stage"))),{}).get("scopeSampleEvery"),1)))
                self.cpu_details.append(detail)
            for source_kind in ('slowSpans','inFlight'):
                for span in report.get(source_kind,[]):
                    self.cpu_span_count+=1
                    if len(self.cpu_spans)>=2000:continue
                    stage=integer(span.get('stage'));domain=integer(span.get('domain'));name,kind=stage_info.get((domain,stage),('unknown','unknown'))
                    start_ca=self.mono_to_ca(span.get('startNS'),pid);end_ca=self.mono_to_ca(span.get('endNS'),pid) if integer(span.get('endNS')) else None
                    self.cpu_spans.append(dict(pid=pid,observation=source_kind,name=name,kind=kind,report=ref(report),inFlightAtReportCF=when if source_kind=='inFlight' else None,
                        measured={k:v for k,v in span.items() if not k.startswith('_')},samplingEvery=integer(sampling.get((domain,stage),{}).get('scopeSampleEvery'),1),
                        startCF=self.ca_to_cf(start_ca,pid),endCF=self.ca_to_cf(end_ca,pid),
                        meaning='Observed thread/span/tag provenance only; inclusive CPU and wall span may overlap nested scopes/other threads and are not exclusive frame costs'))
        if not self.cpu_details:
            self.issue("cpu-submission-detail-unavailable", scope="cpu")
        if self.cpu_span_count>len(self.cpu_spans):self.issue('cpu-span-output-cap',scope='cpu',offered=self.cpu_span_count,limit=len(self.cpu_spans))

    def _ancestor_nodes(self, targets, lo):
        reverse = defaultdict(set)
        for e in self.edges:
            reverse[e["after"]].add(e["before"])
        nodes, todo = set(), list(targets)
        while todo:
            key = todo.pop()
            if key in nodes:
                continue
            nodes.add(key)
            if len(nodes) > 50000:
                self.issue("frame-ancestor-cap", scope="native", cap=50000)
                break
            end = positive(self.cbs[key].get("gpuEndCA"))
            # Closed pre-frame work becomes a boundary node. Its whole old queue
            # prefix cannot contribute execution inside this present interval.
            if key not in targets and end is not None and lo is not None and end < lo:
                continue
            todo.extend(reverse[key] - nodes)
        return nodes

    def _critical_gpu_path(self, nodes, lo, hi):
        parents = defaultdict(set)
        for edge in self.edges:
            if edge["before"] in nodes and edge["after"] in nodes:
                parents[edge["after"]].add(edge["before"])
        lengths, paths = {}, {}
        for key in self.topological:
            if key not in nodes:
                continue
            cb = self.cbs[key]
            interval = clip(positive(cb.get("gpuStartCA")), positive(cb.get("gpuEndCA")), lo, hi)
            weight = interval[1] - interval[0] if interval else D(0)
            best = max(parents[key], key=lambda k: lengths.get(k, D(0)), default=None)
            lengths[key] = lengths.get(best, D(0)) + weight
            paths[key] = paths.get(best, []) + [cb["key"]]
        end = max(lengths, key=lengths.get, default=None)
        selected_intervals = []
        selected = set(paths.get(end, []))
        for key in nodes:
            cb = self.cbs[key]
            if cb["key"] in selected:
                interval = clip(positive(cb.get("gpuStartCA")), positive(cb.get("gpuEndCA")), lo, hi)
                if interval:
                    selected_intervals.append(interval)
        return dict(observedGPUExecutionMs=lengths.get(end, D(0)) * 1000,
                    unionOnSelectedPathMs=interval_union(selected_intervals) * 1000,
                    exclusiveCriticalDurationKnown=False,
                    commandBuffers=paths.get(end, []),
                    meaning="DAG path selected by maximum sum of clipped CB GPU intervals. Intervals can overlap even on one queue; union is also reported. Neither value is an exclusive scheduler/shader critical duration; unmeasured gaps are excluded.")

    def frame_reports(self):
        frames = []
        previous = {}
        presentations = sorted(self.presents, key=lambda r: (str(r["_pid"]),
                              dec(r.get("nativeTimestampCA")) if r.get("nativeTimestampValid") and positive(r.get("nativeTimestampCA"))
                              else dec(r.get("timeCA"), D(0))))
        used_cpu_records = defaultdict(list)
        for row in presentations:
            pid, frameid = row["_pid"], integer(row.get("presentFrame"))
            session = integer(row.get("session"))
            valid = bool(row.get("nativeTimestampValid")) and positive(row.get("nativeTimestampCA")) is not None
            stamp = dec(row.get("nativeTimestampCA")) if valid else None
            swap = integer(row.get("swapchain"))
            previous_ca = previous.get((pid, swap))
            if stamp is not None:
                if previous_ca is not None and stamp <= previous_ca:
                    self.issue("present-timestamp-not-increasing", scope="presentation", pid=pid, presentFrame=frameid)
                previous[(pid, swap)] = stamp
            else:
                self.issue("native-present-timestamp-unavailable", scope="presentation", pid=pid, presentFrame=frameid, **ref(row))
            targets = {k for k, cb in self.cbs.items() if k[0] == pid and integer(cb.get("presentFrame")) == frameid}
            present_cb = integer(row.get("nativeCB"))
            if present_cb:
                if (pid, present_cb) in self.cbs:
                    targets.add((pid, present_cb))
                else:
                    self.issue("present-native-command-buffer-missing", scope="presentation", pid=pid,
                               presentFrame=frameid, nativeCB=present_cb, **ref(row))
            if row.get("partialPrefix"):
                self.issue("native-present-partial-prefix", scope="presentation", pid=pid,
                           presentFrame=frameid, nativeCB=present_cb, **ref(row))
            if not targets:
                self.issue("present-command-buffer-attribution-missing", scope="presentation", pid=pid, presentFrame=frameid)
            if previous_ca is None:
                self.issue("present-window-prefix-missing", scope="presentation", pid=pid, presentFrame=frameid)
            frame = dict(pid=pid, presentFrame=frameid, session=session, swapchain=swap,
                         nativeCB=present_cb or None, partialPrefix=bool(row.get("partialPrefix")),
                         source=ref(row), nativeTimestampValid=valid, nativeTimestampCA=stamp,
                         callbackTimeCA=dec(row.get("timeCA")), previousPresentCA=previous_ca,
                         intervalMs=(stamp - previous_ca) * 1000 if None not in (stamp, previous_ca) else None,
                         targetCommandBuffers=[self.cbs[k]["key"] for k in sorted(targets, key=str)])
            lo = previous_ca
            hi = stamp
            if lo is None and targets:
                lo = min((x for k in targets if (x := positive(self.cbs[k].get("createdCA"))) is not None), default=None)
            if hi is None:
                hi = dec(row.get("timeCA"))
            nodes = self._ancestor_nodes(targets, lo)
            frame["windowForObservedWorkCA"] = [lo, hi]
            frame["dependencyNodeCount"] = len(nodes)
            frame["dependencyEdges"] = [{**{k: v for k, v in e.items() if k not in ("before", "after")},
                                          "before": self.cbs[e["before"]]["key"], "after": self.cbs[e["after"]]["key"]}
                                         for e in self.edges if e["before"] in nodes and e["after"] in nodes]
            relevant = [self.cbs[k] for k in nodes]
            gpu_intervals, per_queue = [], defaultdict(list)
            summaries = []
            commit_gaps = []
            latest_gpu_end = None
            for cb in relevant:
                start, end = positive(cb.get("gpuStartCA")), positive(cb.get("gpuEndCA"))
                interval = clip(start, end, lo, hi)
                if interval:
                    gpu_intervals.append(interval)
                    per_queue[str(cb["queue"])].append(interval)
                commit, scheduled = positive(cb.get("committedCA")), positive(cb.get("scheduledCA"))
                gap = (start - commit) * 1000 if start is not None and commit is not None and start >= commit else None
                if gap is not None and (interval or (lo is not None and hi is not None and lo <= commit <= hi)):
                    commit_gaps.append((gap, cb["key"]))
                if end is not None and hi is not None and end <= hi:
                    latest_gpu_end = max(latest_gpu_end or end, end)
                summaries.append(dict(nativeCB=cb["key"], logicalSubmit=integer(cb.get("logicalSubmit")),
                                      split=integer(cb.get("split")), queue=list(cb["queue"]),
                                      sessions=sorted(cb["sessions"]), createdCA=positive(cb.get("createdCA")),
                                      commitRequestedCA=cb["phases"].get("commitRequested"),
                                      committedCA=commit, scheduledCA=scheduled, gpuStartCA=start, gpuEndCA=end,
                                      commitRequestedToActualCommitMs=(commit - cb["phases"]["commitRequested"]) * 1000
                                      if commit is not None and "commitRequested" in cb["phases"] else None,
                                      GPUIntervalMs=(end - start) * 1000 if None not in (start, end) and end >= start else None,
                                      commitToGPUStartMs=gap, completed="completed" in cb["phases"],
                                      nativeStatus=cb.get("nativeStatus"), partialPrefix=cb["partialPrefix"]))
            gpu_union = interval_union(gpu_intervals) * 1000
            frame["GPU"] = dict(busyIntervalUnionMs=gpu_union,
                                 perQueueBusyIntervalUnionMs={k: interval_union(v) * 1000 for k, v in per_queue.items()},
                                 longestCommitToGPUStartMs=max(commit_gaps, default=(D(0), None))[0],
                                 longestCommitToGPUStartCB=max(commit_gaps, default=(D(0), None))[1],
                                 lastGPUEndToNativePresentMs=(stamp - latest_gpu_end) * 1000 if None not in (stamp, latest_gpu_end) else None,
                                 criticalPath=self._critical_gpu_path(nodes, lo, hi),
                                 commandBuffers=sorted(summaries, key=lambda x: x["nativeCB"]),
                                 limits="GPU intervals may include barriers and internal waits. Queue gaps overlap dependencies; do not add them to GPU time.")
            logicals = {(cb["pid"], integer(cb.get("logicalSubmit")), cb.get("family"), cb.get("index")) for cb in relevant
                        if (cb["pid"], cb["nativeCB"]) in targets or lo is None
                        or positive(cb.get("gpuEndCA")) is None or positive(cb["gpuEndCA"]) >= lo}
            phases = defaultdict(lambda: dict(selfWallNS=0, inclusiveWallNS=0, count=0, failures=0, samplingEvery=1))
            cpu_refs = []
            matched = set()
            for index, detail in enumerate(self.cpu_details):
                key = (detail["pid"], detail["submission"], detail["queueFamily"], detail["queueIndex"])
                if key not in logicals or index in matched:
                    continue
                matched.add(index)
                used_cpu_records[index].append(len(frames))
                cpu_refs.append({k: v for k, v in detail.items() if k != "phases"})
                for p in detail["phases"]:
                    dest = phases[(detail["domain"], p["stage"], p["name"], p["kind"])]
                    dest["samplingEvery"]=max(dest["samplingEvery"],p.get("samplingEvery",1))
                    for field in ("selfWallNS", "inclusiveWallNS", "count", "failures"):
                        dest[field] += p[field]
            unmatched = sorted(str(k) for k in logicals if not any((d["pid"], d["submission"], d["queueFamily"], d["queueIndex"]) == k for d in self.cpu_details))
            if unmatched:
                self.issue("frame-cpu-submissions-unattributed", scope="cpu", pid=pid, presentFrame=frameid, submissions=unmatched[:50], total=len(unmatched))
            phase_rows = [dict(domain=k[0], stage=k[1], name=k[2], kind=k[3], **v,
                               selfWallMs=D(v["selfWallNS"]) / 1000000)
                          for k, v in phases.items()]
            phase_rows.sort(key=lambda p: p["selfWallNS"], reverse=True)
            work_ns = sum(p["selfWallNS"] for p in phase_rows if p["kind"] == "work")
            wait_ns = sum(p["selfWallNS"] for p in phase_rows if p["kind"] == "wait")
            frame["CPU"] = dict(workSelfWallMs=D(work_ns) / 1000000, waitSelfWallMs=D(wait_ns) / 1000000,
                                 phaseRanking=phase_rows, submissionRecords=cpu_refs,
                                 limits="Sum of measured same-thread self wall time over whole domain/submission records, potentially aggregating multiple threads; firstThread/lastThread/mixedThread provenance is preserved. Inclusive times are never summed into the ranking. Async self is zero. Span-completion windows and mixed CB/frame records cannot be split exactly per present.")
            waits = [w for w in self.host_waits if w["pid"] == pid and any(k[0] == pid and k[1] == w["logicalSubmit"] for k in logicals)]
            wait_intervals = [v for w in waits if (v := clip(w["startCA"], w["endCA"], lo, hi))]
            frame["hostWaits"] = dict(records=waits, clippedIntervalUnionMs=interval_union(wait_intervals) * 1000,
                                       limits="Native host waits have no thread ID; union is observed wall coverage, not summed thread CPU or proven frame stall.")
            frame["system"] = self._frame_system(pid, lo, hi, session)
            candidates = [dict(category="CPU measured work", observedMs=frame["CPU"]["workSelfWallMs"], exclusiveFrameCost=False),
                          dict(category="CPU measured waits", observedMs=frame["CPU"]["waitSelfWallMs"], exclusiveFrameCost=False),
                          dict(category="GPU execution interval union", observedMs=gpu_union, exclusiveFrameCost=False),
                          dict(category="native host wait interval union", observedMs=frame["hostWaits"]["clippedIntervalUnionMs"], exclusiveFrameCost=False),
                          dict(category="queue commit to GPU start gap", observedMs=frame["GPU"]["longestCommitToGPUStartMs"], exclusiveFrameCost=False),
                          dict(category="last GPU end to native present gap", observedMs=frame["GPU"]["lastGPUEndToNativePresentMs"] or D(0), exclusiveFrameCost=False)]
            frame["observedContributors"] = sorted(candidates, key=lambda c: c["observedMs"], reverse=True)
            frame["slowComparedWithTarget"] = frame["intervalMs"] is not None and frame["intervalMs"] > D(1000) / self.target_fps
            frame["allCausesFound"] = False
            frame["classification"] = ("observed slow present interval" if frame["slowComparedWithTarget"] else
                                       "observed within target interval" if frame["intervalMs"] is not None else "incomplete present interval")
            frames.append(frame)
        for index, uses in used_cpu_records.items():
            if len(uses) > 1:
                self.issue("cpu-record-spans-multiple-presents", scope="cpu",
                           submission=self.cpu_details[index]["submission"], frameCount=len(uses))
                for frame_index in uses:
                    frames[frame_index]["CPU"]["recordsSharedWithOtherPresents"] = True
        if not self.presents:
            self.issue("native-presents-unavailable", scope="presentation")
        return frames

    def _frame_system(self, pid, lo, hi, session):
        lo_cf, hi_cf = self.ca_to_cf(lo, pid, session), self.ca_to_cf(hi, pid, session)
        selected = [r for r in self.system_rows if dec(r.get("clock", {}).get("CFAbsoluteTime")) is not None and
                    lo_cf is not None and hi_cf is not None and lo_cf <= dec(r["clock"]["CFAbsoluteTime"]) <= hi_cf]
        # Polls are coarse: a one-second system row cannot be fractionally charged
        # to a 33ms frame. Include the surrounding poll references separately.
        surrounding = sorted(self.system_rows, key=lambda r: abs(dec(r.get("clock", {}).get("CFAbsoluteTime"), D(0)) - hi_cf))[:2] if hi_cf is not None else []
        front = [r for r in self.foreground if lo_cf is not None and hi_cf is not None and
                 lo_cf <= dec(r.get("time"), D(-1)) <= hi_cf]
        prior = [r for r in self.foreground if hi_cf is not None and dec(r.get("time"), D(-1)) <= hi_cf]
        latest = max(prior, key=lambda r: dec(r.get("time"), D(-1)), default=None)
        latest_state = None
        if latest is not None:
            latest_state = {k: latest.get(k) for k in ("time", "pid", "alive", "active", "frontmostPID", "visible", "pointWidth", "pointHeight")}
            latest_state["ageAtPresentSeconds"] = hi_cf - dec(latest["time"])
            latest_state["freshWithin2Seconds"] = hi_cf - dec(latest["time"]) <= 2
            latest_state['contextOnlyNotIntervalProof'] = True
        continuity=foreground_intervals(self.foreground)
        intervals=[r for r in continuity['intervals'] if lo_cf is not None and hi_cf is not None and
                   overlap(dec(r['startCF']),dec(r['endCF']),lo_cf,hi_cf)]
        return dict(windowCF=[lo_cf, hi_cf], exactInsidePolls=len(selected),
                    pollReferences=[ref(r) for r in selected], neighboringPollReferences=[ref(r) for r in surrounding],
                    foregroundSamples=[{k: r.get(k) for k in ("time", "pid", "alive", "active", "frontmostPID", "visible", "pointWidth", "pointHeight")} for r in front],
                    lastForegroundObservation=latest_state,
                    foregroundContinuity=intervals, foregroundTailExtrapolated=False,
                    precision="Host polling is coarse; neighboring counter deltas are not assigned proportionally to individual frames.")

    def system_report(self):
        if not self.system_rows:
            self.issue("system-capture-unavailable", scope="system")
            return dict(available=False)
        target = self.system_metadata.get("target", {})
        lstart, identity = target.get("lstart"), self.system_metadata.get("processStartAbstime")
        if lstart is None or identity is None:
            self.issue("system-start-identity-incomplete", scope="system")
        totals, task = Counter(), Counter()
        peaks = defaultdict(int)
        thread_totals = defaultdict(Counter)
        native_progress = []
        host_pressure = []
        warnings = []
        statuses = Counter()
        time_points = []
        for row in self.system_rows:
            clock = row.get("clock", {})
            when = dec(clock.get("CFAbsoluteTime"))
            if when is not None:
                time_points.append(when)
            ident = row.get("identity", {})
            if ident.get("pid") not in (None, self.pid) or ident.get("lstart") not in (None, lstart):
                self.issue("system-pid-start-identity-changed", scope="system", **ref(row))
            usage = row.get("usage", {})
            if identity is not None and usage.get("processStartAbstime") not in (None, identity):
                self.issue("system-kernel-start-identity-changed", scope="system", **ref(row))
            for name, value in row.get("usageDelta", {}).items():
                if isinstance(value, (int, D)) and value >= 0:
                    totals[name] += value
            for name, value in row.get("taskCounterDelta", {}).items():
                if isinstance(value, (int, D)) and value >= 0:
                    task[name] += value
            for name in ("residentBytes", "physicalFootprintBytes", "wiredBytes"):
                peaks[name] = max(peaks[name], integer(usage.get(name)))
            for thread in row.get("threadCPU", {}).get("rows", []):
                dest = thread_totals[(str(thread.get("handle")), thread.get("name", ""))]
                for name in ("userCounterDelta", "systemCounterDelta", "totalCounterDelta"):
                    dest[name] += max(0, integer(thread.get(name)))
            native = row.get("native", {})
            if native.get('directoryInventoryCapped') or native.get('queueSnapshotFileCap'):
                self.issue('system-native-inventory-cap',scope='system',**ref(row))
            graphics = row.get("graphicsLog", {})
            host = row.get("system", {})
            if host:
                host_pressure.append(dict(timeCF=when, source=ref(row),
                                          VMPageSizeBytes=host.get("vmStat", {}).get("pageSizeBytes"),
                                          VMPageCounters=host.get("vmStat", {}).get("counters"),
                                          VMCounterDelta=host.get("vmCounterDelta"),
                                          swapUsage=host.get("swapUsage"), rawPressureLevel=host.get("rawPressureLevel"),
                                          memoryPressureQuery=host.get("memoryPressureQuery"), diskIO=host.get("diskIO"),
                                          thermalLimits=host.get("thermalLimits"), relatedProcesses=host.get("relatedProcesses")))
            if native or graphics:
                native_progress.append(dict(timeCF=when, source=ref(row),
                                            fileCounts=native.get("fileCounts"), fileCountDelta=native.get("fileCountDelta"),
                                            graphicsKeywordCounts=graphics.get("newKeywordCounts"),
                                            newGPUTimeoutFiles=native.get("newGPUTimeoutFiles"),
                                            queues=native.get("queues"), latestPresent=native.get("latestPresent"),
                                            memory=native.get("memory-current"), residency=native.get("residency-cost"),
                                            resourceUse=native.get("resource-use-current"),heapPlan=native.get('heap-plan-stats'),
                                            sharedSnapshots=native.get('shared-snapshot-stats'),descriptorDirty=native.get('descriptor-dirty')))
            # Numeric snapshots are already filtered by the harness. Their age is
            # evaluated rather than treating an old file as active instrumentation.
            def snapshots(obj):
                if isinstance(obj, dict):
                    if "numericFields" in obj and "name" in obj:
                        yield obj
                    for value in obj.values():
                        yield from snapshots(value)
                elif isinstance(obj, list):
                    for value in obj:
                        yield from snapshots(value)
            for snap in snapshots(native):
                if snap.get("sourceFreshWithin15Seconds") is False:
                    self.issue("system-native-snapshot-stale", scope="system", name=snap.get("name"),
                               ageSeconds=snap.get("sourceAgeSeconds"))
            if row.get("threadCounters", {}).get("listMayBeTruncated"):
                self.issue("system-thread-list-truncated", scope="system", **ref(row))
            if row.get("terminal"):
                statuses[row["terminal"]] += 1
        duration = max(time_points) - min(time_points) if time_points else D(0)
        for a, b in zip(sorted(time_points), sorted(time_points)[1:]):
            if b - a > D(3):
                self.issue("system-poll-gap", scope="system", gapSeconds=b - a)
        if not self.foreground:
            self.issue("foreground-observer-unavailable", scope="system")
        warnings += self.system_summary.get("observabilityWarnings", [])
        if self.system_summary.get("errors"):
            self.issue("system-collector-errors", scope="system", count=len(self.system_summary["errors"]))
        return dict(available=True, targetPID=self.pid, targetLstart=lstart, processStartAbstime=identity,
                    observedSeconds=duration, usageCounterDeltaTotals=dict(totals), taskCounterDeltaTotals=dict(task),
                    memoryPeaksBytes=dict(peaks),
                    threadCounterRanking=[dict(handle=k[0], name=k[1], **v) for k, v in sorted(thread_totals.items(), key=lambda pair: pair[1]["totalCounterDelta"], reverse=True)[:40]],
                    progressAndFailurePolls=native_progress, hostPressureAndRelatedProcessPolls=host_pressure,
                    terminalStates=dict(statuses),
                    collectorWarnings=warnings,
                    rawCounterUnits=self.system_metadata.get("rawCPUTimeUnits"),
                    limits=["Kernel raw CPU counters are not converted to utilization without a stated counter timebase.",
                            "System compression/swap/disk/pressure counters identify host pressure, not which process caused it.",
                            "File growth proves progress only; a capped or stale writer cannot prove a stall.",
                            "This analyzer does not unwind Windows guest stacks or infer CPU self time from inclusive samples."])

    def gpu_report(self):
        sidecars = {}
        for row in self.gpu_clocks:
            if row.get("type") != "gpuCounterSessionClock":
                self.issue("gpu-clock-sidecar-type-unparsed", scope="gpu-counters", **ref(row))
                continue
            sidecars[(self._pid_for(row), integer(row.get("armSignature")), integer(row.get("sessionID")))] = row
        parsed, unparsed = [], []
        for artifact in self.gpu_artifacts:
            for path in true_field_paths(artifact, "mayHaveUnsampledSuffix"):
                self.issue("gpu-may-have-unsampled-suffix", scope="gpu-counters", fieldPath=path, **ref(artifact))
            if "samples" in artifact and "coverage" in artifact:
                snapshots = [(artifact, artifact)]
            elif isinstance(artifact.get("gpuTimestamps"), dict):
                # Actual native trace wrapper, distinct from the owned control's
                # snapshot wrapper. The inner coverage carries the native IDs.
                snapshots = [(artifact["gpuTimestamps"], artifact)]
            elif isinstance(artifact.get("rows"), list):
                snapshots = [(r["snapshot"], r) for r in artifact["rows"] if isinstance(r, dict) and isinstance(r.get("snapshot"), dict)]
            elif isinstance(artifact.get("snapshot"), dict):
                snapshots = [(artifact["snapshot"], artifact)]
            else:
                snapshots = []
            if not snapshots:
                unparsed.append(dict(source=ref(artifact), reason="unrecognized-artifact-schema"))
                self.issue("gpu-artifact-unparsed", scope="gpu-counters", **ref(artifact))
            for snap, enclosing in snapshots:
                coverage = snap.get("coverage", {})
                session = snap.get("captureSession", {})
                pid = self._pid_for(artifact)
                arm = integer(session.get("armSignature")) or integer(coverage.get("creationArmSignature"))
                sid = integer(coverage.get("sessionID", session.get("sessionID"))) or integer(coverage.get("creationSessionID"))
                native_only = (coverage.get("nativeIntervalOnly") is True or snap.get("nativeIntervalOnly") is True
                               or enclosing.get("nativeIntervalOnly") is True or integer(coverage.get("skipReasonCode")) == 9)
                readback_expected = bool(coverage.get("counterReadbackExpected", not native_only)) and not native_only
                sidecar = sidecars.get((pid, arm, sid))
                pair = sidecar.get("clockCalibration") if sidecar else snap.get("clockCalibration")
                outcome = dict(source=ref(artifact), pid=pid, armSignature=arm, sessionID=sid,
                               nativeCBID=integer(coverage.get("nativeCBID")),
                               logicalSubmissionID=integer(coverage.get("logicalSubmissionID")),
                               nativeSplitIndex=integer(coverage.get("nativeSplitIndex")),
                               presentFrameID=integer(coverage.get("presentFrameID")),
                               sampleCount=len(snap.get("samples", [])),
                               rawCounterDomain="device-GPU-clock", exclusiveShaderDurationsAvailable=False,
                               convertedCAIsEstimate=True, hardwareClockAccuracyGuaranteed=False,
                               nativeGraphSessionMatched=(pid, arm) in self.calibrations,
                               nativeIntervalOnly=native_only, counterReadbackExpected=readback_expected,
                               calibrationSource=ref(sidecar) if sidecar else ref(artifact),
                               boundaryIntervals=[], unconvertedSamples=0,
                               counterHostClockRaw=dict(
                                   domain="std::chrono::steady_clock nanoseconds",
                                   createdMonotonicNS=coverage.get("createdMonotonicNS"),
                                   nativeCommitMonotonicNS=coverage.get("nativeCommitMonotonicNS"),
                                   sessionStartedMonotonicNS=session.get("startedMonotonicNS"),
                                   sessionDeadlineMonotonicNS=session.get("deadlineMonotonicNS"),
                                   samples=[dict(index=s.get("index"), encodedMonotonicNS=s.get("encodedMonotonicNS"))
                                            for s in snap.get("samples", []) if "encodedMonotonicNS" in s],
                                   comparableToCPUTraceMonotonicNS=False,
                                   mappedToCPUTrace=False,
                                   meaning="Raw counter-host steady-clock fields only; CPU/native trace uses Mach absolute NS. No cross-clock subtraction or mapping is performed."),
                               mayHaveUnsampledSuffix=bool(list(true_field_paths(snap, "mayHaveUnsampledSuffix")))
                               or enclosing.get("mayHaveUnsampledSuffix") is True
                               or artifact.get("mayHaveUnsampledSuffix") is True)
                offered = integer(coverage.get("eligibleEventsOffered"))
                encoded = integer(coverage.get("samplesEncoded"))
                sample_count = len(snap.get("samples", []))
                valid_count = integer(snap.get("validSamples"))
                if native_only:
                    outcome["sampleState"] = "native-interval-only"
                elif not snap.get("enabled"):
                    outcome["sampleState"] = "instrumentation-disabled"
                elif not snap.get("CPUResolveSucceeded") and (encoded or sample_count or valid_count):
                    outcome["sampleState"] = "resolve-failed-with-encoded-samples"
                    self.issue("gpu-counter-resolve-failed", scope="gpu-counters", nativeCB=outcome["nativeCBID"],
                               encodedSamples=encoded, sampleRows=sample_count, validSamples=valid_count)
                elif not encoded and not sample_count and not valid_count:
                    outcome["sampleState"] = "no-eligible-events" if not offered else "no-encoded-events"
                    if offered:
                        self.issue("gpu-offered-events-unsampled", scope="gpu-counters", nativeCB=outcome["nativeCBID"], offeredEvents=offered)
                else:
                    outcome["sampleState"] = "samples-resolved"
                outcome["commandBufferRoleEvidence"] = self._gpu_role_evidence(enclosing, outcome)
                if outcome["sampleState"] == "no-eligible-events" and outcome["commandBufferRoleEvidence"]["recordedWorkCount"]:
                    self.issue("gpu-recorded-work-without-eligible-counter-events", scope="gpu-counters", nativeCB=outcome["nativeCBID"],
                               recordedWorkCount=outcome["commandBufferRoleEvidence"]["recordedWorkCount"])
                if not outcome["nativeGraphSessionMatched"] and not native_only:
                    self.issue("gpu-native-session-unmatched", scope="gpu-counters", pid=pid, armSignature=arm, sessionID=sid)
                cb = self.cbs.get((pid, outcome["nativeCBID"]))
                outcome["nativeCommandBufferMatched"] = cb is not None
                if cb is None:
                    self.issue("gpu-native-command-buffer-unmatched", scope="gpu-counters", pid=pid, nativeCB=outcome["nativeCBID"])
                else:
                    for native_name, counter_name in (("logicalSubmit", "logicalSubmissionID"), ("split", "nativeSplitIndex"), ("presentFrame", "presentFrameID")):
                        if integer(cb.get(native_name)) != outcome[counter_name]:
                            self.issue("gpu-native-attribution-mismatch", scope="gpu-counters", nativeCB=outcome["nativeCBID"],
                                       field=native_name, nativeValue=integer(cb.get(native_name)), counterValue=outcome[counter_name])
                for name in ("capHit", "captureStartedMidCommandBuffer", "eventsDroppedCapacity", "eventsDroppedDuration", "eventsDroppedSampleBudget", "eventsDroppedLiveBudget", "eventsDroppedUnsupportedPoint", "eventsWithoutCounterBuffer"):
                    if coverage.get(name):
                        self.issue("gpu-coverage-" + name, scope="gpu-counters", nativeCB=outcome["nativeCBID"], count=coverage[name])
                if ((not snap.get("enabled") and not native_only) or (not snap.get("nativeCompleted") and not native_only)
                        or outcome["sampleState"] == "resolve-failed-with-encoded-samples"
                        or snap.get("truncated") or integer(snap.get("invalidSamples"))):
                    self.issue("gpu-snapshot-incomplete", scope="gpu-counters", nativeCB=outcome["nativeCBID"])
                if sidecar and sidecar.get("physicalDeviceConflict"):
                    self.issue("gpu-clock-physical-device-conflict", scope="gpu-counters", sessionID=sid)
                    pair = None
                for name in ("allocationFailures", "eventsDroppedCapacity", "eventsDroppedDuration", "eventsDroppedSampleBudget",
                             "eventsDroppedLiveBudget", "eventsDroppedUnsupportedPoint", "commandBuffersDroppedInFlight",
                             "commandBuffersDroppedDuration", "commandBuffersDroppedCap", "commandBuffersUnsupported"):
                    if integer(session.get(name)):
                        self.issue("gpu-session-" + name, scope="gpu-counters", sessionID=sid, count=integer(session[name]))
                converted = []
                reason = "CPU-counter-resolve-failed" if outcome["sampleState"] == "resolve-failed-with-encoded-samples" else None
                for sample in snap.get("samples", []):
                    if native_only:
                        # Informational interval-only outcomes promise no stage
                        # readback. Never convert possible stale counter rows.
                        continue
                    if not sample.get("valid"):
                        outcome["unconvertedSamples"] += 1
                        continue
                    if outcome["sampleState"] == "resolve-failed-with-encoded-samples":
                        outcome["unconvertedSamples"] += 1
                        continue
                    estimate, error = convert_gpu_clock(integer(sample.get("timestamp")), pair, self.timebase)
                    if error:
                        reason = error
                        outcome["unconvertedSamples"] += 1
                    else:
                        converted.append((sample, estimate))
                if reason:
                    outcome["conversionUnavailableReason"] = reason
                    self.issue("gpu-counter-clock-unavailable", scope="gpu-counters", reason=reason, **ref(artifact))
                for (a, x), (b, y) in zip(converted, converted[1:]):
                    if y["timeCA"] < x["timeCA"]:
                        self.issue("gpu-counter-nonmonotonic", scope="gpu-counters", nativeCB=outcome["nativeCBID"])
                        continue
                    outcome["boundaryIntervals"].append(dict(firstIndex=integer(a.get("index")), lastIndex=integer(b.get("index")),
                                                            firstKind=a.get("kind"), lastKind=b.get("kind"),
                                                            firstLabel=a.get("label"), lastLabel=b.get("label"),
                                                            startCA=x["timeCA"], endCA=y["timeCA"],
                                                            observedMs=(y["timeCA"] - x["timeCA"]) * 1000,
                                                            hostBracketUncertaintyNS=max(x["hostBracketUncertaintyNS"], y["hostBracketUncertaintyNS"]),
                                                            exclusiveShaderDuration=False))
                outcome["boundaryIntervals"].sort(key=lambda x: x["observedMs"], reverse=True)
                parsed.append(outcome)
        native_coverage = self._native_counter_coverage(parsed)
        if not self.gpu_artifacts and not (native_coverage["knownCaptureCBs"]
                and native_coverage["nativeIntervalOnlyCBs"] == native_coverage["knownCaptureCBs"]):
            self.issue("gpu-stage-counters-unavailable", scope="gpu-counters")
        return dict(artifacts=parsed, unparsed=unparsed, nativeCommandBufferCoverage=native_coverage,
                    limits=["Counter timestamps are converted only through a valid paired sample and the explicit host Mach timebase.",
                            "Sidecars join by armSignature and sessionID, never by sessionID alone.",
                            "Counter-host created/encoded/commit MonotonicNS fields use std::chrono::steady_clock and are retained raw; CPU/native Mach MonotonicNS anchors are never applied to them.",
                            "Provided artifact completeness does not imply all-queue/all-CB coverage. Native counterSession/skip/allocated/midCB flags independently identify missed capture within the known window; explicitly unarmed future CBs are outside that scope.",
                            "Native interval-only / skip9 outcomes promise no counter artifact or stage readback; they are not missing driver results and provide no shader timings.",
                            "Adjacent counter differences can contain overlapping encoders, barriers and other work; they are not exclusive shader durations.",
                            "Host bracket width is reported; GPU clock hardware accuracy is not guaranteed."])

    def _gpu_role_evidence(self, enclosing, outcome):
        label = str(enclosing.get("nativeCommandBufferLabel", ""))
        events = enclosing.get("events", [])
        work = enclosing.get("workEvents", [])
        operations = Counter(str(row.get("operation", "unknown")) for row in events if isinstance(row, dict))
        kinds = Counter(str(row.get("kind", row.get("operation", "unknown"))) for row in work if isinstance(row, dict))
        known_count = "workCount" in enclosing
        count = integer(enclosing.get("workCount")) if known_count else None
        truncated = bool(integer(enclosing.get("truncatedWorkEvents")) or integer(enclosing.get("truncatedEvents")))
        present_native_ids = {(row["_pid"], integer(row.get("nativeCB"))) for row in self.presents}
        present_evidence = "vkQueuePresent" in label or (outcome["pid"], outcome["nativeCBID"]) in present_native_ids
        role = "unclassified"
        if truncated:
            role = "unknown-truncated-record"
        elif known_count and count == 0:
            if present_evidence:
                role = "present-with-no-recorded-work"
            elif set(operations) == {"wait"}:
                role = "wait-events-only-with-no-recorded-work"
            elif set(operations) == {"signal"}:
                role = "signal-events-only-with-no-recorded-work"
            elif operations and set(operations) <= {"wait", "signal"}:
                role = "wait-and-signal-with-no-recorded-work"
            else:
                role = "no-recorded-work-role-unknown"
        elif known_count and count:
            role = "recorded-work"
        return dict(role=role, nativeCommandBufferLabel=label or None,
                    recordedWorkCount=count, workCountKnown=known_count,
                    observedWorkKinds=dict(kinds), observedEventOperations=dict(operations),
                    workOrEventRecordTruncated=truncated, presentEvidence=present_evidence,
                    limits="Observed enclosing work/event records and label/native present association only. Zero samples alone never proves wait-only, present, empty work or driver readback failure.")

    def _native_counter_coverage(self, artifacts):
        names = {0: "not-armed", 1: "allocated", 2: "legacy-queue-filter", 3: "legacy-pipeline-pending",
                 4: "duration-cap", 5: "command-buffer-cap", 6: "in-flight-cap",
                 7: "unsupported-counter-sampling", 8: "counter-buffer-allocation-failed", 9: "no-eligible-GPU-events-observed"}
        by_native = defaultdict(list)
        for artifact in artifacts:
            by_native[(artifact["pid"], artifact["nativeCBID"])].append(artifact)
        records, unarmed, unknown = [], [], []
        for key, cb in sorted(self.cbs.items(), key=lambda pair: str(pair[0])):
            observation = cb.get("counterNativeObservation")
            if observation is None:
                unknown.append(cb["key"])
                continue
            session = integer(observation.get("counterSession"))
            skip = integer(observation.get("counterSkip"), -1)
            allocated = observation.get("counterAllocated") is True
            mid = cb.get("counterMidCB", False) or observation.get("counterMidCB") is True
            native_only = skip == 9 or observation.get("nativeIntervalOnly") is True
            known_capture = session > 0 or allocated or mid or skip > 0
            if not known_capture:
                # A later unarmed CB can have a native graph record. It must not
                # turn one finite counter arm into a permanent capture failure.
                unarmed.append(cb["key"])
                continue
            matches = by_native.get(key, [])
            issues = []
            row = dict(pid=cb["pid"], nativeCB=cb["nativeCB"], logicalSubmit=integer(cb.get("logicalSubmit")),
                       split=integer(cb.get("split")), nativeSessions=sorted(cb["sessions"]),
                       counterSession=session, counterSkip=skip, counterSkipMeaning=names.get(skip, "unknown"),
                       counterAllocated=allocated, counterMidCB=mid, source=observation["source"],
                       nativeIntervalOnly=native_only,
                       counterReadbackExpected=False if native_only else observation.get("counterReadbackExpected", allocated),
                       matchedArtifactCount=len(matches), nativeCompleted="completed" in cb["phases"],
                       captureExpectedFrom="counterSession>0 or explicit counter capture/skip flag")
            def gap(code, **details):
                issues.append(code)
                self.issue(code, scope="gpu-counters", pid=cb["pid"], nativeCB=cb["nativeCB"],
                           counterSession=session, **details)
            if skip not in (0, 1, 9):
                gap("gpu-native-counter-skipped", counterSkip=skip, reason=names.get(skip, "unknown"))
            if not allocated and not native_only:
                gap("gpu-native-counter-not-allocated", counterSkip=skip)
            if mid:
                gap("gpu-native-counter-mid-command-buffer")
            if not matches and not native_only:
                gap("gpu-native-artifact-missing")
            elif matches and not native_only:
                if session and any(artifact["sessionID"] != session for artifact in matches):
                    gap("gpu-native-counter-session-mismatch", artifactSessions=sorted({artifact["sessionID"] for artifact in matches}))
                if any(artifact.get("unconvertedSamples") or artifact.get("mayHaveUnsampledSuffix") for artifact in matches):
                    gap("gpu-native-artifact-incomplete")
            if "completed" not in cb["phases"]:
                gap("gpu-native-counter-completion-missing")
            row["coverageIssues"] = issues
            row["observedCoverageComplete"] = not issues
            records.append(row)
        return dict(scope="Native CBs with explicit counterSession>0 or allocated/midCB/skip>0 flags; not all future/unarmed CBs.",
                    knownCaptureCBs=len(records), completeKnownCaptureCBs=sum(r["observedCoverageComplete"] for r in records),
                    nativeIntervalOnlyCBs=sum(r["nativeIntervalOnly"] for r in records),
                    incompleteKnownCaptureCBs=sum(not r["observedCoverageComplete"] for r in records),
                    observedCoverageComplete=bool(records) and all(r["observedCoverageComplete"] for r in records),
                    records=records, knownUnarmedNativeCBs=unarmed, nativeCounterEligibilityUnknownCBs=unknown,
                    limits="A complete provided artifact set only covers its known sampled portion; unknown native eligibility is not assumed captured and finite arms do not promise capture of future CBs.")

    def guest_report(self):
        # Guest IDs/clocks stay separate from native Mach identities.
        epoch=D(116444736000000000);anchors=defaultdict(list);records=[];begins=defaultdict(list);spans=[];kinds=Counter();unclocked=0
        names={1:'ExecuteCommandLists',2:'worker',3:'workerEnqueue',4:'workerAcquire',5:'vkQueueSubmit2',6:'waitSemaphoreEdge',7:'signalSemaphoreEdge',8:'VkCommandBuffer',9:'CreateGraphicsPipelineState',10:'CreateComputePipelineState',11:'CreatePipelineStateStream',12:'vkCreateGraphicsPipelines',13:'vkCreateComputePipelines',14:'returnedVkPipeline',15:'pthread_cond_wait',16:'nativeQueueAcquire',17:'serializedQueueDrain',18:'vkWaitSemaphores',19:'VkQueueMapping',20:'PSOBuild',21:'createCommittedResource',22:'createPlacedResource',23:'createReservedResource',24:'allocateHeapMemory',25:'vkAllocateMemory',26:'VkDeviceMemoryHandle',27:'vkMapMemory',28:'ResourceMap',29:'ResourceUnmap',30:'vkFlushMappedMemoryRanges',31:'vkInvalidateMappedMemoryRanges'}
        seen=set();sequences=defaultdict(set);copy_rows=defaultdict(list);missing=[];edge_caps=[];unpaired_ends=0
        for row in self.guest_rows:
            if row.get('type')!='clockCalibration':continue
            before,after,freq,wall=[dec(row.get(k)) for k in ('qpcBefore','qpcAfter','qpcFrequency','fileTimeUTC100ns')]
            if row.get('clockDomain')!='windows-qpc' or None in (before,after,freq,wall) or freq<=0 or after<before or not row.get('session'):
                missing.append(dict(reason='invalid-or-missing-guest-calibration',source=ref(row)));continue
            anchors[(row.get('windowsPID'),row.get('runID'))].append(dict(mid=(before+after)/2,freq=freq,cf=(wall-epoch)/D(10000000)-CF_UNIX_OFFSET,bound=(after-before)/2/freq,session=row.get('session')))
        for row in sorted(self.guest_rows,key=lambda r:integer(r.get('qpc'))):
            if row.get('type') in ('copyCumulative','resourceAPICumulative'):
                copy_rows[(row.get('type'),row.get('runID'),row.get('shardIndex'),integer(row.get('operation')))].append(row);continue
            if row.get('type')!='event':continue
            pid,run=row.get('windowsPID'),row.get('runID');seq=row.get('seq');key=(pid,run,seq)
            if seq is None:key=(pid,run,ref(row).get('source'),ref(row).get('line'))
            if key in seen:continue
            seen.add(key)
            if isinstance(seq,int):sequences[(pid,run)].add(seq)
            qpc=dec(row.get('qpc'));available=[a for a in anchors.get((pid,run),[]) if a['session']==row.get('session')]
            anchor=min(available,key=lambda a:abs(a['mid']-qpc)) if available and qpc is not None and row.get('schema')==1 and row.get('session') else None
            cf=anchor['cf']+(qpc-anchor['mid'])/anchor['freq'] if anchor else None
            unclocked+=cf is None;kind=integer(row.get('kind'),-1);kinds[str(kind)]+=1
            session_filetime=dec(row.get('session'));arm_unix_ns=(session_filetime-epoch)*100 if session_filetime is not None and session_filetime>0 else None
            args=row.get('args') if isinstance(row.get('args'),list) and len(row['args'])==8 else None
            if args is None:missing.append(dict(reason='missing-eight-guest-args',source=ref(row)))
            if row.get('phase')==2 and args and ((kind==5 and integer(args[5])) or (kind==6 and integer(args[6]) and not integer(args[0])) or (kind==14 and integer(args[4]))):edge_caps.append(ref(row))
            record=dict(guestPID=pid,runID=run,kind=kind,kindName=names.get(kind,'unknown'),phase=row.get('phase'),id=row.get('id'),parent=row.get('parent'),
                windowsThreadID=row.get('windowsThreadID'),timeCF=cf,qpc=row.get('qpc'),args=args,
                sessionFileTime100ns=row.get('session'),sessionUnixNS=arm_unix_ns,sessionQuantumNS=100,
                calibrationBracketHalfSeconds=anchor['bound'] if anchor else None,UTCGranularityBound='unknown; GetSystemTimeAsFileTime resolution can exceed QPC bracket',
                hostPIDOrMachThreadJoin='unjoinable without an independently measured map',source=ref(row))
            if row.get('phase')==2 and kind in (28,30,31) and args and integer(args[3])==1:
                failure=integer(args[1]);failure=failure-(1<<64) if failure>=1<<63 else failure
                record['unsampledFailureDetail']=dict(object=args[0],originalSignedResult=failure,subresourceOrRangeCount=args[2],partialSuffix=bool(args[4]),timedSampleNotImplied=True)
            elif row.get('phase')==2 and kind==26 and args:
                record['memoryHandleDetail']=dict(VkDeviceMemory=args[0],allocationSizeBytes=args[1],memoryTypeIndex=args[2])
            pair=(pid,run,row.get('windowsThreadID'),row.get('id'),row.get('parent'),kind)
            if row.get('phase')==0:begins[pair].append(record)
            elif row.get('phase')==1:
                start=begins[pair].pop() if begins[pair] else None
                if start and anchor and qpc is not None and dec(start['qpc']) is not None and qpc>=dec(start['qpc']):
                    body=dec(args[3]) if args else None;body_start=dec(args[7]) if args else None
                    valid_body=body is not None and body>=0 and body_start is not None and dec(start['qpc'])<=body_start<=qpc and body<=qpc-dec(start['qpc'])
                    result=integer(args[4]) if args and integer(args[5]) else None
                    if result is not None and result>=1<<63:result-=1<<64
                    spans.append(dict(guestPID=pid,runID=run,kind=kind,kindName=names.get(kind,'unknown'),id=row.get('id'),windowsThreadID=row.get('windowsThreadID'),
                        envelopeElapsedMs=(qpc-dec(start['qpc']))/anchor['freq']*1000,actualBodyElapsedMs=body/anchor['freq']*1000 if valid_body else None,
                        originalSignedResult=result,partialSuffixSessionChanged=bool(args and integer(args[6])),sourceBegin=start['source'],sourceEnd=record['source'],
                        meaning='Guest API wall span, not GPU execution or exclusive frame cost'))
                else:unpaired_ends+=1
            if len(records)<2000:records.append(record)
        copy_deltas=[];resource_deltas=[];cumulative_streams=[]
        operations={0:'CopyDescriptors',1:'ResourceMap',2:'ResourceUnmap',3:'FlushMappedRanges',4:'InvalidateMappedRanges'}
        for (record_type,run,shard,operation),rows in copy_rows.items():
            rows=sorted(rows,key=lambda r:integer(r.get('qpc')))
            units='offeredDescriptors' if record_type=='copyCumulative' else 'offeredUnits'
            fields=('offeredCalls',units,'sampledCalls','sampledWallQPC')
            boundaries={}
            for sample in rows:
                session_key=str(sample.get('session'));boundaries[session_key]=boundaries.get(session_key,False) or bool(sample.get('finalBoundary'))
            cumulative_streams.append(dict(type=record_type,runID=run,shardIndex=shard,operation=operation,operationName=operations.get(operation,'unknown'),
                snapshots=len(rows),lastRunArmedCumulative={k:rows[-1].get(k) for k in fields},lastSamplePeriod=rows[-1].get('samplePeriod'),finalBoundaryBySession=boundaries,
                nonAtomicCumulativeSnapshot=any(r.get('nonAtomicCumulativeSnapshot') for r in rows),sourceFirst=ref(rows[0]),sourceLast=ref(rows[-1]),
                statuses=['observed','sampled']+(['missing'] if not all(boundaries.values()) else []),
                meaning='Run+operation+shard counters across arms; absolute run-armed totals are not a user-stage delta. finalBoundary is explicit but the tuple can straddle in-flight sampled work.'))
            if record_type=='resourceAPICumulative' and operation not in (1,2,3,4):missing.append(dict(reason='unknown-resource-api-operation',source=ref(rows[-1])))
            for a,b in zip(rows,rows[1:]):
                delta={k:integer(b.get(k))-integer(a.get(k)) for k in fields}
                if any(v<0 for v in delta.values()):missing.append(dict(reason='api-cumulative-nonmonotonic',source=ref(b)));continue
                entry=dict(type=record_type,runID=run,shardIndex=shard,operation=operation,operationName=operations.get(operation,'unknown'),
                    fromSession=a.get('session'),toSession=b.get('session'),samplePeriod=b.get('samplePeriod'),
                    finalBoundaryAtEnd=bool(b.get('finalBoundary')),measuredCumulativeDelta=delta,extrapolated=False,
                    nonAtomicCumulativeSnapshot=bool(a.get('nonAtomicCumulativeSnapshot') or b.get('nonAtomicCumulativeSnapshot')),
                    sourceBegin=ref(a),sourceEnd=ref(b),meaning='Same run+operation+shard differences across arms; sampledWallQPC is measured samples only, never extrapolated to total API CPU or wall cost')
                (copy_deltas if record_type=='copyCumulative' else resource_deltas).append(entry)
        # Detail.id is the Vulkan scope id; parent remains its OUTER scope.
        # Merge generations before this pass. Never pair by detail.parent.
        vulkan_scopes={};details=[];link_seen=set();link_cap=False
        for row in self.guest_rows:
            if row.get('type')!='event':continue
            key=(row.get('windowsPID'),row.get('runID'),row.get('session'),row.get('id'))
            dedup=(key,row.get('seq')) if row.get('seq') is not None else (key,ref(row).get('source'),ref(row).get('line'))
            if dedup in link_seen:continue
            link_seen.add(dedup);kind=integer(row.get('kind'));phase=row.get('phase')
            if phase in (0,1) and kind in (5,12,13,18,25) and integer(row.get('id')):
                if key not in vulkan_scopes and len(vulkan_scopes)>=8192:link_cap=True;continue
                scope=vulkan_scopes.setdefault(key,dict(guestPID=key[0],runID=key[1],session=key[2],id=key[3],kind=kind,kindName=names[kind],outerParent=row.get('parent'),begin=None,end=None,details=[]))
                if scope['kind']!=kind:missing.append(dict(reason='vulkan-scope-id-kind-conflict',source=ref(row)));continue
                scope['begin' if phase==0 else 'end']=ref(row)
            elif phase==2 and kind in (5,6,7,8,14,26):
                if len(details)<32768:details.append((key,row))
                else:link_cap=True
        unresolved=[];scope_expect={5:(5,),6:(5,18),7:(5,),8:(5,),14:(12,13),26:(25,)}
        for key,row in details:
            scope=vulkan_scopes.get(key);kind=integer(row.get('kind'))
            if scope is None or scope['kind'] not in scope_expect[kind] or scope['outerParent']!=row.get('parent'):
                unresolved.append(dict(guestPID=key[0],runID=key[1],session=key[2],id=key[3],kind=kind,outerParent=row.get('parent'),source=ref(row),reason='same-id-vulkan-scope-missing-or-conflicting'));continue
            if len(scope['details'])<256:scope['details'].append(dict(kind=kind,kindName=names[kind],args=row.get('args'),source=ref(row)))
            else:link_cap=True
        for scope in vulkan_scopes.values():scope['paired']=scope['begin'] is not None and scope['end'] is not None
        bad=cumulative_counter_windows(self.guest_current,('producerDropped','lockDrops','ringDrops','rateDrops','IOFailures','copyUntrackedCalls','copyUntrackedDescriptors'),'windowsPID')
        if not self.guest_current:missing.append(dict(reason='guest-current-metadata-not-observed'))
        losses=[r for r in self.guest_copy_index if r.get('status') in ('missing','capped','unjoinable')]
        gaps=[]
        for (pid,run),values in sequences.items():
            ordered=sorted(values);ranges=[dict(after=a,before=b,missing=b-a-1) for a,b in zip(ordered,ordered[1:]) if b>a+1]
            if ranges:gaps.append(dict(guestPID=pid,runID=run,ranges=ranges[:32]))
        statuses=['observed'] if kinds else ['missing'];statuses.append('unjoinable')
        if missing or unclocked or gaps or unpaired_ends or any(begins.values()) or unresolved or any(not s['paired'] for s in vulkan_scopes.values()) or any('missing' in r['statuses'] for r in cumulative_streams):
            if 'missing' not in statuses:statuses.append('missing')
        if any(r['observedDelta'] for r in bad) or losses or edge_caps or link_cap or sum(kinds.values())>len(records) or len(copy_deltas)>512 or len(resource_deltas)>512 or len(cumulative_streams)>512 or len(spans)>500:statuses.append('capped')
        return dict(available=bool(kinds),statuses=statuses,clockDomain='guest QPC paired with Windows FILETIME UTC; session FILETIME epoch differs from native Unix mtimeNS',
            kinds=dict(kinds),records=records,recordsTruncated=sum(kinds.values())>len(records),clockUnjoinable=unclocked,
            pairedSoftwareSpans=spans[:500],softwareSpansTruncated=len(spans)>500,unclosedBeginEvents=sum(len(v) for v in begins.values()),unpairedEndEvents=unpaired_ends,
            unclosedSoftwareScopeRecords=[r for values in begins.values() for r in values][:128],unclosedSoftwareScopeOutputCapped=sum(len(v) for v in begins.values())>128,
            copyDescriptorCumulativeDeltas=copy_deltas[:512],copyDeltaOutputCapped=len(copy_deltas)>512,
            resourceAPICumulativeDeltas=resource_deltas[:512],resourceDeltaOutputCapped=len(resource_deltas)>512,cumulativeStreams=cumulative_streams[:512],cumulativeStreamOutputCapped=len(cumulative_streams)>512,cumulativeAvailable=bool(copy_rows),
            vulkanScopeDetails=list(vulkan_scopes.values()),unresolvedVulkanScopeDetails=unresolved[:128],unresolvedVulkanScopeDetailCount=len(unresolved),vulkanScopeLinkCapped=link_cap,
            vulkanScopeLinkRule='Actual guest (windowsPID,runID,session,id) and compatible scope kind; detail.parent is outer provenance, never used as target id. No native-host handle equivalence is inferred.',
            resourceKindCounts={names[k]:kinds[str(k)] for k in range(21,32) if kinds[str(k)]},resourceAPILimits='Map/Unmap all offers counted; only1:64 calls timed. Flush/invalidate units are range counts. Unsampled failures are explicit details; sampled times are never extrapolated. Legacy copyUntracked fields cover all sampled API operations.',missingMetadata=missing[:128],sequenceGaps=gaps,edgeMetadataCapped=edge_caps[:128],
            counterWindows=bad,counterSessions=cumulative_counter_sessions(self.guest_current,('producerDropped','lockDrops','ringDrops','rateDrops','IOFailures','copyUntrackedCalls','copyUntrackedDescriptors'),'windowsPID'),budgetOrIOIssues=[r for r in bad if r['observedDelta'] or r['nonmonotonic']],counterPrefixUnknown=[r for r in bad if r['alreadyNonzeroAtFirstSnapshot']],copyCoverageLosses=[ref(r)|{k:r[k] for k in ('status','reason') if k in r} for r in losses[:128]],
            argSemantics='vendor/vkd3d-proton-212991fc2c266bc0d59f4c4ce8f80f7126508d71/libs/vkd3d/vkd3d_forensics.h; actual body elapsed comes from end args[3], body-start args[7]; raw args preserved',
            limits='Only guest software timing and observed user-stage overlap; FIFO workKey association is not a unique submission ticket. No implicit host-process/thread/pipeline mapping or exclusive slow-frame attribution',allCausesFound=False)

    def forensics_report(self):
        from analyze_causal_diagnostics import analyze as analyze_causal_diagnostics
        from analyze_native_sync import analyze as analyze_native_sync
        native_id_runs=defaultdict(set)
        for raw in self.forensic_rows:
            if str(raw.get('kind','')).startswith('NativeCB'):
                cbid=raw.get('fields',{}).get('ownerNativeCB')
                if cbid:native_id_runs[(self._pid_for(raw),cbid)].add(raw.get('runID'))
        anchors=defaultdict(list)
        for row in self.forensic_rows:
            if row.get('type')!='clockCalibration':continue
            before,after,cf=dec(row.get('machBeforeNS')),dec(row.get('machAfterNS')),dec(row.get('timeCF'))
            if row.get('clockDomain')!='mach-absolute-nanoseconds' or None in (before,after,cf) or after<before:
                self.issue('forensics-clock-invalid',scope='forensics',**ref(row));continue
            anchors[(self._pid_for(row),row.get('runID'))].append(dict(mid=(before+after)/2,cf=cf,ca=dec(row.get('timeCA')),
                bound=(after-before)/2,session=row.get('session'),source=ref(row)))
        categories={'d3d12-entry':('d3d12','guest','entry'), 'shader-pipeline-cache':('shader','pipeline','compile','archive'),
                    'resource-heap-descriptors':('resource','heap','descriptor','residency'),
                    'queue-sync':('queue','submit','wait','signal','barrier'), 'draw-dispatch':('draw','dispatch','geometry'),
                    'presentation':('present','drawable'), 'coarse-gpu-timeline':('gpu_cb_completed','nativecb')}
        stages={key:dict(observed=0,clockUnjoinable=0,contextUnjoinable=0) for key in categories}
        records=[];kinds=Counter();seen=set();capped=False;sequences=defaultdict(set)
        coarse_cbs={};coarse_presents=[];scope_starts={};slow_scopes=[];scope_total=0;scope_unpaired_end=0;scope_start_cap=False;coarse_cap=False
        for row in self.forensic_rows:
            if row.get('type')!='forensics':continue
            pid=self._pid_for(row);run=row.get('runID');seq=row.get('seq');key=(pid,run,seq)
            if run is None or seq is None:key=(pid,run,ref(row).get('source'),ref(row).get('line'))
            if key in seen:continue
            seen.add(key);kind=str(row.get('kind','unknown'));kinds[kind]+=1
            if isinstance(seq,int):sequences[(pid,run)].add(seq)
            clock=dec(row.get('machNS'));available=anchors.get((pid,run),[])
            physical=row.get('streamSession') if row.get('streamOwnershipSchema')==2 else row.get('session')
            matching=[a for a in available if a['session']==physical]
            anchor=min(matching,key=lambda a:abs(a['mid']-clock)) if matching and clock is not None and row.get('schema')==1 else None
            cf=anchor['cf']+(clock-anchor['mid'])/NS if anchor else None
            ctx=row.get('context',{}) if isinstance(row.get('context'),dict) else {}
            fields=row.get('fields',{}) if isinstance(row.get('fields'),dict) else {};payload=row.get('payload',{}) if isinstance(row.get('payload'),dict) else {}
            owner_names={'nativeCB':('ownerNativeCB',),'logicalSubmit':('ownerSubmission','ownerSubmit'),'frame':('ownerFrame',),'queueFamily':('ownerQueueFamily','ownerFamily'),'queueIndex':('ownerQueueIndex','ownerIndex'),'shader':('ownerShader',)}
            owner={key:next((fields[name] for name in names if name in fields),None) for key,names in owner_names.items()}
            # Encoding may split to a different ambient CB before an earlier
            # encoder scope is emitted. Saved owner fields win, including0.
            has_owner='ownerNativeCB' in fields
            native=integer(owner['nativeCB'] if has_owner else ctx.get('nativeCB'))
            logical=integer(owner['logicalSubmit'] if has_owner else ctx.get('logicalSubmit'))
            run_validated=native_id_runs.get((pid,native))=={run}
            joined=bool(run_validated and native and logical and (pid,native) in self.cbs and integer(self.cbs[(pid,native)].get('logicalSubmit'))==logical)
            if any(t in kind.lower() for t in ('denied','dropped','truncated')) or any(re.search(r'(dropped|truncated|denied|overflow)$',k,re.I) and integer(v)>0 for k,v in fields.items()):capped=True
            pipeline=fields.get('pipeline',fields.get('vulkanPipeline',payload.get('ownerPipeline')))
            record=dict(pid=pid,runID=run,session=row.get('session'),streamSession=physical,streamOwnershipSchema=row.get('streamOwnershipSchema',1),seq=seq,kind=kind,machNS=row.get('machNS'),timeCF=cf,
                clockStatus='observed' if cf is not None else 'unjoinable',
                calibrationBracketHalfNS=anchor['bound'] if anchor else None,
                calibrationSessionMatched=bool(anchor and anchor['session']==physical),
                lateLogicalOwner=physical!=row.get('session'),
                context={k:ctx.get(k) for k in ('domain','queueFamily','queueIndex','logicalSubmit','nativeCB','frame','shader')},
                savedOwnerContext=owner if has_owner else None,linkedNativeCB=native,linkedLogicalSubmit=logical,linkContextSource='saved-owner-fields' if has_owner else 'ambient-context',
                pipeline=pipeline,nativePipeline=fields.get('nativePipeline'),threadMachID=row.get('threadMachID'),nativeGraphJoined=joined,nativeGraphRunValidated=run_validated,fields=fields,payload=payload,source=ref(row),
                meaning='Software observation, not exclusive GPU/shader duration or proven cause of a frame stall')
            if available and not matching:
                self.issue('forensics-clock-session-mismatch',scope='forensics',runID=run,session=row.get('session'))
            if 'spanID' in fields and fields.get('phase') in (0,1):
                scope_key=(pid,run,fields['spanID'])
                if fields['phase']==0:
                    if len(scope_starts)<16384:scope_starts[scope_key]=ref(row)
                    else:scope_start_cap=True
                else:
                    begin=scope_starts.pop(scope_key,None);scope_total+=1;scope_unpaired_end+=begin is None
                    item=dict(kind=kind,pid=pid,runID=run,fields=fields,sourceBegin=begin,sourceEnd=ref(row),endCF=cf,
                        elapsedWallNS=integer(fields.get('elapsedWallNS')),pairedBeginObserved=begin is not None,
                        meaning='Software wall span with saved owner fields; not exclusive thread CPU or GPU duration')
                    entry=(item['elapsedWallNS'],scope_total,item)
                    if len(slow_scopes)<500:heapq.heappush(slow_scopes,entry)
                    elif entry[:2]>slow_scopes[0][:2]:heapq.heapreplace(slow_scopes,entry)
            cbid=integer(fields.get('ownerNativeCB'))
            if kind.startswith('NativeCB') and cbid:
                cbkey=(pid,run,cbid)
                if cbkey in coarse_cbs or len(coarse_cbs)<20000:
                    cb=coarse_cbs.setdefault(cbkey,dict(pid=pid,runID=run,nativeCB=cbid,phases={},fields={}))
                    cb['phases'][kind]=dict(timeCF=cf,source=ref(row));cb['fields'].update(fields)
                    for key in ('gpuStartCANS','gpuEndCANS','createdCANS','committedCANS'):
                        if integer(fields.get(key)) and anchor and anchor['ca'] is not None:cb[key[:-4]+'CF']=D(integer(fields[key]))/NS+anchor['cf']-anchor['ca']
                else:coarse_cap=True
            if kind=='NativePresentedFrame':
                timestamp=integer(fields.get('nativeTimestampCANS'));mapped=D(timestamp)/NS+anchor['cf']-anchor['ca'] if timestamp and fields.get('nativeTimestampValid') and anchor and anchor['ca'] is not None else None
                if len(coarse_presents)<10000:coarse_presents.append(dict(pid=pid,runID=run,nativeTimestampCF=mapped,fields=fields,source=ref(row)))
                else:coarse_cap=True
            for name,tokens in categories.items():
                if any(token in kind.lower() for token in tokens):
                    stages[name]['observed']+=1;stages[name]['clockUnjoinable']+=cf is None;stages[name]['contextUnjoinable']+=not joined
            if len(records)<2000:records.append(record)
        losses=[r for r in self.forensic_copy_index if r.get('status') in ('missing','capped','unjoinable')]
        budgets=cumulative_counter_windows(self.forensic_current,('dropped','IOFailures','serializationFailures','lowDiskDrops'),'pid')
        capped=capped or any(r['observedDelta'] for r in budgets) or any(r.get('status')=='capped' for r in losses)
        sequence_gaps=[]
        for (pid,run),values in sequences.items():
            values=sorted(values)
            gaps=[dict(after=a,before=b,missing=b-a-1) for a,b in zip(values,values[1:]) if b>a+1]
            if gaps:sequence_gaps.append(dict(pid=pid,runID=run,ranges=gaps[:32],missing=sum(g['missing'] for g in gaps)))
        matrix=[]
        input_gaps=[r for r in self.issues if r['code'] in ('input-json-invalid','source-unavailable','source-mutated-during-read','input-byte-cap','input-row-cap') and 'forensics-' in r.get('source','') and 'vkd3d-forensics' not in r.get('source','')]
        for name,values in stages.items():
            statuses=['observed'] if values['observed'] else ['missing']
            if values['clockUnjoinable'] or values['contextUnjoinable']:statuses.append('unjoinable')
            if capped:statuses.append('capped')
            if (losses or sequence_gaps or input_gaps) and 'missing' not in statuses:statuses.append('missing')
            matrix.append(dict(stage=name,statuses=statuses,**values,
                scope='Provided software events only; missing/unclocked/unjoined records are not attributed exclusively to slow frames'))
        matrix += [dict(stage='thread-counter-to-native-thread',statuses=['unjoinable'],reason='PROC_PIDLISTTHREADS pthread/opaque handles have no measured mapping to native threadMachID; numeric equality or names are not a join'),
                   dict(stage='forensics-writer-health',statuses=(['observed'] if self.forensic_current else ['missing'])+(['capped'] if any(r['observedDelta'] for r in budgets) else [])+(['unjoinable'] if any(r['alreadyNonzeroAtFirstSnapshot'] or r['nonmonotonic'] for r in budgets) else []),reason='Run-cumulative metadata deltas; pre-first-snapshot losses are an unknown prefix'),
                   dict(stage='closed-driver-internals',statuses=['missing','unjoinable'],reason='Public coarse native timelines can contain waits. Private driver scheduler/compiler internals and exclusive shader execution costs are unknown')]
        return dict(available=bool(kinds),clockDomain='mach-absolute-nanoseconds; never C++ steady-clock subtraction',
            causalDiagnostics=analyze_causal_diagnostics(self.forensic_rows,self.cbs),
            syncDiagnostics=analyze_native_sync(self.forensic_rows),
            stageMatrix=matrix,kinds=dict(kinds),records=records,recordsTruncated=sum(kinds.values())>len(records),
            recordsDisplayLimit=2000,structuredSummariesProcessAllParsedRows=True,
            recordsDisplayLimitIsNotWriterLoss=True,
            slowSoftwareScopes=[item for _,_,item in sorted(slow_scopes,reverse=True)],softwareScopeCount=scope_total,softwareScopeRankingCapped=scope_total>len(slow_scopes),unpairedSoftwareScopeEnds=scope_unpaired_end,openSoftwareScopes=len(scope_starts),softwareScopePairingCap=scope_start_cap,
            coarseCommandBuffers=list(coarse_cbs.values()),coarsePresents=coarse_presents,coarseTimelineOutputCapped=coarse_cap,
            coarseTimelineLimits='Actual per-CB/public present observations only; callback observation time is not substituted for native CA timestamps. Coarse CB intervals can contain waits and do not form a complete dependency graph.',
            copyCoverageLosses=[{k:v for k,v in r.items() if not k.startswith('_')} for r in losses[:128]],
            inputCoverageIssues=input_gaps,
            nativeCounterWindows=budgets,nativeCounterSessions=cumulative_counter_sessions(self.forensic_current,('dropped','IOFailures','serializationFailures','lowDiskDrops'),'pid'),nativeBudgetOrIOIssues=[r for r in budgets if r['observedDelta'] or r['nonmonotonic']],nativeCounterPrefixUnknown=[r for r in budgets if r['alreadyNonzeroAtFirstSnapshot']],sequenceGaps=sequence_gaps,allCausesFound=False)

    def report(self):
        self.build_native()
        self.build_cpu()
        for row in self.cpu_copy_index:
            if row.get('status') in ('capped','missing','unjoinable'):self.issue('cpu-current-copy-'+row['status'],scope='cpu',reason=row.get('reason'),**ref(row))
        clocks = self._clock_report()
        system = self.system_report()
        gpu = self.gpu_report()
        frames = self.frame_reports()
        forensics=self.forensics_report()
        guest=self.guest_report()
        memory=self.memory_report()
        for frame in frames:
            ids={r['nativeCB'] for r in frame['GPU']['commandBuffers']}
            matched=[r for r in forensics['records'] if r['pid']==frame['pid'] and r['nativeGraphJoined'] and
                     str(r['pid'])+':'+str(r['linkedNativeCB']) in ids]
            frame['Forensics']=dict(records=matched[:100],truncated=len(matched)>100,
                meaning='Shared software/native-CB context only; no aggregate/event is charged exclusively to a frame')
        path_gaps = sorted({r["code"] for r in self.issues if r["scope"] in ("native", "wait", "clock", "presentation", "global")})
        for frame in frames:
            frame["GPU"]["criticalPath"]["observedCoverageComplete"] = not path_gaps
            frame["GPU"]["criticalPath"]["coverageIssues"] = path_gaps
            cbids = {row["nativeCB"] for row in frame["GPU"]["commandBuffers"]}
            boundaries = []
            for artifact in gpu["artifacts"]:
                if (artifact["pid"] == frame["pid"] and str(artifact["pid"]) + ":" + str(artifact["nativeCBID"]) in cbids
                        and artifact["nativeGraphSessionMatched"] and artifact["nativeCommandBufferMatched"]):
                    for boundary in artifact["boundaryIntervals"]:
                        boundaries.append(dict(boundary, nativeCBID=artifact["nativeCBID"], logicalSubmit=artifact["logicalSubmissionID"],
                                               split=artifact["nativeSplitIndex"], source=artifact["source"]))
            frame["GPUCounterBoundaryRanking"] = sorted(boundaries, key=lambda r: r["observedMs"], reverse=True)[:100]
        cpu_totals = defaultdict(lambda: dict(selfWallNS=0, count=0, samplingEvery=1,threadCPUCount=0,inclusiveThreadCPUNS=0))
        for row in self.cpu_aggregate:
            key = (row["domain"], row["stage"], row["name"], row["kind"])
            cpu_totals[key]["selfWallNS"] += row["selfWallNS"]
            cpu_totals[key]["count"] += row["count"]
            cpu_totals[key]['threadCPUCount']+=row.get('threadCPUCount',0)
            cpu_totals[key]['inclusiveThreadCPUNS']+=row.get('inclusiveThreadCPUNS',0)
            cpu_totals[key]["samplingEvery"]=max(cpu_totals[key]["samplingEvery"],row.get("samplingEvery",1))
        ranking = [dict(domain=k[0], stage=k[1], name=k[2], kind=k[3], selfWallNS=v["selfWallNS"],
                        selfWallMs=D(v["selfWallNS"]) / 1000000, count=v["count"],samplingEvery=v["samplingEvery"],sampled=v["samplingEvery"]>1,extrapolated=False,
                        threadCPUCount=v['threadCPUCount'],inclusiveThreadCPUNS=v['inclusiveThreadCPUNS'],threadCPUMeaning='Measured inclusive CPU samples only; not additive across nested stages') for k, v in cpu_totals.items()]
        ranking.sort(key=lambda r: r["selfWallNS"], reverse=True)
        matrix = []
        for scope, available, detail in (
            ("native", bool(self.cbs), "Native split IDs, logical submissions, enqueue/commit/scheduled/completed and per-queue/event-value DAG."),
            ("clock", bool(self.calibrations), "Sequential public CF/CA/monotonic anchors; no guaranteed calibration error bound."),
            ("cpu", bool(self.cpu_details), "Self-time-only phases per domain/submission, with first/last/mixed thread provenance, plus deduplicated report totals."),
            ("wait", bool(self.native_rows), "Encoded event-value dependencies and paired host waits; external producers remain unknown."),
            ("presentation", bool(self.presents), "Actual native timestamps where valid; callback time is never substituted for frame pacing."),
            ("system", bool(self.system_rows), "PID/start identity, threads, faults, memory/IO/pressure and graphics/compiler progress polls."),
            ("gpu-counters", bool(gpu["artifacts"]) or bool(gpu["nativeCommandBufferCoverage"]["knownCaptureCBs"]), "Optional paired-clock boundaries plus native per-CB skip/allocated/session/midCB checks within the known counter window; not an all-queue capture promise.")):
            problems = sorted({r["code"] for r in self.issues if r["scope"] in (scope, "global")})
            statuses=['observed'] if available else ['missing']
            if any(any(token in code for token in ('cap','drop','trunc','budget')) for code in problems):statuses.append('capped')
            if problems:statuses.append('unjoinable')
            matrix.append(dict(layer=scope, available=available, observedCoverageComplete=available and not problems,
                               statuses=statuses, issues=problems, detail=detail))
        matrix += [dict(layer='forensics:'+r['stage'],available=bool(r.get('observed')),observedCoverageComplete=False,
                        statuses=r['statuses'],detail=r.get('reason',r.get('scope'))) for r in forensics['stageMatrix']]
        matrix.append(dict(layer='guest-d3d12-entry',available=guest['available'],observedCoverageComplete=False,statuses=guest['statuses'],detail='Guest QPC/FILETIME software timeline; no implicit Windows/native PID or thread join'))
        resource_api_observed=bool(guest['resourceKindCounts'] or any(r['type']=='resourceAPICumulative' for r in guest['cumulativeStreams']))
        matrix.append(dict(layer='guest-resource-memory-map',available=resource_api_observed,observedCoverageComplete=False,statuses=(['observed','sampled','unjoinable'] if resource_api_observed else ['missing'])+(['capped'] if 'capped' in guest['statuses'] else []),detail='Kinds21–31 and run+operation+shard cumulative deltas; all offers vs1:64 timing kept separate; no exact full-CPU or closed-driver attribution'))
        if self.cpu_fine_sampling:matrix.append(dict(layer='cpu-fine-scopes',available=True,observedCoverageComplete=False,statuses=['observed']+(['sampled'] if any(integer(r.get('scopeSampleEvery'),1)>1 for r in self.cpu_fine_sampling) else []),detail='Measured completed timing samples only; no extrapolation or independent full-cost claim; unsampled child work remains in parent'))
        heap_observed=any(r.get('native',{}).get('heap-plan-stats') for r in self.system_rows)
        matrix.append(dict(layer='resource-heap-plan-stats',available=heap_observed,statuses=['observed'] if heap_observed else ['missing'],
            observedCoverageComplete=False,detail='Coarse counter snapshots only; never exclusive slow-frame cost'))
        matrix.append(dict(layer='cpu-history-archive',available=bool(self.cpu_status),observedCoverageComplete=False,statuses=(['observed'] if self.cpu_status else ['missing'])+(['capped'] if any(integer(r.get('historyRowsSkipped')) for r in self.cpu_status) else []),detail='Native history cap is separate from changed-current archives; current/status copy gaps and caps remain explicit'))
        matrix.append(dict(layer='native-memory-allocation-events',available=bool(self.memory_events or self.memory_snapshots),observedCoverageComplete=False,
            statuses=(['observed'] if self.memory_events or self.memory_snapshots else ['missing'])+(['unjoinable'] if memory['gaps'] or self.memory_unassigned else [])+(['capped'] if memory['outputRankingCapped'] else []),
            detail='Full bounded journals and recent snapshot rings; no durable allocation Begin or free/resident VRAM measurement. Process lifetime and overlapping omission counters remain explicit.'))
        return dict(schema=1, tool="analyze_stutter_capture.py", rawInputsPreserved=True,
                    targetPID=self.pid, targetFPS=self.target_fps, referenceCF=self.reference_cf,
                    allCausesFound=False,
                    conclusion="Ranks observed contributors only. Missing, disabled, capped, stale or unclocked paths remain explicit; no claim that every cause is captured.",
                    coverage=dict(complete=False, reason="Finite instrumentation does not prove all causes observed.",
                                  matrix=matrix, issueCounts=dict(self.issue_counts), issues=self.issues,
                                  issueListTruncated=len(self._issue_keys) > len(self.issues)),
                    clockCorrelation=clocks,
                    nativeGraph=dict(commandBuffers=len(self.cbs), edges=len(self.edges), hostWaits=len(self.host_waits),
                                     presents=len(self.presents), topologicallyOrderedNodes=len(self.topological),
                                     eventPhaseAliasesNormalized=dict(self.event_alias_counts),
                                     scope="captured nativeCB and event IDs in one PID, not a complete host/device scheduler trace"),
                    CPUPhaseRanking=ranking, CPUReportProvenance=self.cpu_report_provenance,
                    CPUHistoricalReportWindowsSkipped=self.cpu_historical_skipped,CPUHistoryStatus=[ref(r)|{k:v for k,v in r.items() if not k.startswith('_')} for r in self.cpu_status],CPUCurrentCopyIssues=self.cpu_copy_index,
                    CPUObservedSpans=self.cpu_spans,CPUObservedSpanOutputCapped=self.cpu_span_count>len(self.cpu_spans),
                    frames=frames, system=system, GPUCounterArtifacts=gpu, Forensics=forensics, GuestD3D12=guest, CPUFineScopeSampling=self.cpu_fine_sampling,
                    MemoryAllocations=memory,
                    foregroundContinuity=foreground_intervals(self.foreground),
                    requestedDiagnosticWindows=[{k:v for k,v in r.items() if not k.startswith('_')} for r in self.requested_windows],
                    inputs=self.sources, inputBytesRead=self.bytes_read, inputRowsRead=self.rows_read,
                    limitations=["CPU self wall time across threads can overlap GPU execution and other threads. Contributor columns must not be added into a frame budget.",
                                 "CPU aggregates use span-completion windows; crossing/mixed submission records cannot be split precisely per present.",
                                 "Public command-buffer GPU intervals and counter boundaries can contain waits; they do not identify an exclusive shader cost.",
                                 "An event value may have been produced outside the capture. Missing producer is incomplete coverage, not proof of deadlock.",
                                 "Native trace files contain PID but no process start identity; the system capture's PID+lstart+kernel start guard and overlapping clocks are needed.",
                                 "No game scene correctness, input response or sustained playable FPS is inferred from log coverage."])

    def memory_report(self):
        from analyze_memory_observations import analyze as analyze_memory
        result=analyze_memory(self.memory_events,self.memory_snapshots)
        result['unassignedTargetLifetimeRecords']=self.memory_unassigned[:128]
        result['unassignedTargetLifetimeCount']=len(self.memory_unassigned)
        result['unassignedOutputCapped']=len(self.memory_unassigned)>128
        result['sourcePolicy']='Full append-only journals/current snapshot read from the owned profile with source hashes; session loads require filename PID and observed kernel-start/Mach lifetime bounds. No event is inferred from scalar-only polling.'
        return result


def convert_gpu_clock(raw, pair, timebase):
    """Match the native paired-clock formula using Decimal, with no GPU-ns guess."""
    if not isinstance(pair, dict) or not pair.get("available"):
        return None, "paired-clock-unavailable"
    before, after = pair.get("before", {}), pair.get("after", {})
    domain = before.get("cpuDomain")
    if domain != after.get("cpuDomain") or domain not in ("mach-absolute-ticks", "nanoseconds"):
        return None, "cpu-clock-domain-unrecognized-or-mismatched"
    bcpu, acpu = integer(before.get("cpuRaw")), integer(after.get("cpuRaw"))
    bgpu, agpu = integer(before.get("gpuRaw")), integer(after.get("gpuRaw"))
    invalid = (1 << 64) - 1
    if min(bcpu, acpu, bgpu, agpu) <= 0 or max(bgpu, agpu, raw) >= invalid or acpu <= bcpu or agpu <= bgpu:
        return None, "paired-clock-nonpositive-or-nonmonotonic"
    if not bgpu <= raw <= agpu:
        return None, "sample-outside-calibration-bracket"
    if not isinstance(timebase, dict) or integer(timebase.get("numer")) <= 0 or integer(timebase.get("denom")) <= 0:
        return None, "explicit-mach-timebase-unavailable"
    with localcontext() as context:
        context.prec = 60
        ratio = D(integer(timebase["numer"])) / D(integer(timebase["denom"]))
        cpu = D(bcpu) + D(raw - bgpu) * D(acpu - bcpu) / D(agpu - bgpu)
        cpu_ns = cpu * ratio if domain == "mach-absolute-ticks" else cpu
        offsets = []
        uncertainties = []
        for anchor in (before, after):
            hbc, hac = dec(anchor.get("hostBeforeCA")), dec(anchor.get("hostAfterCA"))
            hb, ha = integer(anchor.get("hostBeforeMachTicks")), integer(anchor.get("hostAfterMachTicks"))
            if None in (hbc, hac) or ha < hb or hb <= 0 or hac < hbc:
                return None, "host-clock-bracket-invalid"
            cpu_value = D(integer(anchor.get("cpuRaw")))
            cpu_lo, cpu_hi = (D(hb), D(ha)) if domain == "mach-absolute-ticks" else (D(hb) * ratio, D(ha) * ratio)
            if not cpu_lo <= cpu_value <= cpu_hi:
                return None, "public-cpu-sample-outside-host-bracket"
            offsets.append((hbc + hac) / 2 - (D(hb) + D(ha)) / 2 * ratio / NS)
            uncertainties.append(max((hac - hbc) * NS, D(ha - hb) * ratio))
        result = cpu_ns / NS + sum(offsets) / 2
        return dict(timeCA=result, timeCAExactDecimal=str(result),
                    hostBracketUncertaintyNS=max(uncertainties),
                    convertedCAIsEstimate=True, hardwareClockAccuracyGuaranteed=False), None


def markdown(report):
    lines = ["# Stutter capture correlation", "", report["conclusion"], "",
             f"Target PID: {report['targetPID']}. Native CBs: {report['nativeGraph']['commandBuffers']}; "
             f"dependency edges: {report['nativeGraph']['edges']}; presents: {report['nativeGraph']['presents']}.", "",
             "| Layer | Available | Observed coverage |", "| --- | --- | --- |"]
    for row in report["coverage"]["matrix"]:
        lines.append(f"| {row['layer']} | {row['available']} | {'complete in observed scope' if row['observedCoverageComplete'] else 'incomplete'} |")
    lines += ["", "## Present intervals and observed contributors", "",
              "CPU self times, GPU intervals and wait/queue/presentation gaps overlap. Do not sum these columns.", "",
              "| Frame | Native interval ms | Highest observed contributor | ms |", "| --- | ---: | --- | ---: |"]
    for frame in report["frames"]:
        top = frame["observedContributors"][0]
        interval = f"{number(frame['intervalMs']):.3f}" if frame["intervalMs"] is not None else "unavailable"
        lines.append(f"| {frame['presentFrame']} | {interval} | {top['category']} | {number(top['observedMs']):.3f} |")
    lines += ["", "## CPU self-time ranking", "", "| Domain | Phase | Kind | Self ms |", "| ---: | --- | --- | ---: |"]
    for row in report["CPUPhaseRanking"][:25]:
        lines.append(f"| {row['domain']} | {row['name']} | {row['kind']} | {number(row['selfWallMs']):.3f} |")
    lines += ["", "## Coverage gaps", ""]
    lines += [f"- `{name}`: {count}" for name, count in sorted(report["coverage"]["issueCounts"].items())]
    lines += ["", "## Limits", ""] + ["- " + text for text in report["limitations"]]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-trace", type=Path, action="append", default=[])
    parser.add_argument("--cpu-report", type=Path, action="append", default=[])
    parser.add_argument("--system-capture", type=Path)
    parser.add_argument("--session-capture",type=Path)
    parser.add_argument("--guest-trace",type=Path,action="append",default=[])
    parser.add_argument("--guest-current",type=Path,action="append",default=[])
    parser.add_argument("--guest-copy-index",type=Path,action="append",default=[])
    parser.add_argument("--forensics-trace",type=Path,action="append",default=[])
    parser.add_argument("--forensics-current",type=Path,action="append",default=[])
    parser.add_argument("--forensics-copy-index",type=Path,action="append",default=[])
    parser.add_argument("--memory-events",type=Path,action="append",default=[])
    parser.add_argument("--memory-snapshot",type=Path,action="append",default=[])
    parser.add_argument("--gpu-artifact", type=Path, action="append", default=[])
    parser.add_argument("--gpu-clock-sidecar", type=Path, action="append", default=[])
    parser.add_argument("--pid", type=int)
    parser.add_argument("--target-fps", type=float, default=30)
    parser.add_argument("--freshness-seconds", type=float, default=15)
    parser.add_argument("--reference-cf", type=D)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.target_fps <= 0 or args.freshness_seconds < 0:
        parser.error("FPS must be positive and freshness must be nonnegative")
    out = args.output.resolve()
    if not any(out.is_relative_to(ROOT / name) for name in ("evidence", "build")):
        parser.error("Output must be a new owned evidence/ or build/ directory")
    if out.exists():
        parser.error("Output directory must not already exist; raw captures and prior reports are never overwritten")
    out.mkdir(parents=True)
    if args.self_test:
        # The test driver is a separate source under evidence, never production.
        import importlib.util
        test = ROOT / "evidence/stutter-analysis-20261025/test_analyze_stutter_capture.py"
        spec = importlib.util.spec_from_file_location("stutter_analysis_selftest", test)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        result = module.run_tests(out)
        print(json.dumps(json_ready(result), indent=2))
        return 0 if result["passed"] else 1
    analyzer = Analyzer(target_pid=args.pid, freshness_seconds=args.freshness_seconds, target_fps=args.target_fps)
    if args.session_capture:
        analyzer.load_session(args.session_capture)
    elif args.system_capture:
        analyzer.load_system(args.system_capture)
    analyzer.load_forensics(args.forensics_trace,args.forensics_current,args.forensics_copy_index)
    analyzer.load_guest(args.guest_trace,args.guest_current,args.guest_copy_index)
    analyzer.load_memory(args.memory_events,args.memory_snapshot)
    analyzer.load_native(args.native_trace)
    analyzer.load_cpu(args.cpu_report)
    analyzer.load_gpu(args.gpu_artifact, args.gpu_clock_sidecar)
    if args.reference_cf is not None:
        analyzer.reference_cf = args.reference_cf
    started = time.monotonic()
    result = analyzer.report()
    result["analysisSeconds"] = time.monotonic() - started
    dump(out / "summary.json", result)
    (out / "summary.md").write_text(markdown(result))
    print(json.dumps(json_ready(dict(summary=str(out / "summary.json"),
                                    frames=len(result["frames"]), allCausesFound=False,
                                    coverageIssueCounts=result["coverage"]["issueCounts"])), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
