#!/bin/bash
# Legitimate installed Tencent Steam baseline, NOT a new prefix or a claim that
# the owned fragment candidate has been integrated into D3DMetal/game shaders.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
if [ "${YYB_NORMAL_STEAM_GUARDED:-0}" != 1 ]; then
    if [ "${1:-steam}" = gptk4-play ]; then
        if /bin/ps -axo comm= | /usr/bin/awk '/SB-Win64-Shipping[.]exe$/ || /[Ss]team[.]exe$/ || /yyb-gptk4-steam-bridge$/ {found=1} END {exit !found}'; then
            printf 'A game, Steam or owned bridge still exists; wait for shutdown before changing the GPTK library.\n' >&2
            exit 126
        fi
    fi
    if [ "${1:-steam}" = replay ] || [ "${1:-steam}" = quit ] || [ "${1:-steam}" = gptk4-play ] || [ "${1:-steam}" = window-release ] || [ "${1:-steam}" = window-show ] || [ "${1:-steam}" = window-continue-click ]; then
        # Read-only ownership check runs before file-write sandbox application;
        # ps is restricted inside that macOS sandbox. Game launch remains inside.
        trial_pid=$(<"$research_dir/yyb-normal-protected-server.pid")
        trial_path=$(/bin/ps -p "$trial_pid" -o comm= || true)
        expected_server='/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/MacOS/wineserver'
        if [ "${1:-}" = gptk4-play ] && [ -z "$trial_path" ]; then
            if pgrep -f "$expected_server" >/dev/null; then exit 126; fi
            export YYB_REPLAY_VERIFIED_PID=cold
        else
            if [ "$trial_path" != "$expected_server" ]; then
                # The vendor's bootstrap can leave its genuine server running
                # from the byte-identical owned bundle. Verify both the actual
                # executable and the socket directory of this exact prefix.
                python3 - "$trial_path" "$expected_server" "$research_dir" "$trial_pid" <<'SERVER_CHECK'
from pathlib import Path
import sys,hashlib,subprocess,os
image,original,project,pid=sys.argv[1:]
owned=Path(project)/'wine-yyb10-gptk4-isolated.app/Contents/MacOS/wineserver'
if Path(image).resolve()!=owned.resolve():raise SystemExit('Unrecognized server image')
if hashlib.sha256(Path(image).read_bytes()).digest()!=hashlib.sha256(Path(original).read_bytes()).digest():raise SystemExit('Server differs from original vendor engine')
prefix=Path('/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine');st=prefix.stat()
expected=Path('/tmp/.wine-'+str(os.getuid()))/f'server-{st.st_dev:x}-{st.st_ino:x}'
metadata=subprocess.check_output(['/usr/sbin/lsof','-a','-p',pid,'-d','cwd','-Fn'],text=True)
cwd=next((l[1:] for l in metadata.splitlines() if l.startswith('n')),None)
if cwd is None or Path(cwd).resolve()!=expected.resolve():raise SystemExit('Server socket directory differs from expected prefix')
SERVER_CHECK
            fi
            export YYB_REPLAY_VERIFIED_PID="$trial_pid"
        fi
    fi
    export YYB_NORMAL_STEAM_GUARDED=1
    exec /usr/bin/sandbox-exec -f "$research_dir/stellar-original-write-guard.sb" /bin/bash "$0" "$@"
