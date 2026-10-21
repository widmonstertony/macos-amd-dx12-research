> 连续 OneID 描述符表的大范围写入现在先裁去字节完全相同的首尾块，变化区仍走原来的引用计数和增量路径；其他布局使用独立编译的原循环。增加同进程交错 CPU 对照、随机集合校验和 50 万槽位真实 GPU 回读源码。此改动针对已采样的 CPU 扫描热点，不代表间歇性 GPU 超时已修复或游戏已稳定可玩。FSR3 超分与帧生成仍未验证；仅更新源码和通用说明。
> Trim byte-identical edge blocks of large contiguous OneID descriptor writes, retaining the original reference-count/delta path for potentially changed slots and a separately compiled original loop for strided layouts. Add paired in-process CPU controls, randomized set oracles and a 500,000-slot real GPU readback fixture. This targets an observed CPU scan hotspot; intermittent GPU timeouts and stable game playability remain unresolved. Both FSR3 features are unvalidated. Source and generic documentation only.

> 增加三独立队列、间接原子写入和像素回读的通用 GPU 对照源码。图形管线的诊断标签改为使用已有着色器源码身份，避免不同程序都显示为 main0。此修改只改善故障归因，未修复或验收游戏超时；稳定可玩和 FSR3 超分/帧生成仍未验证。新的本机故障日志保持私有。
> Add a generic three-queue indirect atomic-write and pixel-readback control. Graphics failure labels now carry existing shader source identities instead of ambiguous main0 entry names. This improves attribution only; game timeouts and stable playability remain unresolved, and both FSR3 features are unvalidated. New local fault logs remain private.

> 合并同一批中被更完整阶段/写权限覆盖的待发资源声明；已经送入 Metal 的声明保留，用独立批次编号防止旧索引影响下一批。补充真实 GPU 多次绘制、资源身份核对与编号回绕对照，并完善受窗口限制的攻击输入记录。实际游戏仍未达到稳定可玩结论，FSR3 两项尚未验证。仅发布源码与通用说明，新的本机诊断数据未公开。
> Coalesce pending resource declarations superseded by broader stage/write coverage within the same batch. Preserve already emitted Metal declarations; a separate batch serial prevents stale indices affecting later batches. Add real GPU multiple-draw, identity-contract and serial-wrap controls, plus scoped attack input records. Stable game playability remains unproven and both FSR3 features are unvalidated. Source and generic documentation only; new local diagnostics remain private.

> 描述符快照的存活过滤结果现在可跨着色器阶段和访问类型复用；读写权限用独立阶段掩码记录，编码器切换后重新声明，相关资源注册后仍强制校验。新增真实顶点/像素阶段间接原子写入和像素回读对照源码，保留堆写入、增量与注册失效回归。实际游戏收益仍需验证，尚未达到可玩结论。仅更新源码与通用说明，新的本机诊断数据未公开。
> Share immutable snapshot liveness filtering across shader stages and access types. Separate read/write stage masks preserve encoder-local declarations and registration invalidation. Add real vertex/fragment indirect atomic writes and pixel readback fixture source, retaining heap-write, delta and registry regression coverage. Actual game benefit requires validation; playability remains unproven. Source and generic documentation only; new local diagnostics remain private.

> 修正描述符集合路径误用描述符缓冲区状态的诊断检查，避免正常描述符表更新触发同步重复警告。保留描述符缓冲区路径的缺堆/越界检查及所有实际 GPU 命令。新增 UAV 描述符表 GPU 回读对照、隔离 D3D12 库选择与有界线程 CPU 计数工具。游戏性能仍未达到可玩结论；FSR3 超分及帧生成仍未验证。本次仅更新源码，未发布新的本机日志或环境数据。
> Fix descriptor-buffer-only diagnostic checks incorrectly reading inactive heap state on the descriptor-set route, preventing synchronous false-warning floods on valid table updates. Buffer-path heap/bounds validation and all actual GPU commands remain intact. Add a UAV-table GPU readback control, isolated D3D12 library selection and bounded thread CPU counters. Game playability is still unproven; FSR3 upscaling and frame generation remain unvalidated. Source only; no new local logs or environment data are published.

> 新增实验性描述符增量规则：资源身份集合不变时保留快照；小范围改动记录新增/移除身份；原生编码路径只复用已持有引用的旧资源，并保留每个编码器的阶段与写权限声明。注册状态影响表中资源时回退完整校验，弱引用避免快照历史无限保留。包含独立集合对照和真实 GPU 测试源码。游戏性能收益仍待验证，FSR3 两项仍未完成。本次只发布源码，不公开新的本机日志或运行环境证据。
> Experimental descriptor membership deltas preserve immutable snapshot identity for set-equivalent edits and record additions/removals for small updates. Native encoding reuses only retained parent resources while preserving per-encoder stage/write declarations. Registrations affecting table resources trigger full validation; weak ancestry bounds retained history. Independent set-oracle and real GPU fixture source is included. Game performance benefit remains unverified; both FSR3 features remain incomplete. This update publishes source only, without new local logs or machine evidence.

> 诊断工具补充：命中测试使用系统实际输入接收进程核对可穿透覆盖层；窗口大小请求同时记录实际大小；Wine 正常线程挂起信号原样传递。新的本机测试数据仍只保存在本机，游戏可玩性仍未通过。
> Diagnostic tooling follow-up: verify the actual accessibility input recipient when a click-through overlay exists; report actual window size alongside resize requests; pass Wine thread-suspension signals unchanged. New local test data remain local. Playability is still unverified.

> 源码工具更新：新增有限时长的 Wine 原生异常捕获；补齐原生启动器的后端配置；明确区分日志请求与实际生效、库加载与设备初始化。诊断工具不改变驱动代码或异常返回值。游戏兼容性与性能仍未解决，FSR3 超分及帧生成仍未验证。本次只发布源码，不发布新的本机诊断日志或运行环境证据。
> Source tooling update: add bounded native Wine fault capture and preserve complete backend configuration through the original native launcher. Logging requests are distinguished from active logging, and library loading from device initialization. Diagnostics do not change drivers or exception results. Game compatibility and performance remain unresolved; FSR3 upscaling and frame generation are unverified. This update publishes source only, without new local diagnostic logs or machine environment evidence.

> 2026-10-21：挥剑动作已通过游戏截图确认，但随后仍发生 4 次 GPU 超时；两段一分钟采样未保持前台，因此没有可用的稳定 FPS 结果。**仍未修好。**
> Sword input was visually verified in the actual game, but four later GPU timeouts still occurred. Both one-minute samples lost foreground, so neither provides a valid sustained FPS result. **Still unresolved.**

