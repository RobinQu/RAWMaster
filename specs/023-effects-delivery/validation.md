# 023 · 实际验证记录

## 当前检查点

本记录按实际执行追加，不把历史通过当作当前源码结果，也不把候选生成或公开导出计时当作原生GUI性能。

### 普通回归

- 完整Imaging：782项、41条件跳过、0失败，186.7秒，退出0。
- 完整UI：424项、17条件跳过、0失败，80.4秒，退出0。两个WindowServer用例因xctest宿主未激活而明确跳过；不替代原生窗口验收。
- Core：324项、3条件跳过、0失败；AI：20项、2条件跳过、0失败；Diagnostics：19项、0失败；SequenceProbe 30项通过。
- 运行时安装/打包Python回归与工具测试通过；比较器11项数学自测通过。
- 当前源码完整Debug全套：1600项、63条件跳过、0失败，271.2秒，退出0；完整Release全套同为1600项、63条件跳过、0失败，249.4秒，退出0。

### 已修复问题

- AdvancedDetail使用一次完整F32 materialize并真实join，消除整图/分块求值漂移；portrait统一在landscape坐标计算后恢复方向。8项高级细节测试在Debug/Release定点通过，原阈值未改，算子升为advanced-v2。
- StickyFailure测试改为异步invalidate→观察撤销→释放worker→等待invalidate/closeAll；增加waiting=0。完整ProgressChannel通过。排查用GCD生产实验已撤回。
- Native8在Debug明确跳过；诊断合同纳入两个现有proven字段；两个窗口测试只在测试宿主失活时跳过，其他错误仍失败。
- 当前直接曲线编辑通过`forDirectUserEdit()`选择natural-cubic-gamma512-luma-v1；仅打开/重放旧配方不迁移。拖拽、控制点数值和黑白场均走该入口。

### Photos／Camera Raw冻结参考

使用固定9504×6336 sRGB TIFF、原021 protocol SHA `fa0ba842…`、既有ROI与阈值。生成器绑定完整Core/Imaging源码、实际配方、候选和参考SHA。

- 固定20例＋ACR Texture/Clarity/Dehaze：20 PASS、3 FAIL、0 UNVERIFIED。FAIL为common-neutral、旧版Brilliance和旧PCHIP曲线。
- 当前直接编辑自适应Brilliance与自然曲线补测：2 PASS、0 FAIL。两项补测与旧路径分开保存，不覆盖旧失败。
- 因此22个调整病例均有当前或当前直接编辑路径的通过证据；common-neutral是独立的重编码/源保真差异，不能据此宣称与参考应用逐码值相同。
- 固定范围之外、组合配方、全部照片/RAW模式及全部透明边界不自动外推。已有滤镜、局部工具、几何和旧版本证据保持其原范围。

### 保存、导出与恢复

真实三图片Release控制器闭环通过：调整、保存开发候选、保持原采用版本、JPEG8/TIFF16导出、切换照片、重开数据库、原资产/审阅/纳入/组关系不变、源SHA不变、shutdown后ownedOperationCount=0。证据：`output/validation/023-effects-delivery/controller-persistence/`。

真实原生窗口闭环也已完成，证据位于`output/validation/023-effects-delivery/native-window/`：

