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

## Public backup boundary

This update copies source only. It contains no private checkpoints, raw game logs, shaders, binaries or runtime packages, and creates no new release. Historical checkpoint data is unchanged. Existing historical results retain their original scope; the new diagnostics do not retroactively validate them.
