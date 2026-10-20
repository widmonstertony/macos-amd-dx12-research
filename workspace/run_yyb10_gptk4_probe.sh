#!/bin/bash
# Own-process probes only; original GPTK4 libraries remain unmodified.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
target_contents="$research_dir/wine-yyb10-gptk4-isolated.app/Contents"
builtin_lib="$target_contents/SharedSupport/wine/lib/wine"
frameworks="$target_contents/Frameworks"
backend="$frameworks/render/gptk"
stage="${1:-load}"
shift || true
case "$stage" in
  load) probe="$research_dir/windows_load_library_probe.exe"; probe_args=("${1:-all}");;
  gpu) probe="$research_dir/d3d12_probe.exe"; probe_args=("$@");;
  *) printf 'Use stage load [all|user32|dxgi|d3d12] or gpu.\n' >&2; exit 2;;
esac
mode="${GPU_ADAPTER_MODE:-trace}"
case "$mode" in trace|name|gate) ;; *) exit 2;; esac
test -d "$research_dir/wine-yyb10-gptk4-isolated.app/.gptk4-research-prepared"
test -x "$research_dir/yyb10-research-loader"
test -x "$target_contents/MacOS/wineserver"
test -f "$probe"
unset DYLD_PRINT_LIBRARIES YYB_WINESERVER_HOST_APP YYB_KEEPALIVE
export YYB_NTDLL_PATH="$builtin_lib/x86_64-unix/ntdll.so"
export WINEPREFIX="$research_dir/prefix-yyb10-gptk4-probe"
export WINEARCH=win64
export WINELOADER="$research_dir/yyb10-research-loader"
export WINESERVER="$target_contents/MacOS/wineserver"
export WINEDLLPATH="$builtin_lib"
export GFX_BACKEND_PATH="$backend/wine"
export DYLD_LIBRARY_PATH="$backend/external:$frameworks"
export DYLD_FALLBACK_LIBRARY_PATH="$backend/external:$frameworks"
export DYLD_INSERT_LIBRARIES="$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"
export GPU_ADAPTER_MODE="$mode"
export GPU_ADAPTER_TIMEOUT_SECONDS=0
export D3DM_MTL4=0 D3DM_ENABLE_METALFX=0 MTL_HUD_ENABLED=0
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG="${YYB10_PROBE_DEBUG:--all,+loaddll,+seh}"
log_file="$research_dir/yyb10-gptk4-$stage-$mode.log"
cd "$research_dir"
set +e
"$research_dir/yyb10-research-loader" "$probe" "${probe_args[@]}" > "$log_file" 2>&1
probe_status=$?
printf 'Stage: %s\nMode: %s\nExit: %s\nLog: %s\n' "$stage" "$mode" "$probe_status" "$log_file"
exit "$probe_status"
