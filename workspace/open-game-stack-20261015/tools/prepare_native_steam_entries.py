#!/usr/bin/env python3
"""Prepare native Steam entries offline; never install or launch during prepare.

The one qualified entry delegates to the existing Tencent/Steam launch tool.
Other disk games remain inventory-only until normal Windows Steam discovery.
All writes, including binary shortcuts merges and backups, stay in this repo.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import struct
import subprocess
import sys
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
DISK = Path('/Volumes/Applications/Program Files (x86)/Steam/steamapps')
DEFAULT_PROOF = ROOT / 'evidence/pending-native-binary-archive-signed.json'
STELLAR = '3489700'
ENTRY_NAME = 'Stellar Blade (YYB)'


def workspace_path(path: Path) -> Path:
    path = path.expanduser().resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError('Output and offline merge files must stay inside this project')
    return path


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes, expected: bytes | None = None) -> None:
    path = workspace_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if expected is not None and (not path.exists() or path.read_bytes() != expected):
        raise ValueError('Offline destination changed; no overwrite performed')
    fd, temp = tempfile.mkstemp(prefix=path.name + '.', suffix='.next', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


@dataclass
class Node:
    kind: int
    key: bytes
    value: bytes = b''
    children: list['Node'] = field(default_factory=list)
    raw: bytes = b''


def decode_vdf(data: bytes) -> list[Node]:
    """Keep every original record's bytes; reject formats not understood."""
    if len(data) > 16 * 1024 * 1024:
        raise ValueError('Offline shortcuts file is unexpectedly large')
    pos = 0
    count = 0

    def cstring() -> bytes:
        nonlocal pos
        end = data.find(b'\0', pos)
        if end < 0:
            raise ValueError('Truncated binary VDF string')
        value = data[pos:end]
        pos = end + 1
        return value

    def nodes(depth: int) -> list[Node]:
        nonlocal pos, count
        if depth > 16:
            raise ValueError('Unexpected binary VDF depth')
        result = []
        while pos < len(data):
            begin = pos
            kind = data[pos]
            pos += 1
            if kind == 8:
                return result
            key = cstring()
            count += 1
            if count > 100000:
                raise ValueError('Unexpected binary VDF record count')
            children: list[Node] = []
            value = b''
            if kind == 0:
                children = nodes(depth + 1)
            elif kind == 1:
                value = cstring()
            elif kind in (2, 3, 4, 6, 7, 10):
                size = 8 if kind in (7, 10) else 4
                if pos + size > len(data):
                    raise ValueError('Truncated binary VDF scalar')
                value = data[pos:pos + size]
                pos += size
            else:
                raise ValueError(f'Unsupported binary VDF field type {kind}; original retained')
            result.append(Node(kind, key, value, children, data[begin:pos]))
        raise ValueError('Missing binary VDF object terminator')

    result = nodes(0)
    if pos != len(data):
        raise ValueError('Trailing binary VDF data; original retained')
    return result


def encode_node(node: Node) -> bytes:
    if node.raw:
        return node.raw
    head = bytes([node.kind]) + node.key + b'\0'
    if node.kind == 0:
        return head + b''.join(encode_node(c) for c in node.children) + b'\x08'
    return head + node.value + (b'\0' if node.kind == 1 else b'')


def text_node(key: str, value: str) -> Node:
    return Node(1, key.encode(), value.encode('utf-8'))


def int_node(key: str, value: int) -> Node:
    return Node(2, key.encode(), struct.pack('<I', value))


def shortcut_node(index: int, app: Path) -> Node:
    executable = '"' + str(app / 'Contents/MacOS/launcher') + '"'
    appid = zlib.crc32((executable + ENTRY_NAME).encode()) | 0x80000000
    return Node(0, str(index).encode(), children=[
        int_node('appid', appid), text_node('AppName', ENTRY_NAME),
        text_node('Exe', executable), text_node('StartDir', '"' + str(app.parent) + '"'),
        text_node('icon', ''), text_node('ShortcutPath', ''), text_node('LaunchOptions', ''),
        int_node('IsHidden', 0), int_node('AllowDesktopConfig', 1),
        int_node('AllowOverlay', 0), int_node('OpenVR', 0), int_node('Devkit', 0),
        text_node('DevkitGameID', ''), int_node('DevkitOverrideAppID', 0),
        int_node('LastPlayTime', 0), Node(0, b'tags', children=[text_node('0', 'YYB / open-game-stack')])])


