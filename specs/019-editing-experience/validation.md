# 019 · 验证记录

本机环境与源码基线：output/validation/019-preview-ux/baseline/。真实RAW与Adobe副本identity：sample-protocol.json。开发阶段不修改活动用户资料库或已安装018应用。实际结果逐阶段追加，未测不填达标。

质量门预先固定：canonical settled2400与原始同配方/同分辨率参考，几何方向/视场/整数裁切一致；可见8-bit通道p99绝对误差≤1/255。快速互动层若加入，单独记录近似性并由canonical终值替换；100%必须真实细节。API/赋图/draw/第三方GUI采样分开；单次cold不算p95。


A阶段旧版API首轮：DSC05994.ARW / SHA8f96d2fd…891e1c / 69,488,640bytes，RAW decoder8 / draftfalse / scale1，2400×1600适屏。进程首请求844.447ms（OS文件/Metal缓存未清），暖20请求标准中位665.27ms（排序上中位665.431ms）、p95698.304ms。包含真实API中的校验/捕获/解码/桥接，未包含Core入口snapshot、界面150ms尾部等待及实际绘制；不是GUI input-to-pixel、也不是CameraRaw对照胜负。阶段拆分probe与API/header已由Oracle审核通过。证据baseline-performance/legacy-api.json及同目录log/参考PNG。


B1界面回归106项，104执行通过、2环境跳过、0失败。入口仅明确项目/已纳入项目组且ready照片；重新纳入身份会使旧草稿/任务展示上下文失效。证据另见output/validation/019-editing-experience/ui-b1-tests.log与ui-b1-context-regression.log；源设计记录.slim/deepwork/019-ux-proposal.md。

P1同2400像素层：打开291.28ms+首帧742.79ms=1034.07ms，首次进程观测比旧844.45ms慢；暖20标准中位295.40ms、p95383.28ms，分别比旧约快2.25倍/1.82倍。21配方canonical通道p99误差0/255、最大1/255，尺寸/几何校验通过，不能称字节相同。18次native渲染与3次重复配方缓存命中均包含在暖结果中。一次69.49MB捕获/hash、57次stat；显示bitmap缓存预算128MiB，CI memoryLimit512MiB只是目标，进程physicalfootprint采样约6130MiB，必须继续分析，尚非最终性能验收。P1时Adobe加载RAW但空闲，旧基线仅打开文件框，内存/缓存环境不同。证据output/validation/019-preview-ux/p1-performance/。

CameraRaw行为对照已观察：18.7.0.2743、M4Max全加速、AdobeColor/拍摄时WB，曝光0→+1正确改变图像；仅在自有样本副本操作，最终Cancel放弃，未保存修改。原片SHA不变。没有可比的高频GUI呈现延迟证据，不宣称快于CameraRaw。具体配置和截图见output/validation/019-preview-ux/adobe/observations.json。

P1并发/原生detail审查修复后17/17回归通过，Oracle复审通过；其中revalidate/close临时租约、closeAll全局join、detail必须viewport0、满容量重绑定均补覆盖。接下来独立缓存消融，不沿用P1数字作为最终默认结果。开发中独立核对Core/AI/canonical渲染及Package共49文件SHA与019基线均相同；最终阶段需再核。


G生产版真实RAW闭环已过：warm20标准中位236.43ms、p95243.58ms，cold单次open+首帧744.92ms；21canonical p99通道误差0/255、最大1/255。afterframe采样最大1992.33MiB，生产periodic360次、约20ms中位间隔/p9526.53ms，双源与双native显示bitmap高水位2678.25MiB。只能称周期采样高水位，可能漏短瞬时峰；不能使用较低clone2454.53替代生产数。未证明冷启动收益。生产19focused含透明alpha/梯度/边缘及300事件fake20Hz风暴，active≤1、pending≤2、最终settled/安静后比较均交付。证据production-G-performance/及production-G-{real-raw,periodic}-tests.log。

匹配freshprocess旧/G/旧/G复测：旧标准中位620.47/628.06ms、p95653.09/639.81；G标准中位236.08/233.62、p95246.81/248.62。全部运行保留，不挑最好一次；p95接近250ms工程目标，无跨硬件余量证据。

C阶段最终51/51（协调器15/15）与双真实RAWcontrollerfixture1/1通过，Oracle签收代码+controller阶段。2ready且已纳入、保存baseline、9504×6336JPEG、比较/100%/fit、未自动采用、两source SHA与既有review/admission/pair/group/assets快照均不变。输入来源明确programmatic，不混入nativeinput p95。报告native-controller/019-native-preview-report.json。

