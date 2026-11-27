import CSQLite
import Foundation
import RAWMasterLibrary

/// One serialized connection: a state write and its operation record always commit together.
public final class LibraryStore: @unchecked Sendable {
  var db: OpaquePointer?
  let lock = NSRecursiveLock()
  public let databaseURL: URL
  var catalogInstalled = false
  private var writeDepth = 0
  let importLockDirectory: URL
  let encoder = JSONEncoder(), decoder = JSONDecoder()
  var deviceID = ""
  public private(set) var lastMigrationBackupURL: URL?
  public init(databaseURL: URL, migrationBackupDirectory: URL? = nil, requireExisting: Bool = false) throws {
    let canonicalDatabase = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
    self.databaseURL = canonicalDatabase
    importLockDirectory = canonicalDatabase.deletingLastPathComponent().appendingPathComponent("." + canonicalDatabase.lastPathComponent + ".imports", isDirectory: true)
    // Validate first, including active-WAL state. Unknown databases never enter a writer connection.
    let inspected = try DatabaseSchema.inspectAndBackup(
      databaseURL, directory: migrationBackupDirectory)
    if requireExisting, inspected.0 == 0 { throw LibraryError.invalid("资料库文件已移走或不存在。") }
    lastMigrationBackupURL = inspected.1
    let rehearsal: CatalogJSON?
    if inspected.0 == 7, let snapshot = inspected.1 {
      rehearsal = try LibraryEngine.shared().request("migrationPreview", at: snapshot, payload: LibraryEmpty(), as: CatalogJSON.self)
    } else { rehearsal = nil }
    if !requireExisting {
      try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (requireExisting ? 0 : SQLITE_OPEN_CREATE)
    guard
      sqlite3_open_v2(
        databaseURL.path, &db, flags,
        nil) == SQLITE_OK
    else {
      sqlite3_close(db)
      db = nil
      throw LibraryError.database("无法打开资料库")
    }
    sqlite3_busy_timeout(db, 5000)
    do {
      // The catalog is a single hot file for browsing, editing and export. The SQLite default
      // page cache is 2 MiB, which turns large facet scans into repeated reads.
      try exec("PRAGMA cache_size=-262144")
      try exec("PRAGMA temp_store=MEMORY")
      try exec("PRAGMA foreign_keys=ON")
      if inspected.0 == DatabaseSchema.version {
        let needsReplay = try withReadSnapshot {
          guard try DatabaseSchema.validate(db) == inspected.0 else { throw LibraryError.invalid("资料库版本已变化，请重新打开") }
          return try rows("SELECT 1 WHERE EXISTS(SELECT 1 FROM lc_pair_dirty) OR EXISTS(SELECT 1 FROM lc_group_dirty)").isEmpty == false
        }
        catalogInstalled = true
        if needsReplay { try transaction {} }
      } else {
        try transaction {
          let found = try DatabaseSchema.validate(db)
          guard found == inspected.0 else { throw LibraryError.invalid("资料库在检查后被另一进程升级，请重新打开") }
          if let rehearsal { _ = try catalogTransaction("migrationCheck", rehearsal) }
          if found == 0 { try createSchema() }
          if found == 1 { try migrateVersionOne() }
          if found == 1 || found == 2 { try createGroupCommandSchema() }
          if found < 4 { try createTriageSchema() }
          if found < 5 { try createProjectReviewSchema() }
          if found < 6 { try createColorLabelSchema() }
          if found < 7 { try createEditingSchema() }
          if found < 8 {
            _ = try catalogTransaction("install", LibraryEmpty())
            try exec("PRAGMA user_version=8")
            guard try DatabaseSchema.validate(db) == 8, try rows("PRAGMA foreign_key_check").isEmpty else {
              throw LibraryError.database("资料库升级未通过一致性校验")
            }
            if let rehearsal {
              try statement("INSERT OR REPLACE INTO metadata(key,value) VALUES('libraryMigration.v8',?)", [try json(rehearsal)])
            }
          }
          _ = try catalogTransaction("upgradeScheduler", LibraryEmpty())
          guard try DatabaseSchema.validate(db) == DatabaseSchema.version, try rows("PRAGMA foreign_key_check").isEmpty else {
            throw LibraryError.database("资料库升级未通过一致性校验")
          }
          catalogInstalled = true
        }
      }
      if try rows("PRAGMA journal_mode").first?.first != "wal" { try exec("PRAGMA journal_mode=WAL") }
      try exec("PRAGMA synchronous=FULL")
      // The primary membership key starts with group_id. Asset edits and membership
      // projection also need the reverse lookup, including in existing catalogues.
      if try rows("SELECT 1 FROM sqlite_schema WHERE type='index' AND name='membership_asset_id'").isEmpty {
        try exec("CREATE INDEX IF NOT EXISTS membership_asset_id ON membership(asset_id)")
      }
      if let existing = try rows("SELECT value FROM metadata WHERE key='deviceID'").first?.first {
        deviceID = existing
      } else {
        try transaction {
          try statement("INSERT OR IGNORE INTO metadata VALUES('deviceID',?)", [UUID().uuidString])
          guard let id = try rows("SELECT value FROM metadata WHERE key='deviceID'").first?.first else {
            throw LibraryError.database("无法读取设备身份")
          }
          deviceID = id
        }
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
      if writeDepth > 0 {
        let name = "rm_nested_" + String(writeDepth)
        try exec("SAVEPOINT " + name)
        writeDepth += 1
        defer { writeDepth -= 1 }
        do {
          let value = try body()
          try exec("RELEASE " + name)
          return value
        } catch {
          try? exec("ROLLBACK TO " + name)
          try? exec("RELEASE " + name)
          throw error
        }
      }
      try exec("BEGIN IMMEDIATE")
      writeDepth = 1
      defer { writeDepth = 0 }
      do {
        let result = try body()
        if catalogInstalled { _ = try catalogTransaction("flushLegacy", LibraryEmpty()) }
        try exec("COMMIT")
        return result
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
    }
  }
  /// A consistent catalogue view across several public read methods. The body
  /// must only read; nested snapshots reuse the caller's existing transaction.
  public func withReadSnapshot<T>(_ body: () throws -> T) throws -> T {
    try locked {
      if sqlite3_get_autocommit(db) == 0 { return try body() }
      try exec("BEGIN DEFERRED")
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
      try rows(catalogInstalled ? "SELECT s.data FROM sessions s WHERE NOT EXISTS(SELECT 1 FROM lc_sessions x WHERE x.session_id=s.id AND x.origin='version-host') ORDER BY s.rowid" : "SELECT data FROM sessions ORDER BY rowid").map {
        try decode($0[0], ImportSession.self)
      }
    }
  }
  public func loadAssets(sessionID: String? = nil) throws -> [AssetRecord] {
    try locked {
      let data = try rows(
        "SELECT data FROM assets" + (sessionID == nil ? "" : " WHERE session_id=?")
          + " ORDER BY rowid", sessionID.map { [$0] } ?? [])
      // One ordered projection replaces a query (and table scan) for every photo.
      // Keep the legacy first-membership-by-rowid and any-included semantics.
      let memberships = try rows(
        "SELECT m.asset_id,m.group_id,m.position,m.included FROM membership m"
          + (sessionID == nil ? "" : " JOIN assets a ON a.id=m.asset_id WHERE a.session_id=?")
          + " ORDER BY m.rowid", sessionID.map { [$0] } ?? [])
      var first: [String: (groupID: String, position: Int?)] = [:]
      var included = Set<String>()
      for member in memberships {
        if first[member[0]] == nil { first[member[0]] = (member[1], Int(member[2])) }
        if member[3] == "1" { included.insert(member[0]) }
      }
      return try data.map { row in
        var a = try decode(row[0], AssetRecord.self)
        a.groupID = first[a.id]?.groupID
        a.sequenceIndex = first[a.id]?.position
        a.isSequenceMember = included.contains(a.id)
        return a
      }
    }
  }
  public func loadGroups(projectID: String? = nil) throws -> [CaptureGroup] {
    try locked {
      let arguments = projectID.map { [$0] } ?? []
      let condition = projectID == nil ? "" : " WHERE g.project_id=?"
      let records = try rows("SELECT g.data FROM groups_data g" + condition + " ORDER BY g.rowid", arguments)
      let membership = try rows("SELECT m.group_id,m.asset_id,m.included FROM membership m JOIN groups_data g ON g.id=m.group_id" + condition + " ORDER BY m.group_id,m.position,m.rowid", arguments)
      let byGroup = Dictionary(grouping: membership, by: { $0[0] })
      return try records.map { row in
        var group = try decode(row[0], CaptureGroup.self)
        let members = byGroup[group.id] ?? []
        group.assetIDs = members.map { $0[1] }
        group.includedAssetIDs = members.filter { $0[2] == "1" }.map { $0[1] }
        return group
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
  public func updateSelection(ids: [String], decision: Decision?, rating: Int?, markReviewed: Bool = false) throws
    -> [SelectionChange]
  {
    if let rating, !(0...5).contains(rating) { throw LibraryError.invalid("星级必须为 0–5") }
    return try transaction {
      if markReviewed && (decision != nil || rating != nil) {
        try writeReview(assertAdmitted(ids), reviewed: true)
      }
      return try Array(Set(ids)).sorted().compactMap { id in
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
      try assertSessionWritable(s.id)
      try statement(
        "INSERT INTO sessions VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
        [s.id, try json(s)])
    }
  }
  func register(_ a: AssetRecord) throws -> AssetRecord {
    try transaction { try registerInTransaction(a) }
  }
  /// Discovery has no file I/O here; a bounded batch shares one durable commit.
  func registerDiscovered(_ records: [AssetRecord]) throws {
    guard records.count <= 64 else { throw LibraryError.invalid("发现批次超出预算") }
    guard !records.isEmpty else { return }
    try transaction {
      for record in records { _ = try registerInTransaction(record) }
    }
  }
  private func registerInTransaction(_ a: AssetRecord) throws -> AssetRecord {
    try assertSessionWritable(a.sessionID)
    if let existing = try rows(
      "SELECT data FROM assets WHERE session_id=? AND source_path=?", [a.sessionID, a.sourcePath]
    ).first {
      return try decode(existing[0], AssetRecord.self)
    }
    try statement(
      "INSERT INTO assets(id,session_id,source_path,data) VALUES(?,?,?,?)",
      [a.id, a.sessionID, a.sourcePath, try json(a)])
    try operation(entity: a.id, action: "discover", payload: try json(a), base: 0, result: 0)
    if try workflow(a.sessionID) == nil || workflow(a.sessionID)?.phase == .legacyHistory {
      try writeAdmission(ProjectAdmission(assetID: a.id, projectID: a.projectID))
    }
    return a
  }
  func saveImportAsset(
    _ imported: AssetRecord, expectedSourceFingerprint: String? = nil,
    expectedManagedFingerprint: String? = nil, session: ImportSession? = nil
  ) throws {
    try transaction {
      var a = try asset(imported.id)
      try assertSessionWritable(a.sessionID)
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
      try bindVerifiedImportOccurrence(a)
      if let session {
        guard session.id == a.sessionID else { throw LibraryError.invalid("导入进度与素材会话不一致") }
        try statement(
          "INSERT INTO sessions VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
          [session.id, try json(session)])
      }
    }
  }
}
