import XCTest
import Foundation
import RAWMasterCore
@testable import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequenceCaptureEventTests: XCTestCase {
    struct Fixture {
        let manifest: SequenceInputManifest
        let metadata: SequenceMetadataSnapshot
        let files: [SequenceCaptureFileInput]
    }
    func feature(color: Float = 0, luma: Float = 0, hash: UInt64 = 0, informative: Bool = true) throws -> SequenceFrameFeature {
        var histogram = [Float](repeating: 0, count: 48)
        for channel in 0..<3 { histogram[channel * 16] = 1-color; histogram[channel * 16+15] = color }
        return try SequenceFrameFeature(width: 32, height: 32,
            normalizedLuminance: (0..<1024).map { ($0.isMultiple(of: 2) ? -1 : 1) + luma },
            colorHistogram: histogram, differenceHash: hash, mean: 0.5, standardDeviation: informative ? 0.2 : 0)
    }
    func fixture(_ times: [Double], formats: [SequenceOriginalFormat]? = nil, counters: [Int]? = nil,
                 colors: [Float]? = nil, originalOffsets: [String?]? = nil, currentOffsets: [String?]? = nil,
                 secondsOnly: Bool = false, barriers: [Int: SequenceReason] = [:], missingFeatures: Set<Int> = [],
                 deviceValues: [String]? = nil) throws -> Fixture {
        func sha(_ text: String) throws -> String { try SequenceFingerprint.digest(text) }
        let entries = try times.indices.map { index in SequenceManifestEntry(assetID: "asset\(index)", ordinal: index,
            contentHash: try sha("current-\(index)"), barrier: barriers[index]) }
        let raw = try SequenceInputManifest(scopeID: "synthetic-scope", sessionID: "synthetic-session", orderVersion: SequenceBaseOrder.version, entries: entries)
        let manifest = try SequenceInputManifest(scopeID: raw.scopeID, sessionID: raw.sessionID, orderVersion: raw.orderVersion,
            entries: entries.map { SequenceManifestEntry(assetID: $0.assetID, ordinal: $0.ordinal, contentHash: $0.contentHash,
                camera: .manifestAssertion(id: "qualified-synthetic-source", revision: 1, manifestFingerprint: raw.contentFingerprint), barrier: $0.barrier) })
        let audit = try sha("audit"), key = try sha("key"), commonDevice = try sha("one-device")
        var facts: [SequenceMetadataFileEvidence] = [], currents: [SequenceCaptureEvidence] = []
        for index in times.indices {
            let ms = Int((times[index]*1000).rounded()), second = ms/1000
            let date = String(format: "2026:10:02 %02d:%02d:%02d", second/3600, (second/60)%60, second%60)
            let sub = secondsOnly ? nil : String(format: "%03d", ms%1000)
            let originalHash = try sha("original-\(index)")
            let originalTime = SequenceTimestampParser.parse(original: date, subseconds: sub, offset: originalOffsets?[index] ?? nil)
            let currentTime = SequenceTimestampParser.parse(original: date, subseconds: sub, offset: currentOffsets?[index] ?? nil)
            let original = SequenceCaptureEvidence(assetID: "asset\(index)", contentHash: originalHash,
                extractorVersion: SequenceMetadataEvidenceLoader.originalExtractor, evidenceRevision: 1,
                time: originalTime, cameraMake: "SONY", cameraModel: "synthetic-model", exposureSeconds: 0.01)
            currents.append(SequenceCaptureEvidence(assetID: "asset\(index)", contentHash: entries[index].contentHash!,
                extractorVersion: SequenceCaptureReader.extractorVersion, time: currentTime,
                cameraMake: "SONY", cameraModel: "synthetic-model", exposureSeconds: 0.01))
            var numbers = ["exif.ExposureTime":"0.01", "exif.ISO":"200", "exif.FNumber":"2.8", "exif.FocalLength":"50", "exif.ExposureProgram":"2"]
            if let counters {
                numbers["sony.ReleaseMode"] = "2"; numbers["sony.SequenceNumber"] = String(counters[index])
                numbers["sony.SequenceImageNumber"] = String(counters[index])
            }
            var states = numbers.mapValues { _ in SequenceMetadataFieldState.present }
            states["exif.SerialNumber"] = .present
            facts.append(SequenceMetadataFileEvidence(assetID: "asset\(index)", currentSHA256: entries[index].contentHash!,
                originalSHA256: originalHash, auditSeal: audit, keyID: key, originalFormat: formats?[index] ?? .arw,
                originalCapture: original, fieldStates: states, resolvedNumbers: numbers,
                opaqueCandidates: ["exif.SerialNumber": deviceValues?[index] ?? commonDevice]))
        }
        let metadata = SequenceMetadataSnapshot(auditSeal: audit, fingerprint: try sha("curated-"+String(times.count)),
            v1IndexSHA256: try sha("v1"), caseManifestSHA256: try sha("case"), files: facts)
        let files = try times.indices.map { index in SequenceCaptureFileInput(entry: manifest.entries[index], currentEvidence: currents[index],
            metadata: facts[index], contentVersion: 0, feature: missingFeatures.contains(index) ? nil : try feature(color: colors?[index] ?? 0)) }
        return Fixture(manifest: manifest, metadata: metadata, files: files)
    }
    func map(_ fixture: Fixture, _ policy: SequenceAssociationPolicy = .strict, confirmed: [SequenceConfirmedCapturePair] = []) throws -> SequenceCaptureEventMap {
        try SequenceCaptureEvents.make(files: fixture.files, manifest: fixture.manifest, metadata: fixture.metadata, confirmedPairs: confirmed, policy: policy)
    }
    func run(_ fixture: Fixture, _ rescue: SequenceMetadataRescuePolicy = .continuationOnly,
             association: SequenceAssociationPolicy = .strict, confirmed: [SequenceConfirmedCapturePair] = []) throws -> SequenceMetadataEventAnalysis {
        try SequenceMetadataEventPipeline.analyze(files: fixture.files, manifest: fixture.manifest, metadata: fixture.metadata,
            confirmedPairs: confirmed, associationPolicy: association, rescuePolicy: rescue)
    }
    func testProposalsAreNotConfirmationsAndKeepEveryFileIdentity() throws {
        let input = try fixture([0,0,5,5], formats: [.dng,.jpeg,.dng,.jpeg], secondsOnly: true)
        let strict = try map(input), assumed = try map(input, .assumeCorroborated)
        XCTAssertEqual(strict.events.count, 4); XCTAssertEqual(strict.proposals.count, 2)
        XCTAssertFalse(strict.associationHypothesisAssumed)
        XCTAssertEqual(assumed.events.count, 2); XCTAssertEqual(assumed.fileToEvent, [0,0,1,1])
        XCTAssertTrue(assumed.associationHypothesisAssumed)
        XCTAssertEqual(assumed.events.flatMap(\.members).map(\.assetID), input.manifest.entries.map(\.assetID))
        XCTAssertEqual(assumed.events.map(\.representativeAssetID), ["asset0","asset2"])
        XCTAssertTrue(assumed.events.allSatisfy { $0.basis == .assumed })
    }
    func testSameSecondAmbiguityAndSameFormatNeverPickAWinningPair() throws {
        let ambiguous = try fixture([0,0,0,0], formats: [.dng,.jpeg,.dng,.jpeg], secondsOnly: true)
        XCTAssertTrue(try map(ambiguous, .assumeCorroborated).proposals.isEmpty)
        XCTAssertEqual(try map(ambiguous, .assumeCorroborated).events.count, 4)
        let sameFormat = try fixture([0,0], formats: [.dng,.dng], secondsOnly: true)
        XCTAssertTrue(try map(sameFormat).proposals.isEmpty)
    }
    func testDeviceContradictionAndReadProtectionCannotBeLaunderedByPairing() throws {
        let values = [try SequenceFingerprint.digest("device1"), try SequenceFingerprint.digest("device2")]
        XCTAssertThrowsError(try map(fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true, deviceValues: values), .assumeCorroborated))
        for barrier in [SequenceReason.protectedRange, .unreadable, .incomplete] {
            let input = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true, barriers: [1:barrier])
            XCTAssertTrue(try map(input, .assumeCorroborated).proposals.isEmpty)
            XCTAssertEqual(try map(input, .assumeCorroborated).events.count, 2)
        }
        let noPreview = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true, missingFeatures: [1])
        XCTAssertTrue(try map(noPreview, .assumeCorroborated).proposals.isEmpty)
    }
    func testProtectedFilesRetainTransientReadCoverageAcrossFullProjection() throws {
        let input = try fixture([0,0.1,0.2], counters: [1,2,3], barriers: [1:.protectedRange])
        for (failure, state) in [(SequenceReason.unreadable, SequenceCoverageState.unreadable),
                                 (.incomplete, .incomplete), (.missingEmbeddedPreview, .unreadable)] {
            var files = input.files
            let file = files[1]
            files[1] = SequenceCaptureFileInput(entry: file.entry, currentEvidence: file.currentEvidence,
                metadata: file.metadata, contentVersion: file.contentVersion, feature: file.feature, readBarrier: failure)
            let changed = Fixture(manifest: input.manifest, metadata: input.metadata, files: files)
            let analysis = try run(changed)
            let coveredOrdinals = analysis.result.coverage.flatMap { Array($0.range.first...$0.range.last) }
            XCTAssertEqual(coveredOrdinals, [0,1,2])
            let coverage = try XCTUnwrap(analysis.result.coverage.first { $0.range.first <= 1 && $0.range.last >= 1 })
            XCTAssertEqual(coverage.state, state)
            XCTAssertTrue(coverage.reasons.contains(failure))
            XCTAssertEqual(analysis.observations[1].entry.barrier, .protectedRange)
            XCTAssertEqual(analysis.observations[1].barrier, failure)
            XCTAssertFalse(analysis.result.ranges.contains { $0.range.first <= 1 && $0.range.last >= 1 })
            try analysis.result.validate(manifest: input.manifest, expectedToken: analysis.result.token,
                observations: analysis.observations)
        }
    }

    func testConfirmedMapRequiresCompleteCurrentScopeAndRevisionBindings() throws {
        let input = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true)
        let scope = try SequenceCaptureEvents.scopeSnapshotFingerprint(files: input.files, manifest: input.manifest, metadata: input.metadata)
        let confirmation = SequenceConfirmedCapturePair(captureID: "actual-user-confirmation", confirmationSource: "synthetic-user-action",
            scopeSnapshotFingerprint: scope, confirmationRevision: 3, members: input.files.map(\.member))
        let confirmed = try map(input, confirmed: [confirmation])
        XCTAssertEqual(confirmed.events.count, 1); XCTAssertEqual(confirmed.events[0].basis, .confirmed)
        XCTAssertFalse(confirmed.associationHypothesisAssumed)
        let stale = SequenceConfirmedCapturePair(captureID: confirmation.captureID, confirmationSource: confirmation.confirmationSource,
            scopeSnapshotFingerprint: String(repeating: "f", count: 64), confirmationRevision: 3, members: confirmation.members)
        XCTAssertThrowsError(try map(input, confirmed: [stale]))
        let bad = SequenceCaptureMember(assetID: input.files[0].member.assetID, currentSHA256: input.files[0].member.currentSHA256,
            originalSHA256: input.files[0].member.originalSHA256, ordinal: 0, contentVersion: 1)
        let versionChanged = SequenceConfirmedCapturePair(captureID: confirmation.captureID, confirmationSource: confirmation.confirmationSource,
            scopeSnapshotFingerprint: scope, confirmationRevision: 3, members: [bad,input.files[1].member])
        XCTAssertThrowsError(try map(input, confirmed: [versionChanged]))
        XCTAssertThrowsError(try map(input, confirmed: [confirmation,confirmation]))
    }
    func testDecodedForgedMapDoesNotAcquireAuthority() throws {
        let input = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true)
        let correct = try map(input)
        let forged = SequenceCaptureEventMap(events: correct.events, fileToEvent: [0,0], proposals: correct.proposals,
            fingerprint: correct.fingerprint, scopeSnapshotFingerprint: correct.scopeSnapshotFingerprint, associationHypothesisAssumed: false)
        let decoded = try JSONDecoder().decode(SequenceCaptureEventMap.self, from: JSONEncoder().encode(forged))
        XCTAssertThrowsError(try decoded.validate(files: input.files, manifest: input.manifest, metadata: input.metadata, confirmedPairs: [], policy: .strict))
    }
    func testConditionalIntervalProjectionRetainsDuplicateFilesAndRealTimes() throws {
        let input = try fixture([0,0,5,5,10,10,15,15,20,20], formats: [.dng,.jpeg,.dng,.jpeg,.dng,.jpeg,.dng,.jpeg,.dng,.jpeg], secondsOnly: true)
        let strict = try run(input)
        XCTAssertEqual(strict.map.events.count, 10)
        XCTAssertTrue(strict.observations.contains { $0.barrier == .ambiguous })
        let assumed = try run(input, association: .assumeCorroborated)
        XCTAssertEqual(assumed.map.events.count, 5); XCTAssertTrue(assumed.associationHypothesisAssumed)
        XCTAssertEqual(assumed.result.ranges.map(\.kind), [.interval])
        XCTAssertEqual(assumed.result.ranges.first?.range, try SequenceOrdinalRange(first: 0, last: 9))
        XCTAssertEqual(assumed.observations.map(\.evidence), input.files.map(\.currentEvidence))
        try assumed.result.validate(manifest: input.manifest, expectedToken: assumed.result.token, observations: assumed.observations)
    }
    func testOriginalOffsetStaysSupplementAndOffsetChangesRemainBarriers() throws {
        let input = try fixture([0,0.1,0.2], counters: [1,2,3], originalOffsets: ["+08:00","+08:00","+08:00"])
        let analysis = try run(input)
        XCTAssertTrue(analysis.observations.allSatisfy { $0.evidence?.time.offsetRaw == nil && $0.evidence?.time.utcInstant == nil })
        let changed = try fixture([0,0.1,0.2,0.3], counters: [1,2,3,4], originalOffsets: ["+08:00","+08:00","+09:00","+09:00"])
        let split = try run(changed)
        XCTAssertTrue(split.observations.contains { $0.barrier == .invalidClockPartition })
        XCTAssertFalse(split.result.ranges.contains { $0.range.count == 4 })
    }
    func testMetadataAAndBOnlyRescueBoundedHistogramFailure() throws {
        let restart = try fixture([0,0.451], counters: [45,1], colors: [0,0.25])
        XCTAssertTrue(try run(restart).result.ranges.isEmpty)
        let rescued = try run(restart, .allowShortRestart)
        XCTAssertEqual(rescued.result.ranges.first?.range.count, 2)
        XCTAssertEqual(rescued.metadataStatistics?.shortRestartRescues, 1)
        let continuation = try fixture([0,0.1], counters: [4,5], colors: [0,0.25])
        XCTAssertEqual(try run(continuation).metadataStatistics?.continuationRescues, 1)
        let equal = try fixture([0,0.1], counters: [4,4], colors: [0,0.25])
        XCTAssertTrue(try run(equal, .allowShortRestart).result.ranges.isEmpty)
        let jump = try fixture([0,0.1], counters: [4,9], colors: [0,0.25])
        XCTAssertTrue(try run(jump, .allowShortRestart).result.ranges.isEmpty)
        let longGap = try fixture([0,4.506], counters: [11,3], colors: [0,0.25])
        XCTAssertTrue(try run(longGap, .allowShortRestart).result.ranges.isEmpty)
        let cap = try fixture([0,0.1], counters: [4,1], colors: [0,0.5])
        XCTAssertTrue(try run(cap, .allowShortRestart).result.ranges.isEmpty)
    }
    func replacingFeature(_ input: Fixture, at index: Int, feature: SequenceFrameFeature) -> Fixture {
        let files = input.files.enumerated().map { ordinal, file in SequenceCaptureFileInput(entry: file.entry,
            currentEvidence: file.currentEvidence, metadata: file.metadata, contentVersion: file.contentVersion,
            feature: ordinal == index ? feature : file.feature, readBarrier: file.readBarrier) }
        return Fixture(manifest: input.manifest, metadata: input.metadata, files: files)
    }
    func testMetadataCannotRescueLumaHashTextureOrGlobalAnchorFailures() throws {
        let input = try fixture([0,0.1], counters: [8,1], colors: [0,0.25])
        for altered in [try feature(color: 0.25, luma: 2), try feature(color: 0.25, hash: .max), try feature(color: 0.25, informative: false)] {
            let changed = replacingFeature(input, at: 1, feature: altered)
            XCTAssertTrue(try run(changed, .allowShortRestart).result.ranges.isEmpty)
        }
        let drift = try fixture([0,0.1,0.2,0.3], counters: [1,2,3,4], colors: [0,0.15,0.30,0.45])
        XCTAssertFalse(try run(drift, .allowShortRestart).result.ranges.contains { $0.range.count == 4 })
        let absent = try fixture([0,0.1], colors: [0,0.25])
        XCTAssertTrue(try run(absent, .allowShortRestart).result.ranges.isEmpty)
    }
    func testOriginalToCurrentExposureUsesExistingRoundtripTolerance() throws {
        let input = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true)
        func exposure(_ value: Double) -> Fixture {
            let file = input.files[1], old = file.currentEvidence!
            let changed = SequenceCaptureEvidence(assetID: old.assetID, contentHash: old.contentHash, extractorVersion: old.extractorVersion,
                evidenceRevision: old.evidenceRevision, time: old.time, cameraMake: old.cameraMake, cameraModel: old.cameraModel,
                exposureSeconds: value, orientation: old.orientation)
            var files = input.files
            files[1] = SequenceCaptureFileInput(entry: file.entry, currentEvidence: changed, metadata: file.metadata,
                contentVersion: file.contentVersion, feature: file.feature)
            return Fixture(manifest: input.manifest, metadata: input.metadata, files: files)
        }
        XCTAssertEqual(try map(exposure(0.01 + 0.5e-8)).proposals.count, 1)
        XCTAssertTrue(try map(exposure(0.0101)).proposals.isEmpty)
    }
    func testLegacySuccessfulEdgesAreNotSplitByCounterResets() throws {
        let input = try fixture([0,0.1,0.2], counters: [5,1,8])
        for policy in [SequenceMetadataRescuePolicy.continuationOnly, .allowShortRestart] {
            XCTAssertEqual(try run(input, policy).result.ranges.first?.range.count, 3)
            XCTAssertEqual(try run(input, policy).metadataStatistics?.rescueCandidates, 0)
        }
    }
    func testProjectionCannotSplitARepresentationEventOrAlterInputTime() throws {
        let input = try fixture([0,0,5,5,10,10,15,15], formats: [.dng,.jpeg,.dng,.jpeg,.dng,.jpeg,.dng,.jpeg], secondsOnly: true)
        let analysis = try run(input, association: .assumeCorroborated)
        let first = try XCTUnwrap(analysis.result.ranges.first)
        let split = SequenceDetectedRange(range: try SequenceOrdinalRange(first: 1, last: 7), kind: first.kind,
            cameraPartitionID: first.cameraPartitionID, clockPartitionID: first.clockPartitionID)
        let result = SequenceAnalysisResult(token: analysis.result.token, ranges: [split], coverage: analysis.result.coverage)
        XCTAssertThrowsError(try SequenceMetadataEventPipeline.validateProjection(result: result, observations: analysis.observations,
            featuresAvailable: analysis.featuresAvailable, files: input.files, manifest: input.manifest, metadata: input.metadata,
            map: analysis.map, configuration: analysis.configuration, confirmedPairs: []))
    }
    func replacingMetadata(_ input: Fixture, at index: Int, keyID: String? = nil,
                           format: SequenceOriginalFormat? = nil, numbers: [String:String]? = nil) -> Fixture {
        let old = input.metadata.files[index]
        let changed = SequenceMetadataFileEvidence(assetID: old.assetID, currentSHA256: old.currentSHA256,
            originalSHA256: old.originalSHA256, auditSeal: old.auditSeal, keyID: keyID ?? old.keyID,
            originalFormat: format ?? old.originalFormat, originalCapture: old.originalCapture,
            fieldStates: old.fieldStates, resolvedNumbers: numbers ?? old.resolvedNumbers, opaqueCandidates: old.opaqueCandidates)
        var facts = input.metadata.files; facts[index] = changed
        let metadata = SequenceMetadataSnapshot(auditSeal: input.metadata.auditSeal, fingerprint: input.metadata.fingerprint,
            v1IndexSHA256: input.metadata.v1IndexSHA256, caseManifestSHA256: input.metadata.caseManifestSHA256, files: facts)
        let files = input.files.enumerated().map { ordinal, file in SequenceCaptureFileInput(entry: file.entry,
            currentEvidence: file.currentEvidence, metadata: facts[ordinal], contentVersion: file.contentVersion,
            feature: file.feature, readBarrier: file.readBarrier) }
        return Fixture(manifest: input.manifest, metadata: metadata, files: files)
    }
    func testPublicSnapshotRejectsMixedKeyDomainAndUnknownNativeFormat() throws {
        let input = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true)
        XCTAssertThrowsError(try map(replacingMetadata(input, at: 1, keyID: String(repeating: "d", count: 64))))
        XCTAssertThrowsError(try map(replacingMetadata(input, at: 1, format: .unknown)))
    }
    func testOriginalSettingsCannotBecomeEqualByDecimalRounding() throws {
        let input = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true)
        let first = "1." + String(repeating: "0", count: 38) + "1"
        let second = "1." + String(repeating: "0", count: 38) + "2"
        XCTAssertNil(SequenceCaptureEvents.decimal(first))
        XCTAssertNil(SequenceCaptureEvents.decimal(second))
        var a = input.metadata.files[0].resolvedNumbers, b = input.metadata.files[1].resolvedNumbers
        a["exif.FNumber"] = first; b["exif.FNumber"] = second
        let changed = replacingMetadata(replacingMetadata(input, at: 0, numbers: a), at: 1, numbers: b)
        XCTAssertTrue(try map(changed).proposals.isEmpty)
        XCTAssertEqual(changed.metadata.files[0].resolvedNumbers["exif.FNumber"], first)
        XCTAssertEqual(changed.metadata.files[1].resolvedNumbers["exif.FNumber"], second)
        XCTAssertNotNil(SequenceCaptureEvents.decimal("12345678901234567890123456789012345678"))
        XCTAssertNil(SequenceCaptureEvents.decimal("1e-999"))
        a["exif.FNumber"] = "2.8000"; b["exif.FNumber"] = "28e-1"
        XCTAssertEqual(try map(replacingMetadata(replacingMetadata(input, at: 0, numbers: a), at: 1, numbers: b)).proposals.count, 1)
    }

    func testMapBindsActualMetadataEvenWhenClaimedSidecarFingerprintIsUnchanged() throws {
        let input = try fixture([0,0], formats: [.dng,.jpeg], secondsOnly: true)
        let original = try map(input)
        var numbers = input.metadata.files[0].resolvedNumbers
        numbers["exif.ISO"] = "400"
        let changed = replacingMetadata(input, at: 0, numbers: numbers)
        XCTAssertEqual(changed.metadata.fingerprint, input.metadata.fingerprint)
        XCTAssertThrowsError(try original.validate(files: changed.files, manifest: changed.manifest, metadata: changed.metadata,
            confirmedPairs: [], policy: .strict))
    }
    func testStrictMetadataAdapterSharesLegacyMetricBodyAndRejectsWrongMap() throws {
        let input = try fixture([0,0.1,0.2], counters: [1,2,3])
        let candidate = try run(input)
        let stampURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("synthetic-stamp".utf8).write(to: stampURL)
        defer { try? FileManager.default.removeItem(at: stampURL) }
        let stamp = ProbeStamp(try SequenceFileCredential.capture(at: stampURL))
        let sources = input.manifest.entries.map { entry -> ProbeSourceRecord in
            var value = ProbeSourceRecord(assetID: entry.assetID, relativePath: "synthetic-\(entry.ordinal).bin")
            value.beforeSHA256 = entry.contentHash; value.afterSHA256 = entry.contentHash
            value.before = stamp; value.after = stamp
            return value
        }
        func analysis(_ result: SequenceAnalysisResult, observations: [SequenceAssetInput]) -> ProbeAnalysis {
            ProbeAnalysis(manifest: input.manifest, result: result, observations: observations, featuresAvailable: [true,true,true],
                sources: sources, hashBeforeSeconds: 0, readerAndEngineSeconds: 0, hashAfterSeconds: 0,
                analysisSeconds: 0, engineManagedPeakEstimateBytes: 0, processPeakResidentBytes: nil)
        }
        func policy(_ configuration: SequenceDetectorConfiguration) -> ProbePolicy {
            ProbePolicy(schemaVersion: 2, detector: configuration,
                sourceAssertion: ProbeSourceAssertion(id: "qualified-synthetic-source", revision: 1, declaredByUser: true, provenance: "synthetic whole scope"),
                acceptance: ProbeAcceptance(minimumPositivePairs: 2, minimumRecall: 0.95, minimumTypedCoverage: 0.8,
                    minimumExactGroupFraction: 1, minimumPrecision: 0.95, minimumNegativePairs: 1), maximumDurationSeconds: 10, deterministicSeed: 0)
        }
        let base = SequenceDetectorConfiguration()
        let baseToken = try SequenceAnalysisToken.make(manifest: input.manifest, versions: base.versions(order: input.manifest.orderVersion), policyFingerprint: base.fingerprint)
        var detector = try SequenceDetector(manifest: input.manifest, token: baseToken, configuration: base)
        var prepare = SequenceObservationPreprocessor(manifest: input.manifest)
        var observations: [SequenceAssetInput] = []
        for file in input.files {
            let observation = prepare.make(entry: file.entry, evidence: file.currentEvidence, feature: file.feature)
            observations.append(observation.input); try detector.consume(observation)
        }
        let old = try analysis(detector.finish(), observations: observations)
        let current = analysis(candidate.result, observations: candidate.observations)
        let labels = ProbeLabels(schemaVersion: 1, role: "synthetic", groups: [.init(id: "truth", kind: .burst, assetIDs: input.manifest.entries.map(\.assetID))], negativePairs: [])
        let originalMetrics = try ProbeEvaluator.evaluate(old, labels: labels, policy: policy(base))
        let candidateMetrics = try ProbeEvaluator.evaluateMetadata(analysis: current, labels: labels, policy: policy(candidate.configuration),
            configuration: candidate.configuration.metadataExperiment!, files: input.files, map: candidate.map,
            metadata: input.metadata, confirmedPairs: [])
        XCTAssertEqual(candidateMetrics.truePositive, originalMetrics.truePositive)
        XCTAssertEqual(candidateMetrics.falseNegative, originalMetrics.falseNegative)
        XCTAssertEqual(candidateMetrics.falsePositive, originalMetrics.falsePositive)
        XCTAssertEqual(candidateMetrics.exactGroupFraction, originalMetrics.exactGroupFraction)
        XCTAssertEqual(candidateMetrics.typedCoverage, originalMetrics.typedCoverage)
        XCTAssertEqual(candidateMetrics.failures, originalMetrics.failures)
        let wrongMap = try map(input, .assumeCorroborated)
        XCTAssertThrowsError(try ProbeEvaluator.evaluateMetadata(analysis: current, labels: labels, policy: policy(candidate.configuration),
            configuration: candidate.configuration.metadataExperiment!, files: input.files, map: wrongMap,
            metadata: input.metadata, confirmedPairs: []))
    }
    func testCancellationDoesNotReturnPartialSuccess() throws {
        let input = try fixture([0,0.1,0.2], counters: [1,2,3])
        XCTAssertThrowsError(try SequenceCaptureEvents.make(files: input.files, manifest: input.manifest,
            metadata: input.metadata, confirmedPairs: [], policy: .strict, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try SequenceMetadataEventPipeline.analyze(files: input.files, manifest: input.manifest, metadata: input.metadata,
            associationPolicy: .strict, rescuePolicy: .continuationOnly, cancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
}
