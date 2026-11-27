import SwiftUI
import RAWMasterCore
import RAWMasterLibrary

struct WorkbenchActivityWindow: View {
    enum Tab: String, CaseIterable, Identifiable {
        case notices, tasks, logs
        var id: Self { self }
        var label: String { switch self { case .notices: "通知"; case .tasks: "任务"; case .logs: "日志" } }
    }
    @ObservedObject var model: AppModel
    @ObservedObject var activity: WorkbenchLibraryActivity
    @ObservedObject private var applicationLog = WorkbenchApplicationLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.notices
    @FocusState private var tabsFocused: Bool

    init(model: AppModel) { self.model = model; activity = model.activity }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.libraryURL.deletingLastPathComponent().lastPathComponent)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                AppIconButton(systemName: "xmark", label: "关闭后台信息") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("workbench.activity.close")
            }
            Picker("后台信息栏目", selection: $tab) {
                ForEach(Tab.allCases) { section in Text(section.label).tag(section).accessibilityIdentifier("workbench.activity." + section.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().focused($tabsFocused)
            .accessibilityIdentifier("workbench.activity.tabs")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    switch tab {
                    case .notices:
                        if activity.notices.isEmpty { empty("当前资料库暂无通知") }
                        ForEach(activity.notices.reversed()) { notice in
                            let error = notice.kind == .error
                            row(symbol: error ? "exclamationmark.triangle" : "info.circle", title: notice.text,
                                detail: [error ? "错误" : "信息", notice.photoName ?? (notice.assetID == nil ? "资料库" : "照片"),
                                         notice.date.formatted(date: .abbreviated, time: .standard)].joined(separator: " · "))
                        }
                    case .tasks:
                        WorkbenchActivityTasks(model: model, workflow: model.sceneWorkflowBatches)
                    case .logs:
                        let logs = (applicationLog.entries + activity.logs).sorted { $0.date > $1.date }
                        if logs.isEmpty { empty("暂无应用日志") }
                        ForEach(logs) { entry in
                            row(symbol: entry.error ? "exclamationmark.triangle" : "waveform.path.ecg", title: entry.message,
                                detail: [entry.source, entry.error ? "错误" : "信息", entry.date.formatted(date: .abbreviated, time: .standard)].joined(separator: " · "))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("workbench.activity.list." + tab.rawValue)
        }
        .padding(18).frame(minWidth: 350, idealWidth: 445, minHeight: 270, idealHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbench.activity.window")
        .onAppear { tabsFocused = true }
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).textSelection(.enabled)
                Text(detail).foregroundStyle(.secondary).font(.caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + "，" + detail)
        .accessibilityAddTraits(.isStaticText)
    }

    private func empty(_ text: String) -> some View { Text(text).foregroundStyle(.secondary) }
}

struct WorkbenchActivityTask: Identifiable, Equatable {
    enum Detail: Identifiable, Equatable {
        case delivery(String), ai(String)
        var id: String { switch self { case .delivery(let id): "delivery." + id; case .ai(let id): "ai." + id } }
    }
    let id, name, status: String
    let active: Bool
    var detail: Detail? = nil

    @MainActor static func live(_ model: AppModel) -> [Self] {
        var rows = [Self]()
        if let task = model.progress {
            let counts = task.total > 0 ? "\(task.completed) / \(task.total)" : ""
            rows.append(.init(id: "progress", name: task.title,
                status: [counts, task.message, task.isRunning ? "处理中" : "已结束"].filter { !$0.isEmpty }.joined(separator: " · "), active: task.isRunning))
        }
        if model.qualityAnalysisRunning {
            rows.append(.init(id: "quality", name: "质量检查", status: model.qualityAnalysisMessage, active: true))
        }
        if model.timelapseIsRunning {
            let progress = model.timelapseComposer?.progress
            rows.append(.init(id: "timelapse", name: "延时视频",
                status: progress.map { "\($0.phase.title) · \($0.completed) / \($0.total)" } ?? "准备中", active: true))
        }
        if model.externalEditorPreparing {
            rows.append(.init(id: "external", name: "外部编辑", status: "准备输入文件", active: true))
        }
        if let batch = model.workbenchPhotoDelivery {
            let id = batch.id.uuidString.lowercased()
            rows.append(.init(id: "delivery." + id, name: "导出成片", status: "\(batch.completed) / \(batch.total) · " + (batch.message ?? (batch.running ? "正在交付" : "已结束")),
                active: batch.running, detail: .delivery(id)))
        }
        let flow = model.sceneWorkflowBatches
        if let review = flow.result {
            let pending = review.items.filter { $0.state == .pending }.count
            rows.append(.init(id: "workflow." + review.header.id.uuidString, name: "工作流批量处理",
                status: "\(review.items.count - pending) / \(review.items.count) · " + (flow.problem ?? (flow.running ? "处理中" : (pending > 0 ? "等待继续" : "已结束"))), active: flow.running))
        } else if flow.running {
            rows.append(.init(id: "workflow", name: "工作流批量处理", status: "正在准备", active: true))
        }
        if let services = model.editingServices {
            if services.busy { rows.append(.init(id: "runtime", name: "本机 AI 运行时",
                status: services.setupSnapshot?.message ?? services.runtimeStateTitle, active: true)) }
            let flux = services.fluxModel
            if flux.isBusy || flux.status == .paused || flux.status == .failed {
                let state = flux.status == .verifying ? "正在校验" : (flux.status == .downloading ? "下载中" : (flux.status == .paused ? "已暂停" : "下载失败"))
                rows.append(.init(id: "model", name: "本地模型", status: state + " · " + flux.progress.formatted(.percent.precision(.fractionLength(0))), active: flux.isBusy))
            }
        }
        for job in model.editing?.jobs ?? [] {
            rows.append(.init(id: "ai." + job.id, name: job.request.quickPrompt == nil ? "AI 编辑" : "快速 Prompt",
                status: job.state.editingTitle, active: !job.state.isTerminal && job.state != .outcomeUnknown, detail: .ai(job.id)))
        }
        return rows
    }

    static func catalog(_ database: URL, store: LibraryStore?) async throws -> [Self] {
        var rows = try await WorkbenchDeliveryCatalog(database: database).history().map {
            Self(id: "delivery." + $0.id, name: "导出成片", status: "\($0.itemCount) 张照片 · " + $0.phase.title,
                 active: $0.phase == .running, detail: .delivery($0.id))
        }
        if let store {
            let renders = try await Task.detached(priority: .utility) { try store.loadRenderedExports() }.value
            for record in renders.reversed() {
                rows.append(.init(id: "render." + record.id, name: "成片导出",
                    status: record.targetURL.lastPathComponent + " · " + record.state.nativeTitle,
                    active: record.state == .queued || record.state == .prepared))
            }
            let groups = try await store.catalogActions.read("groupProcessing", ["action": .string("list")])
            for item in groups["jobs"]?.arrayValue ?? [] {
                guard let id = item["jobID"]?.stringValue, let phase = item["state"]?.stringValue else { continue }
                let states = ["queued":"等待处理", "preparing":"正在准备", "rendering":"正在处理", "staged":"等待归档",
                              "published":"已完成", "failed":"处理失败", "cancelled":"已取消", "stale":"需要重试"]
                rows.append(.init(id: "group." + id, name: "分组制作",
                    status: states[phase] ?? phase, active: ["queued","preparing","rendering","staged"].contains(phase)))
            }
        }
        return rows
    }
}

private struct WorkbenchActivityTasks: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workflow: SceneWorkflowBatchCoordinator
    @State private var stored: [WorkbenchActivityTask] = []
    @State private var problem: String?
    @State private var detail: WorkbenchActivityTask.Detail?

    var body: some View {
        // The timer refreshes only this open tab, including producers outside the editing controller.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let live = WorkbenchActivityTask.live(model)
            let ids = Set(live.map(\.id))
            let storedIDs = Set(stored.map(\.id))
            let rows = live.map { item in
                var row = item
                if case .delivery = row.detail, !storedIDs.contains(row.id) { row.detail = nil }
                return row
            } + stored.filter { !ids.contains($0.id) }
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if rows.isEmpty { Text("当前资料库暂无后台任务").foregroundStyle(.secondary) }
            ForEach(rows.filter(\.active) + rows.filter { !$0.active }) { task in
                HStack {
                    Image(systemName: task.active ? "clock" : "checklist").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.name)
                        Text(task.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let target = task.detail { Button("查看详情") { detail = target }.controlSize(.small) }
                }
            }
        }
        .task(id: model.workbenchPhotoDelivery?.running) {
            while !Task.isCancelled {
                do {
                    let rows = try await WorkbenchActivityTask.catalog(model.libraryURL, store: model.store)
                    try Task.checkCancellation()
                    stored = rows; problem = nil
                } catch is CancellationError { return }
                catch { problem = "无法读取资料库任务。\(error.localizedDescription)" }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(item: $detail) { target in
            switch target {
            case .delivery(let id): WorkbenchDeliveryHistory(initial: id).environmentObject(model)
            case .ai(let id):
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("生成任务").font(.headline)
                        Spacer()
                        Button("返回") { detail = nil }.keyboardShortcut(.cancelAction)
                    }
                    if let editing = model.editing, let job = editing.jobs.first(where: { $0.id == id }) {
                        EditingJobSummary(editing: editing, job: job)
                    } else { Text("这项任务已不可用。") }
                }
                .padding(16).frame(minWidth: 360)
            }
        }
    }
}
