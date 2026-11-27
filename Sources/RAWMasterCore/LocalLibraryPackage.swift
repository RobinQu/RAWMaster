import CSQLite
import CryptoKit
import Darwin
import Foundation
import RAWMasterLibrary

public enum LocalLibraryDisposition: Sendable {
  case keepIdentity, independentCopy
}

public enum LocalLibraryRelationship: Sendable {
  case known, new, copy(LocalLibraryRecent), ambiguous(LocalLibraryRecent)
}

private final class LibraryPackageAccess: @unchecked Sendable {
  private let url: URL
  private let scoped: Bool

  init(_ url: URL) {
    self.url = url
    scoped = url.startAccessingSecurityScopedResource()
  }

  deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct LibraryPackageBinding: Codable, Equatable, Sendable {
  var format: Int = 1
  let libraryID: String
  let database: String
  let root: String
  let physicalIdentity: String
  var previousLibraryID: String? = nil

  static let metadataKey = "localPackage.binding.v1"
  static let filename = "library.json"

  func validate(database filename: String) throws {
    guard format == 1, database == filename, !libraryID.isEmpty, root.hasPrefix("/"), !physicalIdentity.isEmpty else {
      throw LibraryError.invalid("无法识别资料库包的清单。")
    }
  }
}

public struct LocalLibraryPackage: Sendable {
  public enum Kind: Sendable { case working, legacy, backup }

  public static let pathExtension = "rawmasterlibrary"
  static let databaseName = "library.sqlite"
  public let root: URL
  public let database: URL
  public let libraryID: String?
  public let physicalIdentity: String
  public let kind: Kind
  public var name: String {
    if database.lastPathComponent != Self.databaseName { return database.deletingPathExtension().lastPathComponent }
    return root.pathExtension.lowercased() == Self.pathExtension ? root.deletingPathExtension().lastPathComponent : root.lastPathComponent
  }

  fileprivate let access: LibraryPackageAccess
  fileprivate let legacyAccess: OpenLibraryLocation?
  let binding: LibraryPackageBinding?
  let version: Int
  fileprivate let restored: Bool
  fileprivate let hasManifest: Bool
  fileprivate let previousRoot: URL?

  public static func inspect(_ url: URL) throws -> Self { try inspect(url, legacyAccess: nil) }

  fileprivate static func inspect(_ url: URL, legacyAccess: OpenLibraryLocation?) throws -> Self {
    guard url.isFileURL else { throw LibraryError.invalid("请选择本机资料库文件。") }
    let access = LibraryPackageAccess(url)
    let alias = (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
      ? try URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) : url
    let selected = alias.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory) else {
      throw LibraryError.invalid("找不到资料库。请接回磁盘或重新定位。")
    }
    let root = isDirectory.boolValue ? selected : selected.deletingLastPathComponent()
    let database = isDirectory.boolValue ? root.appendingPathComponent(databaseName) : selected
    let manifest = root.appendingPathComponent(LibraryPackageBinding.filename)
    let backup = root.appendingPathComponent("manifest.json")
    let hasManifest = try existsRegular(manifest)
    let hasBackup = try existsRegular(backup)
    guard !(hasManifest && hasBackup) else { throw LibraryError.invalid("资料库包同时包含工作库与备份清单。") }
    let hasPackageExtension = root.pathExtension.caseInsensitiveCompare(pathExtension) == .orderedSame
    if hasManifest || hasPackageExtension || hasBackup {
      guard database.lastPathComponent == databaseName else { throw LibraryError.invalid("请选择资料库包本身。") }
    }
    let stamp = try FileSafety.stat(database)
    let identity = try physicalIdentity(for: database, stamp: stamp)
    let snapshot = try readCatalog(database)
    let manifestBinding = hasManifest ? try JSONDecoder().decode(LibraryPackageBinding.self, from: Data(contentsOf: manifest)) : nil
    try manifestBinding?.validate(database: database.lastPathComponent)
    try snapshot.binding?.validate(database: database.lastPathComponent)
    if let manifestBinding, manifestBinding.libraryID != snapshot.id {
      // The database transaction is authoritative if a fork committed before its manifest was replaced.
      guard let binding = snapshot.binding, binding.libraryID == snapshot.id,
        binding.root == root.path, binding.physicalIdentity == identity,
        binding.previousLibraryID == manifestBinding.libraryID else {
        throw LibraryError.invalid("资料库清单和目录身份不一致。")
      }
    }
    guard snapshot.binding == nil || snapshot.binding?.libraryID == snapshot.id else {
      throw LibraryError.invalid("无法核对已登记的资料库身份。")
    }
    let kind: Kind = hasBackup ? .backup : (hasPackageExtension || hasManifest ? .working : .legacy)
    let binding = snapshot.binding ?? manifestBinding
    let oldRoot = binding.map { URL(fileURLWithPath: $0.root, isDirectory: true) }
      ?? (kind == .working ? unregisteredArchiveRoot(snapshot.archivePath) : nil)
    return Self(root: root, database: database, libraryID: snapshot.id, physicalIdentity: identity,
      kind: kind, access: access, legacyAccess: legacyAccess, binding: binding,
      version: snapshot.version, restored: try existsRegular(root.appendingPathComponent("restoration.json")),
      hasManifest: hasManifest, previousRoot: oldRoot)
  }

