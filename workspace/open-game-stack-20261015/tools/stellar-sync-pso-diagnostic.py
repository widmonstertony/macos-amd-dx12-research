#!/usr/bin/env python3
"""Prepare/apply a backed-up single-variable UE PSO scheduling diagnostic.

This is an A/B experiment, not a graphics compatibility or gameplay success claim.
"""
import argparse, datetime, hashlib, json, pathlib, subprocess

p = pathlib.Path(__file__).resolve().parents[1]
config = pathlib.Path('/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine/drive_c/users/tencentyyb/AppData/Local/SB/Saved/Config/WindowsNoEditor/Engine.ini')
parser = argparse.ArgumentParser()
parser.add_argument('--apply', type=pathlib.Path, metavar='PREPARED_DIRECTORY')
args = parser.parse_args()
sha = lambda data: hashlib.sha256(data).hexdigest()
if args.apply:
    dest = args.apply.resolve()
    if dest.parent != p/'evidence' or not dest.name.startswith('sync-pso-diagnostic-'):
        raise SystemExit('Use an owned prepared diagnostic directory')
    record = json.loads((dest/'manifest.json').read_text())
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
    if 'SB-Win64-Shipping.exe' in processes or '/StellarBlade/SB.exe' in processes:
        raise SystemExit('Do not change settings while the game is running')
    current = config.read_bytes()
    if sha(current) != record['beforeSHA256']:
        raise SystemExit('Settings changed since preparation; do not overwrite')
    replacement = (dest/'Engine.after.ini').read_bytes()
    if sha(replacement) != record['afterSHA256']:
        raise SystemExit('Prepared replacement changed')
    config.write_bytes(replacement)
    record['applied'] = True
    record['appliedUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    record['readbackMatched'] = config.read_bytes() == replacement
    (dest/'manifest.json').write_text(json.dumps(record, indent=2)+'\n')
else:
    before = config.read_bytes()
    lines = before.decode('utf-8').splitlines()
    section = None
    insertion = None
    found = False
    out = []
    for line in lines:
        if line.startswith('[') and line.endswith(']'):
            if section == 'SystemSettings' and insertion is None:
                insertion = len(out)
            section = line[1:-1]
        if section == 'SystemSettings' and line.split('=', 1)[0].strip() == 'r.AsyncPipelineCompile':
            line = 'r.AsyncPipelineCompile=0'
            found = True
        out.append(line)
    if not found:
        if section == 'SystemSettings' and insertion is None:
            insertion = len(out)
        if insertion is None:
            out.extend(['', '[SystemSettings]'])
            insertion = len(out)
        out.insert(insertion, 'r.AsyncPipelineCompile=0')
    after = ('\r\n'.join(out)+'\r\n').encode('utf-8')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    dest = p/'evidence'/('sync-pso-diagnostic-'+stamp)
    dest.mkdir()
    (dest/'Engine.before.ini').write_bytes(before)
    (dest/'Engine.after.ini').write_bytes(after)
    record = dict(config=str(config), beforeSHA256=sha(before), afterSHA256=sha(after),
        settings={'SystemSettings.r.AsyncPipelineCompile':'0'}, applied=False,
        purpose='Test whether removing UE asynchronous PSO compilation prevents the captured compute-task object lifetime crash',
        rootCauseProven=False, finalWorkaround=False, evictionDisabled=False,
        cacheDeleted=False, gameFilesModified=False, vendorEngineModified=False,
        existingFSRDiagnosticSettingsUnchanged=True,
        restoreFrom=str(dest/'Engine.before.ini'))
    (dest/'manifest.json').write_text(json.dumps(record, indent=2)+'\n')
print(dest)
print(json.dumps(record, indent=2))
