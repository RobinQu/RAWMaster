import Darwin
import Foundation
import zlib

public enum PresetExchangeError: LocalizedError {
  case invalid(String)
  case noMappableFields([String])
  public var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .noMappableFields(let fields):
      return fields.isEmpty ? "本次没有可写入 XMP 的非零调整" : "无法写入所选设置：" + fields.joined(separator: ", ")
    }
  }
}

enum PresetExchangeLimits {
  static let xmpBytes = 8 * 1024 * 1024
  static let archiveBytes = 64 * 1024 * 1024
  static let batchBytes = 96 * 1024 * 1024
  static let files = 2048

  static func safePath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.isEmpty && !path.contains("\\") && !path.contains(":")
      && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." } && path.utf8.count <= 2048
  }

  static func read(_ url: URL, limit: Int) throws -> Data {
    guard url.isFileURL else { throw PresetExchangeError.invalid("请选择本地文件") }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    return try read(fd: fd, limit: limit)
  }

  /// Pin every directory while walking an approved relative path. Concurrent renames or
  /// symlink substitutions cannot redirect a later component outside the chosen root.
  static func read(root: URL, relative: String, limit: Int) throws -> Data {
    guard root.isFileURL, safePath(relative) else { throw PresetExchangeError.invalid("无效的迁移路径") }
    var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }
    defer { close(directory) }
    let parts = relative.components(separatedBy: "/")
    for part in parts.dropLast() {
      let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
      close(directory)
      directory = next
    }
    guard let name = parts.last else { throw CocoaError(.fileReadNoSuchFile) }
    return try read(fd: openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), limit: limit)
  }

  private static func read(fd: Int32, limit: Int) throws -> Data {
    guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size >= 0, info.st_size <= limit else {
      throw PresetExchangeError.invalid("文件超限或不是常规文件")
    }
    var result = Data()
    while let chunk = try handle.read(upToCount: min(64 * 1024, limit - result.count + 1)), !chunk.isEmpty {
      try Task.checkCancellation()
      guard chunk.count <= limit - result.count else { throw PresetExchangeError.invalid("文件超过字节上限") }
      result.append(chunk)
    }
    return result
  }
}

/// Only stored and deflated regular XMPs are read. Archive paths never become disk paths.
enum PresetExchangeArchive {
  private static let invalid = PresetExchangeError.invalid("ZIP 目录、压缩方法或校验和无效")
  struct Member {
    let path: String
    let data: Data
  }

  static func read(_ data: Data) throws -> (members: [Member], ignored: Int) {
    guard (22...PresetExchangeLimits.archiveBytes).contains(data.count) else { throw invalid }
    func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    let end = stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1).first {
      u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == data.count
    }
    guard let end, u16(end + 4) == 0, u16(end + 6) == 0,
          u16(end + 8) == u16(end + 10) else { throw invalid }
    let count = u16(end + 10), directory = u32(end + 16)
    guard count <= PresetExchangeLimits.files, directory + u32(end + 12) == end else { throw invalid }
    var cursor = directory, total = 0, ignored = 0
    var result: [Member] = [], names: Set<String> = []
    for _ in 0..<count {
      try Task.checkCancellation()
      guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw invalid }
      let flags = u16(cursor + 8), method = u16(cursor + 10)
      let checksum = u32(cursor + 16), packed = u32(cursor + 20), plain = u32(cursor + 24)
      let nameLength = u16(cursor + 28), local = u32(cursor + 42)
      let next = cursor + 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
      guard next <= end, u16(cursor + 34) == 0, flags & (1 | 32 | 64) == 0,
            let path = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else { throw invalid }
      let type = (u32(cursor + 38) >> 16) & 0o170000
      let isDirectory = path.hasSuffix("/")
      let normalized = isDirectory ? String(path.dropLast()) : path
      guard PresetExchangeLimits.safePath(normalized), names.insert(normalized).inserted,
            type == 0 || (isDirectory ? type == 0o040000 : type == 0o100000) else { throw invalid }
      cursor = next
      guard !isDirectory else { continue }
      guard path.lowercased().hasSuffix(".xmp"),
            !path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { ignored += 1; continue }
      guard [0,8].contains(method), plain <= PresetExchangeLimits.xmpBytes,
            plain <= PresetExchangeLimits.batchBytes - total, local + 30 <= directory,
            u32(local) == 0x04034b50, u16(local + 6) == flags, u16(local + 8) == method else { throw invalid }
      let localNameEnd = local + 30 + u16(local + 26)
      let start = localNameEnd + u16(local + 28)
      guard start + packed <= directory,
            String(data: data[(local + 30)..<localNameEnd], encoding: .utf8) == path else { throw invalid }
      let payload: Data
      if method == 0 {
        guard packed == plain else { throw invalid }
        payload = data.subdata(in: start..<(start + packed))
      } else {
        payload = try inflateRaw(data, range: start..<(start + packed), size: plain)
      }
      let crc = payload.withUnsafeBytes { buffer in crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(plain)) }
      guard crc == checksum else { throw invalid }
      total += plain
      result.append(Member(path: path, data: payload))
    }
    guard cursor == end else { throw invalid }
    return (result, ignored)
  }

  private static func inflateRaw(_ data: Data, range: Range<Int>, size: Int) throws -> Data {
    var output = Data(count: size + 1)
    let capacity = output.count
    var stream = z_stream()
    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid }
    defer { inflateEnd(&stream) }
    let status = data.withUnsafeBytes { input in
      output.withUnsafeMutableBytes { result -> Int32 in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: range.lowerBound))
        stream.avail_in = uInt(range.count)
        stream.next_out = result.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(capacity)
        return inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, stream.total_in == range.count, stream.total_out == size else { throw invalid }
    output.removeLast()
    return output
  }
}
