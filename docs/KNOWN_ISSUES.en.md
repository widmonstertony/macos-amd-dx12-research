Latest (2026-10-20): the game remains unplayable. Observed locn2 failures were eliminated by stable unique mesh entry names; archive-hit rehydration resolved the measured mapping leak. A later correctly rendered scene still delivered about 1–2 FPS and then GPU timeouts. Effective configuration and low-overhead CPU/GPU/queue timing are under validation. FSR3 upscaling and frame generation remain unvalidated, with historical force-off settings still present during the base-FPS measurement. The table below preserves older observations, not current process state.

# Known issues and evidence gaps

| Priority | Observation | What remains unknown |
|---|---|---|
| P0 | Full game replay PID 66635 timed out on native compute and graphics queues at 2026-10-20 07:41:16 UTC | Which earliest producer failed to complete; whether ordering, workload, or resource state caused it |
| P0 | Compute waited for graphics timeline 108032 while observed 108030; graphics later waited for compute 15418 while observed 15417 | Native enqueue/commit/scheduled order is absent. Earlier exact-value signal producers have no recorded semaphore waits. No dependency cycle is proven |
| P1 | Scene entry has very low frame rate and blue rectangular corruption | CPU resource-declaration cost, GPU workload, and rendering defects need separate attribution |
| P1 | Native MSL and pipeline work repeats; mesh link failures can trigger successful source replay | Full compiler-option/specialization/library identity and reusable native archives require more work |
| P1 | Cocoa window controls may fail even while Win32 is enabled/resizable/responding | Native input routing/state needs further reproduction; no confirmed root cause yet |
| Coverage | Queue fixtures pass at large readback counts | They do not reproduce the game failure or validate full shader/texture/descriptor semantics |
| Packaging | No generic Wine/game installer; historical proxies are path-bound | Additional portable integration and actual game validation are required |

Earlier GPU reports listing completed encoders do not identify a guilty shader. An opened archive is not a strict native archive hit. A game out-of-memory dialog is not sufficient evidence of physical VRAM exhaustion. Do not suppress these errors or claim complete DX12/FSR3 compatibility.

Logs in the historical snapshot describe their capture time; they are not live process state. PID values must never be reused blindly.
