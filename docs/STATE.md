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
