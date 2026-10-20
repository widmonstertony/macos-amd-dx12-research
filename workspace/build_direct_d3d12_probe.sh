#!/bin/sh
set -eu
probe_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/usr/bin/clang++ -std=c++17 -O1 -Wall -Wextra -fshort-wchar -fno-exceptions -fno-rtti -fno-stack-protector -ffreestanding "$probe_dir/direct_d3d12_probe.mm" -o "$probe_dir/direct_d3d12_probe"
file "$probe_dir/direct_d3d12_probe"
