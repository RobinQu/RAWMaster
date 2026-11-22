import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

/// The same admitted original can underlie a master and many virtual copies. A recipe lives on its exact organization work.
public struct CatalogLocalRecipe: Codable, Equatable, Sendable {
  public struct Crop: Codable, Equatable, Sendable {
    public var left: Double, top: Double, right: Double, bottom: Double
    public init(left: Double = 0, top: Double = 0, right: Double = 1, bottom: Double = 1) {
      self.left = left
      self.top = top
      self.right = right
      self.bottom = bottom
    }
  }
  public var exposureEV: Double
  public var crop: Crop
  public init(exposureEV: Double = 0, crop: Crop = .init()) {
    self.exposureEV = exposureEV
    self.crop = crop
  }
  public func validate() throws {
    let c = crop
    guard exposureEV.isFinite, (-5...5).contains(exposureEV),
      [c.left, c.top, c.right, c.bottom].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
      c.right - c.left >= 0.02, c.bottom - c.top >= 0.02
    else { throw LibraryEngineError("曝光或裁切范围无效") }
  }
}

public struct CatalogLocalBase: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case historicalLook, original }
  public let kind: Kind
  public let sha256: String
  public let resourceID: String?, sourceRunID: String?, fileID: String?, contentID: String?
  public let sourceWorkID: String?, revisionBound: Bool?
}

struct LocalAppearance: Codable, Sendable {
  let origin: String, schemaVersion: Int
  let source: CatalogLocalBase
  let recipe: CatalogLocalRecipe
  static let originName = "rawmasterLocalDevelop"
}

public struct CatalogLocalEdit: Sendable {
  public let workID: String, name: String
  public let revision: Int64, versionID: String?
  public let source: CatalogLocalBase?, sourceURL: URL?
  public let recipe: CatalogLocalRecipe
  public let hasLocalVersion: Bool
  public let belongsToLightroom: Bool
  public let historicalReferenceURL: URL?
  public let canStartFromOriginal: Bool
}

public enum CatalogLocalEditing {
  private struct Work: Decodable {
    struct Version: Decodable {
      let versionID: String
      let appearance: CatalogJSON
    }
    let workID: String, kind: String, name: String?, versionID: String?, revision: Int64,
      versions: [Version]
  }
  private struct Media: Decodable {
    let path, resourceID, kind, sha256: String
    let sourceRunID: String?, sourceWorkID: String?, revisionBound: Bool?
  }
  private static func media(_ work: String, run: String?, actions: CatalogActions) async throws
    -> Media?
  {
    var r: [String: CatalogJSON] = ["action": .string("workMedia"), "workID": .string(work)]
    if let run { r["sourceRunID"] = .string(run) }
    let v = try await actions.read("lightroom", r)
    if v == .null { return nil }
    return try v.decoded(Media.self)
  }
  private static func scopedFile(_ work: String, actions: CatalogActions) async throws
    -> CatalogJSON
  {
    try await actions.read("inspection", ["op": .string("work"), "workID": .string(work)])
  }
  private static func locate(
    _ base: CatalogLocalBase, work: String, scoped: CatalogJSON, actions: CatalogActions
  ) async throws -> URL? {
    switch base.kind {
    case .historicalLook:
      guard let bound = base.sourceRunID, let id = base.resourceID,
        let m = try await media(work, run: bound, actions: actions),
        m.kind == "historical", m.resourceID == id, m.sha256 == base.sha256,
        m.sourceWorkID == base.sourceWorkID
      else { return nil }
      return URL(fileURLWithPath: m.path)
    case .original:
      guard let file = base.fileID, let content = base.contentID,
        scoped["fileID"]?.stringValue == file
      else { return nil }
      let bits = content.split(separator: ":")
      guard bits.count == 3, bits[0] == "sha256", String(bits[1]) == base.sha256,
        let size = Int64(bits[2])
      else { return nil }
      let fileDetails = try await actions.read(
        "inspection",
        ["op": .string("file"), "fileID": .string(file), "contentID": .string(content)])
      guard fileDetails["archiveEligible"] == .boolean(true) else { return nil }
      let replicas = fileDetails["replicas"]?.arrayValue ?? []
      let first =
        scoped["contentID"]?.stringValue == content ? scoped["resolvedPath"]?.stringValue : nil
      let paths =
        [first].compactMap { $0 }
        + replicas.filter { $0["state"]?.stringValue == "available" }.compactMap {
          $0["path"]?.stringValue
        }
      return try await Task.detached(priority: .utility) {
        var visited = Set<String>()
        for path in paths where visited.insert(path).inserted {
          try Task.checkCancellation()
          let url = URL(fileURLWithPath: path)
          if let checked = try? LibraryInspectionReader.digest(url), checked.0 == base.sha256,
            checked.1 == size
          {
            return url
          }
        }
        return nil
      }.value
    }
  }

