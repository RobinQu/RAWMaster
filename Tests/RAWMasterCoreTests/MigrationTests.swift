import CSQLite
import XCTest

@testable import RAWMasterCore

final class MigrationTests: XCTestCase {
  func testVersionTwoUpgradeSeedsDomainsWithoutInventingHistoryAndPreservesWALBackup() throws {
    let active = try v1Fixture()
    defer { sqlite3_close(active) }
    try exec(
      active,
      "CREATE TABLE relocation_sessions(id TEXT PRIMARY KEY,data TEXT NOT NULL); PRAGMA user_version=2"
    )
    let library = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try DatabaseSchema.strings(library.db, "PRAGMA user_version"), ["3"])
    XCTAssertEqual(try library.loadGroupCommands().count, 0)
    XCTAssertFalse(try library.rows("SELECT * FROM group_domains WHERE group_id='group'").isEmpty)
    XCTAssertEqual(try library.loadGroups()[0].assetIDs, ["asset"])
    XCTAssertEqual(try library.loadGroups()[0].includedAssetIDs, [])
    let backup = try XCTUnwrap(library.lastMigrationBackupURL)
    var old: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(backup.path, &old, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_close(old) }
    XCTAssertEqual(try DatabaseSchema.strings(old, "PRAGMA user_version"), ["2"])
    let rename = try library.commitGroupCommand(
      library.previewGroupCommand(.rename(groupID: "group", name: "New name")))
    _ = try library.undoGroupCommand(id: rename.id)
    XCTAssertEqual(try library.loadGroups()[0].name, "Legacy group")
    XCTAssertEqual(try library.loadAssets()[0].rating, 5)
    let reopened = try LibraryStore(databaseURL: database)
    XCTAssertNil(reopened.lastMigrationBackupURL)
    XCTAssertEqual(try reopened.loadGroupCommands().count, 2)
  }
  func testVersionTwoFailedSeedRollsBackBothNewTablesAndVersion() throws {
    let active = try v1Fixture(corruptGroup: true)
    defer { sqlite3_close(active) }
    try exec(
      active,
      "CREATE TABLE relocation_sessions(id TEXT PRIMARY KEY,data TEXT NOT NULL); PRAGMA user_version=2"
    )
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try DatabaseSchema.strings(active, "PRAGMA user_version"), ["2"])
    XCTAssertEqual(
      try DatabaseSchema.strings(
        active,
        "SELECT count(*) FROM sqlite_master WHERE name IN ('group_commands','group_domains')"),
      ["0"])
    XCTAssertEqual(try DatabaseSchema.strings(active, "SELECT data FROM groups_data"), ["not JSON"])
    try exec(active, "DELETE FROM membership; DELETE FROM groups_data")
    let reopened = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try reopened.loadGroupCommands().count, 0)
  }
  func testStandaloneWALHeaderHigherSchemaAndViewOnlyUnknownAreRejectedWithoutSidecars() throws {
    var connection = try open()
    try exec(
      connection,
      "PRAGMA journal_mode=WAL; CREATE VIEW unknown_view AS SELECT 1; PRAGMA user_version=99")
    try exec(connection, "PRAGMA wal_checkpoint(TRUNCATE)")
    sqlite3_close(connection)
    for suffix in ["-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: database.path + suffix)
    }
    let before = try Data(contentsOf: database)
    XCTAssertEqual(before[18], 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try Data(contentsOf: database), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
    connection = try open()
    try exec(connection, "PRAGMA user_version=0; PRAGMA wal_checkpoint(TRUNCATE)")
    sqlite3_close(connection)
    for suffix in ["-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: database.path + suffix)
    }
    let unknown = try Data(contentsOf: database)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try Data(contentsOf: database), unknown)
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
  }
  func testKnownSchemaWithUnexpectedViewRejectedWithoutUpgradeBackup() throws {
    let connection = try v1Fixture()
    try exec(connection, "CREATE VIEW unknown_view AS SELECT id FROM assets")
    sqlite3_close(connection)
    let before = try Data(contentsOf: database)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try Data(contentsOf: database), before)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Migration Backups").path))
  }
  func testActualVersionOneBaselineCopyPreservesCountsAndInputBytes() throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_V1_BASELINE"] else {
      throw XCTSkip(
        "Set RAWMASTER_V1_BASELINE to opt into a read-only real-library snapshot validation")
    }
    let original = URL(fileURLWithPath: path)
    let before = try FileSafety.hash(original)
    try FileManager.default.copyItem(at: original, to: database)
    let library = try LibraryStore(databaseURL: database)
    XCTAssertNotNil(library.lastMigrationBackupURL)
    XCTAssertEqual(try library.loadAssets().count, 153)
    XCTAssertEqual(try library.loadGroups().count, 1)
    XCTAssertEqual(try library.loadGroups()[0].assetIDs.count, 2)
    XCTAssertTrue(try library.loadGroups()[0].locked)
    XCTAssertEqual(
      try DatabaseSchema.strings(library.db, "SELECT count(*) FROM operations"), ["469"])
    XCTAssertEqual(try FileSafety.hash(original), before)
  }
  var root: URL!
  var database: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RAWMasterMigration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = root.appendingPathComponent("library.sqlite")
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  func open() throws -> OpaquePointer {
    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
      throw LibraryError.invalid("fixture open")
    }
    return db
  }
  func exec(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseSchema.error(db) }
  }
  func insert<T: Encodable>(_ db: OpaquePointer, _ table: String, _ values: [String], _ record: T)
    throws
  {
    let data = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    let arguments = values + [data]
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db, "INSERT INTO \(table) VALUES(\(arguments.map{_ in "?"}.joined(separator:",")))", -1,
        &statement, nil) == SQLITE_OK
    else { throw DatabaseSchema.error(db) }
    defer { sqlite3_finalize(statement) }
    for (i, value) in arguments.enumerated() {
      sqlite3_bind_text(
        statement, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseSchema.error(db) }
  }
  func v1Fixture(corruptGroup: Bool = false) throws -> OpaquePointer {
    let db = try open()
    try exec(
      db,
      """
      PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
      CREATE TABLE projects(id TEXT PRIMARY KEY,data TEXT NOT NULL);
      CREATE TABLE sessions(id TEXT PRIMARY KEY,data TEXT NOT NULL);
      CREATE TABLE assets(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,source_path TEXT NOT NULL,data TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,UNIQUE(session_id,source_path));
      CREATE TABLE groups_data(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,data TEXT NOT NULL);
      CREATE TABLE membership(group_id TEXT NOT NULL REFERENCES groups_data(id),asset_id TEXT NOT NULL REFERENCES assets(id),position INTEGER NOT NULL,included INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(group_id,asset_id));
      CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE operations(id TEXT PRIMARY KEY,device_id TEXT NOT NULL,entity_id TEXT NOT NULL,base_revision INTEGER NOT NULL,resulting_revision INTEGER NOT NULL,payload_version INTEGER NOT NULL,action TEXT NOT NULL,payload TEXT NOT NULL,timestamp REAL NOT NULL);
      INSERT INTO metadata VALUES('deviceID','legacy-device');
      PRAGMA user_version=1;
      """)
    try insert(db, "projects", ["project"], ProjectRecord(id: "project", name: "Old"))
    let s = ImportSession(
      id: "session", projectID: "project", projectName: "Old", sourcePath: "/old/card",
      destinationPath: "/old/work", mode: .copy, status: "completed", discovered: 1, completed: 1,
      scanCompleted: true)
    try insert(db, "sessions", [s.id], s)
    let a = AssetRecord(
      id: "asset", sessionID: s.id, projectID: s.projectID, sourcePath: "/old/card/a.ARW",
      currentPath: "/old/work/RAWMaster-session/a.ARW", relativePath: "a.ARW", fileSize: 123,
      contentHash: "legacy-hash", decision: .keep, rating: 5, importState: .ready)
    let data = String(decoding: try JSONEncoder().encode(a), as: UTF8.self).replacingOccurrences(
      of: "'", with: "''")
    try exec(db, "INSERT INTO assets VALUES('asset','session','/old/card/a.ARW','\(data)',7)")
    // Frozen old JSON intentionally lacks all new group/model fields.
    let group =
      corruptGroup
      ? "not JSON"
      : "{\"id\":\"group\",\"projectID\":\"project\",\"name\":\"Legacy group\",\"kind\":\"HDR\",\"assetIDs\":[\"asset\"],\"includedAssetIDs\":[\"asset\"]}"
    try exec(
      db,
      "INSERT INTO groups_data VALUES('group','project','\(group)'); INSERT INTO membership VALUES('group','asset',4,0)"
    )
    return db
  }
  func testVersionOneUpgradeIncludesActiveWALAndDefaultsAndReopensWithoutAnotherBackup() throws {
    let active = try v1Fixture()
    defer { sqlite3_close(active) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path + "-wal"))
    let library = try LibraryStore(databaseURL: database)
    let backup = try XCTUnwrap(library.lastMigrationBackupURL)
    var snapshot: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(backup.path, &snapshot, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_close(snapshot) }
    XCTAssertEqual(try DatabaseSchema.strings(snapshot, "PRAGMA user_version"), ["1"])
    XCTAssertEqual(try DatabaseSchema.strings(snapshot, "SELECT count(*) FROM assets"), ["1"])
    XCTAssertEqual(try library.loadAssets()[0].rating, 5)
    XCTAssertEqual(try library.loadAssets()[0].effectiveSourcePath, "/old/card/a.ARW")
    XCTAssertEqual(
      try library.loadAssets()[0].effectiveManagedPath, "/old/work/RAWMaster-session/a.ARW")
    let group = try library.loadGroups()[0]
    XCTAssertEqual(group.origin, .manual)
    XCTAssertTrue(group.locked)
    XCTAssertEqual(group.assetIDs, ["asset"])
    XCTAssertEqual(group.includedAssetIDs, [])
    XCTAssertEqual(try library.loadSessions()[0].effectiveManagedRoot, "/old/work")
    XCTAssertEqual(try DatabaseSchema.strings(library.db, "PRAGMA user_version"), ["3"])
    let reopened = try LibraryStore(databaseURL: database)
    XCTAssertNil(reopened.lastMigrationBackupURL)
    XCTAssertEqual(try reopened.loadAssets()[0].decision, .keep)
  }
  func testHigherAndUnknownSchemasRejectedBeforeAnyDatabaseWrite() throws {
    let db = try open()
    defer { sqlite3_close(db) }
    try exec(
      db,
      "CREATE TABLE private_data(value TEXT); INSERT INTO private_data VALUES('keep'); PRAGMA user_version=99"
    )
    let before = try Data(contentsOf: database)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try Data(contentsOf: database), before)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Migration Backups").path))
    try exec(db, "PRAGMA user_version=0")
    let unknown = try Data(contentsOf: database)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try Data(contentsOf: database), unknown)
    try exec(db, "PRAGMA user_version=1")
    let malformed = try Data(contentsOf: database)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try Data(contentsOf: database), malformed)
  }
  func testBackupFailureAbortsBeforeUpgradeAndMigrationFailureRollsBack() throws {
    let active = try v1Fixture(corruptGroup: true)
    defer { sqlite3_close(active) }
    let blocked = root.appendingPathComponent("blocked")
    try Data("file".utf8).write(to: blocked)
    let walURL = URL(fileURLWithPath: database.path + "-wal")
    let before = try Data(contentsOf: walURL)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database, migrationBackupDirectory: blocked))
    XCTAssertEqual(try Data(contentsOf: walURL), before)
    XCTAssertThrowsError(try LibraryStore(databaseURL: database))
    XCTAssertEqual(try DatabaseSchema.strings(active, "PRAGMA user_version"), ["1"])
    XCTAssertEqual(
      try DatabaseSchema.strings(
        active, "SELECT count(*) FROM sqlite_master WHERE name='relocation_sessions'"), ["0"])
    XCTAssertEqual(try DatabaseSchema.strings(active, "SELECT data FROM groups_data"), ["not JSON"])
    let backups = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("Migration Backups"), includingPropertiesForKeys: nil)
    XCTAssertEqual(
      backups.filter { $0.pathExtension == "sqlite" }.count, 1,
      backups.map(\.lastPathComponent).joined(separator: ","))
    // Repair the fixture, then verify reopening performs one atomic successful upgrade.
    try exec(active, "DELETE FROM membership; DELETE FROM groups_data")
    let reopened = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try reopened.loadAssets().count, 1)
  }
}
