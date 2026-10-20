#!/bin/bash
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
wine_dir="$research_dir/wine-sikarugir10/wswine.bundle"
original_lib="$research_dir/runtime-gptk4b2/redist/lib"
test -f "$wine_dir/lib/wine/x86_64-unix/ntdll.so"
test -x "$wine_dir/bin/wine"
if [ ! -d "$wine_dir/.original-gptk4-staged" ]; then
  mkdir -p "$wine_dir/lib/external"
  cp -cR -p "$original_lib/external/." "$wine_dir/lib/external/"
  for module in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do
    cp -c -p "$original_lib/wine/x86_64-windows/$module.dll" "$wine_dir/lib/wine/x86_64-windows/$module.dll"
    ln -sf '../../external/libd3dshared.dylib' "$wine_dir/lib/wine/x86_64-unix/$module.so"
  done
  cmp "$original_lib/external/libd3dshared.dylib" "$wine_dir/lib/external/libd3dshared.dylib"
  cmp "$original_lib/external/D3DMetal.framework/Versions/A/D3DMetal" "$wine_dir/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
  mkdir "$wine_dir/.original-gptk4-staged"
fi
