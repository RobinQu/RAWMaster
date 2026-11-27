import SwiftUI
import RAWMasterCore

struct VirtualCopyMenuItems: View {
    @EnvironmentObject private var model: AppModel
    let asset: AssetRecord?

    var body: some View {
        let admitted = asset.flatMap { model.editingAdmissions[$0.physicalAssetID] } != nil
        if model.scope == .project || model.scope == .all {
            Button("创建虚拟副本…") {
                if let asset { model.requestVirtualCopy(.create, for: asset) }
            }.disabled(model.isBusy || !admitted)
                .help(asset == nil ? "请先选中一张照片" : admitted ? "从当前调整创建一份独立的呈现" : "这张照片尚未接入编辑")
                .accessibilityIdentifier("library.virtualCopy.create")
            if let asset, asset.virtualCopyName != nil {
                Button("重命名虚拟副本…") { model.requestVirtualCopy(.rename, for: asset) }
                    .accessibilityIdentifier("library.virtualCopy.rename")
                Button("移除虚拟副本…") { model.requestVirtualCopy(.remove, for: asset) }
                    .accessibilityIdentifier("library.virtualCopy.remove")
            }
        }
    }
}

struct VirtualCopySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: VirtualCopyRequest
    @State private var name: String
    @State private var issue: String?
    @State private var saving = false
    private enum Field: Hashable { case name, cancel }
    @FocusState private var focused: Field?

    init(request: VirtualCopyRequest) {
        self.request = request
        _name = State(initialValue: request.suggestedName)
    }

    private var title: String {
        switch request.action {
        case .create: "创建虚拟副本"
        case .rename: "重命名虚拟副本"
        case .remove: "移除虚拟副本"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text(title).font(.headline)
            Text(request.asset.exportPresentationName).foregroundStyle(.secondary).lineLimit(2)
            if request.action == .remove {
                Text("移除这份副本及其编辑与快照？原片和已交付文件会保留。")
            } else {
                TextField("副本名称", text: $name).focused($focused, equals: .name)
                    .onSubmit(commit)
                    .accessibilityIdentifier("library.virtualCopy.name")
            }
            if let issue { Text(issue).foregroundStyle(AppPalette.warning).accessibilityIdentifier("library.virtualCopy.issue") }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .focused($focused, equals: .cancel)
                    .accessibilityIdentifier("library.virtualCopy.cancel")
                if request.action == .remove {
                    Button("移除副本", role: .destructive, action: commit)
                        .accessibilityIdentifier("library.virtualCopy.confirm")
                } else {
                    Button(request.action == .create ? "创建" : "存储", action: commit)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("library.virtualCopy.confirm")
                }
            }
        }
        .disabled(saving)
        .padding(AppDesign.Spacing.section)
        .frame(idealWidth: 360, maxWidth: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focused = request.action == .remove ? .cancel : .name }
        .interactiveDismissDisabled(saving)
    }

    private func commit() {
        guard !saving else { return }
        if request.action != .remove, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue = "请输入副本名称。"
            focused = .name
            return
        }
        saving = true
        Task {
            do { try await model.commitVirtualCopy(request, name: name) }
            catch { issue = error.localizedDescription; focused = request.action == .remove ? .cancel : .name }
            saving = false
        }
    }
}
