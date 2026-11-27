import SwiftUI
import RAWMasterCore
import RAWMasterImaging
import RAWMasterLibrary

@MainActor final class SceneWorkflowBatchCoordinator: ObservableObject {
    @Published private(set) var result: SceneWorkflowBatch.Review?
    private(set) var runningID: UUID?
    @Published private(set) var problem: String?
    @Published private(set) var accepting = true
    @Published private(set) var running = false
    private var worker: Task<Void, Never>?
    private var cancelPendingOnStop = false

    func openLatest(in store: LibraryStore) async {
        guard !running else { return }
        do {
            let latest = try await Task.detached { try store.latestSceneWorkflow().map { try store.sceneWorkflow(id: $0.id) } }.value
            if !running { result = latest; problem = nil }
        } catch { problem = error.localizedDescription }
    }
    func start(_ review: SceneWorkflowBatch.Review, in store: LibraryStore) {
        execute(review.header.id, store: store, register: review)
    }
    func resume(_ id: UUID, in store: LibraryStore) {
        execute(id, store: store)
    }
    func retry(_ id: UUID, in store: LibraryStore) {
        execute(id, store: store, retry: true)
    }
    func undo(_ id: UUID, in store: LibraryStore) {
        mutate(id) { try store.undoSceneWorkflow(id) }
    }
    func cancel(_ id: UUID, in store: LibraryStore) {
        guard accepting else { return }
        if runningID == id { stopPending() }
        else { mutate(id) { try store.cancelSceneWorkflow(id) } }
    }
    func stopPending() {
        guard accepting, let worker else { return }
        cancelPendingOnStop = true
        worker.cancel()
    }
    func stopAndJoin() async {
        accepting = false
        let active = worker
        active?.cancel()
        await active?.value
    }
    func reopenAdmission() { accepting = true }

    private func begin(_ id: UUID) -> Bool {
        guard accepting, !running else { return false }
        runningID = id; running = true; problem = nil; cancelPendingOnStop = false
        return true
    }
    private func finish() {
        runningID = nil; running = false; worker = nil; cancelPendingOnStop = false
    }
    private func mutate(_ id: UUID, operation: @escaping @Sendable () throws -> SceneWorkflowBatch.Review) {
        guard begin(id) else { return }
        worker = Task { [self] in
            defer { finish() }
            do { result = try await Task.detached(priority: .utility, operation: operation).value }
            catch { problem = error.localizedDescription }
        }
    }

    private func execute(_ id: UUID, store: LibraryStore, register: SceneWorkflowBatch.Review? = nil, retry: Bool = false) {
        guard begin(id) else { return }
        if let register { result = register }
        worker = Task { [weak self] in
            defer { self?.finish() }
            let native = Task.detached(priority: .utility) {
                if let register { try store.registerSceneWorkflow(register) }
                try Task.checkCancellation()
                let review = try retry ? store.retrySceneWorkflow(id) : store.sceneWorkflow(id: id)
                await MainActor.run { self?.result = review }
                var qualified = Set<String>()
                for item in review.items where item.state == .pending {
                    let fingerprint = item.source?.contentSHA256
                    let cached = fingerprint.map(qualified.contains) == true
                    let row = try await ProcessingAdmission.shared.withPermit(.library, resources: .init(cpu: 1, io: 1)) {
                        try store.commitSceneWorkflowItem(id, assetID: item.id, cancel: { try Task.checkCancellation() }) { source in
                            if !cached { try SceneWorkflowRawQualification.verify(source) }
                        }
                    }
                    if let fingerprint, row.state == .completed { qualified.insert(fingerprint) }
                    await MainActor.run {
                        guard let self, let current = self.result, current.header.id == id,
                              let slot = current.items.firstIndex(where: { $0.id == row.id }) else { return }
                        var list = current.items; list[slot] = row
                        self.result = .init(header: current.header, items: list)
                    }
                }
                return try store.sceneWorkflow(id: id)
            }
            do { self?.result = try await withTaskCancellationHandler { try await native.value } onCancel: { native.cancel() } }
            catch is CancellationError {
                let shouldCancel = self?.cancelPendingOnStop == true
                do {
                    self?.result = try await Task.detached {
                        try shouldCancel ? store.cancelSceneWorkflow(id) : store.sceneWorkflow(id: id)
                    }.value
                }
                catch { self?.problem = error.localizedDescription }
            } catch { self?.problem = error.localizedDescription }
        }
    }
}

