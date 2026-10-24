import Foundation

enum SequenceCanonical {
  static func digest<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = Data("RAWMaster.sequence.v1\n".utf8)
    data.append(try encoder.encode(value))
    return LocationIdentity.digest(data)
  }
  static func isHash(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

/// Domain-separated canonical JSON digest for an Imaging-owned policy value.
public enum SequenceFingerprint {
  public static func digest<T: Encodable>(_ value: T) throws -> String {
    try SequenceCanonical.digest(value)
  }
}

public enum SequenceReason: String, Codable, Sendable, Hashable {
  case missingContentIdentity, missingMetadata, contentMismatch, extractorMismatch
  case evidenceRevisionMismatch, cameraIdentityUnknown, assertionMismatch
  case invalidTimestamp, invalidClockPartition, missingEmbeddedPreview
  case unreadable, unsupported, protectedRange, ambiguous, insufficientEvidence
  case noSequenceSupport, incomplete
}

public struct SequenceManifestEntry: Codable, Sendable, Equatable {
  public let assetID: String
  public let ordinal: Int
  public let contentHash: String?
  public let evidenceRevision: Int
  public let camera: SequenceCameraEvidence
  public let barrier: SequenceReason?
  public init(
    assetID: String, ordinal: Int, contentHash: String?, evidenceRevision: Int = 0,
    camera: SequenceCameraEvidence = .unknown, barrier: SequenceReason? = nil
  ) {
    self.assetID = assetID
    self.ordinal = ordinal
    self.contentHash = contentHash
    self.evidenceRevision = evidenceRevision
    self.camera = camera
    self.barrier = barrier
  }
}

public struct SequenceInputManifest: Codable, Sendable, Equatable {
  public let scopeID, sessionID, orderVersion: String
  public let entries: [SequenceManifestEntry]
  /// Cached once so streaming observation validation does not rehash the entire session per frame.
  public let contentFingerprint: String
  public init(
    scopeID: String, sessionID: String, orderVersion: String,
    entries: [SequenceManifestEntry]
  ) throws {
    guard !scopeID.isEmpty, !sessionID.isEmpty, !orderVersion.isEmpty,
      Set(entries.map(\.assetID)).count == entries.count
    else { throw LibraryError.invalid("序列分析清单身份无效或有重复资产") }
    for (ordinal, entry) in entries.enumerated() {
      guard !entry.assetID.isEmpty, entry.ordinal == ordinal, entry.evidenceRevision >= 0,
        entry.contentHash.map(SequenceCanonical.isHash) ?? true
      else { throw LibraryError.invalid("序列分析清单顺序或内容身份无效") }
    }
    self.scopeID = scopeID
    self.sessionID = sessionID
    self.orderVersion = orderVersion
    self.entries = entries
    self.contentFingerprint = try SequenceCanonical.digest(
      ContentManifest(
        scopeID: scopeID, sessionID: sessionID, orderVersion: orderVersion,
        entries: entries.map {
          ContentEntry(assetID: $0.assetID, ordinal: $0.ordinal, contentHash: $0.contentHash)
        }))
  }
  private enum CodingKeys: String, CodingKey { case scopeID, sessionID, orderVersion, entries }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      scopeID: c.decode(String.self, forKey: .scopeID),
      sessionID: c.decode(String.self, forKey: .sessionID),
      orderVersion: c.decode(String.self, forKey: .orderVersion),
      entries: c.decode([SequenceManifestEntry].self, forKey: .entries))
  }
  private struct ContentEntry: Encodable {
    let assetID: String
    let ordinal: Int
    let contentHash: String?
  }
  private struct ContentManifest: Encodable {
    let scopeID, sessionID, orderVersion: String
    let entries: [ContentEntry]
  }
}

public struct SequenceAnalysisVersions: Codable, Sendable, Equatable {
  public let extractor, feature, algorithm, policy, order: String
  public init(extractor: String, feature: String, algorithm: String, policy: String, order: String) {
    self.extractor = extractor
    self.feature = feature
    self.algorithm = algorithm
    self.policy = policy
    self.order = order
  }
}

