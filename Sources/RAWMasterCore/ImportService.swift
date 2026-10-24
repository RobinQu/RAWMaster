import Foundation
import ImageIO

public final class ImportService: @unchecked Sendable {
  private let store: LibraryStore
  private let postIngest: ImportPostIngestCallback?
  private let control = JobControl()
  private static let extensions: Set<String> = [
    "arw", "dng", "raw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "jpg", "jpeg", "heic", "tif",
    "tiff",
  ]
  public init(store: LibraryStore, postIngest: ImportPostIngestCallback? = nil) {
    self.store = store
    self.postIngest = postIngest
  }
  public func cancel() { control.cancel() }
  public func importDirectory(
    source: URL, destination: URL?, projectName: String, mode: ImportMode, projectID: String? = nil,
    progress: @escaping @Sendable (TaskProgress) -> Void
  ) async throws -> ImportSession {
    return try await execute(progress: progress) { [self] in
      let root = FileSafety.canonical(source)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw LibraryError.invalid("源目录不可用：\(root.path)") }
      if mode == .copy {
        guard let destination else { throw LibraryError.invalid("请选择复制目标目录") }
        try FileSafety.checkTarget(destination, sources: try store.protectedSourceRoots() + [root])
      }
      let projects = try store.loadProjects()
      let project: ProjectRecord
      if let projectID {
        guard let p = projects.first(where: { $0.id == projectID }) else {
          throw LibraryError.invalid("项目不存在")
        }
        project = p
      } else {
        project = ProjectRecord(name: projectName.isEmpty ? root.lastPathComponent : projectName)
        try store.saveProject(project)
      }
      // Reopening a source in its existing project continues its original mode and destination.
      let existing = try store.loadSessions().first {
        $0.projectID == project.id
          && (FileSafety.canonical($0.sourceURL) == root
            || FileSafety.canonical($0.effectiveSourceURL) == root)
      }
      if let existing {
        guard existing.mode == mode,
          (existing.effectiveManagedRoot ?? existing.destinationPath)
            == destination.map({ FileSafety.canonical($0).path })
        else { throw LibraryError.invalid("该来源已存在于此项目，接入方式或目标不同；请恢复原会话，或选择新项目") }
      }
      let session =
        existing
        ?? ImportSession(
          projectID: project.id, projectName: project.name, sourcePath: root.path,
          destinationPath: destination.map { FileSafety.canonical($0).path }, mode: mode)
      try store.saveSession(session)
      return try run(session, progress: progress)
    }
  }
  public func resume(sessionID: String, progress: @escaping @Sendable (TaskProgress) -> Void)
    async throws -> ImportSession
  {
    return try await execute(progress: progress) { [self] in
      guard let s = try store.loadSessions().first(where: { $0.id == sessionID }) else {
        throw LibraryError.invalid("导入会话不存在")
      }
      return try run(s, progress: progress)
    }
  }
  private func execute(
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
            await postIngest(result, { try self.control.check() }, progress)
          }
          return result
        } catch {
          progress(
            TaskProgress(title: "导入未完成", message: error.localizedDescription, isRunning: false))
          throw error
        }
      }, onCancel: { self.control.cancel() })
  }
  private func run(_ original: ImportSession, progress: @escaping @Sendable (TaskProgress) -> Void)
    throws -> ImportSession
  {
    var session = original
    session.status = "scanning"
    session.failed = 0
    try store.saveSession(session)
    let root = session.effectiveSourceURL
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
      if session.mode == .copy {
        guard let path = session.effectiveManagedRoot ?? session.destinationPath else {
          throw LibraryError.invalid("缺少复制目标目录")
        }
        try FileSafety.checkTarget(URL(fileURLWithPath: path), sources: protectedRoots)
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
        for case let url as URL in iterator {
          try control.check()
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
            _ = try store.register(record)
          }
          if processed % 32 == 0 {
            progress(TaskProgress(title: "扫描素材", completed: 0, total: 0, message: relative))
          }
          processed += 1
        }
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
              expectedManagedFingerprint: managedFingerprint)
            processed += 1
            try store.saveSession(session)
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
            let before = try FileSafety.stat(a.resolvedSourceURL)
            a.importState = session.mode == .copy ? .copying : .verifying
            a.error = nil
            try store.saveImportAsset(
              a, expectedSourceFingerprint: sourceFingerprint,
              expectedManagedFingerprint: managedFingerprint)
            let source = a.resolvedSourceURL
            if let previous = a.contentHash {
              let current = try FileSafety.hash(source, cancel: { try self.control.check() })
              guard previous == current else { throw LibraryError.sourceChanged(source.path) }
            }
            if session.mode == .copy {
              let work = session.managedContainerURL!.appendingPathComponent(
                "RAWMaster-" + session.id)
              let target = work.appendingPathComponent(try FileSafety.safeRelative(a.relativePath))
              let result = try FileSafety.verifiedCopy(
                source: source, target: target, expectedHash: a.contentHash,
                protectedRoots: protectedRoots,
                cancel: { try self.control.check() })
              a.currentPath = result.0.path
              a.effectiveManagedPath = result.0.path
              a.contentHash = result.1
            } else {
              a.currentPath = a.resolvedSourceURL.path
              a.contentHash = try FileSafety.hash(source, cancel: { try self.control.check() })
            }
            guard before == (try FileSafety.stat(source)) else {
              throw LibraryError.sourceChanged(source.path)
            }
            a.fileSize = before.size
            Self.metadata(source, into: &a)
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
          expectedManagedFingerprint: managedFingerprint)
        assets[i] = a
        processed += 1
        try store.saveSession(session)
        progress(
          TaskProgress(
            title: "导入", completed: processed, total: session.discovered,
            message: a.error ?? a.filename))
      }
      session.status =
        (session.failed == 0 && session.scanCompleted == true) ? "completed" : "partial"
      try store.saveSession(session)
      return session
    } catch {
      session.status =
        (error as? LibraryError).map {
          if case .cancelled = $0 { return "cancelled" }
          return "failed"
        } ?? "failed"
      if let registered = try? store.loadAssets(sessionID: session.id) {
        session.discovered = registered.count
        session.completed = registered.filter { $0.importState == .ready }.count
        session.failed = registered.filter { $0.importState == .failed }.count
      }
      try? store.saveSession(session)
      if session.status == "cancelled" { return session }
      throw error
    }
  }
  private func readableHash(_ url: URL) throws -> String? {
    do { return try FileSafety.hash(url, cancel: { try self.control.check() }) } catch LibraryError
      .cancelled
    { throw LibraryError.cancelled } catch { return nil }
  }
  private static func metadata(_ url: URL, into a: inout AssetRecord) {
    guard
      let image = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
    else { return }
    a.width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
    a.height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      a.camera = tiff[kCGImagePropertyTIFFModel] as? String
    }
    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
      let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
    {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyy:MM:dd HH:mm:ss"
      a.capturedAt = f.date(from: text)
    }
  }
}
