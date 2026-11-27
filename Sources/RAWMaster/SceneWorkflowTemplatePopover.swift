import SwiftUI
import RAWMasterCore

struct SceneWorkflowTemplatePopover: View {
    @ObservedObject var editing: EditingController
    let ticket: EditingController.SceneGraphTicket
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = SceneWorkflowTemplate.Kind.whole
    @State private var items = [SceneWorkflowTemplate]()
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工作流模板").font(.headline)
            Text("只保存工作流意图；不保存原片、输出设置或监看。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("模板名", text: $title).textFieldStyle(.roundedBorder)
                Picker("范围", selection: $kind) {
                    Text("整个工作流").tag(SceneWorkflowTemplate.Kind.whole)
                    if isGroup { Text("选中组").tag(SceneWorkflowTemplate.Kind.group) }
                }.labelsHidden()
                Button("保存模板") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            if items.isEmpty { Text("尚未存入模板。").font(.caption).foregroundStyle(.secondary) }
            else {
                List(items) { template in
                    HStack {
                        Text(template.name).lineLimit(1); Spacer()
                        Button(template.kind == .group ? "插入到所选边/图尾" : "替换图（可撤销）") {
                            if editing.applySceneWorkflowTemplate(template, ticket: ticket) { dismiss() }
                            else if editing.sceneGraphTicket != ticket { editing.postNotice("工作流上下文已改变，请重新打开。", kind: .error) }
                        }.disabled(template.kind == .whole && (!editing.sceneGraphState.path.isEmpty || editing.sceneGraphState.edge != nil))
                    }
                }.frame(height: 145)
            }
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(12).frame(width: 352).disabled(busy || editing.sceneGraphTicket != ticket)
         .task { await reload() }
    }
    private var isGroup: Bool { if case .group? = editing.sceneGraphNode?.operation { return true }; return false }
    private func reload() async {
        let owner = editing.asset?.id
        do { items = try await editing.loadSceneWorkflowTemplates() }
        catch is CancellationError {}
        catch { editing.postNotice(error.localizedDescription, kind: .error, for: owner) }
    }
    private func save() {
        busy = true
        let owner = editing.asset?.id
        Task {
            defer { busy = false }
            do {
                try await editing.saveSceneWorkflowTemplate(title, kind: kind, ticket: ticket)
                editing.postNotice("已保存工作流模板。", for: owner)
                title = ""; await reload()
            } catch { editing.postNotice(error.localizedDescription, kind: .error, for: owner) }
        }
    }
}