新增诊断 `740c588c…` 用固定 64 条 CPU 记录替代逐条 Foundation 字典分配，保留前 16 条及后 48 条，每个命令缓冲区 36,880 字节。独立 CPU 对照 10 万次记录从 385.035ms 降到 11.519ms；这只是诊断开销对照，**不是游戏提速结论**。并发读取、真实 AMD 绘制/清屏/几何阶段及内存读写、应用宝原 Wine 计算/呈现/严格缓存命中均通过。

Diagnostic `740c588c…` replaces per-event Foundation allocations with a fixed 64-event CPU history (first 16, latest 48; 36,880 bytes per command buffer). A 100,000-event CPU control improved from 385.035ms to 11.519ms; **this is diagnostic overhead, not game FPS**. Concurrent snapshots, real AMD graphics/clear/geometry/memory output and original Tencent Wine compute/presentation/strict cache-hit qualification passed.

新游戏通过原 Steam 启动并确认映射该库，但在生成图形日志前退出，原因尚未确定，未将它算成 GPU 回归成功。此前短时详细记录未覆盖晚发生的超时，具体着色器/同步根因仍未知。游戏与缓存保留，FSR3 两项未验证；此下载为可恢复研究版本，不是保证可玩的发布版。

A new original-Steam game mapped the qualified library but exited before graphics logs; cause unknown, not a game-validation success. Earlier timed work capture missed late timeouts, so the exact shader/synchronization root remains unproven. Game and caches remain intact; both FSR3 features are unvalidated. Downloads are recoverable research builds, not a guaranteed playable release.

[Controls and actual failed-game evidence](release-evidence/fixed-work-flight-20261021/)

> 2026-10-21 更新：已确认一次真实磁盘写满（最低约 139MB 空闲）。仅压缩校验过的旧研究文本日志，保留恢复元数据；游戏、存档和所有着色器缓存未删除。正常 Steam 测试现增加启动前 10GiB 空间检查及限时磁盘监测。
> Update: actual ENOSPC occurred with about 139MB free. Only old owned text research logs were losslessly compressed with decompressed SHA verification and recovery metadata. Game, saves and all shader caches remain intact. Normal-Steam tests now require 10GiB free before launch and use a bounded disk monitor.

恢复到约 19GiB 空闲后，游戏仍复现挥剑 GPU 超时，因此磁盘耗尽不是唯一原因。该次详细记录在故障前到期，未获取具体管线，不能声称已经定位或修复。下一轮只延长限时诊断覆盖，不改变 GPU 同步语义。仍不可玩，FSR3 两项未验证。

A sword-related GPU timeout still reproduced with about 19GiB free, so ENOSPC is not the sole cause. Detailed recording expired before that fault: no exact pipeline has been identified or fixed. The next run extends bounded diagnostic coverage without changing GPU synchronization semantics. Still not playable; both FSR3 features are unvalidated.

[Disk guard and failed-capture evidence](release-evidence/disk-guarded-capture-20261021/)

> 最新实际游戏结果（2026-10-21）：营地能正常显示，13,779 条计算管线全部从缓存加载/重建成功，0 创建错误；但用户挥剑后发生 **3 次原生 GPU 超时并退出**，仍不可玩。本轮为 3072×1920 输出，一分钟前台观测包含故障，期间呈现统计 8.76 FPS **不能当成稳定帧率或成功结果**。
> Latest actual game: the camp rendered correctly and all 13,779 compute archives loaded/rehydrated with zero creation errors, but a sword attack triggered **three native GPU timeouts and game exit**. **Not playable.** Output was 3072×1920; the one-minute foreground observation includes that failure. Its 8.76 FPS presentation statistic is not a sustained-performance or success claim.

第一条超时发生在计算队列等待图形队列信号；图形生产者随后也超时。现有记录不足以指认具体着色器或证明循环依赖。三个独立队列、三个独立时间线事件的正序与逆序对照共检查 8,388,608 words，0 差异，未复现实际游戏故障。

The first timeout is a compute-queue wait on the graphics producer, which also times out later. Existing evidence does not identify the exact shader or prove a dependency cycle. Independent forward/reverse three-queue, three-event controls checked 8,388,608 GPU words with zero mismatches and did not reproduce the game failure.

诊断候选 `6e7d6b81…` 只增加可短时开启的详细工作记录及管线函数名，不改变同步语义。有效标记记录到 115 个工作事件，过期标记为 0，图形 GPU 输出均正确；原应用宝 Wine 计算、呈现与严格缓存命中通过。已由原 Steam 启动新一轮准备捕获挥剑现场，标记尚未开启。缓存保留，FSR3 超分和帧生成仍未验证，**不是已修复的可玩版本**。

Diagnostic candidate `6e7d6b81…` adds bounded, armable work capture and pipeline function names, without changing synchronization semantics. Fresh/expired marker controls produced 115/0 work events with correct GPU output; original Tencent Wine compute, presentation and strict cache-hit tests passed. A new original-Steam run is warming caches for targeted attack capture; recording is currently unarmed. Caches remain intact. Both FSR3 features are unvalidated; **this is not a fixed playable release**.

[Sword-timeout, queue-control and diagnostic evidence](release-evidence/sword-timeout-20261021/)

以下为历史记录。 / Earlier measurements follow.

> 最新状态（2026-10-21）：同一轮、同一场景、726×526 输出，外部模拟器高负载下 **5.72 FPS**；有时限的减载对照测得 **12.69 FPS**，冷却后 **13.33 FPS**，均未记录 GPU 错误，**仍不可玩**。模拟器原进程已在十分钟时限内恢复，没有关闭模拟器或删除数据。
> Latest: the same game, scene and output delivered **5.72 FPS** under external simulator CPU load, **12.69 FPS** with bounded load isolation and **13.33 FPS** after cooling. No GPU failures were recorded in those controls. **Still unplayable.** The isolated simulator process was resumed at the ten-minute deadline; no simulator shutdown or data removal occurred.

