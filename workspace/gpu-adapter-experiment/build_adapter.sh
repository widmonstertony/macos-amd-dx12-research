#!/bin/bash
set -euo pipefail
adapter_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
clang -dynamiclib -fobjc-arc -fblocks -framework Foundation -framework Metal \
  "$adapter_dir/metal_device_adapter.m" "$adapter_dir/software_residency_adapter.m" "$adapter_dir/texture_storage_adapter.m" \
  -o "$adapter_dir/metal_device_adapter.dylib"
