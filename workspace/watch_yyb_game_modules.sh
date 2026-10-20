#!/bin/bash
# Read only vmmap region names for the game launched by legitimate Steam.
# No raw process memory, credentials, stack/context dumps or game execution.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
output="$research_dir/yyb-game-module-watch-$(date +%Y%m%d-%H%M%S).log"
printf 'Owned diagnostic output=%s\n' "$output"
deadline=$((SECONDS+60))
game_pid=''
while [ "$SECONDS" -lt "$deadline" ]; do
    game_pid=$(ps -axo pid=,comm= | awk '/SB-Win64-Shipping[.]exe$/ && !found {print $1;found=1}')
    [ -z "$game_pid" ] || break
    sleep 0.2
done
if [ -z "$game_pid" ]; then printf 'No actual Steam Shipping process observed within60s.\n' | tee "$output";exit 2;fi
printf 'Actual Steam game pid=%s\n' "$game_pid" > "$output"
for ((i=0;i<12;i++));do
    kill -0 "$game_pid" 2>/dev/null || break
    printf '\nMetadata snapshot=%s\n' "$i" >> "$output"
    /usr/bin/vmmap -w "$game_pid" 2>&1 | rg -i 'd3d12|d3d11|dxgi|d3dmetal|metal_device_adapter|libvulkan|moltenvk|render/(gptk|dxvk|dxmt)|not permitted|failed' >> "$output" || true
    sleep 1
done
printf 'Metadata watch completed; no successful-game claim.\n' >> "$output"
