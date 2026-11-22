import CSQLite
import XCTest

@testable import RAWMasterCore

final class CoreTests: XCTestCase {
  var root: URL!
  var source: URL!
  var store: LibraryStore!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RAWMasterTests-" + UUID().uuidString)
    source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    store = try LibraryStore(databaseURL: root.appendingPathComponent("catalog.sqlite"))
  }
  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: root)
  }
  @discardableResult func file(_ path: String, _ text: String = "RAW fixture") throws -> URL {
    let u = source.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: u)
    return u
  }
  func runImport(_ mode: ImportMode = .reference, name: String = "Test", projectID: String? = nil,
                 initialScreening: Bool = false)
    async throws -> ImportSession
  {
    try await ImportService(store: store).importDirectory(
      source: source, destination: mode == .copy ? root.appendingPathComponent("work") : nil,
      projectName: name, mode: mode, projectID: projectID, initialScreening: initialScreening, progress: { _ in })
  }

  func assertSealedSessionCannotResume(_ id: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
      _ = try await ImportService(store: store).resume(sessionID: id, progress: { _ in })
      XCTFail("A sealed import must stay closed", file: file, line: line)
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("已关闭"), error.localizedDescription, file: file, line: line)
    }
  }

  func testReferenceDiscoveryIdempotenceAndOriginalPreservation() async throws {
    let a = try file("a.ARW", "one")
    try file("nested/a.ARW", "two")
    try file(".hidden.ARW")
    try file("ignored.txt")
    let hash = try FileSafety.hash(a)
    let session = try await runImport(initialScreening: true)
    let assets = try store.loadAssets()
    XCTAssertEqual(session.completed, 2)
    XCTAssertEqual(Set(assets.map(\.relativePath)), ["a.ARW", "nested/a.ARW"])
    XCTAssertTrue(assets.allSatisfy { $0.importState == .ready && $0.currentPath == $0.sourcePath })
    XCTAssertEqual(try FileSafety.hash(a), hash)
    let continued = try await runImport(projectID: session.projectID, initialScreening: true)
    XCTAssertEqual(continued.id, session.id)
    XCTAssertEqual(try store.loadAssets().count, 2)
    let resumed = try await ImportService(store: store).resume(
      sessionID: session.id, progress: { _ in })
    XCTAssertEqual(resumed.completed, 2)
    XCTAssertEqual(Set(try store.loadAssets(sessionID: session.id).map(\.id)), Set(assets.map(\.id)))
    let preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    _ = try store.commitCompletion(preview)
    await assertSealedSessionCannotResume(session.id)
    let later = try await runImport(projectID: session.projectID)
    XCTAssertNotEqual(later.id, session.id)
    let laterAssets = try store.loadAssets(sessionID: later.id)
    XCTAssertEqual(Set(laterAssets.map(\.relativePath)), Set(assets.map(\.relativePath)))
    XCTAssertTrue(Set(laterAssets.map(\.id)).isDisjoint(with: assets.map(\.id)))
    XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_catalog_files WHERE project_id=?", [session.projectID]), [["2"]])
    XCTAssertEqual(try store.rows("SELECT count(*),count(DISTINCT content_id) FROM lc_scopes WHERE project_id=?", [session.projectID]), [["4","2"]])
    XCTAssertEqual(try FileSafety.hash(a), hash)
  }
  func testCopyCollisionResumeAndChangedSourceIdentity() async throws {
    let original = try file("a.ARW", "original bytes")
    let s = try await runImport(.copy, initialScreening: true)
    var a = try XCTUnwrap(store.loadAssets().first)
    let priorHash = a.contentHash
    XCTAssertNotEqual(a.currentPath, a.sourcePath)
    XCTAssertEqual(try FileSafety.hash(a.resolvedURL), priorHash)
    _ = try store.updateSelection(ids: [a.id], decision: .keep, rating: 4)
    try Data("changed! bytes".utf8).write(to: original)
    let resumed = try await ImportService(store: store).resume(sessionID: s.id, progress: { _ in })
    a = try XCTUnwrap(store.loadAssets().first)
    XCTAssertEqual(resumed.status, "completed")
    XCTAssertEqual(a.contentHash, priorHash)
    XCTAssertEqual(a.availability, .available)
    XCTAssertEqual(a.importState, .ready)
    XCTAssertTrue(a.error?.contains("源文件内容已改变") == true)
    XCTAssertEqual(a.decision, .keep)
    XCTAssertEqual(a.rating, 4)
    // Verified old managed bytes were never overwritten by changed source.
    XCTAssertEqual(try FileSafety.hash(a.resolvedURL), priorHash)
  }
  func testReferenceSameSizeRewriteRefreshAndResume() async throws {
    let original = try file("a.ARW", "aaaa")
    let s = try await runImport(initialScreening: true)
    let a = try XCTUnwrap(store.loadAssets().first)
    try Data("bbbb".utf8).write(to: original)
    try store.refreshAvailability(ids: [a.id])
    XCTAssertEqual(try store.loadAssets()[0].availability, .changed)
    let resumed = try await ImportService(store: store).resume(sessionID: s.id, progress: { _ in })
    XCTAssertEqual(resumed.failed, 1)
    XCTAssertEqual(try store.loadAssets()[0].contentHash, a.contentHash)
    XCTAssertTrue(try store.loadAdmissions().isEmpty)
  }
  func testSelectionUndoAtomicFailureAndReopen() async throws {
    try file("a.ARW")
    try file("b.ARW")
    _ = try await runImport()
    let assets = try store.loadAssets()
    let ids = assets.map(\.id)
    let undo = try store.updateSelection(ids: ids, decision: .keep, rating: 5)
    XCTAssertThrowsError(
      try store.updateSelection(ids: [ids[0], "missing"], decision: .reject, rating: 0))
    XCTAssertTrue(try store.loadAssets().allSatisfy { $0.decision == .keep && $0.rating == 5 })
    store = nil
    store = try LibraryStore(databaseURL: root.appendingPathComponent("catalog.sqlite"))
    try store.undoSelection(undo)
    XCTAssertTrue(try store.loadAssets().allSatisfy { $0.decision == .undecided && $0.rating == 0 })
    let rows = try operationRows()
    XCTAssertTrue(rows.contains { $0.action == "undoSelection" })
    XCTAssertTrue(rows.allSatisfy { !$0.device.isEmpty && $0.result >= $0.base })
  }
  func testManyToManyGroupsRejectAndSequenceAreIndependent() async throws {
    try file("a.ARW")
    try file("b.ARW")
    _ = try await runImport()
    let ids = try store.loadAssets().map(\.id)
    try store.createGroup(ids: ids, name: "Burst", kind: "连拍")
    try store.createGroup(ids: [ids[0]], name: "HDR", kind: "HDR")
    let groups = try store.loadGroups()
    XCTAssertEqual(groups.count, 2)
    _ = try store.updateSelection(ids: [ids[0]], decision: .reject, rating: nil)
    XCTAssertEqual(try store.loadGroups()[0].includedAssetIDs.count, 2)
    try store.setSequenceMembership(ids: [ids[0]], included: false, groupID: groups[0].id)
    let refreshed = try store.loadGroups()
    XCTAssertFalse(refreshed[0].includedAssetIDs.contains(ids[0]))
    XCTAssertTrue(refreshed[1].includedAssetIDs.contains(ids[0]))
    XCTAssertTrue(try store.loadAssets()[0].isSequenceMember)
    try store.reorderGroup(groupID: groups[0].id, assetIDs: ids.reversed())
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, Array(ids.reversed()))
    try store.renameGroup(id: groups[0].id, name: "Renamed")
    XCTAssertThrowsError(try store.mergeGroups(ids: groups.map(\.id), name: "Merged"))
    let merge = try store.previewGroupCommand(
      .merge(groupIDs: groups.map(\.id), name: "Merged", kind: "HDR"))
    _ = try store.commitGroupCommand(merge, participationResolutions: [ids[0]: true])
    XCTAssertEqual(try store.loadGroups().count, 1)
    XCTAssertEqual(try store.loadGroups()[0].includedAssetIDs.count, 2)
    let membershipOps = try operationRows().filter { $0.action == "sequenceMembership" }
    XCTAssertTrue(
      membershipOps.allSatisfy {
        $0.payload.contains("included") && $0.payload.contains("position")
      })
  }
  func testCrossProjectGroupRejected() async throws {
    try file("a.ARW")
    _ = try await runImport(name: "one")
    _ = try await runImport(name: "two")
    let ids = try store.loadAssets().map(\.id)
    XCTAssertThrowsError(try store.createGroup(ids: ids, name: "mixed", kind: "连拍"))
    XCTAssertEqual(try store.loadGroups().count, 0)
  }
  func testExportScopeManifestCollisionMissingAndRetry() async throws {
    try file("a.ARW", "first")
    let b = try file("nested/b.ARW", "second")
    _ = try await runImport()
    let assets = try store.loadAssets()
    let first = try XCTUnwrap(assets.first(where: { $0.filename == "a.ARW" }))
    let second = try XCTUnwrap(assets.first(where: { $0.filename == "b.ARW" }))
    _ = try store.updateSelection(ids: [first.id], decision: .keep, rating: 3)
    _ = try store.updateSelection(ids: [second.id], decision: .reject, rating: nil)
    let destination = root.appendingPathComponent("delivery")
    let conflict = destination.appendingPathComponent("RAWMaster精选/\(first.sessionID)/a.ARW")
    try FileManager.default.createDirectory(
      at: conflict.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("unrelated".utf8).write(to: conflict)
    try store.createGroup(ids: assets.map(\.id), name: "Manifest group", kind: "HDR")
    let g = try XCTUnwrap(store.loadGroups().first)
    try store.setSequenceMembership(ids: [second.id], included: false, groupID: g.id)
    let service = ExportService(store: store)
    let report = try await service.exportAssets(
      ids: [first.id], destination: destination, manifestIDs: assets.map(\.id), progress: { _ in })
    XCTAssertEqual(report.copied, 1)
    XCTAssertEqual(try String(contentsOf: conflict, encoding: .utf8), "unrelated")
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: report.manifestPath))) as! [String: Any]
    XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
    let manifestGroups = manifest["groups"] as! [[String: Any]]
    XCTAssertEqual(manifestGroups.count, 1)
    XCTAssertEqual(manifestGroups[0]["includedAssetIDs"] as? [String], [first.id])
    let items = manifest["items"] as! [[String: Any]]
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items.filter { $0["copyRequested"] as? Bool == true }.count, 1)
    let copiedPath = try XCTUnwrap(
      items.first(where: { $0["status"] as? String == "copied" })?["outputPath"] as? String)
    XCTAssertTrue(copiedPath.hasSuffix("a-1.ARW"))
    let retry = try await service.exportAssets(
      ids: [first.id], destination: destination, progress: { _ in })
    XCTAssertEqual(retry.copied, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: conflict.deletingLastPathComponent().appendingPathComponent("a-2.ARW").path))
    try FileManager.default.removeItem(at: b)
    let missing = try await service.exportAssets(
      ids: [second.id], destination: destination, manifestIDs: assets.map(\.id), progress: { _ in })
    XCTAssertEqual(missing.failed, 1)
    XCTAssertEqual(missing.copied, 0)
  }
  func testCanonicalSymlinkOverlapAndTraversalGuards() async throws {
    try file("a.ARW")
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    do {
      _ = try await ImportService(store: store).importDirectory(
        source: source, destination: alias.appendingPathComponent("new"), projectName: "bad",
        mode: .copy, progress: { _ in })
      XCTFail("accepted descendant alias")
    } catch {}
    _ = try await runImport()
    let id = try XCTUnwrap(store.loadAssets().first?.id)
    do {
      _ = try await ExportService(store: store).exportAssets(
        ids: [id], destination: alias, progress: { _ in })
      XCTFail("accepted source alias")
    } catch {}
    XCTAssertThrowsError(try FileSafety.safeRelative("../unsafe"))
    XCTAssertThrowsError(try FileSafety.safeRelative("/absolute"))
    let target = source.appendingPathComponent("nested/nonexistent/file.ARW")
    XCTAssertThrowsError(try FileSafety.checkTarget(target, sources: [source]))
    XCTAssertEqual(try store.loadAssets().count, 1)
  }
  func testExistingSessionCannotSilentlyChangeMode() async throws {
    try file("a.ARW")
    let session = try await runImport(initialScreening: true)
    do {
      _ = try await runImport(.copy, projectID: session.projectID, initialScreening: true)
      XCTFail("accepted silent mode change")
    } catch { XCTAssertTrue(error.localizedDescription.contains("接入方式")) }
  }
  func testCancelledImportDurableAndResumable() async throws {
    for i in 0..<80 { try file("\(i).ARW", String(repeating: "x", count: 1000)) }
    let service = ImportService(store: store)
    let session = try await service.importDirectory(
      source: source, destination: nil, projectName: "cancel", mode: .reference,
      progress: { p in if p.title == "扫描素材" { service.cancel() } })
    XCTAssertEqual(session.status, "cancelled")
    XCTAssertGreaterThan(try store.loadAssets().count, 0)
    let resumed = try await service.resume(sessionID: session.id, progress: { _ in })
    XCTAssertEqual(resumed.completed, 80)
    XCTAssertEqual(resumed.status, "completed")
  }
  func testCopyTargetFailureIsRecoverableAndNotABadPhoto() async throws {
    let original = try file("a.ARW", "original")
    let hash = try FileSafety.hash(original)
    let blocked = root.appendingPathComponent("work")
    try Data("existing file".utf8).write(to: blocked)
    let failed = try await runImport(.copy)
    XCTAssertEqual(failed.status, "partial")
    let a = try XCTUnwrap(store.loadAssets().first)
    XCTAssertEqual(a.importState, .failed)
    XCTAssertEqual(a.availability, .available)
    XCTAssertEqual(try FileSafety.hash(original), hash)
    try FileManager.default.removeItem(at: blocked)
    let resumed = try await ImportService(store: store).resume(
      sessionID: failed.id, progress: { _ in })
    XCTAssertEqual(resumed.completed, 1)
    XCTAssertEqual(resumed.failed, 0)
    XCTAssertEqual(try FileSafety.hash(store.loadAssets()[0].resolvedURL), hash)
  }
  func testCompletedManagedCopySurvivesSourceRemoval() async throws {
    try file("a.ARW", "card original")
    let session = try await runImport(.copy)
    let original = try XCTUnwrap(store.loadAssets(sessionID: session.id).first)
    try FileManager.default.removeItem(at: source)
    await assertSealedSessionCannotResume(session.id)
    store = try LibraryStore(databaseURL: root.appendingPathComponent("catalog.sqlite"))
    try store.refreshAvailability(ids: [original.id])
    let persisted = try XCTUnwrap(store.loadSessions().first { $0.id == session.id })
    XCTAssertEqual(persisted.completed, 1)
    XCTAssertEqual(persisted.status, "completed")
    let reopened = try XCTUnwrap(store.loadAssets(sessionID: session.id).first)
    XCTAssertEqual(reopened.importState, .ready)
    XCTAssertEqual(reopened.availability, .available)
    XCTAssertEqual(try FileSafety.hash(reopened.resolvedURL), original.contentHash)
    let report = try await ExportService(store: store).exportAssets(
      ids: store.loadAssets().map(\.id), destination: root.appendingPathComponent("delivery"),
      progress: { _ in })
    XCTAssertEqual(report.copied, 1)
    XCTAssertEqual(report.failed, 0)
  }
  func testExportCancellationWritesTruthfulFullScopeManifest() async throws {
    try file("a.ARW")
    try file("b.ARW")
    try file("c.ARW")
    _ = try await runImport()
    let assets = try store.loadAssets()
    let service = ExportService(store: store)
    let report = try await service.exportAssets(
      ids: assets.map(\.id), destination: root.appendingPathComponent("cancel-export"),
      progress: { p in if p.isRunning && p.completed == 1 { service.cancel() } })
    XCTAssertEqual(report.copied, 1)
    XCTAssertEqual(report.failed, 2)
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: report.manifestPath))) as! [String: Any]
    XCTAssertEqual(manifest["status"] as? String, "cancelled")
    XCTAssertEqual((manifest["items"] as? [[String: Any]])?.count, 3)
    let retry = try await service.exportAssets(
      ids: assets.map(\.id), destination: root.appendingPathComponent("cancel-export"),
      progress: { _ in })
    XCTAssertEqual(retry.copied, 3)
    XCTAssertEqual(retry.failed, 0)
  }
  func testConcurrentSelectionsHaveContiguousDurableRevisions() async throws {
    try file("a.ARW")
    _ = try await runImport()
    let id = try XCTUnwrap(store.loadAssets().first?.id)
    let safeStore = store!
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<30 {
        group.addTask {
          _ = try? safeStore.updateSelection(
            ids: [id], decision: i.isMultiple(of: 2) ? .keep : .reject, rating: i % 6)
        }
      }

    }
    let operations = try operationRows().filter { $0.result > 0 }
    XCTAssertGreaterThan(operations.count, 20)
    for (previous, next) in zip(operations, operations.dropFirst()) {
      XCTAssertEqual(previous.result, next.base)
    }
    XCTAssertTrue(try store.loadAssets()[0].rating <= 5)
  }

  func testExplicitNewProjectDoesNotAliasAnotherProjectsName() async throws {
    try file("a.ARW")
    let first = try await runImport(name: "同名项目")
    let second = try await runImport(name: "同名项目")
    XCTAssertNotEqual(first.projectID, second.projectID)
    XCTAssertEqual(try store.loadProjects().count, 2)
    XCTAssertEqual(try store.loadAssets().count, 2)
    let repeated = try await runImport(name: "同名项目", projectID: first.projectID)
    XCTAssertNotEqual(repeated.id, first.id)
    XCTAssertEqual(repeated.projectID, first.projectID)
    XCTAssertEqual(try store.loadProjects().count, 2)
    let occurrences = try [first, second, repeated].map { try XCTUnwrap(store.loadAssets(sessionID: $0.id).first) }
    XCTAssertEqual(Set(occurrences.map(\.id)).count, 3)
    XCTAssertEqual(Set(try store.catalogFiles(for: occurrences.map(\.id)).map(\.id)).count, 1)
    XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_catalog_files WHERE project_id=?", [first.projectID]), [["1"]])
    XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_catalog_files WHERE project_id=?", [second.projectID]), [["1"]])
    XCTAssertEqual(try store.rows("SELECT count(*),count(DISTINCT content_id),count(DISTINCT project_id) FROM lc_scopes"), [["3","1","2"]])
  }
  func testExplicitLightroomReconnectionSharesOnlyTheVerifiedOriginalAtThatLocation() async throws {
    let firstURL = try file("first.RAW", "same bytes")
    let differentURL = try file("separate.RAW", "same bytes")
    let initial = try await runImport()
    let files = try store.loadAssets(sessionID: initial.id)
    let first = try XCTUnwrap(files.first { $0.filename == "first.RAW" })
    let other = try XCTUnwrap(files.first { $0.filename == "separate.RAW" })
    let originalID = try XCTUnwrap(store.catalogFiles(for: [first.id]).first?.id)
    let otherID = try XCTUnwrap(store.catalogFiles(for: [other.id]).first?.id)
    XCTAssertNotEqual(originalID, otherID)
    let project = ProjectRecord(name: "Lightroom")
    try store.saveProject(project)
    XCTAssertThrowsError(try store.admitLightroomOriginal(firstURL, projectID: "missing-project"))
    XCTAssertEqual(try store.admitLightroomOriginal(firstURL, projectID: project.id), originalID)
    XCTAssertEqual(try store.admitLightroomOriginal(differentURL, projectID: project.id), otherID)
    XCTAssertEqual(try store.admitLightroomOriginal(firstURL, projectID: project.id), originalID)
    XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_scopes WHERE project_id=?", [project.id]), [["2"]])
    try Data("new version".utf8).write(to: firstURL)
    let changed = try store.admitLightroomOriginal(firstURL, projectID: project.id)
    XCTAssertNotEqual(changed, originalID)
    XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_scopes WHERE project_id=?", [project.id]), [["3"]])
    XCTAssertEqual(try store.rows("SELECT count(*) FROM lc_contents"), [["2"]])
  }
  struct Operation {
    var action: String
    var payload: String
    var device: String
    var base: Int
    var result: Int
  }
  func operationRows() throws -> [Operation] {
    // Read through an independent SQLite connection to verify actual durability rather than implementation mirrors.
    var db: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db) == SQLITE_OK else {
      throw LibraryError.invalid("test DB open")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(
      db,
      "SELECT action,payload,device_id,base_revision,resulting_revision FROM operations ORDER BY rowid",
      -1, &stmt, nil)
    defer { sqlite3_finalize(stmt) }
    var rows: [Operation] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      rows.append(
        Operation(
          action: String(cString: sqlite3_column_text(stmt, 0)),
          payload: String(cString: sqlite3_column_text(stmt, 1)),
          device: String(cString: sqlite3_column_text(stmt, 2)),
          base: Int(sqlite3_column_int(stmt, 3)), result: Int(sqlite3_column_int(stmt, 4))))
    }
    return rows
  }
}
