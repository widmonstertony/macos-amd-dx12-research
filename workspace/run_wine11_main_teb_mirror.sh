#!/bin/bash
# Uses only own research runtime/prefix, no injected Metal GPU capability gate.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
wine_dir="$research_dir/wine-gptk4-isolated"
unset DYLD_INSERT_LIBRARIES DYLD_PRINT_LIBRARIES
export WINEPREFIX="$research_dir/prefix-gptk4-adapter"
export WINEARCH=win64
export WINELOADER="$wine_dir/bin/wine"
export WINESERVER="$wine_dir/bin/wineserver"
export DYLD_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib:/usr/local/opt/vulkan-loader/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib"
export D3DM_MTL4=0 D3DM_ENABLE_METALFX=0 MTL_HUD_ENABLED=0
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG='-all,+loaddll,+seh'
cd "$research_dir"
probe_exe="${WINE11_MIRROR_PROBE:-$research_dir/windows_wine10_teb_mirror_probe.exe}"
log_file="${WINE11_MIRROR_LOG:-$research_dir/wine11-main-teb-mirror.log}"
test -f "$probe_exe"
set +e
"$wine_dir/bin/wine" "$probe_exe" "${1:-all}" > "$log_file" 2>&1
probe_status=$?
printf 'Mirror diagnostic exit: %s\nLog: %s\n' "$probe_status" "$log_file"
exit "$probe_status"
