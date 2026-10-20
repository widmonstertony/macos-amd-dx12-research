#!/bin/bash
# No installed files or live prefixes touched; install path was configure-scoped.
set -euo pipefail
research_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$research_dir/Wine10-source/build"
export PATH="/usr/local/opt/bison/bin:/usr/local/opt/llvm@20/bin:/usr/local/opt/pkgconf/bin:$PATH"
test -f "$build_dir/Makefile"
cd "$build_dir"
make -j6
make install