public struct SequenceAnalysisToken: Codable, Sendable, Equatable {
  public let scopeID, manifestFingerprint, inputFingerprint: String
  public let inputRevision, structureRevision, generation: Int
  public let versions: SequenceAnalysisVersions
  public let policyFingerprint: String

  private struct FingerprintInput: Encodable {
    let manifest: SequenceInputManifest
    let versions: SequenceAnalysisVersions
    let policyFingerprint: String
    let inputRevision, structureRevision, generation: Int
  }

  public static func make(
    manifest: SequenceInputManifest, versions: SequenceAnalysisVersions,
    policyFingerprint: String, inputRevision: Int = 0, structureRevision: Int = 0,
    generation: Int = 0
  ) throws -> SequenceAnalysisToken {
    guard inputRevision >= 0, structureRevision >= 0, generation >= 0,
      versions.order == manifest.orderVersion,
      [versions.extractor, versions.feature, versions.algorithm, versions.policy, versions.order]
        .allSatisfy({ !$0.isEmpty }), SequenceCanonical.isHash(policyFingerprint)
    else { throw LibraryError.invalid("序列分析版本或输入前提无效") }
    return SequenceAnalysisToken(
      scopeID: manifest.scopeID, manifestFingerprint: manifest.contentFingerprint,
      inputFingerprint: try SequenceCanonical.digest(
        FingerprintInput(
          manifest: manifest, versions: versions, policyFingerprint: policyFingerprint,
          inputRevision: inputRevision, structureRevision: structureRevision, generation: generation)),
      inputRevision: inputRevision, structureRevision: structureRevision, generation: generation,
      versions: versions, policyFingerprint: policyFingerprint)
  }
}

public struct SequenceAssetInput: Codable, Sendable, Equatable {
  public let entry: SequenceManifestEntry
  public let evidence: SequenceCaptureEvidence?
  public let clock: SequenceClockPartition?
  public let barrier: SequenceReason?
  public init(
    entry: SequenceManifestEntry, evidence: SequenceCaptureEvidence?,
    clock: SequenceClockPartition?, barrier: SequenceReason? = nil
  ) {
    self.entry = entry
    self.evidence = evidence
    self.clock = clock
    self.barrier = barrier
  }

  public func validationIssues(
    manifest: SequenceInputManifest, versions: SequenceAnalysisVersions
  ) -> [SequenceReason] {
    var issues: [SequenceReason] = []
    func add(_ reason: SequenceReason) {
      if !issues.contains(reason) { issues.append(reason) }
    }
    if let barrier = entry.barrier { add(barrier) }
    if let barrier { add(barrier) }
    guard manifest.entries.indices.contains(entry.ordinal), manifest.entries[entry.ordinal] == entry
    else { return issues + [.ambiguous] }
    if entry.contentHash == nil { add(.missingContentIdentity) }
    if case .unknown = entry.camera {
      add(.cameraIdentityUnknown)
    } else if entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint) == nil {
      if case .manifestAssertion = entry.camera { add(.assertionMismatch) }
      else { add(.cameraIdentityUnknown) }
    }
    guard let evidence else {
      add(.missingMetadata)
      return issues
    }
    if evidence.assetID != entry.assetID || evidence.contentHash != entry.contentHash {
      add(.contentMismatch)
    }
    if evidence.extractorVersion != versions.extractor { add(.extractorMismatch) }
    if evidence.evidenceRevision != entry.evidenceRevision { add(.evidenceRevisionMismatch) }
    if !evidence.time.isConsistent || evidence.time.local == nil { add(.invalidTimestamp) }
    if !(1...8).contains(evidence.orientation)
      || evidence.exposureSeconds.map({ !$0.isFinite || $0 <= 0 }) == true
    { add(.unsupported) }
    if let clock, !clock.id.isEmpty, !clock.derivationVersion.isEmpty {
      if clock.basis == .explicitUTC && evidence.time.utcInstant == nil {
        add(.invalidClockPartition)
      }
    } else { add(.invalidClockPartition) }
    return issues
  }
}

public enum SequenceKind: String, Codable, Sendable { case burst, interval, sequence }

