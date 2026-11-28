import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct PhotosLocalAdjustmentControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    @ObservedObject var input: EditingLocalInputSession
    let context: EditingInteractionContext
    let tool: DevelopmentLocalTool
    private var title: String { tool == .retouch ? "修复" : "红眼" }
    private var operations: [DevelopmentLocalEdit] { session.parameters.localEdits.operations.filter { $0.tool == tool } }
    private var modeDescription: String {
        switch input.retouchMode {
        case .remove: return "点击或涂抹要移除的区域。按住 Option 点击干净区域可指定来源。"
        case .heal: return "点击或涂抹要修复的区域。按住 Option 点击干净区域可指定来源。"
        case .clone: return "按住 Option 点击干净区域取样，再点击或涂抹目标区域。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
            if tool == .retouch {
                Text(modeDescription).photosInspectorParagraph().foregroundStyle(.secondary)
            }
            PhotosSliderRow(title: title + "大小", value: .init(get: { input.size(for: tool) },
                set: { input.setSize($0, tool: tool) }), range: input.sizeRange, step: 1, digits: 0) {
                    input.setSize($0, tool: tool)
                }.help("放大照片不会改变修饰范围。")
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
                if input.donor != nil {
                    let canChooseAutomatically = input.retouchMode != .clone &&
                        editing.developmentSourceFacts?.localCapabilities.contains(.automaticDonor) == true
                    Button(canChooseAutomatically ? "使用自动来源" : "清除来源") { input.clearDonor() }
                        .buttonStyle(.borderless).font(.caption)
                }
            } else {
                Text("调整圆圈大小，再点击红色瞳孔。未检测到红眼时不会改动照片。")
                    .photosInspectorParagraph().foregroundStyle(.secondary)
            }
            if !session.parameters.isEnabled(tool == .retouch ? .retouch : .redEye), !operations.isEmpty {
                Text("新增调整会启用这一组，并保留已有调整。").photosInspectorParagraph().foregroundStyle(.secondary)
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
        }
    }
}

struct PhotosRepairInspector: View {
    private enum Choice: Hashable {
        case retouch(DevelopmentRetouchMode)
        case redEye

        var tool: DevelopmentLocalTool {
            if case .retouch = self { return .retouch }
            return .redEye
        }

        var title: String {
            switch self {
            case .retouch(.remove): "移除"
            case .retouch(.heal): "修复"
            case .retouch(.clone): "仿制"
            case .redEye: "红眼"
            }
        }
    }
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    @ObservedObject var input: EditingLocalInputSession
    let context: EditingInteractionContext
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var repairHeadingFocused: Bool

    var body: some View {
        let tool = input.tool ?? editing.repairTools.first ?? .retouch
        let choices = [Choice.retouch(.remove), .retouch(.heal), .retouch(.clone), .redEye]
            .filter { editing.repairTools.contains($0.tool) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("修复").font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($repairHeadingFocused)
                if let asset = editing.asset {
                    Text(asset.editingDisplayName + " · 未提交草案").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
            Divider()
            ScrollView {
                if choices.count > 1 {
                    PhotosFlatTabs(title: "修复方式", selection: Binding(get: {
                        tool == .retouch ? .retouch(input.retouchMode) : .redEye
                    }, set: { choice in
                        input.cancelCollection()
                        if case let .retouch(mode) = choice { input.retouchMode = mode }
                        if choice.tool != tool { editing.selectDevelopmentLocalTool(choice.tool, context: context) }
                    }), options: choices, label: \.title)
                    .disabled(editing.developmentAnalysisBusy)
                    .padding(.horizontal, 12).padding(.top, 10)
                    .accessibilityIdentifier("photos.retouch.mode")
                }
                PhotosDevelopmentContent(editing: editing, session: session, context: context, viewportHeight: 0,
                    destination: .group(tool == .retouch ? .retouch : .redEye))
                if let failure = editing.repairFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.message).font(.caption)
                        HStack {
                            Button("重试") { editing.retryDevelopmentRepair() }.accessibilityIdentifier("editing.repair.retry")
                            Button("放弃这一笔") { editing.discardDevelopmentRepairFailure() }
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 6).disabled(editing.developmentAnalysisBusy)
                }
            }
            Divider()
            HStack(spacing: 6) {
                AppIconButton(systemName: "arrow.uturn.backward", label: "撤销草案",
                    isEnabled: session.repairCanUndo && !editing.developmentAnalysisBusy && !input.collecting) {
                    editing.undoDevelopment(context: context)
                }.accessibilityIdentifier("editing.repair.undo")
                AppIconButton(systemName: "arrow.uturn.forward", label: "重做草案",
                    isEnabled: session.repairCanRedo && !editing.developmentAnalysisBusy && !input.collecting) {
                    editing.undoDevelopment(context: context, redo: true)
                }.accessibilityIdentifier("editing.repair.redo")
                Spacer(minLength: 4)
                Button("取消", action: editing.cancelDevelopmentRepair)
                    .focused($cancelFocused).accessibilityIdentifier("editing.repair.cancel")
                Button("完成", action: editing.completeDevelopmentRepair)
                    .buttonStyle(.borderedProminent)
                    .disabled(editing.repairCompletionReason != nil)
                    .help(editing.repairCompletionReason ?? "应用本次修复")
                    .accessibilityIdentifier("editing.repair.done")
            }.controlSize(.small).padding(12)
        }
        .toggleStyle(PhotosFlatCheckboxStyle())
        .onAppear { cancelFocused = true; repairHeadingFocused = true }
    }
}
