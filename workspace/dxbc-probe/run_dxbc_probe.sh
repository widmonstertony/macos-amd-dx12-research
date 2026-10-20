#!/bin/bash
set -euo pipefail
dxbc_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dxbc_research=$(CDPATH= cd -- "$dxbc_dir/.." && pwd)
dxbc_host="$dxbc_research/Wine10-source/host"
dxbc_compiler="$dxbc_research/Wine10-source/build/dlls/d3dcompiler_47/x86_64-windows/d3dcompiler_47.dll"
test -f "$dxbc_compiler"
mkdir -p "$dxbc_dir/module-overlay/x86_64-windows"
cp "$dxbc_compiler" "$dxbc_dir/module-overlay/x86_64-windows/d3dcompiler_47.dll"
unset YYB_NTDLL_PATH YYB_WINESERVER_HOST_APP YYB_KEEPALIVE DYLD_PRINT_LIBRARIES
export WINEPREFIX="$dxbc_dir/prefix"
export WINEARCH=win64
export WINELOADER="$dxbc_host/bin/wine64"
export WINESERVER="$dxbc_host/bin/wineserver"
export WINEDLLPATH="$dxbc_dir/module-overlay:$dxbc_host/lib/wine"
export DYLD_LIBRARY_PATH="$dxbc_host/lib/external:$dxbc_host/lib:/usr/local/opt/freetype/lib:/usr/local/opt/fontconfig/lib:/usr/local/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$dxbc_host/lib/external:$dxbc_host/lib:/usr/local/lib:/usr/lib"
export DYLD_INSERT_LIBRARIES="$dxbc_research/gpu-adapter-experiment/metal_device_adapter.dylib"
export GPU_ADAPTER_MODE=gate GPU_ADAPTER_TEXTURE_MODE=managed GPU_ADAPTER_RENDERPASS_NORMALIZE=1 GPU_ADAPTER_TIMEOUT_SECONDS=0
export WINE_PE_ANONYMOUS_IMAGE_MAP=1 MTL_DEBUG_LAYER=1 D3DM_MTL4=0 D3DM_ENABLE_METALFX=0 MTL_HUD_ENABLED=0
export WINEDLLOVERRIDES='d3dcompiler_47,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export WINEDEBUG=-all,+loaddll,+seh
cd "$dxbc_dir"
set +e
"$WINELOADER" "$dxbc_dir/d3d12_dxbc_graphics_probe.exe" > "$dxbc_dir/windows-dxbc-gate-validation.log" 2>&1 &
dxbc_pid=$!
dxbc_timeout=0
for ((dxbc_elapsed=0; dxbc_elapsed<120; dxbc_elapsed++)); do
  kill -0 "$dxbc_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$dxbc_pid" 2>/dev/null; then
  dxbc_timeout=1
  kill -TERM "$dxbc_pid" 2>/dev/null
  env -u DYLD_INSERT_LIBRARIES "$WINESERVER" -k
fi
wait "$dxbc_pid"
dxbc_status=$?
env -u DYLD_INSERT_LIBRARIES "$WINESERVER" -k
if [ "$dxbc_timeout" -eq 1 ]; then dxbc_status=124; fi
printf 'DXBC SM5 probe exit: %s\nOwn prefix: %s\nLog: %s\n' "$dxbc_status" "$WINEPREFIX" "$dxbc_dir/windows-dxbc-gate-validation.log"
exit "$dxbc_status"
