#!/bin/sh
set -eu
probe_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
"$probe_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding -c "$probe_dir/cross_process_gdi_probe.cpp" -o "$probe_dir/cross_process_gdi_probe.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /out:"$probe_dir/cross_process_gdi_probe.exe" "$probe_dir/cross_process_gdi_probe.obj" "$probe_dir/d3d12_probe_kernel32.lib"
