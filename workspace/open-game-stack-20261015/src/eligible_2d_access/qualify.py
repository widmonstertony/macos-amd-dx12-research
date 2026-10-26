#!/usr/bin/env python3
"""Owned fixtures for a separate 2D-only access contract; no native integration."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CROSS = ROOT / 'native-vendor/SPIRV-Cross-939b40b33a44443c404c4078823c406e3c94866f'
CONVERTER = ROOT / 'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVKShaderConverter/MoltenVKShaderConverter'

def fixture(kind):
    if kind == 'unused_fetch_2d':
        source = fixture('sample')
        return source + '''\n%unused = OpFunction %void None %fn
%unusedEntry = OpLabel
%unusedImage = OpLoad %image %tex
%unusedRead = OpImageFetch %v4 %unusedImage %coord Lod %i0
OpReturn
OpFunctionEnd
'''
    dim, array, operation, coord = 'Buffer', 0, 'fetch', '%i0'
    capability = 'OpCapability SampledBuffer'
    if kind == 'three_d': dim, coord, capability = '3D', '%coord3', ''
    if kind in ('fetch_2d', 'query_2d'): dim, coord, capability = '2D', '%coord', 'OpCapability ImageQuery'
    if kind == 'one_d': dim, coord, operation, capability = '1D', '%zero', 'sample', 'OpCapability Sampled1D'
    if kind == 'cube_array': dim, array, coord, operation, capability = 'Cube', 1, '%uv4', 'sample', 'OpCapability SampledCubeArray'
    if kind.startswith('storage_'): dim, coord, operation, capability = '3D', '%coord3', kind, ''
    sampled, fmt = (2, 'Rgba32f') if kind.startswith('storage_') else (1, 'Unknown')
    extra = kind != 'sample'
    declarations = f'''
%image2 = OpTypeImage %float {dim} 0 {array} 0 {sampled} {fmt}
{'%combined2 = OpTypeSampledImage %image2' if sampled == 1 else ''}
%ptrImage2 = OpTypePointer UniformConstant %image2
%tex2 = OpVariable %ptrImage2 UniformConstant
''' if extra else ''
    body = ''
    if extra:
        body = '%im2 = OpLoad %image2 %tex2\n'
        if operation == 'sample': body += f'%ss2 = OpSampledImage %combined2 %im2 %sm\n%read = OpImageSampleImplicitLod %v4 %ss2 {coord}\n'
        elif operation == 'storage_read': body += f'%read = OpImageRead %v4 %im2 {coord}\n'
        elif operation == 'storage_write': body += f'OpImageWrite %im2 {coord} %sampled\n%read = OpCopyObject %v4 %sampled\n'
        elif kind == 'query_2d': body += '%size = OpImageQuerySizeLod %iv2 %im2 %i0\n%sizef = OpConvertSToF %v2 %size\n%ss2 = OpSampledImage %combined2 %im2 %sm\n%read = OpImageSampleImplicitLod %v4 %ss2 %sizef\n'
        else: body += f'%read = OpImageFetch %v4 %im2 {coord}' + (' Lod %i0' if dim != 'Buffer' else '') + '\n'
    value = '%read' if kind == 'buffer_only' else '%sampled'
    if extra and kind != 'buffer_only': body += '%sum = OpFAdd %v4 %sampled %read\n'; value = '%sum'
    if dim == '2D' and sampled == 1:
        declarations = '%tex2 = OpVariable %ptrImage UniformConstant\n'
        body = body.replace('%image2', '%image').replace('%combined2', '%combined')
    return f'''OpCapability Shader
{capability if extra else ''}
OpMemoryModel Logical GLSL450
OpEntryPoint Fragment %main "main" %out %tex %samp {'%tex2' if extra else ''}
OpExecutionMode %main OriginUpperLeft
OpDecorate %out Location 0
OpDecorate %tex DescriptorSet 0
OpDecorate %tex Binding 0
OpDecorate %samp DescriptorSet 0
OpDecorate %samp Binding 1
{'OpDecorate %tex2 DescriptorSet 0' if extra else ''}
{'OpDecorate %tex2 Binding 2' if extra else ''}
%void = OpTypeVoid
%fn = OpTypeFunction %void
%float = OpTypeFloat 32
%int = OpTypeInt 32 1
%v2 = OpTypeVector %float 2
%v3 = OpTypeVector %float 3
%v4 = OpTypeVector %float 4
%iv2 = OpTypeVector %int 2
%iv3 = OpTypeVector %int 3
%image = OpTypeImage %float 2D 0 0 0 1 Unknown
%sampler = OpTypeSampler
%combined = OpTypeSampledImage %image
%ptrImage = OpTypePointer UniformConstant %image
%ptrSampler = OpTypePointer UniformConstant %sampler
%ptrOutput = OpTypePointer Output %v4
%tex = OpVariable %ptrImage UniformConstant
%samp = OpVariable %ptrSampler UniformConstant
%out = OpVariable %ptrOutput Output
%zero = OpConstant %float 0
%i0 = OpConstant %int 0
%uv = OpConstantComposite %v2 %zero %zero
%uv4 = OpConstantComposite %v4 %zero %zero %zero %zero
%coord = OpConstantComposite %iv2 %i0 %i0
%coord3 = OpConstantComposite %iv3 %i0 %i0 %i0
{declarations}
%main = OpFunction %void None %fn
%entry = OpLabel
%im = OpLoad %image %tex
%sm = OpLoad %sampler %samp
%ss = OpSampledImage %combined %im %sm
{'%sampled = OpImageSampleImplicitLod %v4 %ss %uv' if kind != 'buffer_only' else ''}
{body}
OpStore %out {value}
OpReturn
OpFunctionEnd
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    out = parser.parse_args().output.resolve()
    if out.exists() or not out.is_relative_to(ROOT / 'evidence') or not out.parent.is_dir():
        parser.error('output must be a new directory below evidence with an existing parent')
    out.mkdir(mode=0o700)
    fixtures = out / 'fixtures'; fixtures.mkdir()
    commands = []
    def run(label, command):
        result = subprocess.run([str(x) for x in command], cwd=ROOT, text=True, capture_output=True, timeout=180)
        (out / (label + '.stdout')).write_text(result.stdout)
        (out / (label + '.stderr')).write_text(result.stderr)
        commands.append({'label': label, 'argv': [str(x) for x in command], 'exitCode': result.returncode})
        if result.returncode: raise RuntimeError(label + ': ' + result.stderr[:400])
        return result.stdout
    files = [HERE / 'eligible_2d_access.h', HERE / 'control.cpp', Path(__file__).resolve(), CONVERTER / 'SPIRVSampleOnlyAccess.h']
    manifest = [{'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]
    try:
        for name in ('sample', 'buffer', 'three_d', 'buffer_only', 'fetch_2d', 'query_2d', 'one_d', 'cube_array', 'storage_read', 'storage_write', 'unused_fetch_2d'):
            source = fixtures / (name + '.spvasm'); binary = fixtures / (name + '.spv')
            source.write_text(fixture(name))
            run(name + '-assemble', ['/usr/local/bin/spirv-as', '--target-env', 'vulkan1.2', source, '-o', binary])
            run(name + '-validate', ['/usr/local/bin/spirv-val', '--target-env', 'vulkan1.2', binary])
        # Reuse stable read-only static libraries; never run a native build.
        libraries = ROOT / 'build/moltenvk-runtime-trace/_deps/spirv-cross-build'
        libs = [libraries / ('libspirv-cross-' + x + '.a') for x in ('msl', 'glsl', 'core')]
        library_manifest = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in libs}
        results = []
        for label, flags in [('optimized', ['-O2']), ('sanitized', ['-O1', '-g', '-fno-omit-frame-pointer', '-fsanitize=address,undefined'])]:
            binary = out / label
            run(label + '-build', ['clang++', '-std=c++17', *flags, '-Wall', '-Wextra', '-Werror', '-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross',
                '-I' + str(CROSS), '-I' + str(CONVERTER), '-I/usr/local/opt/spirv-tools/include', HERE / 'control.cpp', *libs,
                '-L/usr/local/opt/spirv-tools/lib', '-lSPIRV-Tools', '-Wl,-rpath,/usr/local/opt/spirv-tools/lib', '-o', binary])
            results.append({'variant': label, 'result': json.loads(run(label, [binary, fixtures]))})
        for p, sha in library_manifest.items():
            if hashlib.sha256(Path(p).read_bytes()).hexdigest() != sha: raise RuntimeError('library changed during qualification')
        for item in manifest:
            if hashlib.sha256(Path(item['path']).read_bytes()).hexdigest() != item['sha256']: raise RuntimeError('input changed during qualification')
        report = {'passed': all(row['result']['passed'] for row in results), 'results': results, 'inputs': manifest, 'staticLibraries': library_manifest,
            'semanticValidation': 'All authored modules validated with spirv-val and actual libSPIRV-Tools callback.',
            'productionIntegrated': False, 'existingNativeFilesModified': False, 'cacheReadOrWritten': False,
            'gameOperated': False, 'GPUCalls': 0, 'commands': commands}
    except Exception as exc:
        report = {'passed': False, 'error': str(exc), 'inputs': manifest, 'commands': commands}
    (out / 'qualification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'error': report.get('error'), 'output': str(out)}))
    return 0 if report['passed'] else 1

if __name__ == '__main__': raise SystemExit(main())
