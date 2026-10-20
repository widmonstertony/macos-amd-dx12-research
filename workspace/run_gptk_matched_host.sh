#!/bin/bash
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
wine_dir="$research_dir/gptk-wine-host-3/Game Porting Toolkit.app/Contents/Resources/wine"
original_lib="$research_dir/runtime-gptk4b2/redist/lib"
adapter="$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"
test -x "$wine_dir/bin/wine64"
test -f "$adapter"
if [ ! -d "$wine_dir/.gptk4-original-libraries-staged" ]; then
  cp -cR -p "$original_lib/external/." "$wine_dir/lib/external/"
  for module in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do
    cp -c -p "$original_lib/wine/x86_64-windows/$module.dll" "$wine_dir/lib/wine/x86_64-windows/$module.dll"
    ln -sf '../../external/libd3dshared.dylib' "$wine_dir/lib/wine/x86_64-unix/$module.so"
  done
  cmp "$original_lib/external/libd3dshared.dylib" "$wine_dir/lib/external/libd3dshared.dylib"
  cmp "$original_lib/external/D3DMetal.framework/Versions/A/D3DMetal" "$wine_dir/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
  mkdir "$wine_dir/.gptk4-original-libraries-staged"
fi
export WINEPREFIX="$research_dir/prefix-gptk-matched-host"
export WINEARCH=win64
export WINELOADER="$wine_dir/bin/wine64"
export WINESERVER="$wine_dir/bin/wineserver"
export WINEDLLPATH="$wine_dir/lib/wine"
export PATH="$wine_dir/bin:$PATH"
export DYLD_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib"
export DYLD_INSERT_LIBRARIES="$adapter"
export DYLD_PRINT_LIBRARIES="${GPTK4_DYLD_TRACE:-1}"
export GPU_ADAPTER_TIMEOUT_SECONDS=0
export GPU_ADAPTER_MODE="${GPU_ADAPTER_MODE:-gate}"
export D3DM_MTL4=0
export D3DM_ENABLE_METALFX=0
export MTL_HUD_ENABLED=0
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG="${GPTK4_WINEDEBUG:--all,+loaddll,+seh}"
probe_exe="${GPTK4_PROBE_EXE:-$research_dir/d3d12_probe.exe}"
test -f "$probe_exe"
cd "$research_dir"
set +e
"$wine_dir/bin/wine64" "$probe_exe" "$@" 2>&1 | tee "${GPTK4_LOG_PATH:-$research_dir/gptk-matched-host-probe.log}"
exit "${PIPESTATUS[0]}"
