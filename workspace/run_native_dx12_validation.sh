#!/bin/bash
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$research_dir"
framework="$research_dir/runtime-gptk4b2/redist/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
expected_sha=f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad
actual_sha="$(shasum -a 256 "$framework" | cut -d ' ' -f 1)"
test "$actual_sha" = "$expected_sha"
export GPU_ADAPTER_MODE=gate
export GPU_ADAPTER_TEXTURE_MODE=managed
export GPU_ADAPTER_RENDERPASS_NORMALIZE=1
export GPU_ADAPTER_TIMEOUT_SECONDS=60
export MTL_DEBUG_LAYER=1
export DYLD_INSERT_LIBRARIES="$research_dir/gpu-adapter-experiment/metal_device_adapter.dylib"
export D3DM_MTL4=0
export D3DM_ENABLE_METALFX=0
for stage in copy compute graphics; do
  case "$stage" in
    copy) test_host="$research_dir/direct_d3d12_probe"; result_pattern='copy_smoke.result=PASS';;
    compute) test_host="$research_dir/compute-probe/native_compute_host"; result_pattern='compute.result=PASS';;
    graphics) test_host="$research_dir/graphics-probe/native_graphics_host"; result_pattern='graphics.result=PASS';;
  esac
  "$test_host" "$framework" > "$research_dir/gpu-adapter-experiment/final-$stage-validation.log" 2>&1
  rg -F "$result_pattern" "$research_dir/gpu-adapter-experiment/final-$stage-validation.log"
done
printf 'PASS: three real GPU tests with Metal API Validation. Classification simulated; full conformance and games NOT TESTED.\n'
