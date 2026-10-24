import XCTest

@testable import RAWMasterCore

final class SequenceAnalysisTests: XCTestCase {
  let contentDigest = String(repeating: "a", count: 64)
  let camera = SequenceCameraEvidence.verifiedDevice(
    opaqueID: "synthetic-camera", source: "unit-test-fixture", validationVersion: "fixture-v1")
  var versions: SequenceAnalysisVersions {
    SequenceAnalysisVersions(
      extractor: "extractor-v1", feature: "feature-v1", algorithm: "algorithm-v1",
      policy: "policy-v1", order: SequenceBaseOrder.version)
  }
  func manifest(_ entries: [SequenceManifestEntry]? = nil) throws -> SequenceInputManifest {
    try SequenceInputManifest(
      scopeID: "scope", sessionID: "session", orderVersion: SequenceBaseOrder.version,
      entries: entries ?? (0..<4).map {
        SequenceManifestEntry(assetID: "asset-\($0)", ordinal: $0, contentHash: contentDigest, camera: camera)
      })
  }
  func token(_ manifest: SequenceInputManifest, generation: Int = 0) throws -> SequenceAnalysisToken {
    try SequenceAnalysisToken.make(
      manifest: manifest, versions: versions,
      policyFingerprint: SequenceFingerprint.digest(["window": 4]), generation: generation)
  }
  func range(_ first: Int, _ last: Int) throws -> SequenceOrdinalRange {
    try SequenceOrdinalRange(first: first, last: last)
  }
  func detected(_ manifest: SequenceInputManifest, _ first: Int = 0, _ last: Int = 3) throws
    -> SequenceDetectedRange
  {
    SequenceDetectedRange(
      range: try range(first, last), kind: .burst,
      cameraPartitionID: try XCTUnwrap(camera.partitionID(manifestFingerprint: manifest.contentFingerprint)),
      clockPartitionID: "clock-era-0", reasons: ["synthetic"])
  }
  func evidence(_ entry: SequenceManifestEntry, hash: String? = nil, extractor: String? = nil,
    revision: Int? = nil, offset: String? = nil) -> SequenceCaptureEvidence
  {
    SequenceCaptureEvidence(
      assetID: entry.assetID, contentHash: hash ?? self.contentDigest,
      extractorVersion: extractor ?? versions.extractor,
      evidenceRevision: revision ?? entry.evidenceRevision,
      time: SequenceTimestampParser.parse(
        original: "2026:10:24 12:00:00", subseconds: "123", offset: offset))
  }

