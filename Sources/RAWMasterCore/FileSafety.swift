import CryptoKit
import Darwin
import Foundation

struct FileStamp: Equatable {
  var size: Int64
  var modified: Date
  var inode: UInt64
  var device: UInt64
}

private struct RegularFileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let size: Int64
  let modificationSeconds, modificationNanoseconds: Int
  let changeSeconds, changeNanoseconds: Int

  private init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
    size = value.st_size
    modificationSeconds = value.st_mtimespec.tv_sec
    modificationNanoseconds = value.st_mtimespec.tv_nsec
    changeSeconds = value.st_ctimespec.tv_sec
    changeNanoseconds = value.st_ctimespec.tv_nsec
  }

  static func openFile(_ descriptor: Int32, at url: URL) throws -> Self {
    var value = Darwin.stat()
    guard fstat(descriptor, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard value.st_mode & S_IFMT == S_IFREG else { throw LibraryError.invalid("不是普通文件：\(url.path)") }
    return Self(value)
  }

  static func namedFile(_ url: URL) -> Self? {
    var value = Darwin.stat()
    guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
    return Self(value)
  }

  func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }

  func matchesAfterRename(_ other: Self) -> Bool {
    sameFile(as: other) && size == other.size && modificationSeconds == other.modificationSeconds
      && modificationNanoseconds == other.modificationNanoseconds
  }
}

package struct LocalDirectoryIdentity: Codable, Sendable {
  private let volume: String?
  private let device: UInt64
  private let inode: UInt64
  private let birth: Date?

  package init(_ directory: URL) throws {
    let url = FileSafety.canonical(directory)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
      let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value, inode != 0 else {
      throw LibraryError.invalid("找不到可核对身份的目录：\(url.path)")
    }
    volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    self.device = device
    self.inode = inode
    birth = attributes[.creationDate] as? Date
  }

  package func matches(_ current: Self) -> Bool {
    guard inode == current.inode, birth == current.birth else { return false }
    if let volume { return volume == current.volume }
    return current.volume == nil && device == current.device
  }
}

enum FileSafety {
  static func canonical(_ url: URL) -> URL {
    let u = url.standardizedFileURL
    if FileManager.default.fileExists(atPath: u.path) {
      return u.resolvingSymlinksInPath().standardizedFileURL
    }
    let parent = u.deletingLastPathComponent()
    if parent.path == u.path { return u }
    return canonical(parent).appendingPathComponent(u.lastPathComponent).standardizedFileURL
  }
  static func contains(_ root: URL, _ child: URL) -> Bool {
    let r = canonical(root).path
    let c = canonical(child).path
    return c == r || c.hasPrefix(r == "/" ? "/" : r + "/")
  }
  static func checkTarget(_ target: URL, sources: [URL]) throws {
    for source in sources where contains(source, target) {
      throw LibraryError.invalid("目标目录不能位于源素材目录内：\(target.path)")
    }
  }
  static func stat(_ url: URL) throws -> FileStamp {
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    guard a[.type] as? FileAttributeType == .typeRegular else {
      throw LibraryError.invalid("不是普通文件：\(url.path)")
    }
    return FileStamp(
      size: (a[.size] as? NSNumber)?.int64Value ?? 0,
      modified: a[.modificationDate] as? Date ?? .distantPast,
      inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
      device: (a[.systemNumber] as? NSNumber)?.uint64Value ?? 0)
  }
  static func hash(_ url: URL, cancel: () throws -> Void = {}) throws -> String {
    try withStableRegularFile(at: url) { handle, _ in try hash(handle, cancel: cancel) }
  }

  static func withStableRegularFile<T>(at url: URL, _ read: (FileHandle, Int64) throws -> T) throws -> T {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    let before = try RegularFileIdentity.openFile(descriptor, at: url)
    guard RegularFileIdentity.namedFile(url) == before else { throw LibraryError.sourceChanged(url.path) }
    let result = try read(handle, before.size)
    guard try RegularFileIdentity.openFile(descriptor, at: url) == before,
          RegularFileIdentity.namedFile(url) == before else { throw LibraryError.sourceChanged(url.path) }
    return result
  }

