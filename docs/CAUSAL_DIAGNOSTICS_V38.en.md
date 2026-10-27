# v38 causal diagnostics: source-only checkpoint

v38 adds diagnostics over the v37 behavior and performance strategy. It records evidence for the next diagnosis; it does not establish a performance improvement, a playable game, or a confirmed fix. The human owns every game launch, action, shutdown and restart.

## What the source adds

| Area | Evidence added | Interpretation limit |
|---|---|---|
| Causal and owner chains | Bounded paired software spans, submission/queue/command-buffer owners, saved terminal intent and end records | Missing, sampled or unjoinable records remain explicit. Timing near an operation does not alone establish its cause. |
| Presentation identity and lifetime | Swapchain/surface generations, layer and drawable identities, presentation intent/call/callback timing, lock boundaries and retirement/reference lifetime records | Successful GPU completion or a signaled fence does not prove physical presentation. Raw zero presentation timestamps remain zero; callback time is separate from presentation time. |
| Stream and session identity | Process-start identity, run/session IDs, clock anchors, stream generations, sequence continuity, writer/copy losses and configuration fingerprints | Reused handles, arm changes, rotation and missing prefixes cannot be silently joined into one complete history. |
| Display/session context | Selected public boolean and numeric display-power, HID-idle and session metadata, with acquisition time brackets | Missing or conflicting values remain unknown. These observations do not prove historical lock/display state; active or on-screen window flags do not prove physical display. No screenshot, credentials or private session identity fields are collected. |
| Capture retention | Independent raw quotas for the six labeled actions and unlabeled windows, retained original raw records, a bounded six-second tail after an arm closes, and reserved telemetry/error-tail capacity | Caps, rotation, low disk space and late records beyond the tail are undercoverage. A quota is not proof that every requested action was fully captured. |
| Observer cost | Separate sampler, polling, logging and collector CPU/wall-time accounting | Observer cost is not subtracted as an estimated FPS correction. Instrumented results are not an uninstrumented performance baseline. |

Terminal diagnostics save scalar provenance before commit or a path that can destroy the submission. Their post-commit/end records do not require dereferencing the destroyed submission or its queue. This is a diagnostic lifetime safeguard, not a change to presentation behavior or synchronization strategy.

## Human action labels

The external marker accepts only `stable`, `move`, `attack`, `equipment`, `nanosuit` and `present`, with `start` or `end` phases. For example, a human-supplied `<profile>/diagnostics.action.json` can contain:

```json
{"action":"attack","phase":"start"}
```

The collector records the marker's file timestamp and receipt clock. A label requests/annotates a diagnostic window; it does not generate keyboard or mouse input or verify that the game action occurred. Capture readiness, requested windows, remaining capacity and coverage gaps must be checked separately.

## Qualification at this checkpoint

The local Native build proof records `exitCode: 0`, `sourceStable: true`, `sourceFiles: 223` and `passed: true`. All 55 final Python fixture/mock tests passed, along with 21 terminal ASan/UBSan cases. Their private evidence is not copied into this source-only public update.

The bounded owned GPU regressions passed: the geometry control had no mismatches across 512 pixels / 8,192 primitives; the texture control passed six cases / 12,288 pixels and confirmed six shader-stage hits from the older v37 cache; owned compute and one-frame present probes under the original Wine passed in both cold and warm runs. These are small owned workloads, not proof of game performance or a game failure's root cause.

This checkpoint completes the bounded GPU regressions above; the actual game remains unvalidated. Actual game presentation, stutter, crash and FSR3 root causes remain unconfirmed. Correct scenes, sustained playable FPS, equipment/nanosuit stability, FSR3 upscaling and frame generation still require actual game evidence.

## Analysis completeness follow-up

The analyzer now pairs sync notifications across all parsed rows, exposes drawable acquisition and actual present-call intervals, and reads allocation failure/slow journals plus recent snapshot rings. The first 2,000 records are a display limit, reported separately from writer loss. All 93 CPU tool tests pass. This update changes no Native code, runtime library, cache, or running collector.

