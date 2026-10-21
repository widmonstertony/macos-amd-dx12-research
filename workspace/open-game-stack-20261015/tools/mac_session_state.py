#!/usr/bin/env python3
"""Read console lock booleans only. Never unlocks or exposes session identities."""
import json,plistlib,subprocess

def session_state():
    data=plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-n','Root','-d','1','-a']))
    root=data[0] if isinstance(data,list) else data
    console=[s for s in root.get('IOConsoleUsers',[]) if s.get('kCGSSessionOnConsoleKey')]
    flags=[s['CGSSessionScreenIsLocked'] for s in console if isinstance(s.get('CGSSessionScreenIsLocked'),bool)]
    root_flag=root.get('IOConsoleLocked')
    if isinstance(root_flag,bool):flags.append(root_flag)
    return {'lockStateKnown':bool(flags),'screenLocked':any(flags) if flags else None,'onConsole':bool(console)}

if __name__=='__main__':print(json.dumps(session_state()))
