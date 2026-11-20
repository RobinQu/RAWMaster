import XCTest
@testable import RAWMasterCore

final class GroupCommandLookupTests: XCTestCase {
  private var root: URL!
  private var database: URL!
  private var store: LibraryStore!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterGroupLookup-" + UUID().uuidString)
    database = root.appendingPathComponent("library.sqlite")
    store = try LibraryStore(databaseURL: database)
    try store.saveProject(ProjectRecord(id: "project", name: "Lookup"))
    try store.saveSession(ImportSession(id: "session", projectID: "project", projectName: "Lookup",
      sourcePath: root.appendingPathComponent("source").path, mode: .reference))
    for id in ["a", "b"] {
      _ = try store.register(AssetRecord(id: id, sessionID: "session", projectID: "project",
        sourcePath: root.appendingPathComponent("source/" + id + ".ARW").path))
    }
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func perform(_ request: GroupCommandRequest) throws -> GroupCommandRecord {
    try store.commitGroupCommand(store.previewGroupCommand(request))
  }

  func testExactLookupFindsOldCommandOutsideDefaultHistoryWithoutWriting() throws {
    let old = try perform(.create(assetIDs: ["a"], name: "Old", kind: "连拍"))
    let other = try perform(.create(assetIDs: ["b"], name: "Other", kind: "连拍")).after[0].id
    for index in 0..<51 {
      _ = try perform(.rename(groupID: other, name: "Other \(index)"))
    }
    XCTAssertFalse(try store.loadGroupCommands().contains { $0.id == old.id })
    let tables = ["groups_data", "membership", "group_domains", "group_commands", "operations"]
    let before = try tables.map { try store.rows("SELECT * FROM \($0) ORDER BY rowid") }
    let found = try XCTUnwrap(store.loadGroupCommand(id: old.id))
    XCTAssertEqual(found.id, old.id)
    XCTAssertEqual(found.after.first?.assetIDs, ["a"])
    guard case .available = found.restoreStatus else { return XCTFail("Unchanged old command remains restorable") }
    XCTAssertEqual(try tables.map { try store.rows("SELECT * FROM \($0) ORDER BY rowid") }, before)
  }

  func testExactLookupRecomputesRestoredStatusAcrossRestart() throws {
    let created = try perform(.create(assetIDs: ["a"], name: "Restore", kind: "连拍"))
    _ = try store.undoGroupCommand(id: created.id)
    store = nil
    store = try LibraryStore(databaseURL: database)
    let found = try XCTUnwrap(store.loadGroupCommand(id: created.id))
    guard case .alreadyReverted = found.restoreStatus else { return XCTFail("Restored command must not expose the persisted available status") }
    XCTAssertFalse(found.compensationIDs.isEmpty)
    XCTAssertTrue(try store.loadGroups().isEmpty)
  }

  func testExactLookupReturnsNilForMissingIDAndRecomputesConflicts() throws {
    XCTAssertNil(try store.loadGroupCommand(id: "missing' OR 1=1 --"))
    let created = try perform(.create(assetIDs: ["a"], name: "Original", kind: "连拍"))
    _ = try perform(.rename(groupID: created.after[0].id, name: "Later edit"))
    let found = try XCTUnwrap(store.loadGroupCommand(id: created.id))
    guard case .conflict = found.restoreStatus else { return XCTFail("Later changes must be reflected by exact lookup") }
  }
}
