#!/bin/sh
set -eu
probe_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
"$probe_llvm/llvm-dlltool" -m i386:x86-64 -d "$probe_dir/windows_load_library_kernel32.def" -l "$probe_dir/windows_load_library_kernel32.lib"
"$probe_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding -c "$probe_dir/windows_wine10_teb_mirror_probe.cpp" -o "$probe_dir/windows_wine10_teb_mirror_probe.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /out:"$probe_dir/windows_wine10_teb_mirror_probe.exe" "$probe_dir/windows_wine10_teb_mirror_probe.obj" "$probe_dir/windows_load_library_kernel32.lib"
file "$probe_dir/windows_wine10_teb_mirror_probe.exe"