fi
support='/Users/tonytan/Library/Application Support/YYBIntelLauncher'
contents="$support/.runtime/wine-engine.app/Contents"
frameworks="$contents/Frameworks"
export WINEPREFIX='/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine'
export YYB_NTDLL_PATH="$contents/SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so"
export WINELOADER="$support/wine-loader"
export WINESERVER="$contents/MacOS/wineserver"
export WINEDLLPATH="$contents/SharedSupport/wine/lib/wine"
export GFX_BACKEND_PATH="$frameworks/render/dxvk/wine"
export DYLD_FALLBACK_LIBRARY_PATH="$frameworks"
export WINE_RETINA_MODE=1 WINE_RETINA_SCALE=2.0 DXVK_HUD=0 MTL_HUD_ENABLED=0 D3DM_ENABLE_METALFX=0 WINEDEBUG=-all
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH YYB_WINESERVER_HOST_APP YYB_KEEPALIVE WINEDLLOVERRIDES SteamAppId SteamGameId
steam="$WINEPREFIX/drive_c/Program Files (x86)/Steam/Steam.exe"
stage="${1:-steam}"
case "$stage" in
    window-continue-click)
        # Caller must visually verify the existing Continue button first.
        # The helper rechecks exact game image/class and posts normal client
        # mouse events only to that unique window, never starts a game EXE.
        owned_pid=$(<"$research_dir/yyb-normal-protected-server.pid")
        test "${YYB_REPLAY_VERIFIED_PID:-}" = "$owned_pid"
        test -f "$research_dir/yyb_game_window_click.exe"
        test "$#" = 3
        exec "$WINELOADER" "$research_dir/yyb_game_window_click.exe" --continue-click "$2" "$3";;
    window-show)
        owned_pid=$(<"$research_dir/yyb-normal-protected-server.pid")
        test "${YYB_REPLAY_VERIFIED_PID:-}" = "$owned_pid"
        test -f "$research_dir/yyb_game_window_release.exe"
        exec "$WINELOADER" "$research_dir/yyb_game_window_release.exe" --show;;
    window-release)
        owned_pid=$(<"$research_dir/yyb-normal-protected-server.pid")
        test "${YYB_REPLAY_VERIFIED_PID:-}" = "$owned_pid"
        test -f "$research_dir/yyb_game_window_release.exe"
        exec "$WINELOADER" "$research_dir/yyb_game_window_release.exe";;
    quit)
        owned_pid=$(<"$research_dir/yyb-normal-protected-server.pid")
        test "${YYB_REPLAY_VERIFIED_PID:-}" = "$owned_pid"
        exec "$WINELOADER" "$steam" -shutdown;;
    gptk4-play)
        if [ "${YYB_REPLAY_VERIFIED_PID:-}" = cold ]; then
            /bin/bash "$research_dir/run_yyb_normal_steam_trial.sh" server &
            server_host_pid=$!
            printf '%s\n' "$server_host_pid" > "$research_dir/yyb-normal-protected-server.pid"
            device=$(stat -f %d "$WINEPREFIX"); inode=$(stat -f %i "$WINEPREFIX")
            socket="/tmp/.wine-$(id -u)/server-$(printf '%x' "$device")-$(printf '%x' "$inode")/socket"
            deadline=$((SECONDS+20))
            while [ "$SECONDS" -lt "$deadline" ]; do
                kill -0 "$server_host_pid" 2>/dev/null || break
                [ ! -S "$socket" ] || break
                sleep 1
            done
            kill -0 "$server_host_pid" 2>/dev/null && test -S "$socket"
            export YYB_REPLAY_VERIFIED_PID="$server_host_pid"
        fi
        owned_pid=$(<"$research_dir/yyb-normal-protected-server.pid")
        test "${YYB_REPLAY_VERIFIED_PID:-}" = "$owned_pid"
        gptk="$research_dir/runtime-gptk4b2/redist/lib"
        export YYB_RESEARCH_GPTK4_ROOT="$gptk"
        export DYLD_LIBRARY_PATH="$gptk/external:$frameworks"
        export DYLD_FALLBACK_LIBRARY_PATH="$gptk/external:$frameworks"
        # Separate owned library validated by actual depth/stencil GPU readback
        # and this Steam game's progress beyond its former texture assertion.
        adapter_library="${YYB_GPTK4_ADAPTER_LIBRARY:-$research_dir/gpu-adapter-experiment/metal_device_adapter-depth-query.dylib}"
        case "$adapter_library" in
            "$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-depth-private.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-depth-query.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-capture-batch.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-profile.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-borrowed-metadata.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-memory-profile.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-visibility-trace.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-typed-draw.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-resource-usage-typed.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-resource-scope-trace.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-resource-scope-trace-v2.dylib") ;;
            *) exit 2;;
        esac
        test -f "$adapter_library"
        export DYLD_INSERT_LIBRARIES="$adapter_library"
        export GPU_ADAPTER_MODE=gate GPU_ADAPTER_TEXTURE_MODE=managed GPU_ADAPTER_RENDERPASS_NORMALIZE=1 GPU_ADAPTER_TIMEOUT_SECONDS=0
        export D3DM_MTL4=0
        export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b'
        bridge="$research_dir/wine-yyb10-gptk4-isolated.app/Contents/MacOS/yyb-gptk4-steam-bridge"
        test -x "$bridge"
        log="$research_dir/yyb-gptk4-steam-game-$(date +%Y%m%d-%H%M%S).log"
        printf 'Owned Steam-only GPTK4 launch bridge; original game guard; log=%s\n' "$log"
        cd "$(dirname -- "$steam")"
        exec "$bridge" "$steam" -cef-disable-gpu -cef-disable-gpu-compositing -cef-disable-occlusion -applaunch 3489700 -dx12 -windowed -ResX=1280 -ResY=800 > "$log" 2>&1;;
    gptk4-probe)
        # Per-process backend selection only. Installed engine/prefix modules
        # remain untouched; current Steam keeps its normal environment.
        gptk="$research_dir/runtime-gptk4b2/redist/lib"
        export GFX_BACKEND_PATH="$gptk/wine"
        export WINEDLLPATH="$gptk/wine:$WINEDLLPATH"
        export DYLD_LIBRARY_PATH="$gptk/external:$frameworks"
        export DYLD_FALLBACK_LIBRARY_PATH="$gptk/external:$frameworks"
        probe_adapter_library="${YYB_GPTK4_PROBE_ADAPTER_LIBRARY:-$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib}"
        case "$probe_adapter_library" in
            "$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-typed-draw.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-resource-usage-typed.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-resource-scope-trace.dylib"|"$research_dir/gpu-adapter-experiment/metal_device_adapter-resource-scope-trace-v2.dylib") ;;
            *) exit 2;;
        esac
        test -f "$probe_adapter_library"
        export DYLD_INSERT_LIBRARIES="$probe_adapter_library"
        export GPU_ADAPTER_MODE=gate GPU_ADAPTER_TEXTURE_MODE=managed GPU_ADAPTER_RENDERPASS_NORMALIZE=1 GPU_ADAPTER_TIMEOUT_SECONDS=30
        export D3DM_MTL4=0
        export WINEDLLOVERRIDES='d3d10,d3d11,d3d12,dxgi=b;winemenubuilder.exe=d;mscoree,mshtml='
        export WINEDEBUG=-all,err+all,+loaddll,+seh
        probe_stage="${2:-copy}"
        case "$probe_stage" in
            copy) probe="$research_dir/d3d12_probe.exe";;
            graphics) probe="$research_dir/graphics-probe/d3d12_graphics_probe.exe";;
            presentation) probe="$research_dir/presentation-probe/d3d12_presentation_probe.exe";;
            *) exit 2;;
        esac
        log="$research_dir/yyb-normal-gptk4-$probe_stage-$(date +%Y%m%d-%H%M%S).log"
        printf 'Owned GPTK4 backend probe only; log=%s\n' "$log"
        exec "$WINELOADER" "$probe" > "$log" 2>&1;;
    replay)
        owned_pid=$(<"$research_dir/yyb-normal-protected-server.pid")
        test "${YYB_REPLAY_VERIFIED_PID:-}" = "$owned_pid"
        log="$research_dir/yyb-normal-replay-$(date +%Y%m%d-%H%M%S).log"
        exec "$WINELOADER" "$steam" -applaunch 3489700 -dx12 -windowed -ResX=1280 -ResY=800 > "$log" 2>&1;;
    window-state)
        test -f "$research_dir/yyb_window_state_probe.exe"
        exec "$WINELOADER" "$research_dir/yyb_window_state_probe.exe";;
    server)
        log="$research_dir/yyb-normal-server-$(date +%Y%m%d-%H%M%S).log"
        # Keep this tracked child alive instead of treating a daemonizing parent
        # (or a zombie plus a stale socket pathname) as the ready server.
        exec "$WINESERVER" -f -p120 > "$log" 2>&1;;
    steam|play)
        # Refuse to attach game launch to a pre-existing unguarded Wine family.
        if pgrep -f "$contents/MacOS/wineserver" >/dev/null; then
            printf 'Installed Tencent server already running; cannot establish guard inheritance.\n' >&2;exit 126
        fi
        test -f "$steam"
        /bin/bash "$research_dir/run_yyb_normal_steam_trial.sh" server &
        server_host_pid=$!
        printf '%s\n' "$server_host_pid" > "$research_dir/yyb-normal-protected-server.pid"
        device=$(stat -f %d "$WINEPREFIX"); inode=$(stat -f %i "$WINEPREFIX")
        socket="/tmp/.wine-$(id -u)/server-$(printf '%x' "$device")-$(printf '%x' "$inode")/socket"
        deadline=$((SECONDS + 20))
        while [ "$SECONDS" -lt "$deadline" ]; do
            kill -0 "$server_host_pid" 2>/dev/null || break
            [ ! -S "$socket" ] || break
            sleep 1
        done
        if ! kill -0 "$server_host_pid" 2>/dev/null || [ ! -S "$socket" ]; then
            printf 'Normal protected Tencent backend did not become ready; do not start retries.\n' >&2;exit 125
        fi
        log="$research_dir/yyb-normal-$stage-$(date +%Y%m%d-%H%M%S).log"
        printf 'Installed Tencent legitimate Steam; original game write guard; log=%s\n' "$log"
        cd "$(dirname -- "$steam")"
        # Tencent's existing bridge supplies its normal Cocoa event loop and
        # Steam package launch context. No direct game EXE or AppID fabrication.
        if [ "$stage" = play ]; then
            exec "$contents/MacOS/winelauncher" "$steam" -applaunch 3489700 > "$log" 2>&1
        fi
        exec "$contents/MacOS/winelauncher" "$steam" > "$log" 2>&1;;
    *) exit 2;;
esac
