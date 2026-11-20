import Foundation
import XCTest
@testable import RAWMasterCore

extension AutomaticGroupingTests {
  private func openRegroupWorkflow() throws {
    try store.writeWorkflow(SessionWorkflow(sessionID: sessionID, projectID: "project", isNewProject: false, phase: .screening))
  }
  private func explicitService(_ analyzer: @escaping AutomaticGroupingAnalyzer) -> AutomaticGroupingService {
    AutomaticGroupingService(store: store, analyzer: analyzer)
  }
  private func modified(_ analysis: AutomaticGroupingAnalysis, features: [Bool]? = nil,
                        proofs: [AutomaticGroupingSourceProof]? = nil) -> AutomaticGroupingAnalysis {
    AutomaticGroupingAnalysis(runID: analysis.runID, scopeFingerprint: analysis.scopeFingerprint,
      manifest: analysis.manifest, result: analysis.result, observations: analysis.observations,
      featuresAvailable: features ?? analysis.featuresAvailable, sourceProofs: proofs ?? analysis.sourceProofs,
      provenance: analysis.provenance)
  }

  func testExplicitRegroupReplacesRepeatedlyWithoutDuplicatesAndUndoRestoresPreviousIdentities() async throws {
    try openRegroupWorkflow()
    await run { input, _, _ in try self.analysis(input) }
    let original = try store.loadGroups(), photos = try store.loadAssets()
    let service = explicitService { input, _, _ in try self.analysis(input) }
    let first = try await service.regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
    XCTAssertEqual(try store.loadGroups().count, 2)
    XCTAssertTrue(Set(original.map(\.id)).isDisjoint(with: first.groupIDs))
    let second = try await explicitService({ input, _, _ in try self.analysis(input, ranges: [0...3]) })
      .regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
    XCTAssertEqual(try store.loadGroups().count, 1); XCTAssertEqual(try store.loadGroupCommands().count, 3)
    store = nil; store = try LibraryStore(databaseURL: databaseURL)
    _ = try store.undoGroupCommand(id: XCTUnwrap(second.commandID))
    XCTAssertEqual(Set(try store.loadGroups().map(\.id)), Set(first.groupIDs))
    _ = try store.undoGroupCommand(id: XCTUnwrap(first.commandID))
    XCTAssertEqual(Set(try store.loadGroups().map(\.id)), Set(original.map(\.id)))
    XCTAssertEqual(try store.loadAssets().map(\.decision), photos.map(\.decision))
    XCTAssertEqual(try store.loadAssets().map(\.rating), photos.map(\.rating))
  }

  private func assertFailureRetainsSuccess(ranges: [ClosedRange<Int>]) async throws {
    try openRegroupWorkflow()
    await run { input, _, _ in try self.analysis(input, ranges: ranges) }
    let previous = try XCTUnwrap(store.automaticGroupingRun(sessionID: sessionID))
    let oldIDs = try store.loadGroups().map(\.id)
    for cancellation in [false, true] {
      do {
        _ = try await explicitService({ _, _, _ in
          if cancellation { throw CancellationError() }; throw LibraryError.invalid("injected provider failure")
        }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
        XCTFail("Explicit API must report failure")
      } catch {}
      let failed = try XCTUnwrap(store.automaticGroupingRun(sessionID: sessionID))
      XCTAssertEqual(failed.state, cancellation ? .cancelled : .failed)
      XCTAssertEqual(failed.lastSuccess?.runID, previous.runID)
      XCTAssertEqual(failed.lastSuccess?.commandID, previous.commandID)
      XCTAssertEqual(failed.lastSuccess?.groupIDs, previous.groupIDs)
      XCTAssertNil(failed.provenance, "Old success evidence is not the provenance of a failed new attempt")
      await run { _, _, _ in XCTFail("Ordinary callback must preserve once-success after explicit failure"); throw LibraryError.cancelled }
      XCTAssertEqual(try store.loadGroups().map(\.id), oldIDs)
    }
  }
  func testExplicitFailureAndCancelRetainAppliedSuccessAndDefaultStillSkips() async throws {
    try await assertFailureRetainsSuccess(ranges: [0...1, 2...3])
  }
  func testExplicitFailureAndCancelRetainSuccessfulNoGroupsAndDefaultStillSkips() async throws {
    try await assertFailureRetainsSuccess(ranges: [])
  }

  func testFullyEvidencedEmptyReplacementDeletesOldGroupsUndoably() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let oldIDs = Set(try store.loadGroups().map(\.id))
    let result = try await explicitService({ input, _, _ in try self.analysis(input, ranges: []) })
      .regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
    XCTAssertTrue(try store.loadGroups().isEmpty); XCTAssertEqual(result.state, .completedNoGroups)
    let id = try XCTUnwrap(result.commandID)
    XCTAssertEqual(result.lastSuccess?.commandID, id)
    _ = try store.undoGroupCommand(id: id)
    XCTAssertEqual(Set(try store.loadGroups().map(\.id)), oldIDs)
  }

