#if os(macOS)
  import Combine
  import CryptoKit
  import Foundation
  import Darwin

  public struct LibraryDiscoveryTarget: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let libraryID: String
    public let name: String
    public let generation: String?
    let packageDigest: String?
    let fileStamp: String?
    let location: String?
    let bookmark: Data?
    let current: URL?
  }

  public struct LibraryDiscoverySection: Identifiable, Sendable {
    public let target: LibraryDiscoveryTarget
    public let result: CatalogJSON?
    public let error: String?
    public var id: UUID { target.id }
  }

  public struct LibraryDiscoveryLocalFilter: Sendable {
    public let sourceID: UUID?
    public var scope: [String: CatalogJSON]
    public var personID: String?
    public var fenceID: String?
    public init(
      sourceID: UUID? = nil, scope: [String: CatalogJSON] = [:], personID: String? = nil,
      fenceID: String? = nil
    ) {
      self.sourceID = sourceID
      self.scope = scope
      self.personID = personID
      self.fenceID = fenceID
    }
  }

  /// Read-only requests across explicitly selected catalogs. The location UUID also
  /// distinguishes a live library from another generation of the same library.
  public enum LibraryDiscoveryFederation {
    private struct Package: Decodable {
      let format: Int
      let libraryID: String
      let generation: String
      let catalog: Blob
      struct Blob: Decodable {
        let sha256: String
        let bytes: Int64
      }
    }
    private static func database(_ selected: URL) throws -> URL {
      let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard selected.isFileURL, values.isSymbolicLink != true else {
        throw LibraryEngineError("所选位置不是本地资料库。")
      }
      let db =
        values.isDirectory == true ? selected.appendingPathComponent("library.sqlite") : selected
      let file = try db.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard file.isRegularFile == true, file.isSymbolicLink != true else {
        throw LibraryEngineError("目录中没有可读的 library.sqlite。")
      }
      return db
    }
    private static func locationAndStamp(_ db: URL) throws -> (location: String, stamp: String) {
      var status = stat()
      guard lstat(db.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
        throw LibraryEngineError("资料库文件暂不可用。")
      }
      let location = "\(status.st_dev).\(status.st_ino)"
      let stamp = [
        location, String(status.st_size), String(status.st_mtimespec.tv_sec),
        String(status.st_mtimespec.tv_nsec), String(status.st_ctimespec.tv_sec),
        String(status.st_ctimespec.tv_nsec),
      ].joined(separator: ".")
      return (location, stamp)
    }
    private static func package(_ db: URL, verifiedStamp: String?) throws -> (
      Package?, String, String
    ) {
      let (location, stamp) = try locationAndStamp(db)
      let path = db.deletingLastPathComponent().appendingPathComponent("manifest.json")
      guard FileManager.default.fileExists(atPath: path.path) else { return (nil, location, stamp) }
      let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw LibraryEngineError("资料库包清单无效。")
      }
      let manifest = try JSONDecoder().decode(Package.self, from: Data(contentsOf: path))
      guard manifest.format == 1, !manifest.generation.isEmpty,
        let bytes = try db.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        Int64(bytes) == manifest.catalog.bytes
      else { throw LibraryEngineError("资料库包目录与清单不匹配。") }
      if verifiedStamp != stamp {
        let input = try FileHandle(forReadingFrom: db)
        defer { try? input.close() }
        var hash = SHA256()
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
          try Task.checkCancellation()
          hash.update(data: block)
        }
        guard
          hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.catalog.sha256,
          try locationAndStamp(db).stamp == stamp
        else {
          throw LibraryEngineError("资料库包目录摘要不匹配。")
        }
      }
      return (manifest, location, stamp)
    }
    private static func identity(_ db: URL, validateSchema: Bool = false) throws -> CatalogJSON {
      try LibraryEngine.shared().request(
        "discovery", at: db,
        payload: CatalogJSON.object([
          "op": .string("identity"), "validateSchema": .boolean(validateSchema),
        ]),
        as: CatalogJSON.self)
    }
    public static func target(at selected: URL, isCurrent: Bool = false) throws
      -> LibraryDiscoveryTarget
    {
      let access = selected.startAccessingSecurityScopedResource()
      defer { if access { selected.stopAccessingSecurityScopedResource() } }
      let db = try database(selected)
      let (manifest, location, stamp) = try package(db, verifiedStamp: nil)
      let source = try identity(db, validateSchema: true)
      guard let id = source["libraryID"]?.stringValue, (source["schema"] == .integer(8) || source["schema"] == .integer(9)),
        manifest == nil || manifest?.libraryID == id
      else { throw LibraryEngineError("资料库身份或版本不匹配。") }
      let data =
        isCurrent
        ? nil
        : try selected.bookmarkData(
          options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
          includingResourceValuesForKeys: nil, relativeTo: nil)
      let name =
        db.lastPathComponent == "library.sqlite"
        ? db.deletingLastPathComponent().lastPathComponent : db.lastPathComponent
      return LibraryDiscoveryTarget(
        id: UUID(), libraryID: id, name: name, generation: manifest?.generation,
        packageDigest: manifest?.catalog.sha256, fileStamp: stamp, location: location,
        bookmark: data,
        current: isCurrent ? db : nil)
    }
    public static func refresh(_ target: LibraryDiscoveryTarget) throws -> LibraryDiscoveryTarget {
      guard let book = target.bookmark else { return target }
      var stale = false
      let url = try URL(
        resolvingBookmarkData: book, options: [.withSecurityScope, .withoutUI, .withoutMounting],
        relativeTo: nil, bookmarkDataIsStale: &stale)
      guard stale else { return target }
      let replacement = try self.target(at: url)
      guard replacement.libraryID == target.libraryID, replacement.generation == target.generation,
        replacement.packageDigest == target.packageDigest
      else { throw LibraryEngineError("书签指向的资料库已更换。") }
      return LibraryDiscoveryTarget(
        id: target.id, libraryID: target.libraryID, name: replacement.name,
        generation: target.generation, packageDigest: replacement.packageDigest,
        fileStamp: replacement.fileStamp, location: replacement.location,
        bookmark: replacement.bookmark, current: nil)
    }
    private static func access<T>(
      _ target: LibraryDiscoveryTarget, _ body: (URL, CatalogJSON) throws -> T
    ) throws -> T {
      let url: URL
      if let here = target.current {
        url = here
      } else if let book = target.bookmark {
        var stale = false
        url = try URL(
          resolvingBookmarkData: book, options: [.withSecurityScope, .withoutUI, .withoutMounting],
          relativeTo: nil, bookmarkDataIsStale: &stale)
      } else {
        throw LibraryEngineError("需要重新选择此库。")
      }
      let enabled = url.startAccessingSecurityScopedResource()
      defer { if enabled { url.stopAccessingSecurityScopedResource() } }
      let db = try database(url)
      let (m, _, _) = try package(db, verifiedStamp: target.fileStamp)
      let info = try identity(db)
      guard info["libraryID"] == .string(target.libraryID), m?.generation == target.generation,
        m?.catalog.sha256 == target.packageDigest,
        m == nil || m?.libraryID == target.libraryID
      else { throw LibraryEngineError("当前文件与所勾选库身份或代次不同。") }
      return try body(db, info)
    }
    public static func choices(_ source: LibraryDiscoveryTarget) throws -> CatalogJSON {
      try access(source) { db, info in
        let engine = try LibraryEngine.shared()
        let fences = try engine.request(
          "discovery", at: db, payload: CatalogJSON.object(["op": .string("fences")]),
          as: CatalogJSON.self)
        var people = [CatalogJSON]()
        if info["consent"]?["faces"] == .boolean(true) {
          people =
            try engine.request(
              "discovery", at: db, payload: CatalogJSON.object(["op": .string("people")]),
              as: CatalogJSON.self)["items"]?.arrayValue ?? []
        }
        return .object(["people": .array(people), "fences": fences["items"] ?? .array([])])
      }
    }
    public static func read(
      _ source: LibraryDiscoveryTarget, metadata: String = "", minimumRating: Int = 0,
      visual: CatalogJSON? = nil, local: LibraryDiscoveryLocalFilter = .init(),
      cursor: CatalogJSON? = nil
    ) throws -> CatalogJSON {
      try access(source) { db, info in
        if local.personID != nil || local.fenceID != nil || !local.scope.isEmpty {
          guard local.sourceID == source.id else { throw LibraryEngineError("筛选条件属于另一份资料库。") }
        }
        var scope = local.scope
        var terms = [CatalogJSON]()
        if let predicate = scope["predicate"], predicate != .null { terms.append(predicate) }
        if !metadata.isEmpty {
          terms.append(
            .object([
              "field": .string("text"), "op": .string("contains"), "value": .string(metadata),
            ]))
        }
        if minimumRating > 0 {
          terms.append(
            .object([
              "field": .string("rating"), "op": .string("gte"),
              "value": .integer(Int64(minimumRating)),
            ]))
        }
        if !terms.isEmpty {
          scope["predicate"] = terms.count == 1 ? terms[0] : .object(["all": .array(terms)])
        }
        var req: [String: CatalogJSON] = ["op": .string("search"), "scope": .object(scope)]
        if let person = local.personID, !person.isEmpty {
          guard info["consent"]?["faces"] == .boolean(true) else {
            throw LibraryEngineError("此库未开启人物检索。")
          }
          req["personID"] = .string(person)
        }
        if let fence = local.fenceID, !fence.isEmpty { req["fenceID"] = .string(fence) }
        if let visual {
          req["vector"] = visual["vector"]
          req["model"] = visual["model"]
          req["minimumScore"] = .number(0.07)
        }
        req["cursor"] = cursor
        let page = try LibraryEngine.shared().request(
          "discovery", at: db, payload: CatalogJSON.object(req), as: CatalogJSON.self)
        guard page["libraryID"] == .string(source.libraryID) else {
          throw LibraryEngineError("查询期间资料库已更换。")
        }
        return page
      }
    }
  }

  /// Source and filter changes invalidate the complete batch, including slow replies.
  @MainActor
  public final class LibraryDiscoverySearchBatch: ObservableObject {
    public typealias Reader = @Sendable (LibraryDiscoveryTarget) async throws -> CatalogJSON
    @Published public private(set) var sections = [LibraryDiscoverySection]()
    @Published public private(set) var running = false
    private var ticket = UUID()
    public init() {}
    public func invalidate() {
      ticket = UUID()
      sections = []
      running = false
    }
    public func next(_ source: LibraryDiscoveryTarget, using read: @escaping Reader) async {
      let run = ticket
      guard let idx = sections.firstIndex(where: { $0.id == source.id }),
        let old = sections[idx].result
      else { return }
      do {
        let page = try await read(source)
        guard ticket == run, let i = sections.firstIndex(where: { $0.id == source.id }),
          sections[i].result == old
        else { return }
        if page["status"] == .string("staleCursor") {
          sections[i] = LibraryDiscoverySection(
            target: source, result: nil, error: "此库在翻页时发生变化，请重新查询。")
          return
        }
        guard case .object(var fields) = page else { throw LibraryEngineError("无效查询结果。") }
        fields["items"] = .array(
          (old["items"]?.arrayValue ?? []) + (page["items"]?.arrayValue ?? []))
        sections[i] = LibraryDiscoverySection(target: source, result: .object(fields), error: nil)
      } catch {
        if ticket == run, let i = sections.firstIndex(where: { $0.id == source.id }) {
          sections[i] = LibraryDiscoverySection(
            target: source, result: nil, error: error.localizedDescription)
        }
      }
    }
    public func search(_ chosen: [LibraryDiscoveryTarget], using reader: @escaping Reader) async {
      invalidate()
      let run = ticket
      running = true
      var byID = [UUID: LibraryDiscoverySection]()
      await withTaskGroup(of: LibraryDiscoverySection.self) { group in
        var i = chosen.makeIterator()
        func add(_ target: LibraryDiscoveryTarget) {
          group.addTask {
            do {
              return LibraryDiscoverySection(
                target: target, result: try await reader(target), error: nil)
            } catch {
              return LibraryDiscoverySection(
                target: target, result: nil, error: error.localizedDescription)
            }
          }
        }
        for _ in 0..<min(4, chosen.count) { if let target = i.next() { add(target) } }
        while let row = await group.next() {
          guard ticket == run, !Task.isCancelled else {
            group.cancelAll()
            break
          }
          byID[row.id] = row
          sections = chosen.compactMap { byID[$0.id] }
          if let next = i.next() { add(next) }
        }
      }
      if ticket == run { running = false }
    }
  }
#endif
