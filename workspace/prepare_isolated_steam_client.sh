#!/bin/bash
# Clone only this user's installed Steam client, not any game library.
# Do not print account/configuration contents; never mutate the source.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir='/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine/drive_c/Program Files (x86)/Steam'
client_dir="$research_dir/SteamClient"
test -f "$source_dir/steam.exe"
if [ -e "$client_dir" ]; then
    printf 'Client staging already exists; refusing a recursive overwrite.\n' >&2
    exit 2
fi
mkdir "$client_dir"
for source_item in "$source_dir"/*; do
    case "$(basename -- "$source_item")" in
        steamapps|logs|dumps|depotcache|appcache|userdata) continue;;
    esac
    # APFS clone, with symbolic-link semantics preserved.
    cp -cRP "$source_item" "$client_dir/"
done
mkdir "$client_dir/steamapps"
mkdir "$client_dir/steamapps/common"
cmp "$source_dir/steam.exe" "$client_dir/steam.exe"
printf 'Isolated existing Steam client staged; no game files copied or source files changed.\n'
