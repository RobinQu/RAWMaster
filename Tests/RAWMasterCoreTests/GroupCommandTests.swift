import XCTest

@testable import RAWMasterCore

final class GroupCommandTests: XCTestCase {
  func testRestorePositionCollisionRejectsWithoutAcquiringIndependentMemberDomain() throws {
    let group = try create(["a", "b", "c"]).after[0].id
    let removeC = try perform(.removeMembers(groupID: group, assetIDs: ["c"]))
    let removeB = try perform(.removeMembers(groupID: group, assetIDs: ["b"]))
    let restoreC = try store.undoGroupCommand(id: removeC.id)
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, ["a", "c"])
    let participation = try perform(
      .setParticipation(groupIDs: [group], assetIDs: ["c"], included: false))
    let tables = ["groups_data", "membership", "group_domains", "group_commands", "operations"]
    let before = try tables.map { try store.rows("SELECT * FROM \($0) ORDER BY rowid") }
    let requestID = UUID().uuidString
    for _ in 0..<2 {
      XCTAssertThrowsError(try store.undoGroupCommand(id: removeB.id, requestID: requestID))
      XCTAssertEqual(
        try tables.map { try store.rows("SELECT * FROM \($0) ORDER BY rowid") }, before)
    }
    let remaining = try store.loadGroups()[0]
    XCTAssertEqual(remaining.assetIDs, ["a", "c"])
    XCTAssertFalse(remaining.includedAssetIDs.contains("c"))
    XCTAssertEqual(
      try store.rows(
        "SELECT logical_writer_id,last_operation_id FROM group_domains WHERE group_id=? AND domain='member:c'",
        [group]), [[participation.id, participation.id]])
    let history = try store.loadGroupCommands()
    guard case .conflict = history.first(where: { $0.id == removeB.id })?.restoreStatus else {
      return XCTFail("Colliding inverse must be shown as a conflict")
    }
    _ = try store.undoGroupCommand(id: participation.id)
    XCTAssertTrue(try store.loadGroups()[0].includedAssetIDs.contains("c"))
    _ = try store.undoGroupCommand(id: restoreC.id)
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, ["a"])
    _ = try store.undoGroupCommand(id: removeB.id, requestID: requestID)
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, ["a", "b"])
    _ = try store.undoGroupCommand(id: removeC.id)
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, ["a", "b", "c"])
  }

  func testMultiEntityFailureRollsBackGroupsDomainsCommandsAndOperations() throws {
    let first = try create(["a", "b"]).after[0].id
    let second = try create(["b", "c"]).after[0].id
    let preview = try store.previewGroupCommand(
      .merge(groupIDs: [first, second], name: "Merged", kind: "HDR"))
    let beforeGroups = try store.rows("SELECT id,data FROM groups_data ORDER BY id")
    let beforeDomains = try store.rows("SELECT * FROM group_domains ORDER BY group_id,domain")
    let beforeMembers = try store.rows("SELECT * FROM membership ORDER BY group_id,asset_id")
    let beforeOperations = try store.rows("SELECT count(*) FROM operations")
    let beforeCommands = try store.rows("SELECT count(*) FROM group_commands")
    try store.exec(
      "CREATE TEMP TRIGGER inject_failure BEFORE INSERT ON group_commands BEGIN SELECT RAISE(ABORT,'injected command failure'); END"
    )
    XCTAssertThrowsError(try store.commitGroupCommand(preview))
    XCTAssertEqual(try store.rows("SELECT id,data FROM groups_data ORDER BY id"), beforeGroups)
    XCTAssertEqual(
      try store.rows("SELECT * FROM group_domains ORDER BY group_id,domain"), beforeDomains)
    XCTAssertEqual(
      try store.rows("SELECT * FROM membership ORDER BY group_id,asset_id"), beforeMembers)
    XCTAssertEqual(try store.rows("SELECT count(*) FROM operations"), beforeOperations)
    XCTAssertEqual(try store.rows("SELECT count(*) FROM group_commands"), beforeCommands)
    try store.exec("DROP TRIGGER inject_failure")
    _ = try store.commitGroupCommand(preview)
    XCTAssertEqual(try store.loadGroups().count, 1)
  }
  func testCrossProjectAndMalformedInputFailWithoutAnyGroupWrites() throws {
    _ = try create(["a"])
    try store.saveProject(ProjectRecord(id: "other", name: "Other"))
    try store.saveSession(
      ImportSession(
        id: "other-session", projectID: "other", projectName: "Other",
        sourcePath: root.appendingPathComponent("other").path, mode: .reference))
    _ = try store.register(
      AssetRecord(
        id: "foreign", sessionID: "other-session", projectID: "other",
        sourcePath: root.appendingPathComponent("other/foreign.ARW").path))
    let foreign = try create(["foreign"], name: "Foreign").after[0].id
    let first = try store.loadGroups().first(where: { $0.id != foreign })!.id
    XCTAssertThrowsError(
      try perform(.merge(groupIDs: [first, foreign], name: "Mixed", kind: "HDR")))
    XCTAssertThrowsError(
      try perform(
        .setParticipation(groupIDs: [first, foreign], assetIDs: ["a", "foreign"], included: false)))
    XCTAssertThrowsError(
      try perform(.create(assetIDs: ["a", "a"], name: "Duplicate", kind: "HDR")))
    XCTAssertThrowsError(try perform(.rename(groupID: first, name: "   ")))
    XCTAssertEqual(try store.loadGroups().count, 2)
  }
  var root: URL!
  var dbURL: URL!
  var store: LibraryStore!
  let ids = ["a", "b", "c", "d"]
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RAWMasterGroups-" + UUID().uuidString)
    dbURL = root.appendingPathComponent("library.sqlite")
    store = try LibraryStore(databaseURL: dbURL)
    try store.saveProject(ProjectRecord(id: "project", name: "Test"))
    try store.saveSession(
      ImportSession(
        id: "session", projectID: "project", projectName: "Test",
        sourcePath: root.appendingPathComponent("source").path, mode: .reference))
    for id in ids {
      _ = try store.register(
        AssetRecord(
          id: id, sessionID: "session", projectID: "project",
          sourcePath: root.appendingPathComponent("source/" + id + ".ARW").path))
    }
  }
  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: root)
  }
  @discardableResult func perform(_ request: GroupCommandRequest, _ choices: [String: Bool] = [:])
    throws -> GroupCommandRecord
  {
    try store.commitGroupCommand(
      store.previewGroupCommand(request), participationResolutions: choices)
  }
  func create(_ members: [String]? = nil, name: String = "Group") throws -> GroupCommandRecord {
    try perform(.create(assetIDs: members ?? ids, name: name, kind: "连拍"))
  }
  func testSequentialUndoRestoresLogicalAggregateButPhysicalRevisionsOnlyIncrease() throws {
    let created = try create()
    let group = created.after[0].id
    let renamed = try perform(.rename(groupID: group, name: "Renamed"))
    let member = try perform(.setParticipation(groupIDs: [group], assetIDs: ["a"], included: false))
    let before = try store.loadGroups()[0].groupRevision
    _ = try store.undoGroupCommand(id: member.id)
    _ = try store.undoGroupCommand(id: renamed.id)
    XCTAssertEqual(try store.loadGroups()[0].name, "Group")
    XCTAssertGreaterThan(try store.loadGroups()[0].groupRevision, before)
    _ = try store.undoGroupCommand(id: created.id)
    XCTAssertTrue(try store.loadGroups().isEmpty)
    let domains = try store.rows(
      "SELECT revision,last_operation_id,tombstoned FROM group_domains WHERE group_id=? AND domain='all'",
      [group])
    XCTAssertGreaterThan(Int(domains[0][0])!, before)
    XCTAssertFalse(domains[0][1].isEmpty)
    XCTAssertEqual(domains[0][2], "1")
  }
  func testIndependentMemberSurvivesRenameRestoreAndWholeRestoreRemainsBlocked() throws {
    let created = try create()
    let group = created.after[0].id
    let renamed = try perform(.rename(groupID: group, name: "Renamed"))
    let member = try perform(.setParticipation(groupIDs: [group], assetIDs: ["b"], included: false))
    _ = try store.undoGroupCommand(id: renamed.id)
    XCTAssertEqual(try store.loadGroups()[0].name, "Group")
    XCTAssertFalse(try store.loadGroups()[0].includedAssetIDs.contains("b"))
    XCTAssertThrowsError(try store.undoGroupCommand(id: created.id))
    _ = try store.undoGroupCommand(id: member.id)
    _ = try store.undoGroupCommand(id: created.id)
    XCTAssertEqual(try store.loadGroups().count, 0)
  }
  func testMinimalMemberCompensationPreservesLaterRatingsAndOtherMember() throws {
    let group = try create().after[0].id
    let a = try perform(.setParticipation(groupIDs: [group], assetIDs: ["a"], included: false))
    _ = try perform(.setParticipation(groupIDs: [group], assetIDs: ["b"], included: false))
    let selection = try store.updateSelection(ids: ["a"], decision: .keep, rating: 5)
    _ = try store.undoGroupCommand(id: a.id)
    XCTAssertTrue(try store.loadGroups()[0].includedAssetIDs.contains("a"))
    XCTAssertFalse(try store.loadGroups()[0].includedAssetIDs.contains("b"))
    XCTAssertEqual(try store.loadAssets()[0].decision, .keep)
    XCTAssertEqual(try store.loadAssets()[0].rating, 5)
    try store.undoSelection(selection)
    XCTAssertEqual(try store.loadAssets()[0].rating, 0)
  }
  func testSameDomainABARejectedAndFineUndoSurvivesUnrelatedPreviewChange() throws {
    let group = try create().after[0].id
    let first = try perform(.rename(groupID: group, name: "B"))
    _ = try perform(.rename(groupID: group, name: "C"))
    _ = try perform(.rename(groupID: group, name: "B"))
    XCTAssertThrowsError(try store.undoGroupCommand(id: first.id))
    let preview = try store.previewGroupCommand(.rename(groupID: group, name: "D"))
    _ = try perform(.setParticipation(groupIDs: [group], assetIDs: ["a"], included: false))
    _ = try store.commitGroupCommand(preview)
    XCTAssertEqual(try store.loadGroups()[0].name, "D")
    XCTAssertFalse(try store.loadGroups()[0].includedAssetIDs.contains("a"))
  }
  func testCompensationNeverAddsAutoLockAndInverseCompensationIsUndoable() throws {
    let created = try create()
    let group = created.after[0].id
    let unlock = try perform(.setLocked(groupID: group, locked: false))
    XCTAssertFalse(try store.loadGroups()[0].locked)
    let rename = try perform(.rename(groupID: group, name: "Locked edit"))
    XCTAssertTrue(try store.loadGroups()[0].locked)
    let inverse = try store.undoGroupCommand(id: rename.id)
    XCTAssertFalse(try store.loadGroups()[0].locked)
    _ = try store.undoGroupCommand(id: inverse.id)
    XCTAssertEqual(try store.loadGroups()[0].name, "Locked edit")
    XCTAssertTrue(try store.loadGroups()[0].locked)
    _ = try store.undoGroupCommand(id: rename.id)
    XCTAssertFalse(try store.loadGroups()[0].locked)
    _ = try store.undoGroupCommand(id: unlock.id)
    _ = try store.undoGroupCommand(id: created.id)
    XCTAssertTrue(try store.loadGroups().isEmpty)
  }
  func testMergeRequiresExplicitConflictChoiceAndRestoresSourceTombstonesAtomically() throws {
    let first = try create(["a", "b"], name: "One").after[0].id
    let second = try create(["a", "c"], name: "Two").after[0].id
    _ = try perform(.setParticipation(groupIDs: [second], assetIDs: ["a"], included: false))
    let preview = try store.previewGroupCommand(
      .merge(groupIDs: [first, second], name: "Merged", kind: "HDR"))
    XCTAssertEqual(preview.inclusionConflicts.map(\.assetID), ["a"])
    XCTAssertThrowsError(try store.commitGroupCommand(preview))
    XCTAssertEqual(try store.loadGroups().count, 2)
    XCTAssertThrowsError(
      try store.commitGroupCommand(preview, participationResolutions: ["a": true, "b": false]))
    let merged = try store.commitGroupCommand(preview, participationResolutions: ["a": false])
    XCTAssertEqual(try store.loadGroups().count, 1)
    XCTAssertEqual(merged.after[0].assetIDs, ["a", "b", "c"])
    XCTAssertFalse(merged.after[0].includedAssetIDs.contains("a"))
    _ = try store.undoGroupCommand(id: merged.id)
    let restored = try store.loadGroups()
    XCTAssertEqual(Set(restored.map(\.id)), Set([first, second]))
    XCTAssertTrue(restored.first(where: { $0.id == first })!.includedAssetIDs.contains("a"))
    XCTAssertFalse(restored.first(where: { $0.id == second })!.includedAssetIDs.contains("a"))
    XCTAssertFalse(
      try store.rows(
        "SELECT * FROM group_domains WHERE group_id=? AND tombstoned=1", [merged.after[0].id]
      ).isEmpty)
  }
  func testSplitPreservesParticipationEmptyRulesAndUndo() throws {
    let group = try create().after[0].id
    _ = try perform(.setParticipation(groupIDs: [group], assetIDs: ["b"], included: false))
    XCTAssertThrowsError(
      try store.previewGroupCommand(
        .split(groupID: group, movedAssetIDs: ids, newName: "All", newKind: "HDR")))
    XCTAssertThrowsError(
      try store.previewGroupCommand(
        .split(groupID: group, movedAssetIDs: [], newName: "Empty", newKind: "HDR")))
    let split = try perform(
      .split(groupID: group, movedAssetIDs: ["c", "b"], newName: "Part", newKind: "HDR"))
    let new = try XCTUnwrap(split.after.first(where: { $0.id != group }))
    XCTAssertEqual(new.assetIDs, ["b", "c"])
    XCTAssertEqual(new.includedAssetIDs, ["c"])
    XCTAssertTrue(new.locked)
    _ = try store.undoGroupCommand(id: split.id)
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, ids)
    XCTAssertFalse(try store.loadGroups()[0].includedAssetIDs.contains("b"))
    let empty = try perform(.removeMembers(groupID: group, assetIDs: ids))
    XCTAssertEqual(try store.loadGroups().count, 1)
    XCTAssertTrue(try store.loadGroups()[0].assetIDs.isEmpty)
    _ = try store.undoGroupCommand(id: empty.id)
    XCTAssertEqual(try store.loadGroups()[0].assetIDs, ids)
  }
  func testDeletePreviewInvalidatedByAnyInterveningGroupFieldEvenIfCompensated() throws {
    let first = try create(["a", "b"]).after[0].id
    let second = try create(["c", "d"]).after[0].id
    let requests: [GroupCommandRequest] = [
      .rename(groupID: first, name: "Other"), .setKind(groupID: first, kind: "HDR"),
      .setLocked(groupID: first, locked: false),
      .setParticipation(groupIDs: [first], assetIDs: ["a"], included: false),
    ]
    for request in requests {
      let preview = try store.previewGroupCommand(
        .merge(groupIDs: [first, second], name: "Merged", kind: "HDR"))
      let change = try perform(request)
      _ = try store.undoGroupCommand(id: change.id)
      XCTAssertThrowsError(try store.commitGroupCommand(preview))
    }
  }
  func testDeterministicIDsTamperedSnapshotsAndIdempotentRequests() throws {
    var preview = try store.previewGroupCommand(
      .create(assetIDs: ["a", "b"], name: " Name ", kind: " HDR "))
    let expectedID = preview.after[0].id
    preview.after[0].id = "forged"
    preview.after[0].name = "forged"
    preview.after[0].assetIDs = ["d"]
    let first = try store.commitGroupCommand(preview)
    XCTAssertEqual(first.after[0].id, expectedID)
    XCTAssertEqual(first.after[0].name, "Name")
    XCTAssertEqual(first.after[0].assetIDs, ["a", "b"])
    let again = try store.commitGroupCommand(preview)
    XCTAssertEqual(again.id, first.id)
    XCTAssertEqual(try store.loadGroupCommands().count, 1)
    preview.request = .create(assetIDs: ["a"], name: "different", kind: "HDR")
    XCTAssertThrowsError(try store.commitGroupCommand(preview))
    let requestID = UUID().uuidString
    let inverse = try store.undoGroupCommand(id: first.id, requestID: requestID)
    let retry = try store.undoGroupCommand(id: first.id, requestID: requestID)
    XCTAssertEqual(inverse.id, retry.id)
    XCTAssertEqual(try store.loadGroups().count, 0)
    XCTAssertThrowsError(try store.undoGroupCommand(id: "other", requestID: requestID))
  }
  func testHistoryAndCompensationSurviveReopenAndNoSourceFilesAreTouched() throws {
    let command = try create()
    let group = command.after[0].id
    _ = try perform(.setLocked(groupID: group, locked: false))
    let rename = try perform(.rename(groupID: group, name: "Recent"))
    store = nil
    store = try LibraryStore(databaseURL: dbURL)
    let recent = try store.loadGroupCommands()
    XCTAssertEqual(recent.first?.id, rename.id)
    let preview = try store.previewGroupCommand(.restore(commandID: rename.id))
    let restored = try store.commitGroupCommand(preview)
    XCTAssertFalse(try store.loadGroups()[0].locked)
    _ = try store.undoGroupCommand(id: restored.id)
    XCTAssertEqual(try store.loadGroups()[0].name, "Recent")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("source").path))
    XCTAssertFalse(
      try store.loadGroupCommands().first(where: { $0.id == rename.id })!.compensationIDs.isEmpty)
  }
  func testLegacyGlobalParticipationIsOneCommandAndCannotAccidentallyUseEmptyScope() throws {
    let first = try create(["a", "b"]).after[0].id
    let second = try create(["a", "c"]).after[0].id
    let count = try store.loadGroupCommands().count
    try store.setSequenceMembership(ids: ["a"], included: false)
    XCTAssertEqual(try store.loadGroupCommands().count, count + 1)
    XCTAssertTrue(try store.loadGroups().allSatisfy { !$0.includedAssetIDs.contains("a") })
    let change = try store.loadGroupCommands()[0]
    _ = try store.undoGroupCommand(id: change.id)
    XCTAssertTrue(try store.loadGroups().allSatisfy { $0.includedAssetIDs.contains("a") })
    XCTAssertThrowsError(
      try perform(.setParticipation(groupIDs: [], assetIDs: ["a"], included: false)))
    XCTAssertThrowsError(
      try perform(.setParticipation(groupIDs: [first, second], assetIDs: ["d"], included: false)))
  }
}
