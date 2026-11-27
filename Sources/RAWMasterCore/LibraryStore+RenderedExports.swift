import Darwin
import Foundation

extension LibraryStore {
  public func enqueueRenderedExport(commandID: String, workID: String, versionID: String,
    format: RenderedExportFormat, targetURL: URL, liveScene: EditingVersion? = nil) throws -> RenderedExportRecord {
    try transaction {
      guard targetURL.isFileURL, targetURL.path.hasPrefix("/") else { throw EditingError.unsafePath }
      let target = FileSafety.canonical(targetURL)
      var identity = ["workID": workID, "versionID": versionID, "format": format.rawValue, "target": target.path]
      if let liveScene { identity["sceneRecipe"] = try EditingFingerprint.of(liveScene.recipe) }
      let fingerprint = try EditingFingerprint.of(identity)
      if let existing = try commandResult(id: commandID, fingerprint: fingerprint, action: "renderedExport", type: RenderedExportRecord.self) {
        return try renderedExport(id: existing.id)
      }
      let work = try photoWork(id: workID), version = try editingVersion(id: versionID)
      guard version.workID == workID, version.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidParent }
      if let liveScene {
        guard liveScene.isLiveSceneDelivery, liveScene.parentVersionID == version.id else { throw EditingError.invalidParent }
        _ = try checkedSceneDelivery(work: work, selection: liveScene, format: .jpeg8)
      }
      try validateAdmission(work.source)
      if version.artifact == nil { try validateEditingSource(version.source) }
      var record = RenderedExportRecord(commandID: commandID, requestFingerprint: fingerprint, workID: workID,
        versionID: versionID, format: format, targetURL: target)
      record.frozenSceneRecipe = liveScene?.recipe
      try validateRenderedExportDestination(record)
      if FileManager.default.fileExists(atPath: target.path) {
        record.state = .needsAttention; record.error = "目标文件已存在，请使用新文件名"
      }
      try statement("INSERT INTO editing_exports VALUES(?,?,?,?)", [record.id, workID, commandID, try json(record)])
      try saveCommand(id: commandID, fingerprint: fingerprint, action: "renderedExport", result: record)
      return record
    }
  }
  public func renderedExport(id: String) throws -> RenderedExportRecord {
    try locked {
      guard let row = try rows("SELECT data FROM editing_exports WHERE id=?", [id]).first else { throw LibraryError.invalid("成片导出记录不存在") }
      return try decode(row[0], RenderedExportRecord.self)
    }
  }
  /// Seal the queue receipt using the same frozen identity that the exporting worker submitted.
  @discardableResult package func finishRenderedExportTask(id: String) throws -> Bool? {
    try completeVerifiedCatalogTask(key: "rendered-export-" + id) { frozen in
      let record = try renderedExport(id: id)
      guard record.state == .succeeded, frozen["receipt"] == .string(id),
            frozen["format"] == .string(record.format.rawValue) else { return nil }
      let parent = try editingVersion(id: record.versionID)
      let input = try record.frozenSceneRecipe.map { try parent.freezingSceneAppearance($0) } ?? parent
      guard frozen["version"] == .string(input.id),
            frozen["source"] == .string(input.source.contentSHA256) else { return nil }
      return (true, id)
    }
  }

  public func loadRenderedExports(workID: String? = nil) throws -> [RenderedExportRecord] {
    try locked {
      try rows("SELECT data FROM editing_exports" + (workID == nil ? "" : " WHERE work_id=?") + " ORDER BY rowid", workID.map { [$0] } ?? [])
        .map { try decode($0[0], RenderedExportRecord.self) }
    }
  }
  private func writeRenderedExport(_ record: RenderedExportRecord) throws {
    try statement("UPDATE editing_exports SET data=? WHERE id=?", [try json(record), record.id])
  }
  private func validateRenderedExportDestination(_ record: RenderedExportRecord) throws {
    guard record.targetURL.isFileURL, FileSafety.canonical(record.targetURL).path == record.targetURL.standardizedFileURL.path else { throw EditingError.unsafePath }
    try FileSafety.checkTarget(record.targetURL, sources: editingProtectedRoots() + [editingArchive().root])
  }
  private func validateRenderedExportMetadata(_ artifact: RenderArtifact, format: RenderedExportFormat) throws {
    try artifact.validate()
    guard artifact.iccProfileSHA256 != nil else { throw EditingError.invalidArtifact }
    let encoding = artifact.encoding.lowercased()
    switch format {
    case .jpeg8:
      guard ["jpeg", "jpg", "public.jpeg"].contains(encoding), artifact.bitDepth == 8,
        artifact.colorSpace.lowercased().contains("srgb"), [.opaque, .compositedWhite, .compositedBlack].contains(artifact.alphaPolicy) else { throw EditingError.invalidArtifact }
    case .tiff16:
      guard ["tiff", "tif", "public.tiff"].contains(encoding), artifact.bitDepth == 16 else { throw EditingError.invalidArtifact }
    case .png16:
      guard ["png", "public.png"].contains(encoding), artifact.bitDepth == 16 else { throw EditingError.invalidArtifact }
    }
  }
  private func validateRenderedExportStage(_ url: URL, record: RenderedExportRecord, artifact: RenderArtifact) throws {
    guard url.isFileURL, url.lastPathComponent.hasPrefix(".rawmaster-render-"),
      url.standardizedFileURL.path != record.targetURL.path,
      FileSafety.canonical(url).path == url.standardizedFileURL.path,
      FileSafety.canonical(url.deletingLastPathComponent()).path == record.targetURL.deletingLastPathComponent().path else { throw EditingError.unsafePath }
    try FileSafety.checkTarget(url, sources: editingProtectedRoots() + [editingArchive().root])
    guard try FileSafety.stat(url).size == artifact.byteCount, try FileSafety.hash(url) == artifact.sha256 else { throw EditingError.archiveMismatch }
  }
  private func synchronizeRenderedExportDirectory(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }
  /// Renderer callback: invoke off-main after metadata verification, before exclusive final publication.
  /// After this succeeds the renderer must retain this recognized stage on errors/cancellation.
  public func prepareRenderedExport(id: String, artifact: RenderArtifact, stagingURL: URL) throws -> RenderedExportRecord {
    try locked {
      var existing = try renderedExport(id: id)
      if existing.preparedArtifact == nil, FileManager.default.fileExists(atPath: existing.targetURL.path) {
        existing.state = .needsAttention; existing.error = "目标文件已存在，未覆盖"; existing.updatedAt = Date()
        try transaction { try writeRenderedExport(existing) }
        throw LibraryError.invalid("目标文件已存在，未覆盖")
      }
      return try transaction {
        var record = try renderedExport(id: id)
        if let prepared = record.preparedArtifact {
          guard prepared == artifact, record.stagingURL?.path == stagingURL.standardizedFileURL.path else { throw EditingError.commandConflict }
          guard record.state != .cancelled else { throw LibraryError.cancelled }
          return record
        }
        guard record.state == .queued else { throw EditingError.illegalTransition }
        let work = try photoWork(id: record.workID), version = try editingVersion(id: record.versionID)
        guard version.workID == work.id else { throw EditingError.invalidParent }
        try validateAdmission(work.source)
        if version.artifact == nil { try validateEditingSource(version.source) }
        try validateRenderedExportDestination(record)
        try validateRenderedExportMetadata(artifact, format: record.format)
        try validateRenderedExportStage(stagingURL, record: record, artifact: artifact)
        let handle = try FileHandle(forWritingTo: stagingURL); try handle.synchronize(); try handle.close()
        try synchronizeRenderedExportDirectory(stagingURL.deletingLastPathComponent())
        record.preparedArtifact = artifact; record.stagingURL = stagingURL.standardizedFileURL
        record.state = .prepared; record.error = nil; record.updatedAt = Date()
        try writeRenderedExport(record)
        return record
      }
    }
  }
  private func reconcileRenderedExport(id: String, publishStage: Bool) throws -> RenderedExportRecord {
    try transaction {
      var record = try renderedExport(id: id)
      do {
        try validateRenderedExportDestination(record)
        let work = try photoWork(id: record.workID), version = try editingVersion(id: record.versionID)
        guard version.workID == work.id else { throw EditingError.invalidParent }
        if let artifact = record.preparedArtifact {
          try validateRenderedExportMetadata(artifact, format: record.format)
          if FileManager.default.fileExists(atPath: record.targetURL.path) {
            guard try FileSafety.stat(record.targetURL).size == artifact.byteCount,
              try FileSafety.hash(record.targetURL) == artifact.sha256 else { throw EditingError.archiveMismatch }
            // Final publication is authoritative even after a late cancellation or process loss.
            try synchronizeRenderedExportDirectory(record.targetURL.deletingLastPathComponent())
            record.state = .succeeded; record.error = nil; record.completedAt = record.completedAt ?? Date()
          } else if publishStage && record.state != .cancelled && record.completedAt == nil, let stage = record.stagingURL {
            try validateRenderedExportStage(stage, record: record, artifact: artifact)
            try validateRenderedExportDestination(record)
            // Exclusive same-volume publication. A racing writer is never replaced.
            if link(stage.path, record.targetURL.path) != 0 {
              guard errno == EEXIST,
                try FileSafety.stat(record.targetURL).size == artifact.byteCount,
                try FileSafety.hash(record.targetURL) == artifact.sha256 else { throw EditingError.archiveMismatch }
            }
            try synchronizeRenderedExportDirectory(record.targetURL.deletingLastPathComponent())
            record.state = .succeeded; record.error = nil; record.completedAt = record.completedAt ?? Date()
          } else if record.state != .cancelled {
            record.state = .needsAttention; record.error = "外部成片未找到，需要重新核验导出位置"
          }
        } else if record.state != .cancelled {
          if FileManager.default.fileExists(atPath: record.targetURL.path) {
            record.state = .needsAttention; record.error = "目标文件已存在，未覆盖"
          } else if !publishStage {
            record.state = .needsAttention; record.error = "导出尚未完成，需要重新核验"
          }
        }
      } catch {
        // Cancellation is durable intent. An unrelated destination conflict must never
        // turn a cancelled record into a resumable prepared export on the next reconciliation.
        if record.state != .cancelled { record.state = .needsAttention }
        record.error = (error as? EditingError) == .archiveMismatch ? "目标文件或暂存文件与导出收据不一致，未覆盖任何文件" : String(describing: error)
      }
      record.updatedAt = Date(); try writeRenderedExport(record); return record
    }
  }
  public func completeRenderedExport(id: String) throws -> RenderedExportRecord {
    try reconcileRenderedExport(id: id, publishStage: true)
  }
  public func reconcileRenderedExports(workID: String? = nil) throws -> [RenderedExportRecord] {
    try locked { try loadRenderedExports(workID: workID).map { try reconcileRenderedExport(id: $0.id, publishStage: true) } }
  }
  /// A restore verifies external locations but never writes to the user's export volume during library restoration.
  func verifyRestoredRenderedExports() throws {
    for record in try loadRenderedExports() { _ = try reconcileRenderedExport(id: record.id, publishStage: false) }
  }
  public func cancelRenderedExport(id: String) throws -> RenderedExportRecord {
    try locked {
      var record = try reconcileRenderedExport(id: id, publishStage: false)
      if record.state == .succeeded { return record }
      record.state = .cancelled; record.updatedAt = Date()
      try transaction { try writeRenderedExport(record) }
      return record
    }
  }
}
