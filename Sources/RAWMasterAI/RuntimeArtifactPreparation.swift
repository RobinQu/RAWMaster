import CryptoKit
import Darwin
import Foundation

enum RuntimeArtifactFiles {
  // URL directory hints/trailing slashes are presentation, not filesystem identity. Do not
  // resolve here: callers explicitly choose which side must be unredirected/canonical.
  static func pathIdentity(_ url: URL) -> String {
    var path = url.standardizedFileURL.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
  }
  static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(operation: body)
    return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }
  static func validSHA(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
  static func validID(_ value: String) -> Bool { !value.isEmpty && value.count <= 160 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
  static func safeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains(":") &&
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
      value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  static func safeLink(_ target: String, at path: String) -> Bool {
    guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"), !target.contains(":"),
          !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
    var parts = path.split(separator: "/").dropLast().map(String.init)
    for part in target.split(separator: "/") {
      if part == ".." { guard !parts.isEmpty else { return false }; parts.removeLast() }
      else if part != "." { parts.append(String(part)) }
    }
    return !parts.isEmpty
  }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func hash(_ file: URL) throws -> String {
    let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw LocalAISetupError.unsafeArtifact }; defer { Darwin.close(fd) }
    var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw LocalAISetupError.unsafeArtifact }
    var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw LocalAISetupError.unsafeArtifact }; if count == 0 { break }
      buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
    }
    var after = stat(); guard fstat(fd, &after) == 0, same(before, after) else { throw LocalAISetupError.unsafeArtifact }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func same(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode &&
      a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
  static func writeJSON<T: Encodable>(_ value: T, to file: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    var old = stat()
    if lstat(file.path, &old) == 0 {
      guard old.st_mode & S_IFMT == S_IFREG, old.st_nlink == 1 else { throw LocalAISetupError.unsafeArtifact }
    } else if errno != ENOENT { throw LocalAISetupError.unsafeArtifact }
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".journal-" + UUID().uuidString)
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LocalAISetupError.unsafeArtifact }; defer { Darwin.close(fd) }
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.withUnsafeBytes { bytes in
      var position = 0
      while position < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), bytes.count - position)
        if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw LocalAISetupError.preparationFailed }; position += count
      }
    }
    guard fsync(fd) == 0, rename(temporary.path, file.path) == 0 else { throw LocalAISetupError.preparationFailed }
    let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw LocalAISetupError.unsafeArtifact }; defer { Darwin.close(parent) }
    guard fsync(parent) == 0 else { throw LocalAISetupError.preparationFailed }
  }
  static func run(_ executable: URL, arguments: [String], log: URL, environment: [String: String]? = nil) async throws {
    try Task.checkCancellation()
    let fd = Darwin.open(log.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LocalAISetupError.unsafeArtifact }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    let child = Process(); child.executableURL = executable; child.arguments = arguments
    child.environment = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1"]
    child.standardOutput = handle; child.standardError = handle
    try child.run()
    try await withTaskCancellationHandler(operation: {
      await Task.detached { child.waitUntilExit() }.value
      try Task.checkCancellation()
      guard child.terminationStatus == 0 else { throw LocalAISetupError.preparationFailed }
    }, onCancel: { if child.isRunning { child.terminate() } })
  }
}

/// One process owns each runtime root across starts, installs, rollback and preparation.
/// CLOEXEC prevents children from retaining admission after the application exits.
final class RuntimeEnvironmentFileLease: @unchecked Sendable {
  private let fd: Int32
  init(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.resolvingSymlinksInPath().appendingPathComponent(".environment-mutation.lock")
    let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw LocalAISetupError.unsafeArtifact }
    var value = stat()
    guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
          flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw AIServiceError.busy }
    fd = descriptor
  }
  deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}

struct RuntimePackageManifest: Decodable {
  struct Entry: Decodable { let path: String; let type: String?; let target: String?; let size: Int64?; let sha256: String? }
  let id: String
  let files: [Entry]
}

