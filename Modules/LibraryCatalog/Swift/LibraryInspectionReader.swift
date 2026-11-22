#if os(macOS)
  import Foundation
  import CryptoKit
  import ImageIO
  import Darwin

  public struct LibraryInspectionFile: Sendable {
    public let fileID: String, contentID: String
    public let url: URL
    public let sessionID: String?
    public init(fileID: String, contentID: String, url: URL, sessionID: String? = nil) {
      self.fileID = fileID
      self.contentID = contentID
      self.url = url
      self.sessionID = sessionID
    }
    var fields: [String: CatalogJSON] {
      var out: [String: CatalogJSON] = ["fileID": .string(fileID), "contentID": .string(contentID)]
      if let sessionID { out["sessionID"] = .string(sessionID) }
      return out
    }
  }
  public enum LibraryInspectionReader {
    private static let supportedSonyModels: Set<String> = ["ILCE-1", "ILCE-1M2", "ILCE-7RM5"]
    static func digest(_ url: URL) throws -> (String, Int64) {
      let input = try FileHandle(forReadingFrom: url)
      defer { try? input.close() }
      var sha = SHA256()
      var size: Int64 = 0
      while true {
        try Task.checkCancellation()
        let data = try input.read(upToCount: 262_144) ?? Data()
        if data.isEmpty { break }
        size += Int64(data.count)
        sha.update(data: data)
      }
      return (sha.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
    static func verify(_ file: LibraryInspectionFile) throws {
      let (hash, size) = try digest(file.url)
      guard file.contentID == "sha256:\(hash):\(size)" else {
        throw LibraryEngineError("文件内容已变化，请重新核对原件")
      }
    }
    static func signature(_ url: URL) throws -> [String] {
      let a = try FileManager.default.attributesOfItem(atPath: url.path)
      return [.systemNumber, .systemFileNumber, .size, .modificationDate].map {
        String(describing: a[$0])
      }
    }
    public static func capture(
      _ file: LibraryInspectionFile, using actions: CatalogActions, exifTool: URL? = nil
    ) async throws {
      let payload = try await Task.detached(priority: .utility) {
        let stamp = try signature(file.url)
        try verify(file)
        guard
          let source = CGImageSourceCreateWithURL(
            file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw LibraryEngineError("无法读取原片元数据") }
        var fields = embedded(p)
        if let words = hierarchicalKeywords(source), !words.isEmpty {
          fields["keywords"] = .array(
            words.map { .object(["path": .array($0.map(CatalogJSON.string))]) })
        }
        let af = try sonyFocus(url: file.url, fields: fields, executable: exifTool)
        guard try signature(file.url) == stamp else { throw LibraryEngineError("读取期间原件发生变化") }
        return file.fields.merging([
          "fields": .object(fields), "extractor": .string("ImageIO+ExifTool-Sony-v1"),
          "af": .object(af),
        ]) { _, v in v }
      }.value
      _ = try await actions.perform("inspect.capture", payload)
    }
    private static func embedded(_ p: [CFString: Any]) -> [String: CatalogJSON] {
      let t = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
      let e = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
      let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
      let g = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
      let ip = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
      var out = [String: CatalogJSON]()
      func string(_ key: String, _ value: Any?) {
        if let s = value as? String, !s.isEmpty { out[key] = .string(s) }
      }
      func number(_ key: String, _ value: Any?, positive: Bool = true) {
        if let n = value as? NSNumber, n.doubleValue.isFinite, !positive || n.doubleValue > 0 {
          out[key] = .number(n.doubleValue)
        }
      }
      func integer(_ key: String, _ value: Any?) {
        if let n = value as? NSNumber, n.int64Value > 0 { out[key] = .integer(n.int64Value) }
      }
      string("make", t[kCGImagePropertyTIFFMake])
      string("camera", t[kCGImagePropertyTIFFModel])
      string("lens", e[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel])
      integer("width", p[kCGImagePropertyPixelWidth])
      integer("height", p[kCGImagePropertyPixelHeight])
      integer("orientation", p[kCGImagePropertyOrientation] ?? t[kCGImagePropertyTIFFOrientation])
      integer(
        "iso",
        (e[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first ?? e[
          kCGImagePropertyExifISOSpeedRatings] as? NSNumber)
      number("aperture", e[kCGImagePropertyExifFNumber])
      number("shutterSeconds", e[kCGImagePropertyExifExposureTime])
      number("focalLength", e[kCGImagePropertyExifFocalLength])
      number("exposureCompensation", e[kCGImagePropertyExifExposureBiasValue], positive: false)
      string("colorSpace", p[kCGImagePropertyProfileName])
      if out["colorSpace"] == nil, (e[kCGImagePropertyExifColorSpace] as? NSNumber)?.intValue == 1 {
        out["colorSpace"] = .string("sRGB")
      }
      string("capturedLocal", e[kCGImagePropertyExifDateTimeOriginal])
      string("offsetTime", e[kCGImagePropertyExifOffsetTimeOriginal])
      if let local = out["capturedLocal"]?.stringValue, let offset = out["offsetTime"]?.stringValue
      {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        parser.isLenient = false
        if let date = parser.date(from: local + offset) {
          let digits = (e[kCGImagePropertyExifSubsecTimeOriginal] as? String) ?? ""
          let fraction =
            !digits.isEmpty && digits.count <= 9 && digits.allSatisfy(\.isNumber)
            ? Double("0." + digits) ?? 0 : 0
          out["capturedAt"] = .number(date.timeIntervalSinceReferenceDate + fraction)
        }
      }
      string("title", ip[kCGImagePropertyIPTCObjectName])
      string("caption", ip[kCGImagePropertyIPTCCaptionAbstract])
      string("creator", ip[kCGImagePropertyIPTCByline] ?? t[kCGImagePropertyTIFFArtist])
      string(
        "copyright", ip[kCGImagePropertyIPTCCopyrightNotice] ?? t[kCGImagePropertyTIFFCopyright])
      string("place", ip[kCGImagePropertyIPTCCity])
      let words =
        (ip[kCGImagePropertyIPTCKeywords] as? [String])
        ?? (ip[kCGImagePropertyIPTCKeywords] as? String).map { [$0] } ?? []
      if !words.isEmpty {
        out["keywords"] = .array(
          words.filter { !$0.isEmpty }.map { .object(["path": .array([.string($0)])]) })
      }
      for (key, num, ref, positive, negative, limit) in [
        ("latitude", kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef, "N", "S", 90.0),
        (
          "longitude", kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef, "E", "W",
          180.0
        ),
      ] {
        if let val = g[num] as? NSNumber, let dir = (g[ref] as? String)?.uppercased(),
          [positive, negative].contains(dir), abs(val.doubleValue) <= limit
        {
          out[key] = .number(abs(val.doubleValue) * (dir == negative ? -1 : 1))
        }
      }
      return out
    }
    private static func hierarchicalKeywords(_ source: CGImageSource) -> [[String]]? {
      guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
        let tag = CGImageMetadataCopyTagWithPath(
          metadata, nil, "lr:hierarchicalSubject" as CFString),
        let value = CGImageMetadataTagCopyValue(tag), let entries = value as? [Any]
      else { return nil }
      var paths = [[String]]()
      for item in entries {
        let value: String?
        if let s = item as? String {
          value = s
        } else if CFGetTypeID(item as CFTypeRef) == CGImageMetadataTagGetTypeID() {
          value =
            CGImageMetadataTagCopyValue(
              unsafeBitCast(item as AnyObject, to: CGImageMetadataTag.self)) as? String
        } else {
          value = nil
        }
        if let value {
          let p = value.components(separatedBy: "|")
          if !p.isEmpty, p.count <= 64, p.allSatisfy({ !$0.isEmpty }) { paths.append(p) }
        }
      }
      return paths
    }
    /// Sony MakerNotes 0x2027 is W,H,X,Y in unrotated, top-left coordinates. Some bodies record
    /// the centre when AF is unavailable. A lone centre therefore supplies no verified overlay.
    /// See ExifTool's Sony.pm, tag 0x2027, and the bundled runtime's qualified Sony selectors.
    public static func sonyLocation(_ tuple: [Int], model: String, orientation: Int, image: CGSize)
      -> [String: CatalogJSON]
    {
      func missing(_ reason: String) -> [String: CatalogJSON] {
        ["state": .string("unavailable"), "reason": .string(reason), "model": .string(model)]
      }
      guard supportedSonyModels.contains(model) else { return missing("unsupportedModel") }
      guard tuple.count == 4, (1...8).contains(orientation), image.width > 0, image.height > 0
      else { return missing("missingGeometry") }
      let (w, h, x, y) = (tuple[0], tuple[1], tuple[2], tuple[3])
      guard (1...65535).contains(w), (1...65535).contains(h), (0..<w).contains(x),
        (0..<h).contains(y),
        abs((Double(w) / Double(h)) / (image.width / image.height) - 1) < 0.015
      else { return missing("unmatchedCoordinateSpace") }
      guard x != w / 2 || y != h / 2 else { return missing("ambiguousCentreFallback") }
      return [
        "state": .string("available"), "tag": .string("Sony:FocusLocation"),
        "model": .string(model), "coordinateSpace": .string("unorientedTopLeft"),
        "orientation": .integer(Int64(orientation)),
        "tuple": .array(tuple.map { .integer(Int64($0)) }),
      ]
    }
    private static func sonyFocus(url: URL, fields: [String: CatalogJSON], executable: URL?) throws
      -> [String: CatalogJSON]
    {
      func missing(_ reason: String) -> [String: CatalogJSON] {
        ["state": .string("unavailable"), "reason": .string(reason)]
      }
      guard fields["make"]?.stringValue?.uppercased() == "SONY",
        let model = fields["camera"]?.stringValue, supportedSonyModels.contains(model)
      else { return missing("unsupportedModel") }
      guard
        let tool = executable
          ?? Bundle.main.resourceURL?.appendingPathComponent("MetadataTool/exiftool"),
        FileManager.default.isExecutableFile(atPath: tool.path)
      else { return missing("readerUnavailable") }
      guard case .integer(let o)? = fields["orientation"], case .integer(let w)? = fields["width"],
        case .integer(let h)? = fields["height"]
      else { return missing("missingGeometry") }
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: dir) }
      let dest = dir.appendingPathComponent("tags.json")
      FileManager.default.createFile(atPath: dest.path, contents: nil)
      let output = try FileHandle(forWritingTo: dest)
      defer { try? output.close() }
      let proc = Process()
      proc.executableURL = tool
      proc.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
      proc.arguments = [
        "-config", "", "-j", "-n", "-a", "-G0:1:4", "-Sony:FocusLocation", "-ExifTool:Error",
        url.path,
      ]
      proc.standardInput = FileHandle.nullDevice
      proc.standardOutput = output
      proc.standardError = FileHandle.nullDevice
      do { try proc.run() } catch { return missing("readerUnavailable") }
      let clock = ContinuousClock()
      let end = clock.now.advanced(by: .seconds(12))
      while proc.isRunning {
        if Task.isCancelled || clock.now >= end {
          kill(proc.processIdentifier, SIGKILL)
          proc.waitUntilExit()
          try Task.checkCancellation()
          return missing("readerUnavailable")
        }
        Thread.sleep(forTimeInterval: 0.025)
      }
      guard proc.terminationStatus == 0, try output.offset() <= 131_072 else {
        return missing("readerUnavailable")
      }
      let data = try Data(contentsOf: dest)
      guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        let record = list.first
      else { return missing("readerUnavailable") }
      var matches = Set<[Int]>()
      for (name, value) in record {
        let parts = name.split(separator: ":")
        guard parts.count >= 3, parts[0] == "MakerNotes", parts[1] == "Sony",
          parts.last == "FocusLocation"
        else { continue }
        let values: [Int]
        if let a = value as? [NSNumber] {
          values = a.map(\.intValue)
        } else if let s = value as? String {
          values = s.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
        } else {
          continue
        }
        if values.count == 4 { matches.insert(values) }
      }
      guard matches.count == 1, let tuple = matches.first else {
        return missing(matches.isEmpty ? "tagMissing" : "conflictingTags")
      }
      return sonyLocation(
        tuple, model: model, orientation: Int(o), image: .init(width: Int(w), height: Int(h)))
    }
  }
#endif