候选 `b48f4735…` 增加有界注册变化记录，仅当新增对象均与描述符快照无关时复用缓存；相关注册、记录溢出、变化超出查询预算均回退完整验证。同时保留 heap 子资源必须的显式写入声明。真实 helper 的 GPU 对照输出正确：无关注册的重复查询 **131,072→4,096**；必要写入声明 **0→2**。图形切换、多堆、内存保护及几何阶段回归通过。这些是独立回归，**尚未测得新候选的游戏帧率**。原应用宝 Wine 无窗口 D3D12 计算及严格缓存命中已通过；呈现与正常 Steam 游戏验证等待本机会话解锁；游戏缓存保留，FSR3 超分和帧生成仍未验证。

Candidate `b48f4735…` adds a bounded registration log that preserves full validation for related registrations, overrun or excessive churn, while skipping provably unrelated invalidations. Heap-child writes now retain their required explicit write declarations. Exact native-helper GPU output passed: redundant lookups **131,072→4,096**, required write declarations **0→2**. Graphics transitions, multiple heaps, memory protections and geometry regressions passed. **No new game FPS result is claimed.** Original Tencent Wine headless D3D12 compute and strict cache-hit tests passed; presentation and normal Steam game tests await local unlock. Caches are retained; FSR3 upscaling and frame generation remain required and unvalidated.

[Load-isolation results](release-evidence/load-isolation-20261021/) · [New source/GPU controls, including retained before failures](release-evidence/registration-delta-20261021/)

以下为历史记录。 / Earlier measurements follow.

> 最新实测（2026-10-21）：`0da8acf5…` 实际营地 **5.72 FPS**，726×526 输出，60/60 次前台/可见，未记录 GPU 超时，**仍不可玩**。新发现：另一项 iOS 模拟器 `mediaanalysisd` 占 692–885% CPU，系统报告 CPU_Speed_Limit 36–46；接电 94W，低电量模式关闭。仅暂停本游戏的两分钟减载对照已自动恢复，尚不能分离外部负载的影响。模拟器进程未改，临时暂停等待用户确认。
> Latest actual scene for `0da8acf5…`: **5.72 FPS** at 726×526, with 60/60 foreground/visible samples and no GPU timeout files. **Still unplayable.** A separate iOS Simulator media analyzer consumes 692–885% CPU while the system reports CPU_Speed_Limit 36–46. AC adapter is 94W and Low Power Mode is off. A bounded game-only pause auto-resumed; the simulator remains untouched pending approval for a temporary load-isolation control. This is an observed confounder, not proof that it explains all low FPS. FSR3 upscaling and frame generation remain required and unvalidated.

[Measured scene and load-control evidence](release-evidence/stable-use-map-20261021/). The heap-child write-declaration ledger is saved as a compiled-only future diagnostic: it has not run during this live game or changed its backend, and is not a claimed game failure cause. The simulator-pause helper must be used only with the user's approval and restores the verified original process on timeout or interruption.

> 最新实测（2026-10-21）：上一版营地 **5.19 FPS**，60/60 次前台可见，未见 GPU 超时，仍不可玩。窗口为 726×526；更早的 3.22 FPS 使用 3072×1920 输出，因此不能把差值全归于代码优化。13,779 条计算归档全部加载并重建成功，0 创建/重建错误，缓存未清除。
> Latest actual scene: **5.19 FPS**, with 60/60 foreground/visible observations and no GPU timeout files. Still unplayable. Output was 726×526 versus 3072×1920 for the earlier 3.22 FPS run; this is not a controlled source-speedup ratio. All 13,779 compute archives loaded and rehydrated, with zero creation/rehydration errors. Caches remain preserved.

新候选 `0da8acf5…` 将 helper 的逐节点资源状态表换为平坦查询索引与分页稳定值存储，保留查询、持有引用、逐 encoder 声明、权限升级和容量上限。真实 Metal 对象地址的五轮 CPU 对照，12 组场景中位耗时均降低；扩容后值地址、重复插入状态和清空重用检查正确。实际编译的 MoltenVK helper 真实 GPU 测试验证了缺失→注册、跨 encoder 和写权限升级，另有图形、多堆、越界/空描述符及原 Wine 缓存/呈现回归通过。已通过原 Steam 启动，**游戏帧率效果待当前轮测量，FSR3 超分/帧生成仍未验证**。

The new candidate replaces node-per-resource state with a flat lookup index and stable paged values, preserving all liveness, ownership, encoder declarations, access upgrades and bounds. Twelve real-Metal-identity CPU cases improve in five-run medians, including value-address stability through growth. The exact compiled helper's GPU registration/encoder/write-upgrade controls pass, as do graphics, multiheap, robustness/null and original Tencent Wine cache/presentation. It is now in normal-Steam game validation. **No playable result or FSR3 support claim is made.** [Evidence](release-evidence/stable-use-map-20261021/).

额外混合指针哈希的对照反而更慢，未接入原生资源表，也未因此重启游戏。The suspected pointer-hash collision was disproven by real Metal identities; the slower alternative remains a saved, rejected experiment.

> 最新实机场景（2026-10-20）：绑定修复版已经通过原应用宝 Wine / Steam 进入营地。60/60 次采样确认前台且可见，原生呈现 **3.22 FPS**，本轮未见新的 GPU 超时，但仍不可玩。CPU 采样显示瓶颈集中在提交线程的资源表检查、去重和堆声明。
> Latest actual-scene measurement: the binding repair reaches camp through original Tencent Wine/Steam. All 60 observations confirm foreground visibility; native presentation is **3.22 FPS**, with no new GPU timeout files in this run. It remains unplayable. CPU submission, resource validation and heap residency bookkeeping are measured hotspots.

新候选 `57948db5…` 用可复用的开放寻址堆计数表消除每次绘制的哈希节点分配，保留逐 encoder 的所有 Metal 声明。14 组计数/阈值控制正确，五轮 CPU 对照均加快；真实 GPU 的绘制/清除、16 堆描述符和越界/空描述符回读均无差异，原 Wine 严格缓存/呈现通过。**这是局部 CPU 改善，游戏加速仍待本轮实测；FSR3 超分和帧生成仍未验证，未发布可玩承诺。**

The next candidate reuses an open-addressed heap-count scratch table, keeping all per-encoder Metal declarations. All 14 controlled CPU cases improve over five runs, and real AMD graphics/clear, multiheap descriptors, robustness/null and original Wine strict-cache/presentation regressions pass. **These are local CPU controls, not game FPS gains. Normal-Steam game validation is in progress; FSR3 upscaling and frame generation remain required and unvalidated.** [Evidence](release-evidence/heap-use-table-20261020/).

