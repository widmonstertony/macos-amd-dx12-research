#!/usr/bin/env python3
"""Translate explicit local native trace descriptors for linkage controls.

Game-derived sources and generated case files stay local. Missing state and
specialization inputs are rejected, never invented to claim exact replay.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def field(text, pattern):
    match = re.search(pattern, text, re.S)
    if not match:
        raise ValueError('Missing descriptor field: ' + pattern)
    return match.group(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--trace-directory', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    parser.add_argument('--output-stem', default='vertex-stream')
    args = parser.parse_args()
    src, out = args.trace_directory.resolve(), args.output_directory.resolve()
    root = Path(__file__).resolve().parents[1]
    assert src.is_relative_to(root / 'evidence') and out.is_relative_to(root / 'evidence')
    out.mkdir(exist_ok=True)
    function_profiles = {}
    inconsistent_profiles = []
    for path in src.glob(f'trace-function-{args.pid}-*.json'):
        data = json.loads(path.read_text())
        label = data.get('function', {}).get('label')
        if not label:
            continue
        profile = (data.get('fpFastMathFlags'), data.get('positionInvariant'))
        if label in function_profiles and function_profiles[label] != profile:
            inconsistent_profiles.append({'label': label, 'profiles': [function_profiles[label], profile]})
        function_profiles[label] = profile
    if inconsistent_profiles:
        raise ValueError(f'Inconsistent function trace profiles: {inconsistent_profiles[:3]}')
    rows, rejected = [], []
    files = sorted(src.glob(f'trace-pipeline-{args.pid}-*.json'), key=lambda p: int(p.stem.split('-')[-1]))
    for path in files:
        data = json.loads(path.read_text())
        if data.get('kind') != 'vertex' or not data.get('created'):
            continue
        try:
            text, functions = data['descriptor'], {}
            for stage in ['vertex', 'fragment']:
                f = data.get(stage, {})
                if not f:
                    continue
                parts = f['label'].split(':')
                assert len(parts) == 3, 'Missing source identity'
                source = src / ('source-' + parts[1] + '.metal')
                code = source.read_text()
                assert 'function_constant' not in code and 'SPIRV_CROSS_CONSTANT_ID' not in code, 'Unknown specialization values'
                assert f['label'] in function_profiles, 'Missing actual function compiler profile'
                fast_math_flags, preserve_invariance = function_profiles[f['label']]
                assert fast_math_flags in (0, 0xffffffff), 'Unsupported traced FP fast-math mask'
                fast = fast_math_flags == 0xffffffff
                functions[stage] = {'source': str(source), 'entry': f['name'], 'label': f['label'],
                                    'compileProvenance': {'languageVersion': 262144,
                                        'mathMode': 2 if fast else 0,
                                        'mathFloatingPointFunctions': 0 if fast else 1,
                                        'preserveInvariance': preserve_invariance,
                                        'fpFastMathFlags': fast_math_flags,
                                        'profileSource': 'actual-function-trace'},
                                    'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest()}
            assert functions.get('vertex')
            assert not re.search(r'mutability = (?!MTLMutabilityDefault)', text), 'Non-default buffer mutability'
            get = lambda pattern: field(text, pattern)
            row = {'sequence': int(path.stem.split('-')[-1]), 'functions': functions,
                   'depth': get(r'Depth Attachment Format = (\w+)'),
                   'stencil': get(r'Stencil Attachment Format = (\w+)'),
                   'rasterSamples': int(get(r'Raster Sample Count = (\d+)')),
                   'rasterization': get(r'Rasterization Enabled = (\d+)') == '1',
                   'alphaToCoverage': get(r'Alpha to Coverage = (\d+)') == '1',
                   'alphaToOne': get(r'Alpha to One = (\d+)') == '1',
                   'topology': get(r'Input Primitive Topology = (\w+)'),
                   'colors': [], 'vertexBuffers': [], 'compilerProfilesFromActualFunctionTrace': True}
            for m in re.finditer(r'Color Attachment (\d+):\s+(.*?)(?=Color Attachment \d+:|Vertex Buffer \d+:|$)', text, re.S):
                b = m.group(2)
                g = lambda pattern: field(b, pattern)
                row['colors'].append({'index': int(m.group(1)), 'pixelFormat': g(r'pixelFormat = (\w+)'),
                    'blending': g(r'blending = (\w+)') == 'YES',
                    'sourceRGB': g(r'Source blend factors:\s+RGB\s+= (\w+)'),
                    'sourceAlpha': g(r'Source blend factors:.*?Alpha = (\w+)'),
                    'destinationRGB': g(r'Destination blend factors:\s+RGB\s+= (\w+)'),
                    'destinationAlpha': g(r'Destination blend factors:.*?Alpha = (\w+)'),
                    'rgbOperation': g(r'Blend operations:\s+RGB\s+= (\w+)'),
                    'alphaOperation': g(r'Blend operations:.*?Alpha = (\w+)'), 'writeMask': g(r'writeMask = (\w+)')})
            if 'Vertex Array:' in text:
                va = text.split('Vertex Array:')[1].split('Vertex Amplification Mode')[0]
                for m in re.finditer(r'Buffer (\d+):\s+(.*?)(?=Buffer \d+:|$)', va, re.S):
                    b = m.group(2)
                    g = lambda pattern: field(b, pattern)
                    attrs = [{'index': int(x[0]), 'offset': int(x[1]),
                              'format': x[2].replace('MTLAttributeFormat', 'MTLVertexFormat')}
                             for x in re.findall(r'Attribute (\d+):\s+offset = (\d+)\s+format = (\w+)', b)]
                    rate = re.search(r'stepRate = (\d+)', b)
                    row['vertexBuffers'].append({'index': int(m.group(1)), 'stepFunction': g(r'stepFunction = (\w+)'),
                        'stepRate': int(rate.group(1)) if rate else 1, 'stride': g(r'stride = (\w+)'), 'attributes': attrs})
            else:
                assert 'attributeIndex =' not in text, 'Missing active vertex layout'
            rows.append(row)
        except (AssertionError, ValueError, OSError, KeyError, IndexError) as error:
            rejected.append({'sequence': path.name, 'reason': str(error)})
    output_path = out / f'{args.output_stem}.json'
    summary_path = out / f'{args.output_stem}-input-summary.json'
    output_path.write_text(json.dumps(rows, indent=2) + '\n')
    summary = {'eligiblePipelines': len(rows), 'excluded': rejected, 'GPUWorkDispatched': False,
               'completeDescriptorCapture': False,
               'compilerProfilesFromActualFunctionTrace': True,
               'functionTraceProfiles': len(function_profiles),
               'compilerOptionLimitations': ['preprocessor macros are excluded with specialized sources',
                                             'Metal optimization default and MSL language version are reconstructed from the recorded runtime configuration']}
    summary_path.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'eligiblePipelines': len(rows), 'excluded': len(rejected),
                      'functionTraceProfiles': len(function_profiles), 'firstExcluded': rejected[:3]}))


if __name__ == '__main__':
    main()