Each allocation journal retains the first 128 events; each snapshot ring retains the latest 32. These overlap, so omission counts must not be added. There is no durable allocation Begin: an unreturned call's exact pending ID/site remains unknown, and an attempts/completed difference does not establish a hang or OOM. Full-event loading checks PID, kernel start and observed Mach bounds. Wine's `vkQueueSubmit2` assertion checks outer NTSTATUS separately from inner VkResult; static call-chain verification is not a captured fault-time status.

## Public backup boundary

## RenderThread timeout evidence

The latest human-operated run reached UE4's 120-second RenderThread wait watchdog. The blocking call is still unresolved. Graphics progress had already stopped before scene sampling, so empty stage records do not establish a healthy renderer. Passing isolated heap-plan GPU controls also did not establish use in the game; published local counters did not show a successful application.

Add `watch_render_stall_stacks.py`: wait for the human to launch one uniquely identified game process, verify PID/start/kernel identity, and collect bounded native stacks with the system `sample` tool. Stale progress plus raw VM-fault growth is a diagnostic trigger, not a root-cause verdict. Optional continuous mode refreshes separate native/forensics markers every 20/60 seconds; CPU/GPU counter markers remain separate. Limits include eight two-second bursts, 128 MiB output, two bounded raw-tail banks, ownership checks and disk-aware cleanup.

Thirty-three CPU mock controls and fixes from independent review passed. Actual game stack quality, trigger sensitivity and performance gains remain unverified. Only observation tools and diagnostic paths change; the graphics library and performance configuration are unchanged. Raw local logs, crash files and stacks remain private.

This update copies source only. It contains no private checkpoints, raw game logs, shaders, binaries or runtime packages, and creates no new release. Historical checkpoint data is unchanged. Existing historical results retain their original scope; the new diagnostics do not retroactively validate them.

## v39: precise-fallback heap identity fix (2026-10-26)

Actual game stacks and submission ownership locate this stall in the open-source resource grouping path: `queuePreciseRead` throws a retained heap identity `logic_error` before the current native command buffer is committed. Other queues and the upper render thread then wait. This is a regression in the added grouping optimization; it does not explain every historical OOM or low-FPS case.

The historically named `nilHeapResources` bucket also holds physically heap-backed textures requiring precise declarations, including writable/attachment/view and placement-overlap exclusions. The caller incorrectly supplied nil and marked `heapKnown=true`. The fix passes `resource.heap`, preserving precise residency, stage/write replay and genuine identity-change checks. Only that Native caller file changed among the stable 223-source-file build.

Validation:

- The old library reproduces the same exception through the real helper. In the reverse order its pixels are correct but heap metadata and write replay are wrong; that case remains a failure.
- Both candidate orders pass 1,290 actual GPU pixel/word comparisons with zero mismatches. The fixture includes 128 bulk-eligible textures and one physically heap-backed writable exception, plus Vertex/Fragment, encoder reset and write replay.
- New CPU regression: 12,368 checks; existing ledger: 1,292,945 checks. Ten genuine identity-change negative cases remain rejected.
- Existing texture, geometry and original-Tencent-Wine owned compute/present controls pass; the old owned Vulkan fixture cache is unchanged.

Earlier published zero-application statistics predate actual heap API applications. They cannot establish that the plan never ran. The trace has writer drops; contiguous emitted sequence numbers do not prove complete coverage. Repeated stacks and submission ownership support the specific stall diagnosis.

The candidate is installed locally; the human continues to operate the game. Actual scene FPS improvement, attack/equipment/nanosuit stability, presentation delays and both FSR3 features remain unvalidated. This public update contains source and reproduction tools only; downloadable runtimes are unchanged, with no playability claim.

CPU reproduction:

```sh
python3 tools/qualify_heap_plan_precise_identity.py --output evidence/owned-precise-identity
```

