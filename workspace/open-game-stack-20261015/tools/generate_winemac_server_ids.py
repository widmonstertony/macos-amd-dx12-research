#!/usr/bin/env python3
"""Audit immutable Tencent server dispatch names and generate five native IDs.

Only the source window driver uses the generated header. No server/core binary
or common Wine protocol header is patched. Unknown or missing handlers fail.
"""
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'vendor/cx26-reference/sources/wine'
SERVER = Path.home() / 'Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/MacOS/wineserver'
EXPECTED = ('set_queue_fd', 'set_capture_window', 'get_window_rectangles', 'set_window_pos', 'update_window_zorder')
data = SERVER.read_bytes()
symbols, names = {}, {}
for line in subprocess.check_output(['nm', '-an', str(SERVER)], text=True).splitlines():
    fields = line.split()
    if len(fields) != 3:
        continue
    try:
        address = int(fields[0], 16)
    except ValueError:
        continue
    symbols[address] = fields[2]
    names[fields[2]] = address
offset, segments = 32, []
for _ in range(struct.unpack_from('<I', data, 16)[0]):
    cmd, size = struct.unpack_from('<II', data, offset)
    if cmd == 0x19:
        segments.append(struct.unpack_from('<QQQQ', data, offset + 24))
    offset += size
table = names['_req_handlers']
file_offset = next(fo + table - vm for vm, _, fo, fs in segments if vm <= table < vm + fs)
handlers = []
for i in range(500):
    pointer = struct.unpack_from('<Q', data, file_offset + i * 8)[0]
    name = symbols.get(pointer)
    if not name or not name.startswith('_req_'):
        break
    handlers.append(name[5:])
source = (SRC / 'include/wine/server_protocol.h').read_text()
source_names = re.findall(r'REQ_\w+', source.split('enum request')[1].split('};')[0])
assert len(handlers) == 313 and len(source_names) == 307
actual = {name: handlers.index(name) for name in EXPECTED}
assert actual == dict(zip(EXPECTED, (116, 196, 157, 156, 165)))
mapping = {name: {'sourceID': source_names.index('REQ_' + name), 'installedID': actual[name]} for name in EXPECTED}
lines = ['/* Generated from the immutable original server dispatch table. */',
         '#ifndef MACDRV_YYB_SERVER_PROTOCOL_H', '#define MACDRV_YYB_SERVER_PROTOCOL_H',
         '/* Tencent inserts save_app_select_path at ordinal 7. All five direct',
         ' * server requests here otherwise retain the public request layouts. */']
for name, item in mapping.items():
    lines += [f'C_ASSERT(REQ_{name} == {item["sourceID"]});',
              f'#define MACDRV_YYB_REQ_{name} ((enum request){item["installedID"]})']
lines += ['#define MACDRV_YYB_SERVER_REQUEST(name, request) \\',
          '    ((request)->__header.req = MACDRV_YYB_REQ_##name)', '#endif', '']
(SRC / 'dlls/winemac.drv/yyb_server_protocol.h').write_text('\n'.join(lines))
record = {'server': str(SERVER), 'serverSHA256': hashlib.sha256(data).hexdigest(),
          'mapping': mapping, 'installedRequestCount': len(handlers),
          'extraInstalledRequests': [(i, n) for i, n in enumerate(handlers) if 'REQ_' + n not in source_names],
          'serverModified': False, 'sourceWindowModuleOnly': True}
(ROOT / 'evidence/winemac-compat-20261019/server-protocol-request-ids.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))