/// Data-only ZIP admission before any extractor or package Python is executed. ZIP64/encrypted
/// archives are outside this fixed <4GiB package format. Internal relative Python links survive.
enum RuntimeZipAdmission {
  struct Entry { let path: String; let isDirectory: Bool; let link: String? }
  static func entries(_ url: URL) throws -> [Entry] {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let size = try handle.seekToEnd(); guard size >= 22 else { throw LocalAISetupError.unsafeArtifact }
    let tailSize = min(size, 65_557); try handle.seek(toOffset: size - tailSize)
    let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
    func u16(_ d: Data, _ p: Int) throws -> Int { guard p >= 0, p + 2 <= d.count else { throw LocalAISetupError.unsafeArtifact }; return Int(d[p]) | Int(d[p + 1]) << 8 }
    func u32(_ d: Data, _ p: Int) throws -> Int { try u16(d, p) | u16(d, p + 2) << 16 }
    var end: Int?
    for p in stride(from: tail.count - 22, through: 0, by: -1) {
      if try u32(tail, p) == 0x06054b50, p + 22 + (try u16(tail, p + 20)) == tail.count { end = p; break }
    }
    guard let e = end, try u16(tail, e + 4) == 0, try u16(tail, e + 6) == 0,
          try u16(tail, e + 8) == u16(tail, e + 10) else { throw LocalAISetupError.unsafeArtifact }
    let count = try u16(tail, e + 10), bytes = try u32(tail, e + 12), offset = try u32(tail, e + 16)
    guard (1...24_000).contains(count), bytes > 0, bytes <= 16_777_216,
          UInt64(offset + bytes) == size - tailSize + UInt64(e) else { throw LocalAISetupError.unsafeArtifact }
    try handle.seek(toOffset: UInt64(offset)); let directory = try handle.read(upToCount: bytes) ?? Data()
    guard directory.count == bytes else { throw LocalAISetupError.unsafeArtifact }
    var position = 0, result: [Entry] = [], names = Set<String>()
    for _ in 0..<count {
      try Task.checkCancellation()
      guard try u32(directory, position) == 0x02014b50 else { throw LocalAISetupError.unsafeArtifact }
      let flags = try u16(directory, position + 8), method = try u16(directory, position + 10)
      let compressed = try u32(directory, position + 20), unpacked = try u32(directory, position + 24)
      let nameSize = try u16(directory, position + 28), extra = try u16(directory, position + 30), comment = try u16(directory, position + 32)
      let attributes = try u32(directory, position + 38), localOffset = try u32(directory, position + 42)
      guard flags & 1 == 0, method == 0 || method == 8, nameSize > 0,
            position + 46 + nameSize + extra + comment <= directory.count,
            localOffset >= 0, localOffset + 30 < offset else { throw LocalAISetupError.unsafeArtifact }
      let nameData = directory.subdata(in: position + 46..<position + 46 + nameSize)
      guard let name = String(data: nameData, encoding: .utf8) else { throw LocalAISetupError.unsafeArtifact }
      let isDirectory = name.hasSuffix("/"), path = isDirectory ? String(name.dropLast()) : name
      let folded = path.precomposedStringWithCanonicalMapping.lowercased()
      guard RuntimeArtifactFiles.safeRelativePath(path), names.insert(folded).inserted else { throw LocalAISetupError.unsafeArtifact }
      let mode = attributes >> 16, kind = mode & 0o170000
      guard kind == 0 || kind == 0o100000 || kind == 0o040000 || kind == 0o120000 else { throw LocalAISetupError.unsafeArtifact }
      try handle.seek(toOffset: UInt64(localOffset)); let local = try handle.read(upToCount: 30) ?? Data()
      guard try u32(local, 0) == 0x04034b50, try u16(local, 8) == method,
            try u16(local, 26) == nameSize else { throw LocalAISetupError.unsafeArtifact }
      let localExtra = try u16(local, 28), bodyOffset = localOffset + 30 + nameSize + localExtra
      guard bodyOffset + compressed <= offset else { throw LocalAISetupError.unsafeArtifact }
      let localName = try handle.read(upToCount: nameSize) ?? Data()
      guard localName == nameData else { throw LocalAISetupError.unsafeArtifact }
      var target: String?
      if kind == 0o120000 {
        guard !isDirectory, method == 0, compressed == unpacked, (1...4096).contains(unpacked) else { throw LocalAISetupError.unsafeArtifact }
        try handle.seek(toOffset: UInt64(bodyOffset))
        let data = try handle.read(upToCount: unpacked) ?? Data()
        guard let value = String(data: data, encoding: .utf8), RuntimeArtifactFiles.safeLink(value, at: path) else { throw LocalAISetupError.unsafeArtifact }
        target = value
      }
      result.append(.init(path: path, isDirectory: isDirectory, link: target))
      position += 46 + nameSize + extra + comment
    }
    guard position == directory.count else { throw LocalAISetupError.unsafeArtifact }
    let links = result.filter { $0.link != nil }.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() + "/" }
    guard result.allSatisfy({ entry in !links.contains(where: { entry.path.precomposedStringWithCanonicalMapping.lowercased().hasPrefix($0) }) }) else { throw LocalAISetupError.unsafeArtifact }
    return result
  }
}

