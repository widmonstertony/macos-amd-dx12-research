#!/bin/bash
# Official Wine 10 source, unchanged macOS GS/TEB ABI, own build/install paths.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
source_root="$research_dir/Wine10-source"
source_dir="$source_root/wine-10.0"
build_dir="$source_root/build"
host_dir="$source_root/host"
test -x "$source_dir/configure"
mkdir -p "$build_dir"
export PATH="/usr/local/opt/bison/bin:/usr/local/opt/llvm@20/bin:/usr/local/opt/pkgconf/bin:$PATH"
export CC=/usr/bin/clang CXX=/usr/bin/clang++
export CFLAGS='-O2 -g0' CXXFLAGS='-O2 -g0'
export PKG_CONFIG_PATH="/usr/local/opt/freetype/lib/pkgconfig:/usr/local/opt/fontconfig/lib/pkgconfig:/usr/local/opt/libpng/lib/pkgconfig:/usr/local/opt/vulkan-loader/lib/pkgconfig:/usr/local/lib/pkgconfig"
cd "$build_dir"
"$source_dir/configure" --prefix="$host_dir" --enable-win64 --disable-tests \
  --without-x --without-gstreamer --without-dbus --without-cups \
  --without-sane --without-pulse --without-wayland --without-v4l2 \
  --without-usb

