#!/usr/bin/env python3
"""Read-only extraction of a bounded sample from the live vkd3d cache append.

Layout, FNV checksum and unsigned varints follow vendored vkd3d cache.c.
This captures converted shader inputs for offline diagnostics, not game data
or native GPU outputs. It neither changes the cache nor starts the game.
"""
import collections
import datetime
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
MASK = (1 << 64) - 1


def mix(h, value):
    return ((h * 0x100000001b3) ^ value) & MASK


def decode(payload):
    if len(payload) < 12:
        raise ValueError("Short internal SPIRV blob")
    length, compressed = struct.unpack_from("<II", payload, 4)
    if length % 4 or length > 16 * 1024 * 1024 or compressed != len(payload) - 12:
        raise ValueError("Unexpected SPIRV blob bounds")
    words, value, shift = [], 0, 0
    for byte in payload[12:]:
        if shift >= 32:
            raise ValueError("Invalid 32-bit varint")
        value |= (byte & 127) << shift
        shift += 7
        if not byte & 128:
            if value > 0xffffffff:
                raise ValueError("Varint overflow")
            words.append(value)
            value, shift = 0, 0
    if shift or len(words) * 4 != length or len(words) < 5 or words[0] != 0x07230203:
        raise ValueError("Invalid decoded SPIRV header/length")
    models, ops, pos = [], collections.Counter(), 5
    while pos < len(words):
        count, opcode = words[pos] >> 16, words[pos] & 65535
        if not count or pos + count > len(words):
            raise ValueError("Invalid SPIRV instruction boundary")
        ops[opcode] += 1
        if opcode == 15:
            models.append(words[pos + 1])
        pos += count
    return words, models, ops


def main():
    cache = ROOT.parent / "stellar-overlay/SB/Binaries/Win64/vkd3d-proton.cache.write"
    out = ROOT / "evidence" / ("recent-compute-inputs-" +
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    out.mkdir()
    recent = collections.deque(maxlen=200)
    size = cache.stat().st_size
    pos = 48
    with cache.open("rb") as stream:
        stream.seek(pos)
        while pos + 24 <= size:
            header = stream.read(24)
            if len(header) != 24:
                break
            key, checksum, length, kind = struct.unpack("<QQII", header)
            advance = 24 + (length + 7) // 8 * 8
            if pos + advance > size:
                break
            if kind == 0:
                recent.append((length, pos, key, checksum))
            pos += advance
            stream.seek(pos)
        # Recent records establish representative inputs, not their exact
        # association with any particular long-running native compilation.
        selected = sorted(recent, reverse=True)[:4] + list(recent)[-4:]
        result, seen = [], set()
        for length, offset, key, checksum in selected:
            if key in seen:
                continue
            seen.add(key)
            stream.seek(offset + 24)
            payload = stream.read(length)
            h = 0xcbf29ce484222325
            for byte in payload:
                h = mix(h, byte)
            for value in [key & 0xffffffff, key >> 32, length, 0]:
                h = mix(h, value)
            if h != checksum:
                raise ValueError("Cache checksum failure; extraction stopped")
            words, models, ops = decode(payload)
            if models != [5]:
                continue
            binary = struct.pack("<" + "I" * len(words), *words)
            file = out / (f"{key:016x}.spv")
            file.write_bytes(binary)
            result.append({"file": file.name, "key": f"{key:016x}",
                           "SHA256": hashlib.sha256(binary).hexdigest(),
                           "bytes": len(binary), "idBound": words[3],
                           "instructionCount": sum(ops.values()),
                           "functions": ops[54], "functionCalls": ops[57],
                           "loops": ops[246], "conditionalBranches": ops[250],
                           "cacheChecksumPassed": True, "executionModels": models})
    manifest = {"timeLocal": datetime.datetime.now().astimezone().isoformat(),
                "source": str(cache), "sourceSnapshotBytes": size,
                "parsedBytes": pos, "ignoredIncompleteTailBytes": size - pos,
                "sourceModified": False, "samples": result,
                "exactSlowRequestAssociationKnown": False,
                "semanticSPIRVValidationOrGPUExecutionPerformed": False}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"directory": str(out), **manifest}, indent=2))


if __name__ == "__main__":
    main()