enum RuntimeArtifactPreparation {
  static func prepare(_ artifact: RuntimeArtifact, catalog: RuntimeArtifactCatalog, operationRoot: URL,
                      progress: @escaping @Sendable (String, Int64?, Int64?) -> Void) async throws -> URL {
    let source = catalog.resourceRoot.appendingPathComponent(artifact.archivePath)
    guard RuntimeArtifactFiles.pathIdentity(source.resolvingSymlinksInPath().deletingLastPathComponent()) == RuntimeArtifactFiles.pathIdentity(catalog.resourceRoot) else { throw LocalAISetupError.unsafeArtifact }
    let attributes = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, Int64(attributes.fileSize ?? -1) == artifact.archiveByteCount else { throw LocalAISetupError.unsafeArtifact }
    try FileManager.default.createDirectory(at: operationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var space = statfs(); guard statfs(operationRoot.path, &space) == 0 else { throw LocalAISetupError.insufficientSpace }
    let required = UInt64(artifact.archiveByteCount) + UInt64(artifact.unpackedByteCount) * 3 + 3 * 1_073_741_824
    guard UInt64(space.f_bavail) * UInt64(space.f_bsize) >= required else { throw LocalAISetupError.insufficientSpace }
    let copied = operationRoot.appendingPathComponent("runtime.zip")
    progress("verifyingArchive", 0, artifact.archiveByteCount)
    try await RuntimeArtifactFiles.background {
      try copy(source, to: copied)
      guard try RuntimeArtifactFiles.hash(copied) == artifact.archiveSHA256 else { throw LocalAISetupError.unsafeArtifact }
      _ = try RuntimeZipAdmission.entries(copied)
    }
    try Task.checkCancellation()
    let package = operationRoot.appendingPathComponent("package", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    progress("unpacking", nil, nil)
    try await RuntimeArtifactFiles.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", copied.path, package.path], log: operationRoot.appendingPathComponent("extract.log"))
    progress("validatingTree", 0, artifact.unpackedByteCount)
    try await RuntimeArtifactFiles.background { try validateTree(package, artifact: artifact, progress: progress) }
    try Task.checkCancellation(); return package
  }
  static func copy(_ source: URL, to target: URL) throws {
    let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else { throw LocalAISetupError.unsafeArtifact }; defer { Darwin.close(input) }
    var before = stat(); guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw LocalAISetupError.unsafeArtifact }
    let output = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw LocalAISetupError.unsafeArtifact }; defer { Darwin.close(output) }
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      try Task.checkCancellation(); let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw LocalAISetupError.unsafeArtifact }; if count == 0 { break }
      var written = 0
      while written < count {
        let n = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: written), count - written) }
        if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw LocalAISetupError.unsafeArtifact }; written += n
      }
    }
    var after = stat(), owned = stat()
    guard fstat(input, &after) == 0, RuntimeArtifactFiles.same(before, after), fstat(output, &owned) == 0,
          owned.st_mode & S_IFMT == S_IFREG, owned.st_nlink == 1, owned.st_size == before.st_size,
          owned.st_ino != before.st_ino || owned.st_dev != before.st_dev, fsync(output) == 0 else { throw LocalAISetupError.unsafeArtifact }
  }
  static func validateTree(_ root: URL, artifact: RuntimeArtifact, progress: @Sendable (String, Int64?, Int64?) -> Void) throws {
    let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
    guard data.count <= 8_388_608, RuntimeArtifactFiles.digest(data) == artifact.innerManifestSHA256 else { throw LocalAISetupError.unsafeArtifact }
    let manifest = try JSONDecoder().decode(RuntimePackageManifest.self, from: data)
    guard manifest.id == artifact.id, manifest.files.count == artifact.manifestEntryCount,
          Set(manifest.files.map(\.path)).count == manifest.files.count else { throw LocalAISetupError.unsafeArtifact }
    let rootPath = RuntimeArtifactFiles.pathIdentity(root)
    let canonical = RuntimeArtifactFiles.pathIdentity(root.resolvingSymlinksInPath()) + "/"
    var expected: Set<String> = ["manifest.json"], bytes: Int64 = 0
    for item in manifest.files {
      try Task.checkCancellation(); guard RuntimeArtifactFiles.safeRelativePath(item.path) else { throw LocalAISetupError.unsafeArtifact }
      let path = root.appendingPathComponent(item.path); expected.insert(item.path)
      guard RuntimeArtifactFiles.pathIdentity(path.resolvingSymlinksInPath()).hasPrefix(canonical) else { throw LocalAISetupError.unsafeArtifact }
      var st = stat(); guard lstat(path.path, &st) == 0 else { throw LocalAISetupError.unsafeArtifact }
      if item.type == "symlink" {
        guard st.st_mode & S_IFMT == S_IFLNK, let target = item.target,
              RuntimeArtifactFiles.safeLink(target, at: item.path), try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == target else { throw LocalAISetupError.unsafeArtifact }
      } else {
        guard item.type == nil, st.st_mode & S_IFMT == S_IFREG, let size = item.size, size >= 0, st.st_size == size,
              let hash = item.sha256, RuntimeArtifactFiles.validSHA(hash), try RuntimeArtifactFiles.hash(path) == hash else { throw LocalAISetupError.unsafeArtifact }
        bytes += size; progress("validatingTree", bytes, artifact.unpackedByteCount)
      }
    }
    guard bytes == artifact.unpackedByteCount else { throw LocalAISetupError.unsafeArtifact }
    guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw LocalAISetupError.unsafeArtifact }
    var actual = Set<String>()
    for case let path as URL in walk {
      try Task.checkCancellation(); var st = stat(); guard lstat(path.path, &st) == 0 else { throw LocalAISetupError.unsafeArtifact }
      if st.st_mode & S_IFMT != S_IFDIR {
        // FileManager's enumerator may emit /private/var where the supplied URL is /var.
        // Normalize both lexical paths; never resolve this entry to its symlink target.
        let enumeratedPath = RuntimeArtifactFiles.pathIdentity(path)
        guard enumeratedPath.hasPrefix(rootPath + "/") else { throw LocalAISetupError.unsafeArtifact }
        actual.insert(String(enumeratedPath.dropFirst(rootPath.count + 1)))
      }
    }
    guard actual == expected else { throw LocalAISetupError.unsafeArtifact }
  }
}