public struct SequenceOrdinalRange: Codable, Sendable, Equatable {
  public let first, last: Int
  public var count: Int { last - first + 1 }
  public init(first: Int, last: Int) throws {
    guard first >= 0, last >= first, last < Int.max else {
      throw LibraryError.invalid("无效的序列范围")
    }
    self.first = first
    self.last = last
  }
  private enum CodingKeys: String, CodingKey { case first, last }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(first: c.decode(Int.self, forKey: .first), last: c.decode(Int.self, forKey: .last))
  }
}

public struct SequenceDetectedRange: Codable, Sendable, Equatable {
  public let range: SequenceOrdinalRange
  public let kind: SequenceKind
  public let cameraPartitionID, clockPartitionID: String
  public let reasons: [String]
  public init(
    range: SequenceOrdinalRange, kind: SequenceKind, cameraPartitionID: String,
    clockPartitionID: String, reasons: [String] = []
  ) {
    self.range = range
    self.kind = kind
    self.cameraPartitionID = cameraPartitionID
    self.clockPartitionID = clockPartitionID
    self.reasons = reasons
  }
}

public enum SequenceCoverageState: String, Codable, Sendable {
  case complete, insufficient, unreadable, incomplete
}

public struct SequenceCoverageRange: Codable, Sendable, Equatable {
  public let range: SequenceOrdinalRange
  public let state: SequenceCoverageState
  public let reasons: [SequenceReason]
  public init(
    range: SequenceOrdinalRange, state: SequenceCoverageState, reasons: [SequenceReason] = []
  ) {
    self.range = range
    self.state = state
    self.reasons = reasons
  }
}

public struct SequenceAnalysisResult: Codable, Sendable, Equatable {
  public let token: SequenceAnalysisToken
  public let ranges: [SequenceDetectedRange]
  public let coverage: [SequenceCoverageRange]
  public let warnings: [String]
  public init(
    token: SequenceAnalysisToken, ranges: [SequenceDetectedRange],
    coverage: [SequenceCoverageRange], warnings: [String] = []
  ) {
    self.token = token
    self.ranges = ranges
    self.coverage = coverage
    self.warnings = warnings
  }

  private func validateCoverageClassification(
    _ part: SequenceCoverageRange, knownIssues: [SequenceReason] = []
  ) throws {
    // Checked insufficiency may replace automatic structure later; transient states must not
    // be laundered into that meaning. Cancellation may conservatively supersede unreadability.
    if part.state == .incomplete {
      guard part.reasons.contains(.incomplete) else {
        throw LibraryError.invalid("未完成的序列覆盖缺少未完成原因")
      }
    } else if part.reasons.contains(.incomplete) {
      throw LibraryError.invalid("未完成的序列观察被标为已检查")
    }
    if part.state == .unreadable {
      guard part.reasons.contains(.unreadable) || part.reasons.contains(.missingEmbeddedPreview) else {
        throw LibraryError.invalid("不可读的序列覆盖缺少读取失败原因")
      }
    } else if part.state != .incomplete && part.reasons.contains(.unreadable) {
      throw LibraryError.invalid("不可读的序列观察被标为已检查")
    }
    if knownIssues.contains(.incomplete) {
      guard part.state == .incomplete else {
        throw LibraryError.invalid("未完成的序列观察不能降为证据不足")
      }
    } else if knownIssues.contains(.unreadable) && part.state != .incomplete {
      guard part.state == .unreadable, part.reasons.contains(.unreadable) else {
        throw LibraryError.invalid("暂时不可读的序列观察不能降为证据不足")
      }
    }
  }

