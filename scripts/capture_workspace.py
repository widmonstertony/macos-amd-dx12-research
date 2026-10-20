#!/usr/bin/env python3
"""Capture allowlisted research source; never traverses a prefix or game install."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile

DEST = Path(__file__).resolve().parents[1]
SOURCE_EXT = {'.c', '.cpp', '.cc', '.h', '.hpp', '.m', '.mm', '.py', '.sh',
              '.comp', '.vert', '.frag', '.geom', '.tesc', '.tese', '.mesh',
              '.task', '.glsl', '.hlsl', '.metal', '.def', '.inc', '.patch',
              '.sb', '.ini', '.cmake', '.txt', '.md'}
SKIP = {'.git', '__pycache__', '.DS_Store', 'node_modules', 'build', 'runtime',
        '.cache', 'evidence', 'input', 'outputs', 'output', 'source-before'}
records = []


def sha(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def copy(src, rel):
    if src.is_symlink() or not src.is_file():
        return
    target = DEST / 'workspace' / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, target)
    digest = sha(target)
    assert digest == sha(src), f'Concurrent source change: {src}'
    records.append({'path': str(rel), 'bytes': target.stat().st_size,
                    'sha256': digest, 'executable': bool(src.stat().st_mode & 0o111)})


def tree(root, research, source_only=False):
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and
                         not (Path(directory) / d).is_symlink())
        for name in sorted(files):
            p = Path(directory) / name
            if name in SKIP or p.is_symlink():
                continue
            if source_only and p.suffix not in SOURCE_EXT:
                continue
            if p.suffix in {'.o', '.obj', '.pyc', '.dll', '.exe', '.dylib', '.so', '.a', '.lib'}:
                continue
            copy(p, p.relative_to(research))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--research', type=Path, required=True)
    args = ap.parse_args()
    research = args.research.resolve()
    stack = research / 'open-game-stack-20261015'
    assert not (DEST / 'workspace').exists(), 'Snapshot exists; create a new checkpoint instead'
    # Exact current native source and all pinned compile-time dependencies.
    vendor_roots = [
        'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93',
        'native-vendor/SPIRV-Cross-939b40b33a44443c404c4078823c406e3c94866f',
        'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a',
        'native-vendor/cereal/cereal',
        'vendor/vkd3d-proton-212991fc2c266bc0d59f4c4ce8f80f7126508d71',
        'vendor/dxil-spirv-219d770799606f15abb3c57a8a9b9d19c2ae94ca',
        'vendor/dxbc-spirv-29c93aeecd55533a357fdd7c95be5587d1c1f506',
        'vendor/Vulkan-Headers-ad9ce1235e88dc09287e19171dfac384db8ec32c',
        'vendor/SPIRV-Headers-f88a2d766840fc825af1fc065977953ba1fa4a91',
        'vendor/SPIRV-Headers-c8ad050fcb29e42a2f57d9f59e97488f465c436d',
        'vendor/cx26-reference/sources/wine/dlls/winemac.drv',
        'vendor/cx26-reference/sources/wine/include',
    ]
    for rel in vendor_roots:
        tree(stack / rel, research)
    for p in stack.iterdir():
        if p.is_file() and p.suffix in SOURCE_EXT:
            copy(p, p.relative_to(research))
    for name in ['src', 'tools'] + [p.name for p in stack.glob('repro-*') if p.is_dir()]:
        tree(stack / name, research, source_only=True)
    for rel in ['robustness2-reference-20261015', 'robustness2-native-20261014',
                'robustness2-moltenvk-20261014', 'robustness2-amd-20261014']:
        folder = research / rel
        for p in folder.iterdir():
            if p.is_file() and p.suffix in SOURCE_EXT:
                copy(p, p.relative_to(research))
        for name in ['src', 'shaders']:
            if (folder / name).is_dir():
                tree(folder / name, research, source_only=True)
    # Earlier D3DMetal adapter/probes: preserve authored source, not Apple binaries.
    for rel in ['gpu-adapter-experiment', 'presentation-probe', 'graphics-probe',
                'compute-probe', 'descriptor-probe', 'dxbc-probe', 'geometry-probe']:
        folder = research / rel
        if not folder.is_dir():
            continue
        for p in folder.iterdir():
            if p.is_file() and p.suffix in SOURCE_EXT:
                copy(p, p.relative_to(research))
    for p in research.iterdir():
        if p.is_file() and p.suffix in SOURCE_EXT:
            copy(p, p.relative_to(research))
    # Cumulative patches and selected factual summaries, no dumps/game MSL/client logs.
    for p in (stack / 'evidence').rglob('*.patch'):
        if not p.is_symlink():
            copy(p, p.relative_to(research))
    selected = [
        'evidence/queue-dependencies-20261020/native-qualification.json',
        'evidence/queue-dependencies-20261020/cache-regression.json',
        'evidence/private-cache-wine-20261020T072513Z/run.json',
        'evidence/queue-dependency-trial-preview-20261020/game-trial-config.h',
        'evidence/queue-dependency-trial-preview-20261020/preview.json',
        'evidence/queue-dependency-trial-preview-20261020/launch-proof.json',
        'evidence/queue-dependency-trial-preview-20261020/current-run-state.json',
        'evidence/queue-dependency-trial-preview-20261020/deployment.json',
        'evidence/queue-dependency-trial-preview-20261020/selector-before.json',
        'evidence/tencent-normal-game-deferred-20261020T073505Z/launch.json',
        'evidence/winemac-compat-20261019/protocol-fix-qualification.json',
        'evidence/render-cache-final-20261020/summary.json',
        'evidence/render-cache-final-20261020/cases.json',
        'evidence/scene-cpu-resource-use-20261020/failure-and-next-trial.json',
        'evidence/scene-cpu-resource-use-20261020/new-gpu-timeout-summary.json',
        'evidence/scene-cpu-resource-use-20261020/new-dump-fatal.json',
        'build/mvk-queue-dependencies-game/build.json',
        'build/mvk-queue-dependencies-probe/build.json',
        'build/moltenvk-bounded-archive/CMakeCache.txt',
        'build/moltenvk-bounded-archive/cpm-package-lock.cmake',
        'build/vkd3d/meson-info/intro-buildoptions.json',
        'build/winemac-lockfix-cx26/config.status',
        'build/winemac-lockfix-cx26/include/config.h',
    ]
    for rel in selected:
        p = stack / rel
        if p.is_file():
            copy(p, p.relative_to(research))
    copy(research / 'gpu-adapter-experiment/public-api-observations.json',
         Path('gpu-adapter-experiment/public-api-observations.json'))
    # These are source download archives, not game/engine redistributions.
    for rel in ['native-vendor/MoltenVK.tar.gz', 'native-vendor/SPIRV-Cross.tar.gz',
                'vendor/vkd3d-proton.tar.gz', 'vendor/dxil-spirv.tar.gz', 'vendor/dxbc-spirv.tar.gz']:
        p = stack / rel
        copy(p, p.relative_to(research))
    runtime = [
        'build/mvk-queue-dependencies-game/libCandidate.dylib',
        'build/mvk-queue-dependencies-game/libProbeGuard.dylib',
        'build/mvk-queue-dependencies-probe/libCandidate.dylib',
        'build/mvk-queue-dependencies-probe/libProbeGuard.dylib',
        'build/mvk-independent-queues-probe/libCandidate.dylib',
        'build/mvk-independent-queues-probe/libProbeGuard.dylib',
        'build/winemac-lockfix-leaf-select/winemac.so',
        'build/winemac-lockfix-protocol-select/winemac.so',
        'backend/wine/x86_64-windows/d3d12.dll',
        'backend/wine/x86_64-windows/d3d12core.dll',
    ]
    artifact = DEST / 'artifacts/runtime-20261020.tar.gz'
    artifact.parent.mkdir(exist_ok=True)
    runtime_records = []
    with tarfile.open(artifact, 'w:gz') as archive:
        for rel in runtime:
            p = stack / rel
            if p.is_file() and not p.is_symlink():
                arcname = str(p.relative_to(research))
                archive.add(p, arcname=arcname, recursive=False)
                runtime_records.append({'path': arcname, 'bytes': p.stat().st_size, 'sha256': sha(p)})
    manifest = {'capturedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'originalResearchDirectory': str(research), 'sourceFiles': sorted(records, key=lambda x: x['path']),
                'runtimeArtifact': {'path': str(artifact.relative_to(DEST)), 'sha256': sha(artifact),
                                    'files': runtime_records},
                'excluded': ['game assets and game-derived shader dumps', 'Steam clients and credentials',
                             'Wine prefixes and user saves', 'Apple and Tencent proprietary engines',
                             'large shader caches (retained at original local paths)', 'raw crash dumps']}
    (DEST / 'snapshot-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'sourceFiles': len(records), 'sourceBytes': sum(x['bytes'] for x in records),
                      'runtimeFiles': len(runtime_records), 'runtimeArchiveBytes': artifact.stat().st_size}))


if __name__ == '__main__':
    main()
