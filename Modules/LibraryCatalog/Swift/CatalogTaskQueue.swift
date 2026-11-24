import Foundation

public enum CatalogTaskFailure: String, Sendable {
    case transient, permanent, uncertain, offline
    /// The destination preflight or atomic no-replace operation specifically reported a collision.
    case destinationOccupied
}

public enum CatalogExternalPreparationError: Error, LocalizedError, Sendable {
    case destinationExists
    public var errorDescription: String? { "投递目标已存在。" }
}

public struct CatalogPreparedExternal: Equatable, Sendable {
    public let stage: URL
    public let destination: URL
    public let sha256: String
    public let byteCount: Int64

    fileprivate init(_ row: CatalogJSON) throws {
        guard case let .string(stage)? = row["stage"], case let .string(destination)? = row["destination"],
              case let .string(digest)? = row["sha256"], case let .integer(count)? = row["byteCount"] else {
            throw LibraryEngineError("投递任务缺少已准备文件的路径或摘要。")
        }
        self.stage = URL(fileURLWithPath: stage)
        self.destination = URL(fileURLWithPath: destination)
        sha256 = digest
        byteCount = count
    }
}

public struct CatalogPreparedTask: Sendable {
    public let key: String
    public let payload: CatalogJSON
    public let publication: CatalogPreparedExternal
}

/// Shared by value copies of one lease. A file receipt is recorded only after the Rust commit.
fileprivate final class CatalogTaskExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var digest: String?
    private var started = false
    func begin() throws {
        try Task.checkCancellation()
        lock.withLock { started = true }
    }
    var hasStarted: Bool { lock.withLock { started } }
    func record(_ value: String) { lock.withLock { digest = value } }
    func matches(_ value: String) -> Bool { lock.withLock { digest == value } }
}

public struct CatalogTaskLease: Sendable {
    public let database: URL
    public let key: String
    public let token: String
    fileprivate let execution = CatalogTaskExecution()

    fileprivate init(database: URL, key: String, token: String) {
        self.database = database
        self.key = key
        self.token = token
    }

    fileprivate func committedExternal(_ digest: String) -> Bool { execution.matches(digest) }

    /// The batch delivery has no separate domain row. Verify its final file and commit the SHA receipt atomically.
    public func finishExternalDelivery(lane: ProcessingAdmission.Lane = .export) async throws -> CatalogPreparedExternal {
        let row = try await CatalogTaskQueue(database: database).callFile(lane, ["op": .string("finishExternalDelivery"),
            "key": .string(key), "token": .string(token)])
        let ticket = try CatalogPreparedExternal(row)
        execution.record(ticket.sha256)
        return ticket
    }

    /// Close the encoder before recording its output. Keep the returned file until delivery is acknowledged.
    public func prepareExternal(stage: URL, destination: URL, lane: ProcessingAdmission.Lane = .export) async throws -> CatalogPreparedExternal {
        guard stage.isFileURL, destination.isFileURL else { throw LibraryEngineError("投递任务需要本地文件路径。") }
        let row = try await CatalogTaskQueue(database: database).callFile(lane, ["op": .string("prepareExternal"), "key": .string(key),
            "token": .string(token), "stage": .string(stage.path), "destination": .string(destination.path)])
        if row["status"] == .string("destinationExists") { throw CatalogExternalPreparationError.destinationExists }
        return try CatalogPreparedExternal(row)
    }

    /// For a catalog mutation use LibraryStore.publishCatalogTask so this test and publication share one transaction.
    public func check() async throws {
        _ = try await CatalogTaskQueue(database: database).call(["op": .string("check"), "key": .string(key), "token": .string(token)])
    }
}

public struct CatalogTaskStateError: Error, LocalizedError, Sendable {
    public let state: String
    public let detail: String
    public var errorDescription: String? { detail }
}

/// A durable scheduler record refers to an existing domain receipt. The domain remains the owner of the result.
public struct CatalogTaskQueue: Sendable {
    public let database: URL
    public init(database: URL) { self.database = database.standardizedFileURL.resolvingSymlinksInPath() }

    fileprivate func call(_ body: [String: CatalogJSON]) async throws -> CatalogJSON {
        let path = database
        return try await Task.detached {
            try LibraryEngine.shared().request("scheduler", at: path, payload: CatalogJSON.object(body), as: CatalogJSON.self)
        }.value
    }