def merge_shortcuts(original: bytes, app: Path) -> tuple[bytes, bool]:
    doc = decode_vdf(original)
    candidates = [n for n in doc if n.kind == 0 and n.key.lower() == b'shortcuts']
    if len(candidates) != 1:
        raise ValueError('Expected exactly one shortcuts object; original retained')
    shortcuts = candidates[0]
    indexes = [int(c.key) for c in shortcuts.children if c.key.isdigit()]
    addition = shortcut_node(max(indexes, default=-1) + 1, app)
    fields = {n.key.lower(): n.value for n in addition.children}
    for item in shortcuts.children:
        existing = {n.key.lower(): n.value for n in item.children}
        if existing.get(b'exe') == fields[b'exe']:
            return original, False
        if existing.get(b'appid') == fields[b'appid']:
            raise ValueError('Shortcut appid collision; original retained')
    shortcuts.children.append(addition)
    shortcuts.raw = b''
    merged = b''.join(encode_node(n) for n in doc) + b'\x08'
    decode_vdf(merged)
    return merged, True


def offline_merge(source: Path, destination: Path, app: Path) -> dict:
    source, destination = workspace_path(source), workspace_path(destination)
    original = source.read_bytes()
    merged, added = merge_shortcuts(original, app)
    previous = destination.read_bytes() if destination.exists() else None
    if source != destination and previous is not None and previous != original:
        raise ValueError('Offline destination differs from input; choose a fresh destination')
    backup = destination.with_name(destination.name + '.before-' + digest(previous or original)[:16])
    baseline = previous if previous is not None else original
    if backup.exists() and backup.read_bytes() != baseline:
        raise ValueError('Backup path collision; no overwrite performed')
    if not backup.exists():
        atomic_write(backup, baseline)
    if source.read_bytes() != original:
        raise ValueError('Offline input changed; no merge performed')
    atomic_write(destination, merged, previous)
    return {'offlineDestination': str(destination), 'backup': str(backup),
            'added': added, 'originalSHA256': digest(original), 'mergedSHA256': digest(merged)}


def inventory() -> list[dict]:
    rows = []
    for manifest in sorted(DISK.glob('appmanifest_*.acf')):
        text = manifest.read_text(errors='replace')
        values = {}
        for key in ('appid', 'name', 'installdir'):
            found = re.search(r'"' + key + r'"\s+"([^\"]*)"', text)
            values[key] = found.group(1) if found else None
        if not values['appid'] or values['appid'] == '228980':
            continue
        rows.append({'appid': values['appid'], 'name': values['name'],
                     'path': str(DISK / 'common' / values['installdir']),
                     'entry': 'qualified-launch-chain' if values['appid'] == STELLAR else 'pending-normal-Steam-registration',
                     'playability': 'not-yet-qualified'})
    return rows


def validate_proof(path: Path) -> None:
    path = workspace_path(path)
    if not path.is_relative_to(ROOT / 'evidence'):
        raise ValueError('Qualification proof must be under evidence')
    proof = json.loads(path.read_text())
    deferred = proof['deferredRuntime']
    if not all(proof.get(k) for k in ('nativeRegressionPassed', 'originalTencentPresentationPassed', 'deferredGameGuardPassed')) or not deferred.get('presentationPassed'):
        raise ValueError('Qualification proof is incomplete')
    for key in ('proxy', 'candidate'):
        if digest(Path(deferred[key]).read_bytes()) != deferred[key + 'SHA256']:
            raise ValueError('Qualification proof no longer matches deployed libraries')


def bundle_plan(output: Path, proof: Path) -> dict:
    output, proof = workspace_path(output), workspace_path(proof)
    app = output / 'Stellar Blade YYB.app'
    return {'appName': ENTRY_NAME, 'appPath': str(app), 'proof': str(proof),
            'launchCommand': [sys.executable, str(ROOT / 'tools/launch_stellar_deferred_proxy.py'), '--proof', str(proof)],
            'coldSteamStartHelper': str(ROOT / 'tools/start_original_steam_for_candidate.py'),
            'installPerformed': False, 'SteamStarted': False, 'prefixChanged': False,
            'games': inventory()}


def prepare(output: Path, proof: Path, write: bool, merge_from: Path | None, merge_to: Path | None) -> dict:
    plan = bundle_plan(output, proof)
    if bool(merge_from) != bool(merge_to):
        raise ValueError('Provide both offline merge paths')
    if not write:
        return plan
    app = Path(plan['appPath'])
    if app.exists():
        raise ValueError('Prepared app already exists; choose a fresh output directory')
    app.mkdir(parents=True)
    try:
        plist = {'CFBundleName': ENTRY_NAME, 'CFBundleDisplayName': ENTRY_NAME,
                 'CFBundleIdentifier': 'org.opengamestack.yyb.stellarblade',
                 'CFBundleExecutable': 'launcher', 'CFBundlePackageType': 'APPL',
                 'CFBundleVersion': '1', 'LSMultipleInstancesProhibited': True,
                 'NSHighResolutionCapable': True}
        atomic_write(app / 'Contents/Info.plist', plistlib.dumps(plist))
        config = {'root': str(ROOT), 'proof': str(workspace_path(proof)), 'appid': STELLAR}
        atomic_write(app / 'Contents/Resources/entry.json', (json.dumps(config, indent=2) + '\n').encode())
        runner = '#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).resolve())) + ' run --config ' + shlex.quote(str(app / 'Contents/Resources/entry.json')) + ' "$@"\n'
        atomic_write(app / 'Contents/MacOS/launcher', runner.encode())
        (app / 'Contents/MacOS/launcher').chmod(0o755)
        atomic_write(workspace_path(output) / 'inventory-and-plan.json', (json.dumps(plan, ensure_ascii=False, indent=2) + '\n').encode())
        if merge_from:
            plan['offlineMerge'] = offline_merge(merge_from, merge_to, app)
    except Exception:
        # Leave concrete partial preparation for review, never remove user files.
        raise
    return plan