  public static func open(_ id: String, actions: CatalogActions) async throws -> CatalogLocalEdit {
    let work = try await actions.read(
      "organization", ["view": .string("work"), "workID": .string(id)]
    ).decoded(Work.self)
    guard work.workID == id else { throw LibraryEngineError("作品身份发生变化") }
    let active = work.versions.first { $0.versionID == work.versionID }?.appearance
    let hasLocal = active?["origin"]?.stringValue == LocalAppearance.originName
    let lr = work.versions.contains { $0.appearance["origin"]?.stringValue == "lightroom" }
    guard lr || hasLocal else {
      return CatalogLocalEdit(
        workID: id, name: work.name ?? id, revision: work.revision, versionID: work.versionID,
        source: nil, sourceURL: nil, recipe: .init(), hasLocalVersion: false,
        belongsToLightroom: false, historicalReferenceURL: nil, canStartFromOriginal: false)
    }
    let scoped = try await scopedFile(id, actions: actions)
    var base: CatalogLocalBase?
    var recipe = CatalogLocalRecipe()
    // Managed historical bytes are resolved from this work's proven Lightroom lineage. The file address is never persisted.
    let historical = try await media(id, run: nil, actions: actions).flatMap {
      $0.kind == "historical" ? $0 : nil
    }
    if hasLocal, let active {
      let stored = try active.decoded(LocalAppearance.self)
      guard stored.schemaVersion == 1 else { throw LibraryEngineError("此本地编辑版本需要更新的 RAWMaster") }
      try stored.recipe.validate()
      base = stored.source
      recipe = stored.recipe
    } else if let m = historical, let run = m.sourceRunID {
      base = CatalogLocalBase(
        kind: .historicalLook, sha256: m.sha256, resourceID: m.resourceID, sourceRunID: run,
        fileID: nil, contentID: nil, sourceWorkID: m.sourceWorkID, revisionBound: m.revisionBound)
    } else {
      base = originalBase(scoped)
    }
    let url: URL?
    if let base {
      if base.kind == .historicalLook, let h = historical, h.resourceID == base.resourceID,
        h.sourceRunID == base.sourceRunID, h.sha256 == base.sha256,
        h.sourceWorkID == base.sourceWorkID
      {
        url = URL(fileURLWithPath: h.path)
      } else {
        url = try await locate(base, work: id, scoped: scoped, actions: actions)
      }
    } else {
      url = nil
    }
    return CatalogLocalEdit(
      workID: id, name: work.name ?? id, revision: work.revision, versionID: work.versionID,
      source: base, sourceURL: url,
      recipe: recipe, hasLocalVersion: hasLocal, belongsToLightroom: lr || hasLocal,
      historicalReferenceURL: historical.map { URL(fileURLWithPath: $0.path) },
      canStartFromOriginal: !hasLocal && base?.kind == .historicalLook
        && originalBase(scoped) != nil)
  }

  private static func originalBase(_ scoped: CatalogJSON) -> CatalogLocalBase? {
    guard let file = scoped["fileID"]?.stringValue, let content = scoped["contentID"]?.stringValue
    else { return nil }
    let b = content.split(separator: ":")
    guard b.count == 3, b[0] == "sha256", b[1].count == 64, let size = Int64(b[2]), size > 0 else {
      return nil
    }
    return CatalogLocalBase(
      kind: .original, sha256: String(b[1]), resourceID: nil, sourceRunID: nil, fileID: file,
      contentID: content, sourceWorkID: nil, revisionBound: nil)
  }

  /// Pick an admitted original explicitly before the first native version is created.
  public static func startingFromOriginal(_ edit: CatalogLocalEdit, actions: CatalogActions)
    async throws -> CatalogLocalEdit
  {
    guard edit.canStartFromOriginal else { throw LibraryEngineError("此作品没有可选的已纳入原件") }
    let scoped = try await scopedFile(edit.workID, actions: actions)
    guard let base = originalBase(scoped),
      let url = try await locate(base, work: edit.workID, scoped: scoped, actions: actions)
    else {
      throw LibraryEngineError("未能读取此作品已核验的原件")
    }
    return CatalogLocalEdit(
      workID: edit.workID, name: edit.name, revision: edit.revision, versionID: edit.versionID,
      source: base, sourceURL: url, recipe: .init(), hasLocalVersion: false,
      belongsToLightroom: true,
      historicalReferenceURL: edit.historicalReferenceURL, canStartFromOriginal: false)
  }

  @discardableResult public static func save(
    _ recipe: CatalogLocalRecipe, for session: CatalogLocalEdit,
    actions: CatalogActions, commandID: String = UUID().uuidString
  ) async throws -> String {
    try recipe.validate()
    guard session.belongsToLightroom, let source = session.source, session.sourceURL != nil else {
      throw LibraryEngineError("找不到该作品的编辑起点")
    }
    let appearance = LocalAppearance(
      origin: LocalAppearance.originName, schemaVersion: 1, source: source, recipe: recipe)
    let version = "local-develop:" + commandID
    let r = try await actions.perform(
      "org.saveWork",
      [
        "workID": .string(session.workID), "baseRevision": .integer(session.revision),
        "versionID": .string(version), "appearance": try .encoding(appearance),
      ], commandID: commandID)
    guard r["versionID"]?.stringValue == version else { throw LibraryEngineError("保存的工作版本不匹配") }
    return version
  }

