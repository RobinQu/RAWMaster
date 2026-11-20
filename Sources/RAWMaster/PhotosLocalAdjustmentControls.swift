import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct PhotosLocalAdjustmentControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    @ObservedObject var input: EditingLocalInputSession
    let context: EditingInteractionContext
    let tool: DevelopmentLocalTool
    private var title: String { tool == .retouch ? "修饰" : "红眼" }
    private var operations: [DevelopmentLocalEdit] { session.parameters.localEdits.operations.filter { $0.tool == tool } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("大小").font(.caption); Spacer()
                DevelopmentNumberField(title: title + "大小", value: .init(get: { input.size(for: tool) }, set: { input.setSize($0, tool: tool) }),
                    range: input.sizeRange, fractionDigits: 0).frame(width: 78)
            }
            Slider(value: .init(get: { input.size(for: tool) }, set: { input.setSize($0, tool: tool) }), in: input.sizeRange, step: 1)
                .accessibilityLabel(title + "画笔大小")
                .accessibilityHint("放大照片不会改变修饰范围。")
            Button(input.tool == tool ? "结束" + title : "在照片上" + (tool == .retouch ? "修饰" : "修正红眼")) {
                editing.selectDevelopmentLocalTool(input.tool == tool ? nil : tool, context: context)
            }.disabled(editing.developmentAnalysisBusy).accessibilityIdentifier("photos." + (tool == .retouch ? "retouch" : "redEye") + ".tool")
            if editing.developmentLocalAnalysisInProgress(tool) {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text(tool == .redEye && editing.developmentRedEyeAutomaticInProgress
                         ? (editing.developmentRedEyeAutomaticCancelling ? "正在取消…" : "正在检查整张照片…") : "正在处理这笔调整…").font(.caption)
                    Spacer()
                    Button("取消") {
                        if tool == .redEye && editing.developmentRedEyeAutomaticInProgress { editing.cancelDevelopmentRedEyeAutomatic(context: context) }
                        else if editing.developmentContext == context { editing.cancelDevelopmentLocalInput() }
                    }
                }
            }
            if tool == .retouch {
                Text("点击或涂抹修饰区域。按住 Option 点击干净区域，可指定修复来源。")
                    .font(.caption).foregroundStyle(.secondary)
                if input.donor != nil {
                    Button(editing.developmentSourceFacts?.localCapabilities.contains(.automaticDonor) == true ? "使用自动来源" : "清除来源") { input.clearDonor() }
                        .buttonStyle(.borderless).font(.caption)
                }
            } else {
                Text("调整圆圈大小，再点击红色瞳孔。未检测到红眼时不会改动照片。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !session.parameters.isEnabled(tool == .retouch ? .retouch : .redEye), !operations.isEmpty {
                Text("新增调整会启用这一组，并保留已有调整。").font(.caption).foregroundStyle(.secondary)
            }
            if !operations.isEmpty {
                Divider()
                ForEach(operations, id: \.id) { operation in
                    let number = (session.parameters.localEdits.operations.firstIndex(where: { $0.id == operation.id }) ?? 0) + 1
                    HStack {
                        Button(title + " · " + String(number)) { input.selectedOperationID = input.selectedOperationID == operation.id ? nil : operation.id }
                            .buttonStyle(.borderless).font(.caption)
                        Spacer()
                        Button { editing.removeDevelopmentLocalOperation(operation.id, context: context) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("删除第\(number)笔\(title)")
                    }
                }
            }
        }.onDisappear { if input.tool == tool, editing.developmentContext == context { editing.cancelDevelopmentLocalInput(clearTool: true) } }
    }
}
