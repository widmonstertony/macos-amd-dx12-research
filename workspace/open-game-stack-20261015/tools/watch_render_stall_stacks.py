#!/usr/bin/env python3
"""Bounded stack evidence for a human-launched, uniquely identified Shipping PID.

Only /usr/bin/sample sampling helpers are spawned. No game/Steam/Wine launch,
input, target signal, LLDB, or environment inspection is used. The explicit
continuous-native-forensics opt-in holds only its nonce-owned diagnostic markers.
Run only when explicitly authorized; importing this module starts no observer.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import resource
import re
import shutil
import stat
import subprocess
import time
import uuid

import capture_stutter_system as system
import capture_stutter_session as session

MIB = 1024 ** 2
DISK_RESERVE = 3 * 1024 ** 3
SAMPLE_SECONDS = 2
SAMPLE_INTERVAL_MS = 20
MIN_GAP_SECONDS = 15
MAX_SAMPLE_FILE = 16 * MIB
REQUEST_NAME = 'diagnostics.stack-request.json'
SLOT_MAX = 8 * MIB + 65536
CURRENT_MAX = 128 * 1024
RAW_BANK_MAX = 4 * SLOT_MAX + CURRENT_MAX + 65536


class StopWatch(Exception):
    def __init__(self, reason, **details):
        super().__init__(reason)
        self.reason, self.details = reason, details


class Runtime:
    """The live boundary; tests replace this object, including helper creation."""
    def __init__(self):
        self.kernel = system.Kernel()

    def monotonic(self):
        return time.monotonic()

    def clock(self):
        return system.stamp(self.kernel)

    def discover(self):
        return session.discover()

    def identity(self, pid):
        return system.identity(pid)

    def usage(self, pid):
        return self.kernel.usage(pid)

    def task(self, pid):
        return self.kernel.task(pid)

    def sleep(self, seconds):
        time.sleep(seconds)

    def free_bytes(self, path):
        return shutil.disk_usage(path).free

    def spawn_sample(self, argv, file_limit):
        # The hard file-size limit applies only in this owned child. stdout and
        # stderr are discarded; the sole retained sample output is -file.
        def cap_child_file():
            resource.setrlimit(resource.RLIMIT_FSIZE, (file_limit, file_limit))
        return subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                close_fds=True, preexec_fn=cap_child_file)


def shipping(record):
    return str(record.get('comm', '')).replace('\\', '/').lower().endswith('/sb-win64-shipping.exe')


def checked_identity(runtime, expected=None):
    """Require unique discovery and matching ps/kernel identities around a read."""
    found = runtime.discover()
    if not isinstance(found, list) or any(type(pid) is not int or pid <= 0 for pid in found):
        raise StopWatch('discovery-unavailable')
    if len(found) > 1:
        raise StopWatch('multiple-shipping-processes', pids=found)
    if not found:
        if expected is not None:
            raise StopWatch('target-exited-or-discovery-unavailable')
        return None
    pid = found[0]
    if expected and pid != expected['pid']:
        raise StopWatch('target-pid-changed', observedPID=pid)
    before = runtime.identity(pid)
    usage_before = runtime.usage(pid)
    after = runtime.identity(pid)
    usage_after = runtime.usage(pid)
    for item in (before, after):
        if (item.get('present') is not True or item.get('pid') != pid
                or not item.get('lstart') or not shipping(item)
                or any(flag in item.get('state', '') for flag in ('Z', 'X'))):
            raise StopWatch('target-identity-unavailable-or-exited')
    starts = [item.get('processStartAbstime') for item in (usage_before, usage_after)]
    if (not all(item.get('available') is True for item in (usage_before, usage_after))
            or any(type(value) is not int or value <= 0 for value in starts)
            or starts[0] != starts[1]
            or any(item.get('processExitAbstime', 0) for item in (usage_before, usage_after))
            or before['lstart'] != after['lstart']):
        raise StopWatch('target-kernel-start-unavailable-or-changed')
    identity = system.process_identity(after, starts[0])
    if expected and identity['key'] != expected['key']:
        raise StopWatch('target-process-identity-changed', observedIdentity=identity)
    if runtime.discover() != [pid]:
        raise StopWatch('target-discovery-changed-during-identity-check')
    clock = runtime.clock()
    ticks = clock.get('machAbsoluteTicks')
    tb = runtime.kernel.timebase
    if (type(ticks) is not int or ticks < starts[0]
            or not tb.get('numer') or not tb.get('denom')):
        raise StopWatch('target-start-clock-unjoinable')
    start_unix = clock['unixSeconds'] - (ticks - starts[0]) * tb['numer'] / tb['denom'] / 1e9
    return dict(identity, processStartUnixEstimate=start_unix)


class StackRequests:
    """Read a fixed tiny JSON whitelist file; never follow links or write it."""
    def __init__(self, path):
        self.path = Path(path)
        self.last = None

    def poll(self, *, prime=False):
        try:
            before = self.path.lstat()
        except FileNotFoundError:
            self.last = None
            return None
        except OSError:
            return dict(status='unavailable', reason='stack-request-stat-failed')
        key = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if key == self.last:
            return None
        self.last = key
        if not stat.S_ISREG(before.st_mode) or before.st_size > 1024:
            return dict(status='ignored', reason='stack-request-not-regular-or-over-1024-bytes')
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as handle:
                opened = os.fstat(handle.fileno())
                raw = handle.read(1025)
                after = os.fstat(handle.fileno())
            keys = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
            if keys(opened) != key or keys(after) != key or len(raw) != before.st_size:
                return dict(status='ignored', reason='stack-request-changed-during-read')
            value = json.loads(raw)
            if (not isinstance(value, dict) or set(value) != {'reason'}
                    or value['reason'] not in ('scene', 'stall')):
                return dict(status='ignored', reason='stack-request-outside-whitelist')
            return dict(status='baseline-only' if prime else 'requested', reason=value['reason'],
                        markerMtimeUnixNS=before.st_mtime_ns,
                        sha256=hashlib.sha256(raw).hexdigest(),
                        gameActionVerified=False)
        except (OSError, ValueError, UnicodeError):
            return dict(status='ignored', reason='stack-request-unreadable-or-invalid-json')


class Progress:
    """Track only named queue/memory file metadata, not shaders or payloads."""
    def __init__(self, trace, pid, process_start_unix):
        self.trace, self.pid = Path(trace), pid
        self.process_start_unix = process_start_unix
        self.last = None
        self.changed_at = None

    def poll(self, now, unix_now, stall_seconds):
        files = []
        try:
            with os.scandir(self.trace) as entries:
                for count, entry in enumerate(entries, 1):
                    if count > 100000:
                        raise OSError('bounded-directory-inventory-cap')
                    name = entry.name
                    if not (name == f'memory-current-{self.pid}.json'
                            or (name.startswith(f'queue-timing-current-{self.pid}-')
                                and name.endswith('.json'))):
                        continue
                    state = entry.stat(follow_symlinks=False)
                    if not stat.S_ISREG(state.st_mode):
                        raise OSError('progress-source-is-not-regular')
                    if state.st_mtime < self.process_start_unix - .2 or state.st_mtime > unix_now + 1:
                        raise OSError('progress-source-outside-target-lifetime-or-future')
                    files.append((name, state.st_dev, state.st_ino, state.st_size, state.st_mtime_ns))
                    if len(files) > 64:
                        raise OSError('progress-source-count-cap')
        except OSError as error:
            self.last = self.changed_at = None
            return dict(available=False, stalled=False, reason=str(error)[:160])
        files.sort()
        if not files:
            self.last = self.changed_at = None
            return dict(available=False, stalled=False, reason='no-existing-progress-source')
        if files != self.last:
            self.last, self.changed_at = files, now
        newest = max(item[-1] for item in files) / 1e9
        unchanged = max(0, now - self.changed_at)
        age = unix_now - newest
        return dict(available=True, sourceCount=len(files), newestMtimeUnixNS=max(x[-1] for x in files),
                    observedUnchangedSeconds=unchanged, newestMtimeAgeSeconds=age,
                    stalled=unchanged >= stall_seconds and age >= stall_seconds,
                    metadataSHA256=hashlib.sha256(json.dumps(files).encode()).hexdigest())


def continuous_paths(profile):
    """Require explicit config entries; no default path or CPU/GPU aliasing."""
    header = profile / 'game-trial-config.h'
    header_state = header.lstat()
    if not stat.S_ISREG(header_state.st_mode) or header_state.st_size > 65536:
        raise ValueError('bounded regular game-trial-config.h required')
    raw = header.read_bytes()
    text = raw.decode()
    paths = {}
    for role, env in session.ARM_ENV.items():
        found = re.findall(r'setenv\("' + env + r'",\s*("(?:\\.|[^"\\])*")', text)
        if len(found) != 1:
            raise ValueError('continuous mode requires one explicit ' + env)
        path = Path(json.loads(found[0]))
        if not path.is_absolute() or path.is_symlink():
            raise ValueError('absolute non-symlink arm paths required')
        path = session.owned(path)
        if path.parent != profile or path.suffix != '.arm':
            raise ValueError('arm paths must be .arm files directly in the selected profile')
        paths[role] = path
    if len(set(paths.values())) != 4:
        raise ValueError('continuous forensics/native arms must be separate from each other and CPU/GPU')
    return paths, hashlib.sha256(raw).hexdigest()


class NonceLease:
    """Hold only two marker files; retain original bytes/times once, refresh mtime."""
    def __init__(self, paths, runtime):
        self.paths, self.runtime = paths, runtime
        self.nonce = uuid.uuid4().hex
        self.held = {}
        self.closed = []

    @staticmethod
    def key(state):
        return state.st_dev, state.st_ino, state.st_size, state.st_mtime_ns

    def matches(self, path, item):
        try:
            state = path.lstat()
            if not stat.S_ISREG(state.st_mode) or (state.st_dev, state.st_ino) != item['inode']:
                return False
            if not item.get('rollback') and self.key(state) != item['key']:
                return False
            os.lseek(item['fd'], 0, os.SEEK_SET)
            value = os.read(item['fd'], 4097)
            return value in item['rollbackContents'] if item.get('rollback') else value == item['payload']
        except OSError:
            return False

    @staticmethod
    def write_all(fd, value):
        offset = 0
        while offset < len(value):
            count = os.write(fd, value[offset:])
            if count <= 0:
                raise OSError('short marker write')
            offset += count

    def responsibility(self, path, fd, role, payload, old, state, original):
        # Register BEFORE the first content/mtime mutation. A failed write can
        # leave any prefix over the original bytes; only those exact states on
        # the still-held inode are eligible for rollback, never an external nonce.
        item = dict(fd=fd, role=role, payload=payload, original=original,
                    inode=(state.st_dev, state.st_ino), key=self.key(state), rollback=True,
                    rollbackContents={payload[:n] + old[n:] for n in range(len(payload) + 1)} | {payload},
                    nextRefresh=self.runtime.monotonic() + (20 if role == 'native' else 60))
        self.held[path] = item
        return item

    def acquire(self):
        try:
            return self._acquire()
        except BaseException as error:
            self.close()
            if isinstance(error, OSError):
                raise StopWatch('marker-acquire-failed', error=type(error).__name__) from error
            raise

    def _acquire(self):
        for role in ('forensics', 'native'):
            path = self.paths[role]
            original = None
            fd = None
            created = False
            item = None
            try:
                try:
                    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    created = True
                except FileExistsError:
                    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
                payload = (json.dumps(dict(schema=1, owner='watch-render-stall-stacks',
                                           nonce=self.nonce, recorderPID=os.getpid(), role=role)) + '\n').encode()
                if created:
                    # os.stat(fd) establishes ownership immediately after the
                    # exclusive create, before subsequent fstat/flock may fail.
                    item = self.responsibility(path, fd, role, payload, b'', os.stat(fd), None)
                    fd = None
                handle = item['fd'] if item else fd
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                state = os.fstat(handle)
                if not stat.S_ISREG(state.st_mode) or state.st_size > 4096:
                    raise StopWatch('marker-not-bounded-regular-file', role=role)
                old = os.read(handle, 4097)
                if not created:
                    original = dict(bytesBase64=base64.b64encode(old).decode(), bytes=len(old),
                                    sha256=hashlib.sha256(old).hexdigest(), mode=stat.S_IMODE(state.st_mode),
                                    atimeNS=state.st_atime_ns, mtimeNS=state.st_mtime_ns,
                                    inode=state.st_ino, device=state.st_dev)
                    try:
                        old_value = json.loads(old)
                    except (ValueError, UnicodeError):
                        old_value = None
                    age = self.runtime.clock()['unixSeconds'] - state.st_mtime
                    if (age < 120 or (isinstance(old_value, dict) and old_value.get('nonce'))):
                        raise StopWatch('marker-other-live-or-nonce-owner', role=role)
                if self.key(path.lstat()) != self.key(state):
                    raise StopWatch('marker-changed-before-acquire', role=role)
                if item is None:
                    item = self.responsibility(path, fd, role, payload, old, state, original)
                    fd = None
                os.lseek(handle, 0, os.SEEK_SET)
                self.write_all(handle, payload)
                os.ftruncate(handle, len(payload))
                unix_ns = int(self.runtime.clock()['unixSeconds'] * 1e9)
                os.utime(handle, ns=(unix_ns, unix_ns))
                item['key'] = self.key(os.fstat(handle))
                item['rollback'] = False
            except (OSError, BlockingIOError) as error:
                raise StopWatch('marker-acquire-failed', role=role, error=type(error).__name__) from error
            finally:
                if fd is not None:
                    os.close(fd)
        return self.report()

    def report(self):
        return [dict(path=str(path), role=item['role'], nonce=self.nonce,
                     currentMtimeNS=item['key'][-1], sessionIdentity='marker mtime; separate per role',
                     refreshSeconds=20 if item['role'] == 'native' else 60,
                     original=item['original']) for path, item in self.held.items()]

    def refresh(self):
        refreshed = []
        for path, item in self.held.items():
            if not self.matches(path, item):
                raise StopWatch('marker-ownership-changed', role=item['role'])
            if self.runtime.monotonic() >= item['nextRefresh']:
                unix_ns = int(self.runtime.clock()['unixSeconds'] * 1e9)
                item['rollback'], item['rollbackContents'] = True, {item['payload']}
                os.utime(item['fd'], ns=(unix_ns, unix_ns))
                item['key'] = self.key(os.fstat(item['fd']))
                item['rollback'] = False
                item['nextRefresh'] = self.runtime.monotonic() + (20 if item['role'] == 'native' else 60)
                refreshed.append(dict(role=item['role'], mtimeNS=item['key'][-1]))
        return refreshed

    def close(self):
        for path, item in list(self.held.items()):
            restored = False
            try:
                if self.matches(path, item):
                    old = item['original']
                    if old is None:
                        path.unlink()
                    else:
                        raw = base64.b64decode(old['bytesBase64'])
                        os.lseek(item['fd'], 0, os.SEEK_SET)
                        self.write_all(item['fd'], raw)
                        os.ftruncate(item['fd'], len(raw))
                        os.fchmod(item['fd'], old['mode'])
                        os.utime(item['fd'], ns=(old['atimeNS'], old['mtimeNS']))
                    restored = True
            except OSError:
                pass
            finally:
                os.close(item['fd'])
            self.closed.append(dict(path=str(path), role=item['role'], restored=restored,
                                    reason='owned-nonce-restored' if restored else 'externally-changed-preserved'))
        self.held.clear()
        return self.closed


class RawTail:
    """Two bounded banks preserve the latest pre-stall/terminal forensic chain."""
    def __init__(self, trace, identity, evidence, free_bytes=None):
        self.trace, self.identity, self.evidence = Path(trace), identity, evidence
        self.signature = None
        self.next_bank = 0
        self.owned_paths = {0: [], 1: []}
        self.banks = {}
        self.free_bytes = free_bytes or (lambda path: shutil.disk_usage(path).free)

    def budget(self, bank):
        # Check before touching a prior bank. Do not credit deleted logical
        # bytes as disk space: sparse files or another writer can invalidate it.
        control = max(0, self.evidence.control_cap - self.evidence.control_written)
        free = self.free_bytes(self.evidence.out)
        if free - RAW_BANK_MAX - control < DISK_RESERVE:
            return 'skipped-disk-reserve'
        replaceable = sum(p.stat().st_size for p in self.owned_paths[bank] if p.is_file())
        if self.evidence.size() - replaceable + RAW_BANK_MAX + control > self.evidence.max_bytes:
            return 'skipped-output-quota'
        return None

    def read(self, path, cap):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as handle:
            before = os.fstat(handle.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_mtime < self.identity['processStartUnixEstimate'] - .2:
                raise OSError('source-outside-target-lifetime-or-not-regular')
            raw = handle.read(min(before.st_size, cap))
            after = os.fstat(handle.fileno())
        complete = raw[:raw.rfind(b'\n') + 1] if path.suffix == '.jsonl' else raw
        warnings = []
        if before.st_size > cap:
            warnings.append('source-truncated-to-bounded-copy')
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            warnings.append('live-source-changed-during-read')
        if len(complete) != len(raw):
            warnings.append('incomplete-jsonl-tail-preserved')
        return raw, dict(source=str(path), bytes=len(raw), sourceBytesAtOpen=before.st_size,
                         sourceBytesAfterRead=after.st_size, sourceMtimeUnixNS=before.st_mtime_ns,
                         sha256=hashlib.sha256(raw).hexdigest(), completePrefixBytes=len(complete),
                         completePrefixSHA256=hashlib.sha256(complete).hexdigest(),
                         incompleteTailBytes=len(raw) - len(complete), warnings=warnings)

    def freeze(self, reason):
        skipped = self.budget(self.next_bank)
        if skipped:
            return dict(status=skipped, reason=reason, priorBanksPreserved=True)
        pid = self.identity['pid']
        current = self.trace / f'forensics-current-{pid}.json'
        sources = []
        current_pair = None
        run = None
        warnings = []
        try:
            current_pair = self.read(current, CURRENT_MAX)
            value = json.loads(current_pair[0])
            if value.get('pid') == pid and type(value.get('runID')) is int:
                run = value['runID']
            else:
                warnings.append('current-pid-or-run-unjoinable')
        except (OSError, ValueError, UnicodeError):
            warnings.append('current-snapshot-missing-or-unreadable')
        if run is None:
            candidates = []
            try:
                with os.scandir(self.trace) as entries:
                    for count, entry in enumerate(entries, 1):
                        if count > 100000:
                            raise OSError('raw-inventory-cap')
                        match = re.fullmatch(fr'forensics-{pid}-(\d+)-([0-3])\.jsonl', entry.name)
                        if match and entry.stat(follow_symlinks=False).st_mtime >= self.identity['processStartUnixEstimate'] - .2:
                            candidates.append(int(match[1]))
                run = max(candidates) if candidates else None
            except OSError:
                warnings.append('raw-inventory-unavailable-or-capped')
        if run is not None:
            sources = [self.trace / f'forensics-{pid}-{run}-{slot}.jsonl' for slot in range(4)]
        signature = []
        for path in [current, *sources]:
            try:
                s = path.lstat()
                signature.append((path.name, s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns))
            except OSError:
                signature.append((path.name, None))
        if signature == self.signature:
            return dict(status='unchanged-not-copied', reason=reason, runID=run)
        skipped = self.budget(self.next_bank)
        if skipped:
            return dict(status=skipped, reason=reason, priorBanksPreserved=True)
        bank = self.next_bank
        folder = self.evidence.out / f'raw-tail-{bank}'
        folder.mkdir(exist_ok=True)
        for path in self.owned_paths[bank]:
            path.unlink(missing_ok=True)
        self.owned_paths[bank] = []
        records = []
        pairs = [(current, current_pair)] if current_pair is not None else []
        for path in sources:
            try:
                pairs.append((path, self.read(path, SLOT_MAX)))
            except OSError:
                warnings.append('slot-missing-or-unreadable:' + path.name)
        for path, (raw, record) in pairs:
            destination = folder / path.name
            destination.write_bytes(raw)
            self.owned_paths[bank].append(destination)
            records.append(dict(record, destination=str(destination)))
        result = dict(status='frozen-live-prefix', reason=reason, bank=bank, runID=run,
                      files=records, warnings=warnings,
                      nativeSessionEqualsForensicsSessionAssumed=False,
                      scope='Two replaceable owned banks only; sources are untouched, live suffix/rotation may be incomplete.')
        raw_index = (json.dumps(result, indent=2) + '\n').encode()
        if len(raw_index) > 65536:
            raise StopWatch('raw-index-budget')
        index = folder / 'copy-index.json'
        index.write_bytes(raw_index)
        self.owned_paths[bank].append(index)
        self.banks[bank] = result
        self.signature, self.next_bank = signature, 1 - bank
        return result


def fault_change(current, previous, now, previous_time, threshold_per_two_seconds, poll_interval):
    if (not current.get('available') or not previous or not previous.get('available')
            or type(current.get('faults')) is not int or type(previous.get('faults')) is not int):
        return dict(available=False, significant=False, reason='missing-raw-fault-counter-baseline')
    elapsed = now - previous_time
    raw = current['faults'] - previous['faults']
    if elapsed <= 0 or elapsed > poll_interval * 2.5 or raw < 0:
        return dict(available=False, significant=False, reason='counter-decreased-or-observation-gap',
                    rawDelta=raw, observedSeconds=elapsed)
    threshold = math.ceil(threshold_per_two_seconds * elapsed / 2)
    return dict(available=True, rawDelta=raw, observedSeconds=elapsed,
                thresholdAtObservedInterval=threshold, significant=raw >= threshold,
                interpretation='Raw task fault-counter change is only a stack-sampling trigger; no root cause or FPS inference.')


class Evidence:
    def __init__(self, out, max_bytes, raw_reserve=0):
        self.out, self.max_bytes = Path(out), max_bytes
        self.control_cap = min(2 * MIB, max_bytes // 4)
        self.summary_reserve = 64 * 1024
        self.control_written = 0
        self.raw_reserve = raw_reserve

    def size(self):
        return sum(path.stat().st_size for path in self.out.rglob('*') if path.is_file())

    def event(self, kind, **fields):
        raw = (json.dumps(dict(type=kind, **fields), separators=(',', ':')) + '\n').encode()
        if len(raw) > 32768 or self.control_written + len(raw) > self.control_cap - self.summary_reserve:
            raise StopWatch('control-output-cap')
        with (self.out / 'events.jsonl').open('ab') as handle:
            handle.write(raw)
        self.control_written += len(raw)

    def metadata(self, value):
        raw = (json.dumps(value, indent=2) + '\n').encode()
        if len(raw) > self.summary_reserve:
            raise StopWatch('metadata-output-cap')
        (self.out / 'metadata.json').write_bytes(raw)
        self.control_written += len(raw)

    def sample_capacity(self, disk_free):
        reserve = self.control_cap - self.control_written
        raw_used = sum(path.stat().st_size for path in self.out.glob('raw-tail-*/*') if path.is_file())
        reserve += max(0, self.raw_reserve - raw_used)
        available = self.max_bytes - self.size() - reserve
        if available < 65536:
            raise StopWatch('sample-output-quota')
        available = min(available, disk_free - DISK_RESERVE - reserve)
        if available < 65536:
            raise StopWatch('disk-reserve')
        return min(MAX_SAMPLE_FILE, available)

    def finish(self, summary):
        raw = (json.dumps(summary, indent=2) + '\n').encode()
        if len(raw) > self.summary_reserve or self.size() + len(raw) > self.max_bytes:
            raise RuntimeError('reserved summary budget exhausted')
        (self.out / 'summary.json').write_bytes(raw)


def validate(args):
    if not 1 <= args.max_bursts <= 8:
        raise ValueError('max-bursts must be 1..8')
    if not 0 < args.wait_seconds <= 600 or not 0 < args.max_seconds <= 1800:
        raise ValueError('wait-seconds must be <=600 and max-seconds <=1800')
    if not 1 <= args.interval <= 5 or not 12 <= args.stall_seconds <= 120:
        raise ValueError('interval must be 1..5 and stall-seconds must be 12..120')
    if not 1 <= args.fault_delta_per_2s <= 2**32 - 1:
        raise ValueError('fault-delta-per-2s must be positive and fit the raw counter')
    if not 4 <= args.max_output_mib <= 128:
        raise ValueError('max-output-mib must be 4..128')
    profile, out = session.owned(args.profile), session.owned(args.output)
    if not profile.is_dir() or not (profile / 'msl').is_dir():
        raise ValueError('existing owned profile/msl directory required')
    if out.exists() or out == profile or profile.is_relative_to(out):
        raise ValueError('output must be a new directory separate from the profile')
    if getattr(args, 'continuous_native_forensics', False):
        continuous_paths(profile)
        if args.max_output_mib * MIB < 2 * RAW_BANK_MAX + 3 * MIB:
            raise ValueError('continuous mode needs room for two raw-tail banks and control/sample reserve')
    return profile, out


class Watcher:
    def __init__(self, args, runtime, profile, evidence):
        self.args, self.runtime, self.profile, self.evidence = args, runtime, profile, evidence
        self.started = runtime.monotonic()
        self.deadline = self.started + args.max_seconds
        self.target = None
        self.bursts = []
        self.last_sample_end = None
        self.helper = None
        self.lease = None
        self.raw_tail = None
        self.sampling_exhausted = False
        self.last_raw_freeze = None

    def guard(self):
        if self.runtime.monotonic() >= self.deadline:
            raise StopWatch('whole-duration-cap')
        if self.runtime.free_bytes(self.evidence.out) < DISK_RESERVE:
            raise StopWatch('disk-reserve')
        if self.evidence.size() > self.evidence.max_bytes:
            raise StopWatch('output-cap')
        if self.lease:
            refreshed = self.lease.refresh()
            if refreshed:
                self.evidence.event('marker-lease-refreshed', clock=self.runtime.clock(), markers=refreshed)

    def cleanup_helper(self):
        # Only this exact Popen handle, created by spawn_sample, is ever signalled.
        helper, self.helper = self.helper, None
        if helper is None or helper.poll() is not None:
            return None
        helper.terminate()
        try:
            helper.wait(timeout=1)
            return 'terminated-owned-sample-helper'
        except subprocess.TimeoutExpired:
            helper.kill()
            helper.wait(timeout=1)
            return 'killed-owned-sample-helper'

    def sample(self, reason, trigger):
        self.guard()
        if len(self.bursts) >= self.args.max_bursts:
            raise StopWatch('burst-cap')
        if self.last_sample_end is not None and self.runtime.monotonic() - self.last_sample_end < MIN_GAP_SECONDS:
            raise StopWatch('internal-sample-gap-violation')
        checked_identity(self.runtime, self.target)
        try:
            capacity = self.evidence.sample_capacity(self.runtime.free_bytes(self.evidence.out))
        except StopWatch as error:
            if error.reason != 'sample-output-quota':
                raise
            self.sampling_exhausted = True
            self.evidence.event('sample-withheld', reason=error.reason, trigger=trigger,
                                rawTailReservePreserved=True)
            return False
        index = len(self.bursts) + 1
        path = self.evidence.out / f'stacks-{index:02d}-{reason}.txt'
        argv = ['/usr/bin/sample', str(self.target['pid']), '2', '20', '-file', str(path)]
        record = dict(index=index, reason=reason, trigger=trigger, requestedClock=self.runtime.clock(),
                      argv=argv, durationSecondsRequested=SAMPLE_SECONDS,
                      samplingIntervalMilliseconds=SAMPLE_INTERVAL_MS,
                      outputHardFileLimitBytes=capacity, targetIdentity=self.target,
                      targetIdentityChecksAreNotAtomicWithSampleAttach=True)
        self.bursts.append(record)
        self.evidence.event('sample-requested', **record)
        start = self.runtime.monotonic()
        stop_error = None
        try:
            self.helper = self.runtime.spawn_sample(argv, capacity)
            record['ownedHelperPID'] = self.helper.pid
            next_identity_check = start
            while self.helper.poll() is None:
                self.guard()
                if self.runtime.monotonic() >= next_identity_check:
                    checked_identity(self.runtime, self.target)
                    next_identity_check = self.runtime.monotonic() + 1
                if self.runtime.monotonic() - start >= SAMPLE_SECONDS + 6:
                    record['helperTimeout'] = True
                    break
                self.runtime.sleep(min(.25, max(0, self.deadline - self.runtime.monotonic())))
            record['exitCodeBeforeCleanup'] = self.helper.poll()
            checked_identity(self.runtime, self.target)
        except StopWatch as error:
            stop_error = error
            record['stoppedReason'] = error.reason
        except OSError as error:
            stop_error = StopWatch('sample-helper-failed', error=type(error).__name__)
            record['stoppedReason'] = stop_error.reason
        finally:
            record['cleanup'] = self.cleanup_helper()
            self.last_sample_end = self.runtime.monotonic()
            record['helperWallSeconds'] = self.last_sample_end - start
            record['finishedClock'] = self.runtime.clock()
            if path.is_file():
                record['outputBytes'] = path.stat().st_size
                digest = hashlib.sha256()
                with path.open('rb') as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                        digest.update(chunk)
                record['outputSHA256'] = digest.hexdigest()
            self.evidence.event('sample-finished', **record)
        if stop_error:
            raise stop_error
        return True

    def freeze_tail(self, reason):
        if self.raw_tail:
            now = self.runtime.monotonic()
            if (reason == 'automatic-stall-trigger' and self.last_raw_freeze is not None
                    and now - self.last_raw_freeze < MIN_GAP_SECONDS):
                return
            self.evidence.event('raw-tail-freeze', clock=self.runtime.clock(), **self.raw_tail.freeze(reason))
            self.last_raw_freeze = now

    def observe(self):
        if getattr(self.args, 'continuous_native_forensics', False):
            paths, digest = continuous_paths(self.profile)
            self.lease = NonceLease(paths, self.runtime)
            self.evidence.event('marker-lease-acquired', headerSHA256=digest, markers=self.lease.acquire(),
                                nativeSessionEqualsForensicsSessionAssumed=False)
        request = StackRequests(self.profile / REQUEST_NAME)
        baseline = request.poll(prime=True)
        if baseline:
            self.evidence.event('stack-request-baseline', **baseline)
        waiting_until = min(self.deadline, self.started + self.args.wait_seconds)
        progress = None
        previous_task = None
        previous_time = None
        pending = None
        while True:
            self.guard()
            now = self.runtime.monotonic()
            if self.target is None and now >= waiting_until:
                raise StopWatch('wait-for-unique-target-duration-cap')
            identity = checked_identity(self.runtime, self.target)
            if identity is None:
                self.evidence.event('waiting', clock=self.runtime.clock())
                self.runtime.sleep(min(self.args.interval, waiting_until - now))
                continue
            if self.target is None:
                self.target = identity
                progress = Progress(self.profile / 'msl', identity['pid'], identity['processStartUnixEstimate'])
                if self.lease:
                    self.raw_tail = RawTail(self.profile / 'msl', identity, self.evidence, self.runtime.free_bytes)
                self.evidence.event('target-identified', clock=self.runtime.clock(), identity=identity)
                self.sample('first-discovery', dict(kind='first-verified-unique-shipping-process'))
                if len(self.bursts) >= self.args.max_bursts:
                    raise StopWatch('burst-cap')
                continue
            clock = self.runtime.clock()
            task = self.runtime.task(identity['pid'])
            faults = fault_change(task, previous_task, now, previous_time,
                                  self.args.fault_delta_per_2s, self.args.interval)
            state = progress.poll(now, clock['unixSeconds'], self.args.stall_seconds)
            changed = request.poll()
            if changed:
                self.evidence.event('stack-request-observed', clock=clock, **changed)
                if changed['status'] == 'requested':
                    pending = changed  # Keep the latest external request through cooldown.
            self.evidence.event('observation', clock=clock, targetIdentityKey=identity['key'],
                                rawTaskFaults=task.get('faults') if task.get('available') else None,
                                faultChange=faults, progress=state)
            previous_task, previous_time = task, now
            ready = self.last_sample_end is None or now - self.last_sample_end >= MIN_GAP_SECONDS
            reason = 'request-' + pending['reason'] if ready and pending and not self.sampling_exhausted else None
            automatic = state['stalled'] and faults['significant']
            if automatic:
                self.freeze_tail('automatic-stall-trigger')
            if not reason and ready and automatic and not self.sampling_exhausted:
                reason = 'progress-stall-fault-surge'
            if reason:
                trigger = dict(request=pending, progress=state, faultChange=faults)
                self.sample(reason, trigger)
                pending = previous_task = previous_time = None
                if len(self.bursts) >= self.args.max_bursts:
                    raise StopWatch('burst-cap')
            self.runtime.sleep(min(self.args.interval, max(0, self.deadline - self.runtime.monotonic())))


def run(args, runtime=None):
    profile, out = validate(args)
    out.mkdir(parents=True, exist_ok=False)
    raw_reserve = 2 * RAW_BANK_MAX if getattr(args, 'continuous_native_forensics', False) else 0
    evidence = Evidence(out, args.max_output_mib * MIB, raw_reserve)
    runtime = runtime or Runtime()
    watcher = Watcher(args, runtime, profile, evidence)
    evidence.metadata(dict(schema=1, start=runtime.clock(), profile=str(profile),
                           limits=dict(maxBursts=args.max_bursts, sampleSeconds=2, sampleIntervalMilliseconds=20,
                                       minimumGapAfterPreviousHelperSeconds=MIN_GAP_SECONDS,
                                       maxOutputBytes=evidence.max_bytes, diskReserveBytes=DISK_RESERVE,
                                       waitSeconds=args.wait_seconds, wholeSeconds=args.max_seconds,
                                       stallSeconds=args.stall_seconds, faultDeltaPerTwoSeconds=args.fault_delta_per_2s),
                           continuousNativeForensics=getattr(args, 'continuous_native_forensics', False),
                           rawTailReservedBytes=raw_reserve,
                           stackRequest=dict(path=str(profile / REQUEST_NAME), format={'reason': 'scene|stall'},
                                             preexistingRequestIsBaselineOnly=True),
                           gameLaunchStopOrInputUsed=False, targetSignalsUsed=False, LLDBUsed=False,
                           sampleInterpretation='Stacks and fault deltas are diagnostic observations, not FPS or a root-cause verdict.'))
    reason, details = 'unknown', {}
    try:
        watcher.observe()
    except StopWatch as error:
        reason, details = error.reason, error.details
    except KeyboardInterrupt:
        reason = 'observer-interrupted'
    except Exception as error:
        reason, details = 'observer-error', dict(error=type(error).__name__, message=str(error)[:200])
    finally:
        cleanup = watcher.cleanup_helper()
        raw_tail_error = None
        try:
            watcher.freeze_tail('observer-terminal:' + reason)
        except (OSError, StopWatch) as error:
            raw_tail_error = str(error)[:200]
        markers = watcher.lease.close() if watcher.lease else []
    summary = dict(schema=1, end=runtime.clock(), stopReason=reason, stopDetails=details,
                   targetIdentity=watcher.target, bursts=watcher.bursts, finalCleanup=cleanup,
                   continuousMarkerCleanup=markers, rawTailFreezeError=raw_tail_error,
                   rawTailBanks=watcher.raw_tail.banks if watcher.raw_tail else {},
                   observerElapsedSeconds=runtime.monotonic() - watcher.started,
                   gameLaunchStopOrInputUsed=False, targetSignalsUsed=False, LLDBUsed=False,
                   onlySpawnedSamplingHelper='/usr/bin/sample', gameOrSteamRestartAttempted=False,
                   allCausesFound=False, diagnosticOverheadNotSubtracted=True,
                   limits=['Identity checks bracket observations and sampling; sample attaches by PID, so checks are not atomic with OS attachment.',
                           'Missing or event-driven progress timestamps do not alone prove a renderer hang. Automatic bursts require observed unchanged progress plus a significant raw fault delta.',
                           'A raw fault-counter delta only triggers sampling; it does not identify paging, memory pressure, or another root cause.',
                           'Sampling can affect the observed process. Stack frequency and observer cost are not FPS.',
                           'Only the owned sample helper handle may be terminated; target disappearance, identity changes, or multiple Shipping processes stop this watcher.'])
    summary['outputBytesBeforeSummary'] = evidence.size()
    evidence.finish(summary)
    return summary


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--profile', type=Path, required=True)
    result.add_argument('--output', type=Path, required=True, help='New owned evidence directory; never an existing capture.')
    result.add_argument('--wait-seconds', type=float, default=600)
    result.add_argument('--max-seconds', type=float, default=1800)
    result.add_argument('--interval', type=float, default=2)
    result.add_argument('--max-bursts', type=int, default=8)
    result.add_argument('--stall-seconds', type=float, default=12)
    result.add_argument('--fault-delta-per-2s', type=int, default=100000)
    result.add_argument('--max-output-mib', type=int, default=128)
    result.add_argument('--continuous-native-forensics', action='store_true',
                        help='Opt in to owned forensics/native nonce markers only; native/GPU arms must be separate.')
    return result


if __name__ == '__main__':
    arguments = parser().parse_args()
    try:
        result = run(arguments)
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
    print(json.dumps(dict(output=str(arguments.output), stopReason=result['stopReason'],
                          bursts=len(result['bursts'])), indent=2))
