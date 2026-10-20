复用公开原生实现并修复 AMD 向量边界
==================================

为什么继续
----------
上一轮把通用完整FL12_0的稀疏内存缺口当成了游戏研究停止条件，范围过宽。
本轮找到 fxgl/steamac 自身公开记录：Stellar Blade Demo 在其改过的MoltenVK路径
实际渲染，报告M1Max约18FPS；同一项目明确记载MoltenVK只有FL11_0、SM6_0。
其源代码还保留直接以Stellar Blade为例的描述符池大小和百万项数组编译内存修复。
详见相邻 ../stellar-sparse-audit-20261015/assessment.json 与固定原始源码。

这不能证明用户正式版全部场景都不调用reserved/tile mapping，也不是本机AMD游戏
验证。本机旧Saved/Logs为空；原OptiScaler日志没有所需的调用追踪。故实际最低
设备创建级别、全流程稀疏调用依赖仍未知。当前不能把它列为已确认必需的阻挡项；
先不投入整套稀疏软件模拟，不伪报FL12_0，不以此反复启动游戏。

公开源码基线
------------
steamac 6ef3992d869e41291bb2841bef2e71ae318d2a02，70个原始补丁，保存在审计目录。
utmapp/MoltenVK 05604465d691118cfd20f53a48ecf1aad9c12f93
utmapp/SPIRV-Cross 939b40b33a44443c404c4078823c406e3c94866f
Vulkan-Headers 6aefb8eb95c8e170d0805fd0f2d02832ec1e099a
cereal a56bad8bbb770ee266e930c95d37fff2a5be7fea，复用此前固定同版本源码副本。
源码归档哈希在 evidence/sources.json。所有库只在本目录生成/加载，无安装。
没有运行第三方安装/VM/系统修改脚本；只审阅后应用公开源码补丁并使用CMake。
CPM离线本地依赖；私有Metal API关闭；x86_64。先前原型和源树均未修改。

AMD 实验入口
------------
该公开分支原本只向Apple GPU宣告R2三位，AMD仍报告000，本轮保持不变。
私有 MVK_AMD_REFERENCE_RBA2 / RIA2 / NULL 仅选择真实的进程内MSL编译保护路径，
不修改Vulkan功能查询，不请求不存在的R2扩展设备功能。测试空句柄依然是私有
实验语义，不能说成标准Vulkan调用已合规。这不是把三个功能位改true的设备放行。
运行时没有Python/SPIRV-Tools文本转换，不为游戏运行而启动外部着色器转换进程。

发现及修改
----------
直接使用公开原生保护实现时，此前12场景比较出现4处差异：描述符范围20字节，
第二个uint4只有一个有效分量，原生实现按整个16字节向量判定而丢失该分量。
首次完整网格又发现标量分量指针没有附加字节边界；随后三分量向量写入仍改变
padding。分别修复为：
* 记录runtime vector array的描述符相对剩余字节、stride及分量宽度。
* 最后不完整向量按分量检查读写，完整结构/矩阵路径保持原生实现。
* 对MSL向量分量指针补回访问链最终的标量分量检查。
* 用显式标量内存指针存储，避免三分量向量赋值影响第四个padding字。
改动在SPIRV-Cross原生编译路径；原始SPIR-V输入保持不变，没有修改游戏着色器包。

失败日志全部保留
----------------
amd-comparison-first：4处差异。
amd-vector-tail-grid：89处差异（第一次向量修复尚未完成分量指针）。
amd-vector-component-final：29处差异（名称中的final只是当时标签，结果仍FAIL）。
不能根据退出0或目录名字认定通过，应检查各result/output.json。

最终同一库的真实 GPU 验证
-----------------------
evidence/amd-vector-scalar-store-final：
  uint2/uint3/uint4，18种range、4个index、4种整向量/单分量读写。
  864次单线程GPU dispatch，124416个结果及完整输入/输出保护区word，0差异。
evidence/amd-memory-scalar-store-regression：
  此前12场景，9648个结果word+192528个保护区word，0差异。
  涉及实际空buffer/image描述符、部分向量、64位值、并发32位原子、2D存储图像、
  显式LOD采样。旧自定义驱动内部dummy计数器不在此库，因此没有冒充其内部证据；
  外部GPU结果与保护区检查仍全部保留。
evidence/amd-aggregate-scalar-store-regression：
  公开6个shader，16次dispatch；结构体、整数组、行列主矩阵、读改写、纹理缓冲
  atomicStore及函数内指针复制，所有输出比较通过。
三组均为真实AMD5600M，Metal API Validation开启；只有公开aggregate测试保留了
“Non-Apple GPUs do not fully support robustness”警告。警告未抹去，不能因此声称
完整支持或将VK_ERROR_FEATURE_NOT_PRESENT字样当成整个GPU运行失败。
GPU子进程PATH=/nonexistent，只有构建/测试编排使用Python。

仍未完成
--------
未做完整R2或CTS，AMD R2三位仍000。新增向量修复只验证了32位uint的直接runtime
vector array；实现考虑32/64位分量，但64位向量/其他标量类型尚未在新增网格验证。
固定向量数组、嵌套聚合、小range内的静态CBV成员访问、UAB并发、大规模bindless、
更多image/implicit derivative/图形阶段在这套参考库上仍需检查；不能照搬旧库的
210场景结果算成本库已全部通过。原来的图形/BDA原型保留，没有被新库部署替代。
未跑窗口呈现、D3D12设备或游戏，不提供FPS或黑屏修复承诺。

下一步按实际游戏要求继续
----------------------
稀疏硬件缺口本身不再是停工条件。优先验证实际CBV/绑定规模和MSL保护覆盖，以及
Wine到此隔离Vulkan后端的D3D12调用链；正式版准备好后，通过正常正版Steam链
记录最小feature level、CreateReservedResource/UpdateTileMappings等调用，不能
通过直接执行游戏、伪造能力或修改工作的应用宝环境来收集。
仅在正式版实际依赖被确认时评估稀疏软件模拟；当前没有足够访问模式数据给出
可信工期/FPS百分比。保留宽泛DX12适配目标，但不把本轮当成游戏目标已完成。

复现测试
--------
python3 run_reference.py --run --suite vector --label UNIQUE_LABEL
python3 run_reference.py --run --suite memory --label UNIQUE_LABEL_2
python3 run_reference.py --run --suite compiler --label UNIQUE_LABEL_3
evidence/configure-command.json记录隔离构建参数；build/driver是对应构建目录。
evidence/private-compiler-option.patch、private-image-compiler-option.patch及
vector-component-bounds.patch为相对于公开70补丁基线的自身增量。
