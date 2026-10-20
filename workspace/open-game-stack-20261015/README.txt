《剑星》开源链路：AMD 原生保护与正常 Steam 验证
================================================

当前状态
--------
已复用 fxgl/steamac 的试玩版相关公开补丁，在独立目录为 Intel/AMD 构建
MoltenVK/SPIRV-Cross；新增的常量缓冲区和设备地址表保护已通过真实 AMD GPU。
源码构建的 vkd3d-proton 已通过 Windows 复制、DXIL 计算、DXBC 绘制和 DXIL
窗口呈现的实际输出核对。通过正常 Steam 启动正式版的流程已经开始；独立
Steam 完成官方客户端更新后显示登录窗口，正在等待用户自行登录。
正式版尚未启动，黑屏、性能、实际最低 feature level 和稀疏资源调用仍未知。

这不是完整 DX12/R2 实现，也不是游戏已可玩的结论。公开试玩版先例发生于
Apple Silicon，不能算作本机 AMD 正式版通过。未因通用 sparse/FL12_0 缺口
停工；只有正式版实际依赖才决定下一项实现。

源码和边界
----------
公开先例和70个补丁：相邻 stellar-sparse-audit-20261015，steamac 固定提交
6ef3992d869e41291bb2841bef2e71ae318d2a02。
原生库以相邻 robustness2-reference-20261015 的已验证参考实现为基线：
utmapp/MoltenVK 05604465d691118cfd20f53a48ecf1aad9c12f93
utmapp/SPIRV-Cross 939b40b33a44443c404c4078823c406e3c94866f。
本轮原生改动补丁及回放检查：evidence/native-byte-guards-from-reference.patch、
evidence/new-native-patch-replay.json，四个最终文件逐字匹配。
原始测试着色器与驱动实际输入关联：evidence/original-shader-correlation.json。

D3D12 核心来自 HansKristian-Work/vkd3d-proton 固定提交
212991fc2c266bc0d59f4c4ce8f80f7126508d71，子模块固定版本见 evidence 下载
记录及源码目录。官方 llvm-mingw 20261006 工具链归档 SHA256 对照 GitHub
发布资产 digest 验证；没有系统安装。两处标准头文件兼容修复另存补丁。
DXGI 暂复用已有 macOS DXVK1.10.3 提供者，不能声称整个栈都由本轮源码构建。

AMD 的 Vulkan Robustness2 三个位仍为000，不伪报功能或 feature level。
私有编译选项启用实际软件保护；vkd3d 新增明确标注的研究子集入口，在真实
AMD5600M/MoltenVK上允许使用这一私有约定，Vulkan 设备请求仍不启用不存在的
R2位。运行器要求同一个库哈希具有七组 GPU 成功证据，防止把 stock 未保护
MoltenVK 与放宽入口混用。这仍是私有实验语义，不是标准 nullDescriptor
扩展启用或完整 R2 合规。未完成的静态聚合/窄位宽等形式会拒绝编译。

本轮具体改动
------------
1. 在原生 SPIRV-Cross 编译路径追踪静态 UBO/SSBO 成员、固定数组和矩阵的
   实际布局及描述符字节范围，按32/64位分量检查加载和存储。
2. 行主/列主矩阵按真实 stride 访问；uint3 存储不覆盖 padding。原子指针
   沿用既有原子操作保护入口，补入精确字节边界。
3. 逻辑缓冲区中存储的物理地址表按8字节保护读取，失败得到零地址；之后的
   物理地址仍遵守调用方管理的 Vulkan BDA 语义，不保证任意无效物理地址。
4. 区分根描述符数组和缓冲区内部地址数组，修复两者混淆造成的 MSL 错误。
5. 编译器修订进入 pipeline cache UUID，避免重用旧错误 MSL。
6. vkd3d 增加实际 minimum_feature_level 和最多64次/接口的 reserved/tiling
   调用记录；没有实现虚假的稀疏成功返回。

失败保留
--------
amd-static-cbv-initial：缓冲区值被误当成地址，MSL 编译失败，已修正。
amd-bda-byte-guards-regression：此前未支持地址表指针加载，明确拒绝。
amd-bda-pointer-table-fix：内部地址数组被误当成描述符数组，MSL 编译失败。
以上日志未删除；目录名不能代替检查 run.json/output.json 的实际结果。

最终相同库的 GPU 检查
--------------------
精确 SHA256 和每组证据在 evidence/verification-summary.json。
AMD Radeon Pro5600M，Metal API Validation 开启，GPU 子进程无 Python 转换。
* 静态 CBV/SSBO：1100场景、299200个结果及保护区word、0差异。
* 已有内存/实际空缓冲区与图像/并发原子：12场景、202176word、0差异。
* runtime uint2/3/4 边界和标量分量：864次dispatch、124416word、0差异。
* 公开聚合/矩阵/数组/读改写/指针复制：6个shader全部结果核对通过。
* 顶点与片元实际读写/顶点输入：80次draw、5120像素及保护区、0差异。
* BDA/逻辑地址表：6场景、100248word、0差异；不访问无效物理地址。
* 非均匀可变描述符数组：6场景、99456word、0差异。描述符索引均位于
  已分配范围；测试的是描述符内部越界、空值、读写、长度和原子操作。
原型内部计数器不适用于本分支，未冒称其证据。保留非Apple完整robustness
警告；没有完整 CTS、各种图像形式或大规模并发 UAB 的合规保证。

Windows 调用链检查
------------------
独立 stock Wine11.16 / prefix-open-dx12，源码构建的 D3D12/D3D12Core。
windows-device-first：真实 AMD、报告FL11_0/SM6.0，复制及增强屏障读回通过。
windows-compute-first：真实 DXIL、根常量/根UAV设备地址、1024word全匹配。
windows-graphics-loaded-library-check：真实 D3DCompile SM5 DXBC、4096像素全匹配。
windows-present-explicit-loader：原始 DXIL 顶点/片元、标准HWND、4096像素
全匹配、DXGI Present成功、呈现后fence达到2。实际加载库路径已核对。
未截图验证合成器最后显示内容，不把 Present 返回成功当成游戏画面通过。
图形旧探针输出中的“classification simulated”是原测试的固定说明文本；
本轮运行器没有使用GPU分类代理或feature-level覆盖。

正式版流程及下一步
------------------
launch_steam_trial.py 只提供正常 Steam -applaunch 3489700，没有直接游戏模式。
重用研究目录 SteamClient 和 stellar-overlay，游戏大文件指向原安装位置。
只给研究overlay加入三个后端DLL；原游戏资产只读，无第二份大型游戏下载。
保护同时禁止写入应用宝原引擎/前缀以及公共links目录；未修改这些环境。
独立 Steam 本次按官方流程更新约110MiB客户端，并显示登录窗口。没有读取
凭据/令牌/二维码，也没有伪造安装状态、跳过许可或前置安装。
当前试验路径见 evidence/current-steam-trial.json；登录窗口分类证据在其
window-metadata-after-update.log，正式版启动仍待用户登录。

用户登录后沿用当前实例，先确认Steam正常启动正式版；如果待启动请求没有
保留，只通过同前缀 Steam 正常发送 -applaunch，禁止直接执行Shipping.exe。
读取实际 API/编译错误，再决定游戏所需修补；不盲目重启，不恢复旧CLR或
D3DMetal环境工程。原 heartbeat 仍暂停，不自动恢复旧工作流。
