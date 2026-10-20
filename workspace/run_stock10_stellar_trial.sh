#!/bin/bash
# Dedicated, bounded Steam/Stellar trial; not the GPU smoke-test prefix.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
host_dir="$research_dir/Wine10-source/host"
stage="${1:-stellar}"
if [ "$#" -gt 0 ]; then shift; fi
if [ "$stage" != stop ] && [ -f "$research_dir/SteamClient/steamapps/appmanifest_3489700.acf" ] \
    && [ "${STELLAR_ORIGINAL_WRITE_GUARD:-0}" != 1 ]; then
    printf 'Registered game assets require run_guarded_steam_stellar.sh.\n' >&2
    exit 2
fi
export WINEPREFIX="$research_dir/prefix-wine10-stellar"
export WINEARCH=win64
export WINELOADER="$host_dir/bin/wine64"
export WINESERVER="$host_dir/bin/wineserver"
export WINEDLLPATH="$host_dir/lib/wine"
if [ "${STELLAR_NATIVE_LIBRARY_PATH_MODE:-isolated}" = isolated ]; then
    # Do not shadow Apple's ImageIO plugin libraries with unrelated Homebrew
    # libpng/libtiff aliases. Explicit library install names remain resolvable.
    export DYLD_LIBRARY_PATH="$host_dir/lib/external:$host_dir/lib:/usr/local/opt/freetype/lib:/usr/local/opt/fontconfig/lib"
    export DYLD_FALLBACK_LIBRARY_PATH=/usr/lib
else
    export DYLD_LIBRARY_PATH="$host_dir/lib/external:$host_dir/lib:/usr/local/opt/freetype/lib:/usr/local/opt/fontconfig/lib:/usr/local/lib"
    export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH:/usr/lib"
fi
unset DYLD_PRINT_LIBRARIES YYB_NTDLL_PATH YYB_WINESERVER_HOST_APP YYB_KEEPALIVE
export GPU_ADAPTER_MODE=gate
export GPU_ADAPTER_TEXTURE_MODE=managed
export GPU_ADAPTER_RENDERPASS_NORMALIZE=1
export GPU_ADAPTER_TIMEOUT_SECONDS=0
export D3DM_MTL4=0 D3DM_ENABLE_METALFX=0 D3DM_SUPPORT_DXR=0 MTL_HUD_ENABLED=0
export DYLD_INSERT_LIBRARIES="$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"
export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;msvcp140,vcruntime140,vcruntime140_1,x3daudio1_7,xapofx1_5,xinput1_3=n,b;winemenubuilder.exe=d;mscoree=n,b;mshtml='
export WINEDEBUG="${STELLAR_TRIAL_DEBUG:--all,err+all,+loaddll}"
export WINEESYNC=0 WINEFSYNC=0
export WINE_PE_ANONYMOUS_IMAGE_MAP=1
unset SteamAppId SteamGameId
test -d "$host_dir/.original-gptk4-staged"
if [ "$stage" = stop ]; then
    unset DYLD_INSERT_LIBRARIES
    exec "$host_dir/bin/wineserver" -k
