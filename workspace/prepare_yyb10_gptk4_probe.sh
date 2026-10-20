#!/bin/bash
# APFS-cloned Tencent Wine 10 host for original GPTK4 bridge diagnostics.
# Never changes the installed engine or any existing game prefix.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
source_app='/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app'
target_app="$research_dir/wine-yyb10-gptk4-isolated.app"
original_lib="$research_dir/runtime-gptk4b2/redist/lib"
own_loader_source='/Users/tonytan/Documents/GitHub/sky-yyb-mac-fix/intel/wine_loader.c'
test -f "$source_app/Contents/SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so"
test -f "$original_lib/external/libd3dshared.dylib"
test -f "$own_loader_source"
if [ -d "$target_app" ] && [ ! -d "$target_app/.gptk4-research-prepared" ]; then
  printf 'Refusing to reuse an unrecognized target app: %s\n' "$target_app" >&2
  exit 2
fi
if [ ! -d "$target_app/.gptk4-research-prepared" ]; then
  cp -cR -p "$source_app" "$target_app"
  target_contents="$target_app/Contents"
  builtin_lib="$target_contents/SharedSupport/wine/lib/wine"
  backend_dir="$target_contents/Frameworks/render/gptk"
  cp -cR -p "$original_lib/external/." "$backend_dir/external/"
  for module in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do
    cp -c -p "$original_lib/wine/x86_64-windows/$module.dll" "$builtin_lib/x86_64-windows/$module.dll"
    cp -c -p "$original_lib/wine/x86_64-windows/$module.dll" "$backend_dir/wine/x86_64-windows/$module.dll"
    ln -sf "$backend_dir/external/libd3dshared.dylib" "$builtin_lib/x86_64-unix/$module.so"
    ln -sf "$backend_dir/external/libd3dshared.dylib" "$backend_dir/wine/x86_64-unix/$module.so"
  done
  test -f "$builtin_lib/x86_64-unix/ntdll.so"
  test ! -L "$builtin_lib/x86_64-unix/ntdll.so"
  cmp "$source_app/Contents/SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so" "$builtin_lib/x86_64-unix/ntdll.so"
  cmp "$original_lib/external/libd3dshared.dylib" "$backend_dir/external/libd3dshared.dylib"
  cmp "$original_lib/external/D3DMetal.framework/Versions/A/D3DMetal" "$backend_dir/external/D3DMetal.framework/Versions/A/D3DMetal"
  mkdir "$target_app/.gptk4-research-prepared"
fi
cp -c -p "$own_loader_source" "$research_dir/yyb10_research_loader.c"
clang -O2 -Wall -Wextra -Wl,-segalign,0x1000 -Wl,-pagezero_size,0x1000 -Wl,-no_pie -Wl,-image_base,0x200000000 -Wl,-no_huge -Wl,-no_fixup_chains -Wl,-segaddr,WINE_RESERVE,0x1000 -Wl,-segaddr,WINE_TOP_DOWN,0x7ff000000000 -o "$research_dir/yyb10-research-loader" "$research_dir/yyb10_research_loader.c"
printf 'Prepared cloned Wine 10 research host: %s\n' "$target_app"
stat -f 'Copied ntdll inode=%i size=%z' "$target_app/Contents/SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so"

