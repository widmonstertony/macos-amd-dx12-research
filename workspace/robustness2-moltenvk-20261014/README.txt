隔离 MoltenVK Robustness2 接入验证（2026-10-14）
================================================

本轮完成了什么
--------------
保护已接入从固定源码独立编译的 MoltenVK，不再由功能测试程序预先转换
着色器、填保护信息或替换空资源。测试提交原始 SPIR-V 和普通描述符更新；
驱动内部在创建计算管线时转换，在提交前读取实际描述符生成范围信息。

实测设备是 AMD Radeon Pro 5600M。最终 8 组 GPU 功能测试包含 124 次场景执行，
共检查 1,044,992 个结果/保护区的 32 位数值，零差异。另有 3 项驱动层拒绝检查。
这些不是 Vulkan CTS 测试数量，也不是游戏兼容数量。

所有功能测试都启用了 Metal API Validation，最终运行没有验证诊断。
每个功能测试进程还回读驱动内部填有非零数据的空缓冲区/纹理替身，均未被改写。
原有 robustBufferAccess2 / robustImageAccess2 / nullDescriptor 三个功能位仍为 false。

没有启动游戏、Steam 或 Wine，没有修改应用宝、系统 ICD 配置或 Apple 闭源文件。
只通过测试子进程的 ICD 路径加载研究目录内的新库，没有安装/替换系统图形库。

真实接入位置
------------
1. MVKComputePipeline 创建时：读取原始 shader module，按真实 pipeline layout
   提供的描述符上限转换 SPIR-V；无法处理的输入返回错误，没有未保护回退。
2. 隐藏的保护信息使用私有 Metal buffer 槽，不占用应用的 Vulkan descriptor
   binding。转换配置/管线缓存包含这个真实的资源映射。
3. MVKCommandEncoder 提交前：直接读取 MoltenVK 的 CPU 描述符记录，包括复制、
   更新后的状态及实际 variableDescriptorCount；由命令缓冲区池保存每次提交的
   GPU 信息快照，完成后才回收。没有使用不匹配的 Metal setBytes 绑定来绕过检查。
4. 描述符 GPU 编码时：空缓冲区/纹理绑定驱动分配的非零替身；CPU 记录仍保留
   空状态。读操作须返回零，写入/原子操作须被保护。复制路径也保留替身。
5. 研究模式明确拒绝图形管线，避免计算路径之外悄悄绕过保护。

新增并在真实 GPU 上验证的关键缺口
--------------------------------
* 动态 SSBO 和动态 UBO：静态 offset + 动态 offset 正确选数据；保护仍按
  描述符 range，而不是底层 allocation 大小。UBO 向量跨边界时保留有效分量。
* range 从 20 字节更新到 4 字节，以及 VK_WHOLE_SIZE 的实际范围解析。
* 描述符更新和 vkCopyDescriptorSet 后的有效/空状态、范围与数据一致。
* 管线缓存序列化、重新载入并实际命中后，保护仍正常工作。
* 固定及 runtime 描述符数组；上限 3、实际分配 1/2/3 项分别测试，未分配项
  不会错误地被当作已绑定资源。这是此实现提供的额外数组索引保护，不能把所有
  超出描述符数组的行为都说成 Robustness2 标准要求。
* atomicExchange、CompareExchange、Min/Max、And/Or/Xor 的有效、越界、空资源
  输出及内存结果；另保留 atomicAdd 的 1,024 线程并发验证。
* 原有 32/64 位整数数据、部分越界向量、负/大索引、2D storage image 和
  显式 LOD 空纹理采样，均改由驱动内部转换后再次验证。

重要范围：仍是研究构建
----------------------
这还不是完整的 VK_EXT_robustness2 实现，也没有对 Vulkan 应用宣称支持它。
测试的空句柄写入通过私有 MVK_R2_RESEARCH 模式使用实验语义；因为标准功能位
尚未开放，这不构成按标准 feature 开启 nullDescriptor 的 Vulkan 合规证明。
没有运行 Khronos Vulkan validation layer 或 CTS。Metal API 验证开启不等于 CTS。

转换器目前是驱动编译阶段调用的 Python + SPIRV-Tools 开源工具链，不是已移植
到 SPIRV-Cross 内部的原生 C++ 编译 pass。普通计算管线缓存虽能命中，前置转换
目前仍会执行；其启动成本、保护指令成本和大规模着色器兼容性尚未做性能验证。
测试程序本身不会调用转换器或携带预转换的功能测试着色器。

当前只支持已测的计算路径、Metal argument buffers 模式和有限资源形式。
设备地址/物理指针、矩阵、图形阶段、完整纹理形态（mip/array/3D/cube/MSAA/
depth/texel-buffer 等）、隐式导数采样、64 位原子、descriptor-buffer、并发
update-after-bind 等仍未覆盖，不能开放完整扩展。标准功能位保持 false，
也意味着 vkd3d-proton 的完整功能检查目前仍不能因此通过。

本轮未遇到必须修改闭源组件或硬件无法执行的阻碍。这只适用于已实现/实测的
这部分；不代表其他 D3D12 缺口都是时间问题，更不代表《剑星》黑屏已修复。

证据与源码
----------
evidence/final-driver/suite.json：最终 GPU 结果和拒绝检查。
evidence/final-driver/provenance.json：源码、库、原始输入/转换输出的哈希。
  对照每个驱动编译任务的 original.spv 与测试提交的原始文件，哈希均一致。
evidence/moltenvk-r2.patch：相对固定上游源码的完整补丁，含新增驱动文件。
  补丁已在全新解包的上游树重放，与编译树逐文件对比完全一致。
evidence/baseline-controls/：未修改源码构建、修改版关闭研究模式两组对照均通过。
runtime/pipeline-*：每个驱动内部编译任务的原始 SPIR-V、转换结果、信息表及日志。
runtime/msl-dumps/：实际经过该 MoltenVK 转换的 SPIR-V/MSL。

早期失败全部保留：资源基类型映射错误、Metal setBytes 与 shader 接口访问
属性不匹配、普通 C++ 编译错误。它们通过开源源码修改修复，最终运行没有关闭
Metal API 验证来回避问题。未修改 Apple 编译器或 AMD 驱动二进制。

固定版本与复现
--------------
MoltenVK 1.4.2: db66022459ffb663aa2b50f6b018bc2e124f5edf
SPIRV-Cross:    6c09849fe88c48eaed08413aa022aaa136a3a057
其他依赖使用 MoltenVK 的 ExternalRevisions 固定版本，全部放在 vendor/cache。
隔离库为 build/MoltenVK/libMoltenVK.1.4.2.dylib（x86_64）。

  python3 build_isolated.py
    仅重建源码和无窗口测试程序；不执行 GPU，不安装。
  python3 run_suite.py --run --label NEW_UNIQUE_LABEL
    显式运行隔离 GPU 测试；必须能够访问宿主机 GPU，失败即停，证据不覆盖。

构建依赖当前机器已有的 Python、CMake、Apple Command Line Tools、Vulkan
headers/loader、glslc 与 SPIRV-Tools。固定依赖首次配置需要公开源码下载；后续
使用研究目录缓存。部分基础测试输入来自相邻 robustness2-amd-20261014 目录。
运行变量仅传给子进程，没有修改用户启动文件或系统环境。

下一步应继续隔离源码工作：将前置转换移入原生编译路径/建立版本化转换缓存，
扩展资源和着色器阶段覆盖并增加相应符合性测试，再评估可开放哪些功能位。
当前结果不提供游戏启动或部署的依据。
