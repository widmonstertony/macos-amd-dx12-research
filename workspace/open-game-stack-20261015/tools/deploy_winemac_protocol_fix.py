#!/usr/bin/env python3
"""Install the qualified research window module only after the game exits.

Does not stop any process, touch the original engine, or clear shader caches.
The running original Steam can launch its next game child with this selection.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'evidence/winemac-compat-20261019'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    proof = json.loads((OUT / 'protocol-fix-qualification.json').read_text())
    assert proof['qualified']
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    assert 'SB-Win64-Shipping.exe' not in rows, 'Preserving the live game: deployment requires game exit'
    source = Path(proof['candidate'])
    server = Path(proof['serverProtocolAudit']['server'])
    assert sha(server) == proof['serverProtocolAudit']['serverSHA256'], 'Original engine identity changed; re-audit required'
    assert sha(source) == proof['candidateSHA256']
    subprocess.run(['codesign', '--verify', '--strict', str(source)], check=True)
    target = ROOT / 'build/winemac-lockfix-leaf-select/winemac.so'
    prior_hash = sha(target)
    if prior_hash == proof['candidateSHA256']:
        print('Qualified module already selected')
        return
    assert prior_hash == proof['priorModuleSHA256'], 'Unexpected current research module'
    backup = OUT / 'winemac-before-protocol-fix.so'
    if not backup.exists():
        shutil.copy2(target, backup)
    assert sha(backup) == prior_hash
    temp = target.with_name('winemac.protocol-next.so')
    shutil.copy2(source, temp)
    assert sha(temp) == proof['candidateSHA256']
    temp.replace(target)
    proof['deployed'] = True
    proof['deploymentTarget'] = str(target)
    (OUT / 'protocol-fix-qualification.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps({'deployed': str(target), 'sha256': sha(target),
                      'originalEngineModified': False, 'shaderCacheDeleted': False}))


if __name__ == '__main__':
    main()
