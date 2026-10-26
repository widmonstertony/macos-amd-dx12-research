# Stutter diagnosis within one game process

v36 adds diagnostics over v35 behavior. It does not establish improved FPS or playability. The human owns game launch, input, shutdown and restart. Diagnostic windows can be rearmed within the same process, without another launch merely to add a measurement.

## Coverage

| Layer | Evidence | Limits |
|---|---|---|
| D3D12 API and workers | Execute, queue acquire/drain, actual Vulkan submits/semaphore waits, PSO creation and original results | Guest Windows identities are not host/Mach identities; object joins require evidence |
| Resources and descriptors | Descriptor-copy cumulative offers and sampled time; native snapshot/cache invalidation/read-plan/precise-write/Metal-call counters | Sampled measurements are not extrapolated totals; native counters are emitted per encoding segment, not as per-resource JSON |
| Compilation and caches | Actual hit/miss branches, serialized configuration fingerprints, compiler requests/callbacks and lock waits | A shader hash is not the full variant key; closed compiler internals remain opaque |
| CPU to GPU | Logical submits, native CB creation/commit/scheduling/completion, event values and waits | Synchronization behavior is preserved; splits, missing events and arm boundaries stay explicit |
| GPU and presentation | Bounded real GPU timestamps with paired clocks and actual native presentation timestamps | Callback time is not presentation time; timestamp differences are not exclusive draw costs; not every command is guaranteed sampled |
| Host and observer | Process/thread CPU, continuous foreground intervals, VM/swap/disk/thermal limits, collector cost and losses | Host-wide pressure is not exclusively attributed to the game; synchronous diagnostic I/O has measurable cost |

The loaded DXGI binary does not yet have an exact matched, rebuildable source tree. Its internal limiter/frame-latency waits are an explicit gap, supported only by surrounding timing and available stack samples. Game and closed-driver internals are also incomplete. One scenario cannot be promised to trigger every fault.

## One run

Use `tools/capture_stutter_session.py` with the deployed profile and a separate output directory. Configure the two-line Windows sidecar from the original prefix's verified drive mappings. The collector primes markers before the human launch, follows that exact process, and periodically or manually rearms bounded windows. It never launches, stops or controls the game.

Within that run, cover an idle scene, movement/camera changes, attacks and the equipment menu. Record the action order. Preserve a stalled process for further capture when possible; neither a progress percentage nor a surviving window establishes success.

Raw rolling streams, CPU current/status, clock anchors, marker boundaries and losses are archived separately. PID, process start time and kernel identity must agree. Output/disk limits release diagnostic arms and owned observers; they do not terminate the game.

## Qualification

CPU counters, concurrency, arming, rotation, tails and original error values are checked before owned GPU output controls. A real GPU control caught a diagnostic regression: `getVkQueue()` resets loader dispatch magic, so logging now uses a read-only identity accessor. That faulty version was not deployed to the game.

Observer costs are not negligible and must remain visible; instrumented FPS is not an uninstrumented baseline. Probe success does not establish correct game scenes, sustained FPS, attack/equipment stability, or either FSR3 feature. Downloaded artifacts remain research builds.

## Same-process observer control and follow-up source

The collector now supports `--instrumentation-mode forensics-only`: it holds only `forensics.arm` and does not request detailed CPU scopes or GPU boundary sampling. Observer cost remains, and workload changes prevent direct speedup attribution. A rolling copy budget that cannot fit the next complete JSON row explicitly marks truncation.

The [standalone CPU classification prototype](../workspace/open-game-stack-20261015/evidence/sample-only-image-access-20261026/README.md) rejects unknown/unsafe image access and rejects input without a genuine semantic validator. It is not integrated into Native and proves neither heap/attachment/lifetime eligibility nor GPU correctness or FPS.

Runtime integration still needs access-tier upgrades, precise read/write exceptions after heap preparation, and real GPU regressions. Shader serialization and cache UUIDs remain unchanged. New source does not imply a deployed performance fix.
