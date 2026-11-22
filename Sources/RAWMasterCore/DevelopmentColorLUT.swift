import CryptoKit
import Foundation

public enum DevelopmentLUTError: LocalizedError {
  case invalidCube(String), unsupportedFormat, invalidArchive, noCubes, oversized, damagedAsset

  public var errorDescription: String? {
    switch self {
    case .invalidCube(let reason): "CUBE 文件无效（\(reason)）"
    case .unsupportedFormat: "请选择 CUBE 或 ZIP 文件。"
    case .invalidArchive: "无法读取 ZIP 文件。"
    case .noCubes: "ZIP 中没有 CUBE 文件。"
    case .oversized: "LUT 数据超出可读取范围。"
    case .damagedAsset: "LUT 数据校验失败。"
    }
  }
}

/// An immutable display-sRGB look. RGB triples use little-endian IEEE Float32 with red varying fastest.
public struct DevelopmentColorLUT: Codable, Equatable, Sendable, Identifiable {
  public let name: String
  public let dimension: Int
  public let domainMin: SIMD3<Float>
  public let domainMax: SIMD3<Float>
  public let rgb: Data
  public let id: String

  public static let maximumDimension = 64
  public static let maximumTextBytes = 32 * 1024 * 1024
  static let fingerprintOnly = CodingUserInfoKey(rawValue: "rawmaster.lut.fingerprint")!
  static let payloadKey = "lutCubeRGB32"
  static let maximumCubeBytes = maximumDimension * maximumDimension * maximumDimension * 12

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.name == rhs.name }

  private init(name: String, dimension: Int, domainMin: SIMD3<Float>, domainMax: SIMD3<Float>, rgb: Data) throws {
    guard (2...Self.maximumDimension).contains(dimension), rgb.count == dimension * dimension * dimension * 12,
          !name.isEmpty, name.utf8.count <= 1024,
          (0..<3).allSatisfy({ domainMin[$0].isFinite && domainMax[$0].isFinite && domainMax[$0] > domainMin[$0] }),
          rgb.withUnsafeBytes({ bytes in
            stride(from: 0, to: bytes.count, by: 4).allSatisfy {
              Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))).isFinite
            }
          }) else { throw DevelopmentLUTError.damagedAsset }
    self.name = name
    self.dimension = dimension
    self.domainMin = domainMin
    self.domainMax = domainMax
    self.rgb = rgb
    var header = Data("RAWMaster/display-sRGB-CUBE-v1".utf8)
    for value in [Float(dimension), domainMin.x, domainMin.y, domainMin.z, domainMax.x, domainMax.y, domainMax.z] {
      var bits = value.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { header.append(contentsOf: $0) }
    }
    var digest = SHA256()
    digest.update(data: header)
    digest.update(data: rgb)
    self.id = digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private enum CodingKeys: String, CodingKey { case name, dimension, domainMin, domainMax, id, lutCubeRGB32 }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(name: c.decode(String.self, forKey: .name), dimension: c.decode(Int.self, forKey: .dimension),
                  domainMin: c.decode(SIMD3<Float>.self, forKey: .domainMin), domainMax: c.decode(SIMD3<Float>.self, forKey: .domainMax),
                  rgb: c.decode(Data.self, forKey: .lutCubeRGB32))
    guard try c.decode(String.self, forKey: .id) == id else { throw DevelopmentLUTError.damagedAsset }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    if encoder.userInfo[Self.fingerprintOnly] as? Bool == true { return }
    try c.encode(dimension, forKey: .dimension)
    try c.encode(domainMin, forKey: .domainMin)
    try c.encode(domainMax, forKey: .domainMax)
    try c.encode(rgb, forKey: .lutCubeRGB32)
  }

  public static func parse(_ data: Data, filename: String) throws -> Self {
    guard data.count <= maximumTextBytes else { throw DevelopmentLUTError.oversized }
    var name: String?
    var dimension: Int?
    var minimum: SIMD3<Float>?
    var maximum: SIMD3<Float>?
    var samples: [UInt32] = []

    func parseHeader(_ source: String) throws {
      if source.hasPrefix("TITLE"), source.dropFirst(5).first?.isWhitespace == true {
        let quoted = source.dropFirst(5).drop(while: \.isWhitespace)
        guard samples.isEmpty, name == nil, quoted.first == "\"", let end = quoted.dropFirst().firstIndex(of: "\""),
              end > quoted.index(after: quoted.startIndex) else { throw DevelopmentLUTError.invalidCube("TITLE") }
        let tail = quoted[quoted.index(after: end)...].drop(while: \.isWhitespace)
        guard tail.isEmpty || tail.first == "#" else { throw DevelopmentLUTError.invalidCube("TITLE") }
        name = String(quoted[quoted.index(after: quoted.startIndex)..<end])
        return
      }
      let words = source.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace)
      switch words.first {
      case "LUT_3D_SIZE":
        guard dimension == nil, words.count == 2, let value = Int(words[1]), (2...maximumDimension).contains(value) else {
          throw DevelopmentLUTError.invalidCube("LUT_3D_SIZE 必须为 2 至 64")
        }
        dimension = value
        samples.reserveCapacity(value * value * value * 3)
      case "LUT_3D_INPUT_RANGE":
        guard samples.isEmpty, minimum == nil, maximum == nil, words.count == 3,
              let lo = Float(words[1]), let hi = Float(words[2]), lo.isFinite, hi.isFinite, lo < hi else {
          throw DevelopmentLUTError.invalidCube("LUT_3D_INPUT_RANGE")
        }
        minimum = .init(repeating: lo)
        maximum = .init(repeating: hi)
      case "DOMAIN_MIN", "DOMAIN_MAX":
        guard samples.isEmpty, words.count == 4, let x = Float(words[1]), let y = Float(words[2]), let z = Float(words[3]),
              x.isFinite, y.isFinite, z.isFinite else { throw DevelopmentLUTError.invalidCube("DOMAIN") }
        let domain = SIMD3(x, y, z)
        if words.first == "DOMAIN_MIN", minimum == nil { minimum = domain }
        else if words.first == "DOMAIN_MAX", maximum == nil { maximum = domain }
        else { throw DevelopmentLUTError.invalidCube("重复的 DOMAIN") }
      default: throw DevelopmentLUTError.invalidCube(String(words.first ?? ""))
      }
    }

    // Numeric rows dominate 64³ files. Decode tokens in place, with a single allocation
    // for the red-fastest table. Header titles alone require full UTF-8 line handling.
    try data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var index = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
      var line = 1
      func horizontal(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 11 || byte == 12 }
      func newline(_ byte: UInt8) -> Bool { byte == 10 || byte == 13 }
      func skipSpace() { while index < bytes.count && horizontal(bytes[index]) { index += 1 } }
      func skipLine() { while index < bytes.count && !newline(bytes[index]) { index += 1 } }
      while index < bytes.count {
        skipSpace()
        guard index < bytes.count else { break }
        let first = bytes[index]
        if first == 35 { // '#'
          skipLine()
        } else if (65...90).contains(first) {
          let start = index
          skipLine()
          guard let header = String(bytes: bytes[start..<index], encoding: .utf8) else { throw DevelopmentLUTError.invalidCube("UTF-8") }
          try parseHeader(header)
        } else if !newline(first) {
          guard let d = dimension, samples.count < d * d * d * 3 else { throw DevelopmentLUTError.invalidCube("数据行数") }
          for _ in 0..<3 {
            skipSpace()
            let start = index
            while index < bytes.count && bytes[index] > 32 && bytes[index] != 35 { index += 1 }
            guard start < index, let value = Float(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
              throw DevelopmentLUTError.invalidCube("第 \(line) 行")
            }
            samples.append(value.bitPattern.littleEndian)
          }
          skipSpace()
          if index < bytes.count && bytes[index] == 35 { skipLine() }
          guard index == bytes.count || newline(bytes[index]) else { throw DevelopmentLUTError.invalidCube("第 \(line) 行") }
        }
        if index < bytes.count {
          let wasCR = bytes[index] == 13
          index += 1
          if wasCR && index < bytes.count && bytes[index] == 10 { index += 1 }
          line += 1
        }
      }
    }
    guard let dimension, samples.count == dimension * dimension * dimension * 3 else { throw DevelopmentLUTError.invalidCube("数据行数") }
    let fallback = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    return try .init(name: name ?? fallback, dimension: dimension, domainMin: minimum ?? .zero,
                     domainMax: maximum ?? .one, rgb: samples.withUnsafeBytes { Data($0) })
  }

  /// Original, small analytic looks for the app's two built-in menu entries.
  public static let warm: Self = builtin("暖色", transform: { SIMD3($0.x * 0.94 + 0.06, $0.y, $0.z * 0.90) })
  public static let monochrome: Self = builtin("黑白", transform: { .init(repeating: $0.x * 0.2126 + $0.y * 0.7152 + $0.z * 0.0722) })
  private static func builtin(_ name: String, transform: (SIMD3<Float>) -> SIMD3<Float>) -> Self {
    var samples: [Float] = []
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
      let value = transform(.init(Float(r), Float(g), Float(b)))
      samples.append(contentsOf: [value.x, value.y, value.z])
    } } }
    return try! .init(name: name, dimension: 2, domainMin: .zero, domainMax: .one, rgb: samples.withUnsafeBytes { Data($0) })
  }
}

public struct DevelopmentLUTLayer: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var cube: DevelopmentColorLUT
  public var amount: Double
  public init(id: UUID = UUID(), cube: DevelopmentColorLUT, amount: Double = 100) {
    self.id = id; self.cube = cube; self.amount = amount
  }
  public func validate() throws { try DevelopmentV3Validation.range([amount], 0...100) }
}

public struct DevelopmentLUTStack: Codable, Equatable, Sendable {
  public static let maximumLayers = 3
  public var enabled: Bool
  public var layers: [DevelopmentLUTLayer]
  public init(enabled: Bool = true, layers: [DevelopmentLUTLayer] = []) {
    self.enabled = enabled; self.layers = layers
  }
  public var isActive: Bool { enabled && layers.contains { $0.amount > 0 } }
  public func validate() throws {
    guard layers.count <= Self.maximumLayers, Set(layers.map(\.id)).count == layers.count else { throw EditingError.invalidRecipe }
    for layer in layers { try layer.validate() }
  }
}