  func testManifestRejectsGapsDuplicatesBadHashAndDecodeBypass() throws {
    for entries in [
      [SequenceManifestEntry(assetID: "a", ordinal: 1, contentHash: contentDigest)],
      [SequenceManifestEntry(assetID: "", ordinal: 0, contentHash: contentDigest)],
      [SequenceManifestEntry(assetID: "a", ordinal: 0, contentHash: "bad")],
      [SequenceManifestEntry(assetID: "a", ordinal: 0, contentHash: contentDigest, evidenceRevision: -1)],
      [SequenceManifestEntry(assetID: "a", ordinal: 0, contentHash: contentDigest),
       SequenceManifestEntry(assetID: "a", ordinal: 1, contentHash: contentDigest)],
    ] {
      XCTAssertThrowsError(try manifest(entries))
    }
    let good = try manifest()
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
    var entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
    entries[0]["ordinal"] = -1
    json["entries"] = entries
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        SequenceInputManifest.self, from: JSONSerialization.data(withJSONObject: json)))
    entries[0]["ordinal"] = 0
    entries[1]["assetID"] = entries[0]["assetID"]
    json["entries"] = entries
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        SequenceInputManifest.self, from: JSONSerialization.data(withJSONObject: json)))
    entries[1]["assetID"] = "restored-unique"
    entries[0].removeValue(forKey: "ordinal")
    json["entries"] = entries
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        SequenceInputManifest.self, from: JSONSerialization.data(withJSONObject: json)))
  }

  func testBarrierAndSameContentDistinctAssetsAreNotFilteredOrAliased() throws {
    let entries = [
      SequenceManifestEntry(assetID: "a", ordinal: 0, contentHash: contentDigest, camera: camera),
      SequenceManifestEntry(assetID: "unreadable", ordinal: 1, contentHash: nil, barrier: .unreadable),
      SequenceManifestEntry(assetID: "duplicate-content", ordinal: 2, contentHash: contentDigest, camera: camera),
    ]
    let m = try manifest(entries)
    XCTAssertEqual(m.entries.map(\.ordinal), [0, 1, 2])
    XCTAssertEqual(m.entries.map(\.assetID), ["a", "unreadable", "duplicate-content"])
    let restored = try JSONDecoder().decode(
      SequenceInputManifest.self, from: JSONEncoder().encode(m))
    XCTAssertEqual(restored, m)
    XCTAssertEqual(restored.entries[1].barrier, .unreadable)
    XCTAssertEqual(restored.entries[0].contentHash, restored.entries[2].contentHash)
  }

  func testManifestAssertionBindsWholeContentListWithoutCircularFingerprint() throws {
    let unknown = try manifest((0..<2).map {
      SequenceManifestEntry(assetID: "asset-\($0)", ordinal: $0, contentHash: contentDigest)
    })
    let assertion = SequenceCameraEvidence.manifestAssertion(
      id: "user-assertion", revision: 2, manifestFingerprint: unknown.contentFingerprint)
    let asserted = try manifest(unknown.entries.map {
      SequenceManifestEntry(
        assetID: $0.assetID, ordinal: $0.ordinal, contentHash: $0.contentHash, camera: assertion)
    })
    XCTAssertEqual(unknown.contentFingerprint, asserted.contentFingerprint)
    XCTAssertNotEqual(try token(unknown).inputFingerprint, try token(asserted).inputFingerprint)
    XCTAssertNotNil(assertion.partitionID(manifestFingerprint: asserted.contentFingerprint))
    let expanded = try manifest(asserted.entries + [
      SequenceManifestEntry(assetID: "new", ordinal: 2, contentHash: contentDigest, camera: assertion)
    ])
    XCTAssertNotEqual(expanded.contentFingerprint, asserted.contentFingerprint)
    XCTAssertNil(assertion.partitionID(manifestFingerprint: expanded.contentFingerprint))
    let input = SequenceAssetInput(
      entry: expanded.entries[0], evidence: evidence(expanded.entries[0]),
      clock: SequenceClockPartition(id: "era", basis: .localCivil, derivationVersion: "clock-v1"))
    XCTAssertTrue(input.validationIssues(manifest: expanded, versions: versions).contains(.assertionMismatch))
  }

  func testTokenDeterministicAndRelevantInputVersionChangesInvalidate() throws {
    let m = try manifest()
    let t = try token(m)
    XCTAssertEqual(t, try token(m))
    XCTAssertNotEqual(t, try token(m, generation: 1))
    let evidenceChanged = try manifest(m.entries.map {
      SequenceManifestEntry(
        assetID: $0.assetID, ordinal: $0.ordinal, contentHash: $0.contentHash,
        evidenceRevision: 1, camera: $0.camera)
    })
    XCTAssertEqual(evidenceChanged.contentFingerprint, m.contentFingerprint)
    XCTAssertNotEqual(try token(evidenceChanged).inputFingerprint, t.inputFingerprint)
    XCTAssertNotEqual(
      try SequenceAnalysisToken.make(
        manifest: m, versions: versions, policyFingerprint: SequenceFingerprint.digest(["window": 5])), t)
    XCTAssertThrowsError(
      try SequenceAnalysisToken.make(
        manifest: m, versions: versions, policyFingerprint: t.policyFingerprint, generation: -1))
    XCTAssertThrowsError(
      try SequenceAnalysisToken.make(manifest: m, versions: versions, policyFingerprint: "label-not-hash"))
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
    json["inputFingerprint"] = String(repeating: "0", count: 64)
    let forged = try JSONDecoder().decode(
      SequenceAnalysisToken.self, from: JSONSerialization.data(withJSONObject: json))
    let result = SequenceAnalysisResult(
      token: forged, ranges: [], coverage: [.init(range: try range(0, 3), state: .complete)])
    XCTAssertThrowsError(try result.validateStructure(manifest: m))
  }

  func testObservationContentVersionCameraAndClockMustBeValidated() throws {
    let m = try manifest()
    let entry = m.entries[0]
    let clock = SequenceClockPartition(id: "era", basis: .localCivil, derivationVersion: "clock-v1")
    let valid = SequenceAssetInput(entry: entry, evidence: evidence(entry), clock: clock)
    XCTAssertEqual(valid.validationIssues(manifest: m, versions: versions), [])
    let mismatched = SequenceAssetInput(
      entry: entry, evidence: evidence(entry, hash: String(repeating: "b", count: 64),
        extractor: "old-extractor", revision: 1), clock: nil)
    XCTAssertEqual(
      Set(mismatched.validationIssues(manifest: m, versions: versions)),
      Set([.contentMismatch, .extractorMismatch, .evidenceRevisionMismatch, .invalidClockPartition]))
    let utcClock = SequenceClockPartition(id: "era", basis: .explicitUTC, derivationVersion: "clock-v1")
    let noOffset = SequenceAssetInput(entry: entry, evidence: evidence(entry), clock: utcClock)
    XCTAssertEqual(noOffset.validationIssues(manifest: m, versions: versions), [.invalidClockPartition])
    let explicit = SequenceAssetInput(entry: entry, evidence: evidence(entry, offset: "+08:00"), clock: utcClock)
    XCTAssertEqual(explicit.validationIssues(manifest: m, versions: versions), [])
    let unknown = try manifest([.init(assetID: "u", ordinal: 0, contentHash: contentDigest)])
    let unknownInput = SequenceAssetInput(
      entry: unknown.entries[0], evidence: evidence(unknown.entries[0]), clock: clock)
    XCTAssertEqual(unknownInput.validationIssues(manifest: unknown, versions: versions), [.cameraIdentityUnknown])
    XCTAssertNil(SequenceCameraEvidence.verifiedDevice(
      opaqueID: "", source: "unverified", validationVersion: "").partitionID(manifestFingerprint: m.contentFingerprint))
  }

  func testResultRejectsGapOverlapOutOfBoundsAndNoncompleteDetection() throws {
    let m = try manifest()
    let t = try token(m)
    let detected = try detected(m)
    let good = SequenceAnalysisResult(
      token: t, ranges: [detected], coverage: [.init(range: try range(0, 3), state: .complete)])
    XCTAssertNoThrow(try good.validateStructure(manifest: m, expectedToken: t))
    XCTAssertEqual(
      try JSONDecoder().decode(SequenceAnalysisResult.self, from: JSONEncoder().encode(good)), good)
    XCTAssertThrowsError(try good.validateStructure(manifest: m, expectedToken: token(m, generation: 1)))
    let badCoverage: [[SequenceCoverageRange]] = [
      [], [.init(range: try range(1, 3), state: .complete)],
      [.init(range: try range(0, 1), state: .complete), .init(range: try range(1, 3), state: .complete)],
      [.init(range: try range(0, 4), state: .complete)],
      [.init(range: try range(0, 3), state: .insufficient, reasons: [.insufficientEvidence])],
    ]
    for coverage in badCoverage {
      XCTAssertThrowsError(try SequenceAnalysisResult(token: t, ranges: [detected], coverage: coverage).validateStructure(manifest: m))
    }
    for detections in [
      [try self.detected(m, 0, 0)], [try self.detected(m, 0, 4)],
      [try self.detected(m, 0, 2), try self.detected(m, 2, 3)],
    ] {
      XCTAssertThrowsError(try SequenceAnalysisResult(token: t, ranges: detections, coverage: good.coverage).validateStructure(manifest: m))
    }
  }

  func testFailedOrUnknownRowsMustKeepCoverageAndCannotBeBridged() throws {
    let m = try manifest([
      .init(assetID: "a", ordinal: 0, contentHash: contentDigest, camera: camera),
      .init(assetID: "failed", ordinal: 1, contentHash: nil, barrier: .unreadable),
      .init(assetID: "c", ordinal: 2, contentHash: contentDigest, camera: camera),
    ])
    let coverage: [SequenceCoverageRange] = [
      .init(range: try range(0, 0), state: .insufficient, reasons: [.noSequenceSupport]),
      .init(range: try range(1, 1), state: .unreadable, reasons: [.unreadable]),
      .init(range: try range(2, 2), state: .insufficient, reasons: [.noSequenceSupport]),
    ]
    XCTAssertNoThrow(try SequenceAnalysisResult(token: token(m), ranges: [], coverage: coverage).validateStructure(manifest: m))
    XCTAssertThrowsError(
      try SequenceAnalysisResult(token: token(m), ranges: [detected(m, 0, 2)], coverage: coverage).validateStructure(manifest: m))
    XCTAssertThrowsError(
      try SequenceAnalysisResult(token: token(m), ranges: [], coverage: [.init(range: range(0, 2), state: .complete)]).validateStructure(manifest: m))
    let unknown = try manifest([.init(assetID: "unknown", ordinal: 0, contentHash: contentDigest)])
    XCTAssertThrowsError(
      try SequenceAnalysisResult(token: token(unknown), ranges: [], coverage: [.init(range: range(0, 0), state: .complete)]).validateStructure(manifest: unknown))
  }

  func testEmptyManifestAndRangeDecodeAreSafe() throws {
    let empty = try manifest([])
    XCTAssertNoThrow(try SequenceAnalysisResult(token: token(empty), ranges: [], coverage: []).validateStructure(manifest: empty))
    XCTAssertThrowsError(try range(2, 1))
    XCTAssertThrowsError(try range(-1, 0))
    XCTAssertThrowsError(try range(0, Int.max))
    XCTAssertThrowsError(
      try JSONDecoder().decode(SequenceOrdinalRange.self, from: Data(#"{"first":-1,"last":2}"#.utf8)))
  }

  func testStrictBoundaryChecksObservedClockAndContentRatherThanOnlyResultIDs() throws {
    let m = try manifest()
    let t = try token(m)
    let clock = SequenceClockPartition(
      id: "clock-era-0", basis: .localCivil, derivationVersion: "clock-v1")
    let inputs = m.entries.map { SequenceAssetInput(entry: $0, evidence: evidence($0), clock: clock) }
    let result = SequenceAnalysisResult(
      token: t, ranges: [try detected(m)],
      coverage: [.init(range: try range(0, 3), state: .complete)])
    XCTAssertNoThrow(try result.validate(manifest: m, expectedToken: t, observations: inputs))
    XCTAssertThrowsError(try result.validate(
      manifest: m, expectedToken: token(m, generation: 1), observations: inputs))
    XCTAssertThrowsError(try result.validate(
      manifest: m, expectedToken: t, observations: Array(inputs.dropLast())))
    XCTAssertThrowsError(try result.validate(
      manifest: m, expectedToken: t, observations: Array(inputs.reversed())))
    var changed = inputs
    changed[1] = SequenceAssetInput(
      entry: m.entries[1], evidence: evidence(m.entries[1]),
      clock: .init(id: "different-era", basis: .localCivil, derivationVersion: "clock-v1"))
    XCTAssertThrowsError(try result.validate(manifest: m, expectedToken: t, observations: changed))
    changed[1] = SequenceAssetInput(
      entry: m.entries[1], evidence: evidence(m.entries[1], hash: String(repeating: "b", count: 64)),
      clock: clock)
    XCTAssertThrowsError(try result.validate(manifest: m, expectedToken: t, observations: changed))
    for (date, subsecond, offset) in [
      ("2026:10:24 11:59:59", "123", nil),
      ("2026:10:24 12:00:00", "122", nil),
      ("2026:10:24 12:00:00", "123", "+08:00"),
    ] as [(String, String, String?)] {
      let alteredEvidence = SequenceCaptureEvidence(
        assetID: m.entries[1].assetID, contentHash: contentDigest, extractorVersion: versions.extractor,
        time: SequenceTimestampParser.parse(original: date, subseconds: subsecond, offset: offset))
      changed[1] = SequenceAssetInput(entry: m.entries[1], evidence: alteredEvidence, clock: clock)
      XCTAssertTrue(alteredEvidence.time.isConsistent)
      XCTAssertThrowsError(try result.validate(manifest: m, expectedToken: t, observations: changed))
    }
  }

  func testStrictSubsecondHighWaterSurvivesUnknownPrecisionWithinTheSameSecond() throws {
    let cases: [([String?], Bool)] = [
      (["900", nil, "100"], false),
      (["900", "invalid", "100"], false),
      (["900", nil, nil, "100"], false),
      (["100", nil, "900"], true),
      (["900", nil, "900"], true),
    ]
    for (fractions, shouldPass) in cases {
      let m = try manifest(fractions.indices.map {
        .init(assetID: "asset-\($0)", ordinal: $0, contentHash: contentDigest, camera: camera)
      })
      let t = try token(m)
      let result = SequenceAnalysisResult(
        token: t, ranges: [try detected(m, 0, fractions.count - 1)],
        coverage: [.init(range: try range(0, fractions.count - 1), state: .complete)])
      let inputs = m.entries.enumerated().map { ordinal, entry in
        SequenceAssetInput(
          entry: entry,
          evidence: SequenceCaptureEvidence(
            assetID: entry.assetID, contentHash: contentDigest, extractorVersion: versions.extractor,
            time: SequenceTimestampParser.parse(
              original: "2026:10:24 12:00:00", subseconds: fractions[ordinal], offset: nil)),
          clock: .init(id: "clock-era-0", basis: .localCivil, derivationVersion: "clock-v1"))
      }
      XCTAssertTrue(inputs.allSatisfy { $0.evidence?.time.isConsistent == true })
      if shouldPass {
        XCTAssertNoThrow(try result.validate(manifest: m, expectedToken: t, observations: inputs))
      } else {
        XCTAssertThrowsError(try result.validate(manifest: m, expectedToken: t, observations: inputs))
      }
    }
    // Entering a later civil second resets only that second's fractional constraint.
    let m = try manifest()
    let t = try token(m)
    let inputs = m.entries.enumerated().map { ordinal, entry in
      SequenceAssetInput(
        entry: entry,
        evidence: SequenceCaptureEvidence(
          assetID: entry.assetID, contentHash: contentDigest, extractorVersion: versions.extractor,
          time: SequenceTimestampParser.parse(
            original: ordinal == 0 ? "2026:10:24 12:00:00" : "2026:10:24 12:00:01",
            subseconds: ["900", nil, "100", "200"][ordinal], offset: nil)),
        clock: .init(id: "clock-era-0", basis: .localCivil, derivationVersion: "clock-v1"))
    }
    XCTAssertNoThrow(try SequenceAnalysisResult(
      token: t, ranges: [detected(m)], coverage: [.init(range: range(0, 3), state: .complete)]
    ).validate(manifest: m, expectedToken: t, observations: inputs))
  }

  func testKnownTransientManifestBarrierCannotBecomeCheckedInsufficient() throws {
    for reason in [SequenceReason.unreadable, .incomplete] {
      let m = try manifest([
        .init(assetID: "asset", ordinal: 0, contentHash: contentDigest, camera: camera, barrier: reason)
      ])
      let t = try token(m)
      for wrong in [
        SequenceCoverageRange(range: try range(0, 0), state: .insufficient, reasons: [.noSequenceSupport]),
        SequenceCoverageRange(range: try range(0, 0), state: .insufficient, reasons: [reason]),
        SequenceCoverageRange(range: try range(0, 0), state: .unreadable, reasons: [.noSequenceSupport]),
        SequenceCoverageRange(range: try range(0, 0), state: .incomplete, reasons: [.noSequenceSupport]),
      ] {
        let result = SequenceAnalysisResult(token: t, ranges: [], coverage: [wrong])
        let decoded = try JSONDecoder().decode(
          SequenceAnalysisResult.self, from: JSONEncoder().encode(result))
        XCTAssertThrowsError(try decoded.validateStructure(manifest: m, expectedToken: t))
      }
      let correct = SequenceAnalysisResult(
        token: t, ranges: [], coverage: [.init(
          range: try range(0, 0), state: reason == .unreadable ? .unreadable : .incomplete,
          reasons: [reason])])
      XCTAssertNoThrow(try correct.validateStructure(manifest: m, expectedToken: t))
      let observations = [SequenceAssetInput(entry: m.entries[0], evidence: nil, clock: nil)]
      XCTAssertNoThrow(try correct.validate(manifest: m, expectedToken: t, observations: observations))
      let unfinished = SequenceAnalysisResult(
        token: t, ranges: [], coverage: [.init(range: try range(0, 0), state: .incomplete, reasons: [.incomplete])])
      XCTAssertNoThrow(try unfinished.validate(manifest: m, expectedToken: t, observations: observations))
      if reason == .incomplete {
        let unreadable = SequenceAnalysisResult(
          token: t, ranges: [], coverage: [.init(range: try range(0, 0), state: .unreadable, reasons: [.unreadable])])
        XCTAssertThrowsError(try unreadable.validateStructure(manifest: m, expectedToken: t))
      }
    }
  }

  func testObservedTransientFailureMustKeepCoverageMeaningButCheckedInsufficiencyRemainsLegal() throws {
    let m = try manifest([
      .init(assetID: "asset", ordinal: 0, contentHash: contentDigest, camera: camera)
    ])
    let t = try token(m)
    for reason in [SequenceReason.unreadable, .incomplete] {
      let observations = [SequenceAssetInput(
        entry: m.entries[0], evidence: evidence(m.entries[0]),
        clock: .init(id: "era", basis: .localCivil, derivationVersion: "clock-v1"), barrier: reason)]
      let insufficient = SequenceAnalysisResult(
        token: t, ranges: [], coverage: [.init(range: try range(0, 0), state: .insufficient, reasons: [.noSequenceSupport])])
      // Only the read observation knows this failure; manifest-only validation is insufficient.
      XCTAssertNoThrow(try insufficient.validateStructure(manifest: m, expectedToken: t))
      XCTAssertThrowsError(try insufficient.validate(manifest: m, expectedToken: t, observations: observations))
      let correct = SequenceAnalysisResult(
        token: t, ranges: [], coverage: [.init(
          range: try range(0, 0), state: reason == .unreadable ? .unreadable : .incomplete,
          reasons: [reason])])
      XCTAssertNoThrow(try correct.validate(manifest: m, expectedToken: t, observations: observations))
      let unfinished = SequenceAnalysisResult(
        token: t, ranges: [], coverage: [.init(range: try range(0, 0), state: .incomplete, reasons: [.incomplete])])
      XCTAssertNoThrow(try unfinished.validate(manifest: m, expectedToken: t, observations: observations))
      if reason == .unreadable {
        let wrongReason = SequenceAnalysisResult(
          token: t, ranges: [], coverage: [.init(
            range: try range(0, 0), state: .unreadable, reasons: [.missingEmbeddedPreview])])
        XCTAssertThrowsError(try wrongReason.validate(manifest: m, expectedToken: t, observations: observations))
      }
    }
    for reason in [SequenceReason.missingEmbeddedPreview, .invalidTimestamp, .cameraIdentityUnknown] {
      let observations = [SequenceAssetInput(
        entry: m.entries[0], evidence: nil, clock: nil, barrier: reason)]
      let checked = SequenceAnalysisResult(
        token: t, ranges: [], coverage: [.init(range: try range(0, 0), state: .insufficient, reasons: [reason])])
      XCTAssertNoThrow(try checked.validate(manifest: m, expectedToken: t, observations: observations))
    }
  }
}
