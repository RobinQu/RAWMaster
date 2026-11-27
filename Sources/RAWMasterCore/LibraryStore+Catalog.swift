import Foundation
import RAWMasterLibrary

extension LibraryStore {
  func catalogTransaction<T: Encodable>(_ operation: String, _ payload: T) throws -> CatalogJSON {
    guard let db else { throw LibraryError.database("资料库已关闭") }
    return try LibraryEngine.shared().transaction(operation, on: db, payload: payload, as: CatalogJSON.self)
  }

  public func catalogCommand(_ command: CatalogJSON) throws -> CatalogJSON {
    try transaction { try catalogTransaction("command", command) }
  }

  @discardableResult
  func catalogWrite(_ action: String, id: String, fields: [String: CatalogJSON]) throws -> CatalogJSON {
    var envelope = fields
    envelope["commandID"] = .string(id)
    envelope["action"] = .string(action)
    envelope["version"] = .integer(1)
    return try catalogTransaction("command", CatalogJSON.object(envelope))
  }

  public func withCatalogSelection<T>(_ scope: CatalogFrozenSelection, _ action: () throws -> T) throws -> T {
    try transaction {
      _ = try catalogTransaction("validateSelection", scope)
      return try action()
    }
  }

  public var catalogActions: CatalogActions {
    CatalogActions(database: databaseURL, writer: { [self] command in try catalogCommand(command) })
  }

  func completedDirectImport(_ session: ImportSession) throws {
    try transaction {
      guard catalogInstalled, try workflow(session.id) == nil else { return }
      _ = try catalogWrite("session.finishDirect", id: "direct-close/" + session.id,
                           fields: ["sessionID": .string(session.id)])
    }
  }
}

extension LibraryStore {
  public func catalogProjectAssetIDs(_ project: String) throws -> Set<String> {
    try locked { Set(try rows("SELECT DISTINCT asset_id FROM lc_scopes WHERE project_id=?", [project]).map { $0[0] }) }
  }

  public func catalogAssets(for selection: CatalogFrozenSelection) throws -> [AssetRecord] {
    try withReadSnapshot {
      guard try catalogTransaction("resolveSelection", selection) != .null else { throw CatalogSelectionError.changed }
      return try rows("SELECT a.data FROM json_each(?) chosen JOIN assets a ON a.id=chosen.value ORDER BY chosen.key",
                      [try json(selection.assetIDs)]).map { try decode($0[0], AssetRecord.self) }
    }
  }

  public func catalogFiles(for assetIDs: [String]) throws -> [LibraryManagedFile] {
    try locked {
      try assetIDs.compactMap { id in
        guard let row = try rows("SELECT af.file_id,a.data FROM lc_asset_files af JOIN assets a ON a.id=af.asset_id WHERE a.id=?", [id]).first else { return nil }
        return LibraryManagedFile(id: row[0], location: try decode(row[1], AssetRecord.self).resolvedURL)
      }
    }
  }

  /// Lightroom's file picker explicitly admits a single verified original.
  public func admitLightroomOriginal(_ picked: URL, projectID: String?) throws -> String {
    let file = FileSafety.canonical(picked)
    let stamp = try FileSafety.stat(file)
    let hash = try FileSafety.hash(file)
    guard try FileSafety.stat(file) == stamp else { throw LibraryError.invalid("原件已变化，请重新选择") }
    return try transaction {
      let matches = try rows("""
        SELECT DISTINCT s.file_id FROM lc_scopes s JOIN lc_contents c ON c.content_id=s.content_id
        JOIN lc_replicas r ON r.file_id=s.file_id AND r.content_id=s.content_id
        WHERE c.sha256=? AND c.byte_count=? AND r.path=? AND r.state='available'
          AND (?='' OR s.project_id=?) LIMIT 2
        """, [hash,String(stamp.size),file.path,projectID ?? "",projectID ?? ""])
      guard matches.count < 2 else { throw LibraryError.invalid("所选路径对应多个已登记的原件，请先确认文件身份") }
      if let fileID = matches.first?.first { return fileID }
      let project: ProjectRecord
      if let projectID {
        guard let current = try loadProjects().first(where: { $0.id == projectID }) else { throw LibraryError.invalid("指定的项目不存在") }
        project = current
      }
      else if let existing = try loadProjects().first(where: { $0.name == "Lightroom 迁入" }) { project = existing }
      else { project = ProjectRecord(name: "Lightroom 迁入"); try saveProject(project) }
      let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: file.deletingLastPathComponent().path,
                                  mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
      try saveSession(session)
      _ = try catalogWrite("session.open", id: "import-open/" + session.id,
                           fields: ["sessionID": .string(session.id), "projectID": .string(project.id)])
      let asset = try register(AssetRecord(sessionID: session.id, projectID: project.id, projectName: project.name, sourcePath: file.path,
                                           fileSize: stamp.size, contentHash: hash, importState: .ready, effectiveSourcePath: file.path))
      try bindVerifiedImportOccurrence(asset)
      _ = try catalogTransaction("flushLegacy", LibraryEmpty())
      try completedDirectImport(session)
      guard let result = try rows("SELECT file_id FROM lc_scopes WHERE session_id=? AND asset_id=?", [session.id,asset.id]).first else {
        throw LibraryError.invalid("未能确认该原件的归档资格")
      }
      return result[0]
    }
  }
}

extension LibraryStore {
  /// The caller holds the ingest transaction. A new occurrence may refer to the
  /// same original without inheriting the other occurrence's admission decision.
  func bindVerifiedImportOccurrence(_ asset: AssetRecord) throws {
    guard catalogInstalled, asset.importState == .ready, asset.availability == .available,
          asset.error == nil, asset.contentHash != nil else { return }
    let candidates = try rows("""
      SELECT DISTINCT old.file_id FROM lc_occurrences o
      JOIN lc_asset_input a ON a.asset_id=o.asset_id AND a.session_id=o.session_id
      JOIN lc_files provisional ON provisional.file_id=o.file_id
      JOIN lc_replicas old ON old.content_id=o.content_id AND old.path=a.source_path
      JOIN lc_files known ON known.file_id=old.file_id AND known.role=a.role
      WHERE o.session_id=? AND o.asset_id=? AND o.file_id=o.asset_id AND o.explicit_id=0
        AND o.disposition='pending' AND o.content_id IS NOT NULL AND provisional.pair_locked=0
        AND old.file_id<>o.file_id AND old.kind='source' AND old.state='available'
        AND EXISTS(SELECT 1 FROM lc_scopes s WHERE s.asset_id=old.source_asset_id
                   AND s.file_id=old.file_id AND s.content_id=old.content_id)
        AND NOT EXISTS(SELECT 1 FROM lc_files sibling WHERE sibling.capture_id=provisional.capture_id AND sibling.file_id<>o.file_id)
        AND NOT EXISTS(SELECT 1 FROM lc_group_file_members gm WHERE gm.file_id=o.file_id)
      LIMIT 2
      """, [asset.sessionID,asset.id])
    guard candidates.count == 1, let fileID = candidates.first?.first else { return }
    _ = try catalogWrite("occurrence.put", id: "import-bind/" + asset.id + "/" + fileID,
                         fields: ["sessionID":.string(asset.sessionID), "occurrenceID":.string(asset.id),
                                  "assetID":.string(asset.id), "fileID":.string(fileID)])
  }
}
