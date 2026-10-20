#!/bin/bash
# Build the saved open-source MoltenVK/SPIRV-Cross only. No game deployment.
set -euo pipefail
backup_root="$(cd "$(dirname "$0")/.." && pwd)"
research_root="${1:-$backup_root/workspace}"
stack_root="$research_root/open-game-stack-20261015"
native_root="$stack_root/native-vendor"
build_root="$stack_root/build/restored-native"
cmake -S "$native_root/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93" \
  -B "$build_root" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DMVK_EXCLUDE_SPIRV_TOOLS=ON -DMVK_USE_METAL_PRIVATE_API=OFF \
  -DCPM_SOURCE_CACHE="$native_root/cache" \
  -DCPM_SPIRV-Cross_SOURCE="$native_root/SPIRV-Cross-939b40b33a44443c404c4078823c406e3c94866f" \
  -DCPM_Vulkan-Headers_SOURCE="$native_root/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a" \
  -DCPM_cereal_SOURCE="$native_root/cereal/cereal"
if [ "${NATIVE_CONFIGURE_ONLY:-0}" = "1" ]; then
  exit 0
fi
cmake --build "$build_root" --parallel "${BUILD_JOBS:-4}"
codesign --force --sign - "$build_root/MoltenVK/libMoltenVK.1.4.2.dylib"
