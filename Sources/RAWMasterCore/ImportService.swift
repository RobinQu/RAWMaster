import Foundation

public enum ImportExecutionStage: Sendable, Equatable { case intake, grouping }
public typealias ImportStageCallback = @Sendable (String, ImportExecutionStage) -> Void

/// Image I/O decodes the composited image and its color profile for these rendered still formats.
public enum RenderedPhotoFormats {
  public static let extensions: Set<String> = [
    "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "avif", "jxl", "webp", "psd", "psb",
  ]
}

public final class ImportService: @unchecked Sendable {
  private let store: LibraryStore
  private let postIngest: ImportPostIngestCallback?
  private let control = JobControl()
  private static let extensions: Set<String> = RenderedPhotoFormats.extensions.union([
    "arw", "dng", "raw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
  ])
  public init(store: LibraryStore, postIngest: ImportPostIngestCallback? = nil) {
    self.store = store
    self.postIngest = postIngest
  }
  public func cancel() { control.cancel() }
  public func pause() { control.pause() }
  public func importDirectory(
    source: URL, destination: URL?, projectName: String, mode: ImportMode, projectID: String? = nil, initialScreening: Bool = false,
    stageChanged: @escaping ImportStageCallback = { _, _ in },
    progress: @escaping @Sendable (TaskProgress) -> Void
  ) async throws -> ImportSession {
    return try await execute(stageChanged: stageChanged, progress: progress) { [self] in
      let root = FileSafety.canonical(source)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw LibraryError.invalid("源目录不可用：\(root.path)") }
      let sourceIdentity = try LocalDirectoryIdentity(root)
      var destinationIdentity: LocalDirectoryIdentity?
      if mode == .copy {
        guard let destination else { throw LibraryError.invalid("请选择复制目标目录") }
        try FileSafety.checkTarget(destination, sources: try store.protectedSourceRoots() + [root])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        destinationIdentity = try LocalDirectoryIdentity(destination)
      }
      let session = try store.prepareImportSession(root: root, destination: destination, mode: mode, projectName: projectName,
        projectID: projectID, initialScreening: initialScreening, sourceIdentity: sourceIdentity, destinationIdentity: destinationIdentity)
      return try run(session, stageChanged: stageChanged, progress: progress)
    }
  }
  public func resume(sessionID: String, stageChanged: @escaping ImportStageCallback = { _, _ in }, progress: @escaping @Sendable (TaskProgress) -> Void)
    async throws -> ImportSession
  {
    return try await execute(stageChanged: stageChanged, progress: progress) { [self] in
      guard let s = try store.loadSessions().first(where: { $0.id == sessionID }) else {
        throw LibraryError.invalid("导入会话不存在")
      }
      return try run(s, stageChanged: stageChanged, progress: progress)
    }
  }
  private func execute(
    stageChanged: @escaping ImportStageCallback,
    progress: @escaping @Sendable (TaskProgress) -> Void,
    body: @escaping @Sendable () throws -> ImportSession
  ) async throws -> ImportSession {
    try control.begin()
    defer { control.finish() }
    return try await withTaskCancellationHandler(
      operation: {
        do {
          try Task.checkCancellation()
          let result = try await Task.detached(priority: .userInitiated, operation: body).value
          if result.status == "completed", result.scanCompleted == true, let postIngest {
            stageChanged(result.id, .grouping)
            await postIngest(result, { try self.control.check() }, progress)
          }
          if result.status == "completed", result.scanCompleted == true { try store.completedDirectImport(result) }
          return result
        } catch {
          progress(
            TaskProgress(title: "导入未完成", message: error.localizedDescription, isRunning: false))
          throw error
        }
      }, onCancel: { self.control.cancel() })
  }
  private func run(_ original: ImportSession, stageChanged: @escaping ImportStageCallback, progress: @escaping @Sendable (TaskProgress) -> Void)
    throws -> ImportSession
  {
    try store.requireLocalTask(.importSession, id: original.id)
    let executionLease = try store.acquireImportLease(original.id)
    defer { executionLease.release() }
    try store.setImportActive(original.id, active: true)
    defer { try? store.setImportActive(original.id, active: false) }
    stageChanged(original.id, .intake)
    var session = original
    session.status = "scanning"
    session.failed = 0
    try store.saveSession(session)
    let root = session.effectiveSourceURL
    let localDate = DateFormatter()
    localDate.locale = Locale(identifier: "en_US_POSIX")
    localDate.calendar = Calendar(identifier: .gregorian)
    localDate.timeZone = .current
    localDate.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let protectedRoots = try store.protectedSourceRoots()
    var discoveryConflicts = Set<String>()
    var processed = 0
    defer {
      progress(
        TaskProgress(
          title: "导入", completed: processed, total: session.discovered, message: session.status,
          isRunning: false))
    }
    do {
      try control.check()
      var isDir: ObjCBool = false
      let sourceAvailable =
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
      if sourceAvailable {
        let sourceIdentity = try LocalDirectoryIdentity(root)
        if let saved = session.sourceDirectoryIdentity, !saved.matches(sourceIdentity) {
          throw LibraryError.invalid("来源目录或磁盘身份已变化。请接回原设备，或先在导入会话中核验并重新定位原片。")
        }
        session.sourceDirectoryIdentity = sourceIdentity
      }
      let managedRoot = session.managedContainerURL
      if session.mode == .copy {
        guard let managedRoot else {
          throw LibraryError.invalid("缺少复制目标目录")
        }
        try FileSafety.checkTarget(managedRoot, sources: protectedRoots)
        if session.managedDirectoryIdentity == nil {
          try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        }
        guard let actual = try? LocalDirectoryIdentity(managedRoot),
          session.managedDirectoryIdentity?.matches(actual) != false else {
          throw LibraryError.invalid("复制目标目录或磁盘身份已变化。请接回复制目标，或先核验并重新定位副本。")
        }
        session.managedDirectoryIdentity = actual
      }
      let expectedSource = sourceAvailable ? session.sourceDirectoryIdentity : nil
      let expectedManaged = session.managedDirectoryIdentity
      func verifyDirectory(_ url: URL, _ identity: LocalDirectoryIdentity?, message: String) throws {
        guard let identity else { return }
        guard let current = try? LocalDirectoryIdentity(url), identity.matches(current) else {
          throw LibraryError.invalid(message)
        }
      }
      if sourceAvailable {
        session.scanCompleted = false
        try store.saveSession(session)
        var scanError: Error?
        guard
          let iterator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
              scanError = error
              return true
            })
        else { throw LibraryError.invalid("无法扫描源目录") }
        let registered = try store.loadAssets(sessionID: session.id)
        let byRelative = Dictionary(
          registered.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let byPosition = Dictionary(
          registered.map { (FileSafety.canonical($0.resolvedSourceURL).path, $0) },
          uniquingKeysWith: { first, _ in first })
        var discoveryBatch: [AssetRecord] = []
        do {
          for case let url as URL in iterator {
            try control.check()
            if processed % 32 == 0 { try verifyDirectory(root, expectedSource, message: "扫描期间来源目录已变化。") }
            guard Self.extensions.contains(url.pathExtension.lowercased()) else { continue }
            // Resolve both sides: Foundation may enumerate /var while the selected root is /private/var.
            let resolved = FileSafety.canonical(url)
            guard FileSafety.contains(root, resolved), let stamp = try? FileSafety.stat(resolved)
            else { continue }
            let relative = String(resolved.path.dropFirst(FileSafety.canonical(root).path.count + 1))
            _ = try FileSafety.safeRelative(relative)
            if let existing = byRelative[relative] ?? byPosition[resolved.path] {
              if FileSafety.canonical(existing.resolvedSourceURL) != resolved {
                if let identity = existing.contentHash,
                  try FileSafety.hash(resolved, cancel: { try self.control.check() }) == identity
                {
                  try store.adoptDiscoveredSource(
                    assetID: existing.id, path: resolved.path,
                    expectedFingerprint: LocationIdentity.fingerprint(existing, role: .source))
                } else {
                  discoveryConflicts.insert(existing.id)
                }
              }
            } else {
              let record = AssetRecord(
                sessionID: session.id, projectID: session.projectID, projectName: session.projectName,
                sourcePath: resolved.path, relativePath: relative, fileSize: stamp.size,
                effectiveSourcePath: resolved.path)
              discoveryBatch.append(record)
              if discoveryBatch.count == 64 {
                try verifyDirectory(root, expectedSource, message: "扫描期间来源目录已变化。")
                try store.registerDiscovered(discoveryBatch)
                discoveryBatch.removeAll(keepingCapacity: true)
              }
            }
            if processed % 32 == 0 {
              progress(TaskProgress(title: "扫描素材", completed: 0, total: 0, message: relative))
            }
            processed += 1
          }
          try verifyDirectory(root, expectedSource, message: "扫描期间来源目录已变化。")
        } catch LibraryError.cancelled {
          // Graceful cancellation retains the already discovered tail as well as
          // complete batches. A crash can simply rediscover that bounded tail.
          try verifyDirectory(root, expectedSource, message: "扫描期间来源目录已变化。")
          try store.registerDiscovered(discoveryBatch)
          throw LibraryError.cancelled
        }
        try store.registerDiscovered(discoveryBatch)
        if let scanError { throw scanError }
        session.scanCompleted = true
      } else if try store.loadAssets(sessionID: session.id).isEmpty {
        throw LibraryError.invalid("源目录不可用：\(root.path)")
      }
      var assets = try store.loadAssets(sessionID: session.id)
      session.discovered = assets.count
      session.status = "importing"
      session.completed = 0
      processed = 0
      try store.saveSession(session)
      for i in assets.indices {
        try control.check()
        try verifyDirectory(root, expectedSource, message: "接入期间来源目录已变化。")
        if let managedRoot { try verifyDirectory(managedRoot, expectedManaged, message: "接入期间复制目标已变化。") }
        var a = assets[i]
        let sourceFingerprint = LocationIdentity.fingerprint(a, role: .source)
        let managedFingerprint = LocationIdentity.fingerprint(a, role: .managed)
        do {
          if discoveryConflicts.contains(a.id) {
            if session.mode == .copy, let identity = a.contentHash,
              try readableHash(a.resolvedURL) == identity
            {
              a.error = "新来源目录同一相对路径的内容不同或缺少旧哈希；未套用身份，继续使用已核验副本"
              a.availability = .available
              a.importState = .ready
              session.completed += 1
            } else {
              a.error = "新来源目录同一相对路径的内容不同或缺少旧哈希；请作为新内容接入"
              a.availability = .changed
              a.importState = .failed
              session.failed += 1
            }
            try store.saveImportAsset(
              a, expectedSourceFingerprint: sourceFingerprint,
              expectedManagedFingerprint: managedFingerprint, session: session)
            processed += 1
            continue
          }
          // Completed copies are validated again on resume; reference files are rehashed.
          if a.importState == .ready, let oldHash = a.contentHash, session.mode == .copy,
            try readableHash(a.resolvedURL) == oldHash
          {
            a.error = nil
            if FileManager.default.fileExists(atPath: a.resolvedSourceURL.path) {
              do {
                if try FileSafety.hash(
                  a.resolvedSourceURL, cancel: { try self.control.check() })
                  != oldHash
                {
                  a.error = "源文件内容已改变；继续使用已校验的原始受管副本，未采用新内容"
                }
              } catch LibraryError.cancelled { throw LibraryError.cancelled } catch {
                a.error = "无法复核源路径；继续使用已校验的受管副本：" + error.localizedDescription
              }
            }
            a.availability = .available
          } else {
            let source = a.resolvedSourceURL
            let previous = a.contentHash
            let needsMetadata = previous == nil
            a.importState = session.mode == .copy ? .copying : .verifying
            a.error = nil
            try store.saveImportAsset(
              a, expectedSourceFingerprint: sourceFingerprint,
              expectedManagedFingerprint: managedFingerprint)
            var capture: ImportedCaptureMetadata?
            func readMetadata(_ file: FileHandle, _ size: Int64) throws {
              guard needsMetadata else { return }
              try control.check()
              capture = try ImportedCaptureMetadata.read(from: file, size: size,
                extension: source.pathExtension, localDate: localDate)
              try control.check()
            }
            if session.mode == .copy {
              let sourceBefore = try FileSafety.stat(source)
              let work = session.managedContainerURL!.appendingPathComponent(
                "RAWMaster-" + session.id)
              let target = work.appendingPathComponent(try FileSafety.safeRelative(a.relativePath))
              let result = try FileSafety.verifiedCopy(
                source: source, target: target, expectedHash: previous,
                protectedRoots: protectedRoots,
                beforePublish: { try verifyDirectory(work.deletingLastPathComponent(), expectedManaged, message: "接入期间复制目标已变化。") },
                inspectSource: readMetadata,
                cancel: { try self.control.check() })
              guard sourceBefore == (try FileSafety.stat(source)) else {
                throw LibraryError.sourceChanged(source.path)
              }
              a.currentPath = result.0.path
              a.effectiveManagedPath = result.0.path
              a.contentHash = result.1
              a.fileSize = sourceBefore.size
            } else {
              let verified = try FileSafety.withStableRegularFile(at: source) { file, size in
                let digest = try FileSafety.hash(file, cancel: { try self.control.check() })
                if let previous, digest != previous { throw LibraryError.sourceChanged(source.path) }
                try readMetadata(file, size)
                return (digest, size)
              }
              a.currentPath = source.path
              a.contentHash = verified.0
              a.fileSize = verified.1
            }
            if let capture {
              a.width = capture.width
              a.height = capture.height
              a.camera = capture.camera
              a.capturedAt = capture.capturedAt
              a.captureClock = capture.clock
              a.cameraSerialDigest = capture.cameraSerialDigest
            }
            a.importState = .ready
            a.availability = .available
          }
          session.completed += 1
        } catch LibraryError.cancelled { throw LibraryError.cancelled } catch {
          a.importState = .failed
          a.error = error.localizedDescription
          if case LibraryError.sourceChanged = error {
            a.availability = .changed
          } else {
            a.availability =
              FileManager.default.fileExists(atPath: a.resolvedSourceURL.path)
              ? .available : .missing
          }
          session.failed += 1
        }
        try store.saveImportAsset(
          a, expectedSourceFingerprint: sourceFingerprint,
          expectedManagedFingerprint: managedFingerprint, session: session)
        assets[i] = a
        processed += 1
        progress(
          TaskProgress(
            title: "导入", completed: processed, total: session.discovered,
            message: a.error ?? a.filename))
      }
      session.status =
        (session.failed == 0 && session.scanCompleted == true) ? "completed" : "partial"
      try store.saveSession(session)
      // Pairing is part of this ingest run: keep the cross-connection lease and
      // active marker until automatic post-processing has finished.
      if let workflow = try store.loadWorkflows().first(where: { $0.id == session.id }), workflow.phase != .legacyHistory {
        try control.check()
        _ = try store.scanCapturePairs(sessionID: session.id)
      }
      return session
    } catch {
      session.status =
        (error as? LibraryError).map {
          if case .cancelled = $0 { return control.isPausing ? "paused" : "cancelled" }
          return "failed"
        } ?? "failed"
      if let registered = try? store.loadAssets(sessionID: session.id) {
        session.discovered = registered.count
        session.completed = registered.filter { $0.importState == .ready }.count
        session.failed = registered.filter { $0.importState == .failed }.count
      }
      try? store.saveSession(session)
      if session.status == "cancelled" || session.status == "paused" { return session }
      throw error
    }
  }
  private func readableHash(_ url: URL) throws -> String? {
    do { return try FileSafety.hash(url, cancel: { try self.control.check() }) } catch LibraryError
      .cancelled
    { throw LibraryError.cancelled } catch { return nil }
  }
}
