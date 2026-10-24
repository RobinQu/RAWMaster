import Foundation

/// Gregorian camera wall time. This value deliberately has no timezone.
public struct SequenceCivilTime: Codable, Sendable, Equatable {
  public let year, month, day, hour, minute, second: Int
  public let nanosecond: Int?

  public init(
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
    nanosecond: Int? = nil
  ) throws {
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...9999).contains(year), (1...12).contains(month),
      (1...lengths[month - 1]).contains(day), (0...23).contains(hour),
      (0...59).contains(minute), (0...59).contains(second),
      nanosecond.map({ (0...999_999_999).contains($0) }) ?? true
    else { throw LibraryError.invalid("无效的拍摄本地时间") }
    self.year = year
    self.month = month
    self.day = day
    self.hour = hour
    self.minute = minute
    self.second = second
    self.nanosecond = nanosecond
  }

  private enum CodingKeys: String, CodingKey {
    case year, month, day, hour, minute, second, nanosecond
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      year: c.decode(Int.self, forKey: .year), month: c.decode(Int.self, forKey: .month),
      day: c.decode(Int.self, forKey: .day), hour: c.decode(Int.self, forKey: .hour),
      minute: c.decode(Int.self, forKey: .minute), second: c.decode(Int.self, forKey: .second),
      nanosecond: c.decodeIfPresent(Int.self, forKey: .nanosecond))
  }

  /// Seconds on a timezone-free civil axis, not an assertion of UTC.
  public var civilSecond: Int64 {
    let y = year - (month <= 2 ? 1 : 0)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = month + (month > 2 ? -3 : 9)
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return Int64(era * 146_097 + doe - 719_468) * 86_400
      + Int64(hour * 3600 + minute * 60 + second)
  }
}

public enum SequenceTimePrecision: String, Codable, Sendable { case unknown, seconds, subsecond }

public struct SequenceTimeEvidence: Codable, Sendable, Equatable {
  public let originalRaw, subsecondsRaw, offsetRaw: String?
  public let local: SequenceCivilTime?
  public let precision: SequenceTimePrecision
  public let subsecondDigits: Int?
  public let subsecondTruncated: Bool
  public let offsetMinutes: Int?
  public let utcInstant: Date?
  public let warnings: [String]

  public init(
    originalRaw: String?, subsecondsRaw: String?, offsetRaw: String?, local: SequenceCivilTime?,
    precision: SequenceTimePrecision, subsecondDigits: Int? = nil,
    subsecondTruncated: Bool = false, offsetMinutes: Int? = nil, utcInstant: Date? = nil,
    warnings: [String] = []
  ) {
    self.originalRaw = originalRaw
    self.subsecondsRaw = subsecondsRaw
    self.offsetRaw = offsetRaw
    self.local = local
    self.precision = precision
    self.subsecondDigits = subsecondDigits
    self.subsecondTruncated = subsecondTruncated
    self.offsetMinutes = offsetMinutes
    self.utcInstant = utcInstant
    self.warnings = warnings
  }

  /// Decode/public initialization is not evidence validation: verify against retained raw fields.
  public var isConsistent: Bool {
    let parsed = SequenceTimestampParser.parse(
      original: originalRaw, subseconds: subsecondsRaw, offset: offsetRaw)
    return local == parsed.local && precision == parsed.precision
      && subsecondDigits == parsed.subsecondDigits && subsecondTruncated == parsed.subsecondTruncated
      && offsetMinutes == parsed.offsetMinutes && utcInstant == parsed.utcInstant
  }
}

