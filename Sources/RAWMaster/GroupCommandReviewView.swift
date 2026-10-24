import SwiftUI
import RAWMasterCore

extension GroupCommandRequest {
    var title: String {
        switch self {
        case .create: return "建立拍摄组"
        case .rename: return "修改组名称"
        case .setKind: return "修改组用途"
        case .setLocked: return "修改组保护"
        case .removeMembers: return "从组中移出所选"
        case .reorder: return "调整组内顺序"
        case .setParticipation: return "调整序列参与"
        case .merge: return "合并拍摄组"
        case .split: return "拆分拍摄组"
        case .restore: return "恢复组操作前的状态"
        case .automaticBatch: return "自动建立待复核拍摄组"
        }
    }
}

struct GroupCommandReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            if let preview = model.groupPreview {
                GroupCommandReviewContent(preview: preview) { model.groupPreview = nil; dismiss() }.id(preview.id)
            }
        }.padding(26).frame(width: 760).frame(maxHeight: 760)
    }
}

struct GroupCommandReviewContent: View {
    @EnvironmentObject var model: AppModel
    let preview: GroupCommandPreview
    var onBack: () -> Void
    @State private var resolutions: [String: Bool] = [:]
    private var allResolved: Bool { Set(resolutions.keys) == Set(preview.inclusionConflicts.map(\.assetID)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preview.request.title).font(.title2.weight(.semibold))
            Text("核对成员、顺序和参与状态。应用后可撤销，照片决定与星级保持。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppPalette.warning)
                    }
                    if !preview.inclusionConflicts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("参与状态冲突 · 每张均须明确选择").font(.headline)
                            ForEach(preview.inclusionConflicts) { conflict in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(filename(conflict.assetID)).font(.caption.weight(.semibold))
                                    ForEach(Array(conflict.values.enumerated()), id: \.offset) { _, value in
                                        Text("\(groupName(value.groupID))：\(value.included ? "参与序列" : "不参与序列")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Picker("合并后", selection: Binding(get: { resolutions[conflict.assetID].map { $0 ? "include" : "exclude" } ?? "" }, set: { choice in
                                        if choice.isEmpty { resolutions.removeValue(forKey: conflict.assetID) }
                                        else { resolutions[conflict.assetID] = choice == "include" }
                                    })) {
                                        Text("请选择…").tag("")
                                        Text("参与序列").tag("include")
                                        Text("不参与序列").tag("exclude")
                                    }.frame(maxWidth: 350)
                                }
                            }
                        }.padding(12).background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack(alignment: .top, spacing: 18) {
                        snapshotColumn("应用前", groups: preview.before, isAfter: false)
                        snapshotColumn("应用后", groups: preview.after, isAfter: true)
                    }
                }
            }.frame(minHeight: 180, maxHeight: 470)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled)
                Button("重新预览当前操作") { model.refreshGroupPreview() }
            }
            Divider()
            HStack {
                Button("返回") { onBack() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用这项组操作") { _ = model.applyGroupPreview(resolutions: resolutions) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!allResolved)
            }
        }
    }
    private func snapshotColumn(_ title: String, groups: [CaptureGroup], isAfter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if groups.isEmpty { Text("无拍摄组").font(.caption).foregroundStyle(.secondary) }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Label(group.name, systemImage: group.locked ? "lock" : "lock.open").font(.caption.weight(.semibold))
                    Text("\(group.kind) · \(group.assetIDs.count) 张 · \(group.locked ? "受保护" : "未保护")")
                        .font(.caption).foregroundStyle(.secondary)
                    if group.assetIDs.isEmpty { Text("保留命名空组").font(.caption).foregroundStyle(AppPalette.warning) }
                    ForEach(Array(group.assetIDs.enumerated()), id: \.element) { index, id in
                        let conflicted = isAfter && preview.inclusionConflicts.contains { $0.assetID == id }
                        let included = conflicted ? resolutions[id] : group.includedAssetIDs.contains(id)
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                            Text(filename(id)).lineLimit(2)
                            Spacer(minLength: 2)
                            Text(included.map { $0 ? "参与" : "不参与" } ?? "待选择").foregroundStyle(included == nil ? AppPalette.warning : .secondary)
                        }.font(.system(size: 10))
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 7))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func filename(_ id: String) -> String { model.assets.first { $0.id == id }?.filename ?? id }
    private func groupName(_ id: String) -> String { preview.before.first { $0.id == id }?.name ?? model.groups.first { $0.id == id }?.name ?? "来源组" }
}
