import Foundation
import RAWMasterLibrary

public struct LibraryVirtualCopy: Sendable, Identifiable, Equatable {
  public var id: String
  public var sourceID: String
  public var projectID: String
  public var name: String
  public var revision: Int64

  public func projecting(_ source: AssetRecord) -> AssetRecord {
    var result = source
    result.id = id
    result.virtualCopySourceID = sourceID
    result.virtualCopyName = name
    return result
  }
}

extension LibraryStore {
  /// Only explicitly bound native renditions enter the photographic workbench. Imported Lightroom
  /// appearances and organization-only works keep their original interpretation and receipts.
  private static let nativeCopyRows = """
    SELECT w.work_id,e.asset_id,e.project_id,w.name,w.revision
    FROM lc_org_works w JOIN editing_works e ON e.id=w.work_id
    WHERE w.kind='virtual' AND json_extract(e.data,'$.virtualCopyID')=w.work_id
    """

  public func virtualCopies(projectID: String? = nil) throws -> [LibraryVirtualCopy] {
    try locked {
      var sql = Self.nativeCopyRows + " AND coalesce(json_extract(w.metadata_json,'$.rawmasterCopyRemoved'),0)=0"
      if projectID != nil { sql += " AND e.project_id=?" }
      return try rows(sql + " ORDER BY w.rowid", projectID.map { [$0] } ?? []).map { row in
        .init(id: row[0], sourceID: row[1], projectID: row[2], name: row[3], revision: Int64(row[4]) ?? 0)
      }
    }
  }

  public func editingWorks(for asset: AssetRecord) throws -> [PhotoWork] {
    if asset.virtualCopySourceID != nil {
      return try withReadSnapshot {
        guard try rows(Self.nativeCopyRows + " AND w.work_id=? AND e.asset_id=? AND e.project_id=? AND coalesce(json_extract(w.metadata_json,'$.rawmasterCopyRemoved'),0)=0",
                       [asset.id,asset.physicalAssetID,asset.projectID]).first != nil else { throw EditingError.missingWork }
        return [try photoWork(id: asset.id)]
      }
    }
    return try loadPhotoWorks(projectID: asset.projectID, assetID: asset.id).filter { $0.virtualCopyID == nil }
  }

  /// Revisions are small enough to read with the grid sidebar. Untouched files keep using their embedded thumbnails.
  public func renditionPreviewRevisions(projectID: String? = nil) throws -> [String: String] {
    try locked {
      var sql = """
        SELECT coalesce(json_extract(e.data,'$.virtualCopyID'),e.asset_id),e.id,
               coalesce(json_extract(e.data,'$.liveRevision'),0),coalesce(json_extract(e.data,'$.adoptionRevision'),0)
        FROM editing_works e WHERE (json_type(e.data,'$.liveRecipe')='object'
          OR json_extract(e.data,'$.adoptedVersionID')<>json_extract(e.data,'$.originalVersionID')
          OR EXISTS (SELECT 1 FROM editing_works c WHERE c.project_id=e.project_id AND c.asset_id=e.asset_id
                     AND json_extract(c.data,'$.virtualCopyID') IS NOT NULL))
        """
      if projectID != nil { sql += " AND e.project_id=?" }
      return try rows(sql + " ORDER BY e.rowid", projectID.map { [$0] } ?? []).reduce(into: [:]) { result, row in
        result[row[0]] = [row[1],row[2],row[3]].joined(separator: "/")
      }
    }
  }

