import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class SequenceDetectorTests: XCTestCase {
    let contentDigest = String(repeating: "a", count: 64)
    func feature(_ color: Float = 0, informative: Bool = true) throws -> SequenceFrameFeature {
        var histogram = [Float](repeating: 0, count: 48)
        for c in 0..<3 { histogram[c * 16] = 1 - color; histogram[c * 16 + 15] = color }
        return try SequenceFrameFeature(width: 32, height: 32,
            normalizedLuminance: (0..<1024).map { $0.isMultiple(of: 2) ? -1 : 1 }, colorHistogram: histogram,
            differenceHash: 0, mean: 0.5, standardDeviation: informative ? 0.2 : 0)
    }
    func manifest(_ count: Int, camera: SequenceCameraEvidence? = nil, barriers: [Int: SequenceReason] = [:]) throws -> SequenceInputManifest {
        let entries = (0..<count).map { SequenceManifestEntry(assetID: "opaque-\($0)", ordinal: $0, contentHash: contentDigest, barrier: barriers[$0]) }
        let raw = try SequenceInputManifest(scopeID: "scope", sessionID: "session", orderVersion: SequenceBaseOrder.version, entries: entries)
        let proof = camera ?? .manifestAssertion(id: "explicit-whole-manifest-test-assumption", revision: 1, manifestFingerprint: raw.contentFingerprint)
        return try SequenceInputManifest(scopeID: raw.scopeID, sessionID: raw.sessionID, orderVersion: raw.orderVersion,
            entries: entries.map { SequenceManifestEntry(assetID: $0.assetID, ordinal: $0.ordinal, contentHash: $0.contentHash, camera: proof, barrier: $0.barrier) })
    }
    func evidence(_ entry: SequenceManifestEntry, seconds: Double, subsecond: Bool = true, offset: String? = nil, exposure: Double? = 0.01) -> SequenceCaptureEvidence {
        let millis = Int((seconds * 1000).rounded()), whole = millis / 1000
        let date = String(format: "2026:10:01 %02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
        let time = SequenceTimestampParser.parse(original: date, subseconds: subsecond ? String(format: "%03d", millis % 1000) : nil, offset: offset)
        return SequenceCaptureEvidence(assetID: entry.assetID, contentHash: contentDigest, extractorVersion: SequenceCaptureReader.extractorVersion,
            time: time, cameraModel: "model-alone-is-not-device", exposureSeconds: exposure)
    }
    func detector(_ manifest: SequenceInputManifest, _ config: SequenceDetectorConfiguration = .init()) throws -> SequenceDetector {
        let token = try SequenceAnalysisToken.make(manifest: manifest, versions: config.versions(order: manifest.orderVersion), policyFingerprint: config.fingerprint)
        return try SequenceDetector(manifest: manifest, token: token, configuration: config)
    }
    func run(_ times: [Double], colors: [Float]? = nil, subsecond: Bool = true, config: SequenceDetectorConfiguration = .init(),
             badAt: Int? = nil, camera: SequenceCameraEvidence? = nil, offsets: [String?]? = nil) throws -> SequenceAnalysisResult {
        let scope = try manifest(times.count, camera: camera)
        var engine = try detector(scope, config), prepare = SequenceObservationPreprocessor(manifest: scope)
        var observations: [SequenceAssetInput] = []
        for (i, time) in times.enumerated() {
            let observation = prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: time,
                subsecond: subsecond, offset: offsets?[i] ?? nil), feature: i == badAt ? nil : try feature(colors?[i] ?? 0))
            observations.append(observation.input); try engine.consume(observation)
        }
        let result = try engine.finish()
        try result.validate(manifest: scope, expectedToken: result.token, observations: observations)
        XCTAssertLessThanOrEqual(engine.managedPeakEstimateBytes, config.memoryBudgetBytes)
        return result
    }
    func testTwoFrameBurstAndUnrelatedFrameRemainDistinct() throws {
        let result = try run([0, 0.1, 0.2], colors: [0, 0.01, 0.8])
        XCTAssertEqual(result.ranges.count, 1)
        XCTAssertEqual(result.ranges[0].range, try SequenceOrdinalRange(first: 0, last: 1))
        XCTAssertEqual(result.ranges[0].kind, .burst)
        XCTAssertEqual(result.coverage.last?.state, .insufficient)
    }
    func testLongPauseRequiresMultipleFramesOnBothSides() throws {
        let times: [Double] = [0, 0.05, 0.1, 9.1, 9.15, 9.2, 9.25]
        let result = try run(times, colors: [0, 0.01, 0.02, 0.12, 0.13, 0.14, 0.15])
        XCTAssertEqual(result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 6)])
        let unsupported = try run([0, 0.05, 0.1, 9.1], colors: [0, 0, 0, 0.1])
        XCTAssertEqual(unsupported.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 2)])
    }
    func testFailedBridgeKeepsRightRunOpenRatherThanSplittingEveryThree() throws {
        let result = try run([0, 0.05, 0.1, 5, 5.05, 5.1, 5.15, 5.2], colors: [0, 0, 0, 0.8, 0.8, 0.8, 0.8, 0.8])
        XCTAssertEqual(result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 2), try SequenceOrdinalRange(first: 3, last: 7)])
    }
    func testAnchorPreventsArbitrarilyLongLocallySimilarColorChain() throws {
        let colors = (0..<20).map { Float($0) * 0.04 }
        let result = try run((0..<20).map { Double($0) * 0.05 }, colors: colors)
        XCTAssertGreaterThan(result.ranges.count, 1)
        XCTAssertFalse(result.ranges.contains { $0.range.first == 0 && $0.range.last == 19 })
    }
    func runFeatures(_ times: [Double], _ features: [SequenceFrameFeature]) throws -> SequenceAnalysisResult {
        let scope = try manifest(times.count)
        var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for i in times.indices {
            try engine.consume(prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: times[i]), feature: features[i]))
        }
        return try engine.finish()
    }
    func testConstantHistogramCannotHideCumulativeHashOrSpatialDrift() throws {
        let base = try feature()
        let count = 64
        let hashes = try (0..<count).map { i in
            try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: base.normalizedLuminance,
                colorHistogram: base.colorHistogram, differenceHash: i == 0 ? 0 : UInt64.max >> (64 - i), mean: 0.5, standardDeviation: 0.2)
        }
        let hashResult = try runFeatures((0..<count).map { Double($0) * 0.05 }, hashes)
        XCTAssertFalse(hashResult.ranges.contains { $0.range.count == count })
        XCTAssertGreaterThan(hashResult.ranges.count, 1)
        let spatial = try (0..<count).map { i -> SequenceFrameFeature in
            let angle = Float(i) * .pi / Float(count - 1)
            let luma = (0..<1024).map { index -> Float in
                let a: Float = index.isMultiple(of: 2) ? 1 : -1
                let b: Float = (index / 2).isMultiple(of: 2) ? 1 : -1
                return cos(angle) * a + sin(angle) * b
            }
            return try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: luma,
                colorHistogram: base.colorHistogram, differenceHash: 0, mean: 0.5, standardDeviation: 0.2)
        }
        let spatialResult = try runFeatures((0..<count).map { Double($0) * 0.05 }, spatial)
        XCTAssertFalse(spatialResult.ranges.contains { $0.range.count == count })
    }
    func testIntervalSeedAndExtensionUseTheSameStrongSceneBoundary() throws {
        let a = try feature(0)
        let b = try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: a.normalizedLuminance.map { -$0 },
            colorHistogram: try feature(0.9).colorHistogram, differenceHash: .max, mean: 0.5, standardDeviation: 0.2)
        let seed = try runFeatures([0, 2, 4, 6], [a, b, a, b])
        XCTAssertTrue(seed.ranges.isEmpty)
        let extensionResult = try runFeatures([0, 2, 4, 6, 8], [a, a, a, a, b])
        XCTAssertEqual(extensionResult.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 3)])
    }
    func testFixedCadenceAndMissingFrameUseWholeOriginPhase() throws {
        let result = try run([0, 2, 4, 6, 10, 12, 14, 16])
        XCTAssertEqual(result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 7)])
        XCTAssertEqual(result.ranges.first?.kind, .interval)
        let jitter = try run([0, 2.02, 3.98, 6.03, 8.01, 10.02])
        XCTAssertEqual(jitter.ranges.first?.range.count, 6)
    }
    func testAccumulatingCadenceDriftCannotSlideOriginForever() throws {
        var times: [Double] = [0]
        for i in 0..<40 { times.append(times.last! + 2 + Double(i) * 0.015) }
        let result = try run(times)
        XCTAssertFalse(result.ranges.contains { $0.range.count == times.count })
        XCTAssertTrue(result.ranges.count > 1 || result.coverage.contains { $0.state == .insufficient })
    }
    func testExcessMissingAndAlternatingPeriodAreNotOneInterval() throws {
        // A genuine pause may restart phase within 12P; this gap exceeds that bound.
        let missing = try run([0, 2, 4, 6, 31, 33, 35, 37])
        XCTAssertFalse(missing.ranges.contains { $0.range.count == 8 })
        let alternating = try run([0, 2, 5.3, 7.3, 10.6, 12.6, 15.9])
        XCTAssertFalse(alternating.ranges.contains { $0.range.count == 7 })
    }
    func testSecondsPrecisionCanResolveLongCadenceButNotDenseBurst() throws {
        XCTAssertTrue(try run([0, 0.1, 0.2], subsecond: false).ranges.isEmpty)
        let long = try run([0, 10, 20, 30, 40], subsecond: false)
        XCTAssertEqual(long.ranges.first?.kind, .interval)
        XCTAssertEqual(long.ranges.first?.range.count, 5)
    }
    func testUnknownDeviceAndAssertionMismatchNeverBecomeSuccessfulCoverage() throws {
        let unknown = try run([0, 0.1, 0.2], camera: .unknown)
        XCTAssertTrue(unknown.ranges.isEmpty)
        XCTAssertTrue(unknown.coverage.allSatisfy { $0.state != .complete })
        let mismatch = try run([0, 0.1], camera: .manifestAssertion(id: "not-this-manifest", revision: 0, manifestFingerprint: contentDigest))
        XCTAssertTrue(mismatch.ranges.isEmpty)
    }
    func testBadPreviewClockRollbackAndOffsetChangeAreRealBarriers() throws {
        let bad = try run([0, 0.05, 0.1, 0.15, 0.2], badAt: 2)
        XCTAssertEqual(bad.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 1), try SequenceOrdinalRange(first: 3, last: 4)])
        XCTAssertTrue(bad.coverage.contains { $0.range.first == 2 && $0.state == .unreadable })
        let rollback = try run([1, 1.05, 0.8, 0.85, 0.9])
        XCTAssertFalse(rollback.ranges.contains { $0.range.count == 5 })
        let offsets: [String?] = ["+08:00", "+08:00", "+09:00", "+09:00", "+09:00"]
        XCTAssertFalse(try run([0, 0.05, 0.1, 0.15, 0.2], offsets: offsets).ranges.contains { $0.range.count == 5 })
    }
    func testLowTextureIsNotStrongBurstEvidence() throws {
        let scope = try manifest(3)
        var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for i in 0..<3 {
            try engine.consume(prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: Double(i) * 0.05), feature: try feature(informative: false)))
        }
        XCTAssertTrue(try engine.finish().ranges.isEmpty)
    }
    func testCancellationAndUnsealedTailCannotPublishOpenRunAsComplete() throws {
        let scope = try manifest(5)
        var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for i in 0..<3 { try engine.consume(prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: Double(i) * 0.05), feature: try feature())) }
        engine.cancel()
        let result = try engine.finish()
        XCTAssertTrue(result.ranges.isEmpty)
        XCTAssertTrue(result.coverage.allSatisfy { $0.state == .incomplete })
        var second = try detector(scope)
        XCTAssertThrowsError(try second.consume(prepare.make(entry: scope.entries[0], evidence: evidence(scope.entries[0], seconds: 0), feature: try feature()), cancelled: { true }))
        XCTAssertTrue(try second.finish().coverage.allSatisfy { $0.state == .incomplete })
    }
    func testBudgetAndWrongOrdinalStopWithoutSilentTruncation() throws {
        let scope = try manifest(3)
        var prepare = SequenceObservationPreprocessor(manifest: scope)
        var config = SequenceDetectorConfiguration(); config.memoryBudgetBytes = 1024
        var tiny = try detector(scope, config)
        let observation = prepare.make(entry: scope.entries[0], evidence: evidence(scope.entries[0], seconds: 0), feature: try feature())
        XCTAssertThrowsError(try tiny.consume(observation))
        XCTAssertTrue(try tiny.finish().coverage.allSatisfy { $0.state == .incomplete })
        var wrong = try detector(scope)
        let second = prepare.make(entry: scope.entries[1], evidence: evidence(scope.entries[1], seconds: 0.05), feature: try feature())
        XCTAssertThrowsError(try wrong.consume(second))
        XCTAssertTrue(try wrong.finish().coverage.allSatisfy { $0.state == .incomplete })
    }
    func testMoreThan512AndArbitraryPagingDoNotCutSequence() throws {
        let times = (0..<1200).map { Double($0) * 2 }
        let scope = try manifest(times.count), f = try feature()
        var prep = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for start in stride(from: 0, to: times.count, by: 37) {
            for i in start..<min(start + 37, times.count) { try engine.consume(prep.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: times[i]), feature: f)) }
        }
        let result = try engine.finish()
        XCTAssertEqual(result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 1199)])
        XCTAssertLessThan(engine.managedPeakEstimateBytes, 8 * 1024 * 1024)
        XCTAssertEqual(result, try run(times))
    }
    func testActualLongExposureIsContextNotAnInferredTimeInterval() throws {
        let scope = try manifest(5)
        var prep = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for i in 0..<5 {
            try engine.consume(prep.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: Double(i) * 10, exposure: 9), feature: try feature()))
        }
        XCTAssertEqual(try engine.finish().ranges.first?.kind, .interval)
        let shortScope = try manifest(3)
        var shortPrep = SequenceObservationPreprocessor(manifest: shortScope), shortEngine = try detector(shortScope)
        for i in 0..<3 {
            try shortEngine.consume(shortPrep.make(entry: shortScope.entries[i], evidence: evidence(shortScope.entries[i], seconds: Double(i) * 0.05, exposure: 2), feature: try feature()))
        }
        XCTAssertTrue(try shortEngine.finish().ranges.isEmpty)
    }
    func testFullyConsumedButUnsealedInputStillHasNoCompletedTail() throws {
        let scope = try manifest(3)
        var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for i in 0..<3 { try engine.consume(prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: Double(i) * 0.05), feature: try feature())) }
        let result = try engine.finish(sealedInputComplete: false)
        XCTAssertTrue(result.ranges.isEmpty)
        XCTAssertEqual(result.coverage.count, 1)
        XCTAssertEqual(result.coverage[0].state, .incomplete)
        XCTAssertEqual(result.coverage[0].range.count, 3)
    }
    func testEOFSidesWithOneOrTwoFramesDoNotInventLongPauseBridge() throws {
        let one = try run([0, 0.05, 0.1, 4])
        XCTAssertEqual(one.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 2)])
        XCTAssertEqual(one.coverage.last?.state, .insufficient)
        let two = try run([0, 0.05, 0.1, 4, 4.05])
        XCTAssertEqual(two.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 2), try SequenceOrdinalRange(first: 3, last: 4)])
    }
    func testCancellationPreservesClosedPrefixAndMarksOpenAndUnreadTail() throws {
        let scope = try manifest(7)
        var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for i in 0..<5 {
            try engine.consume(prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: Double(i) * 0.05), feature: try feature(i < 3 ? 0 : 0.9)))
        }
        engine.cancel()
        let result = try engine.finish()
        XCTAssertEqual(result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 2)])
        XCTAssertEqual(result.coverage[0].state, .complete)
        XCTAssertTrue(result.coverage.dropFirst().allSatisfy { $0.state == .incomplete })
        let ordinals = result.coverage.flatMap { Array($0.range.first...$0.range.last) }
        XCTAssertEqual(ordinals, Array(0..<7))
    }
    func testKnownDifferentCameraMetadataContradictsEvenWholeManifestAssertion() throws {
        let scope = try manifest(6)
        for usePreprocessor in [true, false] {
        var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        for i in 0..<6 {
            let base = evidence(scope.entries[i], seconds: Double(i) * 0.05)
            let metadata = SequenceCaptureEvidence(assetID: base.assetID, contentHash: base.contentHash, extractorVersion: base.extractorVersion,
                time: base.time, cameraMake: i == 2 ? nil : i < 3 ? "SONY" : "Leica", cameraModel: i == 2 ? nil : i < 3 ? "A" : "Q", exposureSeconds: 0.01)
            let observation = usePreprocessor
                ? prepare.make(entry: scope.entries[i], evidence: metadata, feature: try feature())
                : SequenceObservation(input: SequenceAssetInput(entry: scope.entries[i], evidence: metadata,
                    clock: SequenceClockPartition(id: "same-untrusted-clock", basis: .localCivil, derivationVersion: SequenceObservationPreprocessor.version)), feature: try feature())
            try engine.consume(observation)
        }
        let result = try engine.finish()
        XCTAssertEqual(result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 2), try SequenceOrdinalRange(first: 4, last: 5)])
        XCTAssertTrue(result.coverage.contains { $0.range.first == 3 && $0.reasons.contains(.assertionMismatch) })
        XCTAssertTrue(result.warnings.contains("camera-metadata-contradicts-single-device-evidence"))
        }
    }
    func testMissingSubsecondCannotWashAwayKnownSameSecondHighWater() throws {
        for forward in [true, false] { for usePreprocessor in [true, false] {
            let scope = try manifest(3)
            var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
            let times = forward ? [0.1, 0, 0.9] : [0.9, 0, 0.1]
            for i in 0..<3 {
                let metadata = evidence(scope.entries[i], seconds: times[i], subsecond: i != 1)
                let observation = usePreprocessor
                    ? prepare.make(entry: scope.entries[i], evidence: metadata, feature: try feature())
                    : SequenceObservation(input: SequenceAssetInput(entry: scope.entries[i], evidence: metadata,
                        clock: SequenceClockPartition(id: "same-clock", basis: .localCivil, derivationVersion: SequenceObservationPreprocessor.version)), feature: try feature())
                if usePreprocessor && i == 2 { XCTAssertEqual(observation.input.barrier == nil, forward) }
                try engine.consume(observation)
            }
            let result = try engine.finish()
            let final = try XCTUnwrap(result.coverage.first { $0.range.first <= 2 && $0.range.last >= 2 })
            if forward { XCTAssertFalse(final.reasons.contains(.invalidClockPartition)); XCTAssertFalse(final.reasons.contains(.ambiguous)) }
            else { XCTAssertTrue(final.reasons.contains(.invalidClockPartition) || final.reasons.contains(.ambiguous)) }
        } }
    }
    func testKnownIncompleteAndUnreadableRowsKeepTheirPreservationStates() throws {
        let scope = try manifest(6, barriers: [1: .incomplete, 3: .unreadable])
        var prepare = SequenceObservationPreprocessor(manifest: scope), engine = try detector(scope)
        var observations: [SequenceAssetInput] = []
        for i in 0..<6 {
            let observation = prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: Double(i) * 0.05), feature: try feature())
            observations.append(observation.input); try engine.consume(observation)
        }
        let result = try engine.finish()
        try result.validate(manifest: scope, expectedToken: result.token, observations: observations)
        let incomplete = try XCTUnwrap(result.coverage.first { $0.range.first <= 1 && $0.range.last >= 1 })
        XCTAssertEqual(incomplete.state, .incomplete); XCTAssertTrue(incomplete.reasons.contains(.incomplete))
        let unreadable = try XCTUnwrap(result.coverage.first { $0.range.first <= 3 && $0.range.last >= 3 })
        XCTAssertEqual(unreadable.state, .unreadable); XCTAssertTrue(unreadable.reasons.contains(.unreadable))
        XCTAssertFalse(result.ranges.contains { $0.range.first < 3 && $0.range.last > 1 })
    }
    func testConfigurationInvalidValuesAndTokenMismatchAreRejected() throws {
        var invalid = SequenceDetectorConfiguration(); invalid.denseGapSeconds = .nan
        XCTAssertThrowsError(try invalid.validate())
        let scope = try manifest(2), original = SequenceDetectorConfiguration()
        let token = try SequenceAnalysisToken.make(manifest: scope, versions: original.versions(order: scope.orderVersion), policyFingerprint: original.fingerprint)
        var changed = original; changed.anchorCount += 1
        XCTAssertThrowsError(try SequenceDetector(manifest: scope, token: token, configuration: changed))
    }
}
