#!/usr/bin/env python3
"""Qualify a per-module winevulkan RPATH selector on Tencent Wine and real AMD GPU output."""
from __future__ import annotations

import datetime, hashlib, json, os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = Path.home() / "Library/Application Support/YYBIntelLauncher"
CONTENTS = SUPPORT / ".runtime/wine-engine.app/Contents"
PREFIX = Path.home() / "Library/Application Support/com.tencent.yybmac.wine.engine/wine"
SELECTOR_ROOT = ROOT / "build/wine-mvk-selector-root"
SELECTOR_UNIX = SELECTOR_ROOT / "lib/wine/x86_64-unix"
SELECTOR = SELECTOR_UNIX / "winevulkan.so"
PROXY = Path("/private/tmp/mvk-guard-proxy/libMoltenVKGuard.dylib")
CANDIDATE = Path("/private/tmp/mvk-guard-proxy/libQualifiedCandidateReexport.dylib")

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main() -> int:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = ROOT / "evidence" / f"winevulkan-selector-gpu-{stamp}"
    out.mkdir()
    engine_wine = CONTENTS / "SharedSupport/wine/lib/wine"
    env = {k:v for k,v in os.environ.items() if not k.startswith(("DYLD_","WINE","YYB_","VK_","VKD3D_","DXVK_","MVK_"))}
    env.update(
        WINEPREFIX=str(PREFIX), YYB_NTDLL_PATH=str(SELECTOR_UNIX / "ntdll.so"),
        WINELOADER=str(SUPPORT / "wine-loader"), WINESERVER=str(CONTENTS / "MacOS/wineserver"),
        WINEDLLPATH=f"{SELECTOR_UNIX}:{SELECTOR_ROOT / 'lib/wine/x86_64-windows'}:{engine_wine / 'x86_64-unix'}:{engine_wine / 'x86_64-windows'}", GFX_BACKEND_PATH=str(ROOT / "backend/wine"),
        WINEDEBUG="-all,err+all,+loaddll", WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n",
        DYLD_PRINT_LIBRARIES="1", VKD3D_AMD_PROTECTED_SUBSET="1",
        VKD3D_FILTER_DEVICE_NAME="AMD Radeon Pro 5600M", DXVK_FILTER_DEVICE_NAME="AMD Radeon Pro 5600M",
        VKD3D_DEBUG="info", MVK_AMD_REFERENCE_RBA2="1", MVK_AMD_REFERENCE_RIA2="1",
        MVK_AMD_REFERENCE_NULL="1", MVK_AMD_BYTE_GUARDS="1", MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS="1",
        MVK_CONFIG_LOG_LEVEL="2", MVK_AMD_RUNTIME_TRACE="1", VKD3D_AMD_RUNTIME_TRACE="1",
        MVK_AMD_REPLAY_FAILED_MESH="1", MVK_AMD_SERIALIZE_PIPELINE_LINK="1", MVK_AMD_COHERENT_ATOMICS="1",
        MVK_AMD_ENCODER_LIVE_CACHE="1", MVK_AMD_LIVE_LOOKUP_FAST_CACHE="1", MVK_AMD_DESCRIPTOR_USE_CACHE="1",
        MVK_AMD_BINARY_ARCHIVE_PATH=str(ROOT / "build/game-metal-binary-cache/compute-bounded-v2.metalar"),
        MVK_AMD_RENDER_BINARY_ARCHIVE_PATH=str(ROOT / "build/game-metal-binary-cache/render-bounded-v2.metalar"),
        MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL="64", MVK_AMD_BINARY_ARCHIVE_MAX_BYTES=str(256*1024*1024),
    )
    probes={
        "device":(ROOT/"probe-app/d3d12_probe.exe","copy_smoke.result=PASS"),
        "compute":(ROOT/"probe-app/d3d12_compute_probe.exe","compute.result=PASS"),
        "present":(ROOT/"probe-app/d3d12_presentation_probe.exe","presentation.gpu_api_result=PASS"),
    }
    summary={"timeUTC":datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "selector":str(SELECTOR),"selectorSHA256":digest(SELECTOR),
             "proxy":str(PROXY),"proxySHA256":digest(PROXY),
             "candidate":str(CANDIDATE),"candidateSHA256":digest(CANDIDATE),"results":{}}
    for name,(program,marker) in probes.items():
        d=out/name;d.mkdir();(d/"msl").mkdir()
        run_env=env|{"YYB_OPEN_GUARD_RECORD":str(d/"guard.trace"),"YYB_OPEN_GUARD_FORCE":"1",
                     "MVK_CONFIG_SHADER_DUMP_DIR":str(d/"msl"),
                     "VKD3D_LOG_FILE":"Z:"+str(d/"vkd3d.log").replace("/Users/tonytan","").replace("/","\\")}
        run=subprocess.run([str(SUPPORT/"wine-loader"),str(program)],cwd=program.parent,env=run_env,
                           text=True,capture_output=True,timeout=120)
        (d/"stdout.log").write_text(run.stdout);(d/"stderr.log").write_text(run.stderr)
        guard=(d/"guard.trace").read_text(errors="replace") if (d/"guard.trace").exists() else ""
        result={"exitCode":run.returncode,"actualOutputPassed":run.returncode==0 and marker in run.stdout,
                "selectorMapped":str(SELECTOR) in run.stderr,"proxyMapped":str(PROXY) in run.stderr or "/tmp/mvk" in run.stderr,
                "candidateMapped":str(CANDIDATE) in run.stderr,"guardReady":"step=guard-ready" in guard,"marker":marker}
        summary["results"][name]=result
        if not all((result["actualOutputPassed"],result["selectorMapped"],result["proxyMapped"],result["candidateMapped"],result["guardReady"])):
            (out/"run.json").write_text(json.dumps(summary,indent=2)+"\n")
            print(json.dumps({"directory":str(out),"passed":False,"failed":name,"result":result}),flush=True)
            return 1
    summary["passed"]=True;(out/"run.json").write_text(json.dumps(summary,indent=2)+"\n")
    print(json.dumps({"directory":str(out),"passed":True}),flush=True);return 0

if __name__=="__main__":raise SystemExit(main())
