#!/usr/bin/env python3
"""Bounded native output and cache-identity tests; never starts a game.

Every warm success must be a strict Metal binary-archive hit. Negative inputs
live in fresh private directories. The running game's caches are read-only.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(directory):
    return {f.name: [f.stat().st_size, f.stat().st_mtime_ns, digest(f)]
            for f in directory.glob('*.metalar')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    if not args.label.replace('-', '').isalnum() or len(args.label) > 35:
        parser.error('Short safe unique label required')
    library = args.library.resolve()
    if not library.is_relative_to(ROOT / 'build') or not library.is_file():
        parser.error('Owned built candidate required')
    out = ROOT / 'evidence' / args.label
    out.mkdir(exist_ok=False)
    cache = out / 'render-shards'
    cache.mkdir()
    rows = []
    base = [sys.executable, str(ROOT / 'run_gpu.py'), '--run', '--library', str(library),
            '--runtime-trace', '--replay-only', '--replay-failed-mesh',
            '--specialized-queues', '--serialize-pipeline-link']

    def run(name, suite='graphics', options=(), expected=0, directory=cache):
        label = args.label + '-' + name
        before = snapshot(directory)
        flags = ['--compute-archive-dir' if suite == 'vector' else '--render-archive-dir', str(directory)]
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run(base + ['--suite', suite, '--label', label] + flags + list(options),
                                    cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=60)
        evidence = ROOT / 'evidence' / label
        record = json.loads((evidence / 'run.json').read_text())
        traces = [json.loads(f.read_text()) for f in (evidence / 'msl').glob('trace-*-archive-*.json')]
        after = snapshot(directory)
        unchanged = all(after.get(k) == v for k, v in before.items())
        row = {'name': name, 'evidence': str(evidence), 'expectedExit': expected,
               'run': record, 'archives': traces, 'priorShardsUnchanged': unchanged,
               'newShards': sorted(set(after) - set(before))}
        rows.append(row)
        (out / 'cases.json').write_text(json.dumps(rows, indent=2) + '\n')
        assert result.returncode == expected and unchanged, name
        if expected == 0:
            assert record['passed'] and record['metalValidationEnabled'], name
        if '--render-archive-require-hit' in options and expected == 0:
            assert traces and all(v['strictArchiveHit'] and not v['fallback'] for v in traces), name
        print(json.dumps({'case': name, 'exit': result.returncode,
                          'GPUOutput': record.get('results'), 'archiveRecords': len(traces)}), flush=True)
        return row

    seed = run('seed')
    run('warm', options=['--render-archive-require-hit'])
    run('blend-miss', options=['--graphics-blend', '--render-archive-require-hit'], expected=1)
    run('blend-seed', options=['--graphics-blend'])
    run('blend-warm', options=['--graphics-blend', '--render-archive-require-hit'])
    run('typed-seed', suite='typedgraphics')
    run('typed-warm', suite='typedgraphics', options=['--render-archive-require-hit'])
    a = run('spec-a', options=['--graphics-specialization-layout', 'a'])
    b = run('spec-b', options=['--graphics-specialization-layout', 'b', '--render-archive-require-hit'])
    assert {v['shard'] for v in a['archives']} == {v['shard'] for v in b['archives']}
    key = seed['archives'][0]['shard']
    for name in ['invalid', 'wrong-valid']:
        d = out / name
        d.mkdir()
        if name == 'invalid':
            (d / key).write_bytes(b'private invalid archive fixture\n')
        else:
            # Valid native compute archive, containing none of the required
            # render pipelines. Only copy it; the original is never changed.
            source = next((ROOT / 'build/render-shard-compute-qualification').glob('*.metalar'))
            shutil.copy2(source, d / key)
        row = run(name, directory=d)
        if name == 'wrong-valid':
            assert all(v['loaded'] and not v['strictArchiveHit'] and v['fallback']
                       and v['pipelineCreated'] for v in row['archives'])
    compute = run('compute-warm', suite='vector', options=['--compute-archive-require-hit'],
                  directory=ROOT / 'build/render-shard-compute-qualification')
    assert compute['archives'] and all(v['loaded'] and v['requireHit'] and v['pipelineCreated']
                                      for v in compute['archives'])
    result = {'passed': True, 'library': str(library), 'SHA256': digest(library),
              'cases': [v['name'] for v in rows], 'gameStartedOrRestarted': False,
              'liveGameLibrariesChanged': False, 'sourceGameCacheModified': False,
              'specializationLayoutEquivalentKeysVerified': True,
              'actualGamePerformanceMeasured': False}
    (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
