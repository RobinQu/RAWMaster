import CSQLite
import XCTest
@testable import RAWMasterCore

final class ColorLabelTests: XCTestCase {
  var root: URL!, database: URL!, store: LibraryStore!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ColorLabels-" + UUID().uuidString)
    database = root.appendingPathComponent("library.sqlite")
    store = try LibraryStore(databaseURL: database)
  }
  override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }
  func assets() throws -> [AssetRecord] {
    let project = ProjectRecord(name: "Colors"); try store.saveProject(project)
    let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: root.path, mode: .reference, status: "completed", discovered: 2, completed: 2, scanCompleted: true)
    try store.saveSession(session)
    let files = try (0..<2).map { number in
      let url = root.appendingPathComponent("\(number).jpg")
      let data = Data("original-\(number)".utf8)
      try data.write(to:url)
      return try store.register(AssetRecord(sessionID:session.id,projectID:project.id,sourcePath:url.path,
                                            fileSize:Int64(data.count),contentHash:try FileSafety.hash(url),importState:.ready))
    }
    try store.completedDirectImport(session)
    return files
  }
  func testLabelsAreIndependentFromTextTagsAndSearchUsesStoredColor() throws {
    let files = try assets()
    try store.setTags(ids: [files[0].id], tags: ["red", "精选"])
    try store.setTags(ids: [files[1].id], tags: ["red"])
    _ = try store.setColorLabel(ids: [files[0].id], label: .red)
    XCTAssertEqual(try store.loadTags()[files[0].id], ["red", "精选"])
    let query = ProjectSearchQuery(colorLabel: .red)
    XCTAssertEqual(try store.searchAssets(query: query).map(\.id), [files[0].id])
    XCTAssertEqual(try store.searchAssets(query: ProjectSearchQuery(tags: ["red"])).count, 2)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.loadColorLabels(), [files[0].id: .red])
    let clear = try XCTUnwrap(store.setColorLabel(ids: [files[0].id], label: nil))
    XCTAssertTrue(try store.searchAssets(query: query).isEmpty)
    XCTAssertEqual(try store.loadTags()[files[0].id], ["red", "精选"])
    try store.undoColorLabel(commandID: clear.id)
    XCTAssertEqual(try store.loadColorLabels()[files[0].id], .red)
  }
  func testUndoSurvivesRestartAndRejectsOverwritingNewerWriter() throws {
    let files = try assets()
    let first = try XCTUnwrap(store.setColorLabel(ids: files.map(\.id), label: .blue))
    let second = try XCTUnwrap(store.setColorLabel(ids: [files[0].id], label: .green))
    XCTAssertThrowsError(try store.undoColorLabel(commandID: first.id))
    store = nil; store = try LibraryStore(databaseURL: database)
    try store.undoColorLabel(commandID: second.id)
    try store.undoColorLabel(commandID: first.id)
    XCTAssertTrue(try store.loadColorLabels().isEmpty)
    XCTAssertEqual(try store.loadColorLabelCommands().filter(\.restored).count, 2)
    XCTAssertNil(try store.setColorLabel(ids: files.map(\.id), label: nil), "Clearing unlabelled files is a no-op")
  }
  func testVersionFiveMigrationBacksUpAndPreservesEveryExistingTable() throws {
    let files = try assets(); try store.setTags(ids: [files[0].id], tags: ["legacy"])
    _ = try store.updateSelection(ids: [files[0].id], decision: .keep, rating: 4, markReviewed: true)
    try removeEditingSchemaForLegacyFixture(store)
    try store.exec("DROP TABLE asset_color_labels; PRAGMA user_version=5")
    let tables = try store.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").map { $0[0] }
    let before = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try store.rows("SELECT * FROM \($0) ORDER BY rowid")) })
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try DatabaseSchema.strings(store.db, "PRAGMA user_version"), [String(DatabaseSchema.version)])
    XCTAssertTrue(try store.loadColorLabels().isEmpty)
    for table in tables { XCTAssertEqual(try store.rows("SELECT * FROM \(table) ORDER BY rowid"), before[table], table) }
    let backup = try XCTUnwrap(store.lastMigrationBackupURL)
    var old: OpaquePointer?; XCTAssertEqual(sqlite3_open_v2(backup.path, &old, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_close(old) }
    XCTAssertEqual(try DatabaseSchema.strings(old, "PRAGMA user_version"), ["5"])
    XCTAssertEqual(try DatabaseSchema.strings(old, "SELECT data FROM asset_tags"), before["asset_tags"]?.map { $0[1] })
    let reopened = try LibraryStore(databaseURL: database); XCTAssertNil(reopened.lastMigrationBackupURL)
  }
  func testVersionSixUnexpectedColorColumnsRejectedWithoutMutation() throws {
    try store.exec("ALTER TABLE asset_color_labels ADD COLUMN unknown TEXT; PRAGMA wal_checkpoint(TRUNCATE)")
    store = nil
    let before = try Data(contentsOf: database)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try Data(contentsOf: database), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Migration Backups").path))
  }
  func testLegacyQueryDecodesWithoutColorAndUnknownColorFails() throws {
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSearchQuery())) as? [String: Any])
    value.removeValue(forKey: "colorLabel")
    XCTAssertNil(try JSONDecoder().decode(ProjectSearchQuery.self, from: JSONSerialization.data(withJSONObject: value)).colorLabel)
    value["colorLabel"] = "invented"
    XCTAssertThrowsError(try JSONDecoder().decode(ProjectSearchQuery.self, from: JSONSerialization.data(withJSONObject: value)))
  }
}
