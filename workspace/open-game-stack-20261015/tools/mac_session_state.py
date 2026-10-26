#!/usr/bin/env python3
"""Selected public display/session metadata, with point-observation semantics.

No screenshots, input, session identities, credentials or raw session dictionary
are returned. Missing booleans stay unknown; visibility/idle never implies lock.
"""
from __future__ import annotations
import ctypes as C
import json
import plistlib
import subprocess
import time

SESSION_KEYS=('CGSSessionScreenIsLocked','kCGSessionOnConsoleKey',
              'kCGSSessionOnConsoleKey','kCGSessionLoginDoneKey',
              'kCGSSessionLoginDoneKey')
POWER_KEYS=('DevicePowerState','CurrentPowerState','CapabilityFlags','MaxPowerState')


def _session_booleans():
    """Read only known CFBoolean keys; never enumerate a session dictionary."""
    selected={key:None for key in SESSION_KEYS}
    try:
        cg=C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf=C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGSessionCopyCurrentDictionary.restype=C.c_void_p
        cf.CFStringCreateWithCString.argtypes=[C.c_void_p,C.c_char_p,C.c_uint32];cf.CFStringCreateWithCString.restype=C.c_void_p
        cf.CFDictionaryGetValue.argtypes=[C.c_void_p,C.c_void_p];cf.CFDictionaryGetValue.restype=C.c_void_p
        cf.CFGetTypeID.argtypes=[C.c_void_p];cf.CFGetTypeID.restype=C.c_ulong
        cf.CFBooleanGetTypeID.restype=C.c_ulong
        cf.CFBooleanGetValue.argtypes=[C.c_void_p];cf.CFBooleanGetValue.restype=C.c_bool
        cf.CFRelease.argtypes=[C.c_void_p]
        dictionary=cg.CGSessionCopyCurrentDictionary()
        if not dictionary:return {'available':False,'selected':selected,'reason':'session-dictionary-unavailable'}
        try:
            for key in SESSION_KEYS:
                name=cf.CFStringCreateWithCString(None,key.encode(),0x08000100)
                if not name:continue
                try:
                    value=cf.CFDictionaryGetValue(dictionary,name)
                    if value and cf.CFGetTypeID(value)==cf.CFBooleanGetTypeID():selected[key]=bool(cf.CFBooleanGetValue(value))
                finally:cf.CFRelease(name)
        finally:cf.CFRelease(dictionary)
        return {'available':True,'selected':selected}
    except (OSError,AttributeError):return {'available':False,'selected':selected,'reason':'public-session-query-unavailable'}


def _ioreg_node(name):
    # Query one named public node, with bounded time and retained payload. Never
    # query Root/IOConsoleUsers, which could contain session identity fields.
    try:
        result=subprocess.run(['/usr/sbin/ioreg','-r','-n',name,'-d','1','-a'],capture_output=True,timeout=1)
        if result.returncode:return {'available':False,'reason':'ioreg-nonzero','exitCode':result.returncode}
        if len(result.stdout)>1024*1024:return {'available':False,'reason':'ioreg-payload-over-1MiB'}
        nodes=plistlib.loads(result.stdout)
        if not isinstance(nodes,list) or not nodes or not isinstance(nodes[0],dict):return {'available':False,'reason':'node-unavailable'}
        return {'available':True,'node':nodes[0]}
    except (OSError,subprocess.TimeoutExpired,ValueError,plistlib.InvalidFileException):return {'available':False,'reason':'ioreg-query-unavailable'}


def _consistent_bool(values):
    flags=[value for value in values if type(value) is bool]
    return flags[0] if flags and all(value==flags[0] for value in flags) else None


def session_state():
    begin=time.monotonic();unix=time.time();session=_session_booleans();session['queryStartUnixSeconds']=unix;session['queryEndUnixSeconds']=time.time();selected=session['selected']
    locked=_consistent_bool([selected.get('CGSSessionScreenIsLocked')])
    on_console=_consistent_bool([selected.get('kCGSessionOnConsoleKey'),selected.get('kCGSSessionOnConsoleKey')])
    power_begin=time.time();power=_ioreg_node('IODisplayWrangler');power.update(queryStartUnixSeconds=power_begin,queryEndUnixSeconds=time.time());node=power.pop('node',{});management=node.get('IOPowerManagement',{})
    power['selected']={key:value for key in POWER_KEYS if type(value:=management.get(key)) is int} if isinstance(management,dict) else {}
    power['interpretation']='Raw power-state numbers only; no physical visibility or historical power inference.'
    idle_begin=time.time();idle=_ioreg_node('IOHIDSystem');idle.update(queryStartUnixSeconds=idle_begin,queryEndUnixSeconds=time.time());node=idle.pop('node',{});idle_ns=node.get('HIDIdleTime')
    idle['HIDIdleTimeNS']=idle_ns if type(idle_ns) is int and idle_ns>=0 else None
    idle['interpretation']='Point sample of HID idle counter; idle does not establish lock, sleep or user intent.'
    end=time.monotonic();end_unix=time.time()
    return {'schema':2,'observedUnixSeconds':unix,'observedMonotonicSeconds':begin,
        'observationStartUnixSeconds':unix,'observationEndUnixSeconds':end_unix,'observationStartMonotonicSeconds':begin,'observationEndMonotonicSeconds':end,'fieldsObservedSimultaneously':False,
        'collectionSeconds':end-begin,'lockStateKnown':locked is not None,'screenLocked':locked,
        'onConsole':on_console,'onConsoleKnown':on_console is not None,'sessionBooleans':session,
        'displayPower':power,'idle':idle,'historicalStateKnown':False,'physicalDisplayVisibilityKnown':False,
        'scope':'Bracketed public queries, not simultaneous fields or continuous interval proof; never extend backwards or infer lock/power from active/foreground/CGWindowOnscreen.',
        'privateSessionFieldsRead':False,'screenshotOrInputUsed':False}


if __name__=='__main__':print(json.dumps(session_state()))
