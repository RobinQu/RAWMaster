import CSQLite
import Foundation
import XCTest
@testable import RAWMasterCore

final class EditingTests: XCTestCase {
  var root: URL!, database: URL!, sourceURL: URL!, store: LibraryStore!, asset: AssetRecord!, source: EditingSourceSnapshot!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("Editing-" + UUID().uuidString)
    database = root.appendingPathComponent("library.sqlite")
    sourceURL = root.appendingPathComponent("originals/photo.RAW")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("camera original bytes".utf8).write(to: sourceURL)
    store = try LibraryStore(databaseURL: database)
    let project = ProjectRecord(name: "Editing")
    try store.saveProject(project)
    let session = ImportSession(projectID: project.id, projectName: project.name,
      sourcePath: sourceURL.deletingLastPathComponent().path, mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
    try store.saveSession(session)
    asset = try store.register(.init(sessionID: session.id, projectID: project.id, sourcePath: sourceURL.path,
      fileSize: try FileSafety.stat(sourceURL).size, contentHash: try FileSafety.hash(sourceURL), importState: .ready))
    try store.completedDirectImport(session)
    source = try store.editingSourceSnapshot(assetID: asset.id, verifiedSHA256: FileSafety.hash(sourceURL), verifiedByteCount: FileSafety.stat(sourceURL).size)
  }
  override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }
  func work() throws -> PhotoWork { try store.createPhotoWork(source: source) }
  func version(_ work: PhotoWork, artifact: RenderArtifact? = nil, kind: EditingVersionKind = .development) -> EditingVersion {
    .init(workID: work.id, parentVersionID: work.originalVersionID, kind: kind, source: work.source, recipe: .init(exposureEV: kind == .ai ? 0 : 0.5), artifact: artifact)
  }
  func renderedFile() throws -> (URL, RenderArtifact) {
    let url = root.appendingPathComponent(UUID().uuidString + ".png")
    try Data("verified rendered pixels fixture".utf8).write(to: url)
    return (url, RenderArtifact(sha256: try FileSafety.hash(url), byteCount: try FileSafety.stat(url).size,
      pixelWidth: 40, pixelHeight: 30, encoding: "png", bitDepth: 8, colorSpace: "sRGB"))
  }
  func request(_ work: PhotoWork, kind: ProviderKind = .localComfy) throws -> AIEditRequest {
    _ = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let (url, artifact) = try renderedFile()
    return .init(workID: work.id, inputVersionID: work.originalVersionID, source: work.source,
      inputFileURL: url, inputArtifact: artifact, recipe: .init(),
      profile: .init(kind: kind, displayName: "Test", model: "exact-model-v1", endpoint: URL(string: kind == .localComfy ? "http://127.0.0.1:8188" : "https://api.example.com/v1")!,
        capabilities: .init(capabilityID: "test-v1"), acceptedForUse: true), prompt: "Natural")
  }
  func advanceToRunning(_ job: ProcessingJob) throws -> ProcessingJob {
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .preparing)
    let submitting = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .submitting)
    XCTAssertNotNil(submitting.currentAttempt.submissionIntentAt)
    return try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .running, remoteID: "remote-1")
  }
  func testSourceSnapshotIgnoresRatingAndLocationButRejectsAdmissionABAAndContentChanges() throws {
    _ = try store.updateSelection(ids: [asset.id], decision: .keep, rating: 5)
    try store.validateEditingSource(source)
    var moved = source!; moved.sourceLocation = root.appendingPathComponent("relocated.RAW")
    XCTAssertTrue(source.hasSameIdentity(as: moved))
    let scope = try XCTUnwrap(store.rows("SELECT scope_id FROM lc_scopes WHERE asset_id=?", [asset.id]).first?.first)
    try store.statement("UPDATE lc_scope_times SET admitted_at=admitted_at+1 WHERE scope_id=?", [scope])
    XCTAssertThrowsError(try store.createPhotoWork(source: source)) { XCTAssertEqual($0 as? EditingError, .staleSource) }
    try store.statement("UPDATE lc_scope_times SET admitted_at=admitted_at-1 WHERE scope_id=?", [scope])
    try store.validateEditingSource(source)
    var changed = asset!; changed.contentHash = String(repeating: "b", count: 64)
    try store.statement("UPDATE assets SET data=? WHERE id=?", [try store.json(changed), asset.id])
    XCTAssertThrowsError(try store.validateEditingSource(source))
  }
  func testProvisionalLegacyAdmissionCannotOpenAPendingOrFinallyExcludedFile() async throws {
    let folder = root.appendingPathComponent("screening")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("pending original".utf8).write(to: folder.appendingPathComponent("screen.RAW"))
    let session = try await ImportService(store: store).importDirectory(
      source: folder, destination: nil, projectName: "Triage", mode: .reference, initialScreening: true, progress: { _ in })
    let pending = try XCTUnwrap(store.loadAssets(sessionID: session.id).first)
    try store.writeAdmission(ProjectAdmission(assetID: pending.id, projectID: pending.projectID))
    XCTAssertThrowsError(try store.captureEditingSourceSnapshot(assetID: pending.id)) { XCTAssertEqual($0 as? EditingError, .staleSource) }
    let preview = try store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true, dispositions: [pending.id:.excluded])
    _ = try store.commitCompletion(preview)
    XCTAssertEqual(try store.rows("SELECT disposition FROM lc_occurrences WHERE asset_id=?", [pending.id]), [["excluded"]])
    XCTAssertThrowsError(try store.captureEditingSourceSnapshot(assetID: pending.id)) { XCTAssertEqual($0 as? EditingError, .staleSource) }
  }
  func testMigratedV7AdmittedWorkKeepsItsOriginalEditingFingerprint() throws {
    let data = try XCTUnwrap(store.rows("SELECT data FROM project_admissions WHERE asset_id=?", [asset.id]).first?.first)
    var legacySource = source!
    legacySource.admissionFingerprint = try EditingFingerprint.of(store.decode(data, ProjectAdmission.self))
    var existing = try work()
    var original = try store.editingVersion(id: existing.originalVersionID)
    existing.source = legacySource
    original.source = legacySource
    try store.statement("UPDATE editing_works SET data=? WHERE id=?", [try store.json(existing),existing.id])
    try store.statement("UPDATE editing_versions SET data=? WHERE id=?", [try store.json(original),original.id])
    try removeCatalogSchemaForLegacyFixture(store)
    try store.exec("PRAGMA user_version=7; PRAGMA wal_checkpoint(TRUNCATE)")
    store = nil
    store = try LibraryStore(databaseURL: database)
    let recaptured = try store.captureEditingSourceSnapshot(assetID: asset.id)
    XCTAssertEqual(recaptured.admissionFingerprint, legacySource.admissionFingerprint)
    XCTAssertTrue(try store.photoWork(id: existing.id).source.hasSameIdentity(as: recaptured))
    try store.validateEditingSource(legacySource)
    _ = try store.appendEditingVersion(version(existing))
  }
  func testOriginalCandidateCASIdempotencyAndReviewSeparationSurviveRestart() throws {
    let before = try Data(contentsOf: sourceURL)
    let admission = try XCTUnwrap(store.loadAdmissions().first { $0.assetID == asset.id })
    XCTAssertEqual(try EditingFingerprint.of(admission), source.admissionFingerprint)
    let first = try store.createPhotoWork(source: source, commandID: "create-1")
    XCTAssertEqual(first, try store.createPhotoWork(source: source, commandID: "create-1"))
    XCTAssertEqual(first.adoptedVersionID, first.originalVersionID)
    let candidate = version(first)
    XCTAssertEqual(candidate, try store.appendEditingVersion(candidate, commandID: "save-1"))
    XCTAssertEqual(candidate, try store.appendEditingVersion(candidate, commandID: "save-1"))
    var conflicting = candidate; conflicting.recipe.exposureEV = 1
    XCTAssertThrowsError(try store.appendEditingVersion(conflicting, commandID: "save-1")) { XCTAssertEqual($0 as? EditingError, .commandConflict) }
    XCTAssertEqual(try store.photoWork(id: first.id).adoptedVersionID, first.originalVersionID)
    let adopted = try store.adoptEditingVersion(workID: first.id, versionID: candidate.id, expectedRevision: 0, commandID: "adopt-1")
    XCTAssertEqual(adopted.adoptionRevision, 1)
    XCTAssertEqual(adopted, try store.adoptEditingVersion(workID: first.id, versionID: candidate.id, expectedRevision: 0, commandID: "adopt-1"))
    XCTAssertThrowsError(try store.adoptEditingVersion(workID: first.id, versionID: first.originalVersionID, expectedRevision: 0)) { XCTAssertEqual($0 as? EditingError, .staleAdoption) }
    XCTAssertTrue(try store.loadReviewRecords().isEmpty)
    XCTAssertEqual(try store.loadAssets()[0].rating, 0)
    XCTAssertEqual(try store.loadAdmissions().count, 1)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.loadEditingVersions(workID: first.id).count, 2)
    XCTAssertEqual(try store.photoWork(id: first.id), adopted)
    XCTAssertEqual(try Data(contentsOf: sourceURL), before)
  }
  func testCrossWorkParentsAndMutationOfSavedArtifactAreRejected() throws {
    let one = try work(), two = try work()
    var invalid = version(one); invalid.parentVersionID = two.originalVersionID
    XCTAssertThrowsError(try store.appendEditingVersion(invalid))
    var cycle = version(one); cycle.parentVersionID = cycle.id
    XCTAssertThrowsError(try store.appendEditingVersion(cycle))
    let saved = try store.appendEditingVersion(version(one))
    var replaced = saved; replaced.artifact = try renderedFile().1
    XCTAssertThrowsError(try store.appendEditingVersion(replaced))
    XCTAssertNil(try store.editingVersion(id: saved.id).artifact)
    XCTAssertThrowsError(try store.setVersionDisposition(versionID: one.originalVersionID, disposition: .discarded))
    try store.setVersionDisposition(versionID: saved.id, disposition: .discarded)
    XCTAssertEqual(try store.versionDisposition(versionID: saved.id), .discarded)
  }
  func testPublicationBeforeDatabaseCrashRecoversWithoutRegenerationOrAdoption() throws {
    let work = try work(), (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Production Archive"))
    let receipt = try archive.publish(fileURL: file, version: version(work, artifact: metadata))
    let originalHash = try FileSafety.hash(sourceURL)
    let unknown = archive.root.appendingPathComponent("unrecognized.keep")
    try Data("user bytes".utf8).write(to: unknown)
    XCTAssertEqual(try store.loadEditingVersions(workID: work.id).count, 1)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.recoverEditingArchive(), [receipt])
    XCTAssertEqual(try store.recoverEditingArchive(), [receipt])
    XCTAssertEqual(try store.loadEditingVersions(workID: work.id).count, 2)
    XCTAssertEqual(try store.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
    XCTAssertEqual(try FileSafety.hash(sourceURL), originalHash)
    XCTAssertEqual(try Data(contentsOf: unknown), Data("user bytes".utf8))
  }
  func testReceiptBeforeFinalLinkCrashRecoversAndCorruptionDoesNotRegenerate() throws {
    let work = try work(), (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let receipt = try archive.publish(fileURL: file, version: version(work, artifact: metadata))
    let final = try archive.artifactURL(receipt.version.artifact!)
    try FileManager.default.removeItem(at: final)
    XCTAssertEqual(try store.recoverEditingArchive(), [receipt])
    XCTAssertEqual(try FileSafety.hash(final), metadata.sha256)
    // Final and recognized staging are hard-linked. A corrupt archive is reported and never silently regenerated.
    try Data("corrupt".utf8).write(to: final)
    XCTAssertThrowsError(try store.recoverEditingArchive())
    XCTAssertEqual(try store.editingVersion(id: receipt.version.id).artifact?.sha256, metadata.sha256)
  }
  func testArchiveRefusesOriginalRootsSymlinkEscapeAndWrongByteMetadata() throws {
    XCTAssertThrowsError(try store.configureEditingArchive(root: sourceURL.deletingLastPathComponent().appendingPathComponent("Archive")))
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let work = try work(), (file, metadata) = try renderedFile()
    let link = archive.root.appendingPathComponent("artifacts/\(work.id)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceURL.deletingLastPathComponent())
    XCTAssertThrowsError(try archive.publish(fileURL: file, version: version(work, artifact: metadata)))
    try FileManager.default.removeItem(at: link)
    var bad = metadata; bad.byteCount += 1
    XCTAssertThrowsError(try archive.publish(fileURL: file, version: version(work, artifact: bad)))
    XCTAssertEqual(try FileSafety.hash(sourceURL), source.contentSHA256)
  }
  func testJobsPersistIntentRejectStaleCallbacksAndRequireWorkerJoinForCancelRetry() throws {
    let work = try work(), request = try request(work)
    let initial = try store.enqueueProcessingJob(commandID: "generate-1", request: request)
    XCTAssertEqual(initial, try store.enqueueProcessingJob(commandID: "generate-1", request: request))
    var different = request; different.prompt = "Different"
    XCTAssertThrowsError(try store.enqueueProcessingJob(commandID: "generate-1", request: different))
    XCTAssertThrowsError(try store.transitionProcessingJob(id: initial.id, attemptID: initial.currentAttempt.id, runID: initial.currentAttempt.runID, to: .running))
    let job = try advanceToRunning(initial)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertNotNil(try store.processingJob(id: job.id).currentAttempt.submissionIntentAt)
    XCTAssertThrowsError(try store.transitionProcessingJob(id: job.id, attemptID: "old", runID: job.currentAttempt.runID, to: .archiving))
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .cancelRequested)
    XCTAssertThrowsError(try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .cancelled)) { XCTAssertEqual($0 as? EditingError, .workerNotJoined) }
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .cancelled, workerJoined: true)
    let retry = try store.retryProcessingJob(id: job.id)
    XCTAssertEqual(retry.currentAttempt.number, 2)
    XCTAssertNotEqual(retry.currentAttempt.runID, job.currentAttempt.runID)
    XCTAssertThrowsError(try store.transitionProcessingJob(id: retry.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .running))
  }
  func testUnknownPaidOutcomeNeedsExplicitRetryAndRemoteIDIsImmutable() throws {
    let work = try work(), job = try advanceToRunning(store.enqueueProcessingJob(commandID: "paid", request: request(work, kind: .openAI)))
    XCTAssertEqual(job.usageState, .unknown)
    XCTAssertThrowsError(try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .running, remoteID: "another-run"))
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .outcomeUnknown, workerJoined: true)
    XCTAssertThrowsError(try store.retryProcessingJob(id: job.id)) { XCTAssertEqual($0 as? EditingError, .outcomeUnknown) }
    XCTAssertEqual(try store.retryProcessingJob(id: job.id, allowUnknownOutcome: true).attempts.count, 2)
  }
  func testLateResultAfterCancellationAndSourceLossArchivesHistoryWithoutAutoAdopting() throws {
    let work = try work(), job = try advanceToRunning(store.enqueueProcessingJob(commandID: "late", request: request(work)))
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .cancelRequested)
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .cancelled, workerJoined: true)
    let (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let receipt = try archive.publish(fileURL: file, version: version(work, artifact: metadata, kind: .ai), jobID: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID)
    var missing = asset!; missing.availability = .missing
    try store.statement("UPDATE assets SET data=? WHERE id=?", [try store.json(missing), asset.id])
    _ = try store.commitArchivePublication(receipt)
    XCTAssertEqual(try store.processingJob(id: job.id).resultVersionID, receipt.version.id)
    XCTAssertEqual(try store.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
    // Existing pixels can still be explicitly adopted while the original is offline.
    XCTAssertEqual(try store.adoptEditingVersion(workID: work.id, versionID: receipt.version.id, expectedRevision: 0).adoptedVersionID, receipt.version.id)
    XCTAssertThrowsError(try store.appendEditingVersion(version(work)))
  }
  func testCompleteBackupRestoreAndMissingArchiveRejectBeforeFinalPublication() throws {
    let work = try work(), (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let receipt = try archive.publish(fileURL: file, version: version(work, artifact: metadata))
    _ = try store.commitArchivePublication(receipt)
    _ = try store.adoptEditingVersion(workID: work.id, versionID: receipt.version.id, expectedRevision: 0)
    let backup = root.appendingPathComponent("Backup")
    let manifest = try store.backupEditingLibrary(to: backup)
    XCTAssertEqual(manifest.files.count, 2)
    let restoredDB = root.appendingPathComponent("Restored/library.sqlite"), restoredArchive = root.appendingPathComponent("Restored/Archive")
    let restored = try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: restoredDB, archiveRoot: restoredArchive)
    XCTAssertEqual(try restored.photoWork(id: work.id).adoptedVersionID, receipt.version.id)
    XCTAssertEqual(try restored.editingArchive().root.path, restoredArchive.path)
    try restored.editingArchive().validate(receipt)
    let missing = backup.appendingPathComponent("archive").appendingPathComponent(receipt.version.artifact!.relativePath)
    try FileManager.default.removeItem(at: missing)
    let invalidDB = root.appendingPathComponent("Broken/library.sqlite"), invalidArchive = root.appendingPathComponent("Broken/Archive")
    XCTAssertThrowsError(try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: invalidDB, archiveRoot: invalidArchive))
    XCTAssertFalse(FileManager.default.fileExists(atPath: invalidDB.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: invalidArchive.path))
    XCTAssertEqual(try FileSafety.hash(sourceURL), source.contentSHA256)
  }
  func testOldAttemptPublicationAfterExplicitUnknownRetryRemainsHistorical() throws {
    let work = try work(), job = try advanceToRunning(store.enqueueProcessingJob(commandID: "retry-history", request: request(work)))
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .outcomeUnknown, workerJoined: true)
    let retry = try store.retryProcessingJob(id: job.id, allowUnknownOutcome: true)
    let (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let publication = try archive.publish(fileURL: file, version: version(work, artifact: metadata, kind: .ai),
      jobID: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID)
    _ = try store.commitArchivePublication(publication)
    let current = try store.processingJob(id: job.id)
    XCTAssertEqual(current.currentAttempt.id, retry.currentAttempt.id)
    XCTAssertEqual(current.state, .queued)
    XCTAssertNil(current.resultVersionID)
    XCTAssertEqual(current.attempts[0].resultVersionID, publication.version.id)
    XCTAssertEqual(try store.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
    XCTAssertEqual(try store.recoverEditingArchive(), [publication])
  }
  func testBackupIncludesPublicationAwaitingDatabaseAppend() throws {
    let work = try work(), (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let publication = try archive.publish(fileURL: file, version: version(work, artifact: metadata))
    XCTAssertEqual(try store.loadEditingVersions(workID: work.id).count, 1)
    let backup = root.appendingPathComponent("Backup")
    _ = try store.backupEditingLibrary(to: backup)
    let restored = try LibraryStore.restoreEditingLibrary(from: backup,
      databaseURL: root.appendingPathComponent("Restored/library.sqlite"), archiveRoot: root.appendingPathComponent("Restored/Archive"))
    XCTAssertEqual(try restored.editingVersion(id: publication.version.id), publication.version)
    XCTAssertEqual(try restored.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
  }
  func testRestoreRejectsCatalogueArtifactMismatchBeforePublishingDestinations() throws {
    let work = try work(), (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let publication = try archive.publish(fileURL: file, version: version(work, artifact: metadata))
    _ = try store.commitArchivePublication(publication)
    let backup = root.appendingPathComponent("Backup")
    var manifest = try store.backupEditingLibrary(to: backup)
    let backupDB = backup.appendingPathComponent("library.sqlite")
    do {
      let tampered = try LibraryStore(databaseURL: backupDB)
      var altered = publication.version; altered.artifact!.colorSpace = "incorrect metadata"
      try tampered.statement("UPDATE editing_versions SET data=? WHERE id=?", [try tampered.json(altered), altered.id])
      try tampered.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
    }
    manifest.databaseSHA256 = try FileSafety.hash(backupDB)
    try JSONEncoder().encode(manifest).write(to: backup.appendingPathComponent("manifest.json"))
    let destinationDB = root.appendingPathComponent("Restored/library.sqlite"), destinationArchive = root.appendingPathComponent("Restored/Archive")
    XCTAssertThrowsError(try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: destinationDB, archiveRoot: destinationArchive))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destinationDB.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destinationArchive.path))
  }
  func testTerminalFailureCanAcknowledgeJoinedWorkerWithoutRewritingState() throws {
    let work = try work(), job = try store.enqueueProcessingJob(commandID: "joined-failure", request: request(work))
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .preparing)
    _ = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .failed)
    XCTAssertThrowsError(try store.retryProcessingJob(id: job.id)) { XCTAssertEqual($0 as? EditingError, .workerNotJoined) }
    XCTAssertThrowsError(try store.transitionProcessingJob(id: job.id, attemptID: "wrong", runID: job.currentAttempt.runID, to: .failed, workerJoined: true))
    let joined = try store.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: .failed, workerJoined: true)
    XCTAssertEqual(joined.state, .failed)
    XCTAssertTrue(joined.currentAttempt.workerJoined)
    XCTAssertEqual(try store.retryProcessingJob(id: job.id).currentAttempt.number, 2)
  }
  func testCaptureHelperUsesActualBytesAndSupportsCancellation() throws {
    let captured = try store.captureEditingSourceSnapshot(assetID: asset.id)
    XCTAssertTrue(captured.hasSameIdentity(as: source))
    XCTAssertThrowsError(try store.captureEditingSourceSnapshot(assetID: asset.id, cancel: { throw LibraryError.cancelled }))
    try Data("changed source contents".utf8).write(to: sourceURL)
    XCTAssertThrowsError(try store.captureEditingSourceSnapshot(assetID: asset.id))
  }
  func testHistoricalSourceManagedAndRelocationRootsStayProtectedThroughRestore() throws {
    var session = try store.loadSessions()[0]
    let movedRoot = root.appendingPathComponent("moved-source")
    session.effectiveSourceRoot = movedRoot.path
    session.destinationPath = root.appendingPathComponent("old-managed").path
    session.effectiveManagedRoot = root.appendingPathComponent("new-managed").path
    try store.statement("UPDATE sessions SET data=? WHERE id=?", [try store.json(session), session.id])
    let historicalRoot = root.appendingPathComponent("historical-managed")
    let item = RelocationItem(assetID: asset.id, filename: asset.filename, status: .committed,
      assetFingerprint: "historical", oldPath: historicalRoot.appendingPathComponent("photo.RAW").path, oldPathWasAvailable: false)
    let relocation = RelocationSession(importSessionID: session.id, rootPath: historicalRoot.path, role: .managed, items: [item])
    try store.statement("INSERT INTO relocation_sessions VALUES(?,?)", [relocation.id, try store.json(relocation)])
    for protected in [sourceURL.deletingLastPathComponent(), URL(fileURLWithPath: session.destinationPath!), historicalRoot] {
      XCTAssertThrowsError(try store.configureEditingArchive(root: protected.appendingPathComponent("Archive")))
    }
    _ = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    XCTAssertThrowsError(try store.backupEditingLibrary(to: sourceURL.deletingLastPathComponent().appendingPathComponent("Backup")))
    let backup = root.appendingPathComponent("Backup")
    _ = try store.backupEditingLibrary(to: backup)
    let before = try Data(contentsOf: sourceURL)
    XCTAssertThrowsError(try LibraryStore.restoreEditingLibrary(from: backup,
      databaseURL: root.appendingPathComponent("Restored/library.sqlite"), archiveRoot: sourceURL.deletingLastPathComponent().appendingPathComponent("RestoredArchive")))
    XCTAssertEqual(try Data(contentsOf: sourceURL), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.deletingLastPathComponent().appendingPathComponent("RestoredArchive").path))
  }
  func testInvalidPendingPublicationIsRejectedBeforeFinalRestorePathsExist() throws {
    let work = try work(), (file, metadata) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let backup = root.appendingPathComponent("Backup")
    var manifest = try store.backupEditingLibrary(to: backup)
    var invalid = version(work, artifact: metadata); invalid.parentVersionID = "missing-parent"
    let receipt = try archive.publish(fileURL: file, version: invalid)
    XCTAssertThrowsError(try store.backupEditingLibrary(to: root.appendingPathComponent("InvalidBackup")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("InvalidBackup/manifest.json").path))
    for relative in [receipt.version.artifact!.relativePath, "receipts/" + receipt.id + ".json"] {
      let original = archive.root.appendingPathComponent(relative)
      let target = backup.appendingPathComponent("archive").appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: original, to: target)
      manifest.files[relative] = try FileSafety.hash(target)
    }
    try JSONEncoder().encode(manifest).write(to: backup.appendingPathComponent("manifest.json"))
    let db = root.appendingPathComponent("Restored/library.sqlite"), archived = root.appendingPathComponent("Restored/Archive")
    XCTAssertThrowsError(try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: db, archiveRoot: archived))
    XCTAssertFalse(FileManager.default.fileExists(atPath: db.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: archived.path))
    XCTAssertEqual(try store.loadEditingVersions(workID: work.id).count, 1)
  }
  func testReturnedOutputSurvivesRestartBackupAndArchiveFailureWithoutPaidResubmit() throws {
    let work = try work(), job = try advanceToRunning(store.enqueueProcessingJob(commandID: "received", request: request(work, kind: .openAI)))
    XCTAssertTrue(job.request.inputArtifact.relativePath.hasPrefix(".inputs/"))
    let (file, metadata) = try renderedFile()
    let owned = try store.recordProcessingOutput(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID,
      output: AIEditOutput(fileURL: file, artifact: metadata, configuration: ["decoder": "frozen-v1"]))
    XCTAssertNotEqual(owned.fileURL.path, file.path)
    XCTAssertTrue(owned.artifact.relativePath.hasPrefix(".received/"))
    try FileManager.default.removeItem(at: file)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.processingJob(id: job.id).state, .archiving)
    XCTAssertThrowsError(try store.retryProcessingJob(id: job.id, allowUnknownOutcome: true)) { XCTAssertEqual($0 as? EditingError, .outputAlreadyReceived) }
    let backup = root.appendingPathComponent("Backup")
    _ = try store.backupEditingLibrary(to: backup)
    let restored = try LibraryStore.restoreEditingLibrary(from: backup,
      databaseURL: root.appendingPathComponent("Restored/library.sqlite"), archiveRoot: root.appendingPathComponent("Restored/Archive"))
    let received = try XCTUnwrap(restored.receivedProcessingOutput(id: job.id))
    XCTAssertTrue(received.fileURL.path.hasPrefix(root.appendingPathComponent("Restored/Archive").path))
    XCTAssertEqual(try FileSafety.hash(received.fileURL), metadata.sha256)
    let restoredJob = try restored.processingJob(id: job.id)
    XCTAssertTrue(restoredJob.request.inputFileURL.path.hasPrefix(root.appendingPathComponent("Restored/Archive/.inputs").path))
    XCTAssertEqual(try FileSafety.hash(restoredJob.request.inputFileURL), restoredJob.request.inputArtifact.sha256)
    let publication = try restored.editingArchive().publish(fileURL: received.fileURL,
      version: version(work, artifact: received.artifact, kind: .ai), jobID: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID)
    _ = try restored.commitArchivePublication(publication)
    XCTAssertEqual(try restored.processingJob(id: job.id).state, .succeeded)
    XCTAssertEqual(try restored.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
  }
  func testReceivedReceiptBeforeDatabaseCallbackRecoversExactlyOnce() throws {
    let work = try work(), job = try advanceToRunning(store.enqueueProcessingJob(commandID: "received-crash", request: request(work)))
    let (file, artifact) = try renderedFile()
    let archive = try store.editingArchive()
    _ = try archive.receive(output: AIEditOutput(fileURL: file, artifact: artifact), jobID: job.id,
      attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID)
    XCTAssertNil(try store.processingJob(id: job.id).currentAttempt.receivedOutput)
    // Retry itself must recover a receipt even if a caller forgot startup reconciliation.
    XCTAssertThrowsError(try store.retryProcessingJob(id: job.id, allowUnknownOutcome: true)) { XCTAssertEqual($0 as? EditingError, .outputAlreadyReceived) }
    try FileManager.default.removeItem(at: file)
    store = nil; store = try LibraryStore(databaseURL: database)
    _ = try store.recoverEditingArchive()
    _ = try store.recoverEditingArchive()
    XCTAssertEqual(try store.processingJob(id: job.id).state, .archiving)
    XCTAssertEqual(try store.receivedProcessingOutput(id: job.id)?.artifact.sha256, artifact.sha256)
    XCTAssertThrowsError(try store.retryProcessingJob(id: job.id, allowUnknownOutcome: true))
  }
  func testInitialCaptureFailurePersistsReturnedIntentAndNeverPermitsNetworkRetry() throws {
    let work = try work(), job = try advanceToRunning(store.enqueueProcessingJob(commandID: "capture-failure", request: request(work, kind: .openAI)))
    let (file, artifact) = try renderedFile()
    var invalid = artifact; invalid.sha256 = String(repeating: "a", count: 64)
    XCTAssertThrowsError(try store.recordProcessingOutput(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID,
      output: AIEditOutput(fileURL: file, artifact: invalid)))
    let persisted = try store.processingJob(id: job.id)
    XCTAssertEqual(persisted.state, .archiving)
    XCTAssertNotNil(persisted.currentAttempt.pendingReceivedOutput)
    XCTAssertThrowsError(try store.retryProcessingJob(id: job.id, allowUnknownOutcome: true)) { XCTAssertEqual($0 as? EditingError, .outputAlreadyReceived) }
  }
  func testProviderProfilesAndActualArtifactPrecisionAreExplicit() throws {
    let work = try work(); var profile = try request(work).profile
    try store.saveProviderProfile(profile)
    XCTAssertEqual(try store.loadProviderProfiles(), [profile])
    profile.endpoint = URL(string: "http://remote.example.com")!
    XCTAssertThrowsError(try store.saveProviderProfile(profile))
    profile.endpoint = URL(string: "https://remote.example.com")!
    XCTAssertThrowsError(try store.saveProviderProfile(profile))
    profile.endpoint = URL(string: "http://127.0.0.1:8188")!
    profile.configuration["api_key"] = "never-persist-this"
    XCTAssertThrowsError(try store.saveProviderProfile(profile))
    var artifact = try renderedFile().1
    artifact.bitDepth = 16; artifact.sourceEffectiveBitDepth = nil
    try artifact.validate()
    XCTAssertNil(artifact.sourceEffectiveBitDepth)
    artifact.pixelWidth *= 2
    XCTAssertThrowsError(try artifact.validate())
    artifact.resamplingChain = ["explicit bicubic 2x"]
    try artifact.validate()
    var recipe = DevelopmentRecipe(); recipe.crop.x = .nan
    XCTAssertThrowsError(try recipe.validate())
  }
}
