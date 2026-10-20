#!/bin/sh
set -eu
graphics_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
graphics_research=$(CDPATH= cd -- "$graphics_dir/.." && pwd)
graphics_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
/usr/bin/clang++ -std=c++17 -O1 -fms-extensions -framework Foundation "$graphics_dir/compile_graphics_shaders.mm" -o "$graphics_dir/compile_graphics_shaders"
"$graphics_dir/compile_graphics_shaders" "$graphics_research/runtime-gptk4b2/redist/lib/external/D3DMetal.framework/Versions/A/Resources/libdxcompiler.dylib" "$graphics_dir/graphics_shaders_dxil.h"
"$graphics_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding -c "$graphics_dir/d3d12_graphics_probe.cpp" -o "$graphics_dir/d3d12_graphics_probe.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /out:"$graphics_dir/d3d12_graphics_probe.exe" "$graphics_dir/d3d12_graphics_probe.obj" "$graphics_research/d3d12_probe_kernel32.lib"
/usr/bin/clang++ -std=c++17 -O1 -Wall -Wextra -fshort-wchar -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding "$graphics_dir/native_graphics_host.mm" -o "$graphics_dir/native_graphics_host"
file "$graphics_dir/d3d12_graphics_probe.exe" "$graphics_dir/native_graphics_host"
