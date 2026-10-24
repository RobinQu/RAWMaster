import Foundation

extension LibraryStore {
  func adoptDiscoveredSource(assetID: String, path: String, expectedFingerprint: String) throws {
    try transaction {
      var a = try asset(assetID)
      guard LocationIdentity.fingerprint(a, role: .source) == expectedFingerprint else {
        throw LibraryError.invalid("来源位置已改变，请重新接入")
      }
      guard let session = try loadSessions().first(where: { $0.id == a.sessionID }) else {
        throw LibraryError.invalid("导入会话不存在")
      }
      a.effectiveSourcePath = path
      if session.mode == .reference { a.currentPath = path }
      try changeAsset(a, action: "rediscoverSource")
    }
  }
  public func loadRelocationSessions() throws -> [RelocationSession] {
    try locked {
      try rows("SELECT data FROM relocation_sessions ORDER BY rowid DESC").map {
        try decode($0[0], RelocationSession.self)
      }
    }
  }
  func saveRelocationSession(_ session: RelocationSession) throws {
    try transaction { try writeRelocationSession(session) }
  }
  private func writeRelocationSession(_ session: RelocationSession) throws {
    try statement(
      "INSERT INTO relocation_sessions VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
      [session.id, try json(session)])
  }
  func relocationSession(_ id: String) throws -> RelocationSession {
    guard let session = try loadRelocationSessions().first(where: { $0.id == id }) else {
      throw LibraryError.invalid("找回任务不存在")
    }
    return session
  }
  func chooseRelocationCandidate(sessionID: String, assetID: String, path: String?) throws
    -> RelocationSession
  {
    try transaction {
      var session = try relocationSession(sessionID)
      guard session.status == "review" || session.status == "partial" else {
        throw LibraryError.invalid("请先完成或恢复查找")
      }
      guard let index = session.items.firstIndex(where: { $0.assetID == assetID }) else {
        throw LibraryError.invalid("素材不在本次范围内")
      }
      if let path {
        guard session.items[index].candidates.contains(where: { $0.path == path }),
          [.matched, .ambiguous].contains(session.items[index].status)
        else { throw LibraryError.invalid("候选未通过内容身份核验") }
      }
      session.items[index].selectedPath = path
      try writeRelocationSession(session)
      return session
    }
  }
  /// Files are hashed by the caller before this short atomic compare-and-set transaction.
  func commitRelocation(
    _ proposed: RelocationSession, verified: [VerifiedRelocation], cancelled: () throws -> Void
  ) throws -> RelocationSession {
    try transaction {
      try cancelled()
      let saved = try relocationSession(proposed.id)
      guard saved.status == "review" || saved.status == "partial" || saved.status == "committing"
      else { throw LibraryError.invalid("查找任务状态已改变，请刷新") }
      guard
        let importSession = try loadSessions().first(where: { $0.id == proposed.importSessionID })
      else { throw LibraryError.invalid("导入会话不存在") }
      var result = proposed
      var newlyCommitted = Set<String>()
      for evidence in verified {
        try cancelled()
        guard let index = result.items.firstIndex(where: { $0.assetID == evidence.assetID }) else {
          continue
        }
        // Choice changes during hashing must not be silently committed.
        guard
          saved.items.first(where: { $0.assetID == evidence.assetID })?.selectedPath
            == evidence.candidate.path
        else {
          result.items[index].status = .stale
          result.items[index].message = "候选选择已改变，请重新确认"
          continue
        }
        var a = try asset(evidence.assetID)
        guard a.sessionID == result.importSessionID,
          LocationIdentity.fingerprint(a, role: result.role) == evidence.expectedFingerprint
        else {
          result.items[index].status = .stale
          result.items[index].message = "素材位置或内容身份已改变，请重新查找"
          continue
        }
        let url = URL(fileURLWithPath: evidence.candidate.path)
        let root = URL(fileURLWithPath: result.scanRootPath ?? result.rootPath)
        guard FileSafety.contains(root, url), let stamp = try? FileSafety.stat(url),
          LocationIdentity.stamp(stamp) == evidence.candidate.fileFingerprint
        else {
          result.items[index].status = .stale
          result.items[index].message = "候选文件在核验后发生变化"
          continue
        }
        if let oldPath = evidence.oldPathMustRemainUnavailable,
          FileManager.default.fileExists(atPath: oldPath)
        {
          result.items[index].status = .stale
          result.items[index].message = "旧位置在核验后恢复，请重新查找确认"
          continue
        }
        if result.role == .source {
          a.effectiveSourcePath = evidence.candidate.path
          if importSession.mode == .reference {
            a.currentPath = evidence.candidate.path
            a.availability = .available
            a.importState = .ready
            a.error = nil
          }
        } else {
          guard importSession.mode == .copy else { throw LibraryError.invalid("原地接入没有受管副本角色") }
          a.effectiveManagedPath = evidence.candidate.path
          a.currentPath = evidence.candidate.path
          a.availability = .available
          a.importState = .ready
          a.error = nil
        }
        try changeAsset(a, action: "relocate." + result.role.rawValue)
        newlyCommitted.insert(a.id)
        result.items[index].status = .committed
        result.items[index].message = "已恢复同一内容的位置"
      }
      // Root defaults apply ONLY to future discovery. Existing unresolved assets keep explicit paths.
      let allAssets = try loadAssets(sessionID: importSession.id)
      var updated = importSession
      let selectedRoot = FileSafety.canonical(URL(fileURLWithPath: result.rootPath))
      let proven = result.items.filter {
        $0.status == .committed && newlyCommitted.contains($0.assetID)
      }
      let canUseRoot = proven.contains { item in
        guard let a = allAssets.first(where: { $0.id == item.assetID }),
          let path = item.selectedPath
        else { return false }
        let base =
          result.role == .managed
          ? selectedRoot.appendingPathComponent("RAWMaster-" + importSession.id) : selectedRoot
        return LocationIdentity.path(a, role: result.role) == path
          && FileSafety.canonical(base.appendingPathComponent(a.relativePath)).path == path
      }
      if canUseRoot {
        if result.role == .source {
          updated.effectiveSourceRoot = selectedRoot.path
        } else {
          updated.effectiveManagedRoot = selectedRoot.path
        }
        try statement("UPDATE sessions SET data=? WHERE id=?", [try json(updated), updated.id])
      }
      let unresolved = result.items.filter { $0.status != .committed }
      result.status = unresolved.isEmpty ? "completed" : "partial"
      result.message = "已恢复 \(result.committedCount) / \(result.items.count) 项"
      try writeRelocationSession(result)
      try operation(entity: result.id, action: "relocationCommit", payload: try json(result))
      try cancelled()
      return result
    }
  }
  /// Effective and historical source positions both remain protected from writes.
  func protectedSourceRoots() throws -> [URL] {
    let sessions = try loadSessions()
    let assets = try loadAssets()
    let relocated = try loadRelocationSessions().filter {
      $0.role == .source && $0.committedCount > 0
    }.map { URL(fileURLWithPath: $0.rootPath) }
    return sessions.flatMap { [$0.sourceURL, $0.effectiveSourceURL] } + relocated
      + assets.flatMap { [URL(fileURLWithPath: $0.sourcePath), $0.resolvedSourceURL] }
  }
}
