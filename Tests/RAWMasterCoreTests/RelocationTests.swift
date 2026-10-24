import XCTest

@testable import RAWMasterCore

final class RelocationTests: XCTestCase {
  func testManagedSelectedChildNeverScansSiblingDirectory() async throws {
    try file("a.ARW", "first")
    let s = try await imported(.copy)
    let container = root.appendingPathComponent("new-work")
    try FileManager.default.moveItem(at: root.appendingPathComponent("work"), to: container)
    let child = container.appendingPathComponent("RAWMaster-" + s.id)
    try Data("first".utf8).write(to: container.appendingPathComponent("sibling.ARW"))
    let report = try await scan(s, child, role: .managed)
    XCTAssertEqual(report.scanRootPath, child.path)
    XCTAssertEqual(report.rootPath, container.path)
    XCTAssertEqual(report.items[0].status, .matched)
    XCTAssertEqual(report.items[0].candidates.count, 1)
    XCTAssertEqual(report.items[0].candidates[0].path, child.appendingPathComponent("a.ARW").path)
  }
  func testOldPathRestoredAfterHashingBeforeCommitIsStale() async throws {
    try file("a.ARW", "first")
    let s = try await imported()
    let old = try store.loadAssets()[0]
    let moved = try movedSource()
    let report = try await scan(s, moved)
    let originalRoot = source!
    let originalFile = source.appendingPathComponent("a.ARW")
    let result = try await RelocationService(store: store).confirm(
      sessionID: report.id,
      progress: { p in
        if p.isRunning {
          try? FileManager.default.createDirectory(
            at: originalRoot, withIntermediateDirectories: true)
          try? Data("first".utf8).write(to: originalFile)
        }
      })
    XCTAssertEqual(result.items[0].status, .stale)
    XCTAssertEqual(try store.loadAssets()[0].currentPath, old.currentPath)
  }
  func testOldPartialReportCannotRewindRootAfterLaterRelocation() async throws {
    try file("a.ARW", "first")
    try file("b.ARW", "second")
    let s = try await imported()
    let moved = try movedSource()
    try FileManager.default.removeItem(at: moved.appendingPathComponent("b.ARW"))
    let service = RelocationService(store: store)
    let first = try await scan(s, moved)
    _ = try await service.confirm(sessionID: first.id, progress: { _ in })
    let third = root.appendingPathComponent("third")
    try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: third.appendingPathComponent("a.ARW"))
    let a = try XCTUnwrap(store.loadAssets().first(where: { $0.filename == "a.ARW" }))
    let second = try await service.scan(
      sessionID: s.id, assetIDs: [a.id], root: third, role: .source, progress: { _ in })
    _ = try await service.confirm(sessionID: second.id, progress: { _ in })
    XCTAssertEqual(try store.loadSessions()[0].effectiveSourceRoot, third.path)
    _ = try await service.resume(id: first.id, progress: { _ in })
    _ = try await service.confirm(sessionID: first.id, progress: { _ in })
    XCTAssertEqual(try store.loadSessions()[0].effectiveSourceRoot, third.path)
    _ = try await service.resume(id: second.id, progress: { _ in })
    XCTAssertEqual(try store.loadSessions()[0].effectiveSourceRoot, third.path)
  }
  func testDuplicateContentReportStopsWithinSerializedBudgetAndIsExplicitlyIncomplete() async throws
  {
    let s = ImportSession(
      projectID: "project", projectName: "many", sourcePath: source.path, mode: .reference)
    try store.saveProject(ProjectRecord(id: "project", name: "many"))
    try store.saveSession(s)
    try file("identity.ARW", "same")
    let hash = try FileSafety.hash(source.appendingPathComponent("identity.ARW"))
    for i in 0..<500 {
      _ = try store.register(
        AssetRecord(
          sessionID: s.id, projectID: s.projectID,
          sourcePath: source.appendingPathComponent("old-\(i).ARW").path, fileSize: 4,
          contentHash: hash, importState: .ready))
    }
    let candidates = root.appendingPathComponent("duplicates")
    try FileManager.default.createDirectory(at: candidates, withIntermediateDirectories: true)
    for i in 0..<100 {
      try Data("same".utf8).write(to: candidates.appendingPathComponent("\(i).ARW"))
    }
    let report = try await scan(s, candidates)
    XCTAssertFalse(report.scanComplete)
    XCTAssertTrue(report.message.contains("内存上限"))
    XCTAssertLessThan(try JSONEncoder().encode(report).count, 24 * 1024 * 1024)
    XCTAssertTrue(report.items.allSatisfy { $0.selectedPath == nil })
    XCTAssertEqual(try store.loadAssets().count, 500)
  }
  var root: URL!
  var source: URL!
  var database: URL!
  var store: LibraryStore!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RAWMasterRelocation-" + UUID().uuidString)
    source = root.appendingPathComponent("card")
    database = root.appendingPathComponent("library.sqlite")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    store = try LibraryStore(databaseURL: database)
  }
  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: root)
  }
  func file(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: source.appendingPathComponent(name))
  }
  func imported(_ mode: ImportMode = .reference) async throws -> ImportSession {
    try await ImportService(store: store).importDirectory(
      source: source, destination: mode == .copy ? root.appendingPathComponent("work") : nil,
      projectName: "Project", mode: mode, progress: { _ in })
  }
  func movedSource() throws -> URL {
    let moved = root.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: source, to: moved)
    return moved
  }
  func scan(_ s: ImportSession, _ moved: URL, role: RelocationRole = .source) async throws
    -> RelocationSession
  {
    try await RelocationService(store: store).scan(
      sessionID: s.id, root: moved, role: role, progress: { _ in })
  }
  func testReferencePreviewDeselectAndAtomicConfirmationPreservesHumanWork() async throws {
    try file("a.ARW", "first")
    let s = try await imported()
    let before = try XCTUnwrap(store.loadAssets().first)
    _ = try store.updateSelection(ids: [before.id], decision: .keep, rating: 2)
    try store.createGroup(ids: [before.id], name: "Manual", kind: "HDR")
    let moved = try movedSource()
    let service = RelocationService(store: store)
    let preview = try await scan(s, moved)
    XCTAssertEqual(preview.matchedCount, 1)
    XCTAssertEqual(try store.loadAssets()[0].currentPath, before.currentPath)
    _ = try service.chooseCandidate(sessionID: preview.id, assetID: before.id, path: nil)
    let deselected = try await service.confirm(sessionID: preview.id, progress: { _ in })
    XCTAssertEqual(deselected.committedCount, 0)
    let fresh = try await scan(s, moved)
    let safeStore = store!
    let committed = try await service.confirm(
      sessionID: fresh.id,
      progress: { p in
        if p.isRunning {
          _ = try? safeStore.updateSelection(ids: [before.id], decision: nil, rating: 5)
        }
      })
    let a = try store.loadAssets()[0]
    XCTAssertEqual(committed.status, "completed")
    XCTAssertEqual(a.id, before.id)
    XCTAssertEqual(a.sourcePath, before.sourcePath)
    XCTAssertEqual(a.resolvedSourceURL.path, moved.appendingPathComponent("a.ARW").path)
    XCTAssertEqual(a.currentPath, a.resolvedSourceURL.path)
    XCTAssertEqual(a.decision, .keep)
    XCTAssertEqual(a.rating, 5)
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, [a.id])
    XCTAssertTrue(try store.loadGroups()[0].locked)
    store = nil
    store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.loadAssets()[0].currentPath, a.currentPath)
  }
  func testPartialRelocationNeverRedirectsUnmatchedAndResumeDoesNotDuplicate() async throws {
    try file("a.ARW", "first")
    try file("b.ARW", "second")
    let s = try await imported()
    let original = try store.loadAssets()
    let b = try XCTUnwrap(original.first(where: { $0.filename == "b.ARW" }))
    _ = try store.updateSelection(ids: [b.id], decision: .keep, rating: 5)
    let moved = try movedSource()
    try FileManager.default.removeItem(at: moved.appendingPathComponent("b.ARW"))
    let preview = try await scan(s, moved)
    let result = try await RelocationService(store: store).confirm(
      sessionID: preview.id, progress: { _ in })
    XCTAssertEqual(result.status, "partial")
    XCTAssertEqual(result.committedCount, 1)
    XCTAssertEqual(
      try store.loadAssets().first(where: { $0.id == b.id })?.currentPath, b.currentPath)
    _ = try await ImportService(store: store).resume(sessionID: s.id, progress: { _ in })
    XCTAssertEqual(try store.loadAssets().count, 2)
    // Same relative path with new bytes must not be adopted or get the old decision.
    try Data("new!!!".utf8).write(to: moved.appendingPathComponent("b.ARW"))
    _ = try await ImportService(store: store).resume(sessionID: s.id, progress: { _ in })
    let after = try XCTUnwrap(store.loadAssets().first(where: { $0.id == b.id }))
    XCTAssertEqual(after.resolvedSourceURL.path, b.sourcePath)
    XCTAssertEqual(after.contentHash, b.contentHash)
    XCTAssertEqual(after.availability, .changed)
    XCTAssertEqual(try store.loadAssets().count, 2)
    do {
      _ = try await ExportService(store: store).exportAssets(
        ids: [original[0].id], destination: moved, progress: { _ in })
      XCTFail("writes to relocated source accepted")
    } catch {}
  }
  func testSourceRoleInCopyModePreservesManagedBytesAndRootRoles() async throws {
    try file("a.ARW", "camera card")
    let s = try await imported(.copy)
    let old = try store.loadAssets()[0]
    let moved = try movedSource()
    let preview = try await scan(s, moved)
    _ = try await RelocationService(store: store).confirm(sessionID: preview.id, progress: { _ in })
    let a = try store.loadAssets()[0]
    let session = try store.loadSessions()[0]
    XCTAssertEqual(a.currentPath, old.currentPath)
    XCTAssertEqual(a.sourcePath, old.sourcePath)
    XCTAssertEqual(a.effectiveSourcePath, moved.appendingPathComponent("a.ARW").path)
    XCTAssertEqual(session.destinationPath, s.destinationPath)
    XCTAssertNil(session.effectiveManagedRoot)
    XCTAssertEqual(session.sourcePath, s.sourcePath)
    _ = try await ImportService(store: store).resume(sessionID: s.id, progress: { _ in })
    XCTAssertEqual(try store.loadAssets().count, 1)
    XCTAssertEqual(try FileSafety.hash(a.resolvedURL), old.contentHash)
  }
  func testMixedRelativeAndRenamedMatchesResumeWithoutDuplicateDiscovery() async throws {
    try file("a.ARW", "first")
    try file("b.ARW", "second")
    let s = try await imported()
    let moved = try movedSource()
    try FileManager.default.moveItem(
      at: moved.appendingPathComponent("b.ARW"), to: moved.appendingPathComponent("renamed.ARW"))
    let preview = try await scan(s, moved)
    let committed = try await RelocationService(store: store).confirm(
      sessionID: preview.id, progress: { _ in })
    XCTAssertEqual(committed.committedCount, 2)
    _ = try await ImportService(store: store).resume(sessionID: s.id, progress: { _ in })
    XCTAssertEqual(try store.loadAssets().count, 2)
    XCTAssertEqual(
      try store.loadAssets().first(where: { $0.filename == "b.ARW" })?.resolvedSourceURL
        .lastPathComponent, "renamed.ARW")
  }
  func testCancellationAfterOnlyCandidateCannotPublishReview() async throws {
    try file("a.ARW", "first")
    let s = try await imported()
    let moved = try movedSource()
    let service = RelocationService(store: store)
    let cancelled = try await service.scan(
      sessionID: s.id, root: moved, role: .source,
      progress: { p in if p.isRunning { service.cancel() } })
    XCTAssertEqual(cancelled.status, "cancelled")
    XCTAssertEqual(cancelled.items.first?.candidates.count, 1)
    do {
      _ = try await service.confirm(sessionID: cancelled.id, progress: { _ in })
      XCTFail("last-candidate cancellation ignored")
    } catch {}
    let resumed = try await service.resume(id: cancelled.id, progress: { _ in })
    XCTAssertEqual(resumed.matchedCount, 1)
  }
  func testManagedContainerRelocationResumeAppendsSessionFolderOnlyOnce() async throws {
    try file("a.ARW", "first")
    let s = try await imported(.copy)
    let old = try store.loadAssets()[0]
    let moved = root.appendingPathComponent("new-work")
    try FileManager.default.moveItem(at: root.appendingPathComponent("work"), to: moved)
    // Accept choosing the session folder, but persist its parent container.
    let preview = try await scan(
      s, moved.appendingPathComponent("RAWMaster-" + s.id), role: .managed)
    XCTAssertEqual(preview.rootPath, moved.path)
    _ = try await RelocationService(store: store).confirm(sessionID: preview.id, progress: { _ in })
    try file("c.ARW", "third")
    _ = try await ImportService(store: store).resume(sessionID: s.id, progress: { _ in })
    let assets = try store.loadAssets()
    XCTAssertEqual(assets.count, 2)
    XCTAssertEqual(assets.first(where: { $0.id == old.id })?.sourcePath, old.sourcePath)
    let c = try XCTUnwrap(assets.first(where: { $0.filename == "c.ARW" }))
    XCTAssertEqual(c.currentPath, moved.appendingPathComponent("RAWMaster-" + s.id + "/c.ARW").path)
    XCTAssertEqual(try store.loadSessions()[0].effectiveManagedRoot, moved.path)
    do {
      _ = try await ExportService(store: store).exportAssets(
        ids: [c.id], destination: moved, progress: { _ in })
      XCTFail("writes into managed container accepted")
    } catch {}
  }
  func testAmbiguityNoHashDifferentBytesAndOutsideSymlink() async throws {
    try file("a.ARW", "same")
    try file("b.ARW", "other")
    let s = try await imported()
    let a = try XCTUnwrap(store.loadAssets().first(where: { $0.filename == "a.ARW" }))
    let b = try XCTUnwrap(store.loadAssets().first(where: { $0.filename == "b.ARW" }))
    let moved = try movedSource()
    try Data("same".utf8).write(to: moved.appendingPathComponent("duplicate.ARW"))
    try Data("wrong".utf8).write(to: moved.appendingPathComponent("b.ARW"))
    let outside = root.appendingPathComponent("outside.ARW")
    try Data("same".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: moved.appendingPathComponent("escaped.ARW"), withDestinationURL: outside)
    let preview = try await scan(s, moved)
    let item = try XCTUnwrap(preview.items.first(where: { $0.assetID == a.id }))
    XCTAssertEqual(item.status, .ambiguous)
    XCTAssertEqual(item.candidates.count, 2)
    XCTAssertNil(item.selectedPath)
    XCTAssertEqual(preview.items.first(where: { $0.assetID == b.id })?.status, .differentContent)
    let service = RelocationService(store: store)
    _ = try service.chooseCandidate(
      sessionID: preview.id, assetID: a.id, path: item.candidates[1].path)
    store = nil
    store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(
      try store.loadRelocationSessions()[0].items.first(where: { $0.assetID == a.id })?
        .selectedPath, item.candidates[1].path)
    var noHash = try store.loadAssets().first(where: { $0.id == b.id })!
    noHash.contentHash = nil
    try store.saveImportAsset(noHash)
    let next = try await scan(s, moved)
    XCTAssertEqual(next.items.first(where: { $0.assetID == b.id })?.status, .noHash)
  }
  func testCancellationPersistsAndBlocksLateCommitThenResumeRevalidates() async throws {
    try file("a.ARW", "first")
    try file("b.ARW", "second")
    let s = try await imported()
    let originals = try store.loadAssets()
    let moved = try movedSource()
    let service = RelocationService(store: store)
    let cancelled = try await service.scan(
      sessionID: s.id, root: moved, role: .source,
      progress: { p in if p.isRunning { service.cancel() } })
    XCTAssertEqual(cancelled.status, "cancelled")
    do {
      _ = try await service.confirm(sessionID: cancelled.id, progress: { _ in })
      XCTFail("cancelled scan committed")
    } catch {}
    store = nil
    store = try LibraryStore(databaseURL: database)
    let next = RelocationService(store: store)
    let resumed = try await next.resume(id: cancelled.id, progress: { _ in })
    XCTAssertEqual(resumed.matchedCount, 2)
    let cancelledCommit = try await next.confirm(
      sessionID: resumed.id, progress: { p in if p.isRunning { next.cancel() } })
    XCTAssertEqual(cancelledCommit.status, "cancelled")
    XCTAssertEqual(try store.loadAssets().map(\.currentPath), originals.map(\.currentPath))
  }
  func testCandidateChangeLocationRaceAndRestoredOldPathAreDetected() async throws {
    try file("a.ARW", "first")
    let s = try await imported()
    let old = try store.loadAssets()[0]
    let moved = try movedSource()
    let service = RelocationService(store: store)
    let preview = try await scan(s, moved)
    try Data("wrong".utf8).write(to: moved.appendingPathComponent("a.ARW"))
    let stale = try await service.confirm(sessionID: preview.id, progress: { _ in })
    XCTAssertEqual(stale.items[0].status, .stale)
    XCTAssertEqual(try store.loadAssets()[0].currentPath, old.currentPath)
    try Data("first".utf8).write(to: moved.appendingPathComponent("a.ARW"))
    let next = try await scan(s, moved)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: source.appendingPathComponent("a.ARW"))
    let restored = try await service.confirm(sessionID: next.id, progress: { _ in })
    XCTAssertEqual(restored.items[0].status, .stale)
    try FileManager.default.removeItem(at: source)
    let race = try await scan(s, moved)
    let safeStore = store!
    let raced = try await service.confirm(
      sessionID: race.id,
      progress: { p in
        if p.isRunning {
          var a = old
          a.effectiveSourcePath = "/different/location"
          try? safeStore.saveImportAsset(a)
        }
      })
    XCTAssertEqual(raced.items[0].status, .stale)
    XCTAssertEqual(try store.loadAssets()[0].effectiveSourcePath, "/different/location")
  }
}
