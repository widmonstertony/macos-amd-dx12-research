#!/usr/bin/env python3
"""Give the research overlay its own writable crash-report database.

The installed game and its reports are never changed. This only replaces the
overlay's link to the read-only volume with a private, byte-preserving copy.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT.parent / 'stellar-overlay'
LINK = OVERLAY / '.crashdata'
SOURCE = Path('/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/StellarBlade/.crashdata')
DEST = ROOT / 'build/stellar-crash-report-state'
PROOF = ROOT / 'evidence/winemac-compat-20261019/crash-state-relocation.json'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    if LINK.is_symlink() and LINK.resolve() == DEST.resolve():
        print('Private crash state already selected')
        return
    assert LINK.is_symlink() and LINK.resolve() == SOURCE.resolve(), 'Unexpected overlay state'
    assert not DEST.exists(), 'Refusing to overwrite existing private reports'
    assert os.statvfs(SOURCE).f_flag & os.ST_RDONLY, 'Expected read-only source volume'
    # Copy rather than read report contents. Do not follow any nested links.
    entries = list(SOURCE.rglob('*'))
    assert not any(p.is_symlink() for p in entries), 'Unexpected nested report symlink'
    shutil.copytree(SOURCE, DEST, symlinks=True)
    for p in [DEST, *DEST.rglob('*')]:
        p.chmod(p.stat().st_mode | 0o200 | (0o100 if p.is_dir() else 0))
    files = []
    for p in entries:
        if not p.is_file():
            continue
        copy = DEST / p.relative_to(SOURCE)
        original_hash = digest(p)
        assert digest(copy) == original_hash
        files.append({'name': str(p.relative_to(SOURCE)), 'bytes': p.stat().st_size,
                      'sha256': original_hash})
    record = {'timeUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'original': str(SOURCE), 'privateCopy': str(DEST),
              'overlayLink': str(LINK), 'priorLinkTarget': os.readlink(LINK),
              'originalVolumeReadOnly': True, 'originalModified': False,
              'gameRestarted': False, 'shaderCacheDeleted': False, 'files': files,
              'deployed': False}
    PROOF.write_text(json.dumps(record, indent=2) + '\n')
    # Atomic replacement of this one workspace symlink. Never unlink its target.
    temp = OVERLAY / '.crashdata.private-next'
    assert not temp.exists() and not temp.is_symlink()
    temp.symlink_to(DEST)
    temp.replace(LINK)
    record['deployed'] = True
    PROOF.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