The GPU comparison runner is `tools/qualify_heap_texture_exception_gpu.py`, requiring separately built old/new Native libraries. It runs authored resources and shaders, never the game.

## Actual v39 scene and offline v40 fix

The human subsequently entered a scene and reported severe stutter. The process image UUID matches deployed v39. A 39.413-second observed foreground interval yielded about 1.210 Hz in the valid software present sequence, not physical display FPS. Public GPU execution intervals cover 8.71% of that window, not hardware utilization. Across 35.737 seconds of complete CPU windows, NativeRead self is 17.749 seconds and ResourceGroup self is 7.185 seconds, without scene compilation activity. Per-resource Metal declarations and bookkeeping remain major measured contributors; v39 has not solved low performance. Historical FPS at different resolutions, scenes and instrumentation states is not a speed comparison.

Startup compilation has a separate identified contention point: the second detached PSO creation after archive loading held the shared MTLDevice monitor. v40 preserves that recreation to avoid retaining archive mappings, submits async Metal work under the monitor, and waits outside it. Original PSO fallback and the configured compile timeout remain. Shared requests own descriptor/device/result; late callbacks never access a parent compiler and preserve their original diagnostic session. An admitted async Metal API entry may itself block, so the caller deadline cannot cancel driver work or guarantee a short monitor hold.

Offline qualification passed:

- Stable 224-file Native build; optimized and ASan/UBSan each pass 100 CPU checks with 60/60 objects released.
- Five candidate texture GPU cases check 10,240 pixels with zero mismatches; 15 strict render archive hits and 15 successful detached recreations.
- Headless owned compute cold/warm controls in original Tencent Wine pass with strict compute archive-hit verification.

v40 is **not deployed to the game**. The human continues to operate the same game process with preserved caches. Actual startup speedup, mapping-retention counts and game FPS improvement remain unproven. A stricter eligible-2D access contract is under investigation: representative 3D/buffer reads disqualify an entire stage, potentially excluding otherwise sampled 2D images. It is not integrated; keyword matching or allowing a whole aliased binding is insufficient. Remaining PSO-label coverage is incomplete, so overall benefit is unknown.

## v41: reduce per-resource readonly texture declarations

The v39 scene identified read declarations and grouping as major CPU costs. A whole-stage sampling-only gate unnecessarily excluded physically readonly 2D textures whenever a shader also used Buffer/3D/2D fetch. Metal useHeaps declares readonly argument-buffer access, including texture.read; real 5600M output controls confirm that behavior without shader rewriting.

v41 reuses the existing heap plan for readonly bindings. Native usage/storage/view/overlap exclusions, ownership, stage/reset coverage and precise write replay remain. Writable textures, attachments, views, buffer-backed textures and unknown/overlapping ranges do not gain bulk eligibility. Generated shaders and cache formats are unchanged. Historical sampled/sampleOnly internal names remain for compatibility. The separate typed-2D classifier prototype is preserved but inactive; no optional validator is required.

Eight mixed Vulkan cases checked 24,576 pixels with zero mismatches, covering BC1 sample/fetch/query, actual 3D/texel-buffer reads, stage transitions and encoder resets. For the identical switch workload, precise readonly references fell from 1,040 to 16, with eight heap calls; this is not a game FPS multiplier. The unchanged older cache yielded eight shader-stage cache hits. Existing texture/archive, heap-backed write-exception and 8,192-primitive geometry regressions pass.

v41 also includes the previously offline-qualified v40 async detached-PSO repair and is installed in the original local launch chain. The human operates the game and existing caches are preserved. A headless D3D12 control in original Tencent Wine timed out before the candidate/proxy mapped; that failure is retained and is neither a pass nor evidence against this graphics change. Actual Steam startup, scene FPS, combat/equipment stability and both FSR3 features remain unverified. This is a source/tool update, not a new playable runtime release.

## v41b: OS update cache mismatch and exhausted admission budget