  /// Structural validation only; this does not prove detector quality or observed clock identity.
  public func validateStructure(
    manifest: SequenceInputManifest, expectedToken: SequenceAnalysisToken? = nil
  ) throws {
    let expected = try SequenceAnalysisToken.make(
      manifest: manifest, versions: token.versions, policyFingerprint: token.policyFingerprint,
      inputRevision: token.inputRevision, structureRevision: token.structureRevision,
      generation: token.generation)
    guard token == expected, expectedToken.map({ token == $0 }) ?? true else {
      throw LibraryError.invalid("序列结果与输入清单不匹配")
    }
    var next = 0
    for part in coverage {
      guard part.range.first == next, part.range.last < manifest.entries.count else {
        throw LibraryError.invalid("序列覆盖遗漏、重叠或越界")
      }
      try validateCoverageClassification(part)
      for ordinal in part.range.first...part.range.last {
        let entry = manifest.entries[ordinal]
        try validateCoverageClassification(part, knownIssues: entry.barrier.map { [$0] } ?? [])
        if part.state == .complete {
          guard entry.barrier == nil, entry.contentHash != nil,
            entry.camera.partitionID(manifestFingerprint: token.manifestFingerprint) != nil
          else { throw LibraryError.invalid("失败项或未知相机不能被标为完整可分组证据") }
        }
      }
      next = part.range.last + 1
    }
    guard next == manifest.entries.count else { throw LibraryError.invalid("序列覆盖不完整") }
    var previousEnd = -1
    var coverageIndex = 0
    for detected in ranges {
      let range = detected.range
      guard range.count >= 2, range.first > previousEnd, range.last < manifest.entries.count,
        !detected.cameraPartitionID.isEmpty, !detected.clockPartitionID.isEmpty
      else { throw LibraryError.invalid("序列范围过小、重叠或越界") }
      previousEnd = range.last
      for ordinal in range.first...range.last {
        let entry = manifest.entries[ordinal]
        guard entry.barrier == nil, entry.contentHash != nil,
          entry.camera.partitionID(manifestFingerprint: token.manifestFingerprint)
            == detected.cameraPartitionID
        else { throw LibraryError.invalid("序列跨越失败项或不可信相机边界") }
        while coverageIndex < coverage.count && coverage[coverageIndex].range.last < ordinal {
          coverageIndex += 1
        }
        guard coverageIndex < coverage.count, coverage[coverageIndex].state == .complete else {
          throw LibraryError.invalid("序列跨越未完成或证据不足范围")
        }
      }
    }
  }

  /// Strict consumer boundary: requires the original request token and all observed input rows.
  /// Clock partition derivation is Imaging-owned; IDs alone do not certify the observed clocks.
  public func validate(
    manifest: SequenceInputManifest, expectedToken: SequenceAnalysisToken,
    observations: [SequenceAssetInput]
  ) throws {
    try validateStructure(manifest: manifest, expectedToken: expectedToken)
    guard observations.count == manifest.entries.count else {
      throw LibraryError.invalid("序列观察遗漏清单中的资产")
    }
    var coverageIndex = 0
    for (ordinal, observation) in observations.enumerated() {
      guard observation.entry == manifest.entries[ordinal] else {
        throw LibraryError.invalid("序列观察顺序或资产与清单不一致")
      }
      while coverageIndex < coverage.count && coverage[coverageIndex].range.last < ordinal {
        coverageIndex += 1
      }
      let issues = observation.validationIssues(manifest: manifest, versions: token.versions)
      try validateCoverageClassification(coverage[coverageIndex], knownIssues: issues)
      if coverage[coverageIndex].state == .complete,
        !issues.isEmpty
      { throw LibraryError.invalid("序列完整覆盖包含未验证的观察") }
    }
    for detected in ranges {
      var previous: SequenceAssetInput?
      var highWaterSecond: Int64?
      var highWaterNanosecond: Int?
      for ordinal in detected.range.first...detected.range.last {
        let observation = observations[ordinal]
        guard observation.validationIssues(manifest: manifest, versions: token.versions).isEmpty,
          let clock = observation.clock, clock.id == detected.clockPartitionID,
          let time = observation.evidence?.time, let local = time.local
        else { throw LibraryError.invalid("序列包含无效的内容、时间或时钟分区") }
        if let previous, let before = previous.evidence?.time, let earlier = before.local {
          guard previous.clock == clock, before.offsetMinutes == time.offsetMinutes,
            local.civilSecond >= earlier.civilSecond
          else { throw LibraryError.invalid("序列跨越时钟回拨或偏移变化") }
        }
        if highWaterSecond != local.civilSecond {
          highWaterSecond = local.civilSecond
          highWaterNanosecond = nil
        }
        if let nanos = local.nanosecond {
          guard highWaterNanosecond.map({ nanos >= $0 }) ?? true else {
            throw LibraryError.invalid("序列跨越已知的亚秒时钟回拨")
          }
          highWaterNanosecond = nanos
        }
        previous = observation
      }
    }
  }
}
