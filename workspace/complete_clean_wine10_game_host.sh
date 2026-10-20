#!/bin/bash
# Same-source mandatory PE dependencies only; no original prefix or game edits.
# Default only builds. Install only when all probes using this host have stopped.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$research_dir/Wine10-source/build"
operation="${1:-build}"
case "$operation" in build|install) ;; *) printf 'Use build or install.\n' >&2; exit 2;; esac
export PATH="/usr/local/opt/bison/bin:/usr/local/opt/llvm@20/bin:/usr/local/opt/pkgconf/bin:$PATH"
components=(
  compstui d3d9 dbghelp dinput8 dsound hid jsproxy normaliz
  oleacc opengl32 pdh uiautomationcore wined3d wldap32
  mswsock wsock32 dhcpcsvc dwrite avrt mmdevapi d3dcompiler_43
  ntoskrnl.exe hal hidparse.sys hidclass.sys
)
targets=()
for component in "${components[@]}"; do
  target="dlls/$component/all"
  if [ "$operation" = install ]; then target="dlls/$component/install-lib"; fi
  rg --fixed-strings --quiet "$target:" "$build_dir/Makefile"
  targets+=("$target")
done
cd "$build_dir"
if [ "$operation" = build ]; then
  make -j4 "${targets[@]}"
else
  make "${targets[@]}"
  # Keep the original Apple PEs/Unix bridge after any Wine module installation.
  bash "$research_dir/stage_clean_wine10_gptk4.sh"
fi
