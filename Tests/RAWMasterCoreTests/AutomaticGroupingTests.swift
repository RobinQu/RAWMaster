import Foundation
import XCTest
@testable import RAWMasterCore

final class AutomaticGroupingTests: XCTestCase {
  var root: URL!
  var databaseURL: URL!
  var store: LibraryStore!
  let sessionID = "automatic-session"

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterAutomatic-" + UUID().uuidString)
    databaseURL = root.appendingPathComponent("library.sqlite")
    store = try LibraryStore(databaseURL: databaseURL)
    try store.saveProject(ProjectRecord(id: "project", name: "Automatic"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
    var session = ImportSession(id: sessionID, projectID: "project", projectName: "Automatic",
      sourcePath: root.appendingPathComponent("source").path, mode: .reference)
    session.status = "completed"; session.scanCompleted = true; session.discovered = 4; session.completed = 4
    try store.saveSession(session)
    for index in 0..<4 {
      let url = root.appendingPathComponent("source/DSC\(index).ARW")
      let bytes = Data("synthetic-file-\(index)".utf8)
      try bytes.write(to: url)
      _ = try store.register(AssetRecord(id: "asset-\(index)", sessionID: sessionID, projectID: "project",
        sourcePath: url.path, fileSize: Int64(bytes.count), contentHash: LocationIdentity.digest(bytes),
        decision: index == 0 ? .reject : .undecided, rating: index,
        importState: .ready))
    }
  }
  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: root)
  }
  func analysis(_ input: AutomaticGroupingInput, ranges: [ClosedRange<Int>] = [0...1, 2...3]) throws -> AutomaticGroupingAnalysis {
    let camera = SequenceCameraEvidence.verifiedDevice(opaqueID: "synthetic", source: "test", validationVersion: "v1")
    let manifest = try SequenceInputManifest(scopeID: "automatic-grouping/" + input.sessionID,
      sessionID: input.sessionID, orderVersion: SequenceBaseOrder.version,
      entries: input.assets.enumerated().map { index, asset in
        SequenceManifestEntry(assetID: asset.id, ordinal: index, contentHash: asset.contentHash,
          evidenceRevision: input.assetRevisions[index], camera: camera)
      })
    let versions = SequenceAnalysisVersions(extractor: "test", feature: "test", algorithm: "test",
      policy: "test", order: SequenceBaseOrder.version)
    let token = try SequenceAnalysisToken.make(manifest: manifest, versions: versions,
      policyFingerprint: SequenceFingerprint.digest(["test": 1]))
    let observations = manifest.entries.map { entry in
      SequenceAssetInput(entry: entry, evidence: SequenceCaptureEvidence(assetID: entry.assetID,
        contentHash: entry.contentHash!, extractorVersion: "test", evidenceRevision: entry.evidenceRevision,
        time: SequenceTimestampParser.parse(original: "2026:10:24 12:00:0\(entry.ordinal)", subseconds: "123", offset: nil)),
        clock: SequenceClockPartition(id: "clock", basis: .localCivil, derivationVersion: "test"))
    }
    let result = SequenceAnalysisResult(token: token, ranges: try ranges.map {
      SequenceDetectedRange(range: try SequenceOrdinalRange(first: $0.lowerBound, last: $0.upperBound), kind: .burst,
        cameraPartitionID: camera.partitionID(manifestFingerprint: manifest.contentFingerprint)!, clockPartitionID: "clock")
    }, coverage: [.init(range: try SequenceOrdinalRange(first: 0, last: input.assets.count - 1), state: .complete)])
    return AutomaticGroupingAnalysis(runID: input.runID, scopeFingerprint: input.scopeFingerprint,
      manifest: manifest, result: result, observations: observations, featuresAvailable: input.assets.map { _ in true },
      sourceProofs: try input.assets.map {
        AutomaticGroupingSourceProof(assetID: $0.id, verifiedSHA256: $0.contentHash,
          finalStamp: try AutomaticGroupingFileStamp.read(at: $0.resolvedURL), issue: nil)
      }, provenance: AutomaticGroupingProvenance(providerVersion: "synthetic-v1",
        analysisSHA256: try SequenceFingerprint.digest(result), associationHypothesisAssumed: false,
        reportPath: nil, warnings: []))
  }
  func run(_ analyzer: @escaping AutomaticGroupingAnalyzer) async {
    await AutomaticGroupingService(store: store, analyzer: analyzer).run(sessionID: sessionID,
      checkCancellation: {}, progress: { _ in })
  }
  func prepare(ranges: [ClosedRange<Int>] = [0...1, 2...3]) throws -> AutomaticGroupingBatch? {
    let input = try XCTUnwrap(store.claimAutomaticGrouping(sessionID: sessionID))
    return try store.prepareAutomaticGrouping(analysis(input, ranges: ranges), input: input, checkCancellation: {})
  }

  func testOneAtomicBatchRetainsAllPhotosDecisionsAndDurableUndoAcrossRestart() async throws {
    let before = try store.loadAssets(sessionID: sessionID)
    await run { input, _, _ in try self.analysis(input) }
    let run = try XCTUnwrap(store.automaticGroupingRun(sessionID: sessionID))
    XCTAssertEqual(run.state, .applied)
    XCTAssertEqual(run.groupIDs.count, 2)
    XCTAssertEqual(try store.loadGroupCommands().count, 1)
    for group in try store.loadGroups() {
      XCTAssertEqual(group.origin, .automaticPendingReview)
      XCTAssertFalse(group.locked)
      XCTAssertTrue(group.name.contains("待复核"))
      XCTAssertEqual(group.assetIDs, group.includedAssetIDs)
    }
    let after = try store.loadAssets(sessionID: sessionID)
    XCTAssertEqual(after.map(\.id), before.map(\.id))
    XCTAssertEqual(after.map(\.decision), before.map(\.decision))
    XCTAssertEqual(after.map(\.rating), before.map(\.rating))
    store = nil
    store = try LibraryStore(databaseURL: databaseURL)
    _ = try store.undoGroupCommand(id: XCTUnwrap(run.commandID))
    XCTAssertTrue(try store.loadGroups().isEmpty)
    await self.run { _, _, _ in XCTFail("A successful pass must never replay after undo"); throw LibraryError.invalid("unexpected") }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .applied)
    XCTAssertTrue(try store.loadGroups().isEmpty)
  }

  func testHistoricalRemovedAndUndoneMembersProtectWholeProposal() async throws {
    let created = try store.commitGroupCommand(store.previewGroupCommand(
      .create(assetIDs: ["asset-0"], name: "Manual", kind: "Manual")))
    _ = try store.undoGroupCommand(id: created.id)
    XCTAssertTrue(try store.loadGroups().isEmpty)
    await run { input, _, _ in
      XCTAssertTrue(input.protectedAssetIDs.contains("asset-0"))
      return try self.analysis(input)
    }
    let groups = try store.loadGroups()
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].assetIDs, ["asset-2", "asset-3"])
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.skippedProtectedRanges, 1)
  }

  func testCurrentUnlockedMembershipIsProtectedWithoutTrimming() async throws {
    let command = try store.commitGroupCommand(store.previewGroupCommand(
      .create(assetIDs: ["asset-1"], name: "Manual", kind: "Manual")))
    _ = try store.commitGroupCommand(store.previewGroupCommand(.setLocked(groupID: command.after[0].id, locked: false)))
    await run { input, _, _ in try self.analysis(input) }
    XCTAssertEqual(try store.loadGroups().count, 2)
    XCTAssertFalse(try store.loadGroups().contains { $0.assetIDs == ["asset-0"] })
    XCTAssertEqual(try store.loadGroups().first { $0.id == command.after[0].id }?.assetIDs, ["asset-1"])
  }

  func testGroupHistoryInsertFailureRollsBackGroupsDomainsAndSuccessLedger() async throws {
    let beforeDomains = try store.rows("SELECT * FROM group_domains ORDER BY group_id,domain")
    try store.exec("CREATE TEMP TRIGGER injected BEFORE INSERT ON group_commands BEGIN SELECT RAISE(ABORT,'injected'); END")
    await run { input, _, _ in try self.analysis(input) }
    XCTAssertTrue(try store.loadGroups().isEmpty)
    XCTAssertTrue(try store.loadGroupCommands().isEmpty)
    XCTAssertEqual(try store.rows("SELECT * FROM group_domains ORDER BY group_id,domain"), beforeDomains)
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .failed)
    XCTAssertEqual(try store.loadSessions()[0].status, "completed")
    try store.exec("DROP TRIGGER injected")
    await run { input, _, _ in try self.analysis(input) }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .applied)
  }

  func testSelectionChangeDuringAnalysisInvalidatesFullScope() async throws {
    await run { input, _, _ in
      let result = try self.analysis(input)
      _ = try self.store.updateSelection(ids: ["asset-3"], decision: .keep, rating: nil)
      return result
    }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .failed)
    XCTAssertTrue(try store.loadGroups().isEmpty)
    XCTAssertEqual(try store.loadAssets().last?.decision, .keep)
  }

  func testEqualValueManualUndoDuringAnalysisStillInvalidatesHistoryFence() async throws {
    await run { input, _, _ in
      let result = try self.analysis(input)
      let command = try self.store.commitGroupCommand(self.store.previewGroupCommand(
        .create(assetIDs: ["asset-0"], name: "Manual", kind: "Manual")))
      _ = try self.store.undoGroupCommand(id: command.id)
      return result
    }
    XCTAssertTrue(try store.loadGroups().isEmpty)
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .failed)
    XCTAssertEqual(try store.loadGroupCommands().count, 2)
  }

  func testSourceChangeAfterReadInvalidatesBeforeGroupWrites() async throws {
    await run { input, _, _ in
      let result = try self.analysis(input)
      try Data("changed-content-longer".utf8).write(to: input.assets[0].resolvedURL)
      return result
    }
    XCTAssertTrue(try store.loadGroups().isEmpty)
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .failed)
  }

  func testCancellationAndProviderFailureKeepIngestCompletedAndCanRetry() async throws {
    await run { _, _, _ in throw LibraryError.cancelled }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .cancelled)
    XCTAssertEqual(try store.loadSessions()[0].status, "completed")
    await run { _, _, _ in throw LibraryError.invalid("missing helper") }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .failed)
    await run { input, _, _ in try self.analysis(input, ranges: []) }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .completedNoGroups)
    XCTAssertTrue(try store.loadGroupCommands().isEmpty)
    await run { _, _, _ in XCTFail("No-group success is still one successful pass"); throw LibraryError.cancelled }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .completedNoGroups)
  }

  func testCrossConnectionLeaseAndAbandonedAttemptRecovery() async throws {
    var lease: AutomaticGroupingScopeLease? = try store.acquireAutomaticGroupingLease(sessionID)
    let second = try LibraryStore(databaseURL: databaseURL)
    XCTAssertThrowsError(try second.acquireAutomaticGroupingLease(sessionID))
    let abandoned = try XCTUnwrap(store.claimAutomaticGrouping(sessionID: sessionID))
    lease = nil
    XCTAssertNil(lease)
    await run { input, _, _ in
      XCTAssertNotEqual(input.runID, abandoned.runID)
      return try self.analysis(input)
    }
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .applied)
    try store.failAutomaticGrouping(abandoned, error: LibraryError.cancelled)
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .applied)
  }

  func testPreparedBatchScopeMustStillMatchAtCommitAndPreparedDigestRejectsTampering() throws {
    let batch = try XCTUnwrap(prepare())
    let altered = AutomaticGroupingBatch(runID: batch.runID, sessionID: batch.sessionID,
      scopeFingerprint: batch.scopeFingerprint, groups: Array(batch.groups.prefix(1)), proofs: batch.proofs,
      provenance: batch.provenance, skippedProtectedRanges: batch.skippedProtectedRanges)
    XCTAssertThrowsError(try store.previewGroupCommand(.automaticBatch(altered)))
    let preview = try store.previewGroupCommand(.automaticBatch(batch))
    _ = try store.updateSelection(ids: ["asset-1"], decision: nil, rating: 5)
    XCTAssertThrowsError(try store.commitGroupCommand(preview))
    XCTAssertTrue(try store.loadGroups().isEmpty)
  }

  func testCommitWinsAndLateCancellationCannotRewriteAppliedLedger() throws {
    let input = try XCTUnwrap(store.claimAutomaticGrouping(sessionID: sessionID))
    let batch = try XCTUnwrap(store.prepareAutomaticGrouping(analysis(input), input: input, checkCancellation: {}))
    try store.commitAutomaticGroupingBatch(batch, checkCancellation: {})
    try store.failAutomaticGrouping(input, error: LibraryError.cancelled)
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .applied)
    XCTAssertEqual(try store.loadGroupCommands().count, 1)
  }

  func testCancellationBeforeCommitLeavesGroupsAndHistoryUntouched() throws {
    let batch = try XCTUnwrap(prepare())
    XCTAssertThrowsError(try store.commitAutomaticGroupingBatch(batch, checkCancellation: { throw LibraryError.cancelled }))
    XCTAssertTrue(try store.loadGroups().isEmpty)
    XCTAssertTrue(try store.loadGroupCommands().isEmpty)
  }

  func testSubsetResultAndWrongProofCannotBecomePreparedBatch() throws {
    let input = try XCTUnwrap(store.claimAutomaticGrouping(sessionID: sessionID))
    let subset = AutomaticGroupingInput(runID: input.runID, sessionID: input.sessionID,
      projectID: input.projectID, scopeFingerprint: input.scopeFingerprint,
      assets: Array(input.assets.prefix(2)), assetRevisions: Array(input.assetRevisions.prefix(2)),
      protectedAssetIDs: input.protectedAssetIDs)
    XCTAssertThrowsError(try store.prepareAutomaticGrouping(analysis(subset, ranges: [0...1]),
      input: input, checkCancellation: {}))
    let valid = try analysis(input)
    var proofs = valid.sourceProofs
    proofs[0] = AutomaticGroupingSourceProof(assetID: input.assets[0].id,
      verifiedSHA256: String(repeating: "0", count: 64), finalStamp: proofs[0].finalStamp, issue: nil)
    let wrongProof = AutomaticGroupingAnalysis(runID: valid.runID, scopeFingerprint: valid.scopeFingerprint,
      manifest: valid.manifest, result: valid.result, observations: valid.observations,
      featuresAvailable: valid.featuresAvailable, sourceProofs: proofs, provenance: valid.provenance)
    XCTAssertThrowsError(try store.prepareAutomaticGrouping(wrongProof, input: input, checkCancellation: {}))
    XCTAssertTrue(try store.loadGroupCommands().isEmpty)
    XCTAssertNil(try store.automaticGroupingRun(sessionID: sessionID)?.preparedBatchFingerprint)
  }

  func testSourceChangesAfterPreparationAreRecheckedInCommitTransaction() throws {
    let batch = try XCTUnwrap(prepare())
    let preview = try store.previewGroupCommand(.automaticBatch(batch))
    try Data("changed after preview".utf8).write(to: root.appendingPathComponent("source/DSC0.ARW"))
    XCTAssertThrowsError(try store.commitGroupCommand(preview))
    XCTAssertTrue(try store.loadGroups().isEmpty)
    XCTAssertTrue(try store.loadGroupCommands().isEmpty)
  }

  func testCompletedImportInvokesCallbackWithReleasedSessionLeaseAndActiveCancellationCheck() async throws {
    let calls = AutomaticCallbackCounter()
    let importer = ImportService(store: store, postIngest: { session, check, progress in
      calls.increment()
      XCTAssertEqual(session.status, "completed")
      do {
        try check()
        let lease = try self.store.acquireAutomaticGroupingLease(session.id)
        withExtendedLifetime(lease) {}
      } catch {
        XCTFail("Completed ingest callback must have an active cancellation check and released session lease: \(error)")
      }
      progress(TaskProgress(title: "automatic callback", isRunning: false))
    })
    let result = try await importer.resume(sessionID: sessionID, progress: { _ in })
    XCTAssertEqual(result.status, "completed")
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(try store.loadSessions()[0].status, "completed")
  }

  func testIncompleteSessionCannotBeClaimedAndLedgerDoesNotChangeSchemaVersion() throws {
    var session = try XCTUnwrap(store.loadSessions().first)
    session.status = "partial"; session.scanCompleted = false
    try store.saveSession(session)
    let before = try store.rows("PRAGMA user_version")
    XCTAssertThrowsError(try store.claimAutomaticGrouping(sessionID: sessionID))
    XCTAssertNil(try store.automaticGroupingRun(sessionID: sessionID))
    XCTAssertEqual(try store.rows("PRAGMA user_version"), before)
  }
}

private final class AutomaticCallbackCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.lock(); defer { lock.unlock() }; return value }
  func increment() { lock.lock(); value += 1; lock.unlock() }
}
