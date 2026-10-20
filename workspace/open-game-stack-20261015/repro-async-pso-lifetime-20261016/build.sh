#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
"$llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra \
  -fms-extensions -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding \
  -c "$here/d3d12_pso_lifetime_stress.cpp" -o "$here/d3d12_pso_lifetime_stress.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib \
  /out:"$here/d3d12_pso_lifetime_stress.exe" "$here/d3d12_pso_lifetime_stress.obj" "$root/d3d12_probe_kernel32.lib"
file "$here/d3d12_pso_lifetime_stress.exe"
