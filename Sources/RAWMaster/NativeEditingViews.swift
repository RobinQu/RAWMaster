import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct NativeEditingInspector: View {
    @ObservedObject var editing: EditingController
    @State private var basicExpanded = true
    @State private var curvesExpanded = false
    @State private var gradingExpanded = false
    @State private var geometryExpanded = false
    @State private var exactCropExpanded = false
    @State private var confirmedSceneMode: EditingSceneModeChange?
    var body: some View {
        VStack(spacing: EditingLayout.panelSpacing) {
            if editing.stage == .development, editing.work != nil, !editing.loading {
                Group {
                    if editing.recipe.sceneGraph != nil {
                        EditingSceneGraphToolbar(editing: editing)
                    } else if EditingCompatibilityGraphPanel.isEnabled {
                        EditingCompatibilityGraphToolbar(editing: editing)
                    }
                }
                .frame(maxWidth: .infinity)
                .floatingSelectionSurface()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editing.rail.nodes")
            }
            inspector
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .floatingSelectionSurface()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editing.rail.parameters")
        }
        .environment(\.developmentNumberInputOwner, editing.developmentNumberInputOwner)
        // The compatibility adjustment context is suspended while this sheet has the key window.
        .sheet(item: $editing.sceneModeConfirmation, onDismiss: {
            if let change = confirmedSceneMode, editing.sceneTicket == change.ticket {
                editing.sceneModeFocusRequest = change.mode
            }
            confirmedSceneMode = nil
        }) { change in
            EditingSceneModeConfirmation(editing: editing, change: change)
                .onAppear { confirmedSceneMode = change }
        }
        .onChange(of: editing.stage) { _, _ in editing.previewContextChanged() }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            if editing.stage != .development {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing.asset?.filename ?? "选择一张照片")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Picker("编辑阶段", selection: $editing.stage) {
                        ForEach(EditingController.Stage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("editing.stage")
                }.padding(14)
                Divider()
            }
            if editing.stage == .development, editing.work != nil, !editing.loading {
                if let graph = editing.recipe.sceneGraph {
                    EditingSceneInspector(editing: editing, graph: graph)
                } else {
                    PhotosDevelopmentInspector(editing: editing)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if editing.sourceNeedsRevalidation {
                            Button(editing.revalidatingSource ? "正在验证原片…" : "重新验证原片") { editing.revalidatePreviewSource() }
                                .disabled(editing.revalidatingSource).accessibilityIdentifier("editing.revalidate")
                        }
                        if editing.loading { ProgressView("准备照片…") }
                        else if editing.work == nil {
                            Text("选择资料库中可用的照片开始制作。").foregroundStyle(.secondary)
                        } else {
                            switch editing.stage {
                            case .development: development.disabled(!editing.sourceReady)
                            case .ai: ai
                            case .versions: versions
                            }
                        }
                    }.font(.system(size: 12)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if editing.stage != .development {
                Divider()
                bottomActions.padding(14)
            }
        }
    }
    private var development: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(editing.isDirty ? "初修草稿 · 未保存" : "原片初修", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("全部复位") { editing.resetRecipe(nativeEvent: true) }.buttonStyle(.borderless)
            }
            Text("从原片显影；保存后成为独立版本。").font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $basicExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionReset { editing.resetDevelopmentSection(.basic, nativeEvent: true) }
                    DevelopmentBasicAdjustments(editing: editing)
                }.padding(.top, 8)
            } label: { adjustmentTitle("基础调整", changed: editing.recipe.exposureEV != 0 || editing.recipe.whiteBalance != .asShot || !editing.developmentColor.tones.isNeutral) }
            .accessibilityIdentifier("editing.basic")
            .onChange(of: basicExpanded) { _, expanded in if !expanded { editing.endPreviewInteractions(prefix: "tone."); editing.endPreviewInteractions(prefix: "whiteBalance."); editing.endPreviewInteractions(prefix: "exposure") } }
            DisclosureGroup(isExpanded: $curvesExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionReset { editing.resetDevelopmentSection(.curves, nativeEvent: true) }
                    DevelopmentCurveEditor(editing: editing)
                }.padding(.top, 8)
            } label: { adjustmentTitle("曲线", changed: editing.developmentColor.curves != DevelopmentCurves()) }
            .accessibilityIdentifier("editing.curves")
            .onChange(of: curvesExpanded) { _, expanded in if !expanded { editing.endPreviewInteractions(prefix: "curve.") } }
            DisclosureGroup(isExpanded: $gradingExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionReset { editing.resetDevelopmentSection(.grading, nativeEvent: true) }
                    DevelopmentGradingEditor(editing: editing)
                }.padding(.top, 8)
            } label: { adjustmentTitle("色彩分级", changed: editing.developmentColor.grading != DevelopmentColorGrading()) }
            .accessibilityIdentifier("editing.grading")
            .onChange(of: gradingExpanded) { _, expanded in if !expanded { editing.endPreviewInteractions(prefix: "grading.") } }
            DisclosureGroup(isExpanded: $geometryExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                HStack { Spacer(); Button("复位") { editing.setRecipe(nativeEvent: true) { $0.straightenDegrees = 0; $0.crop = .init() } }.buttonStyle(.borderless).font(.caption) }
                labeledValue("角度 °", value: recipeBinding(\.straightenDegrees), range: -45...45)
                Toggle("在照片上调整裁切", isOn: $editing.cropEditing).toggleStyle(PhotosFlatCheckboxStyle())
                    .onChange(of: editing.cropEditing) { _, _ in editing.setActualPixels(false); editing.previewContextChanged() }
                HStack {
                    Text("比例").foregroundStyle(.secondary)
                    Menu("选择") {
                        Button("完整画面") { editing.setRecipe(control: "crop-aspect", nativeEvent: true) { $0.crop = .init() } }
                        Button("正方形") { editing.applyCropAspect(1, nativeEvent: true) }
                        Button("3:2") { editing.applyCropAspect(1.5, nativeEvent: true) }
                        Button("4:3") { editing.applyCropAspect(4.0 / 3, nativeEvent: true) }
                        Button("16:9") { editing.applyCropAspect(16.0 / 9, nativeEvent: true) }
                    }.frame(maxWidth: .infinity)
                }
                DisclosureGroup("精确数值", isExpanded: $exactCropExpanded) {
                    VStack(spacing: 8) {
                        cropNumber("左边", keyPath: \.x)
                        cropNumber("上边", keyPath: \.y)
                        cropNumber("宽度", keyPath: \.width)
                        cropNumber("高度", keyPath: \.height)
                    }.padding(.top, 6)
                }
                Text("裁切比例按拉直后的可用画面计算；边缘会裁去旋转空白。").font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 8)
            } label: { Text("裁切与拉直").font(.system(size: 12, weight: .semibold)) }
            .accessibilityIdentifier("editing.geometry")
            .onChange(of: geometryExpanded) { _, expanded in
                if !expanded && editing.cropEditing { editing.cropEditing = false; editing.requestPreview() }
            }
            Divider()
            Label("未添加额外镜头配置", systemImage: "camera.aperture").font(.caption).foregroundStyle(.secondary)
            Text("RAW 解码使用系统默认处理；尚未验证独立镜头配置。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func adjustmentTitle(_ title: String, changed: Bool) -> some View {
        HStack { Text(title).font(.system(size: 12, weight: .semibold)); if changed { Text("已调整").font(.caption2).foregroundStyle(.secondary) } }
    }
    private func sectionReset(_ action: @escaping () -> Void) -> some View {
        HStack { Spacer(); Button("复位此组", action: action).font(.caption).buttonStyle(.borderless) }
    }
    private func recipeBinding(_ path: WritableKeyPath<DevelopmentRecipe, Double>) -> Binding<Double> {
        Binding(get: { editing.recipe[keyPath: path] }, set: { value in editing.setRecipe(nativeEvent: true) { $0[keyPath: path] = value } })
    }
    private func labeledValue(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 52, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: { editing.previewInteractionChanged(title, active: $0, nativeEvent: true) }).accessibilityLabel(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder).frame(width: 64)
        }
    }
    private func cropNumber(_ title: String, keyPath: WritableKeyPath<NormalizedCrop, Double>) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            TextField(title + "百分比", value: Binding(get: { editing.recipe.crop[keyPath: keyPath] * 100 }, set: { value in
                editing.setCropValue(keyPath, value: value / 100, nativeEvent: true)
            }), format: .number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder).frame(width: 76)
            Text("%").foregroundStyle(.secondary)
        }
    }
    private var ai: some View {
        VStack(alignment: .leading, spacing: 14) {
            inputPicker
            if editing.isDirty {
                Label("初修草稿尚未保存", systemImage: "exclamationmark.circle").foregroundStyle(AppPalette.warning)
                Text("先保存初修版本，再将它作为 AI 输入。").font(.caption).foregroundStyle(.secondary)
                Button("保存初修版本") { editing.saveDevelopment() }.disabled(editing.saving)
            }
            Picker("编辑意图", selection: Binding(get: { "custom" }, set: { value in
                if value == "natural" { editing.prompt = "自然增强照片，保留主体、构图与真实细节。" }
                if value == "cinema" { editing.prompt = "采用克制的电影调色，保留人物身份、几何、文字和自然细节。" }
            })) {
                Text("选择提示配方…").tag("custom"); Text("自然增强").tag("natural"); Text("电影调色").tag("cinema")
            }
            Text("编辑描述").font(.caption.weight(.semibold))
            TextEditor(text: $editing.prompt).font(.system(size: 12)).frame(minHeight: 110, maxHeight: 180)
                .padding(4).background(AppPalette.thumbnailWell).overlay(RoundedRectangle(cornerRadius: 5).stroke(AppPalette.boundary))
                .accessibilityLabel("AI 编辑描述").accessibilityIdentifier("editing.prompt")
            Picker("执行位置", selection: $editing.selectedProfileID) {
                ForEach(editing.profiles) { profile in Text(profile.displayName).tag(Optional(profile.id)) }
            }.accessibilityIdentifier("editing.location")
            if let profile = editing.selectedProfile {
                VStack(alignment: .leading, spacing: 7) {
                    Label(profile.kind == .localComfy ? "本机执行" : "云端执行", systemImage: profile.kind == .localComfy ? "desktopcomputer" : "cloud")
                        .font(.caption.weight(.medium))
                    Text("模型：" + profile.model).font(.caption).textSelection(.enabled)
                    if profile.kind != .localComfy {
                        Text("上传目标：" + (profile.endpoint.host ?? profile.endpoint.absoluteString)).font(.caption).textSelection(.enabled)
                        Text("仅上传此输入版本的渲染图。可能产生费用；本次费用未知。").font(.caption2).foregroundStyle(.secondary)
                    } else { Text("输入图像保留在本机。首次使用需要受管运行包与模型。").font(.caption2).foregroundStyle(.secondary) }
                    if !profile.acceptedForUse {
                        Text("此配置尚未启用或通过实际编辑验收。请在设置中核对后启用。").font(.caption).foregroundStyle(AppPalette.warning)
                    }
                    if profile.experimental { Text("实验配置 · 使用前核对模型许可与输出限制。").font(.caption2).foregroundStyle(AppPalette.warning) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
            }
            Button("配置 AI 服务与本机环境…") { editing.showSettings = true }.buttonStyle(.borderless)
            if let job = editing.jobs.first(where: { $0.request.workID == editing.work?.id && !$0.state.isTerminal }) {
                EditingJobSummary(editing: editing, job: job)
            }
            if let completed = editing.jobs.first(where: { $0.request.workID == editing.work?.id && $0.resultVersionID != nil }),
               let candidate = editing.versions.first(where: { $0.id == completed.resultVersionID }) {
                Button("查看已保存的候选") { editing.stage = .versions; editing.selectVersion(candidate) }
            }
        }
    }
    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("输入版本", selection: Binding(get: { editing.selectedVersionID }, set: { id in
                if let version = editing.versions.first(where: { $0.id == id }) { editing.selectVersion(version) }
            })) {
                ForEach(editing.versions.filter { editing.dispositions[$0.id] != .discarded }) { version in
                    Text(version.editingTitle + " · " + version.shortID).tag(Optional(version.id))
                }
            }.accessibilityIdentifier("editing.inputVersion")
            if let pixels = editing.selectedVersion?.artifact {
                Text("源版本 \(pixels.pixelWidth) × \(pixels.pixelHeight) · \(pixels.colorSpace)").font(.caption2).foregroundStyle(.secondary)
            }
            Text("提交前另存不超过约 1MP 的 PNG / sRGB 输入，不上传 RAW；完整版本仍可导出。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var versions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择版本只改变查看内容；采用需要明确确认。").font(.caption).foregroundStyle(.secondary)
            ForEach(editing.versions.sorted { $0.createdAt > $1.createdAt }) { version in
                VStack(alignment: .leading, spacing: 7) {
                    Button { editing.selectVersion(version) } label: {
                        HStack(alignment: .top) {
                            Image(systemName: version.kind == .original ? "camera" : "photo")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(version.editingTitle + " · " + version.shortID).font(.system(size: 12, weight: .medium))
                                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if editing.work?.adoptedVersionID == version.id { Label("采用", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(AppPalette.keep) }
                            else if editing.dispositions[version.id] == .discarded { Text("已放弃").font(.caption2).foregroundStyle(.secondary) }
                            else { Text("候选").font(.caption2).foregroundStyle(AppPalette.accent) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("editing.version." + version.id)
                    if let parent = version.parentVersionID { Text("父版本：" + String(parent.prefix(6))).font(.caption2).foregroundStyle(.secondary) }
                    if let artifact = version.artifact {
                        Text("\(artifact.pixelWidth) × \(artifact.pixelHeight) · \(artifact.bitDepth) 位 · \(artifact.colorSpace)").font(.caption2).foregroundStyle(.secondary)
                        if !artifact.resamplingChain.isEmpty { Text("经过重采样：" + artifact.resamplingChain.joined(separator: " → ")).font(.caption2).foregroundStyle(AppPalette.warning) }
                    }
                    if editing.selectedVersionID == version.id {
                        HStack {
                            Button("从此继续") { editing.continueFrom(version) }
                            Menu {
                                if editing.dispositions[version.id] == .discarded { Button("恢复候选") { editing.disposition(version, .candidate) } }
                                else {
                                    Button("保留候选") { editing.disposition(version, .retained) }
                                    if version.id != editing.work?.adoptedVersionID && version.kind != .original { Button("放弃候选") { editing.disposition(version, .discarded) } }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22)
                        }.font(.caption).buttonStyle(.borderless)
                        DisclosureGroup("来源详情") {
                            ForEach(version.configuration.keys.sorted(), id: \.self) { key in
                                Text(key + "：" + (version.configuration[key] ?? "")).font(.caption2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(10).background(editing.selectedVersionID == version.id ? AppPalette.accent.opacity(0.09) : AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(editing.selectedVersionID == version.id ? AppPalette.accent.opacity(0.5) : .clear))
            }
            Button("关联外部编辑结果…") { editing.associateExternalResult() }.disabled(editing.saving)
        }
    }
    @ViewBuilder private var bottomActions: some View {
        let context = editing.developmentContext
        VStack(spacing: 9) {
            if editing.stage == .development {
                Button { if let context { editing.saveDevelopment(context: context) } } label: { Label(editing.saving ? "正在保存…" : "保存初修版本", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(editing.work == nil || !editing.sourceReady || editing.saving || editing.developmentAnalysisBusy || context == nil)
                    .accessibilityIdentifier("editing.saveDevelopment")
            } else if editing.stage == .ai {
                Button { editing.generate() } label: { Label(editing.saving ? "准备输入…" : "生成候选", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(!editing.canGenerate)
                    .accessibilityIdentifier("editing.generate")
            }
            if let version = editing.displayedSavedVersion {
                if version.id != editing.work?.adoptedVersionID {
                    Button("采用此版本") { editing.adopt(version) }.disabled(editing.saving || !editing.canAdoptDisplayVersion(version))
                        .accessibilityIdentifier("editing.adopt")
                } else {
                    Label(editing.isDisplayingDevelopmentDraft ? "草稿与当前采用版本一致" : "当前采用版本", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if editing.work != nil && editing.isDisplayingDevelopmentDraft {
                Text("保存草稿后可采用该初修版本").font(.caption).foregroundStyle(.secondary)
            }
        }.controlSize(.regular)
    }
}

struct EditingJobSummary: View {
    @ObservedObject var editing: EditingController
    let job: ProcessingJob
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(job.state.editingTitle).font(.caption.weight(.semibold))
                Spacer()
                if !job.state.isTerminal && job.state != .outcomeUnknown { ProgressView().controlSize(.small) }
            }
            Text(job.request.profile.displayName + " · " + job.request.profile.model).font(.caption2).foregroundStyle(.secondary)
            Text("实际输入 \(job.request.inputArtifact.pixelWidth) × \(job.request.inputArtifact.pixelHeight) · \(job.request.inputArtifact.bitDepth) 位 · \(job.request.inputArtifact.colorSpace)").font(.caption2).foregroundStyle(.secondary)
            if let quick = job.request.quickPrompt {
                DisclosureGroup("快速 Prompt · \(quick.selection == nil ? "整张当前构图" : "局部范围")") {
                    Text(job.request.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let receipt = job.currentAttempt.receivedOutput?.configuration, let count = receipt["usage.generated_images"] {
                        Text("方舟回执 · 生成 \(count) 张 · \(receipt["usage.output_tokens"] ?? "—") 输出 tokens")
                            .foregroundStyle(.secondary)
                    } else if job.request.profile.kind == .seedream {
                        Text(job.currentAttempt.submissionIntentAt == nil ? "尚未提交方舟" : "方舟用量待核对").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
            if let text = editing.jobMessages[job.id]?.message { Text(text).font(.caption2).foregroundStyle(.secondary) }
            if let error = job.currentAttempt.error { Text(error).font(.caption2).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
            HStack {
                if editing.canResumeSaving(job), !job.state.isTerminal {
                    Button("恢复保存") { editing.resumeSaving(job) }
                    Text("不会重新提交生成").font(.caption2).foregroundStyle(.secondary)
                } else if job.state == .outcomeUnknown {
                    Button("核对结果") { editing.reconcile(job) }
                    if job.currentAttempt.workerJoined && job.request.quickPrompt == nil { Button("重新生成…") { editing.unknownRetryJobID = job.id } }
                } else if (job.state == .failed || job.state == .cancelled) && job.currentAttempt.workerJoined && job.request.quickPrompt == nil {
                    Button("重试") { editing.retry(job) }
                } else if !job.state.isTerminal && job.state != .cancelRequested {
                    Button("取消") { editing.cancel(job) }
                }
                if job.request.quickPrompt != nil && job.request.workID == editing.work?.id {
                    Button("回到本张 Prompt") { editing.reopenQuickPromptTask(job) }.disabled(!editing.canOpenQuickPrompt)
                }
                if job.resultVersionID != nil { Text("结果保留为候选").font(.caption2).foregroundStyle(.secondary) }
            }.font(.caption).buttonStyle(.borderless)
            ForEach(job.attempts.filter { $0.id != job.currentAttempt.id && $0.resultVersionID == nil && ($0.receivedOutput != nil || $0.pendingReceivedOutput != nil) }) { attempt in
                HStack {
                    Text("较早尝试 \(attempt.number) · 结果待保存").font(.caption2).foregroundStyle(.secondary)
                    Button("恢复保存") { editing.resumeSaving(job, attemptID: attempt.id) }.font(.caption).buttonStyle(.borderless)
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("editing.job." + job.id)
    }
}

struct EditingJobsSheet: View {
    @ObservedObject var editing: EditingController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("制作任务与导出").font(.title2.weight(.semibold)); Spacer(); Button("完成") { editing.showJobs = false }.keyboardShortcut(.cancelAction) }
            Text("任务独立于当前照片。结果保存后仍需检查并明确采用。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if editing.jobs.isEmpty && editing.renderedExports.isEmpty { Text("暂无单张制作任务或导出记录").foregroundStyle(.secondary).padding(.vertical, 24) }
                    WorkbenchDeliveryHistoryList()
                    ForEach(editing.jobs) { job in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("照片 " + String(job.request.source.assetID.prefix(8)) + " · " + job.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            EditingJobSummary(editing: editing, job: job)
                        }
                    }
                    if !editing.renderedExports.isEmpty {
                        Divider().padding(.vertical, 4)
                        HStack { Text("成片导出").font(.headline); Spacer(); Button("核对导出") { editing.reconcileExports() }.font(.caption) }
                        ForEach(editing.renderedExports) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(record.targetURL.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(record.state.nativeTitle).font(.caption).foregroundStyle(record.state == .succeeded ? AppPalette.keep : AppPalette.warning)
                                }
                                Text("版本 " + String(record.versionID.prefix(6)) + " · " + record.format.rawValue).font(.caption2).foregroundStyle(.secondary)
                                Text(record.targetURL.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                if let error = record.error { Text(error).font(.caption2).foregroundStyle(AppPalette.warning) }
                                if record.state == .succeeded { Button("在 Finder 中显示") { editing.revealExport(record) }.font(.caption).buttonStyle(.borderless) }
                                else { Button(record.state == .cancelled ? "核对状态" : "核对并恢复保存") { editing.reconcileExports() }.font(.caption).buttonStyle(.borderless) }
                            }.padding(10).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                }
            }
        }.padding(22).frame(width: 580, height: 580)
    }
}

extension RenderedExportState {
    var nativeTitle: String {
        switch self { case .queued: return "等待渲染"; case .prepared: return "准备发布"; case .succeeded: return "已导出"; case .needsAttention: return "需要核对"; case .cancelled: return "已取消" }
    }
}
