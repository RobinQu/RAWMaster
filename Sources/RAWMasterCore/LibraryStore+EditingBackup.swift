import CSQLite
import Darwin
import Foundation

extension LibraryStore {
  /// A standalone SQLite snapshot plus all recognized archive bytes/receipts, verified before publishing manifest.
  /// Original camera files are deliberately not copied and are never mutated.
  public func backupEditingLibrary(to directory: URL) throws -> EditingLibraryBackupManifest {
    try locked {
      let archive = try editingArchive()
      let protected = try editingProtectedRoots()
      try FileSafety.checkTarget(directory, sources: protected + [archive.root])
      guard !FileManager.default.fileExists(atPath: directory.path) else { throw EditingError.unsafePath }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return try withReadSnapshot {
        let database = directory.appendingPathComponent("library.sqlite")
        var destination: OpaquePointer?
        guard sqlite3_open_v2(database.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
          defer { sqlite3_close(destination) }; throw DatabaseSchema.error(destination)
        }
        do {
          guard let backup = sqlite3_backup_init(destination, "main", db, "main") else { throw DatabaseSchema.error(destination) }
          let status = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
          guard status == SQLITE_DONE, finish == SQLITE_OK,
            sqlite3_exec(destination, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK,
            try DatabaseSchema.strings(destination, "PRAGMA quick_check") == ["ok"],
            try DatabaseSchema.validate(destination) == DatabaseSchema.version else { throw EditingError.incompleteBackup }
          sqlite3_close(destination); destination = nil
        } catch { sqlite3_close(destination); throw error }
        var initialFiles: Set<String> = []
        // Preserve every recognized receipt. Invalid pending semantics must reject a backup/restore,
        // never silently disappear or surface only after final destination publication.
        for receipt in try archive.recoverPublications() {
          try archive.validate(receipt)
          initialFiles.insert(receipt.version.artifact!.relativePath)
          initialFiles.insert("receipts/\(receipt.id).json")
        }
        for received in try archive.recoverReceivedOutputs() {
          initialFiles.insert(received.artifact.relativePath)
          initialFiles.insert("received-receipts/\(received.id).json")
        }
        for job in try loadProcessingJobs() {
          guard job.request.inputArtifact.relativePath.hasPrefix(".inputs/") else { throw EditingError.incompleteBackup }
          _ = try archive.processingInputURL(job.request.inputArtifact)
          initialFiles.insert(job.request.inputArtifact.relativePath)
          if let quick = job.request.quickPrompt {
            for file in [quick.basis, quick.matte].compactMap({ $0 }) {
              _ = try archive.processingInputURL(file.artifact)
              initialFiles.insert(file.artifact.relativePath)
            }
          }
        }
        let backupArchiveRoot = directory.appendingPathComponent("archive")
        let backupArchive = try EditingArchive(root: backupArchiveRoot, protectedRoots: protected)
        for relative in initialFiles {
          let source = archive.root.appendingPathComponent(relative)
          let hash = try FileSafety.hash(source)
          let target = backupArchiveRoot.appendingPathComponent(relative)
          let copied = try FileSafety.verifiedCopy(source: source, target: target, expectedHash: hash, protectedRoots: protected, cancel: {})
          guard copied.0 == target else { throw EditingError.incompleteBackup }
        }
        // Reconcile all pending received/publication receipts into the isolated DB snapshot.
        // This also captures a persisted returned-output intent from its still-existing provider file.
        do {
          let snapshot = try LibraryStore(databaseURL: database)
          try snapshot.statement("UPDATE metadata SET value=? WHERE key='editingArchiveRoot'", [backupArchive.root.path])
          _ = try snapshot.recoverEditingArchive()
          try snapshot.validateEditingArchiveReferences(archive: backupArchive)
          try snapshot.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
          guard sqlite3_close(snapshot.db) == SQLITE_OK else { throw EditingError.incompleteBackup }
          snapshot.db = nil
        }
        var relativeFiles = initialFiles
        for received in try backupArchive.recoverReceivedOutputs() {
          relativeFiles.insert(received.artifact.relativePath)
          relativeFiles.insert("received-receipts/\(received.id).json")
        }
        for publication in try backupArchive.recoverPublications() {
          relativeFiles.insert(publication.version.artifact!.relativePath)
          relativeFiles.insert("receipts/\(publication.id).json")
        }
        var files: [String: String] = [:]
        for relative in relativeFiles { files[relative] = try FileSafety.hash(backupArchive.root.appendingPathComponent(relative)) }
        let manifest = EditingLibraryBackupManifest(databaseSHA256: try FileSafety.hash(database), files: files)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try Self.synchronizeEditingDirectories(root: directory, files: files.keys.map { "archive/" + $0 })
        try encoder.encode(manifest).write(to: manifestURL, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: manifestURL); try handle.synchronize(); try handle.close()
        try Self.synchronizeEditingDirectories(root: directory, files: [])
        return manifest
      }
    }
  }
  private static func synchronizeEditingDirectories(root: URL, files: [String]) throws {
    var directories: Set<String> = [root.path]
    for relative in files {
      var directory = root.appendingPathComponent(relative).deletingLastPathComponent()
      while FileSafety.contains(root, directory) && directory.path != root.path {
        directories.insert(directory.path); directory.deleteLastPathComponent()
      }
    }
    for path in directories.sorted(by: { $0.count > $1.count }) {
      let fd = open(path, O_RDONLY)
      guard fd >= 0 else { throw EditingError.incompleteBackup }
      let status = fsync(fd); close(fd)
      guard status == 0 else { throw EditingError.incompleteBackup }
    }
  }
  private func validateEditingArchiveReferences(archive: EditingArchive) throws {
    var versions: [String: EditingVersion] = [:]
    for row in try rows("SELECT id,data FROM editing_versions") {
      let version = try decode(row[1], EditingVersion.self)
      guard version.id == row[0], versions[version.id] == nil else { throw EditingError.incompleteBackup }
      try version.recipe.validate(); versions[version.id] = version
      if version.artifact != nil {
        guard let publication = try rows("SELECT data FROM archive_publications WHERE version_id=?", [version.id]).first else { throw EditingError.incompleteBackup }
        let receipt = try decode(publication[0], ArchivePublicationReceipt.self)
        guard receipt.version == version else { throw EditingError.incompleteBackup }
        try archive.validate(receipt)
      }
    }
    for work in try loadPhotoWorks() {
      guard let original = versions[work.originalVersionID], original.kind == .original, original.parentVersionID == nil,
        original.workID == work.id, original.source.hasSameIdentity(as: work.source),
        let adopted = versions[work.adoptedVersionID], adopted.workID == work.id, work.adoptionRevision >= 0 else { throw EditingError.incompleteBackup }
    }
    for record in try loadRenderedExports() {
      guard let version = versions[record.versionID], version.workID == record.workID,
        record.targetURL.isFileURL, record.targetURL.path.hasPrefix("/"), EditingFingerprint.isSHA256(record.requestFingerprint),
        (record.preparedArtifact == nil) == (record.stagingURL == nil) else { throw EditingError.incompleteBackup }
      if let artifact = record.preparedArtifact { try artifact.validate() }
      if record.state == .succeeded { guard record.preparedArtifact != nil, record.completedAt != nil else { throw EditingError.incompleteBackup } }
    }
    for job in try loadProcessingJobs() {
      _ = try archive.processingInputURL(job.request.inputArtifact)
      if let quick = job.request.quickPrompt {
        try quick.validate(input: job.request.inputArtifact)
        _ = try archive.processingInputURL(quick.basis.artifact)
        if let matte = quick.matte { _ = try archive.processingInputURL(matte.artifact) }
      }
      for attempt in job.attempts {
        guard attempt.pendingReceivedOutput == nil else { throw EditingError.incompleteBackup }
        if let received = attempt.receivedOutput {
          guard received.jobID == job.id, received.attemptID == attempt.id, received.runID == attempt.runID else { throw EditingError.incompleteBackup }
          _ = try archive.resolveReceivedOutput(received)
        }
      }
    }
    for version in versions.values where version.kind != .original {
      guard let parentID = version.parentVersionID, let parent = versions[parentID], parent.workID == version.workID else { throw EditingError.incompleteBackup }
      var visited: Set<String> = [version.id], cursor: EditingVersion? = parent
      while let next = cursor {
        guard visited.insert(next.id).inserted else { throw EditingError.incompleteBackup }
        cursor = next.parentVersionID.flatMap { versions[$0] }
      }
    }
  }
  public func editingProtectedRoots() throws -> [URL] {
    try withReadSnapshot {
      // Preserve the existing relocation safety boundary, then extend it to managed and historical positions.
      try protectedSourceRoots() + Self.editingRoots(sessions: loadSessions(), assets: loadAssets(), relocations: loadRelocationSessions())
    }
  }
  private static func editingRoots(sessions: [ImportSession], assets: [AssetRecord], relocations: [RelocationSession]) -> [URL] {
    let sessionPaths = sessions.flatMap { [$0.sourcePath, $0.effectiveSourceRoot, $0.destinationPath, $0.effectiveManagedRoot].compactMap { $0 } }
    let assetPaths = assets.flatMap { [$0.sourcePath, $0.currentPath, $0.effectiveSourcePath, $0.effectiveManagedPath].compactMap { $0 } }
    let historicalPaths = relocations.filter { $0.committedCount > 0 }.flatMap { relocation in
      [relocation.rootPath] + relocation.items.filter { $0.status == .committed }.flatMap { [$0.oldPath, $0.selectedPath].compactMap { $0 } }
    }
    return Array(Set(sessionPaths + assetPaths + historicalPaths)).map { URL(fileURLWithPath: $0) }
  }
  public static func restoreEditingLibrary(from directory: URL, databaseURL: URL, archiveRoot: URL) throws -> LibraryStore {
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode(EditingLibraryBackupManifest.self, from: Data(contentsOf: manifestURL))
    let sourceDatabase = directory.appendingPathComponent("library.sqlite")
    guard manifest.formatVersion == 1, try FileSafety.hash(sourceDatabase) == manifest.databaseSHA256,
      !FileManager.default.fileExists(atPath: databaseURL.path), !FileManager.default.fileExists(atPath: archiveRoot.path),
      !FileSafety.contains(directory, databaseURL), !FileSafety.contains(directory, archiveRoot),
      !FileSafety.contains(archiveRoot, databaseURL), !FileSafety.contains(databaseURL, archiveRoot) else { throw EditingError.unsafePath }
    var inspection: OpaquePointer?
    guard sqlite3_open_v2(sourceDatabase.path, &inspection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      defer { sqlite3_close(inspection) }; throw DatabaseSchema.error(inspection)
    }
    let protected: [URL]
    do {
      guard try DatabaseSchema.validate(inspection) == DatabaseSchema.version,
        try DatabaseSchema.strings(inspection, "PRAGMA quick_check") == ["ok"] else { throw EditingError.incompleteBackup }
      let decoder = JSONDecoder()
      func values<T: Decodable>(_ table: String, _ type: T.Type) throws -> [T] {
        try DatabaseSchema.strings(inspection, "SELECT data FROM \(table)").map { try decoder.decode(type, from: Data($0.utf8)) }
      }
      protected = try editingRoots(sessions: values("sessions", ImportSession.self), assets: values("assets", AssetRecord.self), relocations: values("relocation_sessions", RelocationSession.self))
      sqlite3_close(inspection); inspection = nil
    } catch { sqlite3_close(inspection); throw error }
    try FileSafety.checkTarget(databaseURL, sources: protected)
    try FileSafety.checkTarget(archiveRoot, sources: protected)
    try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archiveRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    let restoreID = UUID().uuidString
    let stagedDatabase = databaseURL.deletingLastPathComponent().appendingPathComponent(".restore-\(restoreID).sqlite")
    let stagedArchive = archiveRoot.deletingLastPathComponent().appendingPathComponent(".restore-\(restoreID)", isDirectory: true)
    var archivePublished = false
    defer {
      for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: stagedDatabase.path + suffix) }
      if !archivePublished { try? FileManager.default.removeItem(at: stagedArchive) }
    }
    _ = try FileSafety.verifiedCopy(source: sourceDatabase, target: stagedDatabase, expectedHash: manifest.databaseSHA256, protectedRoots: protected, cancel: {})
    let archive = try EditingArchive(root: stagedArchive, protectedRoots: protected)
    for (relative, hash) in manifest.files {
      _ = try FileSafety.safeRelative(relative)
      guard relative.hasPrefix("artifacts/") || relative.hasPrefix("receipts/") || relative.hasPrefix(".received/") || relative.hasPrefix("received-receipts/") || relative.hasPrefix(".inputs/"), EditingFingerprint.isSHA256(hash) else { throw EditingError.incompleteBackup }
      let source = directory.appendingPathComponent("archive").appendingPathComponent(relative)
      guard FileSafety.contains(directory.appendingPathComponent("archive"), source), try FileSafety.hash(source) == hash else { throw EditingError.incompleteBackup }
      let target = stagedArchive.appendingPathComponent(relative)
      guard FileSafety.contains(stagedArchive, target) else { throw EditingError.unsafePath }
      let copied = try FileSafety.verifiedCopy(source: source, target: target, expectedHash: hash, protectedRoots: protected, cancel: {})
      guard copied.0 == target else { throw EditingError.incompleteBackup }
    }
    try synchronizeEditingDirectories(root: stagedArchive, files: Array(manifest.files.keys))
    // Reconcile ALL recognized pending receipts into staged DB/archive, including semantic parent/job guards.
    // No final path exists yet, so any failure leaves both final destinations absent.
    do {
      let stagedStore = try LibraryStore(databaseURL: stagedDatabase)
      try stagedStore.statement("UPDATE metadata SET value=? WHERE key='editingArchiveRoot'", [archive.root.path])
      _ = try stagedStore.recoverEditingArchive()
      try stagedStore.validateEditingArchiveReferences(archive: archive)
      try stagedStore.verifyRestoredRenderedExports()
      try stagedStore.statement("UPDATE metadata SET value=? WHERE key='editingArchiveRoot'", [FileSafety.canonical(archiveRoot).path])
      try stagedStore.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
      guard sqlite3_close(stagedStore.db) == SQLITE_OK else { throw EditingError.incompleteBackup }
      stagedStore.db = nil
    }
    guard try FileSafety.hash(sourceDatabase) == manifest.databaseSHA256 else { throw EditingError.incompleteBackup }
    try FileManager.default.moveItem(at: stagedArchive, to: archiveRoot)
    archivePublished = true
    try synchronizeEditingDirectories(root: archiveRoot.deletingLastPathComponent(), files: [])
    // Exclusive publication of the fully validated standalone DB; never overwrite an active library.
    guard link(stagedDatabase.path, databaseURL.path) == 0 else { throw EditingError.unsafePath }
    // SQLite writer handles must never observe a second linked catalogue filename.
    guard unlink(stagedDatabase.path) == 0 else { throw EditingError.unsafePath }
    try synchronizeEditingDirectories(root: databaseURL.deletingLastPathComponent(), files: [])
    return try LibraryStore(databaseURL: databaseURL)
  }
}