The human launched the real v41 game, whose loaded library UUID is confirmed. The preceding run used macOS 26.7.1 (25G241); this run uses 26.7.2 (25G332). Render archive keys include the OS version and observed requests miss, while 2,632 same-named generated sources match v39 byte for byte. Metal services are compiling source and game workers await results. This is not evidence of a deadlock or a complete explanation of every slow compile.

The legacy render archive contains 2,147,482,864 bytes: only 784 bytes remain in its 2 GiB admission budget. Reservations require 16 MiB, and runtime diagnostics show 2,713 budget skips. New-system results therefore cannot continue being saved there. v41b scopes the game profile's archive directories by the actual kernel build, preserving strict cache validation and existing write limits. Old archives are not deleted and the running game is not hot-modified or restarted. Old-system native archives are not required by the current OS; retention follows the earlier preserve-cache instruction, not a claimed speed benefit.

CPU controls verify version separation, same-version stability, seven invalid-name rejections and symlink rejection. Owned cold/warm Vulkan GPU controls check 4,096 pixels with zero mismatches, write three archives and obtain three strict native cache hits on the second run. The Native library remains identical to v41; only game startup configuration changes. v41b is built but not deployed. First compilation on the new OS, actual game speed and broad cache coverage remain unresolved.

## Further v41b scene decomposition and v42 diagnostic fields

The real game reports os-scoped-archive-ready. The new OS directory holds 6,018 render archives (722,594,016 bytes). Compiler services were idle and the sample contained no compiler calls; this observed stutter cannot be attributed to continuous shader compilation. Real-game cold/warm restart cache hits remain unqualified.

Ten complete host timeline waits each have one captured completed satisfying graphics producer. Waits span about 119–333 ms; 95.21% of their cumulative duration precedes the final signaling CB commit. The producer's public GPU execution-interval union has a median around 16.26 ms, not hardware GPU utilization or an exclusive critical path.

A same-process bounded burst records 896 read calls, 366,179 references, 299.097 ms API wall and 297.933 ms thread-CPU brackets. Cost is spread across 112 pipelines; the largest accounts for about 4.782%. Rejecting label changes inside calibration uncertainty and compute native-label conflicts leaves 93.874% reliable label-cost coverage. A looser nearest-event join gave 99.955% and is not treated as reliable. Eight counter files are truncated, not complete GPU coverage. No identical address-sequence repeats were found within the same CB/encoder/generation/stage; this does not authorize removing cross-encoder declarations or necessary replay.

CPU stacks identify bindHeapPlansAndReset → queuePreciseRead/heapIndex → AMD Metal useResources. The current library does not export precise physical exception classes or read-replay counts, so ShaderWrite, RenderTarget and other possible causes remain unproven. v42 adds diagnostics only: lazy per-plan/session physical properties, writable/attachment intersections, and admission information before the eligible-too-small return; a five-second current snapshot reports queued/suppressed/replayed/metadata-visit counts beyond the historical JSONL row cap. Property categories may overlap. Offered records are not claimed admitted; observer cost is timed separately.

Resource eligibility, shaders, cache format and game settings are unchanged. The candidate is built; the actual game still runs v41b and was not restarted or replaced. analyze_resource_pipeline_burst.py only reads frozen files. qualify_resource_property_gpu.py requires matching Native libraries/headers and is not a cross-version ABI performance comparison. Physical game FPS, the dominant remaining precise-resource exception and playability remain unproven.

The final diagnostic candidate passes 24,576 mixed-texture pixels, 2,580 helper output values and 512 geometry pixels with zero mismatches. Owned controls verify one property record per plan/session, 128 eligible children plus one writable non-attachment exception, and actual five-second current ledger output. This is not a game performance repair or FPS validation.

After the human confirmed game exit, final v42 diagnostics were deployed to the original game launch chain with cache metadata unchanged. Source commit: e4aac2a. Deployment/rollback steps are in operations/2026-10-26-v42-deployment.json. Git revert restores source; the runtime must then be rebuilt and redeployed.
