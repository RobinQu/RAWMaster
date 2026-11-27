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
        if exportWorkspacePresented || showExport || editing?.showExport == true || editing?.showDraftExportChoice == true { return .export }
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
        HStack(spacing: 3) {
            ForEach(WorkbenchWorkflow.allCases, id: \.self) { workflow in
                let selected = model.activeWorkbenchWorkflow == workflow
                Button { model.activateWorkflow(workflow) } label: {
                    Text(workflow.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 15)
                        .frame(minHeight: 28)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(AppPalette.accent.opacity(0.14))
                                    .overlay(Capsule().stroke(AppPalette.accent.opacity(0.20), lineWidth: 0.5))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(workflow == .edit && !model.isNativeEditing && !model.canOpenNativeEditing && model.focusedAsset == nil
                    || workflow == .export && !model.canOpenWorkbenchExport)
                .accessibilityLabel(workflow.title)
                .accessibilityIdentifier("workflow." + workflow.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppPalette.boundary.opacity(0.55), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作流")
    }
}
