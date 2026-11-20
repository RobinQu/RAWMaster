import Foundation
import RAWMasterCore

/// A complete catalogue read on a worker. A single read transaction keeps related tables aligned.
struct LibrarySnapshot: Sendable {
    let projects: [ProjectRecord]
    let sessions: [ImportSession]
    let workflows: [SessionWorkflow]
    let admissions: [ProjectAdmission]
    let triageRecords: [TriageRecord]
    let capturePairs: [CapturePair]
    let qualityEvidence: [TriageQualityEvidence]
    let triageCommands: [TriageCommand]
    let assetTags: [String: [String]]
    let assetColorLabels: [String: PhotoColorLabel]
    let colorLabelCommands: [ColorLabelCommand]
    let reviewRecords: [ReviewRecord]
    let tagCommands: [TagCommand]
    let tagVocabulary: [String]
    let groups: [CaptureGroup]
    let assets: [AssetRecord]
    let relocationHistory: [RelocationSession]
    let groupHistory: [GroupCommandRecord]
    let groupingSessionID: String?
    let groupingRun: AutomaticGroupingRunRecord?
    let groupingCommand: GroupCommandRecord?

    static func read(store: LibraryStore, groupingSessionID: String?) throws -> Self {
        try store.withReadSnapshot {
            let projects = try store.publishedProjects()
            let sessions = try store.loadSessions()
            let groupingRun = try groupingSessionID.flatMap { try store.automaticGroupingRun(sessionID: $0) }
            let groupingCommand = try (groupingRun?.commandID ?? groupingRun?.lastSuccess?.commandID).flatMap { try store.loadGroupCommand(id: $0) }
            return Self(projects: projects, sessions: sessions, workflows: try store.loadWorkflows(),
                admissions: try store.loadAdmissions(), triageRecords: try store.loadTriageRecords(),
                capturePairs: try store.loadCapturePairs(), qualityEvidence: try store.loadQualityEvidence(),
                triageCommands: try store.loadTriageCommands(), assetTags: try store.loadTags(),
                assetColorLabels: try store.loadColorLabels(), colorLabelCommands: try store.loadColorLabelCommands(),
                reviewRecords: try store.loadReviewRecords(), tagCommands: try store.loadTagCommands(),
                tagVocabulary: try store.tagVocabulary(), groups: try store.loadGroups(),
                assets: AssetBrowserOrder.sorted(try store.loadAssets(), sessions: sessions),
                relocationHistory: try store.loadRelocationSessions(), groupHistory: try store.loadGroupCommands(limit: 50),
                groupingSessionID: groupingSessionID, groupingRun: groupingRun, groupingCommand: groupingCommand)
        }
    }
}

/// Keeps at most one MainActor delivery loop alive, regardless of producer speed.
/// Intermediate progress is replaceable; close returns the last pending value for final delivery.
final class ImportProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: TaskProgress?
    private var scheduled = false
    private var closed = false
    private let deliver: @MainActor @Sendable (TaskProgress) -> Void
    init(deliver: @escaping @MainActor @Sendable (TaskProgress) -> Void) { self.deliver = deliver }
    func submit(_ progress: TaskProgress) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        latest = progress
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        Task { @MainActor [self] in
            while let value = take() {
                deliver(value)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    private func take() -> TaskProgress? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let value = latest else { scheduled = false; return nil }
        latest = nil
        return value
    }
    func close() -> TaskProgress? {
        lock.lock(); defer { lock.unlock() }
        closed = true
        defer { latest = nil }
        return latest
    }
}
