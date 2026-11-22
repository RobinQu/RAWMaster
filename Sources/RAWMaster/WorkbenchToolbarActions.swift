import SwiftUI
import RAWMasterCore

/// Contextual native actions. Keep editing, rendering and low-frequency tools visually distinct.
struct WorkbenchToolbarActions: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if !model.isCatalog {
            if model.mode == .single {
                if model.canOpenNativeEditing && !model.isNativeEditing {
                    Button("编辑照片") { model.openNativeEditing() }
                        .help("初修、AI 精修与版本").accessibilityIdentifier("editing.open")
                }
                if model.canExport {
                    if model.canOpenNativeEditing {
                        Button("导出成片…") { model.openPhotoExport(.render) }
                            .disabled(model.focusedAsset == nil).accessibilityIdentifier("editing.export.render")
                    } else {
                        Button("复制原文件…") { model.openPhotoExport(.original) }
                            .disabled(model.focusedAsset == nil).accessibilityIdentifier("editing.export.original")
                    }
                }
            } else if model.scope != .session {
                if model.mode == .grid {
                    Button(exportTitle) { model.openProjectExport() }.disabled(!model.canExport)
                } else {
                    Button("导出所选…") { model.openSelectionExport() }.disabled(!model.canExport || model.actionAssetIDs.isEmpty)
                }
            }
        }
        moreMenu
    }
    private var exportTitle: String {
        switch model.scope { case .project: return "导出项目…"; case .group: return "导出序列…"; default: return "导出素材…" }
    }
    private var activityCount: Int {
        let exports = model.editing?.renderedExports.filter { $0.state != .succeeded && $0.state != .cancelled }.count ?? 0
        return (model.editing?.activeJobCount ?? 0) + exports
    }
    private var moreMenu: some View {
        Menu {
            if let editing = model.editing {
                Button(activityCount > 0 ? "制作任务与导出记录（\(activityCount) 项进行中或待核对）…" : "制作任务与导出记录…") { editing.showJobs = true }
                    .accessibilityIdentifier("editing.jobs")
                Button("AI 服务设置…") { editing.showSettings = true }
                Divider()
            }
            if !model.isCatalog && model.mode != .compare {
                if model.isNativeEditing {
                    Button("返回照片信息") { model.returnFromNativeEditing() }
                } else {
                    Button(model.showsRightSidebar ? "收起照片信息" : "显示照片信息") { model.toggleRightSidebar() }.help("Tab")
                }
            }
            if !model.isCatalog && model.mode == .single {
                if model.canOpenNativeEditing {
                    Button("复制原文件…") { model.openPhotoExport(.original) }.disabled(!model.canExport || model.focusedAsset == nil)
                        .accessibilityIdentifier("editing.export.original")
                }
                Menu(model.externalEditorPreparing ? "正在准备编辑副本…" : "外部编辑副本") {
                    if let application = model.photoshopApplicationURL {
                        Button("在 Photoshop 中编辑副本") { model.openExternalEditor(application: application) }
                    }
                    Button("选择其他编辑器…") { model.chooseExternalEditor() }
                }.disabled(!model.canOpenExternalEditor)
                if model.isNativeEditing {
                    Button("关联外部编辑结果…") { model.editing?.associateExternalResult() }
                }
            }
            if model.scope == .sequences && model.isCatalog {
                Button("序列操作记录…") { model.openGroupHistory() }
            }
        } label: {
            Text(activityCount > 0 ? "更多 · \(activityCount)" : "更多")
        }.help("任务、照片信息、原文件复制与外部编辑副本")
            .accessibilityIdentifier("workbench.more")
            .accessibilityLabel(activityCount > 0 ? "更多操作，有进行中或待核对任务" : "更多操作")
    }
}
