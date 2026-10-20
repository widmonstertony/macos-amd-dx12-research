原生 Robustness2 转换、设备地址与图形阶段（隔离研究构建）
======================================================

本轮结果
--------
Python 转换已从驱动运行时移除。现在是 MoltenVK 进程内的 C++ 转换器，直接调用
SPIRV-Tools 的内存接口完成反汇编、转换、汇编与验证，不启动 Python 或工具进程，
不使用临时文件往返。内部保留文本中间表示，尚未做大规模编译性能优化。
有界转换缓存使用完整原始代码和布局计数作为键；GPU 运行实际观察到了缓存命中。

已在 AMD Radeon Pro 5600M 上完成：
* 新增设备地址：6 个场景，真实地址读写、整数地址运算、并发 atomicAdd、指针表
  间接访问；指针表自身的描述符越界/空资源仍受保护。
* 新增顶点/片元：80 次真实绘制，包含真实顶点输入缓冲区，核对 5,120 个像素，
  同时检查两个阶段的有效、越界、空描述符读写，以及范围外的非零哨兵。
* 上一轮 124 个场景在原生版上全部回归通过，包含 UBO/SSBO、纹理、动态偏移、
  描述符更新/复制、实际变量数组分配数以及序列化管线缓存恢复。

合计 210 次功能场景执行、1,170,840 个结果/保护区 32 位数值检查，零差异。
像素检查已包含在上述数值统计中，不能重复相加。这些不是 CTS 测试或游戏数量。
所有 GPU 子进程均启用 Metal API Validation，并将 PATH 置为 /nonexistent；
最终日志没有 Metal 验证错误。驱动内部非零空资源替身均未被改写。
原生库未导入 NSTask、Python C API 或所检查的外部进程启动接口。

设备地址的保护边界
------------------
设备地址是原始 GPU 指针，不拥有普通 descriptor offset/range 的边界信息。
本轮恢复了合法 PhysicalStorageBuffer 访问与受保护逻辑描述符的共存；没有把
原始指针访问冒充成 Robustness2 已提供越界保护。

测试没有向 GPU 提交非法物理地址/空物理指针。设备地址有效、对齐及访问范围仍由
调用方负责。逻辑指针表越界读返回零指针后，测试着色器先检查零值再访问物理内存。
这验证的是受保护的逻辑表和合法 BDA 组合，不能说明任意坏指针已安全。

Khronos 官方示例明确说明 BDA 不享有普通 SSBO 的 robustness 保证：
https://docs.vulkan.org/samples/latest/samples/extensions/buffer_device_address/README.html

实现位置
--------
src/R2Native.cpp / R2Native.h：进程内 C++ 转换器，输入、输出均经内存校验。
src/MVKR2.mm：原生转换缓存、实际描述符元数据、计算和顶点/片元阶段的提交绑定。
vendor/.../MVKPipeline.mm：计算管线及顶点/片元编译入口接入；隐藏 Metal 槽按
  图形阶段及顶点输入占用计算，检查冲突后才使用。
vendor/.../MVKCommandEncoderState.mm：计算提交和绘制前绑定本次的保护信息快照。
原有 buffer-device-address 资源登记/Metal residency 路径继续由 MoltenVK 使用。

这仍不是完整扩展
----------------
robustBufferAccess2 / robustImageAccess2 / nullDescriptor 功能位仍为 false。
空句柄测试使用私有 MVK_R2_RESEARCH 实验语义，不能当作标准扩展合规证明。
未运行 Vulkan CTS 或 Khronos Vulkan validation layer；Metal 验证通过不等于 CTS。

本轮新验证图形阶段是 vertex/fragment，采用单采样 8x8 RGBA8 离屏渲染及整数
storage-buffer 读写。设备地址在计算路径验证；没有验证 BDA 与所有图形形式组合。
细分、几何、网格、完整 image/mip/array/depth/MSAA/texel-buffer、矩阵布局、
物理 OpPtrAccessChain、8/16 位内存操作、64 位原子、descriptor-buffer 和并发
update-after-bind 等仍未覆盖。遇到不支持的相关输入继续拒绝，不开放完整功能位。
没有验证窗口呈现、游戏、帧率或广泛 shader corpus，不能据此宣布《剑星》兼容。

已覆盖部分没有碰到必须改闭源组件或硬件无法执行的障碍。未修改 Apple 编译器、
AMD 驱动、系统 ICD 或应用宝；未启动游戏、Steam 或 Wine。所有构建在独立目录，
上一轮源树和证据仍保留。

证据
----
evidence/first-native-gpu/：新的 BDA 和顶点/片元 GPU 原始输出。
evidence/native-regression/：此前 124 场景的原生版回归输出。
evidence/native-boundaries.json：原生转换器的预期接受/拒绝结果。
runtime/msl/：MoltenVK 实际编译的转换后 SPIR-V 和 Metal 源码。
evidence/moltenvk-native.patch：相对固定上游源码的完整补丁。
evidence/provenance.json：源码、库、原始输入和运行时转换结果哈希与补丁重放检查。

复现
----
  python3 build_native.py
    只负责编排原生构建；不运行 GPU、不安装。
  python3 run_native.py --run --label UNIQUE_LABEL
    运行新的 BDA / 图形验证，证据目录已存在则拒绝覆盖。
  python3 run_native.py --run --regression --label ANOTHER_UNIQUE_LABEL
    回归上一轮功能。依赖相邻两轮研究目录中的固定测试程序与原始着色器。

上面 Python 脚本仅用于构建/测试编排，不参与 GPU 进程中的着色器转换。
运行时新增依赖是已有的原生 libSPIRV-Tools-shared.dylib，不是 Python 运行时。
MoltenVK 固定 db66022459ffb663aa2b50f6b018bc2e124f5edf；SPIRV-Cross 固定
6c09849fe88c48eaed08413aa022aaa136a3a057；库为 x86_64，仅从研究目录加载。
