#!/bin/bash
# Clone the existing standalone runtime into this research directory, then
# install original GPTK4 PE/Unix bridge libraries ONLY in that copy.
# Does not run Wine, initialize a prefix, launch games, or read Steam accounts.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
source_wine='/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/Wine Staging.app/Contents/Resources/wine'
gptk_lib="$research_dir/runtime-gptk4b2/redist/lib"
isolated_wine="$research_dir/wine-gptk4-isolated"

verify_copy() {
    test -d "$isolated_wine/.gptk4-copy-prepared"
    test -x "$isolated_wine/bin/wine"
    test -x "$isolated_wine/bin/wineserver"
    test -f "$isolated_wine/lib/wine/x86_64-unix/ntdll.so"
    test ! -L "$isolated_wine/lib/wine/x86_64-unix/ntdll.so"
    cmp -s "$source_wine/lib/wine/x86_64-unix/ntdll.so" "$isolated_wine/lib/wine/x86_64-unix/ntdll.so"
    if [[ "$(stat -f '%d:%i' "$source_wine/lib/wine/x86_64-unix/ntdll.so")" == "$(stat -f '%d:%i' "$isolated_wine/lib/wine/x86_64-unix/ntdll.so")" ]]; then
        printf 'ERROR: ntdll.so is not an independent file.\n' >&2
        return 1
    fi
    for module in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do
        cmp -s "$gptk_lib/wine/x86_64-windows/$module.dll" "$isolated_wine/lib/wine/x86_64-windows/$module.dll"
        test -L "$isolated_wine/lib/wine/x86_64-unix/$module.so"
        test -f "$isolated_wine/lib/wine/x86_64-unix/$module.so"
    done
    cmp -s "$gptk_lib/external/libd3dshared.dylib" "$isolated_wine/lib/external/libd3dshared.dylib"
    cmp -s "$gptk_lib/external/D3DMetal.framework/Versions/A/D3DMetal" "$isolated_wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
    printf 'Prepared runtime: %s\n' "$isolated_wine"
    printf 'ntdll.so is independently copied; GPTK4 libraries match originals.\n'
}

if [[ -d "$isolated_wine/.gptk4-copy-prepared" ]]; then
    verify_copy
    exit 0
fi
if [[ -e "$isolated_wine" ]]; then
    printf 'ERROR: %s exists without the research preparation marker; refusing to overwrite it.\n' "$isolated_wine" >&2
    exit 2
fi
test -x "$source_wine/bin/wine"
test -x "$source_wine/bin/wineserver"
test -f "$source_wine/lib/wine/x86_64-unix/ntdll.so"
test ! -L "$source_wine/lib/wine/x86_64-unix/ntdll.so"
test -f "$gptk_lib/external/libd3dshared.dylib"
test -f "$gptk_lib/external/D3DMetal.framework/Versions/A/D3DMetal"

mkdir "$isolated_wine"
# -c requests APFS clone copies: independent inodes, shared unchanged blocks.
# No hardlinks and no symlinks back to the source ntdll.so are created.
cp -cR -p "$source_wine/." "$isolated_wine/"
test ! -e "$isolated_wine/lib/external"
cp -cR -p "$gptk_lib/external" "$isolated_wine/lib/"
for module in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do
    cp -c -p "$gptk_lib/wine/x86_64-windows/$module.dll" "$isolated_wine/lib/wine/x86_64-windows/$module.dll"
    # Relative links stay entirely within the isolated runtime.
    ln -s '../../external/libd3dshared.dylib' "$isolated_wine/lib/wine/x86_64-unix/$module.so"
done
mkdir "$isolated_wine/.gptk4-copy-prepared"
verify_copy
