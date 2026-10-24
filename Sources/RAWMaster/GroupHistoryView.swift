import SwiftUI
import RAWMasterCore

extension GroupRestoreStatus {
    var explanation: String {
        switch self {
        case .available: return "可复核并恢复"
        case .alreadyReverted: return "当前已恢复"
        case .conflict(let reason): return "后续变更有冲突：" + reason
        }
    }
    var isAvailable: Bool { if case .available = self { return true }; return false }
}

struct GroupHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let preview = model.groupPreview {
                GroupCommandReviewContent(preview: preview) { model.groupPreview = nil }.id(preview.id)
            } else {
                Text("最近组操作").font(.title2.weight(.semibold))
                Text("组操作记录在重启后保留。恢复只作用于该次修改；当前运行中的 ⌘Z 按选片与组操作的实际顺序撤销。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.groupHistory.isEmpty { Text("还没有可恢复的组操作记录。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(model.groupHistory) { record in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.request.title).font(.headline)
                                        Text(record.createdAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("预览恢复影响") { _ = model.previewGroup(.restore(commandID: record.id), showSheet: false) }
                                        .disabled(!record.restoreStatus.isAvailable)
                                }
                                Text(record.restoreStatus.explanation).font(.caption).foregroundStyle(record.restoreStatus.isAvailable ? .secondary : AppPalette.warning)
                                Text((record.after.isEmpty ? record.before : record.after).map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }.padding(12).background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }.frame(minHeight: 220, maxHeight: 470)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
                HStack { Button("刷新记录") { model.reload() }; Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }.padding(26).frame(width: 760).frame(maxHeight: 760)
    }
}
