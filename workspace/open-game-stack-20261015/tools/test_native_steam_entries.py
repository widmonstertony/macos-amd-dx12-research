#!/usr/bin/env python3
"""CPU/filesystem-only checks; does not import a Wine launch helper."""
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

import prepare_native_steam_entries as entry


# Constructed independently of the preparation encoder. Preserve unusual
# fields, key order, uint64 values and invalid UTF-8 string bytes verbatim.
ORIGINAL_RECORD = (b'\x000\0\x01AppName\0Existing Game\0'
                   b'\x01Exe\0"/Applications/Existing.app"\0'
                   b'\x02appid\0' + struct.pack('<I', 12345) +
                   b'\x07opaque64\0\x00\xff\x12\x80\x00\x00\x00\x01'
                   b'\x01unfamiliar\0\xff\x80\0\x00tags\0\x010\0keep tag\0\x08\x08')
ORIGINAL = b'\x00shortcuts\0' + ORIGINAL_RECORD + b'\x08\x08'


class Controls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='entry-control-', dir=entry.ROOT / 'evidence')
        cls.out = Path(cls.temp.name)
        cls.app = cls.out / 'Stellar Blade YYB.app'

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_lossless_append_and_idempotence(self):
        merged, added = entry.merge_shortcuts(ORIGINAL, self.app)
        self.assertTrue(added)
        self.assertIn(ORIGINAL_RECORD, merged)
        nodes = entry.decode_vdf(merged)
        self.assertEqual(nodes[0].children[0].raw, ORIGINAL_RECORD)
        fields = {n.key: n.value for n in nodes[0].children[1].children}
        self.assertIn(b'Contents/MacOS/launcher', fields[b'Exe'])
        self.assertNotIn(b'.exe', fields[b'Exe'])
        again, added = entry.merge_shortcuts(merged, self.app)
        self.assertFalse(added)
        self.assertEqual(again, merged)

    def test_unknown_or_truncated_data_is_rejected(self):
        for bad in [ORIGINAL[:-1], ORIGINAL + b'junk', b'\x00shortcuts\0\x05wide\0\x08\x08']:
            with self.assertRaises(ValueError):
                entry.merge_shortcuts(bad, self.app)

    def test_conflicting_appid_is_rejected(self):
        replacement = entry.shortcut_node(1, self.app)
        appid = next(n.value for n in replacement.children if n.key == b'appid')
        collision = ORIGINAL.replace(struct.pack('<I', 12345), appid)
        with self.assertRaises(ValueError):
            entry.merge_shortcuts(collision, self.app)

    def test_offline_merge_backup_and_atomic_failure(self):
        source, dest = self.out / 'original.vdf', self.out / 'merged.vdf'
        source.write_bytes(ORIGINAL)
        record = entry.offline_merge(source, dest, self.app)
        self.assertEqual(Path(record['backup']).read_bytes(), ORIGINAL)
        self.assertEqual(source.read_bytes(), ORIGINAL)
        previous = dest.read_bytes()
        with self.assertRaises(ValueError):
            entry.offline_merge(source, dest, self.app)
        self.assertEqual(dest.read_bytes(), previous)
        # A failed atomic replacement cannot truncate the existing destination.
        with mock.patch.object(entry.os, 'replace', side_effect=OSError('controlled replace failure')):
            with self.assertRaises(OSError):
                entry.atomic_write(dest, b'new', previous)
        self.assertEqual(dest.read_bytes(), previous)
        entry.offline_merge(dest, dest, self.app)
        self.assertEqual(dest.read_bytes(), previous)

    def test_workspace_boundary(self):
        with self.assertRaises(ValueError):
            entry.workspace_path(Path.home() / 'Library/Application Support/Steam/shortcuts.vdf')
        link = self.out / 'outside'
        link.symlink_to(Path.home() / 'Library')
        with self.assertRaises(ValueError):
            entry.workspace_path(link / 'shortcuts.vdf')

    def test_prepare_and_app_dry_run_never_launch(self):
        output = self.out / 'prepared'
        proof = entry.ROOT / 'evidence/not-deployed-test-proof.json'
        with mock.patch.object(entry.subprocess, 'run', side_effect=AssertionError('Unexpected subprocess')):
            plan = entry.prepare(output, proof, False, None, None)
            self.assertFalse(output.exists())
            entry.prepare(output, proof, True, None, None)
            config = Path(plan['appPath']) / 'Contents/Resources/entry.json'
            result = entry.runtime(config, True)
            self.assertTrue(result['dryRun'])
            self.assertIn('--proof', result['command'])
            with self.assertRaises(OSError):
                entry.runtime(config, False)  # Proof absent: no subprocess.
            current = json.loads(config.read_text())
            current['appid'] = '2483190'
            config.write_text(json.dumps(current))
            with self.assertRaises(ValueError):
                entry.runtime(config, True)
            current['appid'] = entry.STELLAR
            config.write_text(json.dumps(current))
        plist = plistlib.loads((Path(plan['appPath']) / 'Contents/Info.plist').read_bytes())
        self.assertEqual(plist['CFBundleExecutable'], 'launcher')
        # Run the generated executable solely with --dry-run. Its output is a
        # command plan; no Steam/Wine helper is imported or invoked.
        result = subprocess.run([str(Path(plan['appPath']) / 'Contents/MacOS/launcher'), '--dry-run'], capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(result.stdout)['dryRun'])

    def test_runtime_routes_only_through_normal_steam_tools(self):
        # Exercise orchestration with a completely synthetic client/PID and
        # intercepted subprocesses. This is not qualification of a game/library.
        root = self.out / 'fake-project'
        (root / 'evidence').mkdir(parents=True)
        config = root / 'entry.json'
        config.write_text(json.dumps({'appid': entry.STELLAR, 'root': str(root),
                                      'proof': str(root / 'evidence/proof-not-executed.json')}))
        state = {'steam': False, 'ps': 0}
        calls = []
        qualified = types.SimpleNamespace(
            process_rows=lambda: [(1, 0, 'original-client')] if state['steam'] else [],
            is_original_steam_process=lambda c: c == 'original-client',
            is_stellar_process=lambda c: c == 'test-game')

        def intercepted(command, **kwargs):
            calls.append(command)
            if command[0] == '/bin/ps':
                state['ps'] += 1
                return subprocess.CompletedProcess(command, 0, 'exact test PID identity' if state['ps'] == 1 else '')
            self.assertFalse(any(k.lower().startswith('steam') for k in kwargs['env']))
            if command[1].endswith('start_original_steam_for_candidate.py'):
                state['steam'] = True
                return subprocess.CompletedProcess(command, 0)
            self.assertTrue(command[1].endswith('launch_stellar_deferred_proxy.py'))
            self.assertIn('--proof', command)
            return subprocess.CompletedProcess(command, 0, json.dumps({'verified': True, 'gamePIDs': [999], 'directory': 'synthetic-only'}))

        with mock.patch.object(entry, 'ROOT', root), mock.patch.object(entry, 'validate_proof'), \
             mock.patch.dict(sys.modules, {'launch_stellar_deferred_proxy': qualified}), \
             mock.patch.object(entry.subprocess, 'run', side_effect=intercepted):
            result = entry.runtime(config, False)
        self.assertTrue(result['gameExited'])
        self.assertFalse(result['SteamStopped'])
        self.assertEqual(sum('start_original_steam_for_candidate.py' in str(c) for c in calls), 1)
        self.assertEqual(sum('launch_stellar_deferred_proxy.py' in str(c) for c in calls), 1)
        self.assertFalse(any('SB.exe' in str(c) or 'SB-Win64' in str(c) for c in calls))


if __name__ == '__main__':
    unittest.main()
