import Foundation

public struct ExportManifestItem: Codable, Sendable {
  public var asset: AssetRecord
  public var copyRequested: Bool
  public var status: String
  public var outputPath: String?
  public var error: String?
  public init(
    asset: AssetRecord, copyRequested: Bool, status: String, outputPath: String? = nil,
    error: String? = nil
  ) {
    self.asset = asset
    self.copyRequested = copyRequested
    self.status = status
    self.outputPath = outputPath
    self.error = error
  }
}
public struct ExportManifest: Codable, Sendable {
  public var schemaVersion: Int = 2
  public var createdAt: Date
  public var status: String
  public var sessions: [ImportSession]
  public var groups: [CaptureGroup]
  public var items: [ExportManifestItem]
  public init(
    schemaVersion: Int = 2, createdAt: Date = Date(), status: String, sessions: [ImportSession],
    groups: [CaptureGroup] = [], items: [ExportManifestItem]
  ) {
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.status = status
    self.sessions = sessions
    self.groups = groups
    self.items = items
  }
}
public final class ExportService: @unchecked Sendable {
  private let store: LibraryStore
  private let control = JobControl()
  public init(store: LibraryStore) { self.store = store }
  public func cancel() { control.cancel() }
  public func exportAssets(
    ids: [String], destination: URL, manifestIDs: [String]? = nil,
    progress: @escaping @Sendable (TaskProgress) -> Void
  ) async throws -> ExportReport {
    try control.begin()
    defer { control.finish() }
    return try await withTaskCancellationHandler(
      operation: {
        do {
          try Task.checkCancellation()
          return try await Task.detached(priority: .userInitiated) { [self] in
            try run(
              ids: ids, destination: destination, manifestIDs: manifestIDs, progress: progress)
          }.value
        } catch {
          progress(
            TaskProgress(title: "导出未完成", message: error.localizedDescription, isRunning: false))
          throw error
        }
      }, onCancel: { self.control.cancel() })
  }
  private func run(
    ids: [String], destination: URL, manifestIDs: [String]?,
    progress: @escaping @Sendable (TaskProgress) -> Void
  ) throws -> ExportReport {
    let all = try store.loadAssets()
    let sessions = try store.loadSessions()
    let copyIDs = Set(ids)
    let scope = Set(manifestIDs ?? ids).union(copyIDs)
    guard copyIDs.isSubset(of: Set(all.map(\.id))), scope.isSubset(of: Set(all.map(\.id))) else {
      throw LibraryError.invalid("导出范围包含不存在的素材")
    }
    let roots =
      try store.protectedSourceRoots()
      + sessions.compactMap { $0.destinationPath.map { URL(fileURLWithPath: $0) } }
      + sessions.compactMap { $0.managedContainerURL }
      + all.map { $0.resolvedURL }
      + (try store.loadRelocationSessions()).filter { $0.role == .managed && $0.committedCount > 0 }
      .map { URL(fileURLWithPath: $0.rootPath) }
    try FileSafety.checkTarget(destination, sources: roots)
    // A selected folder is a container; outputs stay in a stable separate tree for safe retry.
    let output = FileSafety.canonical(destination).appendingPathComponent("RAWMaster精选")
    try FileSafety.checkTarget(output, sources: roots)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var report = ExportReport(destinationPath: output.path)
    var items: [ExportManifestItem] = []
    var processed = 0
    var cancelled = false
    defer {
      progress(
        TaskProgress(
          title: "导出", completed: processed, total: copyIDs.count,
          message: cancelled ? "已取消，已完成文件保留" : (report.failed == 0 ? "完成" : "部分失败"),
          isRunning: false))
    }
    let sorted = all.filter { scope.contains($0.id) }
    let groups = try store.loadGroups().filter { !Set($0.assetIDs).isDisjoint(with: scope) }
    for a in sorted {
      var item = ExportManifestItem(
        asset: a, copyRequested: copyIDs.contains(a.id), status: "notRequested", outputPath: nil,
        error: nil)
      if item.copyRequested {
        do {
          try control.check()
          guard a.importState == .ready else {
            throw LibraryError.invalid("素材导入尚未完成：\(a.filename)")
          }
          _ = try FileSafety.stat(a.resolvedURL)
          let path = try FileSafety.safeRelative(a.relativePath)
          // Session scope preserves identical relative names from distinct sources.
          let target = output.appendingPathComponent(a.sessionID).appendingPathComponent(path)
          let result = try FileSafety.verifiedCopy(
            source: a.resolvedURL, target: target, expectedHash: a.contentHash,
            protectedRoots: roots, cancel: { try self.control.check() })
          item.status = "copied"
          item.outputPath = result.0.path
          report.copied += 1
        } catch LibraryError.cancelled {
          item.status = "cancelled"
          item.error = "已取消"
          cancelled = true
          report.failed += 1
          report.errors.append("\(a.relativePath)：已取消")
        } catch {
          item.status = "failed"
          item.error = error.localizedDescription
          report.failed += 1
          report.errors.append("\(a.relativePath)：\(error.localizedDescription)")
        }
        processed += 1
        progress(
          TaskProgress(
            title: "复制精选原片", completed: processed, total: copyIDs.count,
            message: item.error ?? a.relativePath))
      }
      items.append(item)
    }
    let manifest = ExportManifest(
      createdAt: Date(),
      status: cancelled ? "cancelled" : (report.failed > 0 ? "partial" : "completed"),
      sessions: sessions.filter { s in sorted.contains { $0.sessionID == s.id } }, groups: groups,
      items: items)
    let stem = "selection-" + UUID().uuidString
    let jsonURL = output.appendingPathComponent(stem + ".json")
    let csvURL = output.appendingPathComponent(stem + ".csv")
    try FileSafety.checkTarget(jsonURL, sources: roots)
    try FileSafety.checkTarget(csvURL, sources: roots)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: jsonURL, options: .withoutOverwriting)
    let headers = [
      "assetID", "sessionID", "sourcePath", "currentPath", "relativePath", "decision", "rating",
      "copyRequested", "status", "outputPath", "error", "sha256", "groupMembershipJSON",
    ]
    func quote(_ s: String) -> String {
      "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    func membershipJSON(_ id: String) -> String {
      let membership = groups.filter { $0.assetIDs.contains(id) }.map { g in
        [
          "groupID": g.id, "position": String(g.assetIDs.firstIndex(of: id) ?? 0),
          "included": String(g.includedAssetIDs.contains(id)),
        ]
      }
      return String(
        decoding: (try? JSONEncoder().encode(membership)) ?? Data("[]".utf8), as: UTF8.self)
    }
    let csv =
      ([headers]
      + items.map { i in
        [
          i.asset.id, i.asset.sessionID, i.asset.sourcePath, i.asset.currentPath,
          i.asset.relativePath, i.asset.decision.rawValue, String(i.asset.rating),
          String(i.copyRequested), i.status, i.outputPath ?? "", i.error ?? "",
          i.asset.contentHash ?? "", membershipJSON(i.asset.id),
        ]
      }).map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    try Data(csv.utf8).write(to: csvURL, options: .withoutOverwriting)
    report.manifestPath = jsonURL.path
    return report
  }
}
