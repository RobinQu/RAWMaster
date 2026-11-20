import SwiftUI
import RAWMasterCore

struct GroupPropertiesDraft: Equatable {
    var name: String
    var kind: String
    var locked: Bool
    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Each intentional workflow keeps its own values when users switch tabs.
struct GroupEditorDrafts {
    enum Workflow: String, CaseIterable { case properties = "属性", merge = "合并", split = "拆分" }
    var workflow: Workflow = .properties
    var properties: GroupPropertiesDraft
    var merge: GroupPropertiesDraft
    var split: GroupPropertiesDraft
    var mergeIDs = Set<String>()
    init(group: CaptureGroup?, defaultName: String) {
        properties = GroupPropertiesDraft(name: group?.name ?? defaultName, kind: group?.kind ?? "待分类", locked: group?.locked ?? true)
        merge = GroupPropertiesDraft(name: (group?.name ?? defaultName) + " · 合并", kind: group?.kind ?? "待分类", locked: true)
        split = GroupPropertiesDraft(name: (group?.name ?? defaultName) + " · 拆分", kind: group?.kind ?? "待分类", locked: true)
        if let group { mergeIDs = [group.id] }
    }
    func request(editing: CaptureGroup?, selectedIDs: [String], movedIDs: [String], compatibleGroups: [CaptureGroup]) -> GroupCommandRequest {
        guard let editing else {
            return .createWithProperties(assetIDs: selectedIDs, name: properties.name, kind: properties.kind, locked: properties.locked)
        }
        switch workflow {
        case .properties: return .updateProperties(groupID: editing.id, name: properties.name, kind: properties.kind, locked: properties.locked)
        case .merge:
            let ids = [editing.id] + compatibleGroups.filter { $0.id != editing.id && mergeIDs.contains($0.id) }.map(\.id)
            return .merge(groupIDs: ids, name: merge.name, kind: merge.kind)
        case .split: return .split(groupID: editing.id, movedAssetIDs: movedIDs, newName: split.name, newKind: split.kind)
        }
    }
}

extension AppModel {
    var canMutateGroups: Bool { !isCatalog && !isHistoryScope && !isBusy && !showTimelapse }
    var canCreateGroup: Bool {
        canMutateGroups && activeGroup == nil && !actionAssetIDs.isEmpty
            && Set(selectedAssets.map(\.projectID)).count == 1
    }
    /// Empty groups are editable only while that already-open published project detail remains active.
    func isCurrentPublishedEmptyGroup(_ group: CaptureGroup) -> Bool {
        scope == .group && scopeID == group.id && group.assetIDs.isEmpty
            && projects.contains { $0.id == group.projectID }
    }
    func canEditGroup(_ groupID: String) -> Bool {
        guard canMutateGroups, let group = groups.first(where: { $0.id == groupID }) else { return false }
        return manageableGroups.contains { $0.id == groupID } || isCurrentPublishedEmptyGroup(group)
    }
    var groupSelectionActionTitle: String { activeGroup == nil ? "创建拍摄组…" : "从拍摄组中移除" }
    var canPerformGroupSelectionAction: Bool {
        guard let group = activeGroup else { return canCreateGroup }
        return canEditGroup(group.id) && group.assetIDs.contains { selectedIDs.contains($0) }
    }
    func performGroupSelectionAction() {
        guard canPerformGroupSelectionAction else { return }
        if activeGroup != nil { removeFromGroup() } else { editGroup() }
    }
    func membershipGroups(for assetID: String, containing: Bool) -> [CaptureGroup] {
        guard canMutateGroups, let asset = filteredAssets.first(where: { $0.id == assetID }) else { return [] }
        return manageableGroups.filter { $0.projectID == asset.projectID && $0.assetIDs.contains(assetID) == containing }
    }
    func previewPhotoMembership(assetID: String, groupID: String, adding: Bool) {
        guard membershipGroups(for: assetID, containing: !adding).contains(where: { $0.id == groupID }) else { return }
        _ = previewGroup(adding ? .addMembers(groupID: groupID, assetIDs: [assetID])
            : .removeMembers(groupID: groupID, assetIDs: [assetID]))
    }
    func canOpenCatalogGroupProperties(_ groupID: String) -> Bool {
        guard !isBusy, !showTimelapse, !hasBusinessSheet,
              let group = visibleGroups.first(where: { $0.id == groupID }), projects.contains(where: { $0.id == group.projectID }) else { return false }
        return Set(group.assetIDs).isSubset(of: groupManagementAssetIDs)
    }
    func openCatalogGroupProperties(_ groupID: String) {
        guard canOpenCatalogGroupProperties(groupID) else { return }
        openCatalogSequence(id: groupID)
        guard scope == .group, scopeID == groupID else { return }
        editGroup(groupID)
    }
}

struct GroupSelectionActionButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.performGroupSelectionAction() } label: {
            Label(model.groupSelectionActionTitle, systemImage: model.activeGroup == nil ? "square.stack.3d.up" : "minus.rectangle")
        }.disabled(!model.canPerformGroupSelectionAction).accessibilityIdentifier("group.selectionAction")
    }
}

struct GroupPropertiesButton: View {
    @EnvironmentObject var model: AppModel
    let groupID: String
    var compact = false
    var body: some View {
        Button { model.editGroup(groupID) } label: {
            if compact { Image(systemName: "slider.horizontal.3").font(.system(size: 10)) }
            else { Label("编辑拍摄组…", systemImage: "slider.horizontal.3") }
        }.buttonStyle(.borderless).controlSize(.small).disabled(!model.canEditGroup(groupID))
            .help("编辑组名称、用途和结构保护")
            .accessibilityLabel("编辑拍摄组属性")
            .accessibilityIdentifier("group.properties." + groupID)
    }
}
