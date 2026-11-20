import XCTest
import Foundation
@testable import RAWMasterCore

final class ImportPerformanceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterImportPerformance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testBulkProjectionPreservesMembershipOrderParticipationAndSessionScope() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let a = AssetRecord(id: "a", sessionID: "one", projectID: "project", sourcePath: "/a.jpg", groupID: "obsolete", sequenceIndex: 99, isSequenceMember: true)
        let b = AssetRecord(id: "b", sessionID: "two", projectID: "project", sourcePath: "/b.jpg")
        let c = AssetRecord(id: "c", sessionID: "one", projectID: "project", sourcePath: "/c.jpg", groupID: "obsolete", sequenceIndex: 99, isSequenceMember: true)
        try store.registerDiscovered([a, b, c])
        try store.transaction {
            for id in ["z-first", "a-second"] {
                let group = CaptureGroup(id: id, projectID: "project", name: id)
                try store.statement("INSERT INTO groups_data VALUES(?,?,?)", [id, "project", try store.json(group)])
            }
            try store.statement("INSERT INTO membership VALUES('z-first','a',7,0)")
            try store.statement("INSERT INTO membership VALUES('a-second','b',2,1)")
            try store.statement("INSERT INTO membership VALUES('a-second','a',3,1)")
        }
        let all = try store.loadAssets()
        XCTAssertEqual(all.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(all[0].groupID, "z-first")
        XCTAssertEqual(all[0].sequenceIndex, 7)
        XCTAssertTrue(all[0].isSequenceMember)
        XCTAssertNil(all[2].groupID); XCTAssertNil(all[2].sequenceIndex)
        XCTAssertFalse(all[2].isSequenceMember)
        let scoped = try store.loadAssets(sessionID: "one")
        XCTAssertEqual(scoped.map(\.id), ["a", "c"])
        XCTAssertEqual(scoped[0].groupID, all[0].groupID)
        XCTAssertEqual(scoped[0].sequenceIndex, all[0].sequenceIndex)
        XCTAssertEqual(scoped[0].isSequenceMember, all[0].isSequenceMember)
        XCTAssertTrue(try store.loadAssets(sessionID: "absent").isEmpty)
        XCTAssertEqual(try store.rows("SELECT name FROM sqlite_master WHERE type='index' AND name='membership_asset_id'").count, 1)
    }

    func testDiscoveryBatchRollsBackOnClosedSessionAndEnforcesBound() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        try store.transaction { try store.writeWorkflow(SessionWorkflow(sessionID: "closed", projectID: "project", isNewProject: false, phase: .closed)) }
        let a = AssetRecord(id: "a", sessionID: "open", projectID: "project", sourcePath: "/a.jpg")
        let b = AssetRecord(id: "b", sessionID: "closed", projectID: "project", sourcePath: "/b.jpg")
        XCTAssertThrowsError(try store.registerDiscovered([a, b]))
        XCTAssertTrue(try store.loadAssets().isEmpty)
        XCTAssertTrue(try store.rows("SELECT id FROM operations").isEmpty)
        XCTAssertThrowsError(try store.registerDiscovered(Array(repeating: a, count: 65)))
        try store.registerDiscovered([a, a])
        XCTAssertEqual(try store.loadAssets().count, 1)
        XCTAssertEqual(try store.rows("SELECT id FROM operations WHERE action='discover'").count, 1)
    }

    func testCancellationDuringBatchedDiscoveryResumesWithoutDuplicates() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for i in 0..<130 { try Data("payload \(i)".utf8).write(to: source.appendingPathComponent("\(i).jpg")) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let service = ImportService(store: store)
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var value = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        }
        let counter = Counter()
        let partial = try await service.importDirectory(source: source, destination: nil, projectName: "Cancel", mode: .reference, progress: { progress in
            if progress.title == "扫描素材", counter.next() == 3 { service.cancel() }
        })
        XCTAssertEqual(partial.status, "cancelled")
        XCTAssertEqual(partial.scanCompleted, false)
        XCTAssertEqual(try store.loadAssets().count, 65, "Graceful cancellation flushes the bounded discovered tail")
        let resumed = try await service.resume(sessionID: partial.id, progress: { _ in })
        XCTAssertEqual(resumed.completed, 130)
        let assets = try store.loadAssets()
        XCTAssertEqual(Set(assets.map(\.sourcePath)).count, 130)
        XCTAssertEqual(assets.count, 130)
        XCTAssertTrue(assets.allSatisfy { $0.importState == .ready })
        XCTAssertEqual(try store.rows("SELECT id FROM operations WHERE action='discover'").count, 130)
    }

    func testFinishedImportAssetAndSessionCommitAtomicallyPreservingHumanEdits() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        var session = try store.prepareImportSession(root: root, destination: nil, mode: .reference, projectName: "Atomic", projectID: nil, initialScreening: false)
        var a = AssetRecord(id: "a", sessionID: session.id, projectID: session.projectID, sourcePath: "/a.jpg")
        _ = try store.register(a)
        _ = try store.updateSelection(ids: [a.id], decision: .keep, rating: 4)
        a.importState = .ready; a.contentHash = String(repeating: "a", count: 64)
        session.completed = 1
        var wrong = session; wrong.id = "wrong"
        XCTAssertThrowsError(try store.saveImportAsset(a, session: wrong))
        XCTAssertEqual(try store.loadAssets().first?.importState, .discovered)
        XCTAssertEqual(try store.loadSessions().first?.completed, 0)
        try store.saveImportAsset(a, session: session)
        let saved = try XCTUnwrap(store.loadAssets().first)
        XCTAssertEqual(saved.importState, .ready)
        XCTAssertEqual(saved.decision, .keep); XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(try store.loadSessions().first?.completed, 1)
    }

    func testReadSnapshotIsConsistentAcrossConnectionsAndSupportsNesting() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let store = try LibraryStore(databaseURL: database)
        let other = try LibraryStore(databaseURL: database)
        try store.saveProject(ProjectRecord(name: "First"))
        try store.withReadSnapshot {
            XCTAssertEqual(try store.loadProjects().count, 1)
            try other.saveProject(ProjectRecord(name: "Second"))
            XCTAssertEqual(try store.withReadSnapshot { try store.loadProjects().count }, 1)
        }
        XCTAssertEqual(try store.loadProjects().count, 2)
        try store.transaction {
            XCTAssertEqual(try store.withReadSnapshot { try store.loadProjects().count }, 2)
            try store.statement("INSERT INTO metadata VALUES('snapshot-test','retained')")
        }
        XCTAssertEqual(try store.rows("SELECT value FROM metadata WHERE key='snapshot-test'").first?.first, "retained")
    }

    func testMembershipIndexWhitelistRejectsWrongShapeAndUnknownIndexes() throws {
        for sql in ["DROP INDEX membership_asset_id; CREATE INDEX membership_asset_id ON membership(group_id)",
                    "DROP INDEX membership_asset_id; CREATE UNIQUE INDEX membership_asset_id ON membership(asset_id)",
                    "DROP INDEX membership_asset_id; CREATE INDEX membership_asset_id ON membership(asset_id) WHERE included=1",
                    "CREATE INDEX unknown_index ON membership(asset_id)"] {
            let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("library.sqlite")
            let store = try LibraryStore(databaseURL: url)
            try store.exec(sql)
            XCTAssertThrowsError(try LibraryStore(databaseURL: url))
        }
    }

    func testReadSnapshotRollsBackAfterFailure() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        enum Failure: Error { case expected }
        XCTAssertThrowsError(try store.withReadSnapshot { _ = try store.loadAssets(); throw Failure.expected })
        try store.saveProject(ProjectRecord(name: "Writable after rollback"))
        XCTAssertEqual(try store.withReadSnapshot { try store.loadProjects().count }, 1)
    }

    /// Explicit same-machine before/after benchmark. No user library or original is touched.
    func testOptionalImportBenchmark() async throws {
        guard let output = ProcessInfo.processInfo.environment["RAWMASTER_IMPORT_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Opt-in import/load benchmark")
        }
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let count = 500
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZikAAAAASUVORK5CYII=")!
        for i in 0..<count { try bytes.write(to: source.appendingPathComponent(String(format: "%05d.jpg", i))) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("import.sqlite"))
        let begin = ProcessInfo.processInfo.systemUptime
        let session = try await ImportService(store: store).importDirectory(source: source, destination: nil,
            projectName: "Import benchmark", mode: .reference, initialScreening: true, progress: { _ in })
        let importSeconds = ProcessInfo.processInfo.systemUptime - begin
        XCTAssertEqual(session.completed, count)
        let large = try LibraryStore(databaseURL: root.appendingPathComponent("projection.sqlite"))
        let size = 3000
        try large.transaction {
            for group in ["first", "second"] {
                let value = CaptureGroup(id: group, projectID: "project", name: group, kind: "连拍", assetIDs: [])
                try large.statement("INSERT INTO groups_data VALUES(?,?,?)", [group, "project", try large.json(value)])
            }
            for i in 0..<size {
                let asset = AssetRecord(id: String(i), sessionID: "session", projectID: "project", sourcePath: "/benchmark/\(i).jpg")
                try large.statement("INSERT INTO assets(id,session_id,source_path,data) VALUES(?,?,?,?)", [asset.id, asset.sessionID, asset.sourcePath, try large.json(asset)])
                for group in ["first", "second"] {
                    try large.statement("INSERT INTO membership VALUES(?,?,?,?)", [group, asset.id, String(i), group == "first" ? "0" : "1"])
                }
            }
        }
        var projectionSeconds: [Double] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let assets = try large.loadAssets(sessionID: "session")
            projectionSeconds.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(assets.count, size)
            XCTAssertEqual(assets.first?.groupID, "first")
            XCTAssertTrue(assets.allSatisfy(\.isSequenceMember))
        }
        let result: [String: Any] = ["smallFileCount": count, "smallFileImportSeconds": importSeconds,
            "projectionAssetCount": size, "projectionMembershipCount": size * 2,
            "projectionSeconds": projectionSeconds, "configuration": "debug", "note": "Local tiny-image reference intake only, grouping and UI excluded"]
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("IMPORT_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