def canonical_steam_rows(qualified) -> list:
    rows = [r for r in qualified.process_rows() if qualified.is_original_steam_process(r[2])]
    inner = [r for r in rows if r[2].replace('\\', '/').casefold() == 'c:/program files (x86)/steam/steam.exe']
    return inner or rows


def runtime(config_path: Path, dry_run: bool) -> dict:
    config_path = workspace_path(config_path)
    config = json.loads(config_path.read_text())
    if config.get('appid') != STELLAR or Path(config.get('root', '')).resolve() != ROOT:
        raise ValueError('Only the existing qualified Stellar launch entry is enabled')
    proof = workspace_path(Path(config['proof']))
    command = [sys.executable, str(ROOT / 'tools/launch_stellar_deferred_proxy.py'), '--proof', str(proof)]
    if dry_run:
        return {'appName': ENTRY_NAME, 'command': command, 'SteamStarted': False, 'dryRun': True}
    validate_proof(proof)  # No cold-start for a stale or mismatched candidate.
    logs = ROOT / 'evidence/native-steam-entry-runs'
    logs.mkdir(exist_ok=True)
    with (logs / 'stellar-entry.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError('This entry is already running') from exc
        sys.path.insert(0, str(ROOT / 'tools'))
        import launch_stellar_deferred_proxy as qualified
        if any(qualified.is_stellar_process(c) for _, _, c in qualified.process_rows()):
            raise ValueError('Stellar is already running; no duplicate launch')
        steam = canonical_steam_rows(qualified)
        if len(steam) > 1:
            raise ValueError('Multiple original Steam clients; no additional client started')
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        run = logs / stamp
        run.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.lower().startswith('steam')}
        with (run / 'startup.log').open('w') as log:
            if not steam:
                subprocess.run([sys.executable, str(ROOT / 'tools/start_original_steam_for_candidate.py')], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            if len(canonical_steam_rows(qualified)) != 1:
                raise ValueError('Original Steam was not ready; game not requested')
            result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=log, text=True)
            log.write(result.stdout)
            log.flush()
            if result.returncode:
                raise ValueError('Qualified launch did not verify; see workspace startup.log')
        verified = None
        for line in reversed(result.stdout.splitlines()):
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if item.get('verified') and item.get('gamePIDs'):
                verified = item
                break
        if not verified:
            raise ValueError('No verified game PID; entry cannot track running state')
        # Track only the exact game PID and observed launch time, never Steam.
        def identity(pid: int) -> str:
            row = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=,comm='], capture_output=True, text=True)
            return row.stdout.strip() if row.returncode == 0 else ''
        identities = {int(pid): identity(int(pid)) for pid in verified['gamePIDs']}
        identities = {pid: value for pid, value in identities.items() if value}
        if not identities:
            raise ValueError('Verified game exited before entry tracking')
        atomic_write(run / 'entry.json', (json.dumps({'appid': STELLAR, 'verifiedLaunchDirectory': verified['directory'], 'gamePIDs': list(identities), 'SteamRestartedOnlyIfAbsent': not bool(steam), 'directGameExecutable': False}, indent=2) + '\n').encode())
        while any(identity(pid) == value for pid, value in identities.items()):
            time.sleep(2)
        return {'appName': ENTRY_NAME, 'gameExited': True, 'SteamStopped': False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest='mode', required=True)
    p = modes.add_parser('prepare')
    p.add_argument('--output', type=Path, default=ROOT / 'build/native-steam-entries')
    p.add_argument('--proof', type=Path, default=DEFAULT_PROOF)
    p.add_argument('--write-workspace', action='store_true')
    p.add_argument('--merge-from', type=Path)
    p.add_argument('--merge-to', type=Path)
    r = modes.add_parser('run')
    r.add_argument('--config', type=Path, required=True)
    r.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        result = prepare(args.output, args.proof, args.write_workspace, args.merge_from, args.merge_to) if args.mode == 'prepare' else runtime(args.config, args.dry_run)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
