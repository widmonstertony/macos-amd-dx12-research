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
import json
from pathlib import Path
import re
import time

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
            pid = re.search(r"(?:stutter-native|cpu-stutter(?:-current)?|gpu-counter-clock-sessions|trace-gpu-timestamps)-(\d+)", path.name)
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
        if (directory / "foreground.jsonl").exists():
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
            stage_info = {}
            for row in report.get("rows", []):
                stage_info[(integer(row.get("domain")), integer(row.get("stage")))] = (row.get("name", "unknown"), row.get("kind", "unknown"))
                self.cpu_aggregate.append(dict(pid=pid, domain=integer(row.get("domain")), stage=integer(row.get("stage")),
                                               name=row.get("name", "unknown"), kind=row.get("kind", "unknown"),
                                               selfWallNS=integer(row.get("selfWallNS")), inclusiveWallNS=integer(row.get("inclusiveWallNS")),
                                               count=integer(row.get("count")), report=ref(report),
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
                                                  count=integer(phase.get("count")), failures=integer(phase.get("failures"))))
                self.cpu_details.append(detail)
        if not self.cpu_details:
            self.issue("cpu-submission-detail-unavailable", scope="cpu")

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
            phases = defaultdict(lambda: dict(selfWallNS=0, inclusiveWallNS=0, count=0, failures=0))
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
        return dict(windowCF=[lo_cf, hi_cf], exactInsidePolls=len(selected),
                    pollReferences=[ref(r) for r in selected], neighboringPollReferences=[ref(r) for r in surrounding],
                    foregroundSamples=[{k: r.get(k) for k in ("time", "pid", "alive", "active", "frontmostPID", "visible", "pointWidth", "pointHeight")} for r in front],
                    lastForegroundObservation=latest_state,
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
                                            resourceUse=native.get("resource-use-current")))
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

    def report(self):
        self.build_native()
        self.build_cpu()
        clocks = self._clock_report()
        system = self.system_report()
        gpu = self.gpu_report()
        frames = self.frame_reports()
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
        cpu_totals = defaultdict(lambda: dict(selfWallNS=0, count=0))
        for row in self.cpu_aggregate:
            key = (row["domain"], row["stage"], row["name"], row["kind"])
            cpu_totals[key]["selfWallNS"] += row["selfWallNS"]
            cpu_totals[key]["count"] += row["count"]
        ranking = [dict(domain=k[0], stage=k[1], name=k[2], kind=k[3], selfWallNS=v["selfWallNS"],
                        selfWallMs=D(v["selfWallNS"]) / 1000000, count=v["count"]) for k, v in cpu_totals.items()]
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
            matrix.append(dict(layer=scope, available=available, observedCoverageComplete=available and not problems,
                               issues=problems, detail=detail))
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
                    CPUHistoricalReportWindowsSkipped=self.cpu_historical_skipped,
                    frames=frames, system=system, GPUCounterArtifacts=gpu,
                    inputs=self.sources, inputBytesRead=self.bytes_read, inputRowsRead=self.rows_read,
                    limitations=["CPU self wall time across threads can overlap GPU execution and other threads. Contributor columns must not be added into a frame budget.",
                                 "CPU aggregates use span-completion windows; crossing/mixed submission records cannot be split precisely per present.",
                                 "Public command-buffer GPU intervals and counter boundaries can contain waits; they do not identify an exclusive shader cost.",
                                 "An event value may have been produced outside the capture. Missing producer is incomplete coverage, not proof of deadlock.",
                                 "Native trace files contain PID but no process start identity; the system capture's PID+lstart+kernel start guard and overlapping clocks are needed.",
                                 "No game scene correctness, input response or sustained playable FPS is inferred from log coverage."])


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
    if args.system_capture:
        analyzer.load_system(args.system_capture)
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
