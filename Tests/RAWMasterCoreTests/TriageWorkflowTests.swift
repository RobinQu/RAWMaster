import CSQLite
import XCTest
@testable import RAWMasterCore

final class TriageWorkflowTests: XCTestCase {
  var root: URL!
  var database: URL!
  var store: LibraryStore!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("Triage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = root.appendingPathComponent("library.sqlite")
    store = try LibraryStore(databaseURL: database)
  }
  override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }
  func batch(count: Int = 3, target: ProjectRecord? = nil) throws -> (ImportSession, [AssetRecord]) {
    let project = target ?? ProjectRecord(name: "New")
    try store.saveProject(project)
    let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: root.appendingPathComponent(UUID().uuidString).path, mode: .reference, status: "completed", discovered: count, completed: count, scanCompleted: true)
    try store.saveSession(session); try store.beginTriage(session, isNewProject: target == nil)
    var assets: [AssetRecord] = []
    for i in 0..<count {
      let url = root.appendingPathComponent(session.id).appendingPathComponent("\(i).ARW")
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("asset-\(i)".utf8).write(to: url)
      let a = AssetRecord(sessionID: session.id, projectID: project.id, projectName: project.name, sourcePath: url.path, relativePath: "\(i).ARW", fileSize: Int64(7), capturedAt: Date(timeIntervalSince1970: 1000 + Double(i)), camera: "Camera", width: 100, height: 100, contentHash: try FileSafety.hash(url), importState: .ready)
      assets.append(try store.register(a))
    }
    return (session, assets)
  }
  func testInitialImportHasAtomicHiddenDraftAndIndependentTriage() async throws {
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source.appendingPathComponent("a.ARW"))
    let session = try await ImportService(store: store).importDirectory(source: source, destination: nil, projectName: "Draft", mode: .reference, initialScreening: true, progress: { _ in })
    XCTAssertTrue(try store.publishedProjects().isEmpty)
    XCTAssertTrue(try store.loadAdmissions().isEmpty)
    XCTAssertEqual(try store.loadWorkflows().first?.phase, .screening)
    let a = try XCTUnwrap(store.loadAssets().first)
    _ = try store.updateTriage(ids: [a.id], disposition: .passed)
    XCTAssertEqual(try store.loadAssets()[0].decision, .undecided)
    XCTAssertEqual(try store.loadAssets()[0].rating, 0)
    XCTAssertFalse(try store.previewCompletion(sessionID: session.id).canCommit)
    let preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertTrue(preview.canCommit)
    _ = try store.commitCompletion(preview)
    XCTAssertEqual(try store.publishedProjects().map(\.id), [session.projectID])
    XCTAssertEqual(try store.loadAdmissions().map(\.assetID), [a.id])
    XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a.ARW")), Data("original".utf8))
  }
  func testCloseCASIdempotentAcrossReopenAndRejectsOldImportWrites() throws {
    let (session, assets) = try batch()
    let old = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    _ = try store.updateTriage(ids: [assets[0].id], disposition: .review)
    XCTAssertThrowsError(try store.commitCompletion(old))
    let preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertEqual(preview.reviewAssetIDs, [assets[0].id])
    let closed = try store.commitCompletion(preview)
    XCTAssertEqual(closed.phase, .closed)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.commitCompletion(preview).closedAt, closed.closedAt)
    XCTAssertEqual(try store.loadAdmissions().count, 3)
    XCTAssertThrowsError(try store.saveSession(session))
    XCTAssertThrowsError(try store.saveImportAsset(assets[0]))
    XCTAssertThrowsError(try store.register(assets[0]))
    XCTAssertThrowsError(try store.setImportActive(session.id, active: true))
    var mutated = preview; mutated.admittedAssetIDs = []
    XCTAssertThrowsError(try store.commitCompletion(mutated))
  }
  func testImportLeaseBlocksCloseAndResumeCanClearCrashState() throws {
    let (session, _) = try batch()
    try store.setImportActive(session.id, active: true)
    XCTAssertFalse(try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true).canCommit)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertFalse(try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true).canCommit)
    try store.setImportActive(session.id, active: false)
    XCTAssertTrue(try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true).canCommit)
  }
  func testAllExcludedClosesWithoutPublishingProjectAndRestoresWithoutOverwritingMetadata() throws {
    let (session, assets) = try batch(count: 2)
    _ = try store.updateTriage(ids: assets.map(\.id), disposition: .excluded)
    let preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertTrue(preview.admittedAssetIDs.isEmpty)
    _ = try store.commitCompletion(preview)
    XCTAssertTrue(try store.publishedProjects().isEmpty)
    _ = try store.restoreArchivedAssets(sessionID: session.id, assetIDs: [assets[0].id])
    _ = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 5)
    try store.setTags(ids: [assets[0].id], tags: ["Bird", "Bird", " Sunset "])
    XCTAssertTrue(try store.restoreArchivedAssets(sessionID: session.id, assetIDs: [assets[0].id]).isEmpty)
    XCTAssertEqual(try store.loadAssets()[0].rating, 5)
    XCTAssertEqual(try store.loadTags()[assets[0].id], ["Bird", "Sunset"])
    XCTAssertEqual(try store.publishedProjects().count, 1)
  }
  func testAppendDoesNotPublishUntilCommitOrResetExistingDecisions() throws {
    let (oldSession, oldAssets) = try batch(count: 1)
    _ = try store.commitCompletion(store.previewCompletion(sessionID: oldSession.id, acknowledgeManualAnalysis: true))
    _ = try store.updateSelection(ids: [oldAssets[0].id], decision: .keep, rating: 4)
    let target = try XCTUnwrap(store.loadProjects().first)
    let (next, assets) = try batch(count: 1, target: target)
    XCTAssertEqual(try store.loadAdmissions().map(\.assetID), [oldAssets[0].id])
    _ = try store.commitCompletion(store.previewCompletion(sessionID: next.id, acknowledgeManualAnalysis: true))
    XCTAssertEqual(Set(try store.loadAdmissions().map(\.assetID)), Set([assets[0].id, oldAssets[0].id]))
    XCTAssertEqual(try store.loadAssets().first { $0.id == oldAssets[0].id }?.rating, 4)
    XCTAssertEqual(try store.loadAssets().first { $0.id == assets[0].id }?.decision, .undecided)
  }
  func testExcludedBurstAndRequiredIntervalStayExcludedUnlessExplicitlyAdmitted() throws {
    let (session, assets) = try batch(count: 3)
    try store.createGroup(ids: [assets[0].id, assets[1].id], name: "Burst", kind: "连拍")
    try store.createGroup(ids: [assets[2].id], name: "Interval", kind: "间隔序列")
    _ = try store.updateTriage(ids: [assets[0].id, assets[2].id], disposition: .excluded)
    let preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertEqual(Set(preview.excludedAssetIDs), Set([assets[0].id, assets[2].id]))
    XCTAssertTrue(preview.sequenceOnlyAssetIDs.isEmpty)
    let before = try store.loadGroups()
    _ = try store.commitCompletion(preview)
    XCTAssertNil(try store.loadAdmissions().first { $0.assetID == assets[2].id })
    XCTAssertEqual(try store.loadGroups().flatMap(\.assetIDs), before.flatMap(\.assetIDs))
  }
  func testTriageUndoPersistsAndRefusesNewerHumanChange() throws {
    let (session, assets) = try batch(count: 1)
    let first = try store.updateTriage(ids: [assets[0].id], disposition: .excluded)
    store = nil; store = try LibraryStore(databaseURL: database)
    try store.undoTriage(commandID: first.id)
    XCTAssertEqual(try store.loadTriageRecords(sessionID: session.id).first?.disposition, .pending)
    let next = try store.updateTriage(ids: [assets[0].id], disposition: .excluded)
    _ = try store.updateTriage(ids: [assets[0].id], disposition: .passed)
    XCTAssertThrowsError(try store.undoTriage(commandID: next.id))
    XCTAssertEqual(try store.loadTriageRecords().first?.disposition, .passed)
  }
  func testPairingIsConservativeManualUnlinkProtectedAndDoesNotChangeDecisions() throws {
    let (session, assets) = try batch(count: 1)
    var jpeg = assets[0]; jpeg.id = UUID().uuidString; jpeg.filename = "0.JPG"; jpeg.relativePath = "0.JPG"; jpeg.sourcePath = root.appendingPathComponent("0.JPG").path; jpeg.currentPath = jpeg.sourcePath
    try Data("asset-0".utf8).write(to: jpeg.url)
    _ = try store.register(jpeg)
    _ = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 5)
    _ = try store.updateSelection(ids: [jpeg.id], decision: .reject, rating: 1)
    let pair = try XCTUnwrap(store.scanCapturePairs(sessionID: session.id).first)
    XCTAssertEqual(try store.loadAssets()[0].rating, 5)
    XCTAssertEqual(try store.loadAssets()[1].rating, 1)
    try store.unlinkCapturePair(id: pair.id)
    XCTAssertTrue(try store.scanCapturePairs(sessionID: session.id).isEmpty)
    _ = try store.confirmCapturePair(rawAssetID: assets[0].id, jpegAssetID: jpeg.id)
    let preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertEqual(preview.captureCount, 1)
    _ = try store.commitCompletion(preview)
    XCTAssertEqual(try store.exportSelection(ids: [assets[0].id], formats: .both).assetIDs.count, 2)
    XCTAssertEqual(try store.exportSelection(ids: [assets[0].id], formats: .jpegOnly).assetIDs, [jpeg.id])
  }
  func testPairingDoesNotGuessMissingMetadataOrCrossDirectories() throws {
    let (session, assets) = try batch(count: 1)
    var jpeg = assets[0]; jpeg.id = UUID().uuidString; jpeg.filename = "0.JPG"; jpeg.relativePath = "other/0.JPG"; jpeg.sourcePath = root.appendingPathComponent("0.JPG").path; jpeg.currentPath = jpeg.sourcePath; jpeg.camera = nil
    _ = try store.register(jpeg)
    XCTAssertTrue(try store.scanCapturePairs(sessionID: session.id).isEmpty)
    let pair = try store.confirmCapturePair(rawAssetID: assets[0].id, jpegAssetID: jpeg.id)
    XCTAssertTrue(pair.isManual)
  }
  func testWeakLegacyPairRequiresAUserDecisionBeforeFolding() throws {
    let (session, sources) = try batch(count: 1)
    let raw = sources[0]
    var jpeg = raw
    jpeg.id = UUID().uuidString; jpeg.filename = "other.JPG"; jpeg.relativePath = "other.JPG"
    jpeg.sourcePath = root.appendingPathComponent("other.JPG").path; jpeg.currentPath = jpeg.sourcePath
    try Data("asset-0".utf8).write(to:jpeg.url)
    _ = try store.register(jpeg)
    let legacy = CapturePair(sessionID:session.id,rawAssetID:raw.id,jpegAssetID:jpeg.id,isManual:false)
    try store.transaction { try store.statement("INSERT INTO capture_pairs VALUES(?,?)", [legacy.id,try store.json(legacy)]) }
    XCTAssertTrue(try store.loadCapturePairs(sessionID:session.id).isEmpty)
    let candidate = try XCTUnwrap(store.capturePairCandidates(sessionID:session.id).first)
    try store.dismissCapturePairCandidate(candidate)
    XCTAssertTrue(try store.capturePairCandidates(sessionID:session.id).isEmpty)
    let confirmed = try store.confirmCapturePair(rawAssetID:raw.id,jpegAssetID:jpeg.id)
    XCTAssertEqual(try store.loadCapturePairs(sessionID:session.id).filter(\.isManual).map(\.id),[confirmed.id])
    try store.unlinkCapturePair(id:confirmed.id)
    XCTAssertTrue(try store.scanCapturePairs(sessionID:session.id).isEmpty)
    XCTAssertTrue(try store.loadAdmissions().isEmpty)
  }
  func testFaultyFileRequiresExplicitExclusionAndDoesNotRejectPartner() throws {
    let (session, assets) = try batch(count: 2)
    var failed = assets[0]; failed.importState = .failed; failed.availability = .missing
    try store.saveImportAsset(failed)
    var preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertFalse(preview.canCommit)
    _ = try store.updateTriage(ids: [failed.id], disposition: .excluded)
    preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true, confirmedFailures: true)
    XCTAssertTrue(preview.canCommit)
    XCTAssertEqual(preview.admittedAssetIDs, [assets[1].id])
    XCTAssertEqual(preview.failedAssetIDs, [failed.id])
  }
  func testStaleQualityAndStagingExportManifestAreRejected() async throws {
    let (session, assets) = try batch(count: 1)
    let evidence = TriageQualityEvidence(assetID: assets[0].id, contentHash: "wrong", fileSize: assets[0].fileSize, source: "jpegPreview", methodVersion: "test", status: .risk)
    XCTAssertThrowsError(try store.saveQualityEvidence(evidence))
    let out = root.appendingPathComponent("out")
    do {
      _ = try await ExportService(store: store).exportAssets(ids: [], destination: out, manifestIDs: [assets[0].id], progress: { _ in })
      XCTFail("Manifest-only staging export must fail")
    } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: out.path)) }
    XCTAssertThrowsError(try store.exportSelection(ids: [assets[0].id]))
    _ = try store.commitCompletion(store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true))
    let (_, second) = try batch(count: 1)
    do {
      _ = try await ExportService(store: store).exportAssets(ids: [assets[0].id], destination: out, manifestIDs: second.map(\.id), progress: { _ in })
      XCTFail("Copy-selected asset must not leak staging manifest")
    } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: out.path)) }
  }
  func testVersionThreeUpgradePreservesBusinessAndCreatesConsistentBackup() throws {
    let (session, assets) = try batch(count: 1)
    // Recreate a strict v3 fixture using this isolated connection, then reopen through migration.
    _ = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 5)
    try removeEditingSchemaForLegacyFixture(store)
    for table in ["asset_color_labels", "review_records", "project_review_states", "tag_commands", "tag_domains", "session_workflows", "project_admissions", "triage_records", "capture_pairs", "pair_dismissals", "triage_commands", "quality_evidence", "asset_tags", "workflow_completions"] { try store.exec("DROP TABLE \(table)") }
    try store.exec("PRAGMA user_version=3")
    store = nil; store = try LibraryStore(databaseURL: database)
    let backup = try XCTUnwrap(store.lastMigrationBackupURL)
    var old: OpaquePointer?; XCTAssertEqual(sqlite3_open_v2(backup.path, &old, SQLITE_OPEN_READONLY, nil), SQLITE_OK); defer { sqlite3_close(old) }
    XCTAssertEqual(try DatabaseSchema.strings(old, "PRAGMA user_version"), ["3"])
    XCTAssertEqual(try store.loadWorkflows().first { $0.id == session.id }?.phase, .legacyHistory)
    XCTAssertEqual(try store.loadAdmissions().map(\.assetID), [assets[0].id])
    XCTAssertEqual(try store.loadAssets()[0].rating, 5)
    XCTAssertEqual(try store.loadAssets()[0].decision, .keep)
  }
  func testSequenceOnlyCompanionRequiresExplicitExportSelection() throws {
    let (session, assets) = try batch(count: 1)
    var jpeg = assets[0]; jpeg.id = UUID().uuidString; jpeg.filename = "0.JPG"; jpeg.relativePath = "0.JPG"; jpeg.sourcePath = root.appendingPathComponent("0.JPG").path; jpeg.currentPath = jpeg.sourcePath
    try Data("asset-0".utf8).write(to: jpeg.url)
    _ = try store.register(jpeg)
    _ = try store.confirmCapturePair(rawAssetID: assets[0].id, jpegAssetID: jpeg.id)
    try store.createGroup(ids: [jpeg.id], name: "Interval", kind: "延时")
    _ = try store.updateTriage(ids: [jpeg.id], disposition: .excluded)
    let member = try XCTUnwrap(store.completionMembers(sessionID: session.id).first { $0.assetID == jpeg.id })
    _ = try store.commitCompletion(store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true,
                                                           dispositions: [member.id: .sequenceOnly]))
    let implicit = try store.exportSelection(ids: [assets[0].id], formats: .both)
    XCTAssertEqual(implicit.assetIDs, [assets[0].id])
    XCTAssertEqual(implicit.missingFormats.count, 1)
    XCTAssertEqual(try store.exportSelection(ids: [assets[0].id, jpeg.id], formats: .both).assetIDs.count, 2)
  }
  func testCompletionRejectsChangedGroupAndQualityEvidence() throws {
    let (session, assets) = try batch(count: 1)
    var preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    try store.createGroup(ids: [assets[0].id], name: "Interval", kind: "延时")
    XCTAssertThrowsError(try store.commitCompletion(preview))
    preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    try store.saveQualityEvidence(TriageQualityEvidence(assetID: assets[0].id, contentHash: assets[0].contentHash, fileSize: assets[0].fileSize, source: "embeddedRAWPreview", methodVersion: "test", status: .unknown))
    XCTAssertThrowsError(try store.commitCompletion(preview))
  }
  func testNewTriageBatchDoesNotReuseLegacySourceSession() async throws {
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source.appendingPathComponent("a.ARW"))
    let importer = ImportService(store: store)
    let old = try await importer.importDirectory(source: source, destination: nil, projectName: "Old", mode: .reference, progress: { _ in })
    let fresh = try await importer.importDirectory(source: source, destination: nil, projectName: "Old", mode: .reference, projectID: old.projectID, initialScreening: true, progress: { _ in })
    XCTAssertNotEqual(old.id, fresh.id)
    XCTAssertEqual(try store.loadAdmissions().count, 1)
    XCTAssertEqual(try store.loadAssets().count, 2)
    XCTAssertEqual(try store.loadWorkflows().first { $0.id == fresh.id }?.phase, .screening)
  }
  func testLegacyGroupCommandHistoryStillRestoresAfterWorkflowMigration() throws {
    let (_, assets) = try batch(count: 2)
    try store.createGroup(ids: assets.map(\.id), name: "Before", kind: "连拍")
    let group = try XCTUnwrap(store.loadGroups().first)
    let rename = try store.commitGroupCommand(store.previewGroupCommand(.rename(groupID: group.id, name: "After")))
    try removeEditingSchemaForLegacyFixture(store)
    for table in ["asset_color_labels", "review_records", "project_review_states", "tag_commands", "tag_domains", "session_workflows", "project_admissions", "triage_records", "capture_pairs", "pair_dismissals", "triage_commands", "quality_evidence", "asset_tags", "workflow_completions"] { try store.exec("DROP TABLE \(table)") }
    try store.exec("PRAGMA user_version=3")
    store = nil; store = try LibraryStore(databaseURL: database)
    _ = try store.undoGroupCommand(id: rename.id)
    XCTAssertEqual(try store.loadGroups().first?.name, "Before")
    XCTAssertEqual(try store.loadGroups().first?.projectID, assets[0].projectID)
    XCTAssertEqual(try store.loadGroups().first?.assetIDs, assets.map(\.id))
  }

  func testTriageLIFOUndoAcrossRestartKeepsRevisionMonotonicAndRejectsABA() throws {
    let (_, assets) = try batch(count: 1)
    let a = try store.updateTriage(ids: [assets[0].id], disposition: .excluded)
    let b = try store.updateTriage(ids: [assets[0].id], disposition: .passed)
    try store.undoTriage(commandID: b.id)
    XCTAssertEqual(try store.loadTriageRecords()[0].revision, 3)
    store = nil; store = try LibraryStore(databaseURL: database)
    try store.undoTriage(commandID: a.id)
    XCTAssertEqual(try store.loadTriageRecords()[0].disposition, .pending)
    XCTAssertEqual(try store.loadTriageRecords()[0].revision, 4)
    let c = try store.updateTriage(ids: [assets[0].id], disposition: .excluded)
    _ = try store.updateTriage(ids: [assets[0].id], disposition: .passed)
    _ = try store.updateTriage(ids: [assets[0].id], disposition: .excluded)
    XCTAssertThrowsError(try store.undoTriage(commandID: c.id))
    XCTAssertEqual(try store.loadTriageRecords()[0].revision, 7)
  }
  func testClosedProjectPairMaintenanceCannotIncludeArchivedFile() throws {
    let (session, assets) = try batch(count: 1)
    var jpeg = assets[0]; jpeg.id = UUID().uuidString; jpeg.filename = "0.JPG"; jpeg.relativePath = "0.JPG"; jpeg.sourcePath = root.appendingPathComponent("0.JPG").path; jpeg.currentPath = jpeg.sourcePath
    try Data("asset-0".utf8).write(to: jpeg.url)
    _ = try store.register(jpeg)
    _ = try store.updateTriage(ids: [jpeg.id], disposition: .excluded)
    _ = try store.commitCompletion(store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true))
    XCTAssertTrue(try store.scanCapturePairs(sessionID: session.id).isEmpty)
    XCTAssertThrowsError(try store.confirmCapturePair(rawAssetID: assets[0].id, jpegAssetID: jpeg.id))
    _ = try store.restoreArchivedAssets(sessionID: session.id, assetIDs: [jpeg.id])
    let pair = try XCTUnwrap(store.scanCapturePairs(sessionID: session.id).first)
    try store.unlinkCapturePair(id: pair.id)
    XCTAssertTrue(try store.scanCapturePairs(sessionID: session.id).isEmpty)
    _ = try store.confirmCapturePair(rawAssetID: assets[0].id, jpegAssetID: jpeg.id)
    XCTAssertEqual(try store.loadWorkflows().first?.phase, .closed)
  }

  func testFormatMissingRequestIsPersistedToJSONAndCSV() async throws {
    let (session, assets) = try batch(count: 1)
    _ = try store.commitCompletion(store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true))
    let report = try await ExportService(store: store).exportAssets(ids: [assets[0].id], destination: root.appendingPathComponent("out"), formats: .jpegOnly, progress: { _ in })
    XCTAssertEqual(report.copied, 0)
    XCTAssertEqual(report.failed, 1)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: URL(fileURLWithPath: report.manifestPath)))
    XCTAssertEqual(manifest.formats, .jpegOnly)
    XCTAssertEqual(manifest.requestedAssetIDs, [assets[0].id])
    XCTAssertEqual(manifest.missingFormats?.count, 1)
    let csv = try String(contentsOfFile: String(report.manifestPath.dropLast(5)) + ".csv", encoding: .utf8)
    XCTAssertTrue(csv.contains("missingFormatsJSON"))
    XCTAssertTrue(csv.contains("没有已纳入的JPEG文件"))
  }
  final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var fired = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
  }
  func testConcurrentServiceResumeAndCompletionAreExcludedAcrossConnections() async throws {
    let (session, _) = try batch(count: 3)
    let otherStore = try LibraryStore(databaseURL: database)
    let first = ImportService(store: store), second = ImportService(store: otherStore)
    let entered = expectation(description: "First service owns file lock")
    let release = DispatchSemaphore(value: 0), once = Once()
    let task = Task {
      try await first.resume(sessionID: session.id, progress: { value in
        if value.isRunning && once.claim() { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
      })
    }
    await fulfillment(of: [entered], timeout: 5)
    do { _ = try await second.resume(sessionID: session.id, progress: { _ in }); XCTFail("Concurrent resume must fail") } catch LibraryError.busy { } catch { XCTFail("Unexpected error: \(error)") }
    let preview = try otherStore.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertThrowsError(try otherStore.commitCompletion(preview))
    release.signal()
    _ = try await task.value
    let finished = try otherStore.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
    XCTAssertTrue(finished.canCommit)
    _ = try otherStore.commitCompletion(finished)
  }

  func testAutomaticPairingFinishesBeforeIngestLeaseAndActiveMarkerAreReleased() async throws {
    let (session, assets) = try batch(count: 1)
    var jpeg = assets[0]; jpeg.id = UUID().uuidString; jpeg.filename = "0.JPG"; jpeg.relativePath = "0.JPG"; jpeg.sourcePath = root.appendingPathComponent("0.JPG").path; jpeg.currentPath = jpeg.sourcePath
    try Data("asset-0".utf8).write(to: jpeg.url)
    _ = try store.register(jpeg)
    let observer = try LibraryStore(databaseURL: database)
    let observedTail = expectation(description: "Pairing completed while ingest still owns lease")
    _ = try await ImportService(store: store).resume(sessionID: session.id, progress: { value in
      guard !value.isRunning && value.message == "completed" else { return }
      do {
        XCTAssertEqual(try observer.loadCapturePairs(sessionID: session.id).count, 1)
        XCTAssertEqual(try observer.loadWorkflows().first { $0.id == session.id }?.importActive, true)
        XCTAssertThrowsError(try observer.acquireImportLease(session.id))
        let preview = try observer.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
        XCTAssertThrowsError(try observer.commitCompletion(preview))
        observedTail.fulfill()
      } catch { XCTFail("Unexpected tail observation error: \(error)") }
    })
    await fulfillment(of: [observedTail], timeout: 1)
    XCTAssertEqual(try observer.loadWorkflows().first { $0.id == session.id }?.importActive, false)
    let lease = try observer.acquireImportLease(session.id); lease.release()
    XCTAssertTrue(try observer.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true).canCommit)
  }

  func testNeverVerifiedArchivedFailureRequiresNewIngestWithoutChangingHistory() throws {
    let (session, assets) = try batch(count: 1)
    var failed = assets[0]; failed.importState = .failed; failed.contentHash = nil; failed.error = "Not yet verified"
    try store.saveImportAsset(failed)
    _ = try store.updateTriage(ids: [failed.id], disposition: .excluded)
    _ = try store.commitCompletion(store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true, confirmedFailures: true))
    let before = try store.stableJSON(store.loadAssets())
    let workflowBefore = try store.stableJSON(store.loadWorkflows())
    let triageBefore = try store.stableJSON(store.loadTriageRecords())
    XCTAssertThrowsError(try store.restoreArchivedAssets(sessionID: session.id, assetIDs: [failed.id])) { error in
      XCTAssertTrue(error.localizedDescription.contains("请新建导入会话重新接入"))
      XCTAssertTrue(error.localizedDescription.contains("旧历史记录保留"))
    }
    XCTAssertEqual(try store.stableJSON(store.loadAssets()), before)
    XCTAssertEqual(try store.stableJSON(store.loadWorkflows()), workflowBefore)
    XCTAssertEqual(try store.stableJSON(store.loadTriageRecords()), triageBefore)
    XCTAssertTrue(try store.loadAdmissions().isEmpty)
    XCTAssertTrue(try store.publishedProjects().isEmpty)
  }

}
