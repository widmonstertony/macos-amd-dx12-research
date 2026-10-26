# CPU-only sample-access prototype

This prototype is not connected to MoltenVK, binding, heap residency, device capabilities, or cache serialization. It accepts real SPIR-V words and rejects unknown opcodes/capabilities/extensions/instruction sets, unsafe image types and fetch/read/write/atomic operations. All functions, including unused ones, are inspected. A positive result requires a genuine semantic-validation callback; the default callback is absent and rejects.

The test binary uses the installed public SPIRV-Tools C API, and all authored fixtures are independently assembled and validated. It checks malformed lengths, versions, IDs, missing validator, unknown operations and unchanged input words. The implementation is a policy prototype, not a replacement SPIR-V validator.

Build and test (CPU only):

```sh
python3 evidence/sample-only-image-access-20261026/build_fixtures.py
clang++ -std=c++17 -O2 tools/test_sample_only_image_access.cpp $(pkg-config --cflags --libs SPIRV-Tools) -o /tmp/sample-image-access-test
/tmp/sample-image-access-test --self-test evidence/sample-only-image-access-20261026/fixtures
```

`generate_header.py` pins the grammar used to produce an explicit opcode allowlist. It is not run automatically during native builds.

The initial strict capability table rejected all 64 private cache-prefix samples because they declare physical buffer addresses. That result is preserved in `initial-strict/`. A single explicit expansion admitted known standard buffer-address/demote declarations and operations, keeping all unknown/unsafe operations rejected. The final rule set is frozen. It classifies 27 fragment modules as sample-only; 22 modules fail image-type restrictions and 15 have no sampling. All 64 pass independent semantic validation, and all input hashes are unchanged. This is a fixed first-prefix sample, not a slow-pipeline or game-wide weighted hit rate.

No raw cache, extracted shader, private index or validation message should be published. `private/` contains the per-module census; `corpus-summary.json` contains aggregate scope and limits.

A positive result proves only whole-module SPIR-V image access under this rule set. It does not establish texture/heap/attachment eligibility, generated MSL access semantics, retained resource lifetime, hazard ordering, GPU correctness or performance. The current native build excludes SPIRV-Tools, so production integration needs a genuine validation contract. Reusing the existing SPIRV-Cross parser or successfully converted IR is an alternative with different guarantees, not permission to pass an always-true validator.

Runtime integration would still need transient bind-script metadata (not a shader-cache format change), distinct sample/precise binding coverage, precise texture-read exception handling after heap preparation, attachment and view/alias rules, and real GPU output regressions before a user-run game trial.
