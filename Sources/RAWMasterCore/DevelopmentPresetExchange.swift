import CryptoKit
import Foundation

public struct PresetMigrationRule: Codable, Sendable {
  public let path: String
  public let sha256: String
  public let bytes: Int
}

public enum PresetInspectionStatus: String, Codable, Sendable {
  case ready, duplicate, conflict, changed, missing, ignored, rejected
}

public struct PresetInspectionItem: Codable, Identifiable, Sendable {
  public let id: Int
  public var path: String
  public var origin: String
  public var status: PresetInspectionStatus
  public var sha256: String?
  public var detail: String
}

public struct PresetExchangeStage: Sendable {
  public let batchID: String
  public let items: [PresetInspectionItem]
  public let records: [DevelopmentPresetRecord]
  fileprivate let originals: [String: Data]
  fileprivate let collisions: [String: Set<String>]
  fileprivate let frozenRecordCount: Int?
  public let frozenBatchPreviouslyRemoved: Bool
  public var visibleCount: Int { records.filter(\.isBrowsable).count }
  public var hasConflicts: Bool { !collisions.isEmpty }
  public var frozenMigrationReady: Bool {
    guard let count = frozenRecordCount else { return false }
    return !frozenBatchPreviouslyRemoved && records.count == count && items.count == count && !hasConflicts
      && items.allSatisfy { $0.status == .ready || $0.status == .duplicate }
  }
  public func lensBlurAssessment(for record: DevelopmentPresetRecord) throws -> PresetLensBlurAssessment {
    guard let sha = record.sourceSHA256, let original = originals[sha] else { throw DevelopmentPresetError.missingOriginal }
    return try DevelopmentPresetExchange.lensBlurAssessment(for: record, original: original)
  }

  /// Includes duplicate content so each confirmed batch owns its own reference.
  public func commit(to catalog: DevelopmentPresetCatalog, keepingConflicts: Bool = false) throws -> [String] {
    try Task.checkCancellation()
    if frozenRecordCount != nil && !frozenMigrationReady {
      if frozenBatchPreviouslyRemoved { throw PresetExchangeError.invalid("用户已撤销本次冻结迁移批次") }
      throw PresetExchangeError.invalid("冻结迁移要求清单中每个文件均通过核验，并解决全部 UUID 冲突")
    }
    let allowed = records.compactMap { record -> DevelopmentPresetRecord? in
      var row = record
      if let related = collisions[row.id] {
        guard keepingConflicts else { return nil }
        row.metadata["allowedUUIDHashes"] = related.sorted().joined(separator: ",")
      }
      return row
    }
    let hashes = Set(allowed.compactMap(\.sourceSHA256))
    return try catalog.importBatch(allowed, originals: originals.filter { hashes.contains($0.key) }, batchID: batchID,
                                  requireUnambiguousUUIDs: frozenRecordCount != nil)
  }

  public func commitDisposition(for item: PresetInspectionItem, inserted: Set<String>, keepingConflicts: Bool) -> String? {
    guard [.ready, .duplicate, .conflict].contains(item.status), let hash = item.sha256 else { return nil }
    let id = "xmp." + hash
    if collisions[id] != nil && !keepingConflicts { return "skippedConflict" }
    return inserted.contains(id) && item.status != .duplicate ? "inserted" : "referenced"
  }

  public func reportData(inserted: Set<String>? = nil, keepingConflicts: Bool = false) throws -> Data {
    struct Report: Encodable {
      var batchID: String
      var files: [PresetInspectionItem]
      var visibleCount: Int
      var records: [DevelopmentPresetRecord]
      var addedIDs: [String]?
      var dispositionByItemID: [String: String]?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let outcomes = inserted.map { added in
      Dictionary(uniqueKeysWithValues: items.compactMap { item in
        commitDisposition(for: item, inserted: added, keepingConflicts: keepingConflicts).map { (String(item.id), $0) }
      })
    }
    return try encoder.encode(Report(batchID: batchID, files: items, visibleCount: visibleCount, records: records,
      addedIDs: inserted?.sorted(), dispositionByItemID: outcomes))
  }
}

public enum DevelopmentPresetExchange {
  public static let frozenMigrationV1SHA256 = "a5e60e133e26b859539b1a14521f81a306907e0cbabb2243879b7720fd421f58"
  public static let systemRoot = URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/Settings", isDirectory: true)
  public static let userRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Adobe/CameraRaw/ImportedSettings", isDirectory: true)