  func testEmptyReplacementCannotDeleteOldMemberWithBadSourceProofOrMissingFeature() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let oldIDs = Set(try store.loadGroups().map(\.id)), oldHistoryCount = try store.loadGroupCommands().count
    for missingFeature in [true, false] {
      let input = try store.claimAutomaticRegroup(sessionID: sessionID)
      let empty = try analysis(input, ranges: [])
      var features = empty.featuresAvailable, proofs = empty.sourceProofs
      if missingFeature { features[0] = false }
      else { proofs[0] = AutomaticGroupingSourceProof(assetID: input.assets[0].id, verifiedSHA256: nil, finalStamp: nil, issue: "unreadable") }
      XCTAssertThrowsError(try store.prepareAutomaticRegroup(modified(empty, features: features, proofs: proofs), input: input, checkCancellation: {}))
      XCTAssertEqual(Set(try store.loadGroups().map(\.id)), oldIDs)
      XCTAssertEqual(try store.loadGroupCommands().count, oldHistoryCount)
      try store.failAutomaticGrouping(input, error: LibraryError.invalid("invalid old evidence"))
    }
  }

  func testEmptyReplacementRechecksOldSourceAfterPreparationAtCommit() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let oldIDs = Set(try store.loadGroups().map(\.id))
    let input = try store.claimAutomaticRegroup(sessionID: sessionID)
    let prepared = try XCTUnwrap(store.prepareAutomaticRegroup(analysis(input, ranges: []), input: input, checkCancellation: {}))
    try Data("changed old member before destructive empty commit".utf8).write(to: input.assets[0].resolvedURL)
    XCTAssertThrowsError(try store.commitAutomaticRegroup(prepared, checkCancellation: {}))
    XCTAssertEqual(Set(try store.loadGroups().map(\.id)), oldIDs)
    XCTAssertEqual(try store.loadGroupCommands().count, 1)
  }

  func testManualEditThenUndoPermanentlyProtectsAutomaticGroupAndItsMembers() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let protected = try XCTUnwrap(store.loadGroups().first { $0.assetIDs.contains("asset-0") })
    let edit = try store.commitGroupCommand(store.previewGroupCommand(.updateProperties(groupID: protected.id, name: "Manual", kind: "HDR", locked: false)))
    _ = try store.undoGroupCommand(id: edit.id)
    let result = try await explicitService({ input, _, _ in
      XCTAssertFalse(input.replacementGroupIDs.contains(protected.id))
      XCTAssertTrue(Set(protected.assetIDs).isSubset(of: input.protectedAssetIDs))
      return try self.analysis(input)
    }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
    XCTAssertEqual(result.skippedProtectedRanges, 1)
    XCTAssertEqual(try store.loadGroups().count, 2)
    XCTAssertTrue(try store.loadGroups().contains { $0.id == protected.id && $0.name == protected.name && !$0.locked })
  }

  func testManualOverlapPreservesWholeUntouchedAutomaticGroupAndManualGroup() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input, ranges: [0...3]) }
    let original = try XCTUnwrap(store.loadGroups().first)
    let manual = try store.commitGroupCommand(store.previewGroupCommand(.createWithProperties(
      assetIDs: ["asset-0"], name: "Manual overlap", kind: "HDR", locked: false))).after[0]
    let history = try store.loadGroupCommands().count
    let photos = try store.loadAssets()
    _ = try await explicitService({ input, _, _ in
      XCTAssertTrue(input.replacementGroupIDs.isEmpty)
      XCTAssertEqual(input.protectedAssetIDs.count, 4, "Protection propagates to every member of the retained automatic group")
      return try self.analysis(input, ranges: [0...3])
    }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
    let groups = try store.loadGroups()
    XCTAssertEqual(Set(groups.map(\.id)), Set([original.id, manual.id]))
    XCTAssertEqual(groups.first { $0.id == original.id }?.assetIDs, original.assetIDs)
    XCTAssertEqual(groups.first { $0.id == original.id }?.includedAssetIDs, original.includedAssetIDs)
    XCTAssertEqual(try store.loadGroupCommands().count, history)
    XCTAssertEqual(try store.loadAssets().map(\.decision), photos.map(\.decision))
  }

  func testHumanUndoOfAutomaticCommandIsNotReversedByExplicitRerun() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let original = try XCTUnwrap(store.automaticGroupingRun(sessionID: sessionID))
    _ = try store.undoGroupCommand(id: XCTUnwrap(original.commandID))
    let before = try store.loadGroupCommands().count
    let result = try await explicitService({ input, _, _ in
      XCTAssertTrue(input.replacementGroupIDs.isEmpty)
      XCTAssertEqual(input.protectedAssetIDs.count, 4)
      return try self.analysis(input)
    }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
    XCTAssertEqual(result.state, .completedNoGroups); XCTAssertEqual(result.skippedProtectedRanges, 2)
    XCTAssertTrue(try store.loadGroups().isEmpty); XCTAssertEqual(try store.loadGroupCommands().count, before)
  }

  func testExplicitConcurrentManualEditInvalidatesReplacementAndPreservesCurrentGroups() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let oldIDs = Set(try store.loadGroups().map(\.id))
    do {
      _ = try await explicitService({ input, _, _ in
        let result = try self.analysis(input)
        let id = try XCTUnwrap(input.replacementGroupIDs.first)
        _ = try self.store.commitGroupCommand(self.store.previewGroupCommand(.rename(groupID: id, name: "Concurrent")))
        return result
      }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
      XCTFail("Concurrent edit must invalidate replacement")
    } catch {}
    XCTAssertEqual(Set(try store.loadGroups().map(\.id)), oldIDs)
    XCTAssertTrue(try store.loadGroups().contains { $0.name == "Concurrent" })
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.state, .failed)
  }

  func testExplicitHistoryFailureRollsBackReplacementThenCanRetry() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let oldIDs = Set(try store.loadGroups().map(\.id))
    try store.exec("CREATE TEMP TRIGGER regroup_failure BEFORE INSERT ON group_commands BEGIN SELECT RAISE(ABORT,'injected regroup failure'); END")
    do { _ = try await explicitService({ input, _, _ in try self.analysis(input) }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in }); XCTFail("Expected rollback") } catch {}
    XCTAssertEqual(Set(try store.loadGroups().map(\.id)), oldIDs); XCTAssertEqual(try store.loadGroupCommands().count, 1)
    XCTAssertEqual(try store.automaticGroupingRun(sessionID: sessionID)?.lastSuccess?.groupIDs.count, 2)
    try store.exec("DROP TRIGGER regroup_failure")
    _ = try await explicitService({ input, _, _ in try self.analysis(input) }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in })
    XCTAssertEqual(try store.loadGroups().count, 2); XCTAssertEqual(try store.loadGroupCommands().count, 2)
  }

  func testExplicitRegroupRejectsClosedLegacyIncompleteAndLeaseConflict() async throws {
    try openRegroupWorkflow()
    var session = try XCTUnwrap(store.loadSessions().first)
    session.scanCompleted = false; try store.saveSession(session)
    XCTAssertThrowsError(try store.claimAutomaticRegroup(sessionID: sessionID))
    session.scanCompleted = true; try store.saveSession(session)
    for phase in [TriagePhase.closed, .legacyHistory] {
      try store.writeWorkflow(SessionWorkflow(sessionID: sessionID, projectID: "project", isNewProject: false, phase: phase))
      XCTAssertThrowsError(try store.claimAutomaticRegroup(sessionID: sessionID))
    }
    try openRegroupWorkflow()
    let lease = try store.acquireAutomaticGroupingLease(sessionID)
    do { _ = try await explicitService({ input, _, _ in try self.analysis(input) }).regroup(sessionID: sessionID, checkCancellation: {}, progress: { _ in }); XCTFail("Expected busy lease") } catch {}
    withExtendedLifetime(lease) {}
    XCTAssertNil(try store.automaticGroupingRun(sessionID: sessionID))
  }

  func testLegacyRunJSONWithoutNewLastSuccessFieldStillDecodesAndPreservesOnceSuccess() async throws {
    try openRegroupWorkflow(); await run { input, _, _ in try self.analysis(input) }
    let prior = try XCTUnwrap(store.automaticGroupingRun(sessionID: sessionID))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prior)) as? [String: Any])
    object.removeValue(forKey: "lastSuccess")
    let decoded = try JSONDecoder().decode(AutomaticGroupingRunRecord.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.lastSuccess); XCTAssertNotNil(decoded.successSnapshot)
    try store.saveAutomaticGroupingRun(decoded)
    await run { _, _, _ in XCTFail("Historical success still suppresses normal rerun"); throw LibraryError.cancelled }
  }
}
