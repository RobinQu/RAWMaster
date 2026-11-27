import SwiftUI

/// The three top-level workflows share one stable title-bar location in every browser/editor view.
enum WorkbenchWorkflow: String, CaseIterable {
    case library, edit, export

    var title: String {
        switch self {
        case .library: return "资料库"
        case .edit: return "编辑"
        case .export: return "导出"
        }
    }
}

extension AppModel {
    var canOpenWorkbenchExport: Bool { workbenchExportStore != nil }

    var activeWorkbenchWorkflow: WorkbenchWorkflow {
        if exportWorkspacePresented || showExport || editing?.showExport == true { return .export }
        return isNativeEditing ? .edit : .library
    }

    func activateWorkflow(_ workflow: WorkbenchWorkflow) {
        if workflow != .export { pendingGridExport?.cancel() }
        let returningFromExport = workflow != .export && exportWorkspacePresented
        if returningFromExport {
            workbenchExportContext = .project
            exportCatalogScope = nil
            exportCatalogAssets = []
            requestedWorkbenchExportMode = nil
            editing?.closeWorkbenchExport()
        }
        switch workflow {
        case .library:
            exportWorkspacePresented = false; showExport = false; editing?.showExport = false
            if isNativeEditing { returnFromNativeEditing() }
        case .edit:
            exportWorkspacePresented = false; showExport = false; editing?.showExport = false
            if isNativeEditing {
                if !returningFromExport { editing?.stage = .development }
            }
            else {
                if let selected = singleSelectedGridAsset { focusedID = selected.id }
                if mode != .single { setMode(.single) }
                if canOpenNativeEditing { openNativeEditing() }
            }
        case .export:
            guard canOpenWorkbenchExport, !exportWorkspacePresented else { return }
            if workbenchPhotoDelivery?.running == true || !canExport {
                exportWorkspacePresented = true
                return
            }
            if case .selection = workbenchExportContext {
                // An explicit multi-selection is captured before opening the workspace.
            } else if isNativeEditing {
                let selected = actionAssetIDs.filter { selectedIDs.contains($0) }
                if selected.count > 1 { workbenchExportContext = .selection(ids: selected) }
                else if let asset = focusedAsset { workbenchExportContext = .photo(id: asset.id) }
            } else if actionAssetIDs.count>1 { workbenchExportContext = .selection(ids:actionAssetIDs) }
            else if let only = actionAssetIDs.first { workbenchExportContext = .photo(id:only) }
            else if mode == .grid { workbenchExportContext = .project }
            if isNativeEditing, requestedWorkbenchExportMode != .original {
                openRenderedPhotoExport(context: workbenchExportContext)
            } else {
                prepareLibraryExport(workbenchExportContext)
            }
        }
    }

    func cycleWorkflow(reverse: Bool = false) {
        let workflows = WorkbenchWorkflow.allCases
        let current = workflows.firstIndex(of: activeWorkbenchWorkflow) ?? 0
        for step in 1...workflows.count {
            let next = (current + (reverse ? -step : step) + workflows.count * 2) % workflows.count
            let candidate = workflows[next]
            if candidate == .edit && !isNativeEditing && !canOpenNativeEditing && focusedAsset == nil { continue }
            if candidate == .export && !canOpenWorkbenchExport { continue }
            activateWorkflow(candidate)
            return
        }
    }
}

struct WorkflowTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        AppButtonGroup(title: "工作流", options: WorkbenchWorkflow.allCases, selection: model.activeWorkbenchWorkflow,
                       stretches: false, isDisabled: { disabledReason($0) != nil },
                       help: { disabledReason($0) ?? $0.title }, identifier: { "workflow." + $0.rawValue },
                       action: model.activateWorkflow) { workflow in
            Text(workflow.title)
        }
    }

    private func disabledReason(_ workflow: WorkbenchWorkflow) -> String? {
        switch workflow {
        case .edit where !model.isNativeEditing && !model.canOpenNativeEditing && model.focusedAsset == nil:
            return "选择一张照片后进入编辑"
        case .export where !model.canOpenWorkbenchExport:
            return "打开可用的资料库后进入导出"
        default:
            return nil
        }
    }
}
