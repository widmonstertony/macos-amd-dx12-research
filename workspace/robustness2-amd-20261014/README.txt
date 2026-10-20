Robustness2 / AMD: isolated implementation and GPU evidence
=========================================================

Status: a working source-level subset, NOT a complete implementation of
VK_EXT_robustness2, NOT an installed MoltenVK patch, and NOT game compatibility.
No game, Steam, Wine, Tencent environment or system driver was started/modified.

What executes
-------------
Original unguarded SPIR-V
  -> src/r2_lower.py inserts bounds/null checks before real memory operations
  -> SPIR-V assembler and validator
  -> unmodified installed MoltenVK 1.4.2 / its SPIRV-Cross and Metal compiler path
  -> AMD Radeon Pro 5600M GPU
  -> fence completion and host readback compared with an independent CPU model.

src/r2_bindings.hpp implements the matching caller-side descriptor contract:
logical null resources are replaced by allocated, valid Vulkan dummy resources;
a separate metadata table retains the null status and descriptor byte ranges.
The GPU must return zero / suppress writes even though dummy memory is NONZERO.
This prevents a zero-filled dummy from hiding missing shader guards.
The native Robustness2 feature bits remain false and are never enabled.

Implemented and exercised on the actual GPU
------------------------------------------
* Descriptor-relative buffer range checks, including nonzero descriptor offsets,
  negative and large 32-bit indices, 32/64-bit integer loads/stores, and a vector
  that straddles the descriptor boundary. Byte-offset calculations use 64 bits.
* Out-of-range/null reads return zero; stores and 32-bit atomicAdd do not alter
  protected memory. 1,024 concurrent invocations test atomic return values and
  final memory, with results checked without assuming invocation ordering.
* 2D RGBA32_UINT storage-image reads/writes, integer coordinate bounds checks,
  and null images. Sampled 2D null textures return zero with explicit LOD;
  non-null sampler CLAMP_TO_EDGE behavior is retained outside [0,1].
* Fixed and runtime-sized storage-buffer descriptor arrays with nonuniform
  selection, mixed real/null slots, and range metadata per actual descriptor.
  Invalid descriptor indices are also rejected by guards (an extra guarantee
  of this prototype, not a claim that Robustness2 requires those indices).
* ArrayLength comes from the descriptor range, not the physical allocation,
  including dynamically selected buffer descriptors and null descriptors.
* SPIR-V 1.3 and 1.5 versions both execute on the GPU.

Final verified build
--------------------
evidence/runs/binding-contract-final/final-gpu-suite.json:
  Four native GPU suites, 36 scenario executions, 603,264 checked 32-bit words,
  zero mismatches. The 36 include the memory suite run in two SPIR-V versions;
  they are not 36 distinct Vulkan conformance tests.
  Every subprocess reports the actual AMD 5600M and native Robustness2 bits 000.
  Metal API Validation Enabled is confirmed in every stderr log; there are no
  additional validation diagnostics. No Khronos Vulkan validation layer or CTS
  suite was available/run. This is not conformance certification.
  Binding contract checks additionally reject seven invalid caller inputs and
  accept a null buffer with ignored source offset / VK_WHOLE_SIZE range.

evidence/compiler-boundary-checks.json:
  Nine rejection checks and one SPIR-V 1.5 validation check pass. Rejections
  include metadata-binding collision, absent/invalid runtime descriptor counts,
  physical buffer pointers, matrix layout, implicit derivative sampling,
  image atomics and 3D images. Fixture shaders are validated before lowering.

Source/binary/SPIR-V SHA-256 values and build logs are preserved alongside the
final GPU evidence. Earlier results and compiler failures remain in evidence/.
The initial host compile error and the SPIR-V 1.5 image-qualifier handling error
were fixed in source. A proposed GLSL 64-bit array-index case did not compile;
it was removed rather than silently truncated. Full 64-bit indices are NOT a
GPU-verified claim. Ordinary 64-bit DATA loads/stores are verified.

Unimplemented / unverified boundaries
------------------------------------
* No MoltenVK descriptor-update, pipeline-cache or shader-compilation hook is
  installed. The probe is the caller and explicitly supplies the matching
  metadata. A game currently receives none of these modifications.
* No pipeline robustness extension, dynamic descriptor offsets, descriptor-buffer
  integration, update-after-bind lifetime/concurrency, texel-buffer views, image
  descriptor arrays, array/3D/cube/MSAA/depth images, or view/mip/layer metadata.
* No implicit-derivative sampling, gather/depth compare/image queries, image
  atomics, physical pointers, pointer escape, matrix/copy-memory lowering, or
  64-bit atomics. Relevant encountered unsupported SPIR-V forms are refused.
* Only the operations/types/formats above have GPU coverage. Uniform buffers,
  floating-point formats, all other integer atomics, 8/16-bit accesses, graphics
  stages, and broad shader corpora have no GPU qualification here.
* Performance/overhead has not been benchmarked. The conservative helper calls,
  metadata reads and per-component guards need profiling before production use.
* None of the other vkd3d-proton / D3D12 capability gaps is resolved by this work.
  It does not explain or fix the previous D3DMetal game's black scene or stalls.

Next useful work is isolated integration with a source-built MoltenVK, preserving
the distinction between compiler lowering and descriptor binding, then expanded
resource/stage coverage and relevant conformance testing before any feature
advertisement. No closed compiler/driver change was needed for this subset;
that does not establish that all remaining gaps are software-fixable.

Reproduce without deploying
--------------------------
Dependencies already present on this Intel Mac: Python 3, glslc, SPIRV-Tools,
clang++, Vulkan headers/loader and the stock MoltenVK ICD. No dependency download
or installation is performed by these scripts.

  python3 build.py
    Rebuilds shaders, lowering, boundary checks and native probes. No GPU run.

  python3 run_gpu.py --run --metal-validation --label UNIQUE_RUN_NAME
    Requires host GPU visibility. Verifies build hashes before executing only
    headless native probes; no windows/game. Writes a new evidence/runs folder
    and refuses to overwrite an existing run. Stops at the first failure.

GPU adapter selection is exact: AMD vendor 0x1002 and device name containing
5600M. A missing GPU is an error, not permission to substitute Intel/software.
ICD/Metal validation variables are process-local; installed configuration files
are never edited. The original feature flags are observed, never fabricated.
