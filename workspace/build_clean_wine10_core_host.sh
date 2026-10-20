#!/bin/bash
# Same Wine 10 source as the full build; prioritize bootstrap + UI.
# The optional public-source PE mapping experiment retains the stock GS ABI.
# Full-build objects are reused. No DLL from a different Wine is introduced.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$research_dir/Wine10-source/build"
host_dir="$research_dir/Wine10-source/host"
export PATH="/usr/local/opt/bison/bin:/usr/local/opt/llvm@20/bin:/usr/local/opt/pkgconf/bin:$PATH"
test -f "$build_dir/Makefile"
components=(
  nls fonts loader server
  dlls/apisetschema dlls/ntdll dlls/kernel32 dlls/kernelbase dlls/msvcrt dlls/ucrtbase
  dlls/user32 dlls/win32u dlls/gdi32 dlls/winemac.drv
  dlls/advapi32 dlls/sechost dlls/rpcrt4 dlls/combase dlls/ole32
  dlls/oleaut32 dlls/coml2 dlls/shell32 dlls/shcore dlls/shlwapi dlls/comctl32
  dlls/uxtheme dlls/comdlg32 dlls/dwmapi dlls/newdev dlls/userenv
  dlls/imm32 dlls/crypt32 dlls/bcrypt dlls/bcryptprimitives dlls/rsaenh
  dlls/ws2_32 dlls/nsi dlls/secur32 dlls/sspicli dlls/wintrust
  dlls/imagehlp dlls/setupapi dlls/cfgmgr32 dlls/version dlls/dnsapi
  dlls/winhttp dlls/wininet dlls/netapi32 dlls/mpr dlls/wtsapi32
  dlls/psapi dlls/iphlpapi dlls/winmm dlls/msacm32 dlls/winecoreaudio.drv
  dlls/winspool.drv dlls/spoolss dlls/propsys
  dlls/mountmgr.sys dlls/winebus.sys dlls/winehid.sys dlls/winexinput.sys
  dlls/ntoskrnl.exe dlls/hal dlls/hidparse.sys dlls/hidclass.sys
  programs/wineboot programs/services programs/rpcss programs/explorer
  programs/conhost programs/svchost programs/winedevice programs/rundll32 programs/reg
  programs/cmd programs/control programs/start
)
all_targets=()
install_targets=()
for component in "${components[@]}"; do
  if ! rg --fixed-strings --quiet "$component/all:" "$build_dir/Makefile"; then
    printf 'Configured target missing: %s\n' "$component/all" >&2
    exit 2
  fi
  all_targets+=("$component/all")
  install_targets+=("$component/install-lib")
done
cd "$build_dir"
make -j6 "${all_targets[@]}"
make "${install_targets[@]}"
mkdir -p "$host_dir/.core-only-build"
"$host_dir/bin/wine64" --version
printf 'Core host only: full make/install may be resumed after probes.\n'