  private func checkedCopyName(_ name: String, sourceID: String, projectID: String, excluding: String? = nil) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 128, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw LibraryError.invalid("请输入 1 到 128 个字符的副本名称。")
    }
    guard try !virtualCopies(projectID: projectID).contains(where: {
      $0.sourceID == sourceID && $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame
    }) else { throw LibraryError.invalid("这张照片已使用此副本名称。") }
    return value
  }

  @discardableResult public func createVirtualCopy(of asset: AssetRecord, name: String,
      id: String = UUID().uuidString, rawDecoder: DevelopmentRAWDecoder? = nil) throws -> LibraryVirtualCopy {
    guard UUID(uuidString: id) != nil else { throw EditingError.commandConflict }
    let physical = try self.asset(asset.physicalAssetID)
    let request = try EditingFingerprint.of([asset.id,physical.id,asset.projectID,name])
    let command = "native-copy-create/" + id
    func replay() throws -> LibraryVirtualCopy? {
      guard let saved = try commandResult(id: command, fingerprint: request, action: "createVirtualCopy", type: String.self) else { return nil }
      guard let copy = try virtualCopies(projectID: asset.projectID).first(where: { $0.id == saved }) else { throw EditingError.staleAdoption }
      return copy
    }
    if let copy = try withReadSnapshot(replay) { return copy }
    let verified = physical.availability == .available ? try captureEditingSourceSnapshot(assetID: physical.id) : nil
    return try transaction {
      if let copy = try replay() { return copy }
      guard try rows("SELECT 1 FROM assets WHERE id=? UNION ALL SELECT 1 FROM lc_org_works WHERE work_id=? LIMIT 1", [id,id]).isEmpty else {
        throw EditingError.commandConflict
      }
      let label = try checkedCopyName(name, sourceID: physical.id, projectID: asset.projectID)
      let existing = try editingWorks(for: asset)
      let base: PhotoWork
      if let verified {
        try validateEditingSource(verified)
        if let stored = existing.last(where: { $0.source.hasSameIdentity(as: verified) }) { base = stored }
        else if asset.virtualCopySourceID == nil { base = try createPhotoWork(source: verified, rawDecoder: rawDecoder) }
        else { throw EditingError.staleSource }
      } else {
        guard physical.availability == .missing, let saved = existing.last else { throw EditingError.invalidSource }
        try validateAdmission(saved.source)
        base = saved
      }
      guard let master = try rows("""
        SELECT w.work_id FROM lc_org_works w JOIN lc_catalog_files f ON f.file_id=w.file_id
        WHERE w.work_id='file:'||f.file_id AND f.asset_id=? AND f.project_id=? LIMIT 1
        """, [physical.id,asset.projectID]).first?.first else { throw EditingError.invalidSource }
      let adopted = try editingVersion(id: base.adoptedVersionID)
      let liveParent = base.usesLiveRendition(over: adopted) ? base.liveParentVersionID : nil
      let hasLive = liveParent != nil
      let chosen = try liveParent.map { try editingVersion(id: $0) } ?? adopted
      let root = try editingVersion(id: base.originalVersionID)
      var copy = PhotoWork(id: id, source: verified ?? base.source)
      copy.virtualCopyID = id
      copy.strictDocumentary = base.strictDocumentary
      let original = EditingVersion(id: copy.originalVersionID, workID: id, parentVersionID: nil, kind: .original,
                                   source: copy.source, recipe: root.recipe)
      try insertVersion(original)
      var recipe = (hasLive ? base.liveRecipe : nil) ?? chosen.recipe
      var presets = hasLive ? base.livePresetAdoptions : chosen.presetAdoptions
      var pixels = chosen
      if chosen.artifact == nil, adopted.kind == .development, adopted.recipe == recipe { pixels = adopted }
      let reuseArchive = pixels.artifact != nil && (pixels.kind == .development || recipe.sceneGraph == nil)
      let owner = reuseArchive ? try archivedOwner(of: pixels) : nil
      if let owner {
        let editable = owner.kind == .development
        var alias = EditingVersion(workID: id, parentVersionID: original.id, kind: editable ? .development : .external,
          source: copy.source, recipe: editable ? owner.recipe : .init(), artifact: owner.artifact,
          configuration: ["virtualCopyArchiveSource": owner.id])
        if editable {
          alias.presetAdoptions = owner.presetAdoptions
          if !hasLive || chosen.kind == .external {
            recipe = owner.recipe
            presets = owner.presetAdoptions
          }
        }
        try insertVersion(alias)
        copy.adoptedVersionID = alias.id
      }
      if owner == nil || owner?.kind == .development {
        copy.liveRecipe = recipe
        copy.liveParentVersionID = copy.adoptedVersionID
        copy.liveRevision = 0
        copy.renditionSelection = .live
        copy.livePresetAdoptions = presets
        if let other = base.liveRecipe, (other.sceneGraph == nil) != (recipe.sceneGraph == nil) {
          copy.liveAlternateAppearance = .init(recipe: other, presetAdoptions: base.livePresetAdoptions)
        } else {
          copy.liveAlternateAppearance = base.liveAlternateAppearance
        }
      }
      try statement("INSERT INTO editing_works VALUES(?,?,?,?)", [id,copy.source.projectID,physical.id,try json(copy)])
      _ = try catalogWrite("org.saveWork", id: "native-copy-org/" + id, fields: [
        "workID":.string(id),"kind":.string("virtual"),"masterWorkID":.string(master),
        "projectID":.string(asset.projectID),"name":.string(label),"baseRevision":.integer(0)])
      try saveCommand(id: command, fingerprint: request, action: "createVirtualCopy", result: id)
      return .init(id: id, sourceID: physical.id, projectID: asset.projectID, name: label, revision: 1)
    }
  }

  func archivedOwner(of version: EditingVersion) throws -> EditingVersion {
    let ownerID = version.configuration["virtualCopyArchiveSource"] ?? version.id
    guard let row = try rows("""
      SELECT v.data,p.data FROM editing_versions v JOIN archive_publications p ON p.version_id=v.id WHERE v.id=?
      """, [ownerID]).first else { throw EditingError.incompleteBackup }
    let owner = try decode(row[0], EditingVersion.self)
    guard owner.configuration["virtualCopyArchiveSource"] == nil, owner.artifact != nil,
          owner.id == ownerID, version.artifact == owner.artifact, owner.source.hasSameIdentity(as: version.source),
          try decode(row[1], ArchivePublicationReceipt.self).version == owner else { throw EditingError.incompleteBackup }
    if owner.id != version.id {
      let copy = try photoWork(id: version.workID)
      let matchesDevelopment = version.kind == .development && owner.kind == .development &&
        version.recipe.sceneGraph == nil && version.recipe == owner.recipe && version.presetAdoptions == owner.presetAdoptions
      guard copy.id == version.workID, copy.virtualCopyID == copy.id, copy.source.hasSameIdentity(as: version.source),
            version.kind == .external || matchesDevelopment, version.parentVersionID == copy.originalVersionID else {
        throw EditingError.incompleteBackup
      }
    }
    return owner
  }

  @discardableResult public func updateVirtualCopy(_ copy: LibraryVirtualCopy, name: String? = nil, removed: Bool? = nil) throws -> LibraryVirtualCopy {
    try transaction {
      guard let row = try rows(Self.nativeCopyRows + " AND w.work_id=? AND e.project_id=? AND e.asset_id=?", [copy.id,copy.projectID,copy.sourceID]).first,
            Int64(row[4]) == copy.revision else { throw EditingError.staleAdoption }
      let label = try checkedCopyName(name ?? row[3], sourceID: copy.sourceID, projectID: copy.projectID, excluding: copy.id)
      var fields: [String:CatalogJSON] = ["workID":.string(copy.id),"name":.string(label),"baseRevision":.integer(copy.revision)]
      if let removed {
        let payload = try rows("SELECT metadata_json FROM lc_org_works WHERE work_id=?", [copy.id])[0][0]
        var metadata = try decode(payload,[String:CatalogJSON].self)
        metadata["rawmasterCopyRemoved"] = removed ? .boolean(true) : nil
        fields["metadata"] = .object(metadata)
      }
      _ = try catalogWrite("org.saveWork",id: UUID().uuidString,fields: fields)
      return .init(id: copy.id, sourceID: copy.sourceID, projectID: copy.projectID, name: label, revision: copy.revision + 1)
    }
  }
}