  /// Produce an orientation-correct editable preview once; sliders re-render this immutable source image.
  public static func image(for edit: CatalogLocalEdit, maxSize: Int = 1600) async throws -> CGImage
  {
    guard let url = edit.sourceURL, let source = edit.source, maxSize > 0 else {
      throw LibraryEngineError("该版本的来源当前离线")
    }
    return try await Task.detached(priority: .utility) {
      let before = try LibraryInspectionReader.signature(url)
      guard try LibraryInspectionReader.digest(url).0 == source.sha256 else {
        throw LibraryEngineError("当前文件的内容与作品绑定的来源不符")
      }
      let decoded: CIImage
      if source.kind == .original, let raw = CIRAWFilter(imageURL: url) {
        raw.scaleFactor = Float(
          min(1, Double(maxSize) / max(raw.nativeSize.width, raw.nativeSize.height)))
        guard let image = raw.outputImage else { throw LibraryEngineError("无法解码该 RAW 来源") }
        decoded = image
      } else {
        guard let f = CGImageSourceCreateWithURL(url as CFURL, nil),
          let im = CGImageSourceCreateThumbnailAtIndex(
            f, 0,
            [
              kCGImageSourceThumbnailMaxPixelSize: maxSize,
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        else { throw LibraryEngineError("无法解码历史外观或照片") }
        decoded = CIImage(cgImage: im)
      }
      let bitmap = CIContext().createCGImage(
        decoded, from: decoded.extent, format: .RGBAh,
        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
      guard let bitmap, try LibraryInspectionReader.signature(url) == before else {
        throw LibraryEngineError("预览读取期间来源发生变化")
      }
      return bitmap
    }.value
  }

  public static func render(_ input: CGImage, recipe: CatalogLocalRecipe) throws -> CGImage {
    try recipe.validate()
    let source = CIImage(cgImage: input)
    let e = source.extent
    let c = recipe.crop
    let rect = CGRect(
      x: e.minX + c.left * e.width, y: e.minY + (1 - c.bottom) * e.height,
      width: (c.right - c.left) * e.width, height: (c.bottom - c.top) * e.height
    ).integral.intersection(e)
    let image = source.cropped(to: rect).applyingFilter(
      "CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposureEV])
    guard rect.width > 0, rect.height > 0,
      let bitmap = CIContext().createCGImage(
        image, from: rect, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    else { throw LibraryEngineError("无法呈现本地编辑配方") }
    return bitmap
  }
}

/// A bounded per-process preview cache. Authoritative recipes and verified sources are stored in the catalog.
public actor CatalogLocalPreviewCache {
  public static let shared = CatalogLocalPreviewCache()
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "rawmaster-work-" + UUID().uuidString, isDirectory: true)
  private struct Key: Hashable {
    let workID: String
    let versionID: String
    let sourceSHA: String
    let recipeSHA: String
  }
  private var entries = [Key: LibraryHistogramSource](), order = [Key]()
  deinit { try? FileManager.default.removeItem(at: directory) }
  public func sample(for edit: CatalogLocalEdit) async throws -> LibraryHistogramSource? {
    guard edit.hasLocalVersion, let version = edit.versionID, let base = edit.source else {
      return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let token = SHA256.hash(data: try encoder.encode(edit.recipe)).map {
      String(format: "%02x", $0)
    }.joined()
    let key = Key(workID: edit.workID, versionID: version, sourceSHA: base.sha256, recipeSHA: token)
    if let sample = entries[key], FileManager.default.fileExists(atPath: sample.url.path) {
      return sample
    }
    guard edit.sourceURL != nil else { return nil }
    let input = try await CatalogLocalEditing.image(for: edit, maxSize: 1000)
    let bitmap = try CatalogLocalEditing.render(input, recipe: edit.recipe)
    try Task.checkCancellation()
    if let existing = entries[key], FileManager.default.fileExists(atPath: existing.url.path) {
      return existing
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(UUID().uuidString + ".png")
    try CIContext().writePNGRepresentation(
      of: CIImage(cgImage: bitmap), to: url, format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    let hash = try LibraryInspectionReader.digest(url).0
    let sample = LibraryHistogramSource(kind: .render, url: url, sha256: hash, versionID: version)
    entries[key] = sample
    order.append(key)
    if order.count > 12, let removed = entries.removeValue(forKey: order.removeFirst()) {
      try? FileManager.default.removeItem(at: removed.url)
    }
    return sample
  }
}
