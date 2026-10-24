import Foundation

/// Read-only evidence gathering; only confirm changes asset positions.
public final class RelocationService: @unchecked Sendable {
  private let store: LibraryStore
  private let control = JobControl()
  public init(store: LibraryStore) { self.store = store }
  public func cancel() { control.cancel() }
  public func scan(
    sessionID: String, assetIDs: [String]? = nil, root: URL, role: RelocationRole,
    progress: @escaping @Sendable (TaskProgress) -> Void
  ) async throws -> RelocationSession {
    try await execute(progress: progress) { [self] in
      guard let original = try store.loadSessions().first(where: { $0.id == sessionID }) else {
        throw LibraryError.invalid("导入会话不存在")
      }
      if role == .managed && original.mode != .copy { throw LibraryError.invalid("原地接入请找回来源位置") }
      let all = try store.loadAssets(sessionID: sessionID)
      if let assetIDs {
        guard Set(assetIDs).isSubset(of: Set(all.map(\.id))) else {
          throw LibraryError.invalid("查找范围不能跨导入会话")
        }
      }
      let assets = all.filter { assetIDs == nil || assetIDs!.contains($0.id) }
      guard !assets.isEmpty else { throw LibraryError.invalid("没有可查找的素材") }
      guard assets.count <= 30000,
        assets.reduce(
          0,
          {
            $0 + LocationIdentity.path($1, role: role).utf8.count * 2 + $1.filename.utf8.count + 512
          }) <= 8 * 1024 * 1024
      else { throw LibraryError.invalid("本次范围超过找回任务内存预算，请分批选择素材") }
      let scanRoot = FileSafety.canonical(root)
      var selected = scanRoot
      if role == .managed && selected.lastPathComponent == "RAWMaster-" + sessionID {
        selected = selected.deletingLastPathComponent()
      }
      let items = assets.map { a in
        RelocationItem(
          assetID: a.id, filename: a.filename,
          assetFingerprint: LocationIdentity.fingerprint(a, role: role),
          oldPath: LocationIdentity.path(a, role: role),
          oldPathWasAvailable: FileManager.default.fileExists(
            atPath: LocationIdentity.path(a, role: role)))
      }
      let session = RelocationSession(
        importSessionID: sessionID, rootPath: selected.path, role: role, items: items,
        scanRootPath: scanRoot.path)
      try store.saveRelocationSession(session)
      return try runScan(session, progress: progress)
    }
  }
  public func resume(id: String, progress: @escaping @Sendable (TaskProgress) -> Void) async throws
    -> RelocationSession
  {
    try await execute(progress: progress) { [self] in
      let saved = try store.relocationSession(id)
      if saved.status == "completed" {
        progress(
          TaskProgress(
            title: "找回原片", completed: saved.committedCount, total: saved.items.count,
            message: "已完成，无需重复提交", isRunning: false))
        return saved
      }
      return try runScan(saved, progress: progress)
    }
  }
  @discardableResult public func chooseCandidate(sessionID: String, assetID: String, path: String?)
    throws -> RelocationSession
  {
    try store.chooseRelocationCandidate(sessionID: sessionID, assetID: assetID, path: path)
  }
  public func confirm(sessionID: String, progress: @escaping @Sendable (TaskProgress) -> Void)
    async throws -> RelocationSession
  {
    try await execute(progress: progress) { [self] in try runConfirm(sessionID, progress: progress)
    }
  }
  private func execute(
    progress: @escaping @Sendable (TaskProgress) -> Void,
    body: @escaping @Sendable () throws -> RelocationSession
  ) async throws -> RelocationSession {
    try control.begin()
    defer { control.finish() }
    return try await withTaskCancellationHandler(
      operation: {
        do {
          try Task.checkCancellation()
          return try await Task.detached(priority: .utility, operation: body).value
        } catch {
          progress(
            TaskProgress(title: "找回原片未完成", message: error.localizedDescription, isRunning: false))
          throw error
        }
      }, onCancel: { self.control.cancel() })
  }
  private func runScan(
    _ previous: RelocationSession, progress: @escaping @Sendable (TaskProgress) -> Void
  ) throws -> RelocationSession {
    var session = previous
    session.status = "scanning"
    session.scanComplete = false
    session.scannedFiles = 0
    try store.saveRelocationSession(session)
    defer {
      progress(
        TaskProgress(
          title: "只读查找", completed: session.scannedFiles, total: session.scannedFiles,
          message: session.message, isRunning: false))
    }
    do {
      let root = FileSafety.canonical(
        URL(fileURLWithPath: session.scanRootPath ?? session.rootPath))
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
        directory.boolValue
      else { throw LibraryError.invalid("查找目录不可用") }
      let assets = try store.loadAssets(sessionID: session.importSessionID)
      let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
      let cached = Dictionary(
        previous.items.flatMap(\.candidates).map { ($0.path, $0) },
        uniquingKeysWith: { first, _ in first })
      let wantedNames = Set(session.items.map(\.filename))
      var indicesByHash: [String: [Int]] = [:]
      var neededSizes = Set<Int64>()
      var neededHashes = Set<String>()
      for i in session.items.indices {
        guard session.items[i].status != .committed else { continue }
        guard let a = byID[session.items[i].assetID] else {
          session.items[i].status = .stale
          continue
        }
        if LocationIdentity.fingerprint(a, role: session.role) != session.items[i].assetFingerprint
        {
          session.items[i].status = .stale
          session.items[i].message = "原位置或内容身份已改变，请新建查找"
          session.items[i].selectedPath = nil
          continue
        }
        session.items[i].candidates = []
        session.items[i].selectedPath = nil
        guard let hash = a.contentHash, !hash.isEmpty else {
          session.items[i].status = .noHash
          session.items[i].message = "没有旧 SHA256，不能自动继承身份"
          continue
        }
        neededSizes.insert(a.fileSize)
        neededHashes.insert(hash)
        indicesByHash[hash, default: []].append(i)
        session.items[i].status = .missing
      }
      // Index only useful-size files; cap retained path/evidence memory rather than loading file bytes.
      var matches: [String: [RelocationCandidate]] = [:]
      var named = Set<String>()
      var unreadable = Set<String>()
      var retainedBytes = try JSONEncoder().encode(session).count
      var scanError: String?
      guard
        let iterator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
          errorHandler: { _, error in
            scanError = error.localizedDescription
            return true
          })
      else { throw LibraryError.invalid("无法扫描所选目录") }
      for case let listed as URL in iterator {
        try control.check()
        let path = FileSafety.canonical(listed)
        guard FileSafety.contains(root, path) else { continue }
        guard let stamp = try? FileSafety.stat(path) else { continue }
        if wantedNames.contains(path.lastPathComponent) { named.insert(path.lastPathComponent) }
        guard neededSizes.contains(stamp.size) else { continue }
        session.scannedFiles += 1
        do {
          let hash: String
          if let evidence = cached[path.path],
            evidence.fileFingerprint == LocationIdentity.stamp(stamp)
          {
            hash = evidence.contentHash
          } else {
            hash = try FileSafety.hash(path, cancel: { try self.control.check() })
          }
          guard FileSafety.contains(root, path), try FileSafety.stat(path) == stamp else {
            throw LibraryError.sourceChanged(path.path)
          }
          if neededHashes.contains(hash), matches[hash, default: []].count < 100 {
            let relative = String(path.path.dropFirst(root.path.count + 1))
            _ = try FileSafety.safeRelative(relative)
            let candidate = RelocationCandidate(
              path: path.path, relativePath: relative, contentHash: hash,
              fileFingerprint: LocationIdentity.stamp(stamp))
            if !(matches[hash] ?? []).contains(where: { $0.path == candidate.path }) {
              let cost =
                (try JSONEncoder().encode(candidate).count
                  + JSONEncoder().encode(candidate.path).count + 256)
                * (indicesByHash[hash]?.count ?? 0)
              if retainedBytes + cost > 24 * 1024 * 1024 {
                scanError = "候选报告达到内存上限（重复候选按全部受影响素材计量），请缩小范围重试"
                break
              }
              matches[hash, default: []].append(candidate)
              retainedBytes += cost
              for index in indicesByHash[hash] ?? [] {
                session.items[index].candidates = matches[hash] ?? []
              }
            }
          }
        } catch LibraryError.cancelled { throw LibraryError.cancelled } catch {
          if wantedNames.contains(path.lastPathComponent) {
            unreadable.insert(path.lastPathComponent)
          }
        }
        if retainedBytes > 24 * 1024 * 1024 {
          scanError = "候选证据达到内存上限，请缩小目录后重试"
          break
        }
        if session.scannedFiles.isMultiple(of: 16) { try store.saveRelocationSession(session) }
        progress(
          TaskProgress(
            title: "只读查找", completed: session.scannedFiles, total: 0,
            message: path.lastPathComponent))
      }
      try control.check()
      for i in session.items.indices {
        guard let a = byID[session.items[i].assetID],
          [.missing, .matched, .ambiguous, .differentContent, .unreadable].contains(
            session.items[i].status)
        else { continue }
        let candidates = (matches[a.contentHash ?? ""] ?? []).sorted { $0.path < $1.path }
        session.items[i].candidates = candidates
        if candidates.count == 1 {
          session.items[i].status = .matched
          session.items[i].selectedPath = scanError == nil ? candidates[0].path : nil
          session.items[i].message = scanError == nil ? "完整 SHA256 相同" : "扫描不完整；内容相同，但需明确选择位置"
        } else if candidates.count > 1 {
          session.items[i].status = .ambiguous
          session.items[i].message = "找到多处相同内容，请明确选择位置"
        } else if unreadable.contains(a.filename) {
          session.items[i].status = .unreadable
          session.items[i].message = "同名候选无法读取或读取中变化"
        } else if named.contains(a.filename) {
          session.items[i].status = .differentContent
          session.items[i].message = "同名文件不是已登记内容"
        } else {
          session.items[i].status = .missing
          session.items[i].message = "未找到相同 SHA256"
        }
      }
      try control.check()
      session.scanComplete = scanError == nil
      session.status = "review"
      session.message = scanError ?? "查找完成；确认前不会修改位置"
      try store.saveRelocationSession(session)
      return session
    } catch {
      session.status =
        (error as? LibraryError).map {
          if case .cancelled = $0 { return "cancelled" }
          return "failed"
        } ?? "failed"
      session.message = error.localizedDescription
      try? store.saveRelocationSession(session)
      if session.status == "cancelled" { return session }
      throw error
    }
  }
  private func runConfirm(_ id: String, progress: @escaping @Sendable (TaskProgress) -> Void) throws
    -> RelocationSession
  {
    var session = try store.relocationSession(id)
    guard session.status == "review" || session.status == "partial" else {
      throw LibraryError.invalid("请先完成或恢复查找；取消的任务不能直接提交")
    }
    let root = URL(fileURLWithPath: session.scanRootPath ?? session.rootPath)
    var verified: [VerifiedRelocation] = []
    defer {
      progress(
        TaskProgress(
          title: "核验并找回", completed: session.committedCount, total: session.items.count,
          message: session.message, isRunning: false))
    }
    do {
      for i in session.items.indices {
        try control.check()
        guard let selected = session.items[i].selectedPath,
          [.matched, .ambiguous].contains(session.items[i].status),
          let candidate = session.items[i].candidates.first(where: { $0.path == selected })
        else { continue }
        do {
          let url = URL(fileURLWithPath: selected)
          guard FileSafety.contains(root, url) else { throw LibraryError.invalid("候选已越出所选目录") }
          if !session.items[i].oldPathWasAvailable
            && FileManager.default.fileExists(atPath: session.items[i].oldPath)
          {
            if (try readableHash(URL(fileURLWithPath: session.items[i].oldPath)))
              == candidate.contentHash
            {
              throw LibraryError.invalid("旧位置已恢复，请重新查找后确认")
            }
          }
          let stamp = try FileSafety.stat(url)
          let hash = try FileSafety.hash(url, cancel: { try self.control.check() })
          guard hash == candidate.contentHash, try FileSafety.stat(url) == stamp,
            FileSafety.contains(root, url)
          else { throw LibraryError.sourceChanged(selected) }
          var refreshed = candidate
          refreshed.fileFingerprint = LocationIdentity.stamp(stamp)
          verified.append(
            VerifiedRelocation(
              assetID: session.items[i].assetID,
              expectedFingerprint: session.items[i].assetFingerprint, candidate: refreshed,
              oldPathMustRemainUnavailable: session.items[i].oldPathWasAvailable
                ? nil : session.items[i].oldPath))
        } catch LibraryError.cancelled { throw LibraryError.cancelled } catch {
          session.items[i].status = .stale
          session.items[i].message = error.localizedDescription
        }
        progress(
          TaskProgress(
            title: "核验并找回", completed: verified.count, total: session.matchedCount,
            message: session.items[i].filename))
      }
      try control.check()
      session = try store.commitRelocation(
        session, verified: verified, cancelled: { try self.control.check() })
      return session
    } catch {
      if case LibraryError.cancelled = error {
        session.status = "cancelled"
      } else {
        session.status = "failed"
      }
      session.message = error.localizedDescription
      try? store.saveRelocationSession(session)
      if case LibraryError.cancelled = error { return session }
      throw error
    }
  }
  private func readableHash(_ url: URL) throws -> String? {
    do { return try FileSafety.hash(url, cancel: { try self.control.check() }) } catch LibraryError
      .cancelled
    { throw LibraryError.cancelled } catch { return nil }
  }
}
