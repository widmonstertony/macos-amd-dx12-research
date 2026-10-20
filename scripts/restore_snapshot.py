#!/usr/bin/env python3
"""Verify or restore the exact saved files without launching or changing an app."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--target', type=Path)
    args = parser.parse_args()
    if not args.verify_only and args.target is None:
        parser.error('--verify-only or a new --target directory is required')
    manifest = json.loads((ROOT / 'snapshot-manifest.json').read_text())
    links = json.loads((ROOT / 'source-links.json').read_text())
    for item in manifest['sourceFiles']:
        assert sha(ROOT / 'workspace' / item['path']) == item['sha256'], item['path']
    artifacts = [manifest['runtimeArtifact']] + manifest.get('additionalRuntimeArtifacts', [])
    verified_archives = []
    runtime_count = 0
    seen_runtime_paths = set()
    for artifact in artifacts:
        archive_path = ROOT / artifact['path']
        assert sha(archive_path) == artifact['sha256'], 'Runtime archive hash mismatch'
        expected = {item['path']: item for item in artifact['files']}
        assert not seen_runtime_paths.intersection(expected), 'Overlapping runtime snapshots'
        seen_runtime_paths.update(expected)
        with tarfile.open(archive_path) as archive:
            members = archive.getmembers()
            assert len(members) == len(expected) and set(m.name for m in members) == set(expected), 'Unexpected archive members'
            for member in members:
                name = PurePosixPath(member.name)
                assert member.isfile() and not name.is_absolute() and '..' not in name.parts
                data = archive.extractfile(member).read()
                assert hashlib.sha256(data).hexdigest() == expected[member.name]['sha256']
        verified_archives.append((archive_path, expected))
        runtime_count += len(expected)
    if args.verify_only:
        print(json.dumps({'verifiedSourceFiles': len(manifest['sourceFiles']),
                          'verifiedRuntimeFiles': runtime_count, 'passed': True}))
        return
    target = args.target.resolve()
    assert not target.exists(), 'Target must be a new directory; existing work is never overwritten'
    target.mkdir(parents=True)
    shutil.copytree(ROOT / 'workspace', target, dirs_exist_ok=True)
    for archive_path, expected in verified_archives:
        with tarfile.open(archive_path) as archive:
            for member in archive.getmembers():
                output = target / member.name
                assert not output.is_symlink()
                output.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as src, output.open('wb') as dst:
                    shutil.copyfileobj(src, dst)
                output.chmod(member.mode & 0o777)
                assert sha(output) == expected[member.name]['sha256']
    for item in links:
        link = target / item['path']
        assert not link.exists() and not link.is_symlink()
        link.parent.mkdir(parents=True, exist_ok=True)
        resolved = target / item['targetPath']
        assert resolved.exists(), item
        os.symlink(os.path.relpath(resolved, link.parent), link)
    for item in manifest['sourceFiles']:
        assert sha(target / item['path']) == item['sha256'], item['path']
    print(json.dumps({'restoredTo': str(target), 'sourceFiles': len(manifest['sourceFiles']),
                      'runtimeFiles': runtime_count, 'sourceLinks': len(links), 'allHashesMatched': True,
                      'applicationsStarted': False, 'existingEnvironmentChanged': False}))


if __name__ == '__main__':
    main()
