#!/usr/bin/env python3
"""Remove only the six legacy forced-off FSR3 overrides; dry-run by default.

Never selects a user's upscaler/frame-generation mode or starts the game.
An exact backup and a matching dry-run hash are mandatory for applying.
"""
import argparse, datetime, hashlib, json, os, re, stat, subprocess, tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
KEYS={
    'r.FidelityFX.FSR3.Enabled','r.FidelityFX.FI.Enabled',
    'r.FidelityFX.FI.OverrideSwapChainDX12','r.FidelityFX.FI.AllowAsyncWorkloads',
    'r.FidelityFX.FSR3.UseNativeDX12','r.FidelityFX.FSR3.UseRHI',
}
def remove_overrides(raw):
    bom=raw.startswith(b'\xef\xbb\xbf');text=raw.decode('utf-8-sig')
    section='';kept=[];removed=[]
    for line in text.splitlines(keepends=True):
        stripped=line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):section=stripped.lower()
        match=re.fullmatch(r'\s*([^=;#]+?)\s*=\s*0(?:\.0+)?\s*',line.rstrip('\r\n'))
        if section=='[systemsettings]' and match and match.group(1) in KEYS:
            removed.append(match.group(1));continue
        kept.append(line)
    return (b'\xef\xbb\xbf' if bom else b'')+''.join(kept).encode('utf-8'),removed

def main():
    p=argparse.ArgumentParser();p.add_argument('--apply',action='store_true')
    p.add_argument('--expected-sha256');p.add_argument('--backup-directory',type=Path)
    a=p.parse_args()
    path=Path.home()/'Library/Application Support/com.tencent.yybmac.wine.engine/wine/drive_c/users/tencentyyb/AppData/Local/SB/Saved/Config/WindowsNoEditor/Engine.ini'
    raw=path.read_bytes();before=hashlib.sha256(raw).hexdigest();updated,removed=remove_overrides(raw)
    result={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'beforeSHA256':before,
            'afterSHA256':hashlib.sha256(updated).hexdigest(),'removedForcedOffKeys':removed,
            'userSelectedModesModified':False,'gameStarted':False,'applied':False}
    if a.apply:
        assert a.expected_sha256==before,'INI changed since dry-run; no write'
        rows=subprocess.check_output(['ps','-A','-o','comm='],text=True,errors='replace').splitlines()
        assert not any(x.rstrip().endswith(('\\SB-Win64-Shipping.exe','\\SB.exe')) for x in rows),'Game running; no write'
        assert removed and set(removed)==KEYS,'Expected exact legacy override set; no write'
        backup=a.backup_directory.resolve() if a.backup_directory else None
        assert backup and backup.is_relative_to(ROOT/'evidence') and not backup.exists()
        backup.mkdir();(backup/'Engine.ini.before').write_bytes(raw)
        assert path.read_bytes()==raw,'Concurrent INI change; no write'
        old_mode=stat.S_IMODE(path.stat().st_mode)
        with tempfile.NamedTemporaryFile(dir=path.parent,prefix='.Engine.ini.v37-',delete=False) as f:
            temp=Path(f.name);f.write(updated);f.flush();os.fsync(f.fileno())
        os.chmod(temp,old_mode);os.replace(temp,path)
        assert path.read_bytes()==updated
        result.update(applied=True,backup=str(backup/'Engine.ini.before'))
        (backup/'change.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
