#!/bin/bash
# Executes the original GPTK4 runtime through the isolated Wine copy.
# Default is the trace/control adapter; gate is a separately labelled experiment.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
isolated_wine="$research_dir/wine-gptk4-isolated"
adapter="$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"
mode="${GPU_ADAPTER_MODE:-trace}"
case "$mode" in trace|name|gate) ;; *) printf 'GPU_ADAPTER_MODE must be trace, name, or gate.\n' >&2; exit 2;; esac
probe_exe="${GPTK4_PROBE_EXE:-$research_dir/d3d12_probe.exe}"
test -d "$isolated_wine/.gptk4-copy-prepared"
test -x "$isolated_wine/bin/wine"
test -x "$isolated_wine/bin/wineserver"
test -f "$adapter"
test -f "$probe_exe"

export WINEPREFIX="$research_dir/prefix-gptk4-adapter"
export WINEARCH=win64
export WINELOADER="$isolated_wine/bin/wine"
export WINESERVER="$isolated_wine/bin/wineserver"
export PATH="$isolated_wine/bin:$PATH"
export DYLD_LIBRARY_PATH="$isolated_wine/lib/external:$isolated_wine/lib:/usr/local/opt/vulkan-loader/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$isolated_wine/lib/external:$isolated_wine/lib"
export DYLD_INSERT_LIBRARIES="$adapter"
export DYLD_PRINT_LIBRARIES="${GPTK4_DYLD_TRACE:-1}"
export GPU_ADAPTER_MODE="$mode"
export D3DM_MTL4=0
export D3DM_ENABLE_METALFX=0
export MTL_HUD_ENABLED=0
# Original GPTK PE files are Wine builtins. The copy's own dll_dir now takes
# precedence, so b selects GPTK4 instead of the original runtime's wined3d.
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG='-all,+loaddll,+seh'
log_path="$research_dir/gptk4-wine-$mode-probe.log"
printf 'Isolated Wine: %s\nPrefix: %s\nAdapter mode: %s\nProbe: %s\n' "$isolated_wine" "$WINEPREFIX" "$mode" "$probe_exe"
cd "$research_dir"
set +e
"$isolated_wine/bin/wine" "$probe_exe" "$@" 2>&1 | tee "$log_path"
exit "${PIPESTATUS[0]}"
