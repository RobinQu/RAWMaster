import CSQLite
import Foundation

/// One serialized connection: a state write and its operation record always commit together.
public final class LibraryStore: @unchecked Sendable {
  var db: OpaquePointer?
  let lock = NSRecursiveLock()
  let encoder = JSONEncoder(), decoder = JSONDecoder()
  var deviceID = ""
  public private(set) var lastMigrationBackupURL: URL?
  public init(databaseURL: URL, migrationBackupDirectory: URL? = nil) throws {
    // Validate first, including active-WAL state. Unknown databases never enter a writer connection.
    let inspected = try DatabaseSchema.inspectAndBackup(
      databaseURL, directory: migrationBackupDirectory)
    lastMigrationBackupURL = inspected.1
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
      sqlite3_open_v2(
        databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        nil) == SQLITE_OK
    else { throw LibraryError.database("无法打开资料库") }
    sqlite3_busy_timeout(db, 5000)
    do {
      try transaction {
        let found = try DatabaseSchema.validate(db)
        guard found == inspected.0 else { throw LibraryError.invalid("资料库在检查后被另一进程升级，请重新打开") }
        if found == 0 { try createSchema() }
        if found == 1 { try migrateVersionOne() }
        if found == 1 || found == 2 { try createGroupCommandSchema() }
      }
      try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;")
      if let existing = try rows("SELECT value FROM metadata WHERE key='deviceID'").first?.first {
        deviceID = existing
      } else {
        deviceID = UUID().uuidString
        try statement("INSERT INTO metadata VALUES('deviceID',?)", [deviceID])
      }
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }
  private func createSchema() throws {
    try exec(
      """
      CREATE TABLE projects(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE sessions(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE assets(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, source_path TEXT NOT NULL, data TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, UNIQUE(session_id, source_path));
      CREATE TABLE groups_data(id TEXT PRIMARY KEY, project_id TEXT NOT NULL, data TEXT NOT NULL);
      CREATE TABLE membership(group_id TEXT NOT NULL REFERENCES groups_data(id) ON DELETE CASCADE, asset_id TEXT NOT NULL REFERENCES assets(id), position INTEGER NOT NULL, included INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(group_id, asset_id));
      CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE operations(id TEXT PRIMARY KEY, device_id TEXT NOT NULL, entity_id TEXT NOT NULL, base_revision INTEGER NOT NULL, resulting_revision INTEGER NOT NULL, payload_version INTEGER NOT NULL, action TEXT NOT NULL, payload TEXT NOT NULL, timestamp REAL NOT NULL);
      CREATE TABLE relocation_sessions(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      PRAGMA user_version=2;
      """)
    try createGroupCommandSchema()
  }
  private func migrateVersionOne() throws {
    try exec("CREATE TABLE relocation_sessions(id TEXT PRIMARY KEY, data TEXT NOT NULL)")
    let sessions = try loadSessions()
    let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    for var session in sessions {
      session.effectiveSourceRoot = session.sourcePath
      session.effectiveManagedRoot = session.destinationPath
      try statement("UPDATE sessions SET data=? WHERE id=?", [try json(session), session.id])
    }
    for var a in try loadAssets() {
      a.effectiveSourcePath = a.sourcePath
      if byID[a.sessionID]?.mode == .copy
        && (a.currentPath != a.sourcePath || (a.importState == .ready && a.contentHash != nil))
      {
        a.effectiveManagedPath = a.currentPath
      }
      try statement("UPDATE assets SET data=? WHERE id=?", [try json(a), a.id])
    }
    for var g in try loadGroups() {
      g.origin = .manual
      g.locked = true
      g.groupRevision = 0
      try statement("UPDATE groups_data SET data=? WHERE id=?", [try json(g), g.id])
    }
    try exec("PRAGMA user_version=2")
  }
  deinit { sqlite3_close(db) }
  func locked<T>(_ work: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try work()
  }
  func exec(_ sql: String) throws {
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw failure() }
  }
  func failure() -> LibraryError { .database(String(cString: sqlite3_errmsg(db))) }
  func statement(_ sql: String, _ values: [String] = []) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
    defer { sqlite3_finalize(stmt) }
    for (i, v) in values.enumerated() {
      sqlite3_bind_text(
        stmt, Int32(i + 1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
  }
  func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
    defer { sqlite3_finalize(stmt) }
    for (i, v) in values.enumerated() {
      sqlite3_bind_text(
        stmt, Int32(i + 1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    var result: [[String]] = []
    var status = sqlite3_step(stmt)
    while status == SQLITE_ROW {
      result.append(
        (0..<sqlite3_column_count(stmt)).map {
          sqlite3_column_text(stmt, $0).map { String(cString: $0) } ?? ""
        })
      status = sqlite3_step(stmt)
    }
    guard status == SQLITE_DONE else { throw failure() }
    return result
  }
  func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  func decode<T: Decodable>(_ s: String, _ type: T.Type) throws -> T {
    try decoder.decode(type, from: Data(s.utf8))
  }
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try locked {
      try exec("BEGIN IMMEDIATE")
      do {
        let result = try body()
        try exec("COMMIT")
        return result
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
    }
  }
  func operation(
    entity: String, action: String, payload: String, base: Int = -1, result: Int = -1
  ) throws {
    let prior =
      base >= 0
      ? base
      : (Int(
        try rows(
          "SELECT COALESCE(MAX(resulting_revision),0) FROM operations WHERE entity_id=?", [entity]
        ).first?.first ?? "0") ?? 0)
    let next = result >= 0 ? result : prior + 1
    try statement(
      "INSERT INTO operations VALUES(?,?,?,?,?,1,?,?,?)",
      [
        UUID().uuidString, deviceID, entity, String(prior), String(next), action, payload,
        String(Date().timeIntervalSince1970),
      ])
  }
  public func loadProjects() throws -> [ProjectRecord] {
    try locked {
      try rows("SELECT data FROM projects ORDER BY rowid").map {
        try decode($0[0], ProjectRecord.self)
      }
    }
  }
  public func loadSessions() throws -> [ImportSession] {
    try locked {
      try rows("SELECT data FROM sessions ORDER BY rowid").map {
        try decode($0[0], ImportSession.self)
      }
    }
  }
  public func loadAssets(sessionID: String? = nil) throws -> [AssetRecord] {
    try locked {
      let data = try rows(
        "SELECT data FROM assets" + (sessionID == nil ? "" : " WHERE session_id=?")
          + " ORDER BY rowid", sessionID.map { [$0] } ?? [])
      return try data.map { row in
        var a = try decode(row[0], AssetRecord.self)
        let members = try rows(
          "SELECT group_id,position,included FROM membership WHERE asset_id=? ORDER BY rowid",
          [a.id])
        a.groupID = members.first?.first
        a.sequenceIndex = members.first.flatMap { Int($0[1]) }
        a.isSequenceMember = members.contains { $0[2] == "1" }
        return a
      }
    }
  }
  public func loadGroups(projectID: String? = nil) throws -> [CaptureGroup] {
    try locked {
      try rows(
        "SELECT data FROM groups_data" + (projectID == nil ? "" : " WHERE project_id=?")
          + " ORDER BY rowid", projectID.map { [$0] } ?? []
      ).map { row in
        var g = try decode(row[0], CaptureGroup.self)
        let members = try rows(
          "SELECT asset_id,included FROM membership WHERE group_id=? ORDER BY position,rowid",
          [g.id])
        g.assetIDs = members.map { $0[0] }
        g.includedAssetIDs = members.filter { $0[1] == "1" }.map { $0[0] }
        return g
      }
    }
  }
  func asset(_ id: String) throws -> AssetRecord {
    guard let row = try rows("SELECT data FROM assets WHERE id=?", [id]).first else {
      throw LibraryError.invalid("素材不存在：\(id)")
    }
    return try decode(row[0], AssetRecord.self)
  }
  func changeAsset(_ a: AssetRecord, action: String) throws {
    let base =
      Int(try rows("SELECT revision FROM assets WHERE id=?", [a.id]).first?.first ?? "0") ?? 0
    struct Member: Codable {
      var groupID: String
      var position: Int
      var included: Bool
    }
    struct Snapshot: Codable {
      var asset: AssetRecord
      var memberships: [Member]
    }
    let memberships = try rows(
      "SELECT group_id,position,included FROM membership WHERE asset_id=? ORDER BY rowid", [a.id]
    ).map { Member(groupID: $0[0], position: Int($0[1]) ?? 0, included: $0[2] == "1") }
    var current = a
    current.groupID = memberships.first?.groupID
    current.sequenceIndex = memberships.first?.position
    current.isSequenceMember = memberships.contains { $0.included }
    try statement(
      "UPDATE assets SET data=?,revision=? WHERE id=?", [try json(current), String(base + 1), a.id])
    try operation(
      entity: a.id, action: action,
      payload: try json(Snapshot(asset: current, memberships: memberships)), base: base,
      result: base + 1)
  }
  public func updateSelection(ids: [String], decision: Decision?, rating: Int?) throws
    -> [SelectionChange]
  {
    if let rating, !(0...5).contains(rating) { throw LibraryError.invalid("星级必须为 0–5") }
    return try transaction {
      try Array(Set(ids)).sorted().compactMap { id in
        var a = try asset(id)
        let c = SelectionChange(
          assetID: id, oldDecision: a.decision, newDecision: decision ?? a.decision,
          oldRating: a.rating, newRating: rating ?? a.rating)
        guard c.oldDecision != c.newDecision || c.oldRating != c.newRating else { return nil }
        a.decision = c.newDecision
        a.rating = c.newRating
        try changeAsset(a, action: "selection")
        return c
      }
    }
  }
  public func undoSelection(_ changes: [SelectionChange]) throws {
    try transaction {
      for c in changes {
        var a = try asset(c.assetID)
        guard a.decision == c.newDecision && a.rating == c.newRating else {
          throw LibraryError.invalid("素材已再次修改，无法撤销旧决定")
        }
        a.decision = c.oldDecision
        a.rating = c.oldRating
        try changeAsset(a, action: "undoSelection")
      }
    }
  }
  public func createGroup(ids: [String], name: String, kind: String) throws {
    _ = try commitGroupCommand(previewGroupCommand(.create(assetIDs: ids, name: name, kind: kind)))
  }
  public func renameGroup(id: String, name: String) throws {
    _ = try commitGroupCommand(previewGroupCommand(.rename(groupID: id, name: name)))
  }
  public func removeFromGroup(ids: [String], groupID: String) throws {
    _ = try commitGroupCommand(previewGroupCommand(.removeMembers(groupID: groupID, assetIDs: ids)))
  }
  public func mergeGroups(ids: [String], name: String) throws {
    let groups = try loadGroups()
    guard let first = ids.first, let g = groups.first(where: { $0.id == first }) else {
      throw LibraryError.invalid("拍摄组不存在")
    }
    _ = try commitGroupCommand(previewGroupCommand(.merge(groupIDs: ids, name: name, kind: g.kind)))
  }
  public func reorderGroup(groupID: String, assetIDs: [String]) throws {
    _ = try commitGroupCommand(previewGroupCommand(.reorder(groupID: groupID, assetIDs: assetIDs)))
  }
  public func setSequenceMembership(ids: [String], included: Bool, groupID: String? = nil) throws {
    try locked {
      let groups: [String]
      if let groupID {
        groups = [groupID]
      } else {
        groups = try loadGroups().filter { !Set($0.assetIDs).isDisjoint(with: ids) }.map(\.id)
      }
      _ = try commitGroupCommand(
        previewGroupCommand(.setParticipation(groupIDs: groups, assetIDs: ids, included: included)))
    }
  }
  public func refreshAvailability(ids: [String]? = nil) throws {
    // Hashing happens outside the SQLite lock. Re-read each record before its short commit.
    let assets = try loadAssets().filter { ids == nil || ids!.contains($0.id) }
    for original in assets {
      let availability: AssetAvailability
      if !FileManager.default.fileExists(atPath: original.currentPath) {
        availability = .missing
      } else if let hash = original.contentHash {
        availability =
          ((try? FileSafety.hash(original.resolvedURL)) == hash) ? .available : .changed
      } else {
        availability =
          ((try? FileSafety.stat(original.resolvedURL).size) == original.fileSize)
          ? .available : .changed
      }
      try transaction {
        var current = try asset(original.id)
        if current.currentPath == original.currentPath
          && current.contentHash == original.contentHash
        {
          current.availability = availability
          try changeAsset(current, action: "availability")
        }
      }
    }
  }
  // Services update only import-owned fields, preserving concurrent human edits.
  func saveProject(_ p: ProjectRecord) throws {
    try transaction {
      try statement("INSERT OR IGNORE INTO projects VALUES(?,?)", [p.id, try json(p)])
    }
  }
  func saveSession(_ s: ImportSession) throws {
    try transaction {
      try statement(
        "INSERT INTO sessions VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
        [s.id, try json(s)])
    }
  }
  func register(_ a: AssetRecord) throws -> AssetRecord {
    try transaction {
      if let existing = try rows(
        "SELECT data FROM assets WHERE session_id=? AND source_path=?", [a.sessionID, a.sourcePath]
      ).first {
        return try decode(existing[0], AssetRecord.self)
      }
      try statement(
        "INSERT INTO assets(id,session_id,source_path,data) VALUES(?,?,?,?)",
        [a.id, a.sessionID, a.sourcePath, try json(a)])
      try operation(entity: a.id, action: "discover", payload: try json(a), result: 0)
      return a
    }
  }
  func saveImportAsset(
    _ imported: AssetRecord, expectedSourceFingerprint: String? = nil,
    expectedManagedFingerprint: String? = nil
  ) throws {
    try transaction {
      var a = try asset(imported.id)
      if let expectedSourceFingerprint {
        guard LocationIdentity.fingerprint(a, role: .source) == expectedSourceFingerprint else {
          throw LibraryError.invalid("来源位置在导入期间改变，请重试")
        }
      }
      if let expectedManagedFingerprint {
        guard LocationIdentity.fingerprint(a, role: .managed) == expectedManagedFingerprint else {
          throw LibraryError.invalid("受管位置在导入期间改变，请重试")
        }
      }
      a.effectiveSourcePath = imported.effectiveSourcePath
      a.effectiveManagedPath = imported.effectiveManagedPath
      a.currentPath = imported.currentPath
      a.fileSize = imported.fileSize
      a.capturedAt = imported.capturedAt
      a.camera = imported.camera
      a.width = imported.width
      a.height = imported.height
      a.contentHash = imported.contentHash
      a.availability = imported.availability
      a.importState = imported.importState
      a.error = imported.error
      try changeAsset(a, action: "importState")
    }
  }
}
