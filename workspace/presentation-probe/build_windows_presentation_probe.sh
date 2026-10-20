#!/bin/sh
set -eu
presentation_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
presentation_research=$(CDPATH= cd -- "$presentation_dir/.." && pwd)
presentation_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
"$presentation_llvm/llvm-dlltool" -m i386:x86-64 -d "$presentation_dir/presentation_user32.def" -l "$presentation_dir/presentation_user32.lib"
"$presentation_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding -c "$presentation_dir/d3d12_presentation_probe.cpp" -o "$presentation_dir/d3d12_presentation_probe.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /out:"$presentation_dir/d3d12_presentation_probe.exe" "$presentation_dir/d3d12_presentation_probe.obj" "$presentation_research/d3d12_probe_kernel32.lib" "$presentation_dir/presentation_user32.lib"
file "$presentation_dir/d3d12_presentation_probe.exe"