- 在9504×6336 sRGB TIFF上实际输入饱和度0.5、自适应Brilliance 0.5；自然曲线直接编辑点为输入`0.5533452765443708`、输出`0.6538372097478679`，配方算法为`natural-cubic-gamma512-luma-v1`；Texture、Clarity、Dehaze均输入25并启用，画面均实际完成渲染。
- 2400×1600主预览的原生AppKit draw-return实测：Texture 13.352秒、Clarity 13.950秒、Dehaze含准备31.480秒；自然曲线输出编辑16.058秒，自适应Brilliance 11.767秒。轨迹与汇总为`interaction.jsonl`和`performance.json`。这些数值不是WindowServer呈现时间，也不是与Photos／Camera Raw的同画布速度矩阵。
- 保存得到初修候选`5515A8`，采用版本始终保持原图`FDC55C`。候选恢复后，曲线、Brilliance、饱和度、Texture、Clarity、Dehaze及Dehaze准备数据完整，源SHA始终为`8390078b…`。
- JPEG导出为9504×6336、8位、sRGB IEC61966-2.1，SHA `541e25a8…`；TIFF为9504×6336、16位、同一ICC，SHA `81938075…`。重开后两条记录均为`succeeded`。
- 验收中曾把成片移到证据子目录，应用按登记目标复查时如实标记`needsAttention`；随后恢复登记路径、以硬链接保留证据副本并再次重开，两条记录均恢复成功。最终不移动应用登记目标。
- 每次均通过Cmd+Q正常退出，最终进程不存在；三次shutdown记录均为activeNativeRenders=0、pendingRequests=0、cachedBitmapBytes=0、rawBaseResidentBytes=0。

### 构建、安装与范围

- 当前应用已用固定离线运行时完成Release构建和严格ad-hoc签名；构建版本23.0。固定运行时catalog SHA `6ae90188…`，没有下载模型或调用云API。ZIP `output/RAWMaster-23.0.zip` 已通过CRC，SHA256 `4d3eb4a7…`。
- 旧版20.0、偏好、默认资料库和编辑档案已备份到`output/validation/023-effects-delivery/pre-install-backup/`。23.0已安装到`/Applications/RAWMaster.app`，安装二进制SHA `abd11b71…`，严格签名通过。
- 安装写入完成且尚未启动安装版时，默认`library.sqlite`、偏好及`Editing Archive`与备份逐项一致；随后安装版成功打开含1,408个素材的默认资料库并正常退出。
- 当前通过范围是上述冻结参考、控制器闭环及该原生图片病例；不外推为所有组合配方、所有RAW模式、全部透明边界或全面跨应用速度一致性。
- 内存峰值优化按用户要求后置；崩溃、任务未join、数据安全与失控资源仍不放行。

### 资料库编辑入口补充验收（23.1）

- 实际窗口复现：同一已纳入照片在“全部素材”中没有编辑入口，切到具体项目后立即出现“编辑照片”和“导出成片”。根因是`canOpenNativeEditing`把`.all`和`.session`一律排除，而不是初修／AI精修模块缺失。
- 修复后，已纳入且就绪的照片可从全部素材、导入记录、项目或所属序列进入同一编辑工作区，不再要求先切换项目；未纳入、非就绪、跨项目、非所属序列及目录页面仍被拒绝。图像算法和编辑身份指纹未改动。
- 首次完整Debug仅有旧合同`testEditingRequiresLiteralAdmittedReadyProjectOrOwnedGroupContext`失败；该测试明确禁止全部素材和导入记录。按新需求仅更新这两条作用域预期，其他安全断言保留。两组编辑流程定点27项通过后，完整Debug与Release均为1601项、63条件跳过、0失败。
- 隔离资料库原生路径已实际通过：全部素材→编辑照片→初修→AI精修→初修→返回全部素材；编辑与成片导出按钮均可见，返回后浏览范围不变。shutdown记录为activeNativeRenders=0、pendingRequests=0、cachedBitmapBytes=0、rawBaseResidentBytes=0。证据：`output/validation/023-effects-delivery/library-entry/`。
- 23.1已安装到`/Applications/RAWMaster.app`，严格ad-hoc签名通过；安装二进制SHA `0f826137…`，ZIP SHA `1e77a7f0…`且CRC通过。安装版默认1,408素材页面也实际显示编辑入口并正常退出。
- 当前偏好因正常窗口操作发生变化，已保留当前版本而没有回滚；应用替换前后偏好与默认资料库均逐字节一致。未执行Git提交或推送。
