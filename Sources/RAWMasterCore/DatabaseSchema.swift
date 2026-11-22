import CSQLite
import Foundation
import RAWMasterLibrary

enum DatabaseSchema {
  static let version = 8
  static let columns: [String: Set<String>] = [
    "projects": ["id", "data"], "sessions": ["id", "data"],
    "assets": ["id", "session_id", "source_path", "data", "revision"],
    "groups_data": ["id", "project_id", "data"],
    "membership": ["group_id", "asset_id", "position", "included"],
    "metadata": ["key", "value"],
    "operations": [
      "id", "device_id", "entity_id", "base_revision", "resulting_revision", "payload_version",
      "action", "payload", "timestamp",
    ],
  ]
  static func strings(_ db: OpaquePointer?, _ sql: String, column: Int32 = 0) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error(db) }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      values.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw error(db) }
    return values
  }
  static func error(_ db: OpaquePointer?) -> LibraryError {
    .database(String(cString: sqlite3_errmsg(db)))
  }
  /// Called on a read-only handle before any journal/schema/metadata mutation.
  static func validate(_ db: OpaquePointer?) throws -> Int {
    let found = Int(try strings(db, "PRAGMA user_version").first ?? "-1") ?? -1
    guard (0...version).contains(found) else {
      throw LibraryError.invalid("资料库版本 \(found) 高于本程序支持的版本 \(version)，未修改原库")
    }
    let owned: Set<String>
    if found == 8, let db {
      struct CatalogObjects: Decodable { let valid: Bool; let objects: [String] }
      let reply = try LibraryEngine.shared().transaction("validate", on: db, payload: LibraryEmpty(), as: CatalogObjects.self)
      guard reply.valid else { throw LibraryError.invalid("无法验证资料库目录结构") }
      owned = Set(reply.objects)
    } else { owned = [] }
    let names = Set(
      try strings(
        db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")).subtracting(owned)
    let userObjects = try strings(
      db, "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
    let unexpectedExecutableObjects = try strings(
      db,
      "SELECT name FROM sqlite_master WHERE type IN ('view','trigger') AND name NOT LIKE 'sqlite_%'"
    )
    if found == 0 {
      guard userObjects.isEmpty else { throw LibraryError.invalid("无法识别的非空资料库，未修改原库") }
      return 0
    }
    guard Set(unexpectedExecutableObjects).subtracting(owned).isEmpty else {
      throw LibraryError.invalid("资料库含未知视图或触发器，未修改原库")
    }
    var required = columns
    if found >= 2 { required["relocation_sessions"] = ["id", "data"] }
    if found >= 3 {
      required["group_commands"] = ["id", "data"]
      required["group_domains"] = [
        "group_id", "domain", "revision", "logical_writer_id", "last_operation_id", "tombstoned",
      ]
    }
    if found >= 4 {
      for (table, key) in [("session_workflows", "id"), ("project_admissions", "asset_id"), ("triage_records", "asset_id"), ("capture_pairs", "id"), ("pair_dismissals", "id"), ("triage_commands", "id"), ("quality_evidence", "asset_id"), ("asset_tags", "asset_id"), ("workflow_completions", "id")] {
        required[table] = [key, "data"]
      }
    }
    if found >= 5 {
      for (table, key) in [("review_records", "asset_id"), ("project_review_states", "project_id"), ("tag_commands", "id"), ("tag_domains", "asset_id")] {
        required[table] = [key, "data"]
      }
    }
    if found >= 6 { required["asset_color_labels"] = ["asset_id", "data"] }
    if found >= 7 {
      required["editing_works"] = ["id", "project_id", "asset_id", "data"]
      required["editing_versions"] = ["id", "work_id", "parent_id", "data"]
      required["editing_dispositions"] = ["version_id", "disposition"]
      required["processing_jobs"] = ["id", "work_id", "command_id", "data"]
      required["editing_commands"] = ["id", "fingerprint", "action", "data"]
      required["provider_profiles"] = ["id", "data"]
      required["archive_publications"] = ["id", "version_id", "data"]
      required["editing_exports"] = ["id", "work_id", "command_id", "data"]
    }
    // Only the known reverse membership index is additive across supported
    // versions; retain the strict rejection of all other unknown objects.
    let indexes = Set(try strings(db, "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'"))
    let editingIndexes: [String: (String, [String])] = found >= 7 ? [
      "editing_works_source": ("editing_works", ["project_id", "asset_id"]),
      "editing_versions_work": ("editing_versions", ["work_id"]),
      "processing_jobs_work": ("processing_jobs", ["work_id"]),
      "editing_exports_work": ("editing_exports", ["work_id"])
    ] : [:]
    let legacyIndexes = indexes.subtracting(owned)
    guard legacyIndexes.isSubset(of: Set(["membership_asset_id"]).union(editingIndexes.keys)),
      Set(editingIndexes.keys).isSubset(of: legacyIndexes),
      names == Set(required.keys), Set(userObjects).subtracting(owned) == Set(required.keys).union(legacyIndexes) else {
      throw LibraryError.invalid("资料库结构与版本不符，未修改原库")
    }
    if indexes.contains("membership_asset_id") {
      guard try strings(db, "SELECT tbl_name FROM sqlite_master WHERE type='index' AND name='membership_asset_id'") == ["membership"],
        try strings(db, "PRAGMA index_info(membership_asset_id)", column: 2) == ["asset_id"],
        try strings(db, "SELECT \"unique\" FROM pragma_index_list('membership') WHERE name='membership_asset_id'") == ["0"],
        try strings(db, "SELECT partial FROM pragma_index_list('membership') WHERE name='membership_asset_id'") == ["0"] else {
        throw LibraryError.invalid("资料库成员索引无法识别，未修改原库")
      }
    }
    for (name, definition) in editingIndexes {
      guard try strings(db, "SELECT tbl_name FROM sqlite_master WHERE type='index' AND name='\(name)'") == [definition.0],
        try strings(db, "PRAGMA index_info(\(name))", column: 2) == definition.1,
        try strings(db, "SELECT \"unique\" FROM pragma_index_list('\(definition.0)') WHERE name='\(name)'") == ["0"],
        try strings(db, "SELECT partial FROM pragma_index_list('\(definition.0)') WHERE name='\(name)'") == ["0"] else {
        throw LibraryError.invalid("资料库制作索引无法识别，未修改原库")
      }
    }
    for (table, expected) in required {
      guard Set(try strings(db, "PRAGMA table_info(\(table))", column: 1)) == expected else {
        throw LibraryError.invalid("资料库表 \(table) 无法识别，未修改原库")
      }
    }
    if found >= 7 {
      let primaryKeys = ["editing_works": "id", "editing_versions": "id", "editing_dispositions": "version_id",
                         "processing_jobs": "id", "editing_commands": "id", "provider_profiles": "id", "archive_publications": "id", "editing_exports": "id"]
      let nonNullColumns: [String: Set<String>] = [
        "editing_works": ["project_id", "asset_id", "data"], "editing_versions": ["work_id", "data"],
        "editing_dispositions": ["disposition"], "processing_jobs": ["work_id", "command_id", "data"],
        "editing_commands": ["fingerprint", "action", "data"], "provider_profiles": ["data"],
        "archive_publications": ["version_id", "data"], "editing_exports": ["work_id", "command_id", "data"]
      ]
      for (table, primary) in primaryKeys {
        guard Set(try strings(db, "SELECT name FROM pragma_table_info('\(table)') WHERE \"notnull\"=1")) == nonNullColumns[table],
          try strings(db, "SELECT name FROM pragma_table_info('\(table)') WHERE pk>0 ORDER BY pk") == [primary],
          try strings(db, "SELECT DISTINCT upper(type) FROM pragma_table_info('\(table)')") == ["TEXT"] else {
          throw LibraryError.invalid("资料库制作主键无法识别，未修改原库")
        }
      }
      for (table, primary) in primaryKeys {
        let uniqueIndexes = try strings(db, "SELECT name FROM pragma_index_list('\(table)') WHERE \"unique\"=1 ORDER BY origin,name")
        var actual: Set<String> = []
        for name in uniqueIndexes {
          let origin = try strings(db, "SELECT origin FROM pragma_index_list('\(table)') WHERE name='\(name)'").first ?? ""
          let keys = try strings(db, "PRAGMA index_info('\(name)')", column: 2)
          guard try strings(db, "SELECT partial FROM pragma_index_list('\(table)') WHERE name='\(name)'") == ["0"] else {
            throw LibraryError.invalid("资料库制作唯一约束无法识别，未修改原库")
          }
          actual.insert(origin + ":" + keys.joined(separator: ","))
        }
        var expected: Set<String> = ["pk:" + primary]
        if table == "processing_jobs" || table == "editing_exports" { expected.insert("u:command_id") }
        if table == "archive_publications" { expected.insert("u:version_id") }
        guard actual == expected, uniqueIndexes.count == expected.count else {
          throw LibraryError.invalid("资料库制作唯一约束无法识别，未修改原库")
        }
      }
    }
    return found
  }
  static func inspectAndBackup(_ url: URL, directory: URL?) throws -> (Int, URL?) {
    guard FileManager.default.fileExists(atPath: url.path) else { return (0, nil) }
    // Standalone WAL-format snapshots can fail ordinary read-only opens on system SQLite.
    // Immutable inspection is permitted only without a real WAL; hash guards reject concurrent changes.
    let walPath = url.path + "-wal"
    let header = try FileHandle(forReadingFrom: url)
    let prefix = try header.read(upToCount: 20) ?? Data()
    try header.close()
    let standaloneWAL =
      !FileManager.default.fileExists(atPath: walPath) && prefix.count == 20 && prefix[18] == 2
      && prefix[19] == 2
    let originalHash = standaloneWAL ? try FileSafety.hash(url) : nil
    let name = standaloneWAL ? url.absoluteString + "?immutable=1" : url.path
    var source: OpaquePointer?
    guard
      sqlite3_open_v2(
        name, &source,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (standaloneWAL ? SQLITE_OPEN_URI : 0), nil)
        == SQLITE_OK
    else {
      defer { sqlite3_close(source) }
      throw error(source)
    }
    defer { sqlite3_close(source) }
    sqlite3_busy_timeout(source, 5000)
    guard sqlite3_exec(source, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw error(source) }
    defer { sqlite3_exec(source, "ROLLBACK", nil, nil, nil) }
    func checkStandaloneSnapshot() throws {
      if let originalHash {
        guard !FileManager.default.fileExists(atPath: walPath),
          try FileSafety.hash(url) == originalHash
        else { throw LibraryError.invalid("资料库在只读检查期间变化，请关闭其他程序后重试") }
      }
    }
    let found = try validate(source)
    try checkStandaloneSnapshot()
    guard found > 0, found < version else { return (found, nil) }
    let folder =
      directory ?? url.deletingLastPathComponent().appendingPathComponent("Migration Backups")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let backupURL = folder.appendingPathComponent(
      url.lastPathComponent + ".v\(found)-" + UUID().uuidString + ".sqlite")
    var destination: OpaquePointer?
    guard
      sqlite3_open_v2(
        backupURL.path, &destination,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    else {
      defer { sqlite3_close(destination) }
      throw error(destination)
    }
    var complete = false
    defer {
      sqlite3_close(destination)
      for suffix in ["-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(atPath: backupURL.path + suffix)
      }
      if !complete { try? FileManager.default.removeItem(at: backupURL) }
    }
    guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
      throw error(destination)
    }
    let status = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard status == SQLITE_DONE, finish == SQLITE_OK else {
      throw LibraryError.database("一致备份失败，升级已中止")
    }
    // The snapshot is a standalone rollback-journal file, never dependent on sidecar WAL state.
    guard
      sqlite3_exec(
        destination, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", nil, nil, nil)
        == SQLITE_OK,
      try strings(destination, "PRAGMA quick_check") == ["ok"]
    else { throw LibraryError.database("备份完整性验证失败，升级已中止") }
    try checkStandaloneSnapshot()
    complete = true
    return (found, backupURL)
  }
}
