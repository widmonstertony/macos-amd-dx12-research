#!/bin/bash
set -u
research_dir="$(cd "$(dirname "$0")" && pwd)"
wine_dir='/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/Wine Staging.app/Contents/Resources/wine'
stack_dir="$research_dir/vkd3d-proton-macos"
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
export WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG=-all
export VKD3D_DEBUG=info
export DXVK_LOG_LEVEL=info
mkdir -p "$research_dir/open-dx12-probe-app"
cp "$research_dir/d3d12_probe.exe" "$research_dir/open-dx12-probe-app/"
cp "$stack_dir/dxgi.dll" "$stack_dir/d3d12.dll" "$stack_dir/d3d12core.dll" "$research_dir/open-dx12-probe-app/"
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    "$wine_dir/bin/wineboot" --init >"$research_dir/open-dx12-prefix-init.log" 2>&1
    "$wine_dir/bin/wineserver" -w
fi
cd "$research_dir/open-dx12-probe-app"
"$wine_dir/bin/wine" ./d3d12_probe.exe 2>&1 | tee "$research_dir/open-dx12-probe.log"
exit "${PIPESTATUS[0]}"
