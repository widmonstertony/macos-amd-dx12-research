#!/bin/bash
# Serial own-prefix probes, bounded by the runner, never by all-process kills.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
host_dir="$research_dir/Wine10-source/host"
stage="${1:-load}"
shift || true
case "$stage" in
  load) probe="$research_dir/windows_load_library_probe.exe";;
  copy) probe="$research_dir/d3d12_probe.exe";;
  compute) probe="$research_dir/compute-probe/d3d12_compute_probe.exe";;
  graphics) probe="$research_dir/graphics-probe/d3d12_graphics_probe.exe";;
  descriptor) probe="$research_dir/descriptor-probe/d3d12_descriptor_probe.exe";;
  presentation) probe="$research_dir/presentation-probe/d3d12_presentation_probe.exe";;
  *) printf 'Use load, copy, compute, graphics, descriptor, or presentation.\n' >&2; exit 2;;
esac
probe="${WINE10_PROBE_PATH:-$probe}"
probe_command=("$host_dir/bin/wine64" "$probe")
if [ "$stage" = load ]; then probe_command+=("${1:-all}"); fi
mode="${GPU_ADAPTER_MODE:-trace}"
case "$mode" in trace|gate) ;; *) exit 2;; esac
test -d "$host_dir/.original-gptk4-staged"
test -f "$probe"
unset DYLD_PRINT_LIBRARIES YYB_NTDLL_PATH YYB_WINESERVER_HOST_APP YYB_KEEPALIVE
export WINEPREFIX="$research_dir/prefix-clean-wine10-gptk4"
export WINEARCH=win64
export WINELOADER="$host_dir/bin/wine64"
export WINESERVER="$host_dir/bin/wineserver"
export WINEDLLPATH="$host_dir/lib/wine"
export DYLD_LIBRARY_PATH="$host_dir/lib/external:$host_dir/lib:/usr/local/opt/freetype/lib:/usr/local/opt/fontconfig/lib:/usr/local/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$host_dir/lib/external:$host_dir/lib:/usr/local/opt/freetype/lib:/usr/local/opt/fontconfig/lib:/usr/local/lib:/usr/lib"
export DYLD_INSERT_LIBRARIES="$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"
export GPU_ADAPTER_MODE="$mode"
export GPU_ADAPTER_TEXTURE_MODE=managed
export GPU_ADAPTER_RENDERPASS_NORMALIZE=1
export GPU_ADAPTER_TIMEOUT_SECONDS=0
export D3DM_MTL4=0 D3DM_ENABLE_METALFX=0 MTL_HUD_ENABLED=0
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG="${WINE10_PROBE_DEBUG:--all,+loaddll,+seh}"
log_file="${WINE10_PROBE_LOG:-$research_dir/clean-wine10-$stage-$mode.log}"
cd "$research_dir"
set +e
"${probe_command[@]}" > "$log_file" 2>&1 &
probe_pid=$!
timed_out=0
for ((elapsed=0; elapsed<180; elapsed++)); do
  kill -0 "$probe_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$probe_pid" 2>/dev/null; then
  timed_out=1
  printf '\nOWN_PROBE_RUNNER_TIMEOUT=180_SECONDS\n' >> "$log_file"
  kill -TERM "$probe_pid" 2>/dev/null
fi
wait "$probe_pid"
probe_status=$?
# This server path and prefix belong solely to this smoke-test runner.
env -u DYLD_INSERT_LIBRARIES -u DYLD_PRINT_LIBRARIES "$host_dir/bin/wineserver" -k
if [ "$timed_out" -eq 1 ]; then probe_status=124; fi
printf 'Stage: %s\nMode: %s\nExit: %s\nLog: %s\n' "$stage" "$mode" "$probe_status" "$log_file"
exit "$probe_status"
