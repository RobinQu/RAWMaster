import AppKit
import SwiftUI
import RAWMasterAI
import RAWMasterCore
import RAWMasterImaging

enum QuickPromptDockLayout {
    static func compactActions(width: CGFloat) -> Bool { width < 390 }
    static func inputHeight(width: CGFloat) -> CGFloat { compactActions(width: width) ? 285 : 254 }
    static let bottomPadding: CGFloat = 18
}

struct QuickPromptDock<CanvasControls: View>: View {
    @ObservedObject var editing: EditingController
    let width: CGFloat
    @ViewBuilder let canvasControls: () -> CanvasControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Namespace private var glass
    @FocusState private var inputFocused: Bool
    @FocusState private var entryFocused: Bool
    @State private var selection: TextSelection?
    @State private var coordinates = false
    @State private var configure: QuickPromptModel?
    @State private var acknowledgedJob: ProcessingJob?
    @Binding var showCandidate: Bool
    let inspectPixels: () -> Void

    var body: some View {
        surface.background { material.accessibilityHidden(true) }
            .accessibilityElement(children: .contain)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25, extraBounce: 0), value: editing.quickPromptPresented)
            .onChange(of: editing.quickPromptPresented) { _, opened in
                if !opened { entryFocused = true }
            }
            .onChange(of: editing.quickPromptDraft) { _, _ in editing.dismissQuickPromptConfirmation() }
            .sheet(isPresented: $coordinates) {
                QuickPromptCoordinates(initial: editing.quickPromptDraft.selection) { crop in
                    editing.setQuickPromptScope(.rectangle(crop))
                }
            }
            .sheet(item: $configure) { model in
                QuickPromptSetup(model: model, profile: editing.quickPromptModelProfile ?? model.defaultProfile, editing: editing)
            }
            .sheet(item: Binding(get: { editing.quickPromptPending }, set: { _ in editing.dismissQuickPromptConfirmation() })) { prepared in
                QuickPromptCloudApproval(prepared: prepared, cancel: editing.dismissQuickPromptConfirmation, submit: editing.confirmQuickPrompt)
            }
            .alert("准备新尝试？", isPresented: Binding(get: { acknowledgedJob != nil }, set: { if !$0 { acknowledgedJob = nil } }), presenting: acknowledgedJob) { job in
                Button("取消", role: .cancel) { acknowledgedJob = nil }
                Button("回到提示词") { editing.acknowledgeQuickPromptOutcome(job); acknowledgedJob = nil }
            } message: { _ in Text("上一尝试可能已经出图或计费。保留原任务供核对。新云端尝试仍需确认发送。") }
    }

    @ViewBuilder private var material: some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            GlassEffectContainer(spacing: 0) {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: editing.quickPromptPresented ? 19 : 13))
                    .glassEffectID("darkroom-toolbar", in: glass)
            }
        } else {
            Color.clear.floatingSelectionSurface()
        }
    }

    private var compactActions: Bool { QuickPromptDockLayout.compactActions(width: width) }

    private var surface: some View {
        ZStack(alignment: .bottom) {
            if editing.quickPromptPresented {
                promptPanel.padding(12)
                    .transition(reduceMotion ? .identity : .opacity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("editing.quickPrompt.panel")
            } else {
                HStack(spacing: 6) {
                    canvasControls()
                    if editing.quickPromptUndoVersion != nil {
                        Button { editing.undoQuickPrompt() } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 26)
                        }.help("撤销快速 Prompt 采用").accessibilityIdentifier("editing.quickPrompt.undo")
                    }
                    Divider().frame(height: 18)
                    Button { editing.openQuickPrompt() } label: {
                        Label("Prompt", systemImage: "sparkles").font(.system(size: 11, weight: .medium))
                            .frame(height: 32).padding(.horizontal, 4)
                    }
                    .focused($entryFocused)
                    .disabled(!editing.canOpenQuickPrompt)
                    .help(editing.canOpenQuickPrompt ? "快速 Prompt" : "请先结束当前画布操作")
                    .accessibilityLabel("快速 Prompt")
                    .accessibilityIdentifier("editing.quickPrompt.open")
                }.buttonStyle(.plain).padding(.horizontal, 9).padding(.vertical, 5)
                    .transition(reduceMotion ? .identity : .opacity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("照片查看工具")
                    .accessibilityIdentifier("editing.canvasToolbar")
            }
        }
        .frame(width: editing.quickPromptPresented ? width : min(width, 392),
               height: editing.quickPromptPresented ? (editing.quickPromptReview == nil ? QuickPromptDockLayout.inputHeight(width: width) : 113) : 42,
               alignment: .bottom)
        .clipped()
        .controlSize(.small)
    }

    private var promptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("快速 Prompt", systemImage: "sparkles").font(.callout.weight(.semibold))
                Text(scopeLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("editing.quickPrompt.scope")
                Spacer()
                Button { editing.closeQuickPrompt() } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("收起快速 Prompt")
                    .accessibilityIdentifier("editing.quickPrompt.close")
            }
            if let review = editing.quickPromptReview { reviewControls(review) }
            else { inputControls }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onExitCommand {
            if editing.quickPromptSelecting { editing.quickPromptSelecting = false }
            else { editing.closeQuickPrompt() }
        }
    }

    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            templates
            ZStack(alignment: .topLeading) {
                if editing.quickPromptDraft.prompt.isEmpty {
                    Text("描述要修改的内容…").foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 7)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                TextEditor(text: $editing.quickPromptDraft.prompt, selection: $selection)
                    .focused($inputFocused)
                    .task {
                        await Task.yield()
                        if !Task.isCancelled && editing.quickPromptPresented { inputFocused = true }
                    }
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .accessibilityLabel("提示词")
                    .accessibilityIdentifier("editing.quickPrompt.text")
            }
            .font(.system(size: 13))
            .frame(height: 105)
            .background(AppPalette.panel.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(inputFocused ? AppPalette.accent : AppPalette.boundary)
                    .allowsHitTesting(false)
            }

            if compactActions {
                VStack(alignment: .leading, spacing: 5) {
                    selectionActions
                    submissionActions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 8) {
                    selectionActions
                    Spacer(minLength: 0)
                    submissionActions
                }
            }
            status
        }
    }

    private var templates: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                templateChips
                moreTemplates
            }.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) {
                ScrollView(.horizontal) { templateChips }
                    .scrollIndicators(.hidden)
                moreTemplates
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 27)
    }

    private var templateChips: some View {
        HStack(spacing: 5) {
            ForEach(Self.templates.prefix(4)) { item in
                Button { insert(item) } label: {
                    Text(item.title).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).frame(height: 25)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editing.quickPrompt.template." + item.id)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var moreTemplates: some View {
        Menu("更多短句") {
            ForEach(Self.templates.dropFirst(4)) { item in Button(item.title) { insert(item) } }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var selectionActions: some View {
        HStack(spacing: 5) {
            let full = editing.quickPromptDraft.selection == .whole && !editing.quickPromptSelecting
            scopeButton("圈选", symbol: "selection.pin.in.out", active: !full, id: "rectangle") {
                editing.quickPromptSelecting.toggle()
                inputFocused = false
            }
            scopeButton("全图", symbol: "photo", active: full, id: "whole") {
                editing.setQuickPromptScope(.whole)
            }
            Menu {
                Button("输入坐标…") { coordinates = true }
                Divider()
                if editing.quickPromptAvailableMasks.isEmpty { Text("当前构图没有可用蒙版") }
                else {
                    Section("使用已确认的蒙版") {
                        ForEach(editing.quickPromptAvailableMasks) { mask in
                            Button(mask.name) { editing.setQuickPromptScope(.mask(mask.id.uuidString)) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多圈选操作").help("输入坐标或使用现有蒙版")
            .accessibilityIdentifier("editing.quickPrompt.scopeMenu")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func scopeButton(_ title: String, symbol: String, active: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).frame(height: 26)
                .foregroundStyle(active ? AppPalette.accent : Color.primary)
                .background(active ? AppPalette.accent.opacity(0.16) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("editing.quickPrompt." + id)
    }

    private var submissionActions: some View {
        HStack(spacing: 8) {
            let model = editing.quickPromptDraft.model
            Menu {
                ForEach(QuickPromptModel.allCases) { choice in
                    Button { editing.quickPromptDraft.model = choice } label: {
                        Label(choice.title, systemImage: model == choice ? "checkmark" : "circle")
                    }
                }
                Button("配置所选模型…") { configure = model }
                Divider()
                Button(editing.work?.strictDocumentary == true ? "取消严格纪实标记" : "标记为严格纪实") {
                    editing.setStrictDocumentary(editing.work?.strictDocumentary != true)
                }
            } label: {
                Text(model == .flux ? "FLUX" : "Seedream").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(model.title).help(model.title)
            .accessibilityIdentifier("editing.quickPrompt.model")

            Button(model == .flux ? "生成候选" : "核对并生成…") { editing.prepareQuickPrompt() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editing.quickPromptSubmissionIssue != nil || editing.quickPromptPreparing
                          || editing.quickPromptJob?.blocksQuickPromptSubmission == true)
                .accessibilityIdentifier("editing.quickPrompt.generate")
        }.fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 7) {
            if editing.quickPromptPreparing {
                ProgressView().controlSize(.mini)
                Text("准备本次输入…")
                Spacer(minLength: 0)
                Button("停止准备", action: editing.cancelQuickPromptPreparation)
            } else if let job = editing.quickPromptJob, job.state == .outcomeUnknown {
                Text(job.acknowledgedQuickPromptOutcomeAt == nil ? "结果待核对" : "原结果待核对")
                Spacer(minLength: 0)
                Button("核对原尝试") { editing.reconcile(job) }
                if job.acknowledgedQuickPromptOutcomeAt == nil, !editing.canResumeSaving(job) {
                    Button("准备新尝试…") { acknowledgedJob = job }
                }
            } else if let job = editing.quickPromptJob, !job.state.isTerminal {
                ProgressView().controlSize(.mini)
                Text(job.state.editingTitle)
                Spacer(minLength: 0)
                Button("停止") { editing.cancel(job) }.disabled(job.state == .cancelRequested || job.state == .archiving)
            } else if let job = editing.quickPromptJob, let result = job.resultVersionID,
                      editing.dispositions[result] == .candidate {
                Text("候选已保存")
                Spacer(minLength: 0)
                Button("审阅候选") { showCandidate = true; editing.reviewQuickPrompt(job) }
                    .accessibilityIdentifier("editing.quickPrompt.review")
            } else if let notice = editing.quickPromptNotice {
                Text(notice)
            } else if let issue = editing.quickPromptSubmissionIssue {
                Text(issue)
            } else if let job = editing.quickPromptJob, job.state == .failed || job.state == .cancelled {
                Text(job.state == .failed ? "生成失败，可调整后重新提交。" : "已停止，可重新提交。")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
        .lineLimit(2).font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("editing.quickPrompt.status")
    }

    private func reviewControls(_ review: QuickPromptReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Picker("比较", selection: $showCandidate) {
                    Text("生成前").tag(false); Text("候选").tag(true)
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
                if review.job.request.quickPrompt?.selection != nil { Button("100% 边缘", action: inspectPixels) }
                if let artifact = review.version.artifact {
                    Text("\(artifact.pixelWidth) × \(artifact.pixelHeight)").monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                Button("返回", action: editing.leaveQuickPromptReview)
                Button("丢弃", action: editing.discardQuickPromptReview)
                Spacer(minLength: 0)
                if !editing.canAdoptQuickPrompt { Text("基线或纪实策略已变更").font(.caption).foregroundStyle(.secondary) }
                Button("应用到照片", action: editing.applyQuickPromptReview).buttonStyle(.borderedProminent)
                    .disabled(!editing.canAdoptQuickPrompt || editing.saving)
                    .accessibilityIdentifier("editing.quickPrompt.adopt")
            }
        }.lineLimit(1)
    }

    private var scopeLabel: String {
        if editing.quickPromptSelecting { return "正在圈选" }
        switch editing.quickPromptDraft.selection {
        case .whole: return "整张照片"
        case .rectangle: return "矩形选区"
        case .mask(let id): return editing.quickPromptAvailableMasks.first { $0.id.uuidString == id }?.name ?? "已用蒙版"
        }
    }

    private struct Template: Identifiable {
        let id, title, text: String
    }
    private static var templates: [Template] { [
        Template(id: "remove", title: "移除干扰", text: "移除［干扰物］，按相邻光线与纹理自然补齐，保留周围对象的边缘。"),
        Template(id: "background", title: "替换背景", text: "将背景改成［新背景］，保留主体的形状、发丝边缘和原有构图。"),
        Template(id: "light", title: "调整光向", text: "使用来自［方向］的柔光，保持人物五官、表情和服装细节。"),
        Template(id: "tone", title: "统一色调", text: "将整体色彩统一为［色调］，保留构图、高光层次和原有明暗关系。"),
        Template(id: "face", title: "保护五官", text: "保留五官与发丝。"),
        Template(id: "text", title: "保留标识和文字", text: "保留标识和原有文字。"),
        Template(id: "structure", title: "保持结构", text: "保持主要结构与透视。"),
        Template(id: "shadow", title: "延续阴影", text: "延续原图阴影方向。"),
        Template(id: "reflection", title: "保留倒影", text: "保留水面倒影。"),
        Template(id: "edge", title: "平顺衔接", text: "让补区纹理与邻域平顺衔接。")
    ] }

    private func insert(_ item: Template) {
        var draft = editing.quickPromptDraft
        let text = draft.prompt
        let position: String.Index
        if case .selection(let range) = selection?.indices, text.indices.contains(range.lowerBound) {
            position = range.lowerBound
        } else { position = text.endIndex }
        let offset = text.distance(from: text.startIndex, to: position)
        let before = text[..<position], after = text[position...]
        let phrase = (before.isEmpty || before.hasSuffix("\n") ? "" : "\n") + item.text + (after.isEmpty || after.hasPrefix("\n") ? "" : "\n")
        draft.prompt.insert(contentsOf: phrase, at: position)
        if !draft.templateIDs.contains(item.id) { draft.templateIDs.append(item.id) }
        editing.quickPromptDraft = draft
        selection = TextSelection(insertionPoint: draft.prompt.index(draft.prompt.startIndex, offsetBy: offset + phrase.count))
        inputFocused = true
    }
}

private struct QuickPromptCoordinates: View {
    @Environment(\.dismiss) private var dismiss
    @State private var x: Double
    @State private var y: Double
    @State private var width: Double
    @State private var height: Double
    let apply: (NormalizedCrop) -> Void

    init(initial: QuickPromptSelection, apply: @escaping (NormalizedCrop) -> Void) {
        let region: NormalizedCrop
        if case .rectangle(let current) = initial { region = current }
        else { region = .init(x: 0.25, y: 0.25, width: 0.50, height: 0.50) }
        _x = State(initialValue: region.x * 100); _y = State(initialValue: region.y * 100)
        _width = State(initialValue: region.width * 100); _height = State(initialValue: region.height * 100)
        self.apply = apply
    }

    private var valid: Bool { x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 100 && y + height <= 100 }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("矩形选区").font(.headline)
            Form {
                TextField("左边距 (%)", value: $x, format: .number)
                TextField("上边距 (%)", value: $y, format: .number)
                TextField("宽度 (%)", value: $width, format: .number)
                TextField("高度 (%)", value: $height, format: .number)
            }
            if !valid { Text("选区须位于当前构图内，宽度和高度大于零。").font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用选区") { apply(.init(x: x / 100, y: y / 100, width: width / 100, height: height / 100)); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(22).frame(width: 350)
    }
}

private struct QuickPromptCloudApproval: View {
    let prepared: QuickPromptPrepared
    let cancel, submit: () -> Void
    var body: some View {
        let artifact = prepared.request.inputArtifact
        VStack(alignment: .leading, spacing: 9) {
            Text("核对本次发送").font(.headline)
            Text(prepared.photoName + " · Seedream 5.5 · 北京方舟").font(.callout)
            Image(decorative: prepared.thumbnail, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: 368, maxHeight: 240).frame(maxWidth: .infinity)
                .accessibilityLabel("本次发送的图像")
            Text("\(prepared.request.quickPrompt?.selection == nil ? "整张当前构图" : "选区裁片及周围上下文") · \(artifact.pixelWidth) × \(artifact.pixelHeight)")
                .font(.callout).monospacedDigit()
            ScrollView { Text(prepared.request.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 88).accessibilityLabel("将提交的完整提示词")
            Text("发送一张图像和上面的提示词。生成一张候选，费用由当前方舟账户计入。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("返回", action: cancel).keyboardShortcut(.cancelAction)
                Button("发送并生成一张", action: submit).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("editing.quickPrompt.confirmSend")
            }
        }.padding(22).frame(width: 454)
    }
}

private struct QuickPromptSetup: View {
    @Environment(\.dismiss) private var dismiss
    let model: QuickPromptModel
    let profile: AIProviderProfile
    @ObservedObject var editing: EditingController
    @State private var python: String
    @State private var runtime: String
    @State private var weights: String
    @State private var credential = ""
    @State private var saving = false
    @State private var issue: String?

    init(model: QuickPromptModel, profile: AIProviderProfile, editing: EditingController) {
        self.model = model; self.profile = profile; self.editing = editing
        _python = State(initialValue: profile.configuration["pythonExecutable"] ?? "")
        _runtime = State(initialValue: profile.configuration["runtimeDirectory"] ?? "")
        _weights = State(initialValue: profile.configuration["weightsDirectory"] ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title).font(.headline)
            switch model {
            case .flux:
                Text("选择已安装的 Python、固定 MLX 运行时和 FLUX.3 Klein Q8 权重目录。").font(.callout)
                Form {
                    location("Python 可执行文件", path: $python, directory: false)
                    location("MLX 运行时", path: $runtime, directory: true)
                    location("Q8 权重", path: $weights, directory: true)
                }
            case .seedream:
                SecureField(profile.credentialReference == nil ? "北京方舟 API Key" : "替换已保存的 API Key", text: $credential)
                Text("凭证保存在本机钥匙串。每次生成前均需确认发送内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).foregroundStyle(.secondary).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(saving || (model == .seedream && credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && profile.credentialReference == nil))
            }
        }.padding(22).frame(width: 460).interactiveDismissDisabled(saving)
    }

    private func location(_ title: String, path: Binding<String>, directory: Bool) -> some View {
        HStack {
            TextField(title, text: path)
            Button("选择…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }.accessibilityLabel("选择" + title)
        }
    }

    private func save() {
        var configured = profile
        configured.acceptedForUse = true
        if model == .flux {
            configured.configuration["pythonExecutable"] = python
            configured.configuration["runtimeDirectory"] = runtime
            configured.configuration["weightsDirectory"] = weights
            do { try LocalFluxProvider.validateConfiguration(configured) }
            catch { issue = error.localizedDescription; return }
        }
        let secret = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await editing.saveProfile(configured, secret: secret.isEmpty ? nil : secret)
                credential = ""; dismiss()
            } catch { issue = "未能保存模型配置，请检查输入及钥匙串访问权限。" }
        }
    }
}

struct QuickPromptAreaOverlay: View {
    @ObservedObject var editing: EditingController
    let viewport: CGRect
    @State private var active: NormalizedCrop?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let region = active ?? selected {
                RoundedRectangle(cornerRadius: 2).fill(AppPalette.accent.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white, style: StrokeStyle(lineWidth: 1.3, dash: [5, 3])))
                    .frame(width: viewport.width * region.width, height: viewport.height * region.height)
                    .position(x: viewport.minX + viewport.width * (region.x + region.width / 2),
                              y: viewport.minY + viewport.height * (region.y + region.height / 2))
            }
            if editing.quickPromptSelecting {
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 3)
                    .onChanged { active = region($0) }
                    .onEnded { value in
                        defer { active = nil }
                        guard let crop = region(value), crop.width > 0.001, crop.height > 0.001 else { return }
                        editing.setQuickPromptScope(.rectangle(crop))
                    })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(editing.quickPromptSelecting)
        .accessibilityHidden(true)
        .onChange(of: editing.quickPromptSelecting) { _, new in if !new { active = nil } }
    }

    private var selected: NormalizedCrop? {
        if case .rectangle(let crop) = editing.quickPromptDraft.selection { return crop }
        return nil
    }

    private func region(_ value: DragGesture.Value) -> NormalizedCrop? {
        guard viewport.width > 0, viewport.height > 0, viewport.contains(value.startLocation) else { return nil }
        func fraction(_ value: CGFloat, min origin: CGFloat, size: CGFloat) -> Double { max(0, min(1, (value - origin) / size)) }
        let x1 = fraction(value.startLocation.x, min: viewport.minX, size: viewport.width)
        let y1 = fraction(value.startLocation.y, min: viewport.minY, size: viewport.height)
        let x2 = fraction(value.location.x, min: viewport.minX, size: viewport.width)
        let y2 = fraction(value.location.y, min: viewport.minY, size: viewport.height)
        return .init(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }
}
