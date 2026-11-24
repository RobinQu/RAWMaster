import CSQLite
import Foundation
import RAWMasterLibrary
@testable import RAWMasterCore
import XCTest

final class CatalogProcessing035Tests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testV8UpgradeKeepsUserRowsAndRestorableOriginalSnapshot() throws {
        let root = try temporary(), path = root.appendingPathComponent("library.sqlite")
        do {
            let store = try LibraryStore(databaseURL: path)
            try store.exec("INSERT INTO metadata(key,value) VALUES('queue-test','original')")
            // Reconstruct the prior genuine v8 schema, including all its authority triggers and domain tables.
            try store.exec("""
                DROP TRIGGER lc_workbench_writer_insert;
                DROP TRIGGER lc_workbench_writer_update;
                DROP TABLE lc_workbench_names;
                DROP TABLE lc_task_attempts;
                DROP TABLE lc_task_jobs;
                DROP TABLE lc_task_scheduler;
                PRAGMA user_version=8;
                """)
        }
        let store = try LibraryStore(databaseURL: path)
        XCTAssertEqual(try store.rows("PRAGMA user_version"), [[String(DatabaseSchema.version)]])
        XCTAssertEqual(try store.rows("SELECT value FROM metadata WHERE key='queue-test'"), [["original"]])
        let backup = try XCTUnwrap(store.lastMigrationBackupURL)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backup.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(try DatabaseSchema.validate(handle), 8)
        XCTAssertEqual(try DatabaseSchema.strings(handle, "SELECT value FROM metadata WHERE key='queue-test'"), ["original"])
        XCTAssertNil(try LibraryStore(databaseURL: path).lastMigrationBackupURL)
    }

    func testIncompleteV9IsRejectedBeforeReopeningAWriterOrMakingAnUpgradeBackup() throws {
        let root = try temporary()
        let database = root.appendingPathComponent("library.sqlite")
        let backups = root.appendingPathComponent("rejected-backups", isDirectory: true)
        do {
            let initial = try LibraryStore(databaseURL: database)
            try initial.exec("""
                DROP TRIGGER lc_workbench_writer_insert;
                DROP TRIGGER lc_workbench_writer_update;
                DROP TABLE lc_workbench_names;
                PRAGMA user_version=9;
                DROP INDEX lc_task_external_pending;
                PRAGMA wal_checkpoint(TRUNCATE);
                PRAGMA journal_mode=DELETE;
                """)
        }
        let initialHash = try FileSafety.hash(database)
        XCTAssertThrowsError(try LibraryStore(databaseURL: database, migrationBackupDirectory: backups))
        XCTAssertEqual(try FileSafety.hash(database), initialHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testEditingBackupRestoresActiveBatchesAsHistoryAndDetachesPreparedFiles() throws {
        let root = try temporary()
        let catalog = try LibraryStore(databaseURL: root.appendingPathComponent("source.sqlite"))
        _ = try catalog.configureEditingArchive(root: root.appendingPathComponent("source-archive"))
        let id = UUID().uuidString.lowercased()
        let library = try XCTUnwrap(catalog.rows("SELECT value FROM lc_meta WHERE key='libraryID'").first?.first)
        let source: CatalogJSON = .object(["assetID": .string("asset"), "projectID": .string("project"),
            "contentSHA256": .string(String(repeating: "a", count: 64)), "byteCount": .integer(100), "admissionFingerprint": .string("source-admission")])
        func request(_ fields: [String: CatalogJSON], at store: LibraryStore) throws -> CatalogJSON {
            try LibraryEngine.shared().request("scheduler", at: store.databaseURL, payload: CatalogJSON.object(fields), as: CatalogJSON.self)
        }
        func command(_ fields: [String: CatalogJSON], at store: LibraryStore) throws -> CatalogJSON {
            try request(["op": .string("workbenchBatch"), "command": .object(fields)], at: store)
        }
        let output = root.appendingPathComponent("delivery")
        let privateFolder = output.appendingPathComponent(".staged")
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        let stage = privateFolder.appendingPathComponent("pixels.jpg")
        let final = output.appendingPathComponent("photo.v1.jpg")
        let originalBytes = Data("encoded test bytes".utf8)
        try originalBytes.write(to: stage)
        let registered = try command(["action": .string("register"), "manifest": .object([
            "schema": .integer(1), "batchID": .string(id), "libraryID": .string(library),
            "sourceContext": .object(["anchor": .string("editor")]), "configuration": .object(["format": .string("jpeg8")]),
            "collision": .string("rename"), "namingTemplate": .string("{name}.v1"),
            "destination": .object(["grantID": .string("local-grant"), "pathHint": .string(output.path)]),
            "items": .array([.object(["ordinal": .integer(1), "assetID": .string("asset"), "stem": .string("photo.v1"),
                "work": .object(["id": .string("work"), "source": source]),
                "version": .object(["id": .string("version"), "workID": .string("work"), "source": source, "recipe": .object([:])])])])
        ])], at: catalog)
        let batchToken = try XCTUnwrap(registered["token"]?.stringValue)
        let key = "workbench-export-\(id)-0-1"
        let child = try request(["op": .string("submit"), "key": .string(key), "lane": .string("export"), "resource": .string("cpu"),
            "payload": .object(["destination": .string(final.path)]), "replaySafe": .boolean(true), "claimLeaseMs": .integer(90_000)], at: catalog)
        let childToken = try XCTUnwrap(child["token"]?.stringValue)
        _ = try request(["op": .string("prepareExternal"), "key": .string(key), "token": .string(childToken),
                         "stage": .string(stage.path), "destination": .string(final.path)], at: catalog)

        let backup = root.appendingPathComponent("backup")
        _ = try catalog.backupEditingLibrary(to: backup)
        let restored = try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: root.appendingPathComponent("restored.sqlite"),
                                                             archiveRoot: root.appendingPathComponent("restored-archive"))
        XCTAssertNotEqual(restored.deviceID, catalog.deviceID)
        let history = try command(["action": .string("load"), "batchID": .string(id)], at: restored)
        XCTAssertEqual(history["batch"]?["phase"], .string("historical"))
        XCTAssertEqual(history["manifest"], .null)
        let batchCheck: [String: CatalogJSON] = ["action": .string("check"), "batchID": .string(id), "generation": .integer(1), "token": .string(batchToken)]
        XCTAssertThrowsError(try command(batchCheck, at: restored))
        _ = try command(batchCheck, at: catalog)
        let childCheck: [String: CatalogJSON] = ["op": .string("check"), "key": .string(key), "token": .string(childToken)]
        XCTAssertThrowsError(try request(childCheck, at: restored))
        _ = try request(childCheck, at: catalog)
        XCTAssertEqual(try restored.rows("SELECT state,prepared_detached FROM lc_task_jobs WHERE job_key=?", [key]), [["reconcile", "1"]])
        XCTAssertEqual(try Data(contentsOf: stage), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    }

    func testExistingV8CatalogSnapshotMigratesWithoutChangingSourceOrSelections() throws {
        guard let filename = ProcessInfo.processInfo.environment["RAWMASTER_QUEUE_V8_SNAPSHOT"] else {
            throw XCTSkip("Set RAWMASTER_QUEUE_V8_SNAPSHOT to an existing version 8 catalog snapshot for the library replay.")
        }
        let root = try temporary()
        let original = URL(fileURLWithPath: filename)
        let originalHash = try FileSafety.hash(original)
        let (oldVersion, snapshot) = try DatabaseSchema.inspectAndBackup(original, directory: root)
        XCTAssertEqual(oldVersion, 8)
        let copy = try XCTUnwrap(snapshot)
        func counts(_ handle: OpaquePointer?) throws -> [String] {
            try DatabaseSchema.strings(handle, """
                SELECT count(*) FROM assets UNION ALL SELECT count(*) FROM lc_catalog_files
                UNION ALL SELECT count(*) FROM lc_receipts UNION ALL SELECT count(*) FROM editing_versions
                UNION ALL SELECT count(*) FROM lc_resources UNION ALL SELECT count(*) FROM processing_jobs
                """)
        }
        func firstPage(_ file: URL) throws -> [String] {
            let index = root.appendingPathComponent(UUID().uuidString + ".sqlite")
            let reply = try LibraryEngine.shared().request("page", at: file, index: index,
                payload: CatalogJSON.object(["pageSize": .integer(60), "includeOrderedIDs": .boolean(true)]), as: CatalogJSON.self)
            return try XCTUnwrap(reply["orderedAssetIDs"]?.arrayValue).compactMap(\.stringValue)
        }
        let savedOrder = try firstPage(copy)
        var old: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(copy.path, &old, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let before = try counts(old)
        sqlite3_close(old)
        let migrated = try LibraryStore(databaseURL: copy)
        XCTAssertEqual(try counts(migrated.db), before)
        XCTAssertEqual(try firstPage(copy), savedOrder)
        XCTAssertEqual(try migrated.rows("PRAGMA foreign_key_check"), [])
        XCTAssertEqual(try migrated.rows("SELECT count(*) FROM lc_task_jobs"), [["0"]])
        XCTAssertNotNil(migrated.lastMigrationBackupURL)
        XCTAssertEqual(try FileSafety.hash(original), originalHash)
        print("Catalog v8→\(DatabaseSchema.version) replay: assets, files, receipts, versions, resources, domain jobs = \(before), ordered IDs = \(savedOrder.count).")
    }

    func testContendingSwiftCallersPublishOneDomainReceiptAndRecoverIt() async throws {
        let root = try temporary(), store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let queue = CatalogTaskQueue(database: store.databaseURL)
        @Sendable func runWorker() async throws -> String {
            try await queue.withLease(key: "mask-committed-17", lane: "editing", resource: "gpu",
                payload: .object(["revision": .integer(17)]), replaySafe: true, restore: { receipt in
                    try store.withReadSnapshot { try XCTUnwrap(store.rows("SELECT value FROM metadata WHERE key=?", [receipt]).first?.first) }
                }) { lease in
                    // A second caller waits on this same intent rather than issuing another GPU job.
                    try await Task.sleep(for: .milliseconds(35))
                    let receipt = "mask-17-receipt"
                    let value = try store.publishCatalogTask(lease) {
                        try store.statement("INSERT INTO metadata(key,value) VALUES(?,?)", [receipt,"mask-result"])
                        return ("mask-result", receipt)
                    }
                    return (value, receipt)
                }
        }
        async let first = runWorker()
        async let second = runWorker()
        let values = try await [first, second]
        XCTAssertEqual(values, ["mask-result","mask-result"])
        XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_task_attempts"), [["1"]])
        XCTAssertEqual(try store.rows("SELECT state,result FROM lc_task_jobs"), [["done","mask-17-receipt"]])
    }
    func testPhasedDeliveryRetainsLeaseAndRecoversVerifiedFinalBeforeLeaseDeadline() async throws {
        let root = try temporary()
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let queue = CatalogTaskQueue(database: store.databaseURL)
        let key = "035-workbench-17"
        let payload = CatalogJSON.object(["version": .string("v17")])
        let stageRoot = root.appendingPathComponent(".rawmaster-export-test", isDirectory: true)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: false)
        let stage = stageRoot.appendingPathComponent("pixels.jpg"), final = root.appendingPathComponent("finished.jpg")
        let bytes = Data("encoded fixture".utf8)
        try bytes.write(to: stage)
        let value = try await queue.withLease(key: key, lane: "export", resource: "io", payload: payload,
            replaySafe: true, restore: { receipt in
                XCTAssertEqual(receipt, "asset:17")
                return try Data(contentsOf: final)
            }) { lease in
                let prepared = try await lease.prepareExternal(stage: stage, destination: final)
                XCTAssertEqual(prepared.byteCount, Int64(bytes.count))
                let page = try await queue.preparedExternalTasks(lane: "export", keyPrefix: "035-workbench-")
                XCTAssertEqual(page.map(\.key), [key])
                XCTAssertEqual(page.first?.payload, payload)
                let absent = try await queue.verifyPreparedDestination(key: key)
                XCTAssertFalse(absent)
                let preserved = try await queue.verifyPreparedStage(key: key)
                XCTAssertTrue(preserved)
                XCTAssertThrowsError(try store.completeVerifiedCatalogTask(key: key) { _ in ("too early", "asset:17") })
                try store.withCatalogTaskFence(lease) {
                    try FileManager.default.linkItem(at: prepared.stage, to: prepared.destination)
                    try store.statement("INSERT INTO metadata(key,value) VALUES('export-plan','asset:17')")
                }
                let running = try await queue.status(key: key)
                XCTAssertEqual(running["state"], .string("running"))
                let verifiedFinal = try await queue.verifyExternalDelivery(key: key)
                XCTAssertEqual(verifiedFinal, prepared)
                let verified: Data? = try store.completeVerifiedCatalogTask(key: key) { descriptor in
                    guard descriptor == payload, try store.rows("SELECT value FROM metadata WHERE key='export-plan'") == [["asset:17"]]
                    else { return nil }
                    return (bytes, "asset:17")
                }
                XCTAssertEqual(verified, bytes)
                XCTAssertThrowsError(try store.withCatalogTaskFence(lease) { try store.exec("DELETE FROM metadata WHERE key='export-plan'") })
                return (bytes, "asset:17")
            }
        XCTAssertEqual(value, bytes)
        XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_task_attempts"), [["1"]])
        XCTAssertEqual(try store.rows("SELECT value FROM metadata WHERE key='export-plan'"), [["asset:17"]])
        let none = try await queue.preparedExternalTasks(lane: "export", keyPrefix: "035-workbench-")
        XCTAssertTrue(none.isEmpty)
        let readback = try await queue.preparedExternal(key: key)
        XCTAssertEqual(readback?.byteCount, Int64(bytes.count))
    }

    func testCancellationDuringPreclaimReleasesOnlyTheClaimAcquiredByThatCaller() async throws {
        let root = try temporary(), store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let queue = CatalogTaskQueue(database: store.databaseURL)
        let engine = try LibraryEngine.shared()
        let descriptor = CatalogJSON.object(["request": .integer(77)])
        let existing = try engine.request("scheduler", at: store.databaseURL, payload: CatalogJSON.object([
            "op": .string("submit"), "key": .string("already-owned"), "lane": .string("editing"), "resource": .string("io"),
            "payload": descriptor, "replaySafe": .boolean(false), "claimLeaseMs": .integer(90_000)
        ]), as: CatalogJSON.self)
        let owner = try XCTUnwrap(existing["token"]?.stringValue)
        for key in ["new-claim", "already-owned"] {
            // This real writer lock keeps the detached Rust call inside submit/claim until cancellation.
            try store.exec("BEGIN IMMEDIATE")
            let entered = expectation(description: "caller entered preclaim")
            let caller = Task<String, Error> {
                entered.fulfill()
                return try await queue.withLease(key: key, lane: "editing", resource: "io", payload: descriptor, replaySafe: false,
                    restore: { _ in XCTFail("Unexpected remote result"); return "restore" }) { _ in
                        XCTFail("A cancelled preclaim must not enter the external worker")
                        return ("sent", "receipt")
                    }
            }
            await fulfillment(of: [entered], timeout: 2)
            try await Task.sleep(for: .milliseconds(35))
            caller.cancel()
            try store.exec("COMMIT")
            do { _ = try await caller.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        }
        XCTAssertEqual(try store.rows("SELECT state,token IS NULL,lease_until IS NULL FROM lc_task_jobs WHERE job_key='new-claim'"), [["cancelled","1","1"]])
        XCTAssertEqual(try store.rows("SELECT state,token FROM lc_task_jobs WHERE job_key='already-owned'"), [["running",owner]])
    }

    func testCancellingQueuedCreatorWithdrawsIntentWhileDuplicateCannotWithdrawSharedWork() async throws {
        let root = try temporary(), store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let queue = CatalogTaskQueue(database: store.databaseURL)
        let engine = try LibraryEngine.shared()
        func command(_ fields: [String: CatalogJSON]) throws -> CatalogJSON {
            try engine.request("scheduler", at: store.databaseURL, payload: CatalogJSON.object(fields), as: CatalogJSON.self)
        }
        _ = try command(["op": .string("configure"), "cpu": .integer(1), "gpu": .integer(1), "io": .integer(1), "memoryMiB": .integer(128)])
        let held = try command(["op": .string("submit"), "key": .string("occupied"), "lane": .string("export"), "resource": .string("io"),
            "payload": .object([:]), "replaySafe": .boolean(true), "claimLeaseMs": .integer(90_000)])
        func worker(_ key: String) -> Task<String, Error> {
            Task {
                try await queue.withLease(key: key, lane: "export", resource: "io", payload: .object([:]), replaySafe: true, restore: { $0 }) { _ in
                    XCTAssertEqual(key, "shared")
                    return (key, key)
                }
            }
        }
        func waitForQueue(_ key: String) async throws {
            for _ in 0..<200 {
                if try store.rows("SELECT state FROM lc_task_jobs WHERE job_key=?", [key]) == [["queued"]] { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("The requested job did not reach its durable queue")
        }
        let withdrawn = worker("withdrawn")
        try await waitForQueue("withdrawn")
        withdrawn.cancel()
        do { _ = try await withdrawn.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try store.rows("SELECT state,attempt FROM lc_task_jobs WHERE job_key='withdrawn'"), [["cancelled","0"]])
        let creator = worker("shared")
        try await waitForQueue("shared")
        let duplicate = worker("shared")
        try await Task.sleep(for: .milliseconds(30))
        duplicate.cancel()
        do { _ = try await duplicate.value; XCTFail("Expected duplicate cancellation") } catch is CancellationError {}
        XCTAssertEqual(try store.rows("SELECT state FROM lc_task_jobs WHERE job_key='shared'"), [["queued"]])
        _ = try command(["op": .string("complete"), "key": .string("occupied"), "token": try XCTUnwrap(held["token"]), "result": .string("done")])
        let value = try await creator.value
        XCTAssertEqual(value, "shared")
        XCTAssertEqual(try command(["op": .string("claim")]), .null)
    }

    func testBatchFileLeaseAcknowledgesItsHeadlessDeliveryAndRestoresThatSHA() async throws {
        let root = try temporary()
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let queue = CatalogTaskQueue(database: store.databaseURL)
        let input = root.appendingPathComponent("pixels"), final = root.appendingPathComponent("delivery.jpg")
        let bytes = Data("headless batch".utf8)
        try bytes.write(to: input)
        @Sendable func run() async throws -> String {
            try await queue.withLease(key: "headless-delivery", lane: "export", resource: "io",
                payload: .object(["destination": .string(final.path)]), replaySafe: true, restore: { digest in
                    let ticket = try await queue.verifyExternalDelivery(key: "headless-delivery")
                    XCTAssertEqual(ticket?.sha256, digest)
                    return digest
                }) { lease in
                    let ticket = try await lease.prepareExternal(stage: input, destination: final)
                    try store.withCatalogTaskFence(lease) { try FileManager.default.linkItem(at: ticket.stage, to: ticket.destination) }
                    let receipt = try await lease.finishExternalDelivery()
                    XCTAssertEqual(receipt, ticket)
                    return (receipt.sha256, receipt.sha256)
                }
        }
        let first = try await run()
        let second = try await run()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try store.rows("SELECT state,attempt,result,final_verified FROM lc_task_jobs"), [["done","1",first,"1"]])
        XCTAssertEqual(try Data(contentsOf: final), bytes)
    }

    func testTransientFileReadWaitsForBackoffAndPublishesExactlyOneReceipt() async throws {
        let root = try temporary()
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let queue = CatalogTaskQueue(database: store.databaseURL)
        let input = root.appendingPathComponent("input")
        let expected = Data("now available".utf8)
        let start = ContinuousClock.now
        let result = try await queue.withLease(key: "retry-asset", lane: "library", resource: "io", payload: .object([:]),
            replaySafe: true, restore: { _ in try Data(contentsOf: input) },
            classify: { error in (error as? CocoaError)?.code == .fileReadNoSuchFile ? .transient : .permanent }) { lease in
                let data: Data
                do { data = try Data(contentsOf: input) }
                catch {
                    // Supply the file after a real missing-file error, as a volume becoming available would.
                    try expected.write(to: input)
                    throw error
                }
                let saved = try store.publishCatalogTask(lease) {
                    try store.statement("INSERT INTO metadata(key,value) VALUES('read-receipt','complete')")
                    return (data, "read-receipt")
                }
                return (saved, "read-receipt")
            }
        XCTAssertEqual(result, expected)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(240))
        XCTAssertEqual(try store.rows("SELECT state FROM lc_task_attempts ORDER BY attempt"), [["queued"],["done"]])
        XCTAssertEqual(try store.rows("SELECT count(*) FROM metadata WHERE key='read-receipt'"), [["1"]])
    }

    func testUnsafeRemoteResolvesFromPendingAuthoritativeReceiptWithoutResubmission() async throws {
        let root = try temporary()
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let queue = CatalogTaskQueue(database: store.databaseURL)
        let key = "remote-edit-139"
        let frozen = CatalogJSON.object(["request": .string("139")])
        let engine = try LibraryEngine.shared()
        func schedule(_ body: [String: CatalogJSON]) throws -> CatalogJSON {
            try engine.request("scheduler", at: store.databaseURL, payload: CatalogJSON.object(body), as: CatalogJSON.self)
        }
        _ = try schedule(["op": .string("submit"), "key": .string(key), "lane": .string("editing"),
             "resource": .string("io"), "payload": frozen, "replaySafe": .boolean(false)])
        _ = try schedule(["op": .string("claim"), "key": .string(key)])
        try store.transaction {
            try store.statement("INSERT INTO metadata(key,value) VALUES(?,?)", ["provider-139", "asset-returned"])
            try store.statement("UPDATE lc_task_jobs SET lease_until=0 WHERE job_key=?", [key])
        }
        let result = try await queue.withLease(key: key, lane: "editing", resource: "io", payload: frozen, replaySafe: false,
            restore: { _ in "asset-returned" }, recoverOutstanding: {
                let saved = try store.withReadSnapshot { try store.rows("SELECT value FROM metadata WHERE key='provider-139'").first?.first }
                return saved.map { ($0, "provider-139") }
            }) { _ in
                XCTFail("An independently verified external result must not repeat the provider call.")
                return ("again", "duplicate")
            }
        XCTAssertEqual(result, "asset-returned")
        XCTAssertEqual(try store.rows("SELECT state,result,attempt FROM lc_task_jobs"), [["done","provider-139","1"]])
    }

    func testPreviewCanUseTheReservedGPUWhileLongBackgroundAndAgedWaiterRemain() async throws {
        let admission = ProcessingAdmission(capacity: .init(cpu: 2, gpu: 2, io: 2, memoryBytes: 512))
        let background = ProcessingAdmission.Resources(gpu: 1, memoryBytes: 128)
        let held = ExecutionGate()
        let long = Task { try await admission.withPermit(.editing, resources: background) { await held.block() } }
        await held.waitForEntry()
        let second = Task { try await admission.withPermit(.export, resources: background) { await held.isReleased } }
        try await Task.sleep(for: .milliseconds(15))
        // The blocked background worker ages past the reservation threshold.
        for _ in 0..<8 { try await admission.withPermit(.library, resources: .init(cpu: 1)) {} }
        let painted = expectation(description: "presentation completed before the background command")
        let preview = Task {
            let stillHeld = try await admission.withPermit(.editing, resources: .init(cpu: 1, gpu: 1, memoryBytes: 128),
                                                           presentation: true) { await !held.isReleased }
            painted.fulfill()
            return stillHeld
        }
        await fulfillment(of: [painted], timeout: 2)
        await held.release()
        let renderedBeforeRelease = try await preview.value
        let secondWaited = try await second.value
        try await long.value
        XCTAssertTrue(renderedBeforeRelease)
        XCTAssertTrue(secondWaited)
    }

    func testCancellingWaitingAndExecutingTasksKeepsDeviceReservedUntilWorkJoins() async throws {
        let admission = ProcessingAdmission(capacity: .init(cpu: 2, gpu: 1, io: 2, memoryBytes: 256))
        let gpu = ProcessingAdmission.Resources(gpu: 1, memoryBytes: 128)
        let gate = ExecutionGate()
        let first = Task {
            try await admission.withPermit(.library, resources: gpu) { await gate.block() }
        }
        await gate.waitForEntry()
        let cancelled = Task {
            try await admission.withPermit(.editing, resources: gpu) { XCTFail("Cancelled waiter started real work") }
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancelled waiter") } catch is CancellationError { }
        first.cancel()
        let follower = Task {
            try await admission.withPermit(.export, resources: gpu) { await gate.isReleased }
        }
        // An admitted non-interruptible GPU command can still be using its permit after cancellation.
        try await Task.sleep(for: .milliseconds(35))
        await gate.release()
        try await first.value
        let releasedBeforeFollower = try await follower.value
        XCTAssertTrue(releasedBeforeFollower)
    }
}

private actor ExecutionGate {
    var isReleased = false
    private var hasEntered = false
    private var entered: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?

    func block() async {
        hasEntered = true
        entered?.resume()
        entered = nil
        if !isReleased { await withCheckedContinuation { blocked = $0 } }
    }

    func waitForEntry() async {
        if !hasEntered { await withCheckedContinuation { entered = $0 } }
    }

    func release() {
        isReleased = true
        blocked?.resume()
        blocked = nil
    }
}
