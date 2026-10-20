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
    parser.add_argument('--render-shards', action='store_true')
    parser.add_argument('--render-global-read-only', type=Path)
    parser.add_argument('--render-rehydrate', action='store_true')
    parser.add_argument('--compute-rehydrate', action='store_true')
    parser.add_argument('--replay-only', action='store_true')
    parser.add_argument('--fresh-mesh-libraries', action='store_true')
    parser.add_argument('--safe-mesh-libraries', action='store_true')
    parser.add_argument('--sync-mesh-libraries', action='store_true')
    parser.add_argument('--sync-mesh-pipelines',action='store_true')
    parser.add_argument('--mesh-link-differential',action='store_true')
    parser.add_argument('--disable-mesh-replay', action='store_true')
    parser.add_argument('--gpu-timeout-trace', action='store_true')
    parser.add_argument('--specialized-queues', action='store_true')
    parser.add_argument('--use-mtl-heap', action='store_true')
    parser.add_argument('--cross-encoder-live-cache', action='store_true')
    parser.add_argument('--batch-argument-heaps', action='store_true')
    parser.add_argument('--argument-heap-threshold', type=int, default=16)
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
    if args.use_mtl_heap:env['MVK_CONFIG_USE_MTLHEAP']='2'
    if args.cross_encoder_live_cache:
        env['MVK_AMD_ENCODER_LIVE_CACHE']='1'
        env['MVK_AMD_CROSS_ENCODER_LIVE_CACHE']='1'
    if args.batch_argument_heaps:
        if not args.use_mtl_heap:parser.error('--batch-argument-heaps requires --use-mtl-heap')
        if args.argument_heap_threshold < 1:parser.error('--argument-heap-threshold must be at least 1')
        env['MVK_AMD_BATCH_LIVE_USE_RESOURCE']='1'
        env['MVK_AMD_BATCH_ARGUMENT_HEAPS']='1'
        env['MVK_AMD_ARGUMENT_HEAP_THRESHOLD']=str(args.argument_heap_threshold)
    if args.replay_only:env['MVK_AMD_RUNTIME_REPLAY_ONLY']='1'
    if args.fresh_mesh_libraries:env['MVK_AMD_FRESH_MESH_LIBRARIES']='1'
    if args.safe_mesh_libraries:
        if not args.fresh_mesh_libraries:parser.error('--safe-mesh-libraries requires fresh libraries')
        env['MVK_AMD_SAFE_MESH_LIBRARIES']='1'
    if args.sync_mesh_libraries:
        if not args.safe_mesh_libraries:parser.error('--sync-mesh-libraries requires safe mesh libraries')
        env['MVK_AMD_SYNC_MESH_LIBRARIES']='1'
    if args.sync_mesh_pipelines:env['MVK_AMD_SYNC_MESH_PIPELINES']='1'
    if args.mesh_link_differential:env['MVK_AMD_LINK_DIFFERENTIAL_CAPTURE']='1'
    if args.disable_mesh_replay:env.pop('MVK_AMD_REPLAY_FAILED_MESH', None)
    if args.render_shards:
        env.pop('MVK_AMD_RENDER_BINARY_ARCHIVE_PATH', None)
        render_directory = out / 'render-shards'
        render_directory.mkdir()
        env.update(MVK_AMD_RENDER_ARCHIVE_DIR=str(render_directory),
                   MVK_AMD_RENDER_ARCHIVE_TRACE='1')
    if args.render_global_read_only:
        archive = args.render_global_read_only.resolve()
        if not archive.is_file():
            parser.error('--render-global-read-only must name an existing archive')
        env.pop('MVK_AMD_RENDER_ARCHIVE_DIR', None)
        env.update(MVK_AMD_RENDER_BINARY_ARCHIVE_PATH=str(archive),
                   MVK_AMD_RENDER_BINARY_ARCHIVE_READ_ONLY='1',
                   MVK_AMD_BINARY_ARCHIVE_MAX_BYTES=str(256 * 1024 * 1024))
    if args.render_rehydrate:
        env['MVK_AMD_RENDER_ARCHIVE_REHYDRATE'] = '1'
    if args.compute_rehydrate:
        env['MVK_AMD_COMPUTE_ARCHIVE_REHYDRATE'] = '1'
    candidate = private / "libCandidate.dylib"
    proxy = private / "libProbeGuard.dylib"
    shared = Path("/private/tmp/mvk-guard-proxy/libQualifiedCandidateReexport.dylib")
    shared_before = digest(shared)
    result = {"timeLocal": datetime.datetime.now().astimezone().isoformat(),
              "candidateSHA256": digest(candidate), "proxySHA256": digest(proxy),
              "liveGameLibrariesChanged": False, "gpuTimeoutTrace": args.gpu_timeout_trace,
              "specializedQueues": args.specialized_queues, "useMTLHeap": args.use_mtl_heap,
              "crossEncoderLiveCache": args.cross_encoder_live_cache,
              "batchArgumentHeaps": args.batch_argument_heaps,
              "argumentHeapThreshold": args.argument_heap_threshold, "results": {}}
    probes = [
        ("compute-seed", "d3d12_compute_probe.exe", "compute.result=PASS"),
        ("compute-load", "d3d12_compute_probe.exe", "compute.result=PASS"),
        ("present", "d3d12_presentation_probe.exe", "presentation.gpu_api_result=PASS"),
    ]
    if args.render_shards:
        probes[-1:] = [('present-seed', 'd3d12_presentation_probe.exe', 'presentation.gpu_api_result=PASS'),
                       ('present-warm', 'd3d12_presentation_probe.exe', 'presentation.gpu_api_result=PASS')]
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
        if args.render_shards and name == 'present-warm':
            run_env['MVK_AMD_RENDER_ARCHIVE_REQUIRE_HIT'] = '1'
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
        if args.render_shards and name.startswith('present-'):
            traces = [json.loads(f.read_text()) for f in (d / 'msl').glob('trace-render-archive-*.json')]
            entry['renderArchiveRecords'] = traces
            entry['strictNativeRenderHitVerified'] = bool(traces) and all(
                row['strictArchiveHit'] and not row['fallback'] and row['pipelineCreated']
                for row in traces)
            if name == 'present-warm':
                entry['passed'] = entry['passed'] and entry['strictNativeRenderHitVerified']
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
