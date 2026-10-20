#!/bin/bash
# Pure DLL-load diagnostic in its own disposable prefix. No game or Apple
# binary is modified. Relay filtering observes public Windows/Wine API calls.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
wine_dir="$research_dir/gptk-wine-host-3/Game Porting Toolkit.app/Contents/Resources/wine"
prefix_dir="$research_dir/prefix-gptk7-bridge-diagnostic"
test -x "$wine_dir/bin/wine64"
test -d "$wine_dir/.gptk4-original-libraries-staged"
test -f "$research_dir/windows_load_library_probe.exe"
unset DYLD_PRINT_LIBRARIES DYLD_INSERT_LIBRARIES
export WINEPREFIX="$prefix_dir"
export WINEARCH=win64
export WINELOADER="$wine_dir/bin/wine64"
export WINESERVER="$wine_dir/bin/wineserver"
export WINEDLLPATH="$wine_dir/lib/wine"
export DYLD_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$wine_dir/lib/external:$wine_dir/lib"
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
export D3DM_MTL4=0 D3DM_ENABLE_METALFX=0 MTL_HUD_ENABLED=0
export WINEDEBUG=-all
"$wine_dir/bin/wine64" reg.exe add 'HKCU\Software\Wine\Debug' /v RelayInclude /t REG_SZ /d 'kernel32.GetProcAddress;kernelbase.GetProcAddress;ntdll.NtQueryVirtualMemory;ntdll.__wine_unix_call;ntdll.__wine_unix_call_dispatcher' /f > "$research_dir/gptk7-bridge-diagnostic-setup.log" 2>&1
export WINEDEBUG='-all,+module,+loaddll,+seh,+relay,+virtual'
set +e
"$wine_dir/bin/wine64" "$research_dir/windows_load_library_probe.exe" "${1:-all}" > "$research_dir/gptk7-bridge-diagnostic.log" 2>&1
probe_status=$?
printf 'Diagnostic exit: %s\nLog: %s\n' "$probe_status" "$research_dir/gptk7-bridge-diagnostic.log"
exit "$probe_status"