  /// The OS lock is keyed by volume and inode, so a same-volume move preserves it.
  public func acquireWriter() throws -> LocalLibraryWriter {
    guard kind != .backup else { throw LibraryError.invalid("请先从备份恢复工作资料库。") }
    try Self.validateWritableVolume(root)
    guard FileManager.default.isWritableFile(atPath: database.path) else {
      throw LibraryError.invalid("没有资料库文件的写入权限。")
    }
    return try LocalLibraryWriter(package: self)
  }

  public func relationship(to recent: [LocalLibraryRecent]) -> LocalLibraryRelationship {
    if isUnregisteredRestore { return .new }
    if recent.contains(where: { $0.physicalIdentity == physicalIdentity && $0.libraryID == libraryID }) {
      return .known
    }
    guard let libraryID else { return .new }
    let registered = binding.map { LocalLibraryRecent(binding: $0) }
    let peers = recent.filter { $0.libraryID == libraryID } + (registered.map { [$0] } ?? [])
    if peers.contains(where: { $0.physicalIdentity == physicalIdentity }) { return .known }
    if let available = peers.first(where: { (try? $0.resolve().physicalIdentity) == $0.physicalIdentity }) {
      return .copy(available)
    }
    if let previous = peers.first { return .ambiguous(previous) }
    if let previousRoot, previousRoot.path != root.path {
      if let original = try? Self.inspect(previousRoot), original.libraryID == libraryID,
        original.physicalIdentity != physicalIdentity { return .copy(LocalLibraryRecent(original)) }
      return .ambiguous(LocalLibraryRecent(binding: .init(libraryID: libraryID, database: database.lastPathComponent,
        root: previousRoot.path, physicalIdentity: "unverified")))
    }
    return .new
  }

  fileprivate var isUnregisteredRestore: Bool {
    restored && !hasManifest && (binding?.root != root.path || binding?.physicalIdentity != physicalIdentity)
  }

  public static func create(at url: URL) throws -> Self {
    let access = LibraryPackageAccess(url)
    return try withExtendedLifetime(access) {
      try stagePackage(at: url) { stage, destination in
        let store = try LibraryStore(databaseURL: stage.appendingPathComponent(databaseName))
        try seal(store, at: stage, destination: destination, oldRoot: nil, disposition: .keepIdentity)
      }
    }
  }

