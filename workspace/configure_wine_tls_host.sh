#!/bin/bash
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$research_dir/wine-11.16-tls-build"
mkdir -p "$build_dir"
cd "$build_dir"
export PATH="/usr/local/opt/bison/bin:/usr/local/opt/llvm@20/bin:/usr/local/opt/pkgconf/bin:$PATH"
export CC=/usr/bin/clang
export CXX=/usr/bin/clang++
"$research_dir/wine-11.16/configure" --enable-win64 --disable-tests \
  --without-x --without-gstreamer --without-cups --without-dbus \
  --without-freetype --without-fontconfig --without-gnutls --without-opengl \
  --without-opencl --without-pulse --without-sane --without-sdl \
  --without-usb --without-v4l2 --without-vulkan --without-wayland
