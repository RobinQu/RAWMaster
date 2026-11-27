import CSQLite
import Foundation
import RAWMasterLibrary

public enum LocalLibraryTaskKind: String, Sendable {
  case importSession, flux, sceneWorkflow, relocation, renderedExport

  var historyPrefix: String { "localPackage.historicalTask.v1/\(rawValue)/" }
}

extension LibraryStore {
  public func isHistoricalTask(_ kind: LocalLibraryTaskKind, id: String) throws -> Bool {
    try locked { try !rows("SELECT 1 FROM metadata WHERE key=?", [kind.historyPrefix + id]).isEmpty }
  }

  public func requireLocalTask(_ kind: LocalLibraryTaskKind, id: String) throws {
    guard try !isHistoricalTask(kind, id: id) else {
      throw LibraryError.invalid("此任务属于原资料库。可在此查阅记录，请新建任务继续处理。")
    }
  }

  static func snapshotLocalPackage(from source: URL, to destination: URL) throws {
    var input: OpaquePointer?, output: OpaquePointer?
    defer { sqlite3_close(output); sqlite3_close(input) }
    let wal = FileManager.default.fileExists(atPath: source.path + "-wal")
    let name = wal ? source.path : source.absoluteString + "?immutable=1"
    let sourceFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (wal ? 0 : SQLITE_OPEN_URI)
    guard sqlite3_open_v2(name, &input, sourceFlags, nil) == SQLITE_OK else { throw DatabaseSchema.error(input) }
    sqlite3_busy_timeout(input, 5_000)
    guard try DatabaseSchema.validate(input) > 0 else { throw LibraryError.invalid("无法迁移空目录。") }
    guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let backup = sqlite3_backup_init(output, "main", input, "main") else { throw DatabaseSchema.error(output) }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK,
      sqlite3_exec(output, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK,
      try DatabaseSchema.strings(output, "PRAGMA quick_check") == ["ok"] else {
      throw LibraryError.database("资料库快照未通过完整性校验。")
    }
  }

  func prepareLocalPackage(root: URL, physicalIdentity: String, previousRoot: URL?, disposition: LocalLibraryDisposition,
                           packageFilesAt: URL, requireExistingResources: Bool = false) throws -> LibraryPackageBinding {
    let (binding, writer): (LibraryPackageBinding, String?) = try transaction {
      let oldID = try catalogLibraryIdentity()
      let old = try rows("SELECT value FROM metadata WHERE key=?", [LibraryPackageBinding.metadataKey]).first
        .map { try decode($0[0], LibraryPackageBinding.self) }
      let changedPhysicalPackage = old.map { $0.physicalIdentity != physicalIdentity }
        ?? previousRoot.map { $0.path != root.path } ?? false
      let verifyTransfer = disposition == .independentCopy || changedPhysicalPackage
      if verifyTransfer {
        guard try rows("PRAGMA quick_check") == [["ok"]] else { throw LibraryError.invalid("资料库副本或新卷未通过完整性验证。") }
      }
      if let previousRoot, previousRoot.path != root.path || old?.physicalIdentity != physicalIdentity {
        try rebasePackagePaths(from: previousRoot, to: root, filesAt: packageFilesAt,
          requireExistingResources: requireExistingResources || packageFilesAt.path != root.path)
      }
      if verifyTransfer { try verifyTransferredResources(root: root, filesAt: packageFilesAt) }
      let id: String, writer: String?
      switch disposition {
      case .keepIdentity:
        id = oldID; writer = nil
      case .independentCopy:
        if let archive = try rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first,
          !FileSafety.contains(root, URL(fileURLWithPath: archive, isDirectory: true)) {
          throw LibraryError.invalid("编辑资源位于库包外。请先迁移编辑资源或从完整备份恢复，再创建独立资料库。")
        }
        id = UUID().uuidString.lowercased()
        try markHistoricalTasks()
        let detached = try catalogTransaction("detachLocalCopy", ["libraryID": id])
        writer = detached["writerID"]?.stringValue
        guard writer?.isEmpty == false else { throw LibraryError.invalid("无法登记副本的独立写入身份。") }
      }
      let binding = LibraryPackageBinding(libraryID: id, database: databaseURL.lastPathComponent, root: root.path,
        physicalIdentity: physicalIdentity, previousLibraryID: disposition == .independentCopy ? oldID : old?.previousLibraryID)
      try statement("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [LibraryPackageBinding.metadataKey, try json(binding)])
      return (binding, writer)
    }
    if let writer { locked { deviceID = writer } }
    return binding
  }

  private func markHistoricalTasks() throws {
    for (kind, source) in [
      (LocalLibraryTaskKind.importSession, "SELECT id FROM sessions"),
      (.flux, "SELECT id FROM processing_jobs"),
      (.sceneWorkflow, "SELECT json_extract(data,'$.id') AS id FROM editing_commands WHERE action='sceneWorkflowBatch.v1'"),
      (.relocation, "SELECT id FROM relocation_sessions"),
      (.renderedExport, "SELECT id FROM editing_exports"),
    ] {
      try statement("INSERT OR IGNORE INTO metadata(key,value) SELECT ?||id,'1' FROM (\(source)) WHERE id IS NOT NULL", [kind.historyPrefix])
    }
  }

  /// Inspect named files and their expected sizes. Finder transfers avoid rereading all
  /// media bytes; migration and restore also hash their own materialized copies.
  private func verifyTransferredResources(root: URL, filesAt actual: URL) throws {
    let prefix = root.path + "/"
    func verifyFile(_ file: URL, within boundary: URL, relative: String, byteCount: String) throws {
      guard FileSafety.contains(boundary, file), let expected = Int64(byteCount),
        (try? FileSafety.stat(file).size) == expected else {
        throw LibraryError.invalid("找不到完整的资料库资源：\(relative)。请接回原卷或从完整副本恢复。")
      }
    }

    let resources = actual.appendingPathComponent("LibraryResources", isDirectory: true)
    for row in try rows("SELECT DISTINCT relative_path,byte_count FROM lc_resources") {
      let relative = try FileSafety.safeRelative(row[0])
      try verifyFile(resources.appendingPathComponent(relative), within: actual, relative: relative, byteCount: row[1])
    }
    if let archive = try rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first,
      archive == root.path || archive.hasPrefix(prefix) {
      let localArchive = archive == root.path ? actual
        : actual.appendingPathComponent(try FileSafety.safeRelative(String(archive.dropFirst(prefix.count))), isDirectory: true)
      guard FileSafety.contains(actual, localArchive),
        (try? localArchive.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw LibraryError.invalid("资料库缺少编辑资源目录。请从原库或完整备份恢复编辑资源。")
      }
      for row in try rows("""
        SELECT DISTINCT json_extract(data,'$.artifact.relativePath'),json_extract(data,'$.artifact.byteCount')
        FROM editing_versions WHERE json_type(data,'$.artifact')='object'
        """) {
        let relative = try FileSafety.safeRelative(row[0])
        let file = localArchive.appendingPathComponent(relative)
        try verifyFile(file, within: localArchive, relative: relative, byteCount: row[1])
      }
    }
    for row in try rows("""
      SELECT DISTINCT r.path,c.byte_count FROM lc_replicas r JOIN lc_contents c ON c.content_id=r.content_id
      WHERE r.kind IN ('managed','restored') AND r.state='available' AND instr(r.path,?)=1
      """, [prefix]) {
      let relative = try FileSafety.safeRelative(String(row[0].dropFirst(prefix.count)))
      try verifyFile(actual.appendingPathComponent(relative), within: actual, relative: relative, byteCount: row[1])
    }
  }

  /// These fields are the live path projection. Frozen task payloads and receipt fingerprints stay intact.
  private func rebasePackagePaths(from previous: URL, to target: URL, filesAt source: URL,
                                  requireExistingResources: Bool) throws {
    let old = previous.standardizedFileURL.path
    guard old != "/" else { throw LibraryError.invalid("资料库记录的位置无效。") }
    let prefix = old + "/"
    let volume = try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    var translated = [String: String]()
    func relative(_ path: String) throws -> String? {
      if path == old { return "" }
      guard path.hasPrefix(prefix) else { return nil }
      return try FileSafety.safeRelative(String(path.dropFirst(prefix.count)))
    }
    func translate(_ path: String) throws -> String? {
      if let known = translated[path] { return known }
      guard let fragment = try relative(path) else { return nil }
      if fragment.isEmpty { return target.path }
      let actual = source.appendingPathComponent(fragment)
      guard FileSafety.contains(source, actual) else {
        throw LibraryError.invalid("资料库中的文件指向包外：\(fragment)。请从原库恢复此资源。")
      }
      if requireExistingResources, !FileManager.default.fileExists(atPath: actual.path) { return nil }
      let new = target.appendingPathComponent(fragment).path
      translated[path] = new
      return new
    }

    func rewrite(_ table: String, id: String, field: String, keys: [String]) throws {
      let expressions = keys.map { "json_extract(\(field),'$.\($0)')" }
      let matching = expressions.map { "(\($0)=?1 OR instr(\($0),?2)=1)" }.joined(separator: " OR ")
      let values = try rows("SELECT \(id),\(expressions.joined(separator: ",")) FROM \(table) WHERE \(matching)", [old, prefix])
      for row in values {
        var updates = [String](), bindings = [String]()
        for (key, path) in zip(keys, row.dropFirst()) {
          if let new = try translate(path), new != path {
            updates.append("'$.\(key)',?"); bindings.append(new)
          }
        }
        if !updates.isEmpty {
          try statement("UPDATE \(table) SET \(field)=json_set(\(field),\(updates.joined(separator: ","))) WHERE \(id)=?", bindings + [row[0]])
        }
      }
    }

    let ownedSessionRoots = try rows("""
      WITH roots AS (
        SELECT id, coalesce(json_extract(data,'$.effectiveSourceRoot'),json_extract(data,'$.sourcePath')) AS intake,
          coalesce(json_extract(data,'$.effectiveManagedRoot'),json_extract(data,'$.destinationPath')) AS managed FROM sessions
      ) SELECT id,intake,managed FROM roots WHERE intake=?1 OR instr(intake,?2)=1 OR managed=?1 OR instr(managed,?2)=1
      """, [old, prefix])
    try rewrite("sessions", id: "id", field: "data", keys: ["sourcePath", "destinationPath", "effectiveSourceRoot", "effectiveManagedRoot"])
    for row in ownedSessionRoots {
      for (field, path) in [("sourceDirectoryIdentity", row[1]), ("managedDirectoryIdentity", row[2])] {
        guard let fragment = try relative(path), try translate(path) != nil else { continue }
        let actual = fragment.isEmpty ? source : source.appendingPathComponent(fragment, isDirectory: true)
        if let identity = try? LocalDirectoryIdentity(actual) {
          try statement("UPDATE sessions SET data=json_set(data,'$.\(field)',json(?)) WHERE id=?", [try json(identity), row[0]])
        }
      }
    }
    for row in try rows("SELECT id,source_path FROM assets WHERE instr(source_path,?)=1", [prefix]) {
      if let new = try translate(row[1]), new != row[1] { try statement("UPDATE assets SET source_path=? WHERE id=?", [new, row[0]]) }
    }
    try rewrite("assets", id: "id", field: "data", keys: ["sourcePath", "currentPath", "effectiveSourcePath", "effectiveManagedPath"])
    for row in try rows("SELECT replica_id,path FROM lc_replicas WHERE instr(path,?)=1", [prefix]) {
      if let new = try translate(row[1]), new != row[1] { try statement("UPDATE lc_replicas SET path=? WHERE replica_id=?", [new, row[0]]) }
    }
    for row in try rows("SELECT root_id,local_path FROM lc_roots WHERE local_path=? OR instr(local_path,?)=1", [old, prefix]) {
      if let new = try translate(row[1]) {
        try statement("UPDATE lc_roots SET local_path=?,volume_id=nullif(?,'') WHERE root_id=?", [new, volume ?? "", row[0]])
      }
    }
    if let path = try rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first,
      let new = try translate(path), new != path {
      try statement("UPDATE metadata SET value=? WHERE key='editingArchiveRoot'", [new])
    }
  }

  func copyLocalPackageResources(from actual: URL, recordedAt recorded: URL, to stage: URL, finalRoot: URL) throws {
    let fh = FileManager.default
    let prefix = recorded.path + "/"
    let archive = try rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first
    let owned = try rows("SELECT DISTINCT path,state FROM lc_replicas WHERE kind IN ('managed','restored') AND instr(path,?)=1", [prefix])
    let standard = ["EditingArchive", "Editing Archive", "LibraryResources", "Originals", "CatalogStorage"].map { recorded.appendingPathComponent($0).path }
    let registeredResources = try rows("SELECT relative_path,sha256,byte_count FROM lc_resources")
    var required = Set(owned.filter { $0[1] == "available" }.map { $0[0] })
    if let archive, archive.hasPrefix(prefix) { required.insert(archive) }
    for row in registeredResources {
      let path = try FileSafety.safeRelative(row[0])
      required.insert(recorded.appendingPathComponent("LibraryResources").appendingPathComponent(path).path)
    }
    let resources = Set(standard + (archive.map { [$0] } ?? []) + owned.map { $0[0] }).union(required).sorted()
    var copied = Set<String>()
    for path in resources where path.hasPrefix(prefix) {
      try Task.checkCancellation()
      let relative = try FileSafety.safeRelative(String(path.dropFirst(prefix.count)))
      if copied.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
      let source = actual.appendingPathComponent(relative)
      let destination = stage.appendingPathComponent(relative)
      guard FileSafety.contains(actual, source), fh.fileExists(atPath: source.path) else {
        if required.contains(path) { throw LibraryError.invalid("无法迁移缺失或不安全的资料库资源：\(relative)") }
        continue
      }
      try copyPackageResource(from: source, to: destination, protectedBy: actual)
      copied.insert(relative)
    }
    for value in required {
      let relative = try FileSafety.safeRelative(String(value.dropFirst(prefix.count)))
      let copiedFile = stage.appendingPathComponent(relative)
      guard FileSafety.contains(stage, copiedFile), fh.fileExists(atPath: copiedFile.path) else {
        throw LibraryError.invalid("迁移副本缺少资料库资源：\(relative)")
      }
    }
    for row in registeredResources {
      let resource = stage.appendingPathComponent("LibraryResources").appendingPathComponent(row[0])
      guard try FileSafety.stat(resource).size == Int64(row[2]),
        try FileSafety.hash(resource, cancel: { try Task.checkCancellation() }) == row[1] else {
        throw LibraryError.invalid("迁移副本的编辑资源校验失败：\(row[0])")
      }
    }
    if let archive, archive.hasPrefix("/"), !archive.hasPrefix(prefix) {
      let external = URL(fileURLWithPath: archive, isDirectory: true)
      let target = stage.appendingPathComponent("EditingArchive", isDirectory: true)
      guard !fh.fileExists(atPath: target.path), !FileSafety.contains(external, target) else {
        throw LibraryError.invalid("无法安全地迁移原资料库的编辑资源目录。")
      }
      try copyPackageResource(from: external, to: target, protectedBy: external)
      let final = finalRoot.appendingPathComponent("EditingArchive", isDirectory: true)
      try transaction { try statement("UPDATE metadata SET value=? WHERE key='editingArchiveRoot'", [final.path]) }
    }
  }

  private func copyPackageResource(from source: URL, to destination: URL, protectedBy actual: URL) throws {
    try Task.checkCancellation()
    let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { throw LibraryError.invalid("包内资源包含符号链接：\(source.lastPathComponent)") }
    if values.isRegularFile == true {
      let copy = try FileSafety.verifiedCopy(source: source, target: destination, expectedHash: nil,
        protectedRoots: [actual], cancel: { try Task.checkCancellation() })
      guard copy.0 == destination else { throw LibraryError.invalid("重复的迁移资源位置。") }
      return
    }
    guard values.isDirectory == true else { throw LibraryError.invalid("无法验证资料库资源：\(source.lastPathComponent)") }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    for file in children {
      try copyPackageResource(from: file, to: destination.appendingPathComponent(file.lastPathComponent), protectedBy: actual)
    }
  }
}
