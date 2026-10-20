#!/bin/bash
# Stage unmodified original GPTK4 into only the newly built clean Wine 10 host.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
host_dir="$research_dir/Wine10-source/host"
original_lib="$research_dir/runtime-gptk4b2/redist/lib"
test -x "$host_dir/bin/wine64"
test -x "$host_dir/bin/wineserver"
test -f "$host_dir/lib/wine/x86_64-unix/ntdll.so"
mkdir -p "$host_dir/lib/external"
cp -cR -p "$original_lib/external/." "$host_dir/lib/external/"
for module in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do
  cp -c -p "$original_lib/wine/x86_64-windows/$module.dll" "$host_dir/lib/wine/x86_64-windows/$module.dll"
  cmp "$original_lib/wine/x86_64-windows/$module.dll" "$host_dir/lib/wine/x86_64-windows/$module.dll"
  ln -sf '../../external/libd3dshared.dylib' "$host_dir/lib/wine/x86_64-unix/$module.so"
done
cmp "$original_lib/external/libd3dshared.dylib" "$host_dir/lib/external/libd3dshared.dylib"
cmp "$original_lib/external/D3DMetal.framework/Versions/A/D3DMetal" "$host_dir/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
mkdir -p "$host_dir/.original-gptk4-staged"
"$host_dir/bin/wine64" --version
printf 'Staged original GPTK4 into %s\n' "$host_dir"

