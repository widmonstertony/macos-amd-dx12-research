#!/usr/bin/env python3
"""Summarize bounded GPU traces without assigning a shader root to a wait."""
import argparse
import collections
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    directory = args.directory.resolve()
    assert directory.is_relative_to(ROOT / 'evidence') and directory.is_dir()
    slow = []
    pending = {}
    faults = []
    for path in directory.glob(f'trace-slow-command-buffer-{args.pid}-*.json'):
        record = json.loads(path.read_text())
        events = record.get('workEvents', [])
        slow.append({
            'file': str(path.relative_to(ROOT)),
            'submission': record.get('submission'),
            'queue': [record.get('queueFamily'), record.get('queueIndex')],
            'createdTime': record.get('createdTime'),
            'gpuMilliseconds': record.get('gpuDurationMilliseconds'),
            'hostEncodingMilliseconds': record.get('hostEncodingMilliseconds'),
            'commitToGPUStartMilliseconds': record.get('commitToGPUStartMilliseconds'),
            'nativeStatus': record.get('nativeStatus'),
            'workCount': record.get('workCount'),
            'truncatedWorkEvents': record.get('truncatedWorkEvents'),
            'kindCountsInRetainedRing': dict(collections.Counter(w['kind'] for w in events)),
            'queryOperations': [w for w in events if w['kind'].startswith(('query-', 'timestamp-'))],
            'pipelineLabels': sorted({w['label'] for w in events if 'pipeline' in w['kind']}),
            'tail': events[-8:],
            'eventDependencies': record.get('events', []),
        })
    for path in directory.glob(f'trace-gpu-timeout-{args.pid}-*.json'):
        record = json.loads(path.read_text())
        own = record.get('dependencies', {})
        faults.append({'file': str(path.relative_to(ROOT)), 'time': record.get('time'),
                       'submission': own.get('submission'), 'error': record.get('error'),
                       'workCount': own.get('workCount'), 'events': own.get('events', [])})
        for item in [own] + record.get('pendingQueueDependencies', []):
            if 'submission' in item:
                pending.setdefault(item['submission'], item)
    slow.sort(key=lambda x: x.get('createdTime') or 0)
    faults.sort(key=lambda x: x['time'])
    result = {'pid': args.pid, 'exactShaderRootProven': False,
              'slowSubmissions': slow, 'faults': faults,
              'pendingAtFirstFault': [
                  {'submission': x['submission'], 'queue': [x['queueFamily'], x['queueIndex']],
                   'createdTime': x['createdTime'], 'workCount': x.get('workCount'),
                   'kindCounts': dict(collections.Counter(w['kind'] for w in x.get('workEvents', []))),
                   'events': x.get('events', []), 'tail': x.get('workEvents', [])[-4:]}
                  for _, x in sorted(pending.items())
                  if not faults or x['createdTime'] <= faults[0]['time']],
              'interpretationLimit': 'A long native command-buffer interval can include synchronization or dependency stalls. A pipeline label in the tail alone does not establish an expensive or invalid shader.'}
    if args.output:
        output = args.output.resolve()
        assert output.is_relative_to(ROOT / 'evidence')
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'pid': args.pid, 'slowCount': len(slow), 'faultCount': len(faults),
                      'slow': [{k: row[k] for k in ('submission', 'gpuMilliseconds', 'workCount', 'kindCountsInRetainedRing')}
                               for row in slow],
                      'output': str(args.output) if args.output else None}, indent=2))


if __name__ == '__main__':
    main()