  static func hash(_ handle: FileHandle, cancel: () throws -> Void = {}) throws -> String {
    var digest = SHA256()
    while true {
      try cancel()
      // FileHandle's Objective-C read buffers otherwise survive the long-lived import
      // worker's ambient pool. Consume each buffer before draining this chunk's pool.
      let count = try autoreleasepool {
        let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
        guard !chunk.isEmpty else { return 0 }
        digest.update(data: chunk)
        return chunk.count
      }
      if count == 0 { break }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func safeRelative(_ path: String) throws -> String {
    let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !pieces.contains(".."), !pieces.contains("."),
      !pieces.contains("")
    else { throw LibraryError.invalid("不安全的相对路径：\(path)") }
    return path
  }
  /// Never replaces an existing file, including races. Only this operation's private temporary file is removed.
  static func verifiedCopy(
    source: URL, target: URL, expectedHash: String?, protectedRoots: [URL],
    allowAlternateTarget: Bool = true,
    beforePublish: () throws -> Void = {}, inspectSource: ((FileHandle, Int64) throws -> Void)? = nil,
    cancel: () throws -> Void
  ) throws -> (URL, String) {
    try checkTarget(target, sources: protectedRoots)
    try cancel()
    let before = try stat(source)
    guard canonical(source).path != canonical(target).path else {
      throw LibraryError.invalid("目标不能指向源文件")
    }
    try beforePublish()
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try checkTarget(target, sources: protectedRoots)
    let temporary = target.deletingLastPathComponent().appendingPathComponent(
      ".rawmaster-\(UUID().uuidString).partial")
    try checkTarget(temporary, sources: protectedRoots)
    try beforePublish()
    let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o666)
    guard descriptor >= 0 else {
      throw LibraryError.invalid("无法创建临时文件，请检查磁盘容量和权限")
    }
    let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? output.close() }
    let created = try RegularFileIdentity.openFile(descriptor, at: temporary)
    defer {
      if let named = RegularFileIdentity.namedFile(temporary), created.sameFile(as: named) {
        try? FileManager.default.removeItem(at: temporary)
      }
    }
    let hash = try withStableRegularFile(at: source) { input, size in
      var digest = SHA256()
      while true {
        try cancel()
        let count = try autoreleasepool {
          let data = try input.read(upToCount: 1024 * 1024) ?? Data()
          guard !data.isEmpty else { return 0 }
          try output.write(contentsOf: data)
          digest.update(data: data)
          return data.count
        }
        if count == 0 { break }
      }
      let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
      if let expectedHash, expectedHash != hash { throw LibraryError.sourceChanged(source.path) }
      try inspectSource?(input, size)
      return hash
    }
    try output.synchronize()
    guard before == (try stat(source)) else { throw LibraryError.sourceChanged(source.path) }
    let verified = try RegularFileIdentity.openFile(descriptor, at: temporary)
    try output.seek(toOffset: 0)
    guard try self.hash(output, cancel: cancel) == hash else {
      throw LibraryError.invalid("复制校验失败")
    }
    var candidate = target
    var suffix = 0
    while true {
      try cancel()
      try beforePublish()
      try checkTarget(candidate, sources: protectedRoots)
      guard try RegularFileIdentity.openFile(descriptor, at: temporary) == verified,
            RegularFileIdentity.namedFile(temporary) == verified else {
        throw LibraryError.invalid("已校验的临时副本发生变化")
      }
      if FileManager.default.fileExists(atPath: candidate.path) {
        if canonical(candidate).path == canonical(source).path
          || (try? stat(candidate)).map({ $0.inode == before.inode && $0.device == before.device })
            == true
        {
          throw LibraryError.invalid("目标与源文件为同一文件")
        }
        if (try? self.hash(candidate, cancel: cancel)) == hash { return (candidate, hash) }
        guard allowAlternateTarget else { throw LibraryError.invalid("冻结的交付文件名已由不同内容占用。") }
        suffix += 1
        candidate = target.deletingLastPathComponent().appendingPathComponent(
          target.deletingPathExtension().lastPathComponent + "-\(suffix)"
        ).appendingPathExtension(target.pathExtension)
        continue
      }
      if allowAlternateTarget {
        do {
          try FileManager.default.moveItem(at: temporary, to: candidate)
        } catch {
          if FileManager.default.fileExists(atPath: candidate.path) { continue }
          throw error
        }
      } else if renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL)) != 0 {
        let code = errno
        if code == EEXIST, FileManager.default.fileExists(atPath: candidate.path) { continue }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
      // Rename changes ctime. Keep the checked descriptor open so an inode cannot be reused.
      let published = try RegularFileIdentity.openFile(descriptor, at: candidate)
      guard verified.matchesAfterRename(published), RegularFileIdentity.namedFile(candidate) == published else {
        throw LibraryError.invalid("发布路径未指向已校验的副本")
      }
      return (candidate, hash)
    }
  }
}

/// Lock use is confined to short synchronous operations; workers never hold it over an await.
final class JobControl: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var cancelled = false
  private var pausing = false
  func begin() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !active else { throw LibraryError.busy }
    active = true
    cancelled = false
    pausing = false
  }
  func finish() {
    lock.lock()
    active = false
    lock.unlock()
  }
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  func pause() {
    lock.lock()
    pausing = true
    cancelled = true
    lock.unlock()
  }
  var isPausing: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pausing
  }
  func check() throws {
    lock.lock()
    let c = cancelled
    lock.unlock()
    if c || Task.isCancelled { throw LibraryError.cancelled }
  }
}