    fileprivate func callFile(_ lane: ProcessingAdmission.Lane, _ body: [String: CatalogJSON]) async throws -> CatalogJSON {
        try await ProcessingAdmission.shared.withPermit(lane, resources: .init(cpu: 1, io: 1, memoryBytes: 1 << 20)) {
            try await call(body)
        }
    }

    public func preparedExternal(key: String) async throws -> CatalogPreparedExternal? {
        let row = try await call(["op": .string("preparedExternal"), "key": .string(key)])
        return try row == .null ? nil : CatalogPreparedExternal(row)
    }

    public func preparedExternalTasks(lane: String, keyPrefix: String, after: String? = nil,
                                      limit: Int = 64) async throws -> [CatalogPreparedTask] {
        let page = try await call(["op": .string("preparedExternalTasks"), "lane": .string(lane),
            "keyPrefix": .string(keyPrefix), "after": after.map(CatalogJSON.string) ?? .null, "limit": .integer(Int64(limit))])
        guard case let .array(rows) = page else { throw LibraryEngineError("无法读取投递任务。") }
        return try rows.map { row in
            guard let key = row["key"]?.stringValue, let payload = row["payload"], let publication = row["publication"] else {
                throw LibraryEngineError("投递任务记录不完整。")
            }
            return try .init(key: key, payload: payload, publication: CatalogPreparedExternal(publication))
        }
    }

    /// A missing file returns false. An existing file with different bytes or type throws.
    /// Matching bytes and the directory entry are synced before verified delivery is reported.
    public func verifyPreparedDestination(key: String, lane: ProcessingAdmission.Lane = .export) async throws -> Bool {
        try await callFile(lane, ["op": .string("verifyPrepared"), "key": .string(key), "destination": .boolean(true)]) == .boolean(true)
    }

    /// Verify and retrieve a final delivery in one Rust request, including its durable directory entry.
    public func verifyExternalDelivery(key: String, lane: ProcessingAdmission.Lane = .export) async throws -> CatalogPreparedExternal? {
        let ticket = try await callFile(lane, ["op": .string("verifyExternalDelivery"), "key": .string(key)])
        return try ticket == .null ? nil : CatalogPreparedExternal(ticket)
    }

    public func verifyPreparedStage(key: String, lane: ProcessingAdmission.Lane = .export) async throws -> Bool {
        try await callFile(lane, ["op": .string("verifyPrepared"), "key": .string(key), "destination": .boolean(false)]) == .boolean(true)
    }

    public func status(key: String) async throws -> CatalogJSON {
        try await call(["op": .string("status"), "key": .string(key)])
    }

    public func cancel(key: String) async throws {
        _ = try await call(["op": .string("cancel"), "key": .string(key)])
    }

    public func wake(key: String) async throws {
        _ = try await call(["op": .string("wake"), "key": .string(key)])
    }

    /// Pass the receipt verified against the domain's frozen input and destination.
    public func reconcile(key: String, receipt: String) async throws {
        _ = try await call(["op": .string("reconcile"), "key": .string(key), "safeToResubmit": .boolean(false),
                            "result": .string(receipt)])
    }

    /// Use only when the destination/provider confirms that the previous submission made no change.
    public func confirmNoExternalEffect(key: String) async throws {
        _ = try await call(["op": .string("reconcile"), "key": .string(key), "safeToResubmit": .boolean(true)])
    }

