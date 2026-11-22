import Foundation

public enum DevelopmentLUTImport {
  public static func forEachCube(in file: URL, _ accept: (DevelopmentColorLUT) throws -> Void) throws {
    guard file.isFileURL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw DevelopmentLUTError.unsupportedFormat
    }
    switch file.pathExtension.lowercased() {
    case "cube":
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= DevelopmentColorLUT.maximumTextBytes else { throw DevelopmentLUTError.oversized }
      try accept(.parse(Data(contentsOf: file, options: .mappedIfSafe), filename: file.lastPathComponent))
    case "zip":
      let listing = try unzip(["-Z1", file.path], limit: 4 * 1024 * 1024)
      guard let names = String(data: listing, encoding: .utf8) else { throw DevelopmentLUTError.invalidArchive }
      let paths = names.split(whereSeparator: \.isNewline).map(String.init).filter {
        let parts = $0.split(separator: "/")
        return $0.lowercased().hasSuffix(".cube") && !parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") })
      }
      guard !paths.isEmpty else { throw DevelopmentLUTError.noCubes }
      guard Set(paths).count == paths.count else { throw DevelopmentLUTError.invalidArchive }
      for path in paths {
        // Info-ZIP interprets member operands as patterns. Quote literal glob characters.
        var literal = ""
        for char in path {
          switch char {
          case "*", "?", "[", "]", "\\": literal.append("\\"); literal.append(char)
          case "-" where literal.isEmpty: literal.append("[-]")
          default: literal.append(char)
          }
        }
        let bytes = try unzip(["-p", file.path, literal], limit: DevelopmentColorLUT.maximumTextBytes)
        try accept(.parse(bytes, filename: path))
      }
    default: throw DevelopmentLUTError.unsupportedFormat
    }
  }

  /// Read member data directly from stdout. ZIP pathnames never become filesystem destinations.
  private static func unzip(_ arguments: [String], limit: Int) throws -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let handle = output.fileHandleForReading
    defer { try? handle.close() }
    var bytes = Data()
    do {
      while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        guard chunk.count <= limit - bytes.count else { throw DevelopmentLUTError.oversized }
        bytes.append(chunk)
      }
    } catch {
      try? handle.close()
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      throw error
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw DevelopmentLUTError.invalidArchive }
    return bytes
  }
}

/// Disk-backed chooser shared by all photos. Recipes embed their selected cubes and need no library on replay.
public actor DevelopmentLUTLibrary {
  public struct Entry: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
  }
  public static let shared = DevelopmentLUTLibrary(directory: FileManager.default.urls(for: .applicationSupportDirectory,
    in: .userDomainMask)[0].appendingPathComponent("RAWMaster/LUTs", isDirectory: true))
  private let directory: URL
  private var indexURL: URL { directory.appendingPathComponent("index.json") }
  public init(directory: URL) { self.directory = directory }

  public func entries() throws -> [Entry] {
    guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
    return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: indexURL))
  }

  public func load(_ entry: Entry) throws -> DevelopmentColorLUT {
    guard EditingFingerprint.isSHA256(entry.id) else { throw DevelopmentLUTError.damagedAsset }
    let url = directory.appendingPathComponent(entry.id + ".lut")
    let cube = try PropertyListDecoder().decode(DevelopmentColorLUT.self, from: Data(contentsOf: url))
    guard cube.id == entry.id else { throw DevelopmentLUTError.damagedAsset }
    return cube
  }

  public func importFile(_ url: URL) throws -> [Entry] {
    var entries = try entries()
    var ids = Set(entries.map(\.id))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    var selected: [Entry] = []
    var newIDs: [String] = []
    try DevelopmentLUTImport.forEachCube(in: url) { cube in
      let entry = Entry(id: cube.id, name: cube.name)
      selected.append(entry)
      guard ids.insert(cube.id).inserted else { return }
      try encoder.encode(cube).write(to: temporary.appendingPathComponent(cube.id))
      entries.append(entry)
      newIDs.append(cube.id)
    }
    // Parse and stage the entire pack before publishing the picker index.
    var published: [URL] = []
    do {
      for id in newIDs {
        let file = directory.appendingPathComponent(id + ".lut")
        if !FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.moveItem(at: temporary.appendingPathComponent(id), to: file)
          published.append(file)
        }
      }
      try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
    } catch {
      for file in published { try? FileManager.default.removeItem(at: file) }
      throw error
    }
    return selected
  }
}
