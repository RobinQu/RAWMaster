import SwiftUI
import RAWMasterLibrary
import RAWMasterCore

struct SessionWorkflowHeader: View {
    @EnvironmentObject var model: AppModel
    let session: ImportSession
    var presentation: SessionWorkflowPresentation? = nil
    private var state: SessionWorkflowPresentation { presentation ?? model.sessionPresentation(session) }
    var body: some View {
        let state = self.state
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title).font(.system(size: 20, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .help(session.effectiveSourceURL.path)
                    Text(state.stageTitle).font(.caption.weight(.medium)).foregroundStyle(AppPalette.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(state.primaryTitle) { performPrimary() }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!state.primaryEnabled).accessibilityIdentifier("session.primary")
            }
            Text(state.batchSummary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("session.batchCounts")
            if state.hasCurrentTask {
                HStack(spacing: 10) {
                    if let done = state.activityCompleted, let total = state.activityTotal {
                        ProgressView(value: Double(done), total: Double(max(1, total))).frame(maxWidth: 220)
                        Text("\(done) / \(total)").font(.caption.monospacedDigit())
                    } else { ProgressView().controlSize(.small) }
                    if let message = state.activityMessage, !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            HStack(spacing: 15) {
                Button { model.regroup(sessionID: session.id) } label: { Label("重新扫描分组", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(state.regroupDisabledReason != nil).accessibilityIdentifier("session.regroup")
                    .help("只分析整批已核验素材，不重新扫描来源目录；保留人工调整过的拍摄组。")
                Spacer(minLength: 0)
                SessionAuxiliaryTools(session: session)
                Menu("会话操作") { SessionCatalogMenu(session: session, includesOpen: false, includesRegroup: false) }
            }.buttonStyle(.borderless).controlSize(.small)
            if let reason = state.regroupDisabledReason {
                Text("重新分组：" + reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("session.regroupReason")
            }
            if let outcome = state.groupingOutcomeText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(outcome).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("分组记录…") { model.openGroupHistory() }.buttonStyle(.borderless).controlSize(.small).disabled(model.isBusy)
                }.accessibilityIdentifier("session.groupingOutcome")
            }
        }.padding(.vertical, 12)
            .accessibilityElement(children: .contain).accessibilityLabel("整批会话操作")
    }
    private func performPrimary() {
        switch state.primaryAction {
        case .continueIntake: model.continueIntake(sessionID: session.id)
        case .pauseIntake, .cancelGrouping, .cancelQuality, .cancelPairing: model.cancelSessionTask()
        case .finish: model.prepareCompletion()
        case .openProject: model.openSessionProject(sessionID: session.id)
        }
    }
}

struct SessionAuxiliaryTools: View {
    @EnvironmentObject var model: AppModel
    let session: ImportSession
    private var currentScreening: Bool { model.scope == .session && model.scopeID == session.id && model.activeWorkflow?.phase == .screening }
    var body: some View {
        Menu("辅助工具") {
            Button("检查整批 RAW+JPEG 关联") { model.scanPairs() }.disabled(model.isBusy || !currentScreening)
            Button("查看当前范围的 RAW+JPEG 关联…") { model.showPairReview = true }.disabled(model.isBusy)
            Divider()
            Button("检查整批预览风险") { model.startQualityAnalysis(sessionID: session.id) }.disabled(model.isBusy || !currentScreening)
            Button("查看当前范围的风险证据…") { model.showQualityReview = true }.disabled(model.isBusy)
            Divider()
            Button("拍摄组操作记录…") { model.openGroupHistory() }.disabled(model.isBusy)
            Menu("本批初筛处置记录") {
                let commands = model.triageCommands.filter { $0.sessionID == session.id }
                if commands.isEmpty { Text("暂无初筛处置记录") }
                ForEach(commands.reversed()) { command in
                    Button("恢复 \(command.after.count) 个文件的处置 · \(command.id.prefix(6))\(command.restored ? "（已恢复）" : "")") { model.restoreTriageCommand(command.id) }
                        .disabled(command.restored || model.isBusy || !currentScreening)
                }
            }
            if model.automaticGroupingCommand != nil {
                Button("复核最近自动分组的撤销…") { model.previewAutomaticGroupingRestore() }.disabled(!model.canRestoreAutomaticGrouping)
            }
        }
    }
}

/// Browsing and selection remain separate from the whole-batch actions above.
struct TriageStatusStrip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { scopePicker; filterAndMode }
                VStack(alignment: .leading, spacing: 8) { scopePicker; filterAndMode }
            }
            if let group = model.activeTriageGroup {
                HStack(spacing: 12) {
                    GroupPropertiesButton(groupID: group.id)
                    GroupSelectionActionButton()
                    Spacer(minLength: 0)
                }.controlSize(.small)
                Text("正在查看“\(group.name)”；上方接入、重新分组和完成初筛均作用整批。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(AppPalette.accent.opacity(0.04))
    }
    private var scopePicker: some View {
        Picker("查看", selection: Binding(get: { model.triageGroupID ?? "" }, set: { model.selectTriageGroup($0.isEmpty ? nil : $0) })) {
            Text("整批素材").tag("")
            ForEach(model.triageSessionGroups, id: \.id) { group in Text(group.name).tag(group.id) }
        }.frame(minWidth: 170, idealWidth: 230, maxWidth: 260).controlSize(.small)
    }
    private var filterAndMode: some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: $model.triageFilter) {
                ForEach(AppModel.TriageFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 170).controlSize(.small)
            Spacer(minLength: 0)
            SessionBrowserModePicker()
        }
    }
}

struct SessionHistoryBrowsingControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Picker("记录筛选", selection: $model.triageFilter) {
                ForEach(AppModel.TriageFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 180).controlSize(.small)
            Spacer(minLength: 0)
            SessionBrowserModePicker()
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }
}

struct SessionBrowserModePicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Picker("浏览", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
            Image(systemName: "square.grid.2x2").tag(AppModel.BrowserMode.grid)
            Image(systemName: "rectangle").tag(AppModel.BrowserMode.single)
            Image(systemName: "rectangle.split.2x1").tag(AppModel.BrowserMode.compare)
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("浏览").frame(width: 120).help("网格 G · 单张 E · 比较 C")
    }
}

struct TriageDecisionBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Text(model.actionScopeLabel).font(.caption).foregroundStyle(.secondary)
            Button { model.setTriage(.passed) } label: { Label("通过", systemImage: "checkmark.circle") }.help("P · 允许进入项目，不设置精选或星级")
            Button { model.setTriage(.excluded) } label: { Label("排除", systemImage: "xmark.circle") }.help("X · 可恢复，不删除文件")
            Button { model.setTriage(.review) } label: { Label("需复核", systemImage: "questionmark.circle") }
            Button("清除处置") { model.setTriage(.pending) }.help("U")
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoCount == 0)
            Toggle("自动前进", isOn: $model.autoAdvance).toggleStyle(.checkbox).font(.caption)
        }.disabled(model.selectedIDs.isEmpty).buttonStyle(.borderless).padding(12).background(AppPalette.panel)
    }
}

struct HistoryActionBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            Label(model.activeWorkflow?.phase == .legacyHistory ? "旧版导入记录 · 初筛状态未知" : "已关闭 · 初筛记录只读", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("将所选未纳入文件恢复到项目") { model.restoreSelectedFromHistory() }
                .disabled(model.selectedIDs.isEmpty || model.isBusy)
        }.buttonStyle(.borderless).padding(12).background(AppPalette.panel)
    }
}

