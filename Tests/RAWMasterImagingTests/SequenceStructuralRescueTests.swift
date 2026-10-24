import XCTest
import CoreGraphics
import RAWMasterCore
@testable import RAWMasterImaging

private final class RescueTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SequenceTraceEvent] = []
    func append(_ value: SequenceTraceEvent) { lock.lock(); values.append(value); lock.unlock() }
    var events: [SequenceTraceEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

extension SequenceDetectorTests {
    private func adjusted(_ original: SequenceFrameFeature, angle: Float = 0, hash: UInt64 = 0,
                          color: Float = 0) throws -> SequenceFrameFeature {
        let histogram = try feature(color).colorHistogram
        let luma = (0..<1024).map { index -> Float in
            let a: Float = index.isMultiple(of: 2) ? -1 : 1
            let b: Float = (index / 2).isMultiple(of: 2) ? -1 : 1
            return cos(angle) * a + sin(angle) * b
        }
        return try SequenceFrameFeature(width: original.width, height: original.height,
            normalizedLuminance: luma, colorHistogram: histogram, differenceHash: hash,
            mean: original.mean, standardDeviation: original.standardDeviation)
    }
    private func rescueRun(_ features: [SequenceFrameFeature], times: [Double]? = nil,
                           config: SequenceDetectorConfiguration = .init(), traced: Bool = true)
        throws -> (SequenceAnalysisResult, [SequenceTraceEvent]) {
        let scope = try manifest(features.count), sink = RescueTraceCollector()
        let token = try SequenceAnalysisToken.make(manifest: scope, versions: config.versions(order: scope.orderVersion), policyFingerprint: config.fingerprint)
        let observer: (@Sendable (SequenceTraceEvent) -> Void)?
        if traced { observer = { sink.append($0) } } else { observer = nil }
        var engine = try SequenceDetector(manifest: scope, token: token, configuration: config, trace: observer)
        var prepare = SequenceObservationPreprocessor(manifest: scope), observations: [SequenceAssetInput] = []
        for i in features.indices {
            let observation = prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i],
                seconds: times?[i] ?? Double(i) * 0.05), feature: features[i])
            observations.append(observation.input); try engine.consume(observation)
        }
        let result = try engine.finish()
        try result.validate(manifest: scope, expectedToken: token, observations: observations)
        return (result, sink.events)
    }
    func testStructuralRescueOnlyRepairsSparseHashVetoWithStrongSpatialAgreement() throws {
        let a = try feature(), b = try adjusted(a, hash: UInt64.max >> 28)
        let on = try rescueRun([a, b]), off = try rescueRun([a, b], traced: false)
        XCTAssertEqual(on.0, off.0)
        XCTAssertEqual(on.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 1)])
        let event = try XCTUnwrap(on.1.first { $0.reason == .structuralRescue && $0.stage == .local })
        XCTAssertEqual(event.hash, 0.5625); XCTAssertEqual(event.hashLimit, 0.7)
        XCTAssertEqual(try XCTUnwrap(event.luminanceLimit), 0.115, accuracy: 0.00001)
        XCTAssertTrue(event.accepted); XCTAssertEqual(event.rescueEligible, true)
        XCTAssertTrue(on.1.contains { $0.stage == .local && $0.reason == .distanceLimit && !$0.accepted })
    }
    func testStructuralRescueDoesNotRepairMultipleFailuresWeakStructureOrHardCap() throws {
        let a = try feature()
        let variants = [try adjusted(a, angle: 1, hash: UInt64.max >> 28),
                        try adjusted(a, hash: UInt64.max >> 19),
                        try adjusted(a, hash: UInt64.max >> 28, color: 0.2),
                        try adjusted(a, angle: 1.7, hash: 0)]
        for b in variants {
            let result = try rescueRun([a, b])
            XCTAssertTrue(result.0.ranges.isEmpty)
            XCTAssertTrue(result.1.contains { $0.reason == .structuralRescueRejected && !$0.accepted })
        }
        var strict = SequenceDetectorConfiguration(); strict.localStructuralRescueFraction = 0.1
        let b = try adjusted(a, angle: 0.4, hash: UInt64.max >> 28)
        XCTAssertEqual(try rescueRun([a, b]).0.ranges.count, 1)
        XCTAssertTrue(try rescueRun([a, b], config: strict).0.ranges.isEmpty)
    }
    func testBridgeHistogramRescueKeepsDenseSupportsGlobalAnchorsAndTwelveSecondLimit() throws {
        let a = try feature(), b = try adjusted(a, color: 0.3)
        let frames = [a, a, a, b, b, b], times: [Double] = [0, 0.05, 0.1, 7.1, 7.15, 7.2]
        let on = try rescueRun(frames, times: times), off = try rescueRun(frames, times: times, traced: false)
        XCTAssertEqual(on.0, off.0)
        XCTAssertEqual(on.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 5)])
        let event = try XCTUnwrap(on.1.first { $0.reason == .structuralRescue && $0.stage == .bridge })
        XCTAssertEqual(event.leftSupport, 3); XCTAssertEqual(event.rightSupport, 3)
        XCTAssertEqual(try XCTUnwrap(event.histogram), 0.3, accuracy: 0.00001)
        XCTAssertEqual(event.histogramLimit, 0.35)
        XCTAssertEqual(try XCTUnwrap(event.luminanceLimit), 0.13, accuracy: 0.00001)
        XCTAssertTrue(on.1.filter { $0.stage == .anchor }.allSatisfy(\.accepted))
        let short = try rescueRun([a, a, a, b, b], times: Array(times.prefix(5)))
        XCTAssertFalse(short.0.ranges.contains { $0.range.first == 0 && $0.range.last == 4 })
        let tooLate = try rescueRun(frames, times: [0, 0.05, 0.1, 13.1, 13.15, 13.2])
        XCTAssertFalse(tooLate.0.ranges.contains { $0.range.count == 6 })
        let outsideAnchor = try adjusted(a, color: 0.36)
        let rejected = try rescueRun([a, a, a, outsideAnchor, outsideAnchor, outsideAnchor], times: times)
        XCTAssertFalse(rejected.0.ranges.contains { $0.range.count == 6 })
        XCTAssertTrue(rejected.1.contains { $0.stage == .anchor && !$0.accepted })
    }
    func testBridgeRescueRejectsWeakSpatialAndMultipleOrdinaryFailures() throws {
        let a = try feature(), times: [Double] = [0, 0.05, 0.1, 7.1, 7.15, 7.2]
        for b in [try adjusted(a, angle: 1, color: 0.3),
                  try adjusted(a, hash: UInt64.max >> 21, color: 0.3)] {
            let result = try rescueRun([a, a, a, b, b, b], times: times)
            XCTAssertFalse(result.0.ranges.contains { $0.range.count == 6 })
            XCTAssertTrue(result.1.contains { $0.stage == .bridge && $0.reason == .structuralRescueRejected })
        }
    }
    private func pixels(subjectX: Int, subjectWidth: Int, fullHeight: Bool = false) throws -> SequenceFrameFeature {
        var bytes = [UInt8](repeating: 255, count: 32 * 32 * 4)
        for y in 0..<32 { for x in 0..<32 {
            let inside = x >= subjectX && x < subjectX + subjectWidth && (fullHeight || (4..<28).contains(y))
            let value: UInt8 = inside ? 224 : ((x + y).isMultiple(of: 2) ? 32 : 48)
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
    func testGeneratedPixelsSameBackgroundLargeSubjectShiftIsNotRescued() throws {
        let left = try pixels(subjectX: 0, subjectWidth: 16, fullHeight: true)
        let right = try pixels(subjectX: 16, subjectWidth: 16, fullHeight: true)
        let distance = left.distance(to: right)
        XCTAssertLessThan(distance.histogram, 0.001)
        XCTAssertGreaterThan(distance.luminance, SequenceDetectorConfiguration().localLuminanceLimit)
        XCTAssertTrue(try rescueRun([left, right]).0.ranges.isEmpty)
        let bridge = try rescueRun([left, left, left, right, right, right], times: [0, 0.05, 0.1, 7.1, 7.15, 7.2])
        XCTAssertFalse(bridge.0.ranges.contains { $0.range.count == 6 })
    }
    func testGeneratedPixelsGradualSubjectDriftCannotResetTheFirstAnchor() throws {
        let frames = try (0...16).map { try pixels(subjectX: $0, subjectWidth: 16, fullHeight: true) }
        XCTAssertTrue(zip(frames.dropFirst(), frames).allSatisfy {
            $0.distance(to: $1).luminance < SequenceDetectorConfiguration().localLuminanceLimit
        })
        let result = try rescueRun(frames)
        XCTAssertFalse(result.0.ranges.contains { $0.range.count == frames.count })
        XCTAssertTrue(result.1.contains { $0.stage == .anchor && !$0.accepted })
    }
    func testRepeatedRescuedPauseStillCannotWashOutGlobalDrift() throws {
        let a = try feature(), colors: [Float] = [0, 0.3, 0.6]
        let frames = try colors.flatMap { color in try (0..<3).map { _ in try adjusted(a, color: color) } }
        let result = try rescueRun(frames, times: [0, 0.05, 0.1, 7.1, 7.15, 7.2, 14.2, 14.25, 14.3])
        XCTAssertTrue(result.1.contains { $0.stage == .bridge && $0.reason == .structuralRescue })
        XCTAssertFalse(result.0.ranges.contains { $0.range.count == 9 })
        XCTAssertTrue(result.1.contains { $0.stage == .anchor && !$0.accepted })
    }
    func testRescuePolicyFiniteBoundsAndVersionedFingerprint() throws {
        let baseline = SequenceDetectorConfiguration(), scope = try manifest(2)
        XCTAssertEqual(SequenceDetectorConfiguration.algorithmVersion, "sequence-local-anchor-cadence-dev-4")
        XCTAssertEqual(SequenceDetectorConfiguration.policyVersion, "sequence-policy-dev-4")
        XCTAssertEqual(SequenceTraceEvent.version, "sequence-decision-trace-v3")
        let invalid: [Float] = [0, -0.1, 0.500001, .nan, .infinity, -.infinity]
        for value in invalid {
            var local = baseline; local.localStructuralRescueFraction = value
            XCTAssertThrowsError(try local.validate()); XCTAssertThrowsError(try detector(scope, local))
            var bridge = baseline; bridge.bridgeStructuralRescueFraction = value
            XCTAssertThrowsError(try bridge.validate()); XCTAssertThrowsError(try detector(scope, bridge))
        }
        var other = baseline; other.localStructuralRescueFraction = 0.4
        XCTAssertNotEqual(try baseline.fingerprint, try other.fingerprint)
        XCTAssertEqual(try JSONDecoder().decode(SequenceDetectorConfiguration.self, from: JSONEncoder().encode(other)), other)
    }
}