  public static func migrationRules() throws -> [PresetMigrationRule] {
    guard let url = Bundle.module.url(forResource: "AdobePresetMigration-v1", withExtension: "json") else {
      throw PresetExchangeError.invalid("缺少本机迁移核准清单")
    }
    let rules = try JSONDecoder().decode([PresetMigrationRule].self, from: Data(contentsOf: url))
    guard rules.count == 53, Set(rules.map(\.path)).count == rules.count,
          rules.allSatisfy({ PresetExchangeLimits.safePath($0.path) && EditingFingerprint.isSHA256($0.sha256)
            && (1...PresetExchangeLimits.xmpBytes).contains($0.bytes) }) else {
      throw PresetExchangeError.invalid("本机迁移清单无效")
    }
    return rules
  }

  public static func inspectFiles(_ urls: [URL], catalog: DevelopmentPresetCatalog) throws -> PresetExchangeStage {
    guard urls.count <= PresetExchangeLimits.files else { throw PresetExchangeError.invalid("选择的文件过多") }
    var scan = try Scan(catalog: catalog)
    var inputBytes = 0
    let adobeRoot = systemRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    for url in urls {
      try Task.checkCancellation()
      let path = url.lastPathComponent
      do {
        switch url.pathExtension.lowercased() {
        case "xmp":
          let bytes = try PresetExchangeLimits.read(url, limit: PresetExchangeLimits.xmpBytes)
          guard bytes.count <= PresetExchangeLimits.batchBytes - inputBytes else { throw BatchLimit() }
          inputBytes += bytes.count
          let origin = url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(adobeRoot) ? "adobeBuiltin" : "manual"
          try scan.add(bytes, path: path, origin: origin)
        case "zip":
          let bytes = try PresetExchangeLimits.read(url, limit: PresetExchangeLimits.archiveBytes)
          guard bytes.count <= PresetExchangeLimits.batchBytes - inputBytes else { throw BatchLimit() }
          inputBytes += bytes.count
          let archive = try PresetExchangeArchive.read(bytes)
          for entry in archive.members { try scan.add(entry.data, path: path + "/" + entry.path, origin: "manual") }
          if archive.ignored > 0 || archive.members.isEmpty {
            scan.note(path, "manual", .ignored, "包含 \(archive.ignored) 个非预设文件，可读 XMP \(archive.members.count) 个")
          }
        default: scan.note(path, "manual", .ignored, "仅接受 XMP 或 ZIP")
        }
      } catch is CancellationError { throw CancellationError() }
      catch let error as BatchLimit { throw error }
      catch { scan.note(path, "manual", .rejected, error.localizedDescription) }
    }
    return try scan.finish()
  }

  public static func inspectAdobe(system: URL? = systemRoot, user: URL? = userRoot,
                                  catalog: DevelopmentPresetCatalog) throws -> PresetExchangeStage {
    var scan = try Scan(catalog: catalog)
    if let system {
      let root = system.resolvingSymlinksInPath().standardizedFileURL
      for rule in scan.rules {
        try scan.inspectExpected(root: root, rule: rule, origin: "adobeBuiltin")
      }
    }
    if let user { try scan.enumerateUser(user) }
    return try scan.finish()
  }

