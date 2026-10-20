#!/bin/bash
# Removes only our previous experimental backend from our own overlay.
# Existing game files, installed runtimes and OptiScaler remain untouched.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
overlay_dir="$research_dir/stellar-overlay/SB/Binaries/Win64"
backup_dir="$research_dir/stellar-overlay/previous-open-backend-dlls"
test -f "$overlay_dir/SB-Win64-Shipping.exe"
mkdir -p "$backup_dir"
for module in d3d11.dll d3d12.dll d3d12core.dll dxgi.dll; do
    if [ -f "$overlay_dir/$module" ] && [ ! -L "$overlay_dir/$module" ]; then
        if [ -e "$backup_dir/$module" ]; then
            printf 'Refusing to overwrite previous test DLL: %s\n' "$backup_dir/$module" >&2
            exit 2
        fi
        mv "$overlay_dir/$module" "$backup_dir/$module"
    fi
done
original_exe='/Volumes/Applications/Program Files (x86)/Steam/steamapps/common/StellarBlade/SB/Binaries/Win64/SB-Win64-Shipping.exe'
cmp "$original_exe" "$overlay_dir/SB-Win64-Shipping.exe"
printf 'Own Stellar overlay ready; original executable identical; prior experimental DLLs retained in %s\n' "$backup_dir"
