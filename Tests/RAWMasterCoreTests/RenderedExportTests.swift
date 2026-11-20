import Foundation
import XCTest
@testable import RAWMasterCore

final class RenderedExportTests: XCTestCase {
  var root: URL!, db: URL!, store: LibraryStore!, work: PhotoWork!, source: URL!, target: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("RenderedExports-" + UUID().uuidString)
    db = root.appendingPathComponent("library.sqlite")
    source = root.appendingPathComponent("Originals/source.RAW")
    target = root.appendingPathComponent("Exports/finished.jpg")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("protected original".utf8).write(to: source)
    store = try LibraryStore(databaseURL: db)
    let project = ProjectRecord(name: "Exports"); try store.saveProject(project)
    let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: source.deletingLastPathComponent().path, mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
    try store.saveSession(session)
    let asset = try store.register(.init(sessionID: session.id, projectID: project.id, sourcePath: source.path,
      fileSize: FileSafety.stat(source).size, contentHash: FileSafety.hash(source), importState: .ready))
    work = try store.createPhotoWork(source: store.captureEditingSourceSnapshot(assetID: asset.id))
    _ = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
  }
  override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }
  func plan(command: String = UUID().uuidString) throws -> RenderedExportRecord {
    try store.enqueueRenderedExport(commandID: command, workID: work.id, versionID: work.originalVersionID, format: .jpeg8, targetURL: target)
  }
  func stage() throws -> (URL, RenderArtifact) {
    let url = target.deletingLastPathComponent().appendingPathComponent(".rawmaster-render-\(UUID().uuidString).jpg")
    try Data("verified final JPEG fixture bytes".utf8).write(to: url)
    return (url, RenderArtifact(sha256: try FileSafety.hash(url), byteCount: try FileSafety.stat(url).size,
      pixelWidth: 40, pixelHeight: 30, encoding: "public.jpeg", bitDepth: 8, colorSpace: "sRGB IEC61966-2.1",
      iccProfileSHA256: String(repeating: "a", count: 64), alphaPolicy: .compositedWhite))
  }
  func testPublicationBeforeCompletionCrashReconcilesSameVersionAndNeverOverwrites() throws {
    let plan = try plan(command: "stable-export"), (stage, artifact) = try stage()
    _ = try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage)
    try FileManager.default.moveItem(at: stage, to: target)
    store = nil; store = try LibraryStore(databaseURL: db)
    let recovered = try store.reconcileRenderedExports(workID: work.id)
    XCTAssertEqual(recovered.count, 1)
    XCTAssertEqual(recovered[0].state, .succeeded)
    XCTAssertEqual(recovered[0].versionID, work.originalVersionID)
    XCTAssertEqual(recovered[0].preparedArtifact, artifact)
    XCTAssertEqual(try self.plan(command: "stable-export").id, plan.id)
    XCTAssertEqual(try FileSafety.hash(target), artifact.sha256)
    XCTAssertEqual(try store.loadRenderedExports(workID: work.id).count, 1)
    XCTAssertNotNil(recovered[0].completedAt)
  }
  func testPreparedStageOnlyRecoversWithoutRenderAndConflictingFinalStaysUntouched() throws {
    let plan = try plan(), (stage, artifact) = try stage()
    _ = try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage)
    store = nil; store = try LibraryStore(databaseURL: db)
    XCTAssertEqual(try store.reconcileRenderedExports()[0].state, .succeeded)
    XCTAssertEqual(try FileSafety.hash(target), artifact.sha256)
    try Data("different user's export".utf8).write(to: target)
    let before = try Data(contentsOf: target)
    XCTAssertEqual(try store.reconcileRenderedExports()[0].state, .needsAttention)
    XCTAssertEqual(try Data(contentsOf: target), before)
  }
  func testCompletedExternallyDeletedTargetRequiresAttentionRatherThanRecreation() throws {
    let plan = try plan(), (stage, artifact) = try stage()
    _ = try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage)
    XCTAssertEqual(try store.completeRenderedExport(id: plan.id).state, .succeeded)
    try FileManager.default.removeItem(at: target)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
    XCTAssertEqual(try store.reconcileRenderedExports()[0].state, .needsAttention)
    XCTAssertEqual(try store.reconcileRenderedExports()[0].state, .needsAttention)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }
  func testPlanAndPreparationAreIdempotentAndConflictingCommandsReject() throws {
    let plan = try plan(command: "command"), (stage, artifact) = try stage()
    XCTAssertEqual(try self.plan(command: "command"), plan)
    XCTAssertThrowsError(try store.enqueueRenderedExport(commandID: "command", workID: work.id, versionID: work.originalVersionID, format: .tiff16, targetURL: target)) { XCTAssertEqual($0 as? EditingError, .commandConflict) }
    let prepared = try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage)
    XCTAssertEqual(try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage), prepared)
    var other = artifact; other.pixelWidth += 1
    XCTAssertThrowsError(try store.prepareRenderedExport(id: plan.id, artifact: other, stagingURL: stage)) { XCTAssertEqual($0 as? EditingError, .commandConflict) }
  }
  func testExistingDifferentFileHasNoReceiptAndIsNeverClaimedOrReplaced() throws {
    try Data("existing file".utf8).write(to: target)
    let plan = try plan(), (stage, artifact) = try stage()
    XCTAssertEqual(plan.state, .needsAttention)
    XCTAssertNil(plan.preparedArtifact)
    XCTAssertThrowsError(try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage))
    XCTAssertEqual(try store.reconcileRenderedExports()[0].state, .needsAttention)
    XCTAssertEqual(try Data(contentsOf: target), Data("existing file".utf8))
  }
  func testOriginalArchiveAndUnrecognizedStagesAreProtected() throws {
    let before = try Data(contentsOf: source)
    for url in [source!, source.deletingLastPathComponent().appendingPathComponent("result.jpg"), root.appendingPathComponent("Archive/result.jpg")] {
      XCTAssertThrowsError(try store.enqueueRenderedExport(commandID: UUID().uuidString, workID: work.id, versionID: work.originalVersionID, format: .jpeg8, targetURL: url))
    }
    let plan = try plan(), (stage, artifact) = try stage()
    let unknown = stage.deletingLastPathComponent().appendingPathComponent("user-image.jpg")
    try FileManager.default.moveItem(at: stage, to: unknown)
    XCTAssertThrowsError(try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: unknown))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    XCTAssertEqual(try Data(contentsOf: source), before)
  }
  func testLateCancelAfterPublicationPreservesSuccessAndEarlierCancelDoesNotPublishStage() throws {
    let plan = try plan(), (stage, artifact) = try stage()
    _ = try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage)
    try FileManager.default.moveItem(at: stage, to: target)
    XCTAssertEqual(try store.cancelRenderedExport(id: plan.id).state, .succeeded)
    XCTAssertEqual(try FileSafety.hash(target), artifact.sha256)
    target = root.appendingPathComponent("Exports/cancelled.jpg")
    let earlier = try self.plan(), (earlyStage, earlyArtifact) = try self.stage()
    _ = try store.prepareRenderedExport(id: earlier.id, artifact: earlyArtifact, stagingURL: earlyStage)
    XCTAssertEqual(try store.cancelRenderedExport(id: earlier.id).state, .cancelled)
    XCTAssertEqual(try store.reconcileRenderedExports(workID: work.id).last?.state, .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }
  func testCancelledExportKeepsCancellationAcrossConflictAndLaterConflictRemoval() throws {
    let plan = try plan(), (stage, artifact) = try stage()
    _ = try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage)
    XCTAssertEqual(try store.cancelRenderedExport(id: plan.id).state, .cancelled)
    try Data("unrelated user export".utf8).write(to: target)
    let conflictingBytes = try Data(contentsOf: target)
    let conflict = try store.reconcileRenderedExports()[0]
    XCTAssertEqual(conflict.state, .cancelled)
    XCTAssertNotNil(conflict.error)
    XCTAssertEqual(try Data(contentsOf: target), conflictingBytes)
    try FileManager.default.removeItem(at: target)
    store = nil; store = try LibraryStore(databaseURL: db)
    XCTAssertEqual(try store.reconcileRenderedExports()[0].state, .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
  }
  func testBackupPreservesReceiptsAndRestoreMarksMissingExternalBytesForVerification() throws {
    let plan = try plan(), (stage, artifact) = try stage()
    _ = try store.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: stage)
    XCTAssertEqual(try store.completeRenderedExport(id: plan.id).state, .succeeded)
    let backup = root.appendingPathComponent("Backup")
    let manifest = try store.backupEditingLibrary(to: backup)
    XCTAssertTrue(manifest.files.isEmpty, "External exported files/stages are not duplicated into the production archive backup")
    try FileManager.default.removeItem(at: target)
    let restored = try LibraryStore.restoreEditingLibrary(from: backup,
      databaseURL: root.appendingPathComponent("Restored/library.sqlite"), archiveRoot: root.appendingPathComponent("Restored/Archive"))
    let receipt = try restored.renderedExport(id: plan.id)
    XCTAssertEqual(receipt.preparedArtifact, artifact)
    XCTAssertEqual(receipt.versionID, plan.versionID)
    XCTAssertEqual(receipt.state, .needsAttention)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "Restore only verifies external locations")
  }
}
