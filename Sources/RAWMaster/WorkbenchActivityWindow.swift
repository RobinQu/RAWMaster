import AppKit
import SwiftUI
import RAWMasterAI
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
                        WorkbenchActivityTasks(model: model, workflow: model.sceneWorkflowBatches,
                            originals: model.originalDelivery, returnToWorkbench: { dismiss() })
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
        .onAppear { showRequestedTasks(); tabsFocused = true }
        .onChange(of: activity.tasksRequested) { _, _ in showRequestedTasks() }
    }

    private func showRequestedTasks() {
        if activity.consumeTasksRequest() { tab = .tasks; tabsFocused = true }
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
        case intake(String), delivery(String), originals(String), ai(String), workflow(UUID)
        var id: String {
            switch self {
            case .intake(let id): "intake." + id
            case .delivery(let id): "delivery." + id
            case .originals(let id): "originals." + id
            case .ai(let id): "ai." + id
            case .workflow(let id): "workflow." + id.uuidString
            }
        }
    }
    let id, name, status: String
    let active: Bool
    var detail: Detail? = nil
    var device = false

    @MainActor static func live(_ model: AppModel) -> [Self] {
        var rows = [Self]()
        if let id = model.runningImportSessionID, let task = model.progress {
            let target = Detail.intake(id)
            let session = model.sessions.first { $0.id == id }
            let current = task.total > 0 ? "\(task.completed) / \(task.total)" : ""
            rows.append(.init(id: target.id, name: session.map { "导入 · " + $0.projectName } ?? "导入",
                status: [current, task.message, "处理中"].filter { !$0.isEmpty }.joined(separator: " · "),
                active: true, detail: target))
        } else if let task = model.progress {
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
        if let id = model.originalDelivery.activeID {
            let detail = Detail.originals(id)
            let progress = model.originalDelivery.progress
            let counts = progress.map { $0.total > 0 ? "\($0.completed) / \($0.total)" : "" }
            rows.append(.init(id: detail.id, name: progress?.title ?? "原件交付",
                status: [counts, progress?.message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                active: true, detail: detail))
        }
        let flow = model.sceneWorkflowBatches
        if let review = flow.result, flow.runningID == review.header.id {
            rows.append(workflow(review.header.id, states: review.items.map(\.state), active: true, historical: false, problem: flow.problem))
        } else if flow.running {
            rows.append(.init(id: "workflow", name: "工作流批量处理", status: "正在准备", active: true))
        }
        if let services = model.editingServices {
            if services.busy { rows.append(.init(id: "runtime", name: "本机 AI 运行时",
                status: services.setupSnapshot?.message ?? services.runtimeStateTitle, active: true, device: true)) }
            let flux = services.fluxModel
            if flux.isBusy || flux.status == .paused || flux.status == .failed {
                let state = flux.status == .verifying ? "正在校验" : (flux.status == .downloading ? "下载中" : (flux.status == .paused ? "已暂停" : "下载失败"))
                rows.append(.init(id: "model", name: "FLUX 本机模型", status: state + " · " + flux.progress.formatted(.percent.precision(.fractionLength(0))),
                                  active: flux.isBusy, device: true))
            }
        }
        if let editing = model.editing {
            for job in editing.jobs {
                rows.append(processing(job, historical: editing.isHistoricalProcessing(job)))
            }
        }
        return rows
    }

    static func catalog(_ database: URL, store: LibraryStore?) async throws -> [Self] {
        guard let store else { return [] }
        var rows = try await WorkbenchDeliveryCatalog(database: database).history().map {
            Self(id: "delivery." + $0.id, name: "导出成片", status: "\($0.itemCount) 张照片 · " + $0.phase.title,
                 active: $0.phase == .running, detail: .delivery($0.id))
        }
        let stored = try await Task.detached(priority: .utility) {
            let imports = try store.loadSessions().reversed().map {
                try intake($0, historical: store.isHistoricalTask(.importSession, id: $0.id))
            }
            let workflows = try store.sceneWorkflowTaskHistory().map { header, states, historical in
                workflow(header.id, states: states, active: false, historical: historical)
            }
            let processing = try store.loadProcessingJobs().reversed().map {
                try Self.processing($0, historical: store.isHistoricalTask(.flux, id: $0.id))
            }
            let renders = try store.loadRenderedExports().reversed().map { record in
                let historical = try store.isHistoricalTask(.renderedExport, id: record.id)
                return Self(id: "render." + record.id, name: "成片导出",
                    status: [record.targetURL.lastPathComponent, record.state.nativeTitle, historical ? "副本历史" : nil].compactMap { $0 }.joined(separator: " · "),
                    active: !historical && (record.state == .queued || record.state == .prepared))
            }
            let originals = try store.originalDeliveryHistory().map { job in
                let detail = Detail.originals(job.id)
                let phase = job.historical ? job.phase.title + " · 副本历史" : job.phase.title
                return Self(id: detail.id, name: job.title, status: "\(job.completed) / \(job.total) · " + phase,
                            active: false, detail: detail)
            }
            return imports + workflows + processing + renders + originals
        }.value
        rows.append(contentsOf: stored)
        let groups = try await store.catalogActions.read("groupProcessing", ["action": .string("list")])
        for item in groups["jobs"]?.arrayValue ?? [] {
            guard let id = item["jobID"]?.stringValue, let phase = item["state"]?.stringValue else { continue }
            let states = ["queued":"等待处理", "preparing":"正在准备", "rendering":"正在处理", "staged":"等待归档",
                          "published":"已完成", "failed":"处理失败", "cancelled":"已取消", "stale":"需要重试"]
            rows.append(.init(id: "group." + id, name: "分组制作",
                status: states[phase] ?? phase, active: ["queued","preparing","rendering","staged"].contains(phase)))
        }
        return rows
    }

    private static func intake(_ session: ImportSession, historical: Bool) -> Self {
        let detail = Detail.intake(session.id)
        let phase = ["scanning", "importing", "paused"].contains(session.status) ? "已暂停，可继续" : session.statusTitle
        let status = ["\(session.completed) / \(session.discovered)", phase, historical ? "副本历史" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return .init(id: detail.id, name: "导入 · " + session.projectName, status: status, active: false, detail: detail)
    }

    private static func workflow(_ id: UUID, states: [SceneWorkflowBatch.State], active: Bool, historical: Bool, problem: String? = nil) -> Self {
        let detail = Detail.workflow(id)
        let count = states.filter { $0 == .completed }.count
        let status = historical ? "副本历史" : active ? "处理中" : states.contains(.pending) ? "已暂停，可继续" : "本轮已结束"
        return .init(id: detail.id, name: "工作流批量处理",
            status: "已创建 \(count) / \(states.count) 张 · " + (problem ?? status), active: active, detail: detail)
    }

    private static func processing(_ job: ProcessingJob, historical: Bool) -> Self {
        let detail = Detail.ai(job.id)
        let name = LocalFluxProvider.matches(job.request.profile) ? "FLUX 生成" : job.request.quickPrompt == nil ? "AI 编辑" : "快速 Prompt"
        let phase = historical ? job.state.editingTitle + " · 副本历史" : job.state.editingTitle
        return .init(id: detail.id, name: name, status: phase,
            active: !historical && !job.state.isTerminal && job.state != .outcomeUnknown, detail: detail)
    }
}

private struct WorkbenchActivityTasks: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workflow: SceneWorkflowBatchCoordinator
    @ObservedObject var originals: OriginalDeliveryCoordinator
    let returnToWorkbench: () -> Void
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
            if rows.isEmpty { Text("当前资料库暂无制作任务").foregroundStyle(.secondary) }
            ForEach(rows.filter(\.active) + rows.filter { !$0.active }) { task in
                HStack {
                    Image(systemName: task.active ? "clock" : "checklist").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.name)
                        Text(task.device ? "设备 · " + task.status : task.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let target = task.detail {
                        Button("查看详情") { detail = target }.controlSize(.small).disabled(model.isLibraryTransitioning)
                            .accessibilityIdentifier("workbench.activity.task." + task.id)
                    } else if task.device {
                        Button("打开本机 AI 设置") { model.openApplicationSettings(.localAI) }.controlSize(.small)
                    }
                }
            }
        }
        .task(id: refreshKey) {
            while !Task.isCancelled {
                guard !model.isLibraryTransitioning else { return }
                do {
                    let rows = try await WorkbenchActivityTask.catalog(model.libraryURL, store: model.store)
                    try Task.checkCancellation()
                    stored = rows; problem = nil
                } catch is CancellationError { return }
                catch { problem = "无法读取资料库任务。\(error.localizedDescription)" }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .sheet(item: $detail) { target in
            switch target {
            case .intake(let id):
                WorkbenchImportTaskDetail(model: model, id: id) {
                    model.openCatalogSession(id: id)
                    detail = nil; returnToWorkbench()
                }
            case .delivery(let id): WorkbenchDeliveryHistory(initial: id).environmentObject(model)
            case .originals(let id):
                WorkbenchOriginalDeliveryTaskDetail(model: model, coordinator: originals, id: id)
            case .workflow(let id):
                if let store = model.store {
                    SceneWorkflowBatchSheet(store: store, ids: [], donor: nil, showResults: true, batchID: id, coordinator: workflow) {
                        detail = nil; returnToWorkbench()
                        model.prepareLibraryExport(.workflowBatch(versions: $0))
                    }
                }
            case .ai(let id):
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("生成任务").font(.headline)
                        Spacer()
                        Button("返回") { detail = nil }.keyboardShortcut(.cancelAction)
                    }
                    if let editing = model.editing, let job = editing.jobs.first(where: { $0.id == id }) {
                        Text(model.assetFilename(job.request.source.assetID) + " · 版本 " + job.request.inputVersionID.prefix(8))
                            .font(.caption).foregroundStyle(.secondary)
                        EditingJobSummary(editing: editing, job: job)
                        if let versionID = job.resultVersionID {
                            Button("查看候选") {
                                if editing.work?.id == job.request.workID, model.isNativeEditing {
                                    editing.showSavedResults(versionID)
                                    detail = nil; returnToWorkbench()
                                } else {
                                    do {
                                        guard let version = try model.store?.editingVersion(id: versionID), let artifact = version.artifact else {
                                            throw EditingError.missingVersion
                                        }
                                        NSWorkspace.shared.open(try editing.archive.artifactURL(artifact))
                                    } catch {
                                        model.errorMessage = "无法打开候选文件。\(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                    } else { Text("正在读取生成记录，或制作档案暂不可用。") }
                }
                .padding(16).frame(minWidth: 360)
            }
        }
        .disabled(model.isLibraryTransitioning)
    }

    private var refreshKey: String {
        [String(model.isLibraryTransitioning), String(model.workbenchPhotoDelivery?.running == true),
         String(model.runningImportSessionID != nil), String(workflow.running), originals.activeID ?? ""].joined(separator: "|")
    }
}

private struct WorkbenchOriginalDeliveryTaskDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: OriginalDeliveryCoordinator
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var job: OriginalDeliveryJob?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(job?.title ?? "原件交付").font(.headline)
                Spacer()
                Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let job, let store = model.store {
                let active = coordinator.activeID == id
                let progress = active ? coordinator.progress : nil
                Text(job.historical ? job.phase.title + " · 副本历史" : progress?.message ?? job.phase.title)
                Text("已处理 \(progress?.completed ?? job.completed) / \(progress?.total ?? job.total) 项")
                    .foregroundStyle(.secondary)
                Text(job.destinationPath).textSelection(.enabled).lineLimit(3)
                if !active, let error = job.error {
                    Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled)
                } else if !active, !job.report.errors.isEmpty {
                    Text(job.report.errors.joined(separator: "\n")).font(.caption).foregroundStyle(AppPalette.warning)
                        .lineLimit(4).textSelection(.enabled)
                }
                HStack {
                    if !job.report.manifestPath.isEmpty, !job.historical {
                        Button("在 Finder 中显示清单") {
                            let manifest = URL(fileURLWithPath: job.report.manifestPath)
                            NSWorkspace.shared.activateFileViewerSelecting([manifest, manifest.deletingPathExtension().appendingPathExtension("csv")])
                        }
                    }
                    Spacer()
                    if !job.historical && job.phase != .completed {
                        if job.phase != .cancelled || active { Button("取消任务") { coordinator.cancel(id, store: store) } }
                        if !active && job.phase.canResume {
                            Button("选择原输出目录…") { chooseDestination(store) }
                            Button(job.phase == .failed ? "重试未完成项" : "继续") { coordinator.resume(id, store: store) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }.disabled(model.isLibraryTransitioning || (coordinator.activeID != nil && !active))
            } else if failure == nil {
                ProgressView("读取交付记录…")
            }
            if let failure { Text(failure).foregroundStyle(AppPalette.warning).font(.caption) }
        }
        .padding(18).frame(minWidth: 410, idealWidth: 540)
        .task(id: coordinator.activeID) {
            guard let store = model.store, !model.isLibraryTransitioning else { return }
            do {
                let current = try await Task.detached(priority: .utility) { try store.originalDeliveryJob(id: id) }.value
                try Task.checkCancellation()
                job = current; failure = nil
            } catch is CancellationError {
            } catch {
                if coordinator.activeID != id { failure = coordinator.error ?? error.localizedDescription }
            }
        }
    }

    private func chooseDestination(_ store: LibraryStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url, !model.isLibraryTransitioning {
            coordinator.resume(id, store: store, destination: url)
        }
    }
}

private struct WorkbenchImportTaskDetail: View {
    @ObservedObject var model: AppModel
    let id: String
    let openSession: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceAvailable: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("导入任务").font(.headline)
                Spacer()
                Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let session = model.sessions.first(where: { $0.id == id }) {
                let historical = (try? model.store?.isHistoricalTask(.importSession, id: id)) != false
                let active = model.runningImportSessionID == id
                Text(session.projectName)
                Text("已接入 \(session.completed) / \(session.discovered) · \(session.failed) 项异常")
                Text(session.effectiveSourceURL.path).textSelection(.enabled)
                if let directory = session.managedContainerURL {
                    Text("复制目标 · " + directory.path).textSelection(.enabled)
                }
                if historical { Text("副本历史").foregroundStyle(.secondary) }
                else if active, let progress = model.progress { Text(progress.message).foregroundStyle(.secondary) }
                else if sourceAvailable == false, session.status != "completed" { Text("原来源离线。连接原设备或从导入会话接回来源。").foregroundStyle(AppPalette.warning) }
                else if ["scanning", "importing", "paused"].contains(session.status) { Text("已暂停，可继续").foregroundStyle(.secondary) }
                else { Text(session.statusTitle).foregroundStyle(.secondary) }
                HStack {
                    Button("查看导入会话", action: openSession)
                    Spacer()
                    if active {
                        Button("取消") { model.cancelSessionTask() }.disabled(model.sessionTask?.isCancelling == true)
                    } else if !historical, session.status != "completed" {
                        Button(["failed", "partial", "cancelled"].contains(session.status) ? "重试未完成项" : "继续") {
                            model.continueIntake(sessionID: id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canContinueIntake(sessionID: id) || sourceAvailable == false)
                    }
                }
                .task(id: session.effectiveSourceURL) {
                    let path = session.effectiveSourceURL.path
                    while !Task.isCancelled {
                        sourceAvailable = await Task.detached(priority: .utility) {
                            var directory: ObjCBool = false
                            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
                        }.value
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    }
                }
            } else {
                Text("这项导入已不可用。").foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(minWidth: 370, idealWidth: 470)
        .accessibilityIdentifier("workbench.activity.import")
    }
}
