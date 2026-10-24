import XCTest
import Foundation
import CoreGraphics
import RAWMasterCore
@testable import RAWMasterImaging

private final class StartupTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SequenceTraceEvent] = []
    func append(_ event: SequenceTraceEvent) { lock.lock(); values.append(event); lock.unlock() }
    var events: [SequenceTraceEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

extension SequenceDetectorTests {
    private func startupFeature(color: Float = 0, shift: Float = 0, hash: UInt64 = 0) throws -> SequenceFrameFeature {
        let base = try feature(color)
        return try SequenceFrameFeature(width: 32, height: 32,
            normalizedLuminance: base.normalizedLuminance.map { $0 + shift }, colorHistogram: base.colorHistogram,
            differenceHash: hash, mean: base.mean, standardDeviation: base.standardDeviation)
    }
    private func startupAngle(_ angle: Float) throws -> SequenceFrameFeature {
        let base = try feature()
        let luma = (0..<1024).map { index -> Float in
            let a: Float = index.isMultiple(of: 2) ? -1 : 1
            let b: Float = (index / 2).isMultiple(of: 2) ? -1 : 1
            return cos(angle) * a + sin(angle) * b
        }
        return try SequenceFrameFeature(width: 32, height: 32, normalizedLuminance: luma,
            colorHistogram: base.colorHistogram, differenceHash: 0, mean: 0.5, standardDeviation: 0.2)
    }
    private func startupRun(_ frames: [SequenceFrameFeature], config: SequenceDetectorConfiguration = .init(), traced: Bool = true)
        throws -> (SequenceAnalysisResult, [SequenceTraceEvent]) {
        let times: [Double] = [0, 14, 19, 24, 67, 72, 77, 82]
        XCTAssertEqual(frames.count, times.count)
        let scope = try manifest(frames.count), sink = StartupTraceCollector()
        let token = try SequenceAnalysisToken.make(manifest: scope, versions: config.versions(order: scope.orderVersion), policyFingerprint: config.fingerprint)
        let observer: (@Sendable (SequenceTraceEvent) -> Void)?
        if traced { observer = { sink.append($0) } } else { observer = nil }
        var engine = try SequenceDetector(manifest: scope, token: token, configuration: config, trace: observer)
        var prepare = SequenceObservationPreprocessor(manifest: scope), observations: [SequenceAssetInput] = []
        for i in times.indices {
            let observation = prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: times[i]), feature: frames[i])
            observations.append(observation.input); try engine.consume(observation)
        }
        let result = try engine.finish()
        try result.validate(manifest: scope, expectedToken: token, observations: observations)
        XCTAssertLessThanOrEqual(engine.managedPeakEstimateBytes, config.memoryBudgetBytes)
        return (result, sink.events)
    }
    func testStartupOrdinaryAndHistogramOnlyRescueKeepMaximumAndTruthfulTrace() throws {
        let base = try feature()
        let ordinary = try startupRun([try startupFeature(color: 0.125)] + Array(repeating: base, count: 7))
        XCTAssertEqual(ordinary.0.ranges.first?.range.first, 0)
        XCTAssertTrue(ordinary.1.contains { $0.stage == .startup && $0.reason == .startupAccepted })
        let frames = [try startupFeature(color: 0.3)] + Array(repeating: base, count: 7)
        let rescued = try startupRun(frames), off = try startupRun(frames, traced: false)
        XCTAssertEqual(rescued.0, off.0)
        XCTAssertEqual(rescued.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 7)])
        let event = try XCTUnwrap(rescued.1.first { $0.stage == .startup })
        XCTAssertEqual(event.reason, .structuralRescue); XCTAssertTrue(event.accepted)
        XCTAssertEqual(event.rescueEligible, true); XCTAssertEqual(event.aggregation, .maximum)
        XCTAssertEqual(event.histogramLimit, 0.35)
        XCTAssertEqual(try XCTUnwrap(event.luminanceLimit), 0.13, accuracy: 0.000001)
        XCTAssertEqual(event.hashLimit, 0.65)
        XCTAssertEqual(event.rightRepresentative0, 4); XCTAssertEqual(event.rightRepresentative1, 5)
        XCTAssertEqual(event.rightRepresentative2, 6)
    }
    func testStartupRescueIncludesExactHistogramLuminanceAndHashBoundaries() throws {
        var c = SequenceDetectorConfiguration()
        // Binary-exact fixture limits avoid float summation ambiguity at decimal histogram bins.
        c.bridgeHistogramLimit = 0.25; c.anchorHistogramLimit = 0.375
        c.bridgeLuminanceLimit = 0.25; c.bridgeHashLimit = 0.625
        let base = try feature(), fortyBits = UInt64.max >> 24
        let colors: [Float] = [0.25, 0.3125, 0.375]
        for color in colors {
            let first = try startupFeature(color: color, shift: 0.75, hash: fortyBits)
            let result = try startupRun([first] + Array(repeating: base, count: 7), config: c)
            XCTAssertEqual(result.0.ranges.first?.range.first, 0)
            let event = try XCTUnwrap(result.1.first { $0.stage == .startup })
            XCTAssertEqual(event.luminance, 0.125); XCTAssertEqual(event.hash, 0.625)
            XCTAssertEqual(event.histogramLimit, color == 0.25 ? 0.25 : 0.375)
        }
    }
    func testStartupCannotUseOrdinaryBridgeLuminanceOrAnchorHashAllowance() throws {
        let base = try feature()
        // 0.15 is below ordinary bridge .26 but above startup's hard .13.
        let weakStructure = try startupFeature(color: 0.3, shift: 0.9)
        // 43/64 is above bridge .65 but below anchor .7; startup must still reject it.
        let excessiveHash = try startupFeature(color: 0.3, hash: UInt64.max >> 21)
        for first in [weakStructure, excessiveHash, try startupFeature(color: 0.4),
                      try startupFeature(color: 0.4, shift: 0.9, hash: .max)] {
            let result = try startupRun([first] + Array(repeating: base, count: 7))
            XCTAssertEqual(result.0.ranges.first?.range.first, 1)
            let event = try XCTUnwrap(result.1.first { $0.stage == .startup })
            XCTAssertFalse(event.accepted); XCTAssertEqual(event.reason, .structuralRescueRejected)
            XCTAssertEqual(event.histogramLimit, 0.35)
        }
    }
    func testStartupEachOfSevenComparisonsCanIndividuallyVetoTheMaximum() throws {
        // A startup edge is 0->1; the immutable stable representatives are 4,5,6.
        let pairs = [(0, 1), (0, 4), (1, 4), (0, 5), (1, 5), (0, 6), (1, 6)]
        for badPair in pairs {
            var angles = [Float](repeating: 0.5, count: 8)
            angles[badPair.0] = 0; angles[badPair.1] = 1
            let frames = try angles.map { try startupAngle($0) }
            let distances = pairs.map { frames[$0.0].distance(to: frames[$0.1]) }
            XCTAssertEqual(distances.filter { $0.luminance > 0.13 }.count, 1)
            let result = try startupRun(frames)
            XCTAssertEqual(result.0.ranges.first?.range.first, 1)
            let event = try XCTUnwrap(result.1.first { $0.stage == .startup })
            XCTAssertEqual(event.aggregation, .maximum); XCTAssertFalse(event.accepted)
            XCTAssertGreaterThan(try XCTUnwrap(event.luminance), 0.13)
        }
    }
    func testStartupAnchorRejectionPreventsARescueSuccessEvent() throws {
        var c = SequenceDetectorConfiguration(); c.anchorLuminanceLimit = 0.04
        let base = try feature(), first = try startupFeature(color: 0.3, shift: 0.36)
        let result = try startupRun([first] + Array(repeating: base, count: 7), config: c)
        XCTAssertEqual(result.0.ranges.first?.range.first, 1)
        let failureIndex = try XCTUnwrap(result.1.firstIndex { $0.stage == .anchor && !$0.accepted })
        let startupIndex = try XCTUnwrap(result.1.firstIndex { $0.stage == .startup })
        XCTAssertLessThan(failureIndex, startupIndex)
        XCTAssertEqual(result.1[startupIndex].reason, .structuralRescueRejected)
        XCTAssertEqual(result.1[startupIndex].rescueEligible, true)
        XCTAssertFalse(result.1[startupIndex].accepted)
        XCTAssertFalse(result.1.contains { $0.stage == .startup && $0.reason == .structuralRescue && $0.accepted })
    }
    private func startupPixels(subjectX: Int) throws -> SequenceFrameFeature {
        var bytes = [UInt8](repeating: 255, count: 32 * 32 * 4)
        for y in 0..<32 { for x in 0..<32 {
            let value: UInt8 = (subjectX..<(subjectX + 16)).contains(x) ? 224 : ((x + y).isMultiple(of: 2) ? 32 : 48)
            let i = (y * 32 + x) * 4
            bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try SequenceFrameFeature.extract(image)
    }
    func testStartupPixelDerivedSameBackgroundSubjectShiftAndDriftRemainRejected() throws {
        let left = try startupPixels(subjectX: 0), right = try startupPixels(subjectX: 16)
        XCTAssertLessThan(left.distance(to: right).histogram, 0.001)
        let shifted = try startupRun([left] + Array(repeating: right, count: 7))
        XCTAssertEqual(shifted.0.ranges.first?.range.first, 1)
        let gradual = try (0..<8).map { try startupPixels(subjectX: $0) }
        XCTAssertTrue(zip(gradual.dropFirst(), gradual).allSatisfy { $0.distance(to: $1).luminance < 0.13 })
        let drift = try startupRun(gradual)
        XCTAssertEqual(drift.0.ranges.first?.range.first, 1)
        XCTAssertTrue(drift.1.contains { $0.stage == .startup && !$0.accepted && $0.aggregation == .maximum })
    }
    func testStartupNonInformativeFrameCannotBeRescued() throws {
        let base = try feature(), flat = try feature(0.3, informative: false)
        let result = try startupRun([flat] + Array(repeating: base, count: 7))
        XCTAssertEqual(result.0.ranges.first?.range.first, 1)
        XCTAssertFalse(result.1.contains { $0.stage == .startup && $0.accepted })
    }
}
