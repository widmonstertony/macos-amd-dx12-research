#!/bin/sh
set -eu
descriptor_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
descriptor_research=$(CDPATH= cd -- "$descriptor_dir/.." && pwd)
descriptor_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
/usr/bin/clang++ -std=c++17 -O1 -fms-extensions -framework Foundation "$descriptor_dir/compile_descriptor_shaders.mm" -o "$descriptor_dir/compile_descriptor_shaders"
"$descriptor_dir/compile_descriptor_shaders" "$descriptor_research/runtime-gptk4b2/redist/lib/external/D3DMetal.framework/Versions/A/Resources/libdxcompiler.dylib" "$descriptor_dir/descriptor_shaders_dxil.h"
"$descriptor_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding -c "$descriptor_dir/d3d12_descriptor_probe.cpp" -o "$descriptor_dir/d3d12_descriptor_probe.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /out:"$descriptor_dir/d3d12_descriptor_probe.exe" "$descriptor_dir/d3d12_descriptor_probe.obj" "$descriptor_research/d3d12_probe_kernel32.lib"
/usr/bin/clang++ -std=c++17 -O1 -Wall -Wextra -fshort-wchar -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding "$descriptor_dir/native_descriptor_host.mm" -o "$descriptor_dir/native_descriptor_host"
file "$descriptor_dir/d3d12_descriptor_probe.exe" "$descriptor_dir/native_descriptor_host"
