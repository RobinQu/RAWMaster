# 019 · 项目内编辑流程与低延迟预览

用户2026-10-30要求精简右上重复按钮、评估常见Lightroom/CameraRaw调整、加速初修并与本机CameraRaw对照。最新指令撤回导入初筛调整，初修仅已导入且已纳入项目的单张照片；不扩初筛、全局目录或历史。

执行经Oracle批准的019高层/分工计划。Designer独占App UX/controller/hooks；Services独占Imaging预览与隔离性能探针；root协调、研究/规格、实际验证与打包；Core只读scope审计，无schema/recipe/lineage迁移。所有018未提交集成改动及已安装应用、活动用户库保持为基线；开发与基准使用隔离资料库和已授权原片副本。

交付合同：右上最多三个有明确名称的主入口，内部编辑和外部副本不使用同一图标并列；编辑阶段/返回/保存/采用/导出对应实际显示对象。源会话一次严格验证，bounded latest-wins与native join，预览参数语义不改变，持久输出/AI输入仍严格校验。未实现的新调整不显示假可用滑杆。

[完整能力与阶段评估](../../docs/planning/21-development-controls-and-preview-performance.md)。测试与真实性边界见validation.md；实施进度.slim/deepwork/019-preview-ux.md。
