#!/bin/bash
set -euo pipefail
shopt -s nullglob dotglob
research_dir="$(cd "$(dirname "$0")" && pwd)"
game_source='/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/StellarBlade'
game_overlay="$research_dir/stellar-overlay"
overlay_directory() {
    local source_dir="$1" target_dir="$2" source_item leaf relative
    mkdir -p "$target_dir"
    for source_item in "$source_dir"/*; do
        leaf="${source_item##*/}"
        relative="${source_item#"$game_source"/}"
        case "$relative" in
            SB|SB/Binaries|SB/Binaries/Win64)
                overlay_directory "$source_item" "$target_dir/$leaf" ;;
            SB/Binaries/Win64/dxgi.dll|SB/Binaries/Win64/OptiScaler*|SB/Binaries/Win64/__CodexBackup*)
                ;; # Keep original Windows mods untouched and outside this test.
            SB/Binaries/Win64/SB-Win64-Shipping.exe)
                if [ ! -f "$target_dir/$leaf" ]; then cp "$source_item" "$target_dir/$leaf"; fi ;;
            *)
                if [ ! -e "$target_dir/$leaf" ] && [ ! -L "$target_dir/$leaf" ]; then
                    ln -s "$source_item" "$target_dir/$leaf"
                fi ;;
        esac
    done
}
test -f "$game_source/SB/Binaries/Win64/SB-Win64-Shipping.exe"
overlay_directory "$game_source" "$game_overlay"
test -f "$game_overlay/SB/Binaries/Win64/SB-Win64-Shipping.exe"
printf 'Isolated game executable prepared; content files are reused without copying the 64.7 GB installation.\n'
