#!/bin/bash
# Complete installed Tencent runtime snapshot; owned probes only, never Steam
# or game binaries, and never changes the working Tencent prefix.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
if [ "${YYB_COMPLETE_CONTROL_GUARDED:-0}" != 1 ]; then
    export YYB_COMPLETE_CONTROL_GUARDED=1
    exec /usr/bin/sandbox-exec -f "$research_dir/yyb-complete-control.sb" /bin/bash "$0" "$@"
fi
source_app='/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app'
snapshot="$research_dir/wine-yyb-complete-control.app"
if [ ! -e "$snapshot" ]; then
    cp -cR -p "$source_app" "$snapshot"
    mkdir "$snapshot/.complete-control-snapshot"
fi
test -d "$snapshot/.complete-control-snapshot"
contents="$snapshot/Contents"
builtins="$contents/SharedSupport/wine/lib/wine"
frameworks="$contents/Frameworks"
cmp "$source_app/Contents/SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so" "$builtins/x86_64-unix/ntdll.so"
export WINEPREFIX="$research_dir/prefix-yyb-complete-control"
export YYB_NTDLL_PATH="$builtins/x86_64-unix/ntdll.so"
export WINELOADER="$research_dir/yyb10-research-loader"
export WINESERVER="$contents/MacOS/wineserver"
export WINEDLLPATH="$builtins"
export GFX_BACKEND_PATH="$frameworks/render/dxvk/wine"
export DYLD_FALLBACK_LIBRARY_PATH="$frameworks"
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH YYB_WINESERVER_HOST_APP YYB_KEEPALIVE SteamAppId SteamGameId
export WINEARCH=win64 WINEDEBUG=-all,err+all,+loaddll
export WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=;mshtml='
stage="${1:-baseline32}"
case "$stage" in
    baseline32) program="$research_dir/service-wow64/pe32_probe.exe"; args=();;
    clr64) program="$research_dir/service-wow64/clr_probe.exe"; args=(); export WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=n,b;mshtml=';;
    clr32) program="$research_dir/service-wow64/clr_probe32.exe"; args=(); export WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=n,b;mshtml=';;
    root64) program="$builtins/x86_64-windows/reg.exe"; args=(add 'HKLM\Software\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ /d 'C:\windows\Microsoft.NET\Framework64\' /reg:64 /f); test -f "$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll";;
    root32) program="$builtins/x86_64-windows/reg.exe"; args=(add 'HKLM\Software\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ /d 'C:\windows\Microsoft.NET\Framework\' /reg:32 /f); test -f "$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319/clr.dll";;
    server)
        log="$research_dir/yyb-complete-server-$(date +%Y%m%d-%H%M%S).log"
        exec "$WINESERVER" -p120 > "$log" 2>&1;;
    stop) exec "$WINESERVER" -k;;
    *) exit 2;;
esac
test -x "$WINELOADER"
test -f "$program"
mkdir -p "$WINEPREFIX"
prefix_device=$(stat -f %d "$WINEPREFIX")
prefix_inode=$(stat -f %i "$WINEPREFIX")
socket="/tmp/.wine-$(id -u)/server-$(printf '%x' "$prefix_device")-$(printf '%x' "$prefix_inode")/socket"
if [ ! -S "$socket" ]; then
    host_app="$research_dir/YYBCompleteControlHost.app"
    test -x "$host_app/Contents/MacOS/control-host"
    /usr/bin/open -n -gj "$host_app"
    deadline=$((SECONDS + 20))
    while [ ! -S "$socket" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 1; done
    if [ ! -S "$socket" ]; then printf 'Own Tencent server socket did not become ready.\n' >&2; exit 125; fi
fi
log="$research_dir/yyb-complete-$stage-$(date +%Y%m%d-%H%M%S).log"
printf 'Complete Tencent control stage=%s log=%s\n' "$stage" "$log"
"$WINELOADER" "$program" ${args[@]+"${args[@]}"} > "$log" 2>&1 &
probe_pid=$!
deadline=$((SECONDS + 60))
while kill -0 "$probe_pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        # This exact child is an owned probe; do not kill the working engine.
        kill -TERM "$probe_pid" 2>/dev/null || true
        printf 'Owned probe timed out after60s, pid=%s\n' "$probe_pid" | tee -a "$log"
        exit 124
    fi
    sleep 1
done
set +e
wait "$probe_pid"
status=$?
printf 'Actual owned probe exit=%s\n' "$status" | tee -a "$log"
exit "$status"
