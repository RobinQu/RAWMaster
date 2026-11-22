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
    var activeWorkbenchWorkflow: WorkbenchWorkflow {
        if exportWorkspacePresented || showExport || editing?.showExport == true || editing?.showDraftExportChoice == true { return .export }
        return isNativeEditing ? .edit : .library
    }

    func activateWorkflow(_ workflow: WorkbenchWorkflow) {
        if workflow != .export && exportWorkspacePresented {
            workbenchExportContext = .project
        }
        switch workflow {
        case .library:
            exportWorkspacePresented = false; showExport = false; editing?.showExport = false
            if isNativeEditing { returnFromNativeEditing() }
        case .edit:
            exportWorkspacePresented = false; showExport = false; editing?.showExport = false
            if isNativeEditing { editing?.stage = .development }
            else {
                if mode != .single { setMode(.single) }
                if canOpenNativeEditing { openNativeEditing() }
            }
        case .export:
            guard canExport, !exportWorkspacePresented else { return }
            if isNativeEditing { editing?.openExport(); editing?.showExport = false }
            if case .selection = workbenchExportContext {
                // An explicit multi-selection is captured before opening the workspace.
            } else if isNativeEditing {
                workbenchExportContext = actionAssetIDs.count>1 ? .selection(ids:actionAssetIDs):.photo(id:editing?.asset?.id ?? focusedID ?? "")
            } else if actionAssetIDs.count>1 { workbenchExportContext = .selection(ids:actionAssetIDs) }
            else if let only = actionAssetIDs.first { workbenchExportContext = .photo(id:only) }
            else if mode == .grid { workbenchExportContext = .project }
            prepareLibraryExport(workbenchExportContext)
        }
    }

    func cycleWorkflow(reverse: Bool = false) {
        let workflows = WorkbenchWorkflow.allCases
        let current = workflows.firstIndex(of: activeWorkbenchWorkflow) ?? 0
        for step in 1...workflows.count {
            let next = (current + (reverse ? -step : step) + workflows.count * 2) % workflows.count
            let candidate = workflows[next]
            if candidate == .edit && !isNativeEditing && !canOpenNativeEditing && focusedAsset == nil { continue }
            if candidate == .export && !canExport { continue }
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
                    || workflow == .export && !model.canExport)
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