  /// Replays the versioned engineering manifest. The interactive Adobe importer can still discover user files.
  public static func inspectFrozenAdobe(manifest: URL, system: URL = systemRoot, user: URL = userRoot,
                                        catalog: DevelopmentPresetCatalog) throws -> PresetExchangeStage {
    struct Manifest: Decodable {
      struct Entry: Decodable {
        enum Root: String, Decodable { case systemCameraRawSettings, userImportedSettings }
        let sourceRoot: Root
        let sourceRelativePath, sha256: String
        let bytes: Int
      }
      let entries: [Entry]
    }
    let data = try PresetExchangeLimits.read(manifest, limit: 1_048_576)
    guard hash(data) == frozenMigrationV1SHA256 else {
      throw PresetExchangeError.invalid("迁移清单与冻结的 031 v1 SHA-256 不符")
    }
    let entries = try JSONDecoder().decode(Manifest.self, from: data).entries
    let systemCount = entries.filter { $0.sourceRoot == .systemCameraRawSettings }.count
    guard systemCount == 53, entries.count - systemCount == 25,
          Set(entries.map(\.sha256)).count == entries.count else {
      throw PresetExchangeError.invalid("冻结迁移条目数量或内容标识无效")
    }
    var scan = try Scan(catalog: catalog, frozenRecordCount: entries.count)
    let system = system.resolvingSymlinksInPath().standardizedFileURL
    let user = user.resolvingSymlinksInPath().standardizedFileURL
    for entry in entries {
      let builtin = entry.sourceRoot == .systemCameraRawSettings
      let rule = PresetMigrationRule(path: entry.sourceRelativePath, sha256: entry.sha256, bytes: entry.bytes)
      try scan.inspectExpected(root: builtin ? system : user, rule: rule, origin: builtin ? "adobeBuiltin" : "userImported")
    }
    return try scan.finish()
  }

  public static func projectedXMP(for record: DevelopmentPresetRecord) throws -> PresetXMPExport {
    guard record.kind == .user else { throw PresetExchangeError.invalid("仅个人原生预设可另写为 XMP") }
    return try CameraRawPresetMapping.export(record.patch, name: record.name, group: record.group)
  }

  /// Re-encode the current non-neutral global values and enumerate every omitted active recipe section.
  public static func projectedXMP(for recipe: DevelopmentRecipe, name: String) throws -> PresetXMPExport {
    guard let p = try recipe.promotingToV3().adjustmentsV3 else { throw DevelopmentPresetError.invalid }
    var patch = DevelopmentPresetPatch()
    var skipped: Set<String> = []
    patch.legacyBasis = p.legacyBasis
    if p.light.enabled {
      if p.light.exposure != 0 { patch.exposure = p.light.exposure }
      if p.light.contrast != 0 { patch.contrast = p.light.contrast }
      if p.light.shadows != 0 { patch.shadows = p.light.shadows }
      if p.light.highlights != 0 { patch.highlights = p.light.highlights }
      if p.light.whites != 0 { patch.whites = p.light.whites }
    }
    if p.color.enabled {
      if p.color.saturation != 0 { patch.saturation = p.color.saturation }
      if p.color.vibrance != 0 { patch.vibrance = p.color.vibrance }
    }
    if p.curves.enabled { patch.curves = p.curves }
    let encoder = JSONEncoder()
    encoder.userInfo[DevelopmentColorLUT.fingerprintOnly] = true
    func object(_ value: DevelopmentAdjustmentsV3) throws -> NSDictionary {
      try JSONSerialization.jsonObject(with: encoder.encode(value)) as? NSDictionary ?? [:]
    }
    let actual = try object(p), neutral = try object(.init())
    for case let key as String in actual.allKeys where !["light","color","curves","legacyBasis"].contains(key) {
      if key == "geometry", p.geometry == DevelopmentGeometryV3(version: p.geometry.version) { continue }
      if (actual[key] as? NSObject)?.isEqual(neutral[key]) != true { skipped.insert(key) }
    }
    if p.light.enabled {
      if p.light.brilliance != 0 { skipped.insert("light.brilliance") }
      if p.light.blackPoint != 0 { skipped.insert("light.blackPoint") }
      if p.light.brightness != 0 { skipped.insert("light.brightness") }
    }
    if p.color.enabled, p.color.cast != 0 { skipped.insert("color.cast") }
    do {
      let export = try CameraRawPresetMapping.export(patch, name: name, group: "RAWMaster", omitZeroExposure: true)
      return PresetXMPExport(data: export.data, included: export.included, excluded: skipped.union(export.excluded).sorted())
    } catch PresetExchangeError.noMappableFields(let fields) {
      throw PresetExchangeError.noMappableFields(skipped.union(fields).sorted())
    }
  }

