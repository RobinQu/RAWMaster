import SwiftUI
import RAWMasterCore

extension RelocationRole {
    var title: String { self == .source ? "原始来源" : "受管副本" }
}
extension RelocationItemStatus {
    var title: String {
        switch self {
        case .matched: return "内容一致"
        case .ambiguous: return "多个相同内容候选"
        case .missing: return "未找到"
        case .differentContent: return "同名但内容不同"
        case .noHash: return "缺少旧内容校验"
        case .unreadable: return "无法读取"
        case .stale: return "证据已变化，需重查"
        case .committed: return "已应用位置"
        }
    }
}
extension RelocationSession {
    var statusTitle: String {
        switch status {
        case "scanning": return "只读核验中 / 中断后可继续"
        case "review": return "待确认匹配位置"
        case "cancelled": return "已取消，需重新核验"
        case "failed": return "查找未完成"
        case "completed": return "匹配位置已应用"
        case "partial": return "已部分应用，仍有未恢复项"
        default: return status
        }
    }
}

struct RelocationWorkflowView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rootPath = ""
    private var report: RelocationSession? { model.relocationReport }
    private var canConfirm: Bool {
        guard let report else { return false }
        return !model.isBusy && report.scanComplete && ["review", "partial"].contains(report.status) && report.matchedCount > 0
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("找回原片").font(.title2.weight(.semibold))
                    Text("\(model.relocationImportSession?.projectName ?? "导入会话") · \(model.relocationScopeCount) 张 · \(model.relocationRole.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let report { reportView(report) } else { configuration }
            if model.relocationIsRunning, let progress = model.progress {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress.message.isEmpty ? progress.title : progress.message).font(.caption).lineLimit(2)
                    Spacer()
                    Button("取消查找") { model.cancelJob() }.controlSize(.small)
                }.padding(12).background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 7))
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled)
            }
            Text("只在确认后更新内容一致的文件位置；照片决定、星级和组关系不变。取消或关闭不会删除原记录或原片。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if let report, !model.isBusy {
                    Button(report.scanComplete ? "重新核验" : "继续查找并核验") { model.resumeRelocation() }
                    Button("改选查找目录…") { model.prepareRelocation(sessionID: report.importSessionID, assetIDs: report.items.map(\.assetID), role: report.role) }
                }
                Spacer()
                Button(model.relocationIsRunning ? "在后台继续" : "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                if let report {
                    Button("应用 \(report.matchedCount) 项匹配") { model.confirmRelocation() }
                        .buttonStyle(.borderedProminent).disabled(!canConfirm)
                } else {
                    Button("只读扫描并核验") { model.startRelocation(root: URL(fileURLWithPath: rootPath)) }
                        .buttonStyle(.borderedProminent).disabled(rootPath.isEmpty || model.isBusy)
                }
            }
        }.padding(24).frame(width: 790).frame(minHeight: 430, maxHeight: 720)
    }
    private var configuration: some View {
        Form {
            Picker("查找位置", selection: $model.relocationRole) {
                Text("原始来源").tag(RelocationRole.source)
                if model.relocationImportSession?.mode == .copy { Text("受管副本").tag(RelocationRole.managed) }
            }.pickerStyle(.radioGroup)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(rootPath.isEmpty ? "选择同一批原片所在的文件夹…" : rootPath)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Button("选择…") { model.chooseDirectory("选择同一批原片所在的目录", initial: rootPath) { rootPath = $0.path } }
                }
                Text(model.relocationRole == .source
                     ? "查找原始来源；复制导入已有的受管副本位置保持不变。"
                     : "查找受管副本；导入时的原始来源保留。可选择副本所在工作目录，或 RAWMaster 会话文件夹。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("逐个校验完整内容；同名、同尺寸或相似画面均不会自动继承身份。预览报告后再决定是否应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.isBusy)
    }
    private func reportView(_ report: RelocationSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.statusTitle).font(.headline)
                    Text("待应用 \(report.matchedCount) 项 · 已应用 \(report.committedCount) 项 · 共 \(report.items.count) 项")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(report.scanComplete ? "扫描覆盖完整" : "扫描尚未完成").font(.caption).foregroundStyle(report.scanComplete ? AppPalette.keep : AppPalette.warning)
            }
            Text("查找目录：\(report.scanRootPath ?? report.rootPath)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if !report.message.isEmpty { Text(report.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.items) { item in relocationRow(item, report: report); Divider() }
                }
            }.frame(minHeight: 200, maxHeight: 380).background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 7))
        }
    }
    private func relocationRow(_ item: RelocationItem, report: RelocationSession) -> some View {
        let selectable = (item.status == .matched || item.status == .ambiguous) && report.scanComplete && ["review", "partial"].contains(report.status)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                if selectable {
                    Toggle(item.filename, isOn: Binding(get: { item.selectedPath != nil }, set: { included in
                        if !included { model.chooseRelocationCandidate(assetID: item.assetID, path: nil) }
                        else if item.candidates.count == 1 { model.chooseRelocationCandidate(assetID: item.assetID, path: item.candidates[0].path) }
                    })).toggleStyle(.checkbox).disabled(model.isBusy || (item.status == .ambiguous && item.selectedPath == nil))
                } else {
                    Label(item.filename, systemImage: item.status == .committed ? "checkmark.circle" : "exclamationmark.circle")
                }
                Spacer()
                Text(item.status.title).font(.caption).foregroundStyle(item.status == .committed || item.status == .matched ? AppPalette.keep : AppPalette.warning)
            }
            Text("原位置：\(item.oldPath)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if item.status == .ambiguous && selectable {
                Picker("选择候选位置", selection: Binding(get: { item.selectedPath ?? "" }, set: { model.chooseRelocationCandidate(assetID: item.assetID, path: $0.isEmpty ? nil : $0) })) {
                    Text("请明确选择位置…").tag("")
                    ForEach(item.candidates) { candidate in Text(candidate.path).tag(candidate.path) }
                }.disabled(model.isBusy)
            } else if let path = item.selectedPath {
                Text("新位置：\(path)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            if !item.message.isEmpty { Text(item.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(12)
    }
}
