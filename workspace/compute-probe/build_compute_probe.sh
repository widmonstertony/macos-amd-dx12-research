#!/bin/sh
set -eu
compute_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
compute_research=$(CDPATH= cd -- "$compute_dir/.." && pwd)
compute_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
/usr/bin/clang++ -std=c++17 -O1 -fms-extensions -framework Foundation "$compute_dir/compile_compute_shader.mm" -o "$compute_dir/compile_compute_shader"
"$compute_dir/compile_compute_shader" "$compute_research/runtime-gptk4b2/redist/lib/external/D3DMetal.framework/Versions/A/Resources/libdxcompiler.dylib" "$compute_dir/compute_shader_dxil.h"
"$compute_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding -c "$compute_dir/d3d12_compute_probe.cpp" -o "$compute_dir/d3d12_compute_probe.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /out:"$compute_dir/d3d12_compute_probe.exe" "$compute_dir/d3d12_compute_probe.obj" "$compute_research/d3d12_probe_kernel32.lib"
/usr/bin/clang++ -std=c++17 -O1 -Wall -Wextra -fshort-wchar -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding "$compute_dir/native_compute_host.mm" -o "$compute_dir/native_compute_host"
file "$compute_dir/d3d12_compute_probe.exe" "$compute_dir/native_compute_host"
