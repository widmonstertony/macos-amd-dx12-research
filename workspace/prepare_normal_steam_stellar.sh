#!/bin/bash
# Register only the installed, legitimate game in the independent Steam copy.
# Its borrowed original assets must be write-protected during ALL Wine runs.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_game='/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/StellarBlade'
source_manifest='/Volumes/Applications/Program Files (x86)/Steam/steamapps/appmanifest_3489700.acf'
destination="$research_dir/SteamClient/steamapps"
test -f "$research_dir/stellar-original-write-guard.sb"
test -f "$source_manifest"
test -f "$source_game/SB/Binaries/Win64/SB-Win64-Shipping.exe"
cmp "$source_game/SB/Binaries/Win64/SB-Win64-Shipping.exe" "$research_dir/stellar-overlay/SB/Binaries/Win64/SB-Win64-Shipping.exe"
test -d "$destination/common"
if [ -e "$destination/appmanifest_3489700.acf" ]; then
    printf 'Research manifest exists; keeping its Steam-managed state.\n'
else
    cp -p "$source_manifest" "$destination/appmanifest_3489700.acf"
fi
if [ -L "$destination/common/StellarBlade" ]; then
    test "$(readlink "$destination/common/StellarBlade")" = "$research_dir/stellar-overlay"
elif [ -e "$destination/common/StellarBlade" ]; then
    printf 'Refusing to replace an existing research game directory.\n' >&2
    exit 2
else
    ln -s "$research_dir/stellar-overlay" "$destination/common/StellarBlade"
fi
printf 'Installed game registered in independent Steam copy; original game/client unchanged.\n'