  public static func originalXMP(for record: DevelopmentPresetRecord, catalog: DevelopmentPresetCatalog,
                                 confirmedRights: Bool) throws -> Data {
    guard confirmedRights, record.metadata["origin"] != "adobeBuiltin", let sha = record.sourceSHA256,
          try !migrationRules().contains(where: { $0.sha256 == sha }) else {
      throw PresetExchangeError.invalid("该来源仅供本机使用或尚未确认导出权限")
    }
    return try catalog.originalData(sha256: sha)
  }

  public static func sourceFields(for record: DevelopmentPresetRecord, catalog: DevelopmentPresetCatalog) throws
    -> (fields: [PresetSourceField], additional: Int) {
    guard let hash = record.sourceSHA256 else { throw DevelopmentPresetError.missingOriginal }
    let parsed = try CameraRawXMP.read(catalog.originalData(sha256: hash), collectFields: true)
    return (parsed.sourceFields, parsed.omittedSourceFieldCount)
  }

  /// Recheck dependency links when another batch adds or removes an internal Look.
  public static func resolvingLook(_ source: DevelopmentPresetRecord, among rows: [DevelopmentPresetRecord]) -> DevelopmentPresetRecord {
    guard source.metadata["requiresLook"] == "true" else { return source }
    var record = source
    let uuid = record.metadata["lookUUID"]
    let matches = rows.filter { ($0.kind == .look || $0.kind == .profile) && uuid?.isEmpty == false && $0.metadata["uuid"] == uuid }
    let name = record.metadata["lookName"] ?? uuid ?? "未命名"
    record.blockingReasons.removeAll { $0.hasPrefix("Look · ") }
    record.metadata.removeValue(forKey: "lookSHA256")
    if matches.count == 1 {
      record.metadata["lookResolution"] = "internal"
      record.metadata["lookSHA256"] = matches[0].sourceSHA256
      record.blockingReasons.append("Look · 已收录 \(name)，待验证表渲染")
    } else if matches.isEmpty {
      record.metadata["lookResolution"] = "missing"; record.blockingReasons.append("Look · 缺少外部 \(name)")
    } else {
      record.metadata["lookResolution"] = "ambiguous"; record.blockingReasons.append("Look · \(name) 有多个不同版本")
    }
    return record
  }

  public static func subset(for record: DevelopmentPresetRecord) throws -> DevelopmentPresetRecord {
    guard record.kind == .imported, record.metadata["capability"] == "normalPreset", !record.patch.isEmpty,
          record.metadata["sourceRestriction"] == nil, record.metadata["unverifiedProcess"] == nil else {
      throw DevelopmentPresetError.unavailable
    }
    var subset = record
    subset.metadata["confirmedOmissions"] = ([record.metadata["omitted"] ?? ""] + record.blockingReasons)
      .filter { !$0.isEmpty }.joined(separator: " · ")
    subset.blockingReasons = []
    return subset
  }

  public static func semanticIntent(for record: DevelopmentPresetRecord) -> PresetSemanticIntent? {
    guard record.metadata["capability"] == "semanticCorrection", let raw = record.metadata["semanticIntentV1"] else { return nil }
    return try? JSONDecoder().decode(PresetSemanticIntent.self, from: Data(raw.utf8))
  }