独立debug Preview019已签名并通过bundle验证，尚未启动：CUA检测Mac锁屏，已请求用户解锁，实际窗口/真实输入延迟验收未完成。LSEnvironment仅独立UUID测试库与trace，未替换/Applications或写活动个人库。P2scaled1200/1600原型协议/ROI/参考SHA及公式已在GPU前冻结并经Oracle审核，仅授权独立原型，production默认尚未改。缺少实际方向6/8、肤色与羽毛RAW的项目如实标未验证。

2026-10-31 G+C全回归：719项、29环境相关跳过、0失败，6个testbundle全部通过。见full-G-C-tests.log及full-G-C-tests.json（记录日志SHA与逐bundle计数）；不将这些env skips混为实际模型/GUI验收通过。P2后若更改Imaging需对应回归，未改的Core/AI不为凑数量重复跑。


## 19.2 渐进交付闭环

此前真实burst107native但仅final+comparison2交付暴露持续拖动饥饿，已修订为有界opt-in：旧client/defaultstrict不变，仅primary editableRAW FIT可逐步显示有效active结果，pending替换为最新；mode/source/lease/geometry/viewport等通过不可变registration/fence+单调epoch隔离，终值精确收敛。G像素/context、Core/AI/输出49保护文件不改（NativeSource仅加只读hasRAWFilter资格getter）。

后台33回归与源码阶段通过；真实API300@20Hz期间59唯一primary帧、总61primary+1baseline，native1/pending2、最终301正确，p99=0/max1。n60可关联interactive帧input→API标准median270.046854ms、p95296.063833；期间n59median269.021083，不能将这分布当全部300输入或draw。停止→exactAPI305.61ms。20ms周期采样777点highwater1736.35MiB仅本轮FIT+baseline，不取代此前双源/detail2678.25MiB观察。terminaloverflow237显式报告。最新same21 warmmedian240.37/p95263.131416ms，超过250目标，如实保留；不能挑旧244代表所有轮次。

App源码/71targeted通过，新增无lease取消open/重复reset-shutdown修复退休票据ack。实际App控制器300scheduled20Hz独立probe1/1通过16.254s：duringinput61唯一progress、total64含初始收尾、final303 exactsettled/EV1/busyfalse，release→observedfinal386.703ms（程序化）；source/review/admission/pair/group/assets保持、原图采用不变，shutdown0active/pending/owned；trace关闭/correlationnil/noJSON，只存metadata。API交付数=null未另争stream，AppKitdraw=null无NSView；不把pane接受当屏幕呈现。原有真实双RAWController烟测也再次1/1通过17.694s（native-controller-progress）。

最新完整集成：755项、31环境/opt-in跳过、0失败，6bundle224/30/266/19/206/10，full-progress-integration-tests.json/log（SHA84d1152e…f0944）。Oracle独立复核源码/实际probe/755计数通过。19.2 release正在构建，窗口/真实nativeinput/ACR对照仍被Mac锁屏阻断，未替换/Applications。

19.2 release构建、图标、两app ad-hoc deep/strict签名、ZIP CRC及可执行hash、相同compiledUUID通过。364源码文件构建后未变，49保护源不变，GNativeSource剔除只读hasRAWFilter后SHA精确原G。正常包无测试环境，独立Preview绑定新双RAWfixture；/Applications旧018binary与安装收据完全一致。final-19.2-build.json/package-verification/preservation记录详细值；第四次CUA在最终包准备后仍Maclocked，未启动Preview/无窗口截图，等待用户解锁后原生验收和升级前最新库备份。

## 19.2 原生窗口 UX 验收（2026-10-31；安装后续回执见末节）

此前锁屏阻断已经解除。root在冻结的19.2独立测试App、隔离双RAW/保存初修候选项目中完成CUA原生操作；不是offscreen布局截图或程序化setter替代。完整集成计数保持755项、31skip、0fail，原生验收不额外改写测试数量。

