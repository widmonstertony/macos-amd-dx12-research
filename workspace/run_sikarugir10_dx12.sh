#!/bin/bash
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
wine_dir="$research_dir/wine-sikarugir10/wswine.bundle"
stage="${1:-copy}"
if [ "$#" -gt 0 ]; then shift; fi
case "$stage" in
  load) program="$research_dir/windows_load_library_probe.exe";;
  copy) program="$research_dir/d3d12_probe.exe";;
  compute) program="$research_dir/compute-probe/d3d12_compute_probe.exe";;
  graphics) program="$research_dir/graphics-probe/d3d12_graphics_probe.exe";;
  stellar) program="$research_dir/stellar-overlay/SB/Binaries/Win64/SB-Win64-Shipping.exe";;
  steam) program="$research_dir/prefix-sikarugir10-probe/drive_c/Program Files (x86)/Steam/steam.exe";;
  *) printf 'Unknown isolated test stage\n' >&2; exit 2;;
esac
test -f "$program"
test -d "$wine_dir/.original-gptk4-staged"
export WINEPREFIX="$research_dir/prefix-sikarugir10-probe"
export WINEARCH=win64
export WINELOADER="$wine_dir/bin/wine"
export WINESERVER="$wine_dir/bin/wineserver"
export WINEDLLPATH="$wine_dir/lib/wine"
export PATH="$wine_dir/bin:$PATH"
export DYLD_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib"
export DYLD_INSERT_LIBRARIES="$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"
if [ "${GPTK4_PTHREAD_DIAGNOSTIC:-0}" = 1 ]; then
  export DYLD_INSERT_LIBRARIES="$DYLD_INSERT_LIBRARIES:$research_dir/pthread_rwlock_diagnostic.dylib"
fi
unset DYLD_PRINT_LIBRARIES
if [ "${GPTK4_DYLD_TRACE:-0}" = 1 ]; then export DYLD_PRINT_LIBRARIES=1; fi
export GPU_ADAPTER_MODE="${GPU_ADAPTER_MODE:-gate}"
export GPU_ADAPTER_TEXTURE_MODE=managed
export GPU_ADAPTER_RENDERPASS_NORMALIZE=1
export GPU_ADAPTER_TIMEOUT_SECONDS=0
export D3DM_MTL4=0
export D3DM_ENABLE_METALFX=0
export MTL_HUD_ENABLED=0
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG="${GPTK4_WINEDEBUG:--all,err+all,+loaddll,+seh}"
export WINEESYNC=0
export WINEFSYNC=0
export SteamAppId=3489700
if [ "$stage" = stellar ]; then
  cd "$(dirname -- "$program")"
  set -- SB -DistributionPlatform=Steam -dx12 -windowed -ResX=1280 -ResY=800 -NoSplash -NoStartupMovies -log "$@"
else
  cd "$research_dir"
fi
set +e
"$wine_dir/bin/wine" "$program" "$@" 2>&1 | tee "$research_dir/sikarugir10-$stage.log"
exit "${PIPESTATUS[0]}"
