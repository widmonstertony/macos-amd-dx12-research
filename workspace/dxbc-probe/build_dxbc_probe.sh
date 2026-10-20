#!/bin/sh
set -eu
dxbc_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dxbc_research=$(CDPATH= cd -- "$dxbc_dir/.." && pwd)
dxbc_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
"$dxbc_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding -DGRAPHICS_PROBE_DXBC_SM5 -c "$dxbc_research/graphics-probe/d3d12_graphics_probe.cpp" -o "$dxbc_dir/d3d12_dxbc_graphics_probe.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /out:"$dxbc_dir/d3d12_dxbc_graphics_probe.exe" "$dxbc_dir/d3d12_dxbc_graphics_probe.obj" "$dxbc_research/d3d12_probe_kernel32.lib"
file "$dxbc_dir/d3d12_dxbc_graphics_probe.exe"
