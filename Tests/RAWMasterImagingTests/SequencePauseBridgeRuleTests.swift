import XCTest
import Foundation
import RAWMasterCore
@testable import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequencePauseBridgeRuleTests: XCTestCase {
    struct Fixture {
        let manifest: SequenceInputManifest
        let metadata: SequenceMetadataSnapshot
        let files: [SequenceCaptureFileInput]
        let focus: SequenceFocusSnapshot
    }
    func sha(_ text: String) throws -> String { try SequenceFingerprint.digest(text) }
    func feature(right: Bool = false) throws -> SequenceFrameFeature {
        let color: Float = right ? 0.1 : 0
        var histogram = [Float](repeating: 0, count: 48)
        for channel in 0..<3 { histogram[channel * 16] = 1 - color; histogram[channel * 16 + 15] = color }
        return try SequenceFrameFeature(width: 32, height: 32,
            normalizedLuminance: (0..<1024).map { ($0.isMultiple(of: 2) ? -1 : 1) + (right ? 0.5 : 0) },
            colorHistogram: histogram, differenceHash: right ? 65535 : 0, mean: 0.5, standardDeviation: 0.2)
    }
    func fixture(times: [Double] = [0, 0.05, 0.1, 2, 2.05, 2.1], counters: [Int] = [1, 2, 3, 1, 2, 3],
                 outside: Bool = false, barriers: [Int: SequenceReason] = [:], setting: (Int, String, String)? = nil) throws -> Fixture {
        let entries = try times.indices.map { SequenceManifestEntry(assetID: "asset\($0)", ordinal: $0,
            contentHash: try sha("current-\($0)"), barrier: barriers[$0]) }
        let raw = try SequenceInputManifest(scopeID: "focus-test", sessionID: "session", orderVersion: SequenceBaseOrder.version, entries: entries)
        let manifest = try SequenceInputManifest(scopeID: raw.scopeID, sessionID: raw.sessionID, orderVersion: raw.orderVersion,
            entries: entries.map { SequenceManifestEntry(assetID: $0.assetID, ordinal: $0.ordinal, contentHash: $0.contentHash,
                camera: .manifestAssertion(id: "test-source", revision: 1, manifestFingerprint: raw.contentFingerprint), barrier: $0.barrier) })
        var files: [SequenceCaptureFileInput] = [], facts: [SequenceMetadataFileEvidence] = [], focusFiles: [SequenceFocusFileEvidence] = []
        let audit = try sha("old-audit"), key = try sha("key")
        for index in times.indices {
            let ms = Int((times[index] * 1000).rounded()), second = ms / 1000
            let date = String(format: "2026:10:02 %02d:%02d:%02d", second / 3600, (second / 60) % 60, second % 60)
            let time = SequenceTimestampParser.parse(original: date, subseconds: String(format: "%03d", ms % 1000), offset: "+08:00")
            let originalHash = try sha("original-\(index)")
            let original = SequenceCaptureEvidence(assetID: entries[index].assetID, contentHash: originalHash,
                extractorVersion: SequenceMetadataEvidenceLoader.originalExtractor, evidenceRevision: 1,
                time: time, cameraMake: "SONY", cameraModel: "ILCE-1M2", exposureSeconds: 0.01, orientation: 1)
            let current = SequenceCaptureEvidence(assetID: entries[index].assetID, contentHash: entries[index].contentHash!,
                extractorVersion: SequenceCaptureReader.extractorVersion, time: time,
                cameraMake: "SONY", cameraModel: "ILCE-1M2", exposureSeconds: 0.01, orientation: 1)
            var numbers = ["exif.ExposureTime": "0.01", "exif.ISO": "100", "exif.FNumber": "2.8", "exif.FocalLength": "50",
                "exif.ExposureProgram": "4", "exif.Orientation": "1", "exif.ExifImageWidth": "1000", "exif.ExifImageHeight": "800",
                "sony.ReleaseMode": "2", "sony.SequenceNumber": String(counters[index]), "sony.SequenceImageNumber": String(counters[index])]
            if let setting, setting.0 == index { numbers[setting.1] = setting.2 }
            let metadata = SequenceMetadataFileEvidence(assetID: entries[index].assetID, currentSHA256: entries[index].contentHash!,
                originalSHA256: originalHash, auditSeal: audit, keyID: key, originalFormat: .arw, originalCapture: original,
                fieldStates: numbers.mapValues { _ in .present }, resolvedNumbers: numbers, opaqueCandidates: [:])
            facts.append(metadata)
            files.append(SequenceCaptureFileInput(entry: manifest.entries[index], currentEvidence: current,
                metadata: metadata, contentVersion: 0, feature: try feature(right: index >= 3)))
            var states = Dictionary(uniqueKeysWithValues: SequenceFocusSnapshot.allFields.map { ($0, SequenceMetadataFieldState.present) })
            states["exif.SubjectDistance"] = .absent
            let x = index < 3 ? 200 : 700
            focusFiles.append(SequenceFocusFileEvidence(assetID: entries[index].assetID, currentSHA256: entries[index].contentHash!,
                originalSHA256: originalHash, ordinal: index, state: outside ? .outsideAuditedCohort : .audited,
                fieldStates: outside ? [:] : states,
                resolvedCodes: outside ? [:] : ["sony.FocusMode": 3, "sony.AFAreaModeSetting": 0, "sony.AFAreaMode": 0,
                    "sony.AFPointSelected": 0, "sony.AFTracking": 2, "sony.FocusPosition2": 100, "sony.CameraOrientation": 1],
                resolvedTuples: outside ? [:] : ["sony.FocusLocation": [1000, 800, x, 200], "sony.FocusLocation2": [1000, 800, x, 200],
                    "sony.FocusFrameSize": [80, 60, 257], "sony.FlexibleSpotPosition": [0, 0]]))
        }
        let metadata = SequenceMetadataSnapshot(auditSeal: audit, fingerprint: try sha("old-metadata"),
            v1IndexSHA256: try sha("v1"), caseManifestSHA256: try sha("manifest"), files: facts)
        return Fixture(manifest: manifest, metadata: metadata, files: files,
            focus: SequenceFocusSnapshot(focusAuditSeal: try sha("focus-audit"), fingerprint: try sha("focus-case-bytes"),
                metadataSnapshotFingerprint: metadata.fingerprint, files: focusFiles))
    }
    func changed(_ input: Fixture, index: Int, codes: [String: Int] = [:], tuples: [String: [Int]] = [:],
                 states: [String: SequenceMetadataFieldState] = [:], removeState: String? = nil) -> Fixture {
        var files = input.focus.files
        let old = files[index]
        var fieldStates = old.fieldStates, nextCodes = old.resolvedCodes, nextTuples = old.resolvedTuples
        for (key, value) in codes { nextCodes[key] = value }
        for (key, value) in tuples { nextTuples[key] = value }
        for (key, value) in states { fieldStates[key] = value; nextCodes.removeValue(forKey: key); nextTuples.removeValue(forKey: key) }
        if let removeState { fieldStates.removeValue(forKey: removeState); nextCodes.removeValue(forKey: removeState); nextTuples.removeValue(forKey: removeState) }
        files[index] = SequenceFocusFileEvidence(assetID: old.assetID, currentSHA256: old.currentSHA256, originalSHA256: old.originalSHA256,
            ordinal: old.ordinal, state: old.state, fieldStates: fieldStates, resolvedCodes: nextCodes, resolvedTuples: nextTuples)
        return Fixture(manifest: input.manifest, metadata: input.metadata, files: input.files,
            focus: SequenceFocusSnapshot(focusAuditSeal: input.focus.focusAuditSeal, fingerprint: input.focus.fingerprint,
                metadataSnapshotFingerprint: input.focus.metadataSnapshotFingerprint, files: files))
    }
    func contexts(_ input: Fixture) throws -> [SequencePauseBridgeContext] {
        let digest = try input.focus.boundFingerprint(manifest: input.manifest, metadata: input.metadata)
        return input.files.indices.map { SequencePauseBridgeContext.make(file: input.files[$0], focus: input.focus.files[$0],
            focusAuditSeal: input.focus.focusAuditSeal, scopeFingerprint: digest, manifest: input.manifest) }
    }
    func decision(_ input: Fixture, cancelled: () -> Bool = { false }) throws -> SequencePauseBridgeEvidence {
        let values = try contexts(input)
        return try SequencePauseBridgeRule.decide(leftFeatures: Array(input.files.prefix(3)).map { $0.feature! },
            rightFeatures: Array(input.files.suffix(3)).map { $0.feature! }, leftContexts: values.prefix(3).map { Optional($0) },
            rightContexts: values.suffix(3).map { Optional($0) }, denseGapSeconds: 0.6, maximumBridgeSeconds: 12, cancelled: cancelled)
    }
    func run(_ input: Fixture, focus: Bool = true, base: SequenceDetectorConfiguration = .init(),
             cancelled: () -> Bool = { false }) throws -> SequenceMetadataEventAnalysis {
        try SequenceMetadataEventPipeline.analyze(files: input.files, manifest: input.manifest, metadata: input.metadata,
            associationPolicy: .strict, rescuePolicy: .allowShortRestart, baseConfiguration: base,
            focusSnapshot: focus ? input.focus : nil, pauseBridgePolicy: focus ? .focusRectAndCohortSeparation : nil, cancelled: cancelled)
    }
    func testJointEvidenceVetoesOnlyAfterLegacyAcceptanceAndKeepsAllFiles() throws {
        let input = try fixture(), legacy = try run(input, focus: false), candidate = try run(input)
        XCTAssertEqual(legacy.result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 5)])
        XCTAssertEqual(candidate.result.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 2), try SequenceOrdinalRange(first: 3, last: 5)])
        XCTAssertEqual(candidate.result.coverage.map { $0.range.count }.reduce(0, +), 6)
        XCTAssertEqual(candidate.pauseBridgeStatistics?.bridgeCandidates, 1)
        XCTAssertEqual(candidate.pauseBridgeStatistics?.vetoes, 1)
        XCTAssertEqual(candidate.metadataStatistics, legacy.metadataStatistics)
        XCTAssertEqual(candidate.map, legacy.map)
        XCTAssertNil(legacy.pauseBridgeStatistics)
        XCTAssertEqual(try decision(input).verdict, .vetoed)
    }
    func testFocusJumpWithoutAllAppearanceMetricsDoesNotVeto() throws {
        let input = try fixture()
        let c = try contexts(input), same = try feature()
        let result = try SequencePauseBridgeRule.decide(leftFeatures: [same, same, same], rightFeatures: [same, same, same],
            leftContexts: c.prefix(3).map(Optional.some), rightContexts: c.suffix(3).map(Optional.some),
            denseGapSeconds: 0.6, maximumBridgeSeconds: 12, cancelled: { false })
        XCTAssertEqual(result.verdict, .retained)
        XCTAssertEqual(result.reason, .appearanceNotSeparated)
        XCTAssertTrue(result.focusGeometryPassed)
        XCTAssertFalse(result.appearanceSeparationPassed)
    }
    func testTouchingOrOverlappingFocusRectanglesRetainBridge() throws {
        var input = try fixture()
        for index in 3..<6 { input = changed(input, index: index,
            tuples: ["sony.FocusLocation": [1000, 800, 280, 200], "sony.FocusLocation2": [1000, 800, 280, 200]]) }
        XCTAssertEqual(try decision(input).crossOverlaps, 9)
        XCTAssertEqual(try decision(input).verdict, .retained)
        XCTAssertEqual(try run(input).result.ranges.count, 1)
    }
    func testNoncohesiveFocusWindowsAndUnusableRegionsPreserveLegacy() throws {
        let input = try fixture()
        let scattered = changed(input, index: 5,
            tuples: ["sony.FocusLocation": [1000, 800, 700, 600], "sony.FocusLocation2": [1000, 800, 700, 600]])
        XCTAssertEqual(try decision(scattered).reason, .focusNotCohesive)
        for tuples in [["sony.FocusLocation": [1000, 800, 500, 400], "sony.FocusLocation2": [1000, 800, 500, 400]],
                       ["sony.FocusLocation": [1000, 800, 499, 400], "sony.FocusLocation2": [1000, 800, 500, 400]],
                       ["sony.FocusLocation": [1000, 800, 20, 200], "sony.FocusLocation2": [1000, 800, 20, 200]],
                       ["sony.FocusFrameSize": [80, 60, 0]], ["sony.FocusFrameSize": [0, 60, 257]],
                       ["sony.FocusLocation2": [1001, 800, 200, 200]], ["sony.FocusLocation2": [1000, 800, 202, 200]]] {
            let altered = changed(input, index: 0, tuples: tuples)
            XCTAssertEqual(try decision(altered).verdict, .notApplicable)
            XCTAssertEqual(try run(altered).result.ranges.count, 1)
        }
    }
    func testOnePixelCrosscheckAndNonzeroAvailabilityMarkerRemainValid() throws {
        let input = try fixture()
        for delta in [-1, 1] {
            let altered = changed(input, index: 0, tuples: ["sony.FocusLocation2": [1000, 800, 200 + delta, 200],
                "sony.FocusFrameSize": [80, 60, 1]])
            XCTAssertEqual(try decision(altered).verdict, .vetoed)
        }
    }
    func testUnknownRequiredModesMissingConflictAndOutsideHaveNoNewVeto() throws {
        let input = try fixture()
        for codes in [["sony.FocusMode": 0], ["sony.FocusMode": 999], ["sony.AFTracking": 0], ["sony.AFTracking": 3], ["sony.CameraOrientation": 8]] {
            XCTAssertEqual(try decision(changed(input, index: 0, codes: codes)).verdict, .notApplicable)
        }
        for state in [SequenceMetadataFieldState.absent, .conflicting, .invalid] {
            XCTAssertEqual(try decision(changed(input, index: 0, states: ["sony.FocusLocation": state])).verdict, .notApplicable)
        }
        let outside = try fixture(outside: true)
        XCTAssertEqual(try decision(outside).verdict, .notApplicable)
        XCTAssertEqual(try run(outside).result.ranges.count, 1)
        XCTAssertTrue(outside.focus.files.allSatisfy { $0.fieldStates.isEmpty && $0.resolvedTuples.isEmpty && $0.resolvedCodes.isEmpty })
    }
    func testCounterContinuationBrokenSupportOrSettingsChangesDoNotVeto() throws {
        XCTAssertEqual(try decision(fixture(counters: [1, 2, 3, 4, 5, 6])).reason, .continuousCounter)
        XCTAssertEqual(try decision(fixture(counters: [1, 3, 4, 1, 2, 3])).reason, .counterContextUnavailable)
        for key in ["exif.ISO", "exif.FocalLength", "exif.FNumber", "exif.ExposureProgram"] {
            let input = try fixture(setting: (3, key, key == "exif.ExposureProgram" ? "5" : "200"))
            XCTAssertEqual(try decision(input).reason, .incomparableSettings)
        }
        for (key, value) in [("exif.ISO", "0"), ("exif.FocalLength", "0"), ("exif.ExposureProgram", "1.5")] {
            XCTAssertEqual(try decision(fixture(setting: (0, key, value))).reason, .incomparableSettings)
        }
    }
    func testFiniteStrictSeparationUsesNoEpsilonAndNonfiniteCannotVeto() throws {
        func distance(_ value: Float) -> SequenceFeatureDistance { .init(luminance: value, histogram: value, hash: value) }
        let within = Array(repeating: distance(0.25), count: 3)
        let equal = SequencePauseBridgeRule.gaps(cross: Array(repeating: distance(0.5), count: 9), left: within, right: within)
        XCTAssertEqual(equal, [0, 0, 0])
        let tiny = try XCTUnwrap(SequencePauseBridgeRule.gaps(cross: Array(repeating: distance(Float(0.5).nextUp), count: 9), left: within, right: within))
        XCTAssertTrue(tiny.allSatisfy { $0 > 0 && $0 < 0.000001 })
        for invalid in [Float.nan, .infinity, -.infinity, -0.1] {
            XCTAssertNil(SequencePauseBridgeRule.gaps(cross: Array(repeating: distance(invalid), count: 9), left: within, right: within))
        }
    }
    func testGapSubtractsIntegralEpochsBeforeDoubleConversionAndRejectsOverflow() throws {
        let original = try XCTUnwrap(contexts(fixture()).first)
        func timed(_ second: Int64, _ nano: Int) -> SequencePauseBridgeContext {
            SequencePauseBridgeContext(assetID: original.assetID, currentSHA256: original.currentSHA256,
                originalSHA256: original.originalSHA256, focusAuditSeal: original.focusAuditSeal, scopeFingerprint: original.scopeFingerprint,
                cameraPartitionID: original.cameraPartitionID, originalOffsetMinutes: original.originalOffsetMinutes,
                orientation: original.orientation, referenceWidth: original.referenceWidth, referenceHeight: original.referenceHeight,
                releaseMode: original.releaseMode, sequenceNumber: original.sequenceNumber, sequenceImageNumber: original.sequenceImageNumber,
                localSecond: second, nanosecond: nano, settings: original.settings, focus: original.focus)
        }
        let epoch = Int64.max - 100
        XCTAssertEqual(SequencePauseBridgeRule.gap(timed(epoch, 0), timed(epoch, 600_000_000)), 0.6)
        XCTAssertEqual(SequencePauseBridgeRule.gap(timed(epoch, 0), timed(epoch, 600_000_001)), 0.600000001)
        XCTAssertEqual(SequencePauseBridgeRule.gap(timed(epoch, 0), timed(epoch + 12, 0)), 12)
        XCTAssertEqual(try XCTUnwrap(SequencePauseBridgeRule.gap(timed(epoch, 999_999_999), timed(epoch + 1, 0))), 0.000000001, accuracy: 0.000000000000001)
        XCTAssertNil(SequencePauseBridgeRule.gap(timed(Int64.min, 0), timed(Int64.max, 0)))
    }
    func testActualSnapshotContentsInvalidateTokensEvenWithSameClaimedFingerprint() throws {
        let input = try fixture(), original = try run(input)
        let altered = changed(input, index: 0, tuples: ["sony.FocusFrameSize": [82, 60, 257]])
        XCTAssertEqual(altered.focus.fingerprint, input.focus.fingerprint)
        XCTAssertNotEqual(try altered.focus.boundFingerprint(manifest: input.manifest, metadata: input.metadata),
                          try input.focus.boundFingerprint(manifest: input.manifest, metadata: input.metadata))
        XCTAssertThrowsError(try SequenceMetadataEventPipeline.validateProjection(result: original.result, observations: original.observations,
            featuresAvailable: original.featuresAvailable, files: input.files, manifest: input.manifest, metadata: input.metadata,
            map: original.map, configuration: original.configuration, confirmedPairs: [], focusSnapshot: altered.focus))
        XCTAssertThrowsError(try SequenceMetadataEventPipeline.validateProjection(result: original.result, observations: original.observations,
            featuresAvailable: original.featuresAvailable, files: input.files, manifest: input.manifest, metadata: input.metadata,
            map: original.map, configuration: original.configuration, confirmedPairs: []))
    }
    func testSnapshotIdentityAndAuditedFieldCompletenessAreStrict() throws {
        let input = try fixture()
        XCTAssertThrowsError(try changed(input, index: 0, removeState: "sony.AFPointSelected").focus.validateBindings(manifest: input.manifest, metadata: input.metadata))
        var files = input.focus.files
        let old = files[0]
        files[0] = SequenceFocusFileEvidence(assetID: old.assetID, currentSHA256: old.currentSHA256, originalSHA256: old.originalSHA256,
            ordinal: 1, state: old.state, fieldStates: old.fieldStates, resolvedCodes: old.resolvedCodes, resolvedTuples: old.resolvedTuples)
        let bad = SequenceFocusSnapshot(focusAuditSeal: input.focus.focusAuditSeal, fingerprint: input.focus.fingerprint,
            metadataSnapshotFingerprint: input.metadata.fingerprint, files: files)
        XCTAssertThrowsError(try bad.validateBindings(manifest: input.manifest, metadata: input.metadata))
        let outside = try fixture(outside: true)
        XCTAssertThrowsError(try changed(outside, index: 0, codes: ["sony.FocusMode": 3]).focus.validateBindings(manifest: outside.manifest, metadata: outside.metadata))
    }
    func testPolicyPairingPreinjectedConfigurationAndMissingContextAreRejected() throws {
        let input = try fixture(), candidate = try run(input)
        XCTAssertThrowsError(try SequenceMetadataEventPipeline.analyze(files: input.files, manifest: input.manifest, metadata: input.metadata,
            associationPolicy: .strict, rescuePolicy: .allowShortRestart, focusSnapshot: input.focus))
        XCTAssertThrowsError(try SequenceMetadataEventPipeline.analyze(files: input.files, manifest: input.manifest, metadata: input.metadata,
            associationPolicy: .strict, rescuePolicy: .allowShortRestart, pauseBridgePolicy: .focusRectAndCohortSeparation))
        var injected = SequenceDetectorConfiguration()
        injected.pauseBridgeExperiment = candidate.configuration.pauseBridgeExperiment
        XCTAssertThrowsError(try run(input, base: injected))
        XCTAssertThrowsError(try injected.validate())
        let token = try SequenceAnalysisToken.make(manifest: candidate.eventManifest,
            versions: candidate.configuration.versions(order: candidate.eventManifest.orderVersion), policyFingerprint: candidate.configuration.fingerprint)
        var detector = try SequenceDetector(manifest: candidate.eventManifest, token: token, configuration: candidate.configuration)
        var preprocessor = SequenceObservationPreprocessor(manifest: candidate.eventManifest)
        let observed = preprocessor.make(entry: candidate.eventManifest.entries[0], evidence: input.files[0].currentEvidence,
            feature: input.files[0].feature, metadataBurstContext: SequenceMetadataBurstContext.make(file: input.files[0], snapshot: input.metadata))
        XCTAssertThrowsError(try detector.consume(observed)) { XCTAssertEqual($0 as? SequenceDetectorError, .missingPauseBridgeContext) }
    }
    func testDenseIntervalProtectionCancellationAndBudgetStayIndependent() throws {
        let dense = try fixture(times: [0, 0.05, 0.1, 0.15, 0.2, 0.25])
        XCTAssertEqual(try run(dense).result.ranges.count, 1)
        XCTAssertEqual(try run(dense).pauseBridgeStatistics?.bridgeCandidates, 0)
        let interval = try fixture(times: [0, 5, 10, 15, 20, 25])
        let oldInterval = try run(interval, focus: false), newInterval = try run(interval)
        XCTAssertEqual(newInterval.result.ranges.map(\.range), oldInterval.result.ranges.map(\.range))
        XCTAssertEqual(newInterval.result.coverage, oldInterval.result.coverage)
        XCTAssertEqual(newInterval.pauseBridgeStatistics?.bridgeCandidates, 0)
        let protected = try fixture(barriers: [3: .protectedRange])
        XCTAssertEqual(try run(protected).result.coverage, try run(protected, focus: false).result.coverage)
        XCTAssertThrowsError(try decision(fixture(), cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try run(fixture(), cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        var tiny = SequenceDetectorConfiguration(); tiny.memoryBudgetBytes = 1024
        XCTAssertThrowsError(try run(fixture(), base: tiny)) { XCTAssertEqual($0 as? SequenceDetectorError, .budgetExceeded) }
    }
    func testNilConfigurationKeepsLegacyFingerprintAndVersion() throws {
        let configuration = SequenceDetectorConfiguration()
        XCTAssertEqual(try configuration.fingerprint, "6d2d41684046f60da698eec7e19ed37c74673662fa33500db90fbdc8e7ecfcc4")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertFalse(String(decoding: try encoder.encode(configuration), as: UTF8.self).contains("pauseBridgeExperiment"))
        let input = try fixture(), old = try run(input, focus: false), new = try run(input)
        XCTAssertNil(old.configuration.pauseBridgeExperiment)
        XCTAssertNotEqual(old.result.token.versions, new.result.token.versions)
        XCTAssertNotEqual(old.result.token.policyFingerprint, new.result.token.policyFingerprint)
    }
}
