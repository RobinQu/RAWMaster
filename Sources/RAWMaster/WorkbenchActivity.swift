import Combine
import CryptoKit
import Foundation
import OSLog
import RAWMasterCore

struct WorkbenchLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let source: String
    let message: String
    let error: Bool
}

/// Only explicit, public lifecycle events are copied to the system log. Photo names,
/// prompts, paths, credentials and the contents of errors stay out of this channel.
@MainActor final class WorkbenchApplicationLog: ObservableObject {
    static let shared = WorkbenchApplicationLog()
    @Published private(set) var entries: [WorkbenchLogEntry]
    private let logger = Logger(subsystem: "io.robinqu.RAWMaster", category: "workbench")
    private let defaults: UserDefaults
    private let storageKey = "workbench.applicationLog.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([WorkbenchLogEntry].self, from: $0) } ?? []
    }

    func event(_ message: String) {
        entries.append(record(source: "应用", message: message))
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
    }

    func record(source: String, message: String, error: Bool = false) -> WorkbenchLogEntry {
        logger.log(level: error ? .error : .info, "\(source, privacy: .public) · \(message, privacy: .public)")
        return .init(id: UUID(), date: Date(), source: source, message: message, error: error)
    }
}

@MainActor final class WorkbenchLibraryActivity: ObservableObject {
    private struct Archive: Codable {
        var notices: [EditingWorkspaceNotice] = []
        var logs: [WorkbenchLogEntry] = []
    }
    @Published private(set) var notices: [EditingWorkspaceNotice]
    @Published private(set) var logs: [WorkbenchLogEntry]
    private let defaults: UserDefaults
    private let key: String
    private var subscriptions: Set<AnyCancellable> = []
    private var jobSubscription: AnyCancellable?

    init(libraryURL: URL, libraryID: String?, defaults: UserDefaults) {
        self.defaults = defaults
        // A replaced database at the same location and a separate copy of a catalog have independent histories.
        let identity = (libraryID ?? "") + "|" + libraryURL.standardizedFileURL.resolvingSymlinksInPath().path
        key = "workbench.activity.v1." + SHA256.hash(data: Data(identity.utf8)).description
        let archive = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
        notices = archive.notices
        logs = archive.logs
    }

    func add(_ notice: EditingWorkspaceNotice) {
        notices = Array(notices.suffix(199)) + [notice]
        persist()
    }

    func log(_ source: String, _ summary: String, error: Bool = false) {
        let entry = WorkbenchApplicationLog.shared.record(source: source, message: summary, error: error)
        logs = Array(logs.suffix(199)) + [entry]
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Archive(notices: notices, logs: logs)) { defaults.set(data, forKey: key) }
    }

    func observe(_ model: AppModel) {
        log("工作台", model.store == nil ? "打开资料库失败" : "已打开资料库", error: model.store == nil)
        struct Phase: Equatable { let key: String; let running: Bool }
        model.$progress.compactMap { item -> Phase? in
            item.map { Phase(key: $0.title, running: $0.isRunning) }
        }.removeDuplicates().sink { [weak self] state in
            self?.log("资料库", state.running ? "后台作业已开始" : "后台作业已结束")
        }.store(in: &subscriptions)
        model.$workbenchPhotoDelivery.compactMap { item -> Phase? in
            item.map { Phase(key: $0.id.uuidString, running: $0.running) }
        }.removeDuplicates().sink { [weak self] state in
            self?.log("导出", state.running ? "已开始交付" : "交付任务已结束")
        }.store(in: &subscriptions)
        model.sceneWorkflowBatches.$running.removeDuplicates().dropFirst()
            .sink { [weak self] running in self?.log("工作流", running ? "已开始批量处理" : "批量处理已结束") }
            .store(in: &subscriptions)
        model.$timelapseIsRunning.removeDuplicates().dropFirst()
            .sink { [weak self] running in self?.log("延时视频", running ? "已开始处理" : "处理已结束") }
            .store(in: &subscriptions)
        model.$qualityAnalysisRunning.removeDuplicates().dropFirst()
            .sink { [weak self] running in self?.log("资料库", running ? "已开始质量检查" : "质量检查已结束") }
            .store(in: &subscriptions)
        model.$errorMessage.removeDuplicates().compactMap { $0 }
            .sink { [weak self] message in
                self?.add(.init(assetID: nil, photoName: nil, kind: .error, text: message, action: nil))
                self?.log("资料库", "工作台操作报告错误", error: true)
            }.store(in: &subscriptions)
        model.$editing.sink { [weak self] editing in self?.observeJobs(editing) }.store(in: &subscriptions)
        if let services = model.editingServices {
            services.fluxModel.$status.removeDuplicates().dropFirst()
                .sink { [weak self] state in self?.log("模型", "模型状态已更新 · " + state.rawValue, error: state == .failed) }
                .store(in: &subscriptions)
            services.$runtimeState.removeDuplicates().dropFirst()
                .sink { [weak self] state in self?.log("运行时", "运行时状态已更新 · " + state, error: state == "failed") }
                .store(in: &subscriptions)
        }
    }

    private func observeJobs(_ editing: EditingController?) {
        var states: [String: ProcessingJobState] = [:]
        jobSubscription = editing?.$jobs.sink { [weak self] jobs in
            for job in jobs {
                let previous = states.updateValue(job.state, forKey: job.id)
                if (previous != nil || job.state == .queued) && previous != job.state {
                    self?.log("AI 编辑", "生成任务 · " + job.state.editingTitle, error: job.state == .failed)
                }
            }
        }
    }

}