    public func withLease<T: Sendable>(key: String, lane: String, resource: String, payload: CatalogJSON,
        memoryMiB: Int = 64, replaySafe: Bool,
        restore: @Sendable (String) async throws -> T,
        classify: (@Sendable (Error) -> CatalogTaskFailure)? = nil,
        recoverOutstanding: (@Sendable () async throws -> (T, String)?)? = nil,
        execute: @escaping @Sendable (CatalogTaskLease) async throws -> (T, String)) async throws -> T {
        var state = try await call(["op": .string("submit"), "key": .string(key), "lane": .string(lane),
            "resource": .string(resource), "memoryMiB": .integer(Int64(memoryMiB)), "payload": payload,
            "replaySafe": .boolean(replaySafe), "claimLeaseMs": .integer(90_000)])
        var submissionToken = state["submissionToken"]?.stringValue
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                await cancelBeforeExecution(key: key, leaseToken: state["token"]?.stringValue, submissionToken: submissionToken, attempt: state["attempt"])
                throw error
            }
            switch state["state"]?.stringValue {
            case "done":
                guard let receipt = state["result"]?.stringValue else { throw LibraryEngineError("已完成的任务缺少结果收据。") }
                return try await restore(receipt)
            case "queued" where state["fitsConfiguredBudget"] == .boolean(false):
                // Keep the durable intent available for a capable host or later configuration.
                throw CatalogTaskStateError(state: "resourceUnavailable", detail: "此任务的资源需求超过资料库当前额度。")
            case "cancelled": throw CancellationError()
            case "reconcile":
                if let recoverOutstanding, let (value, receipt) = try await recoverOutstanding() {
                    try await reconcile(key: key, receipt: receipt)
                    return value
                }
                throw CatalogTaskStateError(state: "reconcile", detail: state["lastError"]?.stringValue ?? "待核对已有结果。")
            case "failed", "waiting":
                let phase = state["state"]?.stringValue ?? ""
                throw CatalogTaskStateError(state: phase, detail: state["lastError"]?.stringValue ?? phase)
            default: break
            }
            guard let token = state["token"]?.stringValue else {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    state = try await call(["op": .string("claim"), "key": .string(key), "leaseMs": .integer(90_000),
                                            "includeStatus": .boolean(true)])
                } catch {
                    if Task.isCancelled {
                        await cancelBeforeExecution(key: key, leaseToken: nil, submissionToken: submissionToken, attempt: state["attempt"])
                        throw CancellationError()
                    }
                    throw error
                }
                continue
            }
            let lease = CatalogTaskLease(database: database, key: key, token: token)
            do {
                let (value, receipt) = try await run(lease, execute)
                if !lease.committedExternal(receipt) {
                    _ = try await call(["op": .string("complete"), "key": .string(key), "token": .string(token), "result": .string(receipt)])
                }
                return value
            } catch {
                // A domain publication might have committed just before the caller lost its acknowledgement.
                let current = try await status(key: key)
                if current["state"] == .string("done"), let receipt = current["result"]?.stringValue {
                    return try await restore(receipt)
                }
                let cancelled = error is CancellationError || current["state"] == .string("cancelling")
                let classified = classify?(error)
                if cancelled && !lease.execution.hasStarted {
                    await cancelBeforeExecution(key: key, leaseToken: token, submissionToken: submissionToken, attempt: state["attempt"])
                    throw CancellationError()
                }
                if cancelled && replaySafe && classified != .destinationOccupied {
                    _ = try? await call(["op": .string("cancel"), "key": .string(key), "token": .string(token)])
                    _ = try? await call(["op": .string("ackCancel"), "key": .string(key), "token": .string(token)])
                    throw CancellationError()
                }
                let failure: CatalogTaskFailure
                if classified == .destinationOccupied { failure = .destinationOccupied }
                else if cancelled { failure = .uncertain }
                else { failure = classified ?? (replaySafe ? .permanent : .uncertain) }
                let reported = try? await call(["op": .string("fail"), "key": .string(key), "token": .string(token),
                    "class": .string(failure.rawValue), "ownRetry": .boolean(replaySafe && failure == .transient), "error": .string(String(error.localizedDescription.prefix(2000)))])
                if replaySafe && failure == .transient, let reported, reported["state"] == .string("queued") {
                    state = reported
                    submissionToken = reported["submissionToken"]?.stringValue
                    continue
                }
                throw error
            }
        }
    }

    private func cancelBeforeExecution(key: String, leaseToken: String?, submissionToken: String?, attempt: CatalogJSON?) async {
        if let leaseToken {
            _ = try? await call(["op": .string("abandonUnstarted"), "key": .string(key), "token": .string(leaseToken)])
        } else if let submissionToken {
            _ = try? await call(["op": .string("cancelIfQueued"), "key": .string(key), "submissionToken": .string(submissionToken), "attempt": attempt ?? .integer(0)])
        }
    }

    private func run<T: Sendable>(_ lease: CatalogTaskLease,
        _ operation: @escaping @Sendable (CatalogTaskLease) async throws -> (T, String)) async throws -> (T, String) {
        try await withThrowingTaskGroup(of: (T, String).self) { group in
            group.addTask {
                try lease.execution.begin()
                return try await operation(lease)
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(20))
                    do {
                        _ = try await call(["op": .string("heartbeat"), "key": .string(lease.key),
                                            "token": .string(lease.token), "leaseMs": .integer(90_000)])
                    } catch {
                        if (try? await status(key: lease.key))?["state"] != .string("done") { throw error }
                    }
                }
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
