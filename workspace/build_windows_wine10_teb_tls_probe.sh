#!/bin/sh
set -eu
probe_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe_llvm=/usr/local/Cellar/llvm@20/20.1.8/bin
case "${1:-load}" in
  load) probe_name=windows_wine10_teb_tls_probe; probe_def=windows_load_library_kernel32; probe_define=;;
  gpu) probe_name=windows_wine10_teb_tls_gpu_probe; probe_def=d3d12_probe_kernel32; probe_define=-DCOMPAT_GPU_PROBE;;
  *) exit 2;;
esac
"$probe_llvm/llvm-dlltool" -m i386:x86-64 -d "$probe_dir/$probe_def.def" -l "$probe_dir/$probe_def.lib"
"$probe_llvm/clang++" --target=x86_64-pc-windows-msvc -std=c++17 -O1 -Wall -Wextra -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding $probe_define -c "$probe_dir/windows_wine10_teb_tls_probe.cpp" -o "$probe_dir/$probe_name.obj"
/usr/local/bin/lld-link /nologo /entry:mainCRTStartup /subsystem:console /machine:x64 /nodefaultlib /include:_tls_used /include:wine10CompatCallbacks /out:"$probe_dir/$probe_name.exe" "$probe_dir/$probe_name.obj" "$probe_dir/$probe_def.lib"
file "$probe_dir/$probe_name.exe"
"$probe_llvm/llvm-readobj" --coff-tls-directory "$probe_dir/$probe_name.exe"
