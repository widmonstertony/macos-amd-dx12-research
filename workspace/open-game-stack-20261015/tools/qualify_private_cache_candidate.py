#!/usr/bin/env python3
"""Qualify the staged cache repair without replacing the live game's backend.

Only owned GPU probes run. Original Tencent Wine, its prefix, the asset guard,
and the running Steam/game are reused; no registry or shared-selector edits.
"""
import ast
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import qualify_late_guard as qualified

ROOT = qualified.ROOT
PRIVATE = ROOT / "build/mvk-cache-candidate-probe"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--private-directory', type=Path, default=PRIVATE)
    parser.add_argument('--compute-shards', action='store_true')
    parser.add_argument('--gpu-timeout-trace', action='store_true')
    parser.add_argument('--specialized-queues', action='store_true')
    args = parser.parse_args()
    private = args.private_directory.resolve()
    if not private.is_relative_to(ROOT / 'build') or not (private / 'libCandidate.dylib').is_file():
        parser.error('An existing private candidate directory in owned build is required')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = ROOT / "evidence" / ("private-cache-wine-" + stamp)
    out.mkdir()
    # Reuse the already audited environment without executing its mutable main.
    tree = ast.parse((ROOT / "tools/qualify_late_guard.py").read_text())
    main_function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "main")
    update = next(n for n in main_function.body if isinstance(n, ast.Expr)
                  and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Attribute)
                  and n.value.func.attr == "update")
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("DYLD_", "WINE", "YYB_", "VK_", "VKD3D_", "DXVK_", "MVK_"))}
    eval(compile(ast.Expression(update.value), "qualified-environment", "eval"),
         qualified.__dict__ | {"env": env})
    env.update(DYLD_LIBRARY_PATH=str(private / "select") + ":" +
               str(ROOT / "build/winemac-lockfix-leaf-select"),
               MVK_AMD_BINARY_ARCHIVE_PATH=str(out / "compute.metalar"),
               MVK_AMD_RENDER_BINARY_ARCHIVE_PATH=str(out / "render.metalar"),
               MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL="1",
               MVK_AMD_RUNTIME_REPLAY_ONLY="1")
    if args.compute_shards:
        env.pop('MVK_AMD_BINARY_ARCHIVE_PATH', None)
        env.pop('MVK_AMD_RUNTIME_REPLAY_ONLY', None)
        shard_directory = out / 'compute-shards'
        shard_directory.mkdir()
        env.update(MVK_AMD_COMPUTE_ARCHIVE_DIR=str(shard_directory),
                   MVK_AMD_COMPUTE_ARCHIVE_TRACE='1')
    if args.gpu_timeout_trace:env['MVK_AMD_GPU_TIMEOUT_TRACE']='1'
    if args.specialized_queues:env['MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES']='1'
    candidate = private / "libCandidate.dylib"
    proxy = private / "libProbeGuard.dylib"
    shared = Path("/private/tmp/mvk-guard-proxy/libQualifiedCandidateReexport.dylib")
    shared_before = digest(shared)
    result = {"timeLocal": datetime.datetime.now().astimezone().isoformat(),
              "candidateSHA256": digest(candidate), "proxySHA256": digest(proxy),
              "liveGameLibrariesChanged": False, "gpuTimeoutTrace": args.gpu_timeout_trace, "specializedQueues": args.specialized_queues, "results": {}}
    probes = [
        ("compute-seed", "d3d12_compute_probe.exe", "compute.result=PASS"),
        ("compute-load", "d3d12_compute_probe.exe", "compute.result=PASS"),
        ("present", "d3d12_presentation_probe.exe", "presentation.gpu_api_result=PASS"),
    ]
    for name, filename, marker in probes:
        d = out / name
        d.mkdir()
        (d / "msl").mkdir()
        executable = d / filename
        shutil.copy2(Path("/private/tmp/yyb-probe-app") / filename, executable)
        for dll in ("d3d12.dll", "d3d12core.dll", "dxgi.dll"):
            shutil.copy2(Path("/private/tmp/yyb-probe-app") / dll, d / dll)
        run_env = env | {"YYB_OPEN_GUARD_FORCE": "1",
                         "YYB_OPEN_GUARD_RECORD": str(d / "guard.trace"),
                         "MVK_CONFIG_SHADER_DUMP_DIR": str(d / "msl"),
                         "VKD3D_LOG_FILE": "Z:" + str(d / "vkd3d.log").replace("/Users/tonytan", "").replace("/", "\\")}
        if args.compute_shards and name == 'compute-load':
            run_env['MVK_AMD_COMPUTE_ARCHIVE_REQUIRE_HIT'] = '1'
        with (d / "stdout.log").open("w") as stdout, (d / "stderr.log").open("w") as stderr:
            p = subprocess.Popen([str(qualified.SUPPORT / "wine-loader"), str(executable)],
                                 env=run_env, cwd=d, stdout=stdout, stderr=stderr,
                                 start_new_session=True)
            timed_out = False
            try:
                code = p.wait(timeout=40)
            except subprocess.TimeoutExpired:
                timed_out = True
                # Stop this owned probe only; never stop a shared service.
                p.terminate()
                try:
                    code = p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    code = p.wait(timeout=5)
        stdout = (d / "stdout.log").read_text(errors="replace")
        stderr = (d / "stderr.log").read_text(errors="replace")
        guard = (d / "guard.trace").read_text() if (d / "guard.trace").exists() else ""
        entry = {"pid": p.pid, "exitCode": code, "timedOut": timed_out,
                 "actualGPUOutputPassed": code == 0 and marker in stdout,
                 "privateCandidateMapped": str(candidate) in stderr,
                 "privateProxyMapped": str(proxy) in stderr,
                 "assetGuardReady": "step=guard-ready" in guard,
                 "sharedGameCandidateMapped": str(shared) in stderr,
                 "nativeCacheBytes": (out / "compute.metalar").stat().st_size
                    if (out / "compute.metalar").exists() else 0}
        if args.compute_shards:
            traces = [json.loads(f.read_text()) for f in (d / 'msl').glob('trace-compute-archive-*.json')]
            entry['computeArchiveRecords'] = traces
            entry['nativeArchiveHitVerified'] = bool(traces) and all(
                row['loaded'] and row['requireHit'] and row['pipelineCreated'] for row in traces)
        entry["passed"] = (entry["actualGPUOutputPassed"] and entry["privateCandidateMapped"]
                           and entry["privateProxyMapped"] and entry["assetGuardReady"]
                           and not entry["sharedGameCandidateMapped"])
        if args.compute_shards and name == 'compute-load':
            entry['passed'] = entry['passed'] and entry['nativeArchiveHitVerified']
        result["results"][name] = entry
        print(json.dumps({name: {k:v for k,v in entry.items() if k!="computeArchiveRecords"}}), flush=True)
        if not entry["passed"]:
            break
    result["sharedGameCandidateUnchanged"] = digest(shared) == shared_before
    result["passed"] = (len(result["results"]) == len(probes)
                        and all(v["passed"] for v in result["results"].values())
                        and result["sharedGameCandidateUnchanged"])
    result["nativeArchiveHitRateMeasured"] = args.compute_shards and result['results'].get('compute-load', {}).get('nativeArchiveHitVerified', False)
    result["actualGamePerformanceMeasured"] = False
    (out / "run.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"evidence": str(out), "passed": result["passed"]}), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