struct SceneWorkflowBatchSheet: View {
    let store: LibraryStore
    let ids: [String]
    let donor: String?
    let showResults: Bool
    var batchID: UUID? = nil
    @ObservedObject var coordinator: SceneWorkflowBatchCoordinator
    let export: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results = false
    @State private var preparing = false
    @State private var basis = SceneWorkflowBatch.Basis.current
    @State private var chosen = "source"
    @State private var donorGraph: DevelopmentSceneGraphV1?
    @State private var templates: [SceneWorkflowTemplate] = []
    @State private var review: SceneWorkflowBatch.Review?
    @State private var selectedReview: SceneWorkflowBatch.Review?
    @State private var historical = false
    @State private var preview: DevelopmentScenePreviewFrameV1?
    @State private var problem: String?
    @State private var prepareTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(results ? "工作流批次与撤销" : "批量工作流预检").font(.headline)
            if results { resultContent }
            else if let review { reviewContent(review) }
            else { form }
            if let failure = problem ?? coordinator.problem { Text(failure).foregroundStyle(AppPalette.warning).font(.caption) }
        }.padding(17).frame(minWidth: 370, idealWidth: 560, minHeight: 315, idealHeight: 570)
         .task {
             results = showResults
             if let batchID {
                 do { selectedReview = try await Task.detached { try store.sceneWorkflow(id: batchID) }.value }
                 catch { problem = error.localizedDescription }
             } else if results { await coordinator.openLatest(in: store) }
             else {
                 do {
                     let values = try await Task.detached { (try donor.flatMap(store.sceneWorkflowDonor), try store.sceneWorkflowTemplates()) }.value
                     donorGraph = values.0; templates = values.1
                     if donorGraph == nil, let first = templates.first { chosen = first.id.uuidString }
                 } catch { problem = error.localizedDescription }
             }
         }
         .task(id: displayedResult?.header.id) {
             if let id = displayedResult?.header.id {
                 historical = (try? store.isHistoricalTask(.sceneWorkflow, id: id.uuidString)) != false
             }
         }
         .onDisappear { prepareTask?.cancel() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("焦点照片提供来源。其余 \(max(0, ids.count - 1)) 张为目标，确认前不写任何版本。")
            Picker("操作", selection: $chosen) {
                if firstExposure != nil { Text("仅同步节点曝光").tag("exposure") }
                if donorGraph != nil { Text("源照片整个工作流").tag("source") }
                ForEach(templates) { item in Text(item.name).tag(item.id.uuidString) }
                if donorGraph == nil, templates.isEmpty { Text("没有可用的场景图或模板").tag("source") }
            }
            Picker("目标底稿", selection: $basis) {
                Text("每张当前场景图").tag(SceneWorkflowBatch.Basis.current)
                Text("从原片创建分支").tag(SceneWorkflowBatch.Basis.original)
            }
            Text(basis == .current ? "现有非场景配方不会转换。" : "从原片求值，不带目标当前调整。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if preparing { ProgressView().controlSize(.small) }
                Button("核对将发生的变化", action: prepare).buttonStyle(.borderedProminent)
                    .disabled(preparing || ids.count < 2 || work == nil).accessibilityIdentifier("scene.batch.review")
            }
        }
    }
    private func reviewContent(_ review: SceneWorkflowBatch.Review) -> some View {
        let ready = review.items.filter { $0.state == .pending }.count
        return VStack(alignment: .leading, spacing: 7) {
            Text("来源：\(review.header.donorName) · 可创建 \(ready)/\(review.items.count) 张")
            Text("只创建候选，不自动采用。执行前核验原片字节与校准。")
                .font(.caption).foregroundStyle(.secondary)
            if let preview {
                HStack {
                    SceneBatchPreviewImage(frame: preview).frame(width: 100, height: 66)
                    Text("首张可用照片的 SDR 派生样例").font(.caption).foregroundStyle(.secondary)
                }
            }
            itemList(review.items)
            HStack {
                Button("返回预检") { self.review = nil; preview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认创建批量版本") { results = true; coordinator.start(review, in: store) }
                    .buttonStyle(.borderedProminent).disabled(ready == 0 || !coordinator.accepting || coordinator.running)
                    .accessibilityIdentifier("scene.batch.confirm")
            }
        }
    }
    private var displayedResult: SceneWorkflowBatch.Review? {
        if let batchID { return coordinator.result?.header.id == batchID ? coordinator.result : selectedReview }
        return coordinator.result
    }
    @ViewBuilder private var resultContent: some View {
        if let result = displayedResult {
            let items = result.items, successes = items.filter { $0.state == .completed }
            let id = result.header.id
            let active = coordinator.runningID == id
            let pending = items.contains { $0.state == .pending }
            Text(result.header.donorName).foregroundStyle(.secondary)
            Text("已创建 \(successes.count)/\(items.count) 张 · " + (historical ? "副本历史" : active ? "正在处理" : pending ? "等待继续" : "本轮已结束"))
            itemList(items)
            HStack {
                Button("返回选片") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if active { Button("取消待处理项") { coordinator.stopPending() }.disabled(!coordinator.accepting) }
                else {
                    Menu("更多") {
                        if pending {
                            Button("继续") { coordinator.resume(id, in: store) }
                            Button("取消待处理项") { coordinator.cancel(id, in: store) }
                        }
                        Button("重试未完成项") { coordinator.retry(id, in: store) }.disabled(!items.contains { $0.state.retryable })
                        Button("撤销成功项") { coordinator.undo(id, in: store) }.disabled(successes.isEmpty)
                    }.disabled(historical || !coordinator.accepting || coordinator.running)
                    Button("导出成功候选") {
                        let versions = Dictionary(uniqueKeysWithValues: successes.compactMap { item in item.candidate.map { (item.id, $0) } })
                        dismiss(); export(versions)
                    }.disabled(successes.isEmpty)
                }
            }
        } else if batchID != nil, problem == nil {
            ProgressView("正在读取批次…")
        } else {
            ContentUnavailableView("没有工作流批次", systemImage: "square.stack.3d.up")
            Button("返回选片") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
    private func itemList(_ items: [SceneWorkflowBatch.Item]) -> some View {
        List(items) { item in
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(item.name).lineLimit(1); Spacer(); Text(title(item.state)).foregroundStyle(.secondary) }
                if let reason = item.reason { Text(reason).foregroundStyle(AppPalette.warning) }
                if let id = item.candidate { Text("候选 · " + id.prefix(8)).foregroundStyle(.secondary) }
                else if let parent = item.parent { Text("冻结底稿 · " + parent.prefix(8)).foregroundStyle(.secondary) }
                else if item.recipe != nil { Text("原片底稿").foregroundStyle(.secondary) }
            }.font(.caption)
        }.frame(minHeight: 155, idealHeight: 270)
    }
    private var firstExposure: Float? {
        if case let .corrector(_, _, ev, _, _, _)? = donorGraph?.graph.nodes.first(where: { if case .corrector = $0.operation { return true }; return false })?.operation { return ev }
        return nil
    }
    private var work: SceneWorkflowBatch.Work? {
        if chosen == "exposure", let firstExposure { return .exposure(firstExposure) }
        if chosen == "source", let donorGraph, let template = try? SceneWorkflowTemplate(name: "源照片工作流", kind: .whole, scope: donorGraph.graph) { return .apply(template) }
        return templates.first(where: { $0.id.uuidString == chosen }).map(SceneWorkflowBatch.Work.apply)
    }
    private func prepare() {
        guard let work, let donor else { return }
        preparing = true
        let selectedBasis = basis, targets = ids.filter { $0 != donor }
        prepareTask = Task {
            defer { preparing = false; prepareTask = nil }
            do {
                let plan = try await Task.detached { try store.reviewSceneWorkflow(donorID: donor, targets: targets, work: work, basis: selectedBasis) }.value
                try Task.checkCancellation()
                if let sample = plan.items.first(where: { $0.state == .pending }), let original = sample.source, let graph = sample.recipe?.sceneGraph {
                    preview = try? await DevelopmentScenePreviewV1().render(source: original, graph: graph, view: .init(), target: .sdr709, sampling: .fit(maximumEdge: 192))
                }
                try Task.checkCancellation()
                review = plan
            } catch is CancellationError {} catch { problem = error.localizedDescription }
        }
    }
    private func title(_ state: SceneWorkflowBatch.State) -> String {
        switch state {
        case .pending: return "待处理"
        case .offline: return "离线"
        case .incompatible: return "不兼容"
        case .conflict: return "修订冲突"
        case .completed: return "已创建候选"
        case .cancelled: return "已取消"
        case .undone: return "已撤销"
        case .failed: return "失败"
        }
    }
}

private struct SceneBatchPreviewImage: View {
    let frame: DevelopmentScenePreviewFrameV1
    @State private var texture: CGImage?
    var body: some View {
        Group {
            if let texture { Image(decorative: texture, scale: 1).resizable().scaledToFit() }
            else { ProgressView().controlSize(.small) }
        }.task(id: frame.id) {
            texture = try? await Task.detached { try SceneWorkflowRawQualification.sharePreview(frame) }.value
        }
    }
}