public enum SequenceTimestampParser {
  public static func parse(original: String?, subseconds: String?, offset: String?)
    -> SequenceTimeEvidence
  {
    var warnings: [String] = []
    func cleaned(_ value: String?) -> String? {
      guard let value else { return nil }
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
      if text != value { warnings.append("EXIF padding trimmed for parsing") }
      return text
    }
    let dateText = cleaned(original), fraction = cleaned(subseconds), offsetText = cleaned(offset)
    var nanos: Int?
    var digits: Int?
    var truncated = false
    if let fraction, !fraction.isEmpty {
      if fraction.utf8.allSatisfy({ (48...57).contains($0) }) {
        digits = fraction.utf8.count
        let part = String(fraction.prefix(9))
        nanos = Int(part + String(repeating: "0", count: 9 - part.count))
        truncated = fraction.count > 9
        if truncated { warnings.append("Subsecond precision truncated to nanoseconds; raw preserved") }
      } else {
        warnings.append("Invalid SubsecTimeOriginal; subsecond precision unavailable")
      }
    }
    var local: SequenceCivilTime?
    if let dateText {
      let bytes = Array(dateText.utf8)
      let separators: [Int: UInt8] = [4: 58, 7: 58, 10: 32, 13: 58, 16: 58]
      if bytes.count == 19,
        bytes.enumerated().allSatisfy({ index, byte in
          separators[index].map { byte == $0 } ?? (48...57).contains(byte)
        })
      {
        let values = dateText.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap {
          Int($0)
        }
        if values.count == 6 {
          local = try? SequenceCivilTime(
            year: values[0], month: values[1], day: values[2], hour: values[3], minute: values[4],
            second: values[5], nanosecond: nanos)
        }
      }
    }
    if local == nil {
      warnings.append(original == nil ? "Missing DateTimeOriginal" : "Invalid DateTimeOriginal")
    }
    var offsetMinutes: Int?
    if let offsetText, !offsetText.isEmpty {
      let bytes = Array(offsetText.utf8)
      if bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
        [1, 2, 4, 5].allSatisfy({ (48...57).contains(bytes[$0]) })
      {
        let h = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let m = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        if h <= 14, m < 60, h < 14 || m == 0 {
          offsetMinutes = (h * 60 + m) * (bytes[0] == 45 ? -1 : 1)
        }
      }
      if offsetMinutes == nil { warnings.append("Invalid OffsetTimeOriginal; UTC unavailable") }
    }
    let utc = local.flatMap { local in
      offsetMinutes.map {
        Date(
          timeIntervalSince1970: Double(local.civilSecond - Int64($0 * 60))
            + Double(local.nanosecond ?? 0) / 1_000_000_000)
      }
    }
    return SequenceTimeEvidence(
      originalRaw: original, subsecondsRaw: subseconds, offsetRaw: offset, local: local,
      precision: local == nil ? .unknown : (nanos == nil ? .seconds : .subsecond),
      subsecondDigits: digits, subsecondTruncated: truncated, offsetMinutes: offsetMinutes,
      utcInstant: utc, warnings: warnings)
  }
}

public struct SequenceCaptureEvidence: Codable, Sendable, Equatable {
  public let assetID, contentHash, extractorVersion: String
  public let evidenceRevision: Int
  public let time: SequenceTimeEvidence
  public let cameraMake, cameraModel, imageNumberRaw: String?
  public let exposureSeconds: Double?
  public let orientation: Int
  public let warnings: [String]

  public init(
    assetID: String, contentHash: String, extractorVersion: String, evidenceRevision: Int = 0,
    time: SequenceTimeEvidence, cameraMake: String? = nil, cameraModel: String? = nil,
    imageNumberRaw: String? = nil, exposureSeconds: Double? = nil, orientation: Int = 1,
    warnings: [String] = []
  ) {
    self.assetID = assetID
    self.contentHash = contentHash
    self.extractorVersion = extractorVersion
    self.evidenceRevision = evidenceRevision
    self.time = time
    self.cameraMake = cameraMake
    self.cameraModel = cameraModel
    self.imageNumberRaw = imageNumberRaw
    self.exposureSeconds = exposureSeconds
    self.orientation = orientation
    self.warnings = warnings
  }
}

public enum SequenceCameraEvidence: Codable, Sendable, Equatable {
  case unknown
  case verifiedDevice(opaqueID: String, source: String, validationVersion: String)
  case manifestAssertion(id: String, revision: Int, manifestFingerprint: String)

  public func partitionID(manifestFingerprint: String) -> String? {
    switch self {
    case .unknown: return nil
    case .verifiedDevice(let id, let source, let version):
      guard !id.isEmpty, !source.isEmpty, !version.isEmpty else { return nil }
    case .manifestAssertion(let id, let revision, let fingerprint):
      guard !id.isEmpty, revision >= 0, fingerprint == manifestFingerprint else { return nil }
    }
    return try? SequenceCanonical.digest(self)
  }
}

public enum SequenceClockBasis: String, Codable, Sendable { case localCivil, explicitUTC }

public struct SequenceClockPartition: Codable, Sendable, Equatable {
  public let id: String
  public let basis: SequenceClockBasis
  public let derivationVersion: String
  public init(id: String, basis: SequenceClockBasis, derivationVersion: String) {
    self.id = id
    self.basis = basis
    self.derivationVersion = derivationVersion
  }
}