> 最新（2026-10-20）：已拿到前台失败证据，仍未达到可玩。旧 EF 候选前台/可见 60/60 次采样，首尾场景图相同，期间无新原生呈现记录；计算和图形队列均发生真实超时。错误前最后一段有效呈现约 3 FPS，该更早窗口未独立验证前台。
> Latest: not playable. The old EF candidate froze through all 60 foreground/visible samples, with identical scene captures and no new presentation records; native compute and graphics command buffers timed out. The last earlier valid presentation window was ~3 FPS, but that earlier window did not independently establish foreground visibility.

已经复现一个明确的开源层缺陷：dispatch/fill/dispatch 中填充正确，但后续计算输出全部保持哨兵值；仅原样重绑描述符或使用独立资源绑定可消除错误。采用 [上游 PR2822](https://github.com/KhronosGroup/MoltenVK/pull/2822) 的通用修复，将描述符资源使用缓存与实际 Metal argument-buffer 绑定分开处理，保留现有资源缓存。

A confirmed open-source-layer defect is repaired: helper commands overwrite Metal argument-buffer slots while the Vulkan descriptor set and resource-use cache remain unchanged. Rebinding the same descriptors fixes the old output. The adapted upstream fix restores actual bindings via the existing buffer/offset cache without clearing descriptor resource-use caching on every draw. It applies to compute and graphics, with no shader rewriting or feature-bit claims.

- 旧库计算对照：两种 fill 间隔合计 16,384 个错误输出字；原样重绑与独立绑定对照均正确。
- 修复计算：64 轮/组，327,680 个输出/填充字，0 差异。
- 旧库 draw/clear/draw 图形对照触发真实 GPU 超时；修复版 20 轮、16 次 encoder 切换、20,480 像素，0 差异。
- 越界/空描述符、几何输出与原应用宝 Wine 严格缓存/呈现回归均通过。
- New native SHA-256: `5987d724da4329f86f3f2add1a204a4d084d0c1cd80f4b1fa59328504836dc36`.

[Evidence](release-evidence/helper-binding-20261020/). The new library is deployed through the existing normal original-Steam launch path; game validation is in progress. **The isolated defect is proven; its contribution to the actual game's timeouts and sustained game performance still require real scene validation. FSR3 upscaling and frame generation remain required and unvalidated.** Historical OFF settings were not introduced as a fix. No new playable release is claimed.

另修复长时间日志到上限后不再更新的问题：保留原历史日志，并持续原子更新有时间戳的有限 current 文件。2,200 次写入/23,054 次并发读取无残缺或倒序。新增默认关闭的低开销队列失败上下文，只保存前 8 次错误的依赖快照，不开启逐绘制工作日志；关闭工作日志时也不再构造其标签。仅为诊断，不改同步值、返回码或 watchdog。The performance-regressing small-heap counter remains an archived experiment; the active mainline keeps the original heap grouping.

Separately, upstream mixed-compute-stage fence issue 2805 was investigated but **not applied**: it did not explain this observed one-encoder failing control, which passes after rebinding with unchanged barriers. Avoid combining unrelated hypotheses into the same trial.

> 新对照（2026-10-20）：仍未验收可玩，原 Steam 的现有游戏和缓存未动。原生 heap 分组改用小表内联计数、大表哈希回退；稳定源码构建、20,480 像素图形回读、16 个 heap 的计算回读、越界/空资源回归及原应用宝 Wine 严格缓存命中/呈现均通过。但五次 CPU 对照中，1–8 个 heap 较快，部分大表回退变慢，因此新候选 **仅保留研究，未部署到游戏**。锁屏状态仍存在，实际前台场景帧率与 FSR3 超分/帧生成未验证。
> New control: small heap groups avoid per-draw hash allocations, with a bounded hash fallback for larger groups. The stable-source build, real AMD GPU readbacks and original Tencent Wine cache/presentation checks pass. CPU controls improve small groups but regress some spill cases; candidate **192d7376faa4c1d61817b49d41f4a83a34c9e3bc4e2ab4a08a7a05705333c003 is experimental and NOT deployed**. The active ef9241 game run and all caches remain intact. The console is still locked; sustained foreground FPS and both FSR3 features remain unvalidated. [Evidence](release-evidence/heap-inline-20261020/).

> 验证阻碍（2026-10-20）：系统明确报告 `IOConsoleLocked=true`、`CGSSessionScreenIsLocked=true`。已停止窗口操作，保留原 Steam 启动的现有游戏和缓存，等待用户在本机解锁。锁屏期间的黑色截图、窗口缩略图与后台呈现回调不可作为游戏黑屏或实际前台 FPS 的证据。最新候选仍未验收可玩，FSR3 超分及帧生成仍未验证。
> Validation blocked: macOS reports a locked console session. Window operations stopped; the existing original-Steam game and all caches remain intact pending a local unlock. Locked/background captures and callbacks cannot establish scene rendering or foreground FPS. Playability and both FSR3 features remain unvalidated.

> 最新进展（2026-10-20 18:19 PDT）：仍未验收可玩。新候选把已验证的资源集合保留到同一命令编码结束，跨 encoder 复用过滤结果，每个 encoder 仍收到各自的 Metal 资源声明，注册变化会失效缓存。GPU 注册失效/访问升级回归、图形切换、几何、描述符、内存及原应用宝 Wine 回归均通过，游戏已经原 Steam 启动；持续帧率、实际场景及 FSR3 超分/帧生成仍未通过。
> Latest: not validated as playable. A qualified candidate reuses filtered, owned resource sets across encoders within one command encoding, preserving every encoder's Metal resource declarations and invalidating absences after registration changes. Real GPU and original Tencent Wine regressions passed; the original Steam game run is in progress. Sustained scene frame rate and FSR3 upscaling/frame generation remain unvalidated.

Candidate SHA-256: `ef9241229adbeebe95461386a2d88dd61ca8c31af5197460d02beb3987f6c67f`. [Evidence](release-evidence/cross-snapshot-20261020/). The final profile disables only the internal per-address absence hash cache after CPU controls measured it slower, while retaining snapshot reuse and all robustness/null-descriptor correctness logic. The CPU-only stale-table fixture measured ~158 ms baseline versus ~0.35 ms for cross-encoder snapshot reuse; this is **not game FPS**. Stable-source build verification is now recorded to reject source edits during compilation.

The previous run had no recorded native completion errors, but its post-load scene was not visually verified: legacy captures turned black, window-specific ScreenCaptureKit capture failed, and Win32/native activity disagreed. This is an unresolved observation gap, not proof of correct scene output or of a rendering failure.

> 最新进展（2026-10-20 17:23 PDT）：仍未达到可玩。实际营地的一分钟对照为约 1.4–2 FPS；3,337 万次注册表查询约 89% 返回不存在，资源缓存容量淘汰为 0。随后出现两次原生队列错误，超时首因尚未定位。新候选缓存注册版本限定的空结果，并复用同一 encoder 内已声明的不可变描述符快照；已通过 GPU 和原应用宝 Wine 回归，正在原 Steam 中验证游戏效果。
> Latest: not playable. The measured camp baseline delivered about 1.4–2 FPS, with 89% of 33.37 million registry lookups returning absent over one minute, and no capacity evictions. Two later native queue errors remain unresolved. A qualified candidate caches versioned absences and reuses already-declared immutable descriptor snapshots within each encoder. Normal original-Steam game validation is in progress.

Candidate SHA-256: `58dab7f8f9685323d4b4856567cac3bc83d853e812ec9620f70a45cc12e48eff`. [Evidence](release-evidence/descriptor-reuse-20261020/). Actual helper GPU tests verify absent-to-registered invalidation, write upgrades and declarations in four encoders (6 checked GPU words, zero mismatches); separate Vulkan graphics, descriptor and memory readbacks passed. A bounded CPU fixture improved from 212 ms to 17 ms with both caches, which is **not a game FPS speedup claim**. FSR3 upscaling and frame generation remain unvalidated and required.

An earlier candidate `14e35a…` failed regression because editing a header during compilation left objects with incompatible helper layouts. It was never deployed to the game. A complete rebuild from stable sources removed this fixture crash. Failed evidence is retained locally. No closed driver or game binary was modified.

> 最新核对（2026-10-20 16:38 PDT）：游戏尚不可正常游玩。此前 locn2 链接失败已用稳定且唯一的原生 mesh 入口名消除；归档管线保留大量文件映射的问题已通过命中后重建无归档管线处理。实机场景能够正确显示，但上一轮只有约 1–2 FPS，随后发生原生 GPU 超时。当前轮正在验证资源声明优化的实际生效配置与分队列计时，尚无游戏加速结论。
> Latest: not playable. Unique mesh entry names removed the observed locn2 failures, and archive-hit pipeline rehydration eliminated retained archive mappings in the measured replay. The previous correctly rendered scene delivered about 1–2 FPS and later timed out. Effective resource-declaration configuration and per-queue timing are now being measured in a new normal-Steam run; no playable result is claimed.

## 当前候选 / Current candidate

Candidate SHA-256: `512c041a3f8d3e5a89aae4d195ed4524a16846ba5ebbb97ba53ef21c0b8fa952`. Game proxy SHA-256: `47d7abc5710febf384639574793dda9827f7dc3872096d338e1ee867145957ba`. Evidence: [qualification and effective configuration](release-evidence/effective-submission-profile-20261020/).

真实 GPU 回归：20 轮 × 16 次 encoder 切换的图形测试共 20,480 像素、6 个描述符场景共 99,456 words、12 个内存场景共 9,648 结果及 192,528 witness words，均无差异。原应用宝 Wine 计算、严格缓存命中及呈现探针通过。这些测试不能替代游戏验证。

Real GPU regressions passed with zero mismatches: 20,480 pixels over repeated encoder transitions, 99,456 descriptor words, and 9,648 result plus 192,528 witness words for memory protection. Original Tencent Wine compute/cache/presentation probes passed. These are fixtures, not proof of game playability.

此前给已运行 Steam 的启动客户端设置环境变量，未证明游戏实际继承了参数。因此之前 heap 阈值与跨 encoder 缓存的游戏对照结论不成立。新代理在游戏内明确设置并读取真实解析值，确认 crossEncoderLiveCache=1、recentCacheSlots=256、heapThreshold=2。启用低开销 Metal 原生时间戳聚合，关闭完整逐 encoder 工作追踪，保留错误记录与缓存。

Earlier environment settings on a launch client did not establish what the existing Steam process passed to the game. Previous threshold/cache comparisons are therefore inconclusive. The new game-side profile records the actual parsed values and measures host precommit time, native GPU execution, and submit-to-GPU delay. All caches remain intact.

FSR3 超分与帧生成仍未验证；历史配置包含强制关闭项，当前基础帧率测量不能算 FSR3 支持。恢复功能并逐项实测是完成条件。

FSR3 upscaling and frame generation are unvalidated. Historical force-off settings are still present during this base-frame-rate diagnosis. Both features require restoration and real game validation before claiming support.

以下为保留的历史记录，不代表最新候选或活动 PID。 / The following sections are historical evidence, not the current candidate or live PID.

# 保存时的真实状态

2026-10-20，Intel / AMD Radeon Pro 5600M，macOS 26.7.1。

当前候选 MoltenVK 的 SHA-256：

`ab5a688c2df324983b61106e2af44d59190dfe7bbee9ebe98ba8a46c4e3aa5fb`

游戏加载代理：

`847a4f6f80d15985c51253da9bb3a855a27037cab883e7f173ef66577bdd50f2`

窗口修复模块：

`b1223543882b6c4e625b9c1970ed457615b3eb49d7dfc0388071a18b3820c89c`

已通过：原生跨队列 GPU 输出核对、计算和图形输出回归、原应用宝 Wine 中的计算缓存和窗口呈现探针。具体结果与精确库哈希保存在 `workspace/open-game-stack-20261015/evidence/queue-dependencies-20261020/` 和 `private-cache-wine-20261020T072513Z/run.json`。

最新游戏通过原 Steam 正常启动，PID 66635（仅为当时记录，不能以后直接拿此 PID 操作）。实际确认候选库、代理和窗口修复模块均已映射，原游戏资产写保护生效，队列族 0、2、3 已启用；用户反馈仍在编译。首批 94 个计算管线记录读取了现有归档；游戏记录没有启用严格归档命中验证，不能将 `loaded=true` 等同于强制原生编译器命中证明。

上一轮确实进入过场景，用户反馈只有几帧，并提供蓝色矩形遮挡截图。随后原生计算 / 图形队列报告 GPU timeout，游戏最终报 GameThread 等待 RenderThread 超过 120 秒并自行崩溃。仍未定位到具体致错着色器或已证实的等待环。不能把已完成 encoder 上的着色器标签当成元凶。

本次候选增加实际 Metal wait/signal 值和有界待处理队列记录；未伪造同步成功、硬件功能或修改闭源驱动。可选 render shard 缓存已经有原生探针验证，但当前游戏对照配置没有启用它，避免同时改变多个变量。初次 MSL / 管线编译仍慢，游戏 GPU 超时、蓝色遮挡和持续帧率仍需修复。

用户最新授权：修复验证后可以直接部署并重启测试，不必再次索要常规重启许可。游戏始终通过正常正版 Steam 启动，禁止直接运行游戏主程序来绕过既有启动边界。

## 后续失败核实（2026-10-20 01:00 左右，本地时间）

此前记录为“正在编译”的 PID 66635 已再次失败退出。新日志在 00:41:16 捕获计算与图形队列 GPU timeout，计算队列等待图形时间线 108032，而观测值仍为 108030；对应信号生产者仍在待完成记录中，没有记录到它自身的信号量等待。现有记录缺乏原生 enqueue/commit 顺序，因此不能据此断言已证明等待环，也没有识别出致错着色器。

补充的合法依赖批量队列探针，在单队列和三个独立队列各执行 2048 条 GPU 填充/复制链，每 16 轮才 CPU 等待和读回；每模式核对 8,388,608 words，0 差异，Metal Validation 开启。它未复现游戏故障，不能当作游戏同步正确或游戏可玩的证明。游戏依然未修好。具体 JSON 在 `evidence/queue-burst-20261020`。


## 新一轮队列修复（2026-10-20 01:48 本地）

候选 `0ea6accc79c78bec4aa2d742078385fdab3ba7e99c8f47602a05eed059fe0a07` 修复了同时存活的逻辑队列共享同一个原生 Metal 队列的问题。原生队列改为独占租用，顺序设备仍能复用已经归还的队列；设备丢失后的队列不会再出借。并增加真实设备/队列身份及 enqueue、commit、scheduled、completed 阶段记录。

双设备先等待后提交信号的实际 GPU 测试通过：32轮、262144 words，0差异；释放后的队列复用且不借用存活设备的队列。单/三队列64轮及2048轮回归、图形5120像素、向量124416words，以及原应用宝Wine计算/缓存/呈现均通过。它们不能证明游戏已经修好。

新游戏PID78427通过原Steam正常启动并核实新库、代理、窗口模块映射及原资产写保护；此PID只用于本次记录。保留全部缓存。最初十分钟无GPU超时记录，仍在图形管线编译；尚未验证正常场景与持续帧率。窗口经系统接口实际放大，手动缩放仍待核对。macOS台前调度侧栏会与Wine的前台状态产生差异，不能仅凭Win32前台标志判断用户可见。

增量补丁 `MoltenVK-native-queue-leases-after-v0.1.0.patch` 应在原累计MoltenVK补丁之后应用；当前workspace源文件已含该改动，不要再次打补丁。新二进制单独保存在additionalRuntimeArtifacts中，原v0.1.0历史二进制保持原样。公开下载版v0.1.0仍是旧基线，明确不承诺游戏可玩。


## 编译共享锁修复（2026-10-20 02:08 本地）

候选 `f3b3f775ba97ba3656aa5eb7b66a5b0f77589c43ca2fff677b9b82f3544f4ef7` 包含上述队列租用修复，另将旧式计算/图形原生归档的同步准备移到Metal设备共享锁外；归档自己的互斥锁和原生提交保护保留。真实游戏两次采样看到归档addRenderPipelineFunctions同步编译持有设备锁，其他库/函数请求在objc_sync_enter排队。

14线程并发创建图形管线并轮流实际绘制：修复前后均80场景、5120像素、0差异。测试沿用游戏replay-only模式，旧式图形归档允许内存中添加但不序列化，所以legacyArchiveBytes=0；不能把此结果写成磁盘图形缓存命中证明。约65.8ms对40.3ms的微测试受现有游戏编译争用和驱动缓存影响，不能作为游戏加速比例。

组合修复又通过双设备32轮GPU等待/读回，以及原应用宝Wine计算、严格原生计算缓存命中、窗口呈现。此前游戏PID78427在19分钟受控停止前无GPU超时记录，但仍在图形编译，没有正常场景/帧率验证。用户已授权修复验证后直接重启，本次仅结束该游戏并保留约6GB原生缓存、201MB vkd3d缓存、原Steam和Wine服务。新试验通过原Steam正常启动；游戏效果仍待实测。

源码已含队列和归档两个增量补丁，不要再对当前workspace重复应用。新增精确运行库在runtime-archive-unlock-20261020.tar.gz中，恢复工具会校验并恢复所有附加快照，旧快照保持可追溯。


新游戏PID80504的正常Steam启动与精确候选映射、原资产写保护已核实。新的两秒启动采样中，objc_sync_enter等待栈节点从上一轮样本39个降至0；采样阶段及驱动缓存状态不同，不能推算游戏帧率倍数。当前WindowServer读取到的是台前调度缩略图，原生激活未能确认展开；需要实际可见窗口/场景验证。没有将截图助手失败归咎于游戏或驱动，也没有声称正常游玩。


窗口补充：正常Win32 BringWindowToTop与SetForegroundWindow都返回成功，但WindowServer仍只提供缩略窗口，不能据此宣称用户可见或缩放问题解决。单窗口ScreenCaptureKit截取失败，未取得新游戏画面，没有以进程存活替代视觉验收。已请求用户点击台前调度缩略图后核对实际画面；当前游戏与缓存继续保留。

## GPU 超时仍未解决；可见窗口重新启动（2026-10-20 08:27 本地）

前述 PID80504 在计算归档记录累计13779条后，于09:29Z产生3条GPU超时记录并自行退出。这些是游戏实际失败证据，不能以已进入编译界面或已通过探针替代验收。图形队列中较早已提交且已调度的工作尚未完成，计算队列等待它发出的信号；未证明存在等待环，也未定位具体着色器。

新候选 `c8f98ae74867e6ef45a7cf186cd98dd3a41c4bc9b6d891487f4472d902322fe0` 增加每个命令缓冲有界的编码器/原生管线标签/栅栏记录、VkEvent观察、设备丢失标记前的快照以及原生呈现回调时间窗口。这些是诊断修改，**不是已经修好GPU超时的声明**，不会伪造同步成功或呈现时间。最多保留每个缓冲前16、后48条工作记录，并明确遗漏数量。

真实GPU回归：80次绘制5120像素、向量864场景均0差异；另外80次遮挡查询绘制核对640项查询读回，加入时间戳后80次绘制核对960项，均通过且Metal Validation开启。新增完成记录确实包含原生管线标签和遮挡栅栏等待/更新。查询测试没有复现游戏超时，不能据此排除游戏更复杂的查询或资源用法。原应用宝Wine中计算、33条严格原生计算归档命中和呈现探针也通过。

通过原Steam重新启动的PID2306已核实新候选/代理/窗口模块映射与原资产写保护。系统激活和窗口抬升成功，用户明确确认“能看到，正在加载或编译”。保留全部游戏缓存、存档和原Steam服务。新一轮仍未验收到可玩场景；不能承诺修复概率或所有DX12游戏兼容。

New candidate adds bounded encoder/pipeline/fence observations and native presentation timestamps. It passed owned real-GPU graphics, compute, occlusion and timestamp output checks, plus the original Wine cache/presentation probes. The previous game trial still timed out. A new normal-Steam trial is visible and compiling; **playability and sustained frame rate remain unverified**. No proprietary driver changes or fabricated GPU results are included. The v0.1.0 public diagnostic download remains its historical baseline.

## 补齐内部着色器缓存标识并部署（2026-10-20 08:38 本地）

新增的原Wine严格图形归档测试先确实失败：内部 `vtxCmdBlitImageLayered` 与生成的 `fragCmdBlitImage` 没有稳定函数配方，导致严格模式发生原生归档miss。失败记录保留在 `private-cache-wine-20261020T153315Z/run.json`，没有关闭严格检查来掩盖失败。

现在为MoltenVK自己的静态/生成命令着色器按实际MSL源码、入口、语言版本、数学/优化选项生成稳定标识；未知宏输入拒绝缓存。实际GPU程序和同步语义不变。新候选 `0b72f494a7fc8279261f2b62889e3a5b7581ba4bb6a4d32dc8c11417b499842e` 在原Wine跨进程呈现测试中5条图形管线全部严格命中，计算33条严格命中；12项原生冷/热、混合变体、类型根、特化布局等价、损坏或错误归档回退测试通过，实际输出0差异。

按照用户已给出的修复后直接重启授权，仅结束PID2306，保留全部缓存、原Steam和Wine服务。PID3767经原Steam正常启动，新库与原资产写保护核实，窗口抬升成功且系统读到640×428可见游戏窗口。本轮开启有界原生图形分片；游戏不要求强制命中，缺失或错误归档继续真实编译，保留已有归档及已验证的拒绝名单。

首批实际游戏164条图形归档记录中，134条发布新分片、10条严格原生命中、0条管线创建失败，约10.7MB归档落盘。这个结果证明缓存路径在游戏中运行，不是游戏已经可玩或GPU超时修好的证明。当前尚未核实正常场景和持续帧率。公开v0.1.0诊断下载保持旧基线，新精确运行库另存 `runtime-support-cache-20261020.tar.gz`。

The original Wine strict graphics-cache test exposed missing identities for internal blit shaders. Source/entry/compiler-option recipes now cover these support functions; all five presentation pipelines strictly hit native archives across processes with correct GPU output. Twelve native cache/variant/fallback cases also passed. The normal Steam game trial now writes bounded render shards and reports actual strict hits. **Scene correctness, GPU timeout resolution and sustained playability remain unverified.**

## 本轮编译核对与诊断修复（2026-10-20 09:09 本地）

保持同一PID3767和全部缓存，未重启。记录核对结果：10651条顶点/片元图形管线、13779条有归档记录的计算管线均创建成功；图形严格原生命中4137次，5803个唯一引用分片全部落盘，共693331632字节，没有缺失文件。并未逐个重新加载所有分片，不能据此声称每个文件都重新通过了驱动验证。

中间仍存在50次mesh接口链接失败（47次locn2、3次locn0）。通过三阶段实际函数对象identity逐项匹配，50次都对应真实成功的重编译，未发现未恢复的链接失败。不能把它写成“全程零错误”。抽取一例现有生成源码，6组数学/不变性选项独立链接均成功；这不是原运行时错误的复现，也不是GPU执行正确性的证明。初始失败根因仍未确定，未根据猜测改着色器逻辑。

新发现并修复了精简日志模式遗漏present-progress记录的问题；补充实际库输入源码SHA256与编译选项关联到函数对象，供下一次真正失败时比较来源。新候选 `e107d5153b55ad500fba24499f6d5d8e529462d9c28be1f08313bb91338a7610` **仅隔离验证，未部署到当前游戏**。80次真实GPU绘制0差异，4条函数来源的SHA256均与实际库输入一致；原Wine计算、33条严格计算归档命中、5条严格图形归档命中和呈现通过。replay-only模式下确实产生2条呈现记录，但本次探针的原生呈现时间均为0，所以没有虚构FPS。

最新线程采样已不在原生编译调用，正在编码图形/计算命令；游戏实际菜单/场景状态仍待用户反馈。单窗口截图失败，不把它推断成游戏黑屏或驱动失败。没有将“管线创建成功”当作可玩验收。

Compilation audit found no unrecovered pipeline-creation failure in the observed records, but 50 initial mesh-link errors were recovered and remain disclosed. Six isolated option combinations linked the extracted recipe successfully, so the initial runtime error was not reproduced. A prospective, GPU-qualified diagnostic candidate records actual compiler provenance and fixes presentation tracing in replay-only mode; it is **not deployed**. Current game and caches remain intact. Sustained scene correctness and performance are unverified.


## 首次链接仍失败：保留失败对照（2026-10-20 09:41 本地）

用户对旧 PID3767 的实际反馈是“进去了，可以玩了，但是卡的飞起”，随后授权重启验证并要求编译无错误。这只证明曾进入可操作场景，**不代表已经达到可玩帧率**。

新开关只作用于来源可追溯的 AMD geometry object/mesh/fragment 链：每条管线重建原生库和函数，原样传递 Vulkan 特化值；另设保守数学选项对照。直接原生库输入不改；带 FAIL_ON_PIPELINE_COMPILE_REQUIRED 的请求不偷做编译。默认关闭这些试验开关，失败重放也在本次游戏试验中关闭，避免把恢复成功写成初次零错误。未修改闭源驱动、游戏资产或现有应用宝引擎。

真实 GPU 回归：普通 geometry 与特化值变体各 8 个并发请求、512 像素、0 差异；检查实际函数来源及数学选项。原应用宝 Wine 的计算、33 条严格计算归档命中、5 条严格图形归档命中及呈现也通过。这些微测试未覆盖完整游戏，不能据此保证游戏通过。

实机失败均保留：

- 原数学的独立函数候选 `e895710029a1e0507eeb2eddd72520b9074d3d348840e70de299ce876a0df0af`：PID13176，4 次 mesh 链接失败后退出。
- 保守数学候选 `b9ceea9fa85b2bc033f6f3046fbf46c517d691fa818fa3c50ccaeadebc787699`：PID14258，2 次相同链接错误后退出。
- 同一候选、游戏代理内明确设置串行 mesh 链接：PID15420，仍 2 次相同错误后退出。代理设置值可追溯，但本轮未逐次记录 gate 获取过程。

错误为 `fragment input user(locn2) was not found in vertex shader outputs`。对应 mesh 源码实际声明并写入 locn2；错误前后显示 Out of video memory，**没有证明物理显存耗尽**。不能以降低画质代替修复此链接错误。原 Steam 和 Wine 服务继续保留，所有缓存均保留；当前没有游戏进程运行，也没有重复启动相同失败配置。

两份实际失败源码各做 24 组数学/三阶段 invariance 对照，全部链接成功；新一份进一步做 32 次 mesh-only、三种各 128 次混合/门控/同步链接，也未复现失败。它们是有边界的编译/链接控制，不执行游戏 GPU 着色器，描述符未完全覆盖实机，不能声称已复现或修复根因。下一步需要缩小真实运行时与隔离控制的差异，而非继续按猜测重启。

这些源码、测试和精确候选运行库已存入附加快照 `runtime-first-pass-controls-20261020.tar.gz`；它们是**失败试验及研究恢复材料**，不是推荐给用户的可玩版本。游戏派生源码、SPIR-V、原始转储和用户截图未发布。历史下载版 v0.1.0 保持诊断基线。

The user confirmed the previous run entered a controllable scene with unusably low performance. New fresh-function and conservative-math controls passed owned GPU readback tests, but **all three normal-Steam trials failed initial mesh linkage** (4, 2, and 2 errors). The last proxy explicitly enables mesh-link serialization; this did not eliminate the failure. The generic out-of-video-memory dialog does not establish physical VRAM exhaustion. Exact failed source/options link successfully in isolated controls, so the runtime cause remains unproven. Failed candidates and tests are preserved for recovery, not promoted as a playable release. Caches, saves, original Steam and the YYB engine are preserved. No game is currently running.


## 同步 API 对照失败，补齐初始化边界证据（2026-10-20 10:13 本地）

没有根据猜测删除缓存、改游戏着色器逻辑或修改闭源驱动。隔离对照继续未复现本轮错误：历史 35 条并发序列全部链接；加入本轮完整来源后，36 条同步/异步库与门控对照均链接；另在 128 次混合链接中查询实际 functionConstantsDictionary，三个阶段均为 0 常量且全部链接。**这些阴性结果不证明根因已修复**，因此没有基于常量查询猜测去跳过特化处理。

新增默认关闭的两个 API 对照：`MVK_AMD_SYNC_MESH_LIBRARIES` 仅作用于已有保守 AMD geometry 链，`MVK_AMD_SYNC_MESH_PIPELINES` 仅切换 AMD mesh 管线的公开同步创建 API。参数、完整描述符、特化值、原生返回结果和原有超时/延迟销毁契约保留；阻塞驱动调用不占用设备共享监视锁。编译失败重放继续关闭，不把重试恢复当作初次成功。

候选 `fa163dc9fc8216d1e9bce6e7a1fb69531447ec2cfec79829e5646e9b16db7a61`（仅同步库）：普通几何和特化测试各 8 次绘制、512 像素、0 差异；实际来源确认 24 个函数走同步库创建，Metal Validation 开启；原 Wine 计算/严格缓存/呈现通过。实机 PID18527 仍出现 2 次相同 locn2 链接错误并退出，**试验失败**。

候选 `5361b48e6dc645d71ae4977c6629a7e74ff7dc4736d2b0eb2a9df569bd3e2f68`（同步库与管线）：两组 GPU 输出各 512 像素 0 差异，逐项确认各 8 条实际同步 mesh 链接，原 Wine 回归通过。首次实机 PID19392 在着色器记录产生前无提示退出，用户确认不是手动关闭；Steam 记录退出码 0x80000101，具体退出点未确定，不能归因为 mesh 编译、Wine 断言或 DRM。

为定位该早退，新增编译期选择的自建代理诊断：只包装 Vulkan 实例、物理设备枚举与设备创建边界，原样转发全部参数及实际返回值。不读取凭据，不改能力位。新代理在原 Wine 的实际 GPU 读回、33 条严格计算命中、5 条严格图形命中和呈现均通过，并核对 16 条初始化返回为真实 VK_SUCCESS。

同一候选带边界日志经原 Steam 启动 PID21119，实际映射与原资产写保护核实：2 次设备创建都返回 VK_SUCCESS，随后仍有 2 次 locn2 链接失败，错误记录明确显示三阶段库创建与管线链接均为同步。用户再次提供显存不足弹窗。**同步/异步 API 选择不是充分修复条件；没有达到编译无错误，更没有通过场景帧率验收。**

系统盘检查仅约 5.3 GiB 可用、物理内存聚合空闲约 76%；这不能代替独立显存预算测量，也未证明磁盘或物理显存耗尽导致本次链接错误。未删除用户数据、缓存或原始失败材料。后续应找到运行时函数生成与成功完整源码重建之间可复现的差异，再更改行为；不继续相同配置反复启动。

源码与精确失败试验运行库保存到 `runtime-sync-mesh-api-controls-20261020.tar.gz`。新代理宏需使用已固定 Vulkan-Headers include；默认代理行为不启用边界包装。两个 API 对照开关默认关闭。实验二进制不是新可玩发布，v0.1.0 历史下载基线没有被替换。

The synchronous-library candidate passed both owned GPU output tests and original-Wine strict cache/presentation regressions, but its game trial still failed twice. The synchronous-library-plus-pipeline candidate also passed real GPU output and exact API-provenance checks. One game trial exited before shader tracing; a separately qualified, argument-preserving startup-boundary proxy then established that native instance/device creation succeeded before the same two mesh linkage errors. The user again observed the out-of-video-memory dialog. **Neither API selection nor these microtests fixes or validates the game.** Constant-reflection and mixed-link controls did not reproduce the runtime fault, so no speculative specialization bypass was introduced. Source, exact binaries and failures remain recoverable; caches, saves, original Wine/Steam and proprietary drivers are preserved.