  /// Fresh per-photo segmentation and confirmation are required. The original entry remains strict-blocked.
  public static func semanticReconstruction(for source: DevelopmentPresetRecord) throws -> DevelopmentPresetRecord {
    guard source.kind == .imported, source.metadata["origin"] == "adobeBuiltin",
          source.metadata["sourceRestriction"] == nil, source.metadata["omitted"] == "MaskGroupBasedCorrections",
          let intent = semanticIntent(for: source), let adjustments = intent.adjustments,
          let hash = source.sourceSHA256,
          let rule = try migrationRules().first(where: { $0.sha256 == hash }) else { throw DevelopmentPresetError.unavailable }
    let group = intent.target == .subject ? "Subject" : "Sky"
    guard rule.path.hasPrefix("Premium/Adaptive - \(group)/") else { throw DevelopmentPresetError.unavailable }
    var record = source, patch = DevelopmentPresetPatch()
    patch.semanticMasks = [try DevelopmentPresetMaskIntent(target: intent.target == .subject ? .subject : .sky,
      name: source.name, adjustments: adjustments)]
    record.patch = patch
    record.blockingReasons = []
    record.metadata["semanticReconstruction"] = "true"
    record.metadata["evidence"] = "使用 RAWMaster 本张选区及局部参数重建"
    try record.validate()
    return record
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct BatchLimit: LocalizedError {
    var errorDescription: String? { "本批超过 \(PresetExchangeLimits.files) 项或 \(PresetExchangeLimits.batchBytes / 1024 / 1024) MiB，请缩小选择范围" }
  }

  private struct Scan {
    let rules: [PresetMigrationRule]
    let knownBuiltins: Set<String>
    let existing: [DevelopmentPresetRecord]
    let batchID: String
    let frozenRecordCount: Int?
    let frozenBatchPreviouslyRemoved: Bool
    var items: [PresetInspectionItem] = []
    var candidates: [String: DevelopmentPresetRecord] = [:]
    var originals: [String: Data] = [:]
    var total = 0
    init(catalog: DevelopmentPresetCatalog, frozenRecordCount: Int? = nil) throws {
      rules = try migrationRules(); knownBuiltins = Set(rules.map(\.sha256))
      existing = try catalog.records()
      self.frozenRecordCount = frozenRecordCount
      batchID = frozenRecordCount == nil
        ? ISO8601DateFormatter().string(from: Date()) + "-" + UUID().uuidString
        : "adobe-frozen-v1-" + frozenMigrationV1SHA256
      frozenBatchPreviouslyRemoved = frozenRecordCount == nil ? false : try catalog.wasImportBatchRemoved(batchID)
    }

    mutating func note(_ path: String, _ origin: String, _ status: PresetInspectionStatus, _ detail: String, hash: String? = nil) {
      items.append(PresetInspectionItem(id: items.count, path: path, origin: origin, status: status, sha256: hash, detail: detail))
    }

    mutating func inspectExpected(root: URL, rule: PresetMigrationRule, origin: String) throws {
      try Task.checkCancellation()
      let url = root.appendingPathComponent(rule.path)
      guard FileManager.default.fileExists(atPath: url.path) else { note(rule.path, origin, .missing, "核准路径缺失"); return }
      guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
        note(rule.path, origin, .rejected, "路径包含符号链接"); return
      }
      do {
        let bytes = try PresetExchangeLimits.read(root: root, relative: rule.path, limit: PresetExchangeLimits.xmpBytes)
        let sha = hash(bytes)
        guard bytes.count == rule.bytes, sha == rule.sha256 else {
          note(rule.path, origin, .changed, "安装版本与核准字节数或哈希不符", hash: sha); return
        }
        try add(bytes, path: rule.path, origin: origin, hash: sha)
      } catch is CancellationError { throw CancellationError() }
      catch let error as BatchLimit { throw error }
      catch { note(rule.path, origin, .rejected, error.localizedDescription) }
    }

    mutating func add(_ bytes: Data, path: String, origin: String, hash supplied: String? = nil) throws {
      try Task.checkCancellation()
      guard items.count < PresetExchangeLimits.files, bytes.count <= PresetExchangeLimits.batchBytes - total else { throw BatchLimit() }
      total += bytes.count
      let sha = supplied ?? hash(bytes)
      let origin = knownBuiltins.contains(sha) ? "adobeBuiltin" : origin
      if candidates[sha] != nil { note(path, origin, .duplicate, "本批相同字节", hash: sha); return }
      do {
        var record = CameraRawPresetMapping.record(try CameraRawXMP.read(bytes), path: path, origin: origin, hash: sha)
        record.metadata["exchangeBatchID"] = batchID
        try record.validate()
        candidates[sha] = record
        originals[sha] = bytes
        let duplicate = existing.contains { $0.sourceSHA256 == sha }
        note(path, origin, duplicate ? .duplicate : .ready, duplicate ? "目录已收录相同内容" : record.name, hash: sha)
      } catch {
        try Task.checkCancellation()
        note(path, origin, .rejected, error.localizedDescription, hash: sha)
      }
    }

    mutating func enumerateUser(_ user: URL) throws {
      let root = user.resolvingSymlinksInPath().standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        note("ImportedSettings", "userImported", .missing, "用户 Camera Raw 目录不存在"); return
      }
      let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
      var errors: [(String, String)] = []
      guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
        errorHandler: { url, error in
          if errors.count < PresetExchangeLimits.files { errors.append((url.lastPathComponent, error.localizedDescription)) }
          return true
        }) else { note("ImportedSettings", "userImported", .rejected, "无法读取用户目录"); return }
      var visited = 0
      var otherFileCount = 0
      for case let url as URL in enumerator {
        try Task.checkCancellation()
        visited += 1
        guard visited <= 100_000, items.count < PresetExchangeLimits.files else { throw BatchLimit() }
        // Foundation may enumerate /private/var for a /var root on macOS.
        let entryPath = url.standardizedFileURL.path
        guard entryPath.hasPrefix(root.path + "/") else {
          enumerator.skipDescendants()
          note(url.lastPathComponent, "userImported", .rejected, "条目不在所选目录内"); continue
        }
        let relative = String(entryPath.dropFirst(root.path.count + 1))
        do {
          let info = try url.resourceValues(forKeys: Set(keys))
          if info.isSymbolicLink == true { enumerator.skipDescendants(); note(relative, "userImported", .ignored, "跳过符号链接"); continue }
          if info.isDirectory == true { continue }
          guard info.isRegularFile == true, url.pathExtension.lowercased() == "xmp" else {
            otherFileCount += 1; continue
          }
          guard PresetExchangeLimits.safePath(relative), url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            note(relative, "userImported", .rejected, "文件路径已改变"); continue
          }
          try add(try PresetExchangeLimits.read(root: root, relative: relative, limit: PresetExchangeLimits.xmpBytes),
                  path: relative, origin: "userImported")
        } catch is CancellationError { throw CancellationError() }
        catch let error as BatchLimit { throw error }
        catch { note(relative, "userImported", .rejected, error.localizedDescription) }
      }
      for (path, reason) in errors { note(path, "userImported", .rejected, reason) }
      if otherFileCount > 0 { note("ImportedSettings", "userImported", .ignored, "跳过 \(otherFileCount) 个非 XMP 文件") }
    }

    func finish() throws -> PresetExchangeStage {
      var all = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      for row in candidates.values { all[row.id] = row }
      let known = Array(all.values)
      let uuids = Dictionary(grouping: known.filter { $0.metadata["uuid"]?.isEmpty == false }, by: { $0.metadata["uuid"]!.lowercased() })
      let previousIDs = Set(existing.map(\.id))
      var collisions: [String: Set<String>] = [:]
      var entries = items
      let locations = Dictionary(grouping: items.filter { [.ready,.duplicate].contains($0.status) && $0.sha256 != nil },
                                 by: { $0.sha256! })
      let records = try candidates.values.map { record in
        var resolved = resolvingLook(record, among: known)
        let paths = Set((locations[record.sourceSHA256 ?? ""] ?? []).map { $0.origin + " / " + $0.path })
        let bytes = try JSONEncoder().encode(paths.sorted())
        resolved.metadata["sourceLocationsV1"] = String(decoding: bytes, as: UTF8.self)
        try resolved.validate()
        return resolved
      }.sorted { $0.id < $1.id }
      for row in records where frozenRecordCount != nil || !previousIDs.contains(row.id) {
        guard let uuid = row.metadata["uuid"] else { continue }
        let other = (uuids[uuid.lowercased()] ?? []).filter { $0.id != row.id }.compactMap(\.sourceSHA256)
        if !other.isEmpty { collisions[row.id] = Set(other) }
      }
      for index in entries.indices {
        let item = entries[index]
        if let sha = item.sha256, collisions["xmp." + sha] != nil,
           item.status == .ready || (frozenRecordCount != nil && item.status == .duplicate) {
          entries[index].status = .conflict; entries[index].detail += " · UUID 相同，内容哈希不同"
        }
      }
      try Task.checkCancellation()
      return PresetExchangeStage(batchID: batchID, items: entries, records: records, originals: originals,
                                 collisions: collisions, frozenRecordCount: frozenRecordCount,
                                 frozenBatchPreviouslyRemoved: frozenBatchPreviouslyRemoved)
    }
  }
}