fi
case "$stage" in
    init) program="$host_dir/lib/wine/x86_64-windows/wineboot.exe"; args=(-u);;
    steam|steam-session)
        # CEF CPU painting is separate from SDL3's window presentation. Keep
        # request SDL's genuine software renderer for launcher UI. Steam can
        # override this preference; do not infer the actual renderer from it.
        # Unreal's DX12 game flags are unchanged.
        export SDL_RENDER_DRIVER="${STEAM_UI_RENDER_DRIVER:-software}"
        export SDL_FRAMEBUFFER_ACCELERATION=0
        export SDL_LOGGING='render=info,video=info,input=quiet'
        export WINE_CHROMIUM_SOFTWARE_PROXY=1
        export WINE_LAYERED_CHILD_COMPOSITE=1
        # This is a Steam-recognized flag. CEF's native Windows occlusion
        # calculation can leave newly restored browser contents unpainted.
        program="$research_dir/SteamClient/steam.exe"; args=(-no-cef-sandbox -cef-disable-gpu -cef-disable-gpu-compositing -cef-disable-occlusion "$@");;
    # Let the legitimate running Steam client supply its normal launch/license
    # context. The guard entry point is required before registering game assets.
    steamplay)
        # Use the same legitimate Steam launch path, adding only public UE log
        # switches. Shipping builds may ignore these; log absence is not proof
        # that the game never started. Never alter license or installed state.
        program="$research_dir/SteamClient/steam.exe"
        args=(-applaunch 3489700 -dx12 -windowed -ResX=1280 -ResY=800
            -NoSplash -NoStartupMovies -log
            "-LogCmds=LogD3D12RHI VeryVerbose,LogRHI VeryVerbose,LogShaderLibrary Verbose,LogShaderCompilers Verbose"
            "-ABSLOG=Z:$research_dir/stellar-unreal-runtime.log" "$@");;
    steamquit) program="$research_dir/SteamClient/steam.exe"; args=(-shutdown);;
    # These public UE logging switches only affect builds that retained logging.
    # Shipping builds may ignore them; no game/Pak or settings edits are made.
    stellar) program="$research_dir/stellar-overlay/SB/Binaries/Win64/SB-Win64-Shipping.exe"; args=(SB -DistributionPlatform=Steam -dx12 -windowed -ResX=1280 -ResY=800 -NoSplash -NoStartupMovies -log "-LogCmds=LogD3D12RHI VeryVerbose,LogRHI VeryVerbose,LogShaderLibrary Verbose,LogShaderCompilers Verbose" "-ABSLOG=Z:$research_dir/stellar-unreal-runtime.log" "$@");;
    status) program="$research_dir/windows_status_probe.exe"; args=();;
    clrerrordismiss) program="$research_dir/windows_status_probe.exe"; args=(--dismiss-clr-resource-error);;
    steamshow) program="$research_dir/windows_status_probe.exe"; args=(--show-steam-login);;
    steamrefresh) program="$research_dir/windows_status_probe.exe"; args=(--refresh-steam-login);;
    steamlayout) program="$research_dir/windows_status_probe.exe"; args=(--repair-steam-login-layout);;
    steamfrontendreset) program="$research_dir/windows_status_probe.exe"; args=(--reset-own-steam-login-frontend);;
    servicedismiss) program="$research_dir/windows_status_probe.exe"; args=(--dismiss-steam-service-error);;
    service-repair) program="$research_dir/SteamClient/bin/SteamService.exe"; args=(/repair);;
    service-install) program="$research_dir/SteamClient/bin/SteamService.exe"; args=(/install);;
    service-start) program="$research_dir/service-wow64/build/programs/sc/x86_64-windows/sc.exe"; args=(start "Steam Client Service");;
    service-query) program="$research_dir/service-wow64/build/programs/sc/x86_64-windows/sc.exe"; args=(query "Steam Client Service");;
    service-register-netcfg) program="$research_dir/service-wow64/build/programs/regsvr32/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\hnetcfg.dll");;
    installer-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\msi.dll");;
    installer-register64) program="$host_dir/lib/wine/x86_64-windows/regsvr32.exe"; args=(/s "C:\\windows\\system32\\msi.dll");;
    xml-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\msxml3.dll");;
    xml-register64) program="$host_dir/lib/wine/x86_64-windows/regsvr32.exe"; args=(/s "C:\\windows\\system32\\msxml3.dll");;
    ole-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\ole32.dll");;
    ole-register64) program="$host_dir/lib/wine/x86_64-windows/regsvr32.exe"; args=(/s "C:\\windows\\system32\\ole32.dll");;
    oleauto-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\oleaut32.dll");;
    oleauto-register64) program="$host_dir/lib/wine/x86_64-windows/regsvr32.exe"; args=(/s "C:\\windows\\system32\\oleaut32.dll");;
    task-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\taskschd.dll");;
    task-register64) program="$host_dir/lib/wine/x86_64-windows/regsvr32.exe"; args=(/s "C:\\windows\\system32\\taskschd.dll");;
    explorerframe-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\explorerframe.dll");;
    wic-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\windowscodecs.dll");;
    wic-register64) program="$host_dir/lib/wine/x86_64-windows/regsvr32.exe"; args=(/s "C:\\windows\\system32\\windowscodecs.dll");;
    wintrust-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\wintrust.dll");;
    rsaenh-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\rsaenh.dll");;
    msisip-register32) program="$host_dir/lib/wine/i386-windows/regsvr32.exe"; args=(/s "C:\\windows\\syswow64\\msisip.dll");;
    msicheck32) program="$research_dir/service-wow64/msi_probe32.exe"; args=();;
    msicheck64) program="$research_dir/service-wow64/msi_probe64.exe"; args=();;
    pe32windowcheck) program="$research_dir/service-wow64/pe32_window_probe.exe"; args=();;
    gameruntimecheck) program="$research_dir/service-wow64/game_runtime_probe.exe"; args=();;
    com32check) program="$research_dir/service-wow64/com32_probe.exe"; args=();;
    crypto32check) program="$research_dir/service-wow64/crypto32_probe.exe"; args=();;
    httpscheck) program="$research_dir/userenv-research/certificate_https_probe.exe"; args=();;
    clrcheck) program="$research_dir/service-wow64/clr_probe.exe"; args=();;
    clrcheck-stockmap)
        # Controlled owned CLR-only experiment. Do not change game/GPTK mapping.
        unset WINE_PE_ANONYMOUS_IMAGE_MAP
        program="$research_dir/service-wow64/clr_probe.exe"; args=();;
    clrcheck-noadapter)
        # Controlled owned CLR-only experiment, no GPU classification proxy.
        unset DYLD_INSERT_LIBRARIES
        program="$research_dir/service-wow64/clr_probe.exe"; args=();;
    clr32check) program="$research_dir/service-wow64/clr_probe32.exe"; args=();;
    static-tlscheck) program="$research_dir/service-wow64/static_tls_probe.exe"; args=();;
    version-query) program="$research_dir/service-wow64/build/programs/winecfg/x86_64-windows/winecfg.exe"; args=(-v);;
    version-win7) program="$research_dir/service-wow64/build/programs/winecfg/x86_64-windows/winecfg.exe"; args=(-v win7);;
    version-win10) program="$research_dir/service-wow64/build/programs/winecfg/x86_64-windows/winecfg.exe"; args=(-v win10);;
    clr-root64)
        test -f "$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll"
        test -f "$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscoreei.dll"
        program="$host_dir/lib/wine/x86_64-windows/reg.exe"
        args=(add 'HKLM\Software\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ /d 'C:\windows\Microsoft.NET\Framework64\' /reg:64 /f);;
    clr-root32)
        test -f "$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319/clr.dll"
        test -f "$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319/mscoreei.dll"
        program="$host_dir/lib/wine/x86_64-windows/reg.exe"
        args=(add 'HKLM\Software\Microsoft\.NETFramework' /v InstallRoot /t REG_SZ /d 'C:\windows\Microsoft.NET\Framework\' /reg:32 /f);;
    dotnet-extract)
        program="$research_dir/service-wow64/official-installer-source/redist/dotNetFx40_Full_x86_x64.exe"
        args=("/x:Z:$research_dir/service-wow64/official-dotnet-payload-20261013" /q);;
    dotnet48)
        test -s "$research_dir/service-wow64/dotnet40-runtime-before-upgrade-20261013.tar.gz"
        test -f "$research_dir/service-wow64/official-installer-source/redist/NDP48-x86-x64-AllOS-ENU.exe"
        STELLAR_TRIAL_LIMIT_SECONDS=360
        program="$research_dir/service-wow64/installer_exit_probe.exe"
        args=(--dotnet48);;
    ueprereq-exitcheck)
        # Allow real .NET runtime initialization only for the original installer.
        export WINEDLLOVERRIDES="${WINEDLLOVERRIDES};mscoree=n,b"
        program="$research_dir/service-wow64/installer_exit_probe.exe"; args=();;
    ueprereq)
        program="$research_dir/stellar-overlay/Engine/Extras/Redist/en-us/UE4PrereqSetup_x64.exe"
        args=(/quiet /norestart /log "Z:$research_dir/service-wow64/ue-prereq-installer.log");;
    psprereq)
        program="$host_dir/lib/wine/x86_64-windows/cmd.exe"
        args=(/d /c "Z:$research_dir/stellar-overlay/SB/Binaries/Win64/install_pspc_sdk_runtime.bat" quiet);;
    wow64check) program="$research_dir/service-wow64/pe32_probe.exe"; args=();;
    sdlcheck) program="$research_dir/sdl_software_probe.exe"; args=();;
    comcheck) program="$research_dir/com_window_probe.exe"; args=();;
    crossgdicheck) program="$research_dir/cross_process_gdi_probe.exe"; args=();;
    layeredcheck) program="$research_dir/cross_process_gdi_probe.exe"; args=(--layered-child-test);;
    layereddrawcheck)
        export WINE_LAYERED_CHILD_COMPOSITE=1 WINE_LAYERED_CHILD_DIAGNOSTICS=1
        export OWN_CHILD_CAPTURE_OUTPUT="$research_dir/chromium-proxy-repair/own-child-compositor.png"
        export DYLD_INSERT_LIBRARIES="$DYLD_INSERT_LIBRARIES:$research_dir/chromium-proxy-repair/capture_own_child_probe.dylib"
        program="$research_dir/cross_process_gdi_probe.exe"; args=(--layered-child-test --layered-draw-test);;
    *) printf 'Use init, steam, steam-session, steamplay, stellar, status, steamshow, or stop.\n' >&2; exit 2;;