- 右上文字操作清楚、最多3项；更多菜单收拢任务、设置、信息、原文件和外部副本工具。曝光设为0.5；返回浏览再进入编辑保留草稿，未自动采用。
- dirty草稿导出显示“保存为新版本并导出 / 导出当前采用版本 / 取消”三项；取消返回且不保存、不采用、不导出。[截图](../../output/validation/019-preview-ux/native-ui/dirty-export.jpg)
- 几何区可折叠；crop overlay时100%禁用，收起几何区清除overlay模式。[浅色宽窗口](../../output/validation/019-preview-ux/native-ui/geometry-light-wide.jpg)
- 选择初修候选720755进行比较，切换基准后立即100%，实际9504×6336，无迟到错误永久遮罩。[版本比较/原生像素](../../output/validation/019-preview-ux/native-ui/comparison-native-pixels.jpg)
- AI提示框输入pxgcz123保持为文本，不触发P/X、评分、导航或浏览模式；更多菜单语义清晰。[更多菜单](../../output/validation/019-preview-ux/native-ui/more-menu.jpg)
- 浅/深色、宽/最小窗口可读。最小内容区1100×720，整窗截图2200×1544物理像素，含原生窗框。[深色宽窗口](../../output/validation/019-preview-ux/native-ui/development-dark-wide.jpg) · [深色最小窗口](../../output/validation/019-preview-ux/native-ui/development-dark-minimum.jpg)
- 全部素材没有项目编辑入口。[范围隔离](../../output/validation/019-preview-ux/native-ui/all-assets-no-edit.jpg)

真实原生拖动两次已采集[interaction-19.2.jsonl](../../output/validation/019-preview-ux/native-ui/interaction-19.2.jsonl)，Oracle已完成前132955字节/209行日志前缀的独立分析，见末节；尚不把有限混合样本当全部输入或稳定p95。66ms/250ms速度目标和快于ACR仍未证实，最新API p95263.13ms等历史结果保持，不挑最好轮次。曲线、Color Grading及其他规划调整控件仍是能力评估/路线图，本批未实现。

Preview已恢复“跟随系统”并退出；旧018确认无制作任务、未在编辑并已退出。本段最初的待安装状态已由下面09:32安装与09:33启动校验回执取代。以上只追加文档，未改源码、配方、像素、资料库或重新构建。


## 2026-10-31 09:33 安装、资料库与原生 trace 最终回执

[installation-19.2.json](../../output/validation/019-preview-ux/installation-19.2.json)确认标准build19.2已安装到/Applications/RAWMaster.app；binary SHA256=`13698509d104999c2c088ff05d21615cf07bf229f15811060e9843a482ce0ac1`，codesign --deep --strict通过，正常包无测试环境。原子renameatx_np RENAME_SWAP替换、旧应用保留；实际个人library.sqlite由运行进程打开（lsof已核），schema7 / SQLite integrity=ok。

[升级前备份](../../output/validation/019-preview-ux/installation-backup.json)：`/Users/robinqu/Library/Application Support/RAWMaster Backups/before-019-20261031-093042`，应用支持目录3034913823B，含受管AI Runtime、编辑档案、副本、迁移备份、库及grouping-key；另保存偏好和旧应用。**外部模型权重保留原位置，未复制进备份**，引用原片也保持原位置，不把“完整support备份”写成全模型/全原片备份。

安装验证时32表计数全部不变、31表内容SHA不变；唯一内容变化是既有project_review_states一条记录因GUI验收grid→single、revision13→15，未改变review/adoption/assets。6928资产/7项目/49组/588membership保持，processing_jobs仍0，模型root和外观偏好保持。[已安装App截图](../../output/validation/019-preview-ux/native-ui/installed-19.2.jpg)作为安装证据，报告主视觉沿用隔离测试版宽窗口截图。

[Oracle原生日志前缀分析](../../output/validation/019-preview-ux/native-ui/oracle-native-input-draw-analysis.md)范围132955B、209完整行，非后续追加日志的整体结论：33参数操作，29关联native时间戳、4缺事件；29工作提交均有终态；21唯一发布帧、19 draw-return、2未绘制不填0。6个可关联native input→AppKit draw-return样本，中位259.71ms，范围117.22–436.73ms（仅1个interactive、2个手势settled，混合小样本不算稳定p95）；release→draw n2，396.66–436.73ms。排除的10个programmatic及3个native无timestamp仍保留coverage计数。终点只是image.draw返回，非WindowServer/显示呈现；66ms/250ms目标及ACR胜出仍未证实，未实现的路线图控件保持未实现。

此回执取代前文锁屏/窗口未验收/待备份安装的当前状态，历史阶段数据不改；755/31skip/0fail不变。仅文档更新，无新源码/测试/构建。
