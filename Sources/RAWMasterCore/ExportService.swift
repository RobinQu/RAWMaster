import Foundation
import RAWMasterPhotoExport

public enum ExportCSVLayout: String, Codable, Sendable {
  /// Existing entry points keep their self-contained rows.
  case legacy
  /// Each row refers to the sibling JSON manifest for batch-level details.
  case photoRows
}

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
  public var formats: ExportFormats?
  public var requestedAssetIDs: [String]?
  public var missingFormats: [String]?
  public var allowedAssetIDs: [String]?
  public init(
    schemaVersion: Int = 2, createdAt: Date = Date(), status: String, sessions: [ImportSession],
    groups: [CaptureGroup] = [], items: [ExportManifestItem], formats: ExportFormats? = nil, requestedAssetIDs: [String]? = nil, missingFormats: [String]? = nil, allowedAssetIDs: [String]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.status = status
    self.sessions = sessions
    self.groups = groups
    self.items = items
    self.formats = formats; self.requestedAssetIDs = requestedAssetIDs; self.missingFormats = missingFormats
    self.allowedAssetIDs = allowedAssetIDs
  }
}

struct PreparedOriginalExport: Codable, Sendable {
  let manifest: ExportManifest
  let csvLayout: ExportCSVLayout
  let copyIDs: Set<String>
  let allowedIDs: Set<String>
}

