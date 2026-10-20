#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a relocatable, explicitly experimental native test kit from the backup."""
import argparse,hashlib,json,os,shutil,subprocess,tarfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
VERSION='v0.1.0-experimental'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    name='amd-dx12-macos-x86_64-'+VERSION;package=out/name
    assert not package.exists(),'Build into a new output directory'
    package.mkdir();(package/'lib').mkdir();(package/'bin').mkdir();(package/'windows').mkdir()
    (package/'wine-version-specific').mkdir()
    manifest=json.loads((ROOT/'snapshot-manifest.json').read_text());artifact=ROOT/manifest['runtimeArtifact']['path']
    assert sha(artifact)==manifest['runtimeArtifact']['sha256']
    selected={
      'build/mvk-queue-dependencies-game/libCandidate.dylib':'lib/libMoltenVK.dylib',
      'build/winemac-lockfix-leaf-select/winemac.so':'wine-version-specific/winemac.so',
      'backend/wine/x86_64-windows/d3d12.dll':'windows/d3d12.dll',
      'backend/wine/x86_64-windows/d3d12core.dll':'windows/d3d12core.dll'}
    expected={item['path']:item['sha256'] for item in manifest['runtimeArtifact']['files']}
    with tarfile.open(artifact) as archive:
        for old,new in selected.items():
            member='open-game-stack-20261015/'+old
            data=archive.extractfile(member).read()
            assert hashlib.sha256(data).hexdigest()==expected[member]
            (package/new).write_bytes(data)
    os.symlink('libMoltenVK.dylib',package/'lib/libMoltenVK.1.dylib')
    stack=ROOT/'workspace/open-game-stack-20261015'
    headers=stack/'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include'
    probe_source=out/'probe-source';probe_source.mkdir()
    for binary,source in [('queue-probe',stack/'src/queue_sync_probe.cpp'),
                          ('queue-burst-probe',stack/'evidence/queue-burst-20261020/queue_burst_probe.cpp')]:
        # Quoted includes search the source file's directory before -I paths.
        # Compile a copy here so the public AMD selector is actually used.
        local_source=probe_source/source.name;shutil.copy2(source,local_source)
        subprocess.run(['xcrun','clang++','-std=c++17','-O2','-arch','x86_64',
                        '-I',str(ROOT/'public'),'-I',str(headers),str(local_source),
                        str(package/'lib/libMoltenVK.dylib'),'-Wl,-rpath,@executable_path/../lib',
                        '-o',str(package/'bin'/binary)],check=True)
        subprocess.run(['codesign','--force','--sign','-',str(package/'bin'/binary)],check=True)
    shutil.copy2(ROOT/'public/runtime.py',package/'runtime.py')
    shutil.copy2(ROOT/'LICENSE',package/'LICENSE')
    shutil.copy2(ROOT/'THIRD_PARTY_NOTICES.md',package/'THIRD_PARTY_NOTICES.md')
    shutil.copytree(ROOT/'LICENSES',package/'LICENSES')
    (package/'README.zh-CN.md').write_text((ROOT/'docs/TESTING.zh-CN.md').read_text().replace('TESTING.en.md','README.en.md'))
    (package/'README.en.md').write_text((ROOT/'docs/TESTING.en.md').read_text().replace('TESTING.zh-CN.md','README.zh-CN.md'))
    shutil.copy2(ROOT/'docs/KNOWN_ISSUES.en.md',package/'KNOWN_ISSUES.en.md')
    shutil.copy2(ROOT/'docs/KNOWN_ISSUES.zh-CN.md',package/'KNOWN_ISSUES.zh-CN.md')
    payload=[]
    for path in sorted(package.rglob('*')):
        if path.is_file() and not path.is_symlink():
            payload.append({'path':str(path.relative_to(package)),'bytes':path.stat().st_size,'sha256':sha(path)})
    description={'version':VERSION,'architecture':'x86_64','testedOS':'26.7.1',
                 'testedGPU':'AMD Radeon Pro 5600M','gamePlayable':False,
                 'status':'Experimental native test kit; latest full game replay failed',
                 'wineWindowModuleRestriction':'Only for the audited original Tencent server SHA256 dd1d5e5908429157dea855e246503bf1e47cd0a3c1c4fd84efdac03374a6022a; do not install automatically',
                 'sourceRepository':'https://github.com/widmonstertony/macos-amd-dx12-research',
                 'sourceTag':VERSION,'links':{'lib/libMoltenVK.1.dylib':'libMoltenVK.dylib'},'files':payload}
    (package/'manifest.json').write_text(json.dumps(description,indent=2)+'\n')
    target=out/(name+'.tar.gz')
    with tarfile.open(target,'w:gz') as archive:archive.add(package,arcname=name)
    (out/'SHA256SUMS.txt').write_text(sha(target)+'  '+target.name+'\n')
    print(json.dumps({'package':str(package),'archive':str(target),'bytes':target.stat().st_size,'sha256':sha(target),'gamePlayable':False}))


if __name__=='__main__':main()
