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
