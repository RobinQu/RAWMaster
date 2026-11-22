import RAWMasterCore
import RAWMasterImaging
import SwiftUI

@MainActor
struct PresetLensBlurReconstructionControls: View {
    struct Ticket: Hashable {
        let id: String
        let version: Int
        let context: EditingInteractionContext
        let revision: UUID
    }

    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let catalog: DevelopmentPresetCatalog
    let record: DevelopmentPresetRecord
    let ticket: Ticket

    @State private var assessment: PresetLensBlurAssessment?
    @State private var prepared: DevelopmentPresetRecord?
    @State private var task: Task<Void, Never>?
    @State private var message = ""

    private var isCurrent: Bool {
        editing.developmentContext == ticket.context && session.context == ticket.context && session.revision == ticket.revision
            && editing.work?.id == ticket.context.workID && editing.work?.source.contentSHA256 == ticket.context.sourceContentID
            && editing.stage == .development && editing.isPresented && editing.sourceReady && session.activeGesture == nil
            && !editing.developmentShowingOriginal && !editing.actualPixels && !editing.cropEditing && !editing.comparing
    }
    private var hasDepth: Bool { session.parameters.effects?.lensBlur?.renderDepth != nil }
    private var canPrepare: Bool { isCurrent && (hasDepth || editing.supportsSceneDepth) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch assessment {
            case .unavailable(let reason):
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            case .approximate(let plan):
                Text("在「效果 › 镜头模糊」中以圆形散景近似。沿用本张已有的深度、焦点和修边；首次使用时估算深度并识别焦点。四点焦段、高光阈值和猫眼缩放使用本机行为。")
                    .font(.caption2).foregroundStyle(.secondary)
                if !hasDepth && !editing.supportsSceneDepth {
                    Text("缺少本机场景深度模型。").font(.caption2).foregroundStyle(.secondary)
                } else if let prepared {
                    HStack {
                        Button("主图试看") { editing.previewDevelopmentPreset(prepared, context: ticket.context, explicit: true) }
                            .accessibilityIdentifier("editing.presets.previewDepth")
                            .disabled(!isCurrent)
                        Button("确认采用近似") {
                            guard isCurrent, editing.hoveredPresetID == prepared.id, editing.filterHoverFrame != nil else { return }
                            do {
                                try session.adoptPreset(prepared, context: ticket.context, revision: ticket.revision)
                                cancel()
                            } catch { message = error.localizedDescription }
                        }
                        .accessibilityIdentifier("editing.presets.adoptDepth")
                        .disabled(!isCurrent || editing.hoveredPresetID != prepared.id || editing.filterHoverFrame == nil)
                    }
                } else if task == nil {
                    Button("准备本张散景近似") { prepare(plan) }
                        .accessibilityIdentifier("editing.presets.prepareDepth").disabled(!canPrepare)
                } else {
                    ProgressView("正在准备本张深度和焦点…").controlSize(.small)
                }
                if task != nil || prepared != nil { Button("取消") { cancel() } }
            case nil: EmptyView()
            }
            if !message.isEmpty { Text(message).font(.caption2).foregroundStyle(.secondary) }
        }
        .controlSize(.small)
        .task {
            do {
                let store = catalog, row = record
                let value = try await Task.detached(priority: .userInitiated) {
                    try DevelopmentPresetExchange.lensBlurAssessment(for: row, catalog: store)
                }.value
                if !Task.isCancelled { assessment = value }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
        .onChange(of: isCurrent) { _, current in if !current { cancel() } }
        .onDisappear { cancel() }
    }

    private func prepare(_ plan: PresetLensBlurReconstruction) {
        guard canPrepare, task == nil, let source = editing.work?.source else { return }
        editing.cancelPresetHover()
        let baseline = session.recipe, seed = session.parameters.effects?.lensBlur
        let depth = editing.sceneDepthEngine, subjects = editing.subjectAnalysis
        message = ""
        task = Task { @MainActor in
            defer { if !Task.isCancelled { task = nil } }
            do {
                let scene = seed?.renderDepth == nil ? try await depth.estimate(source) : nil
                try Task.checkCancellation()
                guard isCurrent, editing.work?.source == source else { return }
                let focus = seed == nil ? try await subjects.focus(for: source) : nil
                try Task.checkCancellation()
                guard isCurrent, editing.work?.source == source else { return }
                prepared = try plan.prepare(record: record, baseline: baseline, sourceID: source.contentSHA256, scene: scene,
                    focus: focus.map { .init(x: $0.focusX, y: $0.focusY) }, focusRange: focus?.focusRange)
            } catch { if !Task.isCancelled && isCurrent { message = "本张散景未准备好。\(error.localizedDescription)" } }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        prepared = nil
        if editing.developmentContext == ticket.context, editing.hoveredPresetID == record.id { editing.cancelPresetHover() }
    }
}