struct CompletionReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("完成整批初筛并纳入项目").font(.title2.weight(.semibold))
            if let preview = model.completionPreview {
                if let session = model.sessions.first(where: { $0.id == preview.sessionID }) {
                    Text(session.projectName).font(.headline)
                    Text("来源：\(session.effectiveSourceURL.lastPathComponent) · 整批 \(model.sessionBatchCounts(sessionID: session.id).fileCount) 个文件")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.activeTriageGroup != nil {
                        Text("此摘要覆盖整批，包含当前拍摄组以外的文件。").font(.caption).foregroundStyle(AppPalette.accent)
                    }
                }
                HStack(spacing: 26) {
                    count("纳入拍摄", preview.captureCount)
                    count("纳入文件", preview.admittedAssetIDs.count)
                    count("不纳入文件", preview.excludedAssetIDs.count)
                    count("仅序列用途", preview.sequenceOnlyAssetIDs.count)
                    count("纳入待复核", preview.reviewAssetIDs.count)
                }
                Text("未明确排除的正常素材将进入项目，保持未精筛、无新增评分。仅序列用途的文件不会自动成为单张精选。")
                    .font(.caption).foregroundStyle(.secondary)
                if let draft = model.sealDraft {
                    DisclosureGroup("核对每个原件的归档资格（\(draft.members.count) 个文件）") {
                        ImportSealReview(draft: Binding(get: { model.sealDraft ?? draft }, set: model.updateSealDraft))
                            .frame(height: 185)
                    }
                    if let failed = preview.failedAssetIDs, !failed.isEmpty { Text("仅保留失败历史　\(failed.count) 个文件").font(.caption) }
                }
                if !preview.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("以下问题需要先处理", systemImage: "exclamationmark.triangle").foregroundStyle(AppPalette.warning)
                        ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption) }
                        Text("可返回会话找回、重试异常文件，或明确排除不纳入本批的文件。") .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(AppPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                Toggle(isOn: Binding(get: { model.completionPreview?.manualAnalysisAcknowledged ?? false }, set: { model.acknowledgeManualCompletion($0) })) {
                    Text("我已复核本批初筛结果；自动分组为个人试用，预览证据不代表 RAW 质量验收；\(preview.unanalysedCount) 个文件尚无分析证据。")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }.toggleStyle(.checkbox)
                let excluded = Set(preview.excludedAssetIDs)
                let unverifiedCount = model.assets.filter { excluded.contains($0.id) && ($0.contentHash == nil || $0.importState != .ready) }.count
                if unverifiedCount > 0 {
                    Label("\(unverifiedCount) 个排除文件尚未完成接入核验，关闭后需通过新会话重新接入；其余已核验排除项可从导入历史恢复。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(AppPalette.warning).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("完成后会话移入导入历史，已核验的未纳入素材可从历史找回。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("此操作不移动或删除原片，也不表示已经备份。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
                HStack {
                    Button("返回初筛") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("纳入项目并关闭会话") { _ = model.completeTriage() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!preview.canCommit || model.isBusy)
                }
            } else {
                Text("摘要已失效，请返回会话重新预览。").foregroundStyle(AppPalette.warning)
                Button("返回初筛") { dismiss() }
            }
        }.padding(26).frame(width: 690)
    }
    private func count(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text("\(count)").font(.title2.monospacedDigit()) }
    }
}

struct QualityEvidenceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var evidence: [TriageQualityEvidence] { let ids = Set(model.scopedAssets.map(\.id)); return model.qualityEvidence.filter { ids.contains($0.assetID) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("预览风险证据").font(.title2.weight(.semibold))
            Text("这里只检查有限的预览亮暗与细节统计。低纹理不等于失焦，JPEG 过亮不等于 RAW 不可挽救；没有自动排除规则启用。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if evidence.isEmpty { Text("尚无证据，可返回会话运行检查。").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(evidence) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(model.assets.first { $0.id == entry.assetID }?.filename ?? entry.assetID).font(.caption.weight(.semibold))
                                Spacer(); Text(entry.status.displayTitle).font(.caption).foregroundStyle(entry.status == .risk ? AppPalette.warning : .secondary)
                            }
                            Text(entry.reasons.joined(separator: " · ")).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Text("\(entry.source) · \(entry.methodVersion)").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }.padding(10).background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.frame(minHeight: 180, maxHeight: 370)
            HStack {
                if model.isTriageScope { Button("将未保护风险文件标为需复核") { model.applyRiskReview() }.disabled(!evidence.contains { $0.status == .risk }) }
                Spacer(); Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 690)
    }
}

extension TriageQualityStatus {
    var displayTitle: String { switch self { case .risk: return "疑似风险 · 需复核"; case .clear: return "未触发有限风险"; case .unknown: return "无法判断"; case .unsupported: return "未支持"; case .error: return "文件或读取异常" } }
}

