import Combine
import Foundation
import RAWMasterCore

@MainActor final class OriginalDeliveryCoordinator: ObservableObject {
    @Published private(set) var activeID: String?
    @Published private(set) var progress: TaskProgress?
    @Published private(set) var error: String?

    private enum StopRequest: Equatable { case pause, cancel }
    private let defaults: UserDefaults
    private var worker: Task<Void, Never>?
    private var service: ExportService?
    private var stop: StopRequest?
    private var generation = UUID()
    private var accepting = true

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func submit(store: LibraryStore, ids: [String], manifestIDs: [String], destination: URL, formats: ExportFormats,
                csvLayout: ExportCSVLayout, completion: @escaping (Result<OriginalDeliveryJob, Error>) -> Void) {
        let id = UUID()
        let jobID = id.uuidString.lowercased()
        let access = WorkbenchDeliveryAccess(destination)
        perform(jobID, store: store, completion: completion) { service, progress in
            let prepared = try await Task.detached(priority: .userInitiated) {
                try service.enqueueOriginalDelivery(id: id, ids: ids, destination: access.url,
                    manifestIDs: manifestIDs, formats: formats, csvLayout: csvLayout)
            }.value
            try? access.remember(grantID: Self.grantKey(jobID), database: store.databaseURL, in: self.defaults)
            try Task.checkCancellation()
            return try await service.resumeOriginalDelivery(id: prepared.id, destination: access.url, progress: progress)
        }
    }

    func resume(_ id: String, store: LibraryStore, destination: URL? = nil) {
        perform(id, store: store) { service, progress in
            let access = destination.map(WorkbenchDeliveryAccess.init) ?? (try? WorkbenchDeliveryAccess.open(
                grantID: Self.grantKey(id), database: store.databaseURL, in: self.defaults))
            let result = try await service.resumeOriginalDelivery(id: id, destination: access?.url, progress: progress)
            if let access, destination != nil, result.phase != .waiting, !result.historical,
               result.destinationPath == access.url.path {
                try? access.remember(grantID: Self.grantKey(id), database: store.databaseURL, in: self.defaults, reauthorized: true)
            }
            withExtendedLifetime(access) {}
            return result
        }
    }

    func cancel(_ id: String, store: LibraryStore) {
        guard accepting else { return }
        if activeID == id {
            stop = .cancel
            service?.cancel()
            worker?.cancel()
        } else {
            perform(id, store: store) { service, _ in
                try await Task.detached(priority: .utility) {
                    try service.cancelOriginalDelivery(id: id)
                    return try store.originalDeliveryJob(id: id)
                }.value
            }
        }
    }

    func requestPause() {
        guard worker != nil, stop == nil else { return }
        stop = .pause
        service?.pauseOriginalDelivery()
        worker?.cancel()
    }

    func stopAndJoin() async {
        accepting = false
        let task = worker
        requestPause()
        await task?.value
    }

    func reopenAdmission() { accepting = true }

    private static func grantKey(_ id: String) -> String { "original." + id }

    private func perform(_ id: String, store: LibraryStore,
                         completion: ((Result<OriginalDeliveryJob, Error>) -> Void)? = nil,
                         operation: @escaping @MainActor (ExportService, @escaping @Sendable (TaskProgress) -> Void) async throws -> OriginalDeliveryJob) {
        guard accepting, worker == nil else { return }
        let service = ExportService(store: store)
        self.service = service
        activeID = id
        progress = .init(title: "原件交付", message: "正在准备…")
        error = nil
        let token = UUID()
        generation = token
        let receive: @Sendable (TaskProgress) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == token, self.activeID == id else { return }
                self.progress = value
            }
        }
        worker = Task {
            var result: Result<OriginalDeliveryJob, Error>
            do { result = .success(try await operation(service, receive)) }
            catch { result = .failure(error) }
            if stop == .cancel {
                do {
                    let cancelled = try await Task.detached(priority: .utility) {
                        try service.cancelOriginalDelivery(id: id)
                        return try store.originalDeliveryJob(id: id)
                    }.value
                    result = .success(cancelled)
                } catch {
                    result = .failure(error)
                }
            }
            activeID = nil
            self.service = nil
            worker = nil
            stop = nil
            switch result {
            case .success(let job):
                progress = .init(title: job.title, completed: job.completed, total: job.total,
                    message: job.error ?? job.phase.title, isRunning: false)
                error = job.error
                completion?(.success(job))
            case .failure(let failure):
                if failure is CancellationError {
                    progress = nil
                } else {
                    error = failure.localizedDescription
                    progress = .init(title: "原件交付", message: failure.localizedDescription, isRunning: false)
                    completion?(.failure(failure))
                }
            }
        }
    }
}