public final class ExportService: @unchecked Sendable {
  let store: LibraryStore
  let control = JobControl()
  public init(store: LibraryStore) { self.store = store }
  public func cancel() { control.cancel() }
  public func exportAssets(
    ids: [String], destination: URL, manifestIDs: [String]? = nil, formats: ExportFormats = .allOriginals, allowedAssetIDs: [String]? = nil,
    csvLayout: ExportCSVLayout = .legacy,
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
              ids: ids, destination: destination, manifestIDs: manifestIDs, formats: formats, allowedAssetIDs: allowedAssetIDs,
              csvLayout: csvLayout, progress: progress)
          }.value
        } catch {
          progress(
            TaskProgress(title: "导出未完成", message: error.localizedDescription, isRunning: false))
          throw error
        }
      }, onCancel: { self.control.cancel() })
  }
  func prepareOriginalExport(
    ids: [String], manifestIDs: [String]?, formats: ExportFormats, allowedAssetIDs: [String]?,
    csvLayout: ExportCSVLayout, createdAt: Date
  ) throws -> PreparedOriginalExport {
    try store.withReadSnapshot {
      try prepareOriginalExportSnapshot(ids: ids, manifestIDs: manifestIDs, formats: formats, allowedAssetIDs: allowedAssetIDs,
        csvLayout: csvLayout, createdAt: createdAt)
    }
  }

  private func prepareOriginalExportSnapshot(
    ids: [String], manifestIDs: [String]?, formats: ExportFormats, allowedAssetIDs: [String]?,
    csvLayout: ExportCSVLayout, createdAt: Date
  ) throws -> PreparedOriginalExport {
    let selection = try store.exportSelection(ids: ids, formats: formats, allowedAssetIDs: allowedAssetIDs)
    let admitted = Set(try store.loadAdmissions().map(\.assetID))
    guard Set(manifestIDs ?? ids).isSubset(of: admitted) else { throw LibraryError.invalid("清单范围含未纳入项目的素材") }
    let allowed = allowedAssetIDs.map { Set($0).intersection(admitted) } ?? admitted
    guard Set(manifestIDs ?? ids).isSubset(of: allowed) else { throw LibraryError.invalid("清单范围超出当前筛选范围") }
    let copyIDs = Set(selection.assetIDs)
    let scope = Set(manifestIDs ?? ids).union(copyIDs)
    guard scope.count <= PhotoExportKernel.maximumBatchPhotos else {
      throw LibraryError.invalid("每批最多可交付 \(PhotoExportKernel.maximumBatchPhotos) 张照片，请缩小选片范围。")
    }
    try PhotoExportKernel.validatePhotoCount(scope.count)
    let sorted = try store.loadAssets().filter { scope.contains($0.id) }
    guard scope.count == sorted.count else {
      throw LibraryError.invalid("导出范围包含不存在的素材")
    }
    let sessionIDs = Set(sorted.map(\.sessionID))
    let sessions = try store.loadSessions().filter { sessionIDs.contains($0.id) }
    let groups = try store.loadGroups().filter { !Set($0.assetIDs).isDisjoint(with: scope) }.map { original -> CaptureGroup in
      var group = original
      group.assetIDs = group.assetIDs.filter { allowed.contains($0) }
      group.includedAssetIDs = group.includedAssetIDs.filter { allowed.contains($0) }
      return group
    }
    let items = sorted.map { asset in
      let copy = copyIDs.contains(asset.id)
      return ExportManifestItem(asset: asset, copyRequested: copy, status: copy ? "pending" : "notRequested")
    }
    let manifest = ExportManifest(createdAt: createdAt, status: "pending", sessions: sessions, groups: groups, items: items,
      formats: formats, requestedAssetIDs: Array(Set(ids)).sorted(), missingFormats: selection.missingFormats,
      allowedAssetIDs: allowedAssetIDs.map { Array(Set($0).intersection(admitted)).sorted() })
    return .init(manifest: manifest, csvLayout: csvLayout, copyIDs: copyIDs, allowedIDs: allowed)
  }

  func protectedOriginalExportRoots() throws -> [URL] {
    let sessions = try store.loadSessions()
    return try store.protectedSourceRoots()
      + sessions.compactMap { $0.destinationPath.map { URL(fileURLWithPath: $0) } }
      + sessions.compactMap { $0.managedContainerURL }
      + store.loadAssets().map { $0.resolvedURL }
      + (try store.loadRelocationSessions()).filter { $0.role == .managed && $0.committedCount > 0 }
      .map { URL(fileURLWithPath: $0.rootPath) }
  }

  private func run(
    ids: [String], destination: URL, manifestIDs: [String]?, formats: ExportFormats, allowedAssetIDs: [String]?, csvLayout: ExportCSVLayout,
    progress: @escaping @Sendable (TaskProgress) -> Void
  ) throws -> ExportReport {
    let plan = try prepareOriginalExport(ids: ids, manifestIDs: manifestIDs, formats: formats, allowedAssetIDs: allowedAssetIDs,
      csvLayout: csvLayout, createdAt: .now)
    let roots = try protectedOriginalExportRoots()
    try FileSafety.checkTarget(destination, sources: roots)
    // A selected folder is a container; outputs stay in a stable separate tree for safe retry.
    let output = FileSafety.canonical(destination).appendingPathComponent("RAWMaster精选")
    try FileSafety.checkTarget(output, sources: roots)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var report = ExportReport(destinationPath: output.path)
    report.errors = plan.manifest.missingFormats ?? []
    report.failed = report.errors.count
    var items: [ExportManifestItem] = []
    var processed = 0
    var cancelled = false
    defer {
      progress(
        TaskProgress(
          title: "导出", completed: processed, total: plan.copyIDs.count,
          message: cancelled ? "已取消，已完成文件保留" : (report.failed == 0 ? "完成" : "部分失败"),
          isRunning: false))
    }
    for var item in plan.manifest.items {
      let a = item.asset
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
            title: "复制精选原片", completed: processed, total: plan.copyIDs.count,
            message: item.error ?? a.relativePath))
      }
      items.append(item)
    }
    var manifest = plan.manifest
    manifest.createdAt = .now
    manifest.status = cancelled ? "cancelled" : (report.failed > 0 ? "partial" : "completed")
    manifest.items = items
    let stem = "selection-" + UUID().uuidString
    let jsonURL = output.appendingPathComponent(stem + ".json")
    let csvURL = output.appendingPathComponent(stem + ".csv")
    try FileSafety.checkTarget(jsonURL, sources: roots)
    try FileSafety.checkTarget(csvURL, sources: roots)
    let data = try Self.manifestFiles(manifest, layout: csvLayout, allowedIDs: plan.allowedIDs, jsonName: jsonURL.lastPathComponent)
    try data.json.write(to: jsonURL, options: .withoutOverwriting)
    try data.csv.write(to: csvURL, options: .withoutOverwriting)
    report.manifestPath = jsonURL.path
    return report
  }

  static func manifestFiles(_ manifest: ExportManifest, layout: ExportCSVLayout, allowedIDs: Set<String>,
                            jsonName: String) throws -> (json: Data, csv: Data) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let json = try encoder.encode(manifest)
    let photoColumns = [
      "assetID", "sessionID", "sourcePath", "currentPath", "relativePath", "decision", "rating",
      "copyRequested", "status", "outputPath", "error", "sha256", "groupMembershipJSON", "requestedFormats",
    ]
    func quote(_ s: String) -> String {
      "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    func membershipJSON(_ id: String) -> String {
      let membership = manifest.groups.filter { $0.assetIDs.contains(id) }.map { g in
        [
          "groupID": g.id, "position": String(g.assetIDs.firstIndex(of: id) ?? 0),
          "included": String(g.includedAssetIDs.contains(id)),
        ]
      }
      let membershipEncoder = JSONEncoder()
      membershipEncoder.outputFormatting = [.sortedKeys]
      return String(decoding: (try? membershipEncoder.encode(membership)) ?? Data("[]".utf8), as: UTF8.self)
    }
    let headers: [String]
    let scopeColumns: (ExportManifestItem) -> [String]
    switch layout {
    case .legacy:
      headers = photoColumns + ["requestedAssetIDsJSON", "missingFormatsJSON", "allowedAssetIDsJSON"]
      let requested = String(decoding: try JSONEncoder().encode(manifest.requestedAssetIDs), as: UTF8.self)
      let missing = String(decoding: try JSONEncoder().encode(manifest.missingFormats ?? []), as: UTF8.self)
      let allowed = String(decoding: try JSONEncoder().encode(manifest.allowedAssetIDs), as: UTF8.self)
      scopeColumns = { _ in [requested, missing, allowed] }
    case .photoRows:
      headers = photoColumns + ["csvSchemaVersion", "explicitlyRequested", "inAllowedScope", "batchManifest"]
      let requested = Set(manifest.requestedAssetIDs ?? [])
      scopeColumns = { item in
        ["3", String(requested.contains(item.asset.id)), String(allowedIDs.contains(item.asset.id)), jsonName]
      }
    }
    let csv =
      ([headers]
      + manifest.items.map { i in
        [
          i.asset.id, i.asset.sessionID, i.asset.sourcePath, i.asset.currentPath,
          i.asset.relativePath, i.asset.decision.rawValue, String(i.asset.rating),
          String(i.copyRequested), i.status, i.outputPath ?? "", i.error ?? "",
          i.asset.contentHash ?? "", membershipJSON(i.asset.id), (manifest.formats ?? .allOriginals).rawValue,
        ] + scopeColumns(i)
      }).map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    return (json, Data(csv.utf8))
  }
}