struct CapturePairReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [CapturePair] = []
    private var pairs: [CapturePair] { model.capturePairs.filter(model.confirmsPairScope) }
    private func refreshCandidates() {
        do { candidates = try (model.store?.capturePairCandidates(sessionID: model.scope == .session ? model.scopeID : nil) ?? []).filter(model.confirmsPairScope) }
        catch { model.errorMessage = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RAW + JPEG 关联").font(.title2.weight(.semibold))
            Text("自动关联仅接受同目录、同基名及拍摄证据相容的唯一组合。未关联不代表文件缺失；歧义可返回网格明确选中一个 RAW 和一个 JPEG 后手动确认。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("待核对的拍摄关联").font(.headline)
                            ForEach(candidate.assetIDs, id: \.self) { id in Text(model.assets.first { $0.id == id }?.filename ?? id).font(.caption) }
                            if model.canMaintainPairs {
                                HStack {
                                    Button("确认同一次拍摄") { model.confirmPair(rawID: candidate.rawAssetID, jpegID: candidate.jpegAssetID); refreshCandidates() }
                                    Button("忽略候选") {
                                        do { try model.store?.dismissCapturePairCandidate(candidate); refreshCandidates() }
                                        catch { model.errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                    ForEach(pairs) { pair in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(pair.assetIDs, id: \.self) { id in Text(model.assets.first { $0.id == id }?.filename ?? id).font(.caption) }
                                Text(model.pairHasConflict(pair) ? "已有决定不一致 · 保持展开，原值未覆盖" : (pair.isManual ? "人工确认" : "拍摄证据关联")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.canMaintainPairs { Button("解除关联") { model.unlinkPair(pair.id) } }
                        }.padding(10).background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if pairs.isEmpty { Text("当前没有已确认的 RAW+JPEG 组合。").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 150, maxHeight: 340)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(AppPalette.warning) }
            HStack {
                if model.canMaintainPairs { Button("将当前所选两个文件确认为组合") { model.confirmSelectedPair() }.disabled(model.selectedIDs.count != 2) }
                Spacer(); Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 690)
        .onAppear { refreshCandidates() }
    }
}

struct PairPreviewControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let id = model.focusedID, let pair = model.pair(for: id), model.collapses(pair) {
            HStack {
                Text("组合预览").font(.caption).foregroundStyle(.secondary)
                Button("相机 JPEG") { model.setPreviewRAW(false) }
                Button("RAW 预览 / 细节") { model.setPreviewRAW(true) }
                if let asset = model.focusedAsset { Text("当前：\(model.previewAsset(for: asset).filename)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("展开两个文件") { model.togglePair(pair) }
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 7)
        }
    }
}

struct WorkflowAssetTile: View {
    @EnvironmentObject var model: AppModel
    let asset: AssetRecord
    let compact: Bool
    var sequenceMemberships: [CaptureGroup] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            AssetCard(asset: asset, selected: model.selectedIDs.contains(asset.id), compact: compact,
                      previewAsset: model.previewAsset(for: asset), triageDisposition: (model.isTriageScope || model.isHistoryScope) ? model.disposition(of: asset.id) : nil)
                .overlay(CardInputLayer(onPress: { model.select(asset, modifiers: $0) }, onDoubleClick: { model.select(asset); model.setMode(.single) }))
                .accessibilityAddTraits(.isButton).accessibilityAction { model.select(asset) }
            if let pair = model.pair(for: asset.id) {
                HStack(spacing: 3) {
                    Text(!model.pairIsEntirelyVisible(pair) ? "伴随文件未纳入 · 单文件" : (model.pairHasConflict(pair) ? "RAW+JPEG · 决定冲突" : "RAW+JPEG")).lineLimit(1)
                    Spacer(minLength: 1)
                    if model.collapses(pair) || model.expandedPairIDs.contains(pair.id) {
                        Button(model.collapses(pair) ? "展开 2" : "收起") { model.togglePair(pair) }.buttonStyle(.plain)
                    }
                }.font(.system(size: compact ? 8 : 10)).foregroundStyle(model.pairHasConflict(pair) ? AppPalette.warning : .secondary).padding(.horizontal, 5)
            }
            AdditionalSequenceMemberships(groups: sequenceMemberships, compact: compact)
        }.contextMenu { BrowserAssetContextMenu(asset: asset) }
    }
}

// Project tag editing is implemented by BatchTagEditor in SearchReviewViews.swift.