esac
if [ "$stage" = stellar ]; then
    export SteamAppId=3489700 SteamGameId=3489700
fi
test -f "$program"
log_file="$research_dir/stock10-trial-$stage-$(date +%Y%m%d-%H%M%S).log"
cd "$(dirname -- "$program")"
if [ "$stage" = steam-session ]; then
    # A user-interactive app, not a timed probe. The detached entry point owns
    # this GUI lifetime; normal Steam Exit or scoped prefix stop ends it.
    printf 'Interactive guarded Steam session; log: %s\n' "$log_file"
    exec "$host_dir/bin/wine64" "$program" ${args[@]+"${args[@]}"} > "$log_file" 2>&1
fi
set +e
# macOS ships Bash 3.2, whose nounset treats an empty array as unbound.
"$host_dir/bin/wine64" "$program" ${args[@]+"${args[@]}"} > "$log_file" 2>&1 &
trial_pid=$!
printf 'Started stage: %s\nOwn Wine loader PID: %s\nLog: %s\n' "$stage" "$trial_pid" "$log_file"
limit_seconds="${STELLAR_TRIAL_LIMIT_SECONDS:-180}"
for ((elapsed=0; elapsed<limit_seconds; elapsed++)); do
    kill -0 "$trial_pid" 2>/dev/null || break
    sleep 1
done
timed_out=0
if kill -0 "$trial_pid" 2>/dev/null; then
    timed_out=1
    printf '\nOWN_TRIAL_TIMEOUT_SECONDS=%s\n' "$limit_seconds" >> "$log_file"
    kill -TERM "$trial_pid" 2>/dev/null
fi
wait "$trial_pid"
trial_status=$?
if [ "$timed_out" = 1 ]; then
    # Helpers must not destroy an interactive login or service on timeout.
    if [ "$stage" = stellar ]; then
        env -u DYLD_INSERT_LIBRARIES "$host_dir/bin/wineserver" -k
    fi
    trial_status=124
fi
printf 'Stage: %s\nExit: %s\nLog: %s\n' "$stage" "$trial_status" "$log_file"
exit "$trial_status"
