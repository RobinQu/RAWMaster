import CryptoKit
import Foundation

struct FileStamp: Equatable {
  var size: Int64
  var modified: Date
  var inode: UInt64
  var device: UInt64
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
    let before = try stat(url)
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var digest = SHA256()
    while true {
      try cancel()
      let chunk = try h.read(upToCount: 1024 * 1024) ?? Data()
      if chunk.isEmpty { break }
      digest.update(data: chunk)
    }
    guard before == (try stat(url)) else { throw LibraryError.sourceChanged(url.path) }
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
    cancel: () throws -> Void
  ) throws -> (URL, String) {
    try checkTarget(target, sources: protectedRoots)
    try cancel()
    let before = try stat(source)
    guard canonical(source).path != canonical(target).path else {
      throw LibraryError.invalid("目标不能指向源文件")
    }
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try checkTarget(target, sources: protectedRoots)
    let temporary = target.deletingLastPathComponent().appendingPathComponent(
      ".rawmaster-\(UUID().uuidString).partial")
    try checkTarget(temporary, sources: protectedRoots)
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
      throw LibraryError.invalid("无法创建临时文件，请检查磁盘容量和权限")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: temporary)
    defer { try? output.close() }
    var digest = SHA256()
    do {
      while true {
        try cancel()
        let data = try input.read(upToCount: 1024 * 1024) ?? Data()
        if data.isEmpty { break }
        try output.write(contentsOf: data)
        digest.update(data: data)
      }
      try output.synchronize()
      try input.close()
      try output.close()
    } catch {
      try? input.close()
      try? output.close()
      throw error
    }
    guard before == (try stat(source)) else { throw LibraryError.sourceChanged(source.path) }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    if let expectedHash, expectedHash != hash { throw LibraryError.sourceChanged(source.path) }
    guard try self.hash(temporary, cancel: cancel) == hash else {
      throw LibraryError.invalid("复制校验失败")
    }
    var candidate = target
    var suffix = 0
    while true {
      try cancel()
      try checkTarget(candidate, sources: protectedRoots)
      if FileManager.default.fileExists(atPath: candidate.path) {
        if canonical(candidate).path == canonical(source).path
          || (try? stat(candidate)).map({ $0.inode == before.inode && $0.device == before.device })
            == true
        {
          throw LibraryError.invalid("目标与源文件为同一文件")
        }
        if (try? self.hash(candidate, cancel: cancel)) == hash { return (candidate, hash) }
        suffix += 1
        candidate = target.deletingLastPathComponent().appendingPathComponent(
          target.deletingPathExtension().lastPathComponent + "-\(suffix)"
        ).appendingPathExtension(target.pathExtension)
        continue
      }
      do {
        try FileManager.default.moveItem(at: temporary, to: candidate)
        return (candidate, hash)
      } catch {
        if FileManager.default.fileExists(atPath: candidate.path) { continue }
        throw error
      }
    }
  }
}

/// Lock use is confined to short synchronous operations; workers never hold it over an await.
final class JobControl: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var cancelled = false
  func begin() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !active else { throw LibraryError.busy }
    active = true
    cancelled = false
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
  func check() throws {
    lock.lock()
    let c = cancelled
    lock.unlock()
    if c || Task.isCancelled { throw LibraryError.cancelled }
  }
}
