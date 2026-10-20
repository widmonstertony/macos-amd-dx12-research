#!/bin/bash
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
wine_dir='/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/Wine Staging.app/Contents/Resources/wine'
live_prefix='/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine'
stack_dir="$research_dir/vkd3d-proton-macos"
game_bin="$research_dir/stellar-overlay/SB/Binaries/Win64"
mode="${1:-dx12}"
case "$mode" in dx11|dx12) ;; *) printf 'Mode must be dx11 or dx12\n' >&2; exit 2;; esac
export WINEPREFIX="$research_dir/prefix-open-dx12"
export WINEARCH=win64
export WINESERVER="$wine_dir/bin/wineserver"
export WINELOADER="$wine_dir/bin/wine"
export PATH="$wine_dir/bin:$PATH"
export DYLD_LIBRARY_PATH="$stack_dir:/usr/local/opt/vulkan-loader/lib:$wine_dir/lib"
export VK_ICD_FILENAMES="$stack_dir/MoltenVK_icd.json"
export MVK_PRESENT_MODE=1
export VKMT_ALLOW_NON_SINGLE_TEXEL_ALIGNMENT=1
export VKD3D_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M'
export DXVK_FILTER_DEVICE_NAME='AMD Radeon Pro 5600M'
export WINEDLLOVERRIDES='d3d11,d3d12,d3d12core,dxgi=n;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG='-all,err+all'
export VKD3D_DEBUG=info
export DXVK_LOG_LEVEL=info
export DXVK_LOG_PATH="$research_dir"
export SteamAppId=3489700
test -f "$WINEPREFIX/system.reg"
test -f "$game_bin/SB-Win64-Shipping.exe"
cp "$stack_dir/dxgi.dll" "$stack_dir/d3d12.dll" "$stack_dir/d3d12core.dll" "$game_bin/"
cp "$research_dir/dxvk-macOS-async-v1.10.3-20230507-repack/x64/d3d11.dll" "$game_bin/"
for runtime_dll in msvcp140.dll vcruntime140.dll vcruntime140_1.dll x3daudio1_7.dll xapofx1_5.dll xinput1_3.dll; do
    if [ -f "$live_prefix/drive_c/windows/system32/$runtime_dll" ]; then
        cp "$live_prefix/drive_c/windows/system32/$runtime_dll" "$game_bin/"
    fi
done
cd "$game_bin"
set +e
"$wine_dir/bin/wine" ./SB-Win64-Shipping.exe SB -DistributionPlatform=Steam "-$mode" -windowed -ResX=1280 -ResY=800 -NoSplash -NoStartupMovies -log 2>&1 | tee "$research_dir/stellar-$mode-launch.log"
exit "${PIPESTATUS[0]}"