  public func restore(to url: URL) throws -> Self {
    guard kind == .backup else { throw LibraryError.invalid("所选资料库没有备份清单。") }
    let destinationAccess = LibraryPackageAccess(url)
    return try withExtendedLifetime(destinationAccess) {
      try Self.stagePackage(at: url) { stage, destination in
        guard !FileSafety.contains(root, destination) else { throw LibraryError.invalid("请在备份包之外选择恢复位置。") }
        let manifest = root.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifest)
        let targetDB = stage.appendingPathComponent(Self.databaseName)
        if (try? JSONDecoder().decode(EditingLibraryBackupManifest.self, from: data)) != nil {
          let store = try LibraryStore.restoreEditingLibrary(from: root, databaseURL: targetDB,
            archiveRoot: stage.appendingPathComponent("EditingArchive", isDirectory: true))
          try Self.seal(store, at: stage, destination: destination, oldRoot: stage, disposition: .independentCopy)
        } else {
          let components = stage.appendingPathComponent("sealed-restoration", isDirectory: true)
          let _: CatalogJSON = try LibraryEngine.shared().request("package", at: database,
            payload: ["op": "restore", "package": root.path, "destination": components.path], as: CatalogJSON.self)
          for child in try FileManager.default.contentsOfDirectory(at: components, includingPropertiesForKeys: nil) {
            try FileManager.default.moveItem(at: child, to: stage.appendingPathComponent(child.lastPathComponent))
          }
          try FileManager.default.removeItem(at: components)
          let store = try LibraryStore(databaseURL: targetDB)
          try Self.seal(store, at: stage, destination: destination, oldRoot: components, disposition: .independentCopy)
        }
      }
    }
  }

  static func physicalIdentity(for database: URL, stamp: FileStamp) throws -> String {
    let volume = try database.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    return (volume ?? "device-\(stamp.device)") + ":\(stamp.inode)"
  }

  static func existsRegular(_ url: URL) throws -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return false }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw LibraryError.invalid("资料库文件类型无效：\(url.lastPathComponent)") }
    return true
  }

  static func validateWritableVolume(_ root: URL) throws {
    let location = try root.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey, .isUbiquitousItemKey])
    let syncedRoots = ["Library/CloudStorage", "Library/Mobile Documents"].map {
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0)
    }
    guard location.volumeIsLocal == true, location.volumeIsReadOnly != true,
      location.isUbiquitousItem != true, !syncedRoots.contains(where: { FileSafety.contains($0, root) }),
      FileManager.default.isWritableFile(atPath: root.path) else {
      throw LibraryError.invalid("请选择可写的本机磁盘或本地挂载的外置磁盘。")
    }
  }

  private static func readCatalog(_ url: URL) throws -> (version: Int, id: String?, binding: LibraryPackageBinding?, archivePath: String?) {
    let wal = URL(fileURLWithPath: url.path + "-wal")
    let hasWAL = try existsRegular(wal)
    _ = try existsRegular(URL(fileURLWithPath: url.path + "-shm"))
    _ = try existsRegular(URL(fileURLWithPath: url.path + "-journal"))
    let before = try FileSafety.stat(url)
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    let name = hasWAL ? url.path : url.absoluteString + "?immutable=1"
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (hasWAL ? 0 : SQLITE_OPEN_URI)
    guard sqlite3_open_v2(name, &db, flags, nil) == SQLITE_OK else { throw DatabaseSchema.error(db) }
    sqlite3_busy_timeout(db, 5_000)
    guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else { throw DatabaseSchema.error(db) }
    let version = try DatabaseSchema.validate(db)
    guard version > 0 else { throw LibraryError.invalid("所选文件没有 RAWMaster 资料库目录。") }
    let id = version >= 8 ? try DatabaseSchema.strings(db, "SELECT value FROM lc_meta WHERE key='libraryID'").first : nil
    guard version < 8 || id?.isEmpty == false else { throw LibraryError.invalid("资料库缺少身份。") }
    let raw = try DatabaseSchema.strings(db, "SELECT value FROM metadata WHERE key='\(LibraryPackageBinding.metadataKey)'").first
    let binding = try raw.map { try JSONDecoder().decode(LibraryPackageBinding.self, from: Data($0.utf8)) }
    let archivePath = try DatabaseSchema.strings(db, "SELECT value FROM metadata WHERE key='editingArchiveRoot'").first
    if !hasWAL {
      guard try !existsRegular(wal), try FileSafety.stat(url) == before else {
        throw LibraryError.invalid("资料库在检查期间变化，请重新打开。")
      }
    }
    return (version, id, binding, archivePath)
  }

  private static func unregisteredArchiveRoot(_ path: String?) -> URL? {
    guard let path, path.hasPrefix("/") else { return nil }
    let archive = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let recorded = archive.deletingLastPathComponent()
    guard ["EditingArchive", "Editing Archive"].contains(archive.lastPathComponent),
      recorded.pathExtension.lowercased() == pathExtension else { return nil }
    return recorded
  }

  private static func validatedDestination(_ selected: URL) throws -> URL {
    guard selected.isFileURL else { throw LibraryError.invalid("请选择本机资料库位置。") }
    let withExtension = selected.pathExtension.caseInsensitiveCompare(pathExtension) == .orderedSame
      ? selected : selected.appendingPathExtension(pathExtension)
    let parent = withExtension.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    try validateWritableVolume(parent)
    // Check every reserved path through lstat so a dangling symlink cannot be replaced.
    let destination = parent.appendingPathComponent(withExtension.lastPathComponent, isDirectory: true)
    var existing = stat()
    guard lstat(destination.path, &existing) != 0, errno == ENOENT else {
      throw LibraryError.invalid("所选名称已存在。请选择新的资料库位置。")
    }
    return destination
  }

  static func stagePackage(at url: URL, build: (URL, URL) throws -> Void) throws -> Self {
    let destination = try validatedDestination(url)
    let parent = destination.deletingLastPathComponent()
    let stage = parent.appendingPathComponent(".rawmaster-library-\(UUID().uuidString).partial", isDirectory: true)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: stage) }
    try build(stage, destination)
    _ = try inspect(stage)
    try synchronizeDirectory(stage)
    guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try synchronizeDirectory(parent)
    return try inspect(destination)
  }

  static func seal(_ store: LibraryStore, at stage: URL, destination: URL, oldRoot: URL?, disposition: LocalLibraryDisposition) throws {
    let stamp = try FileSafety.stat(store.databaseURL)
    let identity = try physicalIdentity(for: store.databaseURL, stamp: stamp)
    let binding = try store.prepareLocalPackage(root: destination, physicalIdentity: identity, previousRoot: oldRoot,
      disposition: disposition, packageFilesAt: stage)
    try writeManifest(binding, at: stage)
    try store.locked { try store.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    let db = try FileHandle(forReadingFrom: store.databaseURL)
    defer { try? db.close() }
    try db.synchronize()
  }

  static func writeManifest(_ binding: LibraryPackageBinding, at root: URL) throws {
    let url = root.appendingPathComponent(LibraryPackageBinding.filename)
    _ = try existsRegular(url)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(binding).write(to: url, options: .atomic)
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    try file.synchronize()
    try synchronizeDirectory(root)
  }

  private static func synchronizeDirectory(_ root: URL) throws {
    let fd = open(root.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
}

/// Owns the security-scoped URL and the non-blocking writer lock for one physical database.
public final class LocalLibraryWriter: @unchecked Sendable {
  private let descriptor: Int32
  private let writerLock: Int32
  public let package: LocalLibraryPackage

  fileprivate init(package: LocalLibraryPackage) throws {
    let fd = open(package.database.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var lockFD: Int32 = -1
    do {
      lockFD = try Self.openLock(for: package.physicalIdentity)
      guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK { throw LibraryError.invalid("此资料库已在 RAWMaster 的另一个会话打开。") }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try Self.checkFile(fd: fd, database: package.database)
      let current = try LocalLibraryPackage.inspect(package.database, legacyAccess: package.legacyAccess)
      guard package.physicalIdentity == current.physicalIdentity, package.libraryID == current.libraryID else {
        throw LibraryError.invalid("资料库身份刚刚变化，请重新打开。")
      }
      // Keep the picker's scope even when inspection used an unscoped canonical URL.
      self.package = package
      descriptor = fd
      writerLock = lockFD
    } catch {
      if lockFD >= 0 { close(lockFD) }
      close(fd)
      throw error
    }
  }

  deinit { close(descriptor); close(writerLock) }

  private static func openLock(for identity: String) throws -> Int32 {
    // SQLite also locks the database inode. Use a separate lease shared by RAWMaster
    // instances under this macOS account and hold the database fd only to validate selection.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-library-writers", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(root) }
    var info = stat()
    guard fstat(root, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
      throw LibraryError.invalid("无法验证本机的资料库锁目录。")
    }
    let filename = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    let lock = openat(root, filename, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
    guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
      close(lock)
      throw LibraryError.invalid("资料库锁文件无效。")
    }
    return lock
  }

  private static func checkFile(fd: Int32, database: URL) throws {
    var live = stat(), path = stat()
    guard fstat(fd, &live) == 0, lstat(database.path, &path) == 0, live.st_mode & S_IFMT == S_IFREG,
      live.st_ino == path.st_ino, live.st_dev == path.st_dev else {
      throw LibraryError.invalid("资料库位置刚刚变化，请重新打开。")
    }
  }

  private func inspectLocked() throws -> LocalLibraryPackage {
    try Self.checkFile(fd: descriptor, database: package.database)
    let observed = try LocalLibraryPackage.inspect(package.database, legacyAccess: package.legacyAccess)
    try Self.checkFile(fd: descriptor, database: package.database)
    return observed
  }

  public func openStore() throws -> LibraryStore {
    try Self.checkFile(fd: descriptor, database: package.database)
    let store = try LibraryStore(databaseURL: package.database, requireExisting: true)
    try Self.checkFile(fd: descriptor, database: package.database)
    return store
  }

  public func prepare(_ disposition: LocalLibraryDisposition = .keepIdentity) throws -> LocalLibraryPackage {
    let current = try inspectLocked()
    let detachedRestore = current.isUnregisteredRestore
    let effective: LocalLibraryDisposition = detachedRestore ? .independentCopy : disposition
    if current.kind == .legacy, !detachedRestore, effective == .keepIdentity, current.version == DatabaseSchema.version {
      return current
    }
    if current.kind == .working, effective == .keepIdentity, current.version == DatabaseSchema.version,
      let binding = current.binding, binding.root == current.root.path, binding.physicalIdentity == current.physicalIdentity {
      // Also repair the small manifest if a previous activation stopped after its SQLite commit.
      let manifest = current.root.appendingPathComponent(LibraryPackageBinding.filename)
      if (try? JSONDecoder().decode(LibraryPackageBinding.self, from: Data(contentsOf: manifest))) != binding {
        try LocalLibraryPackage.writeManifest(binding, at: current.root)
      }
      return current
    }
    if effective == .keepIdentity, case .copy = current.relationship(to: []) {
      throw LibraryError.invalid("原资料库仍可访问。请选择作为独立资料库打开。")
    }
    let store = try openStore()
    let binding = try store.prepareLocalPackage(root: current.root, physicalIdentity: current.physicalIdentity,
      previousRoot: current.previousRoot, disposition: effective, packageFilesAt: current.root,
      requireExistingResources: detachedRestore)
    if current.kind == .working { try LocalLibraryPackage.writeManifest(binding, at: current.root) }
    return try LocalLibraryPackage.inspect(package.database, legacyAccess: package.legacyAccess)
  }

  public func migrate(to url: URL) throws -> LocalLibraryPackage {
    let destinationAccess = LibraryPackageAccess(url)
    return try withExtendedLifetime(destinationAccess) {
      try LocalLibraryPackage.stagePackage(at: url) { stage, destination in
        guard !FileSafety.contains(package.root, destination) else {
          throw LibraryError.invalid("请在原资料库目录之外选择迁移位置。")
        }
        let source = try inspectLocked()
        let stagedDatabase = stage.appendingPathComponent(LocalLibraryPackage.databaseName)
        try LibraryStore.snapshotLocalPackage(from: source.database, to: stagedDatabase)
        let store = try LibraryStore(databaseURL: stagedDatabase)
        let sourceRoot = source.previousRoot ?? source.root
        try store.copyLocalPackageResources(from: source.root, recordedAt: sourceRoot, to: stage, finalRoot: destination)
        try LocalLibraryPackage.seal(store, at: stage, destination: destination, oldRoot: sourceRoot, disposition: .keepIdentity)
      }
    }
  }
}

public struct LocalLibraryRecent: Codable, Sendable, Identifiable {
  public let name: String
  public let path: URL
  public let libraryID: String?
  public let physicalIdentity: String
  private let bookmark: Data?
  public var id: String { libraryID ?? physicalIdentity }

  fileprivate init(_ package: LocalLibraryPackage) {
    name = package.name
    path = package.kind == .legacy ? package.database : package.root
    libraryID = package.libraryID
    physicalIdentity = package.physicalIdentity
    bookmark = (try? path.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
      ?? (try? path.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
  }

  fileprivate init(binding: LibraryPackageBinding) {
    let root = URL(fileURLWithPath: binding.root, isDirectory: true)
    name = root.deletingPathExtension().lastPathComponent
    path = root.appendingPathComponent(binding.database)
    libraryID = binding.libraryID
    physicalIdentity = binding.physicalIdentity
    bookmark = nil
  }

  public func resolve() throws -> LocalLibraryPackage {
    var choices = [path]
    if let bookmark {
      var stale = false
      if let resolved = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
        relativeTo: nil, bookmarkDataIsStale: &stale)) ?? (try? URL(resolvingBookmarkData: bookmark,
          options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)) {
        choices.insert(resolved, at: 0)
      }
    }
    for choice in choices {
      if let candidate = try? LocalLibraryPackage.inspect(choice), candidate.kind != .backup,
        candidate.physicalIdentity == physicalIdentity, candidate.libraryID == libraryID { return candidate }
    }
    throw LibraryError.invalid("找不到原资料库「\(name)」，或原位置已有另一资料库。请重新定位。")
  }
}

public enum LocalLibraryHistory {
  private static let key = "library.recentLocations.v2"

  public static func entries(defaults: UserDefaults = .standard) -> [LocalLibraryRecent] {
    defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([LocalLibraryRecent].self, from: $0) } ?? []
  }

  public static func remember(_ package: LocalLibraryPackage, defaults: UserDefaults = .standard) {
    guard package.kind != .backup else { return }
    let entry = LocalLibraryRecent(package)
    let remaining = entries(defaults: defaults).filter { $0.id != entry.id && $0.physicalIdentity != entry.physicalIdentity }
    if let data = try? JSONEncoder().encode(Array(([entry] + remaining).prefix(12))) {
      defaults.set(data, forKey: key)
    }
  }

  public static func hasLegacySelection(defaults: UserDefaults = .standard) -> Bool {
    LibraryLocation.hasSelection(defaults: defaults)
  }

  public static func legacySelectedPath(defaults: UserDefaults = .standard) -> URL? {
    LibraryLocation.selectedPath(defaults: defaults)
  }

  public static func resolveLegacySelection(defaultURL: URL, defaults: UserDefaults = .standard) throws -> LocalLibraryPackage {
    let legacy = try LibraryLocation.resolve(defaultURL: defaultURL, defaults: defaults)
    return try LocalLibraryPackage.inspect(legacy.database, legacyAccess: legacy)
  }
}
