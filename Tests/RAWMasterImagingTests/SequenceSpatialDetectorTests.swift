import XCTest
import CoreGraphics
import RAWMasterCore
@testable import RAWMasterImaging

/// Deliberately controlled legacy distances isolate decision gates; spatial evidence comes from generated pixels.
extension SequenceDetectorTests {
    private func spatialPattern(_ seed: UInt64 = 7, constant: Bool = false) throws -> SequenceSpatialFeature {
        var bytes = [UInt8](repeating: 255, count: 96*96*4)
        for y in 0..<96 { for x in 0..<96 {
            var n = UInt64(x/4) &* 0x9e3779b97f4a7c15 ^ UInt64(y/4) &* 0xbf58476d1ce4e5b9 ^ seed
            n = (n ^ (n >> 30)) &* 0xbf58476d1ce4e5b9; n = (n ^ (n >> 27)) &* 0x94d049bb133111eb
            let v: UInt8 = constant ? 100 : UInt8(40 + (n ^ (n >> 31)) % 170), p = (y*96+x)*4
            bytes[p] = v; bytes[p+1] = v; bytes[p+2] = v
        } }
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: 96, height: 96,
            bitsPerComponent: 8, bytesPerRow: 384, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() })
        return try SequenceSpatialFeature.extract(image)
    }
    private func spatialRun(_ times: [Double], colors: [Float], spatial: [SequenceSpatialFeature?],
                            mode: SequenceSpatialMode?, legacy: [SequenceFrameFeature]? = nil,
                            trace: (@Sendable (SequenceTraceEvent)->Void)? = nil) throws -> (SequenceAnalysisResult, SequenceSpatialStatistics?) {
        var config = SequenceDetectorConfiguration(); config.spatialExperiment = mode.map { .init(mode: $0) }
        let scope = try manifest(times.count)
        let token = try SequenceAnalysisToken.make(manifest: scope, versions: config.versions(order: scope.orderVersion), policyFingerprint: config.fingerprint)
        var engine = try SequenceDetector(manifest: scope, token: token, configuration: config, trace: trace)
        var prepare = SequenceObservationPreprocessor(manifest: scope), inputs: [SequenceAssetInput] = []
        for i in times.indices {
            let observation = prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: times[i]),
                feature: try legacy?[i] ?? feature(colors[i]), spatialFeature: spatial[i])
            inputs.append(observation.input); try engine.consume(observation)
        }
        let result = try engine.finish()
        try result.validate(manifest: scope, expectedToken: token, observations: inputs)
        XCTAssertLessThanOrEqual(engine.managedPeakEstimateBytes, config.memoryBudgetBytes)
        XCTAssertEqual(engine.spatialManagedLiveBytes, 0)
        return (result, engine.spatialStatistics)
    }
    func testSpatialLocalHistogramOnlyRescueIsOptInAndLeavesVetoVariantUnchanged() throws {
        let a = try spatialPattern(), times: [Double] = [0,0.1], colors: [Float] = [0,0.2]
        let base = try spatialRun(times, colors: colors, spatial: [nil,nil], mode: nil)
        let veto = try spatialRun(times, colors: colors, spatial: [a,a], mode: .bridgeVetoOnly)
        let combined = try spatialRun(times, colors: colors, spatial: [a,a], mode: .localRescueAndBridgeVeto)
        XCTAssertTrue(base.0.ranges.isEmpty); XCTAssertNil(base.1)
        XCTAssertEqual(veto.0.ranges,base.0.ranges); XCTAssertEqual(veto.1?.pairRequests,0)
        XCTAssertEqual(combined.0.ranges.map(\.range),[try SequenceOrdinalRange(first: 0,last: 1)])
        XCTAssertEqual(combined.1?.supportedPairs,1)
    }
    func testSpatialLocalRescueCannotOverrideHistogramHardCapOrOtherFailures() throws {
        let a = try spatialPattern()
        for color: Float in [0.36,0.8] {
            let run = try spatialRun([0,0.1], colors: [0,color], spatial: [a,a], mode: .localRescueAndBridgeVeto)
            XCTAssertTrue(run.0.ranges.isEmpty); XCTAssertEqual(run.1?.pairRequests,0)
        }
        let first = try feature(), histogram = try feature(0.2).colorHistogram
        let badLuma = try SequenceFrameFeature(width: 32,height: 32,normalizedLuminance: first.normalizedLuminance.map { -$0 },
            colorHistogram: histogram,differenceHash: 0,mean: 0.5,standardDeviation: 0.2)
        let badHash = try SequenceFrameFeature(width: 32,height: 32,normalizedLuminance: first.normalizedLuminance,
            colorHistogram: histogram,differenceHash: UInt64.max,mean: 0.5,standardDeviation: 0.2)
        for failure in [badLuma,badHash] {
            let run = try spatialRun([0,0.1], colors: [0,0.2], spatial: [a,a], mode: .localRescueAndBridgeVeto, legacy: [first,failure])
            XCTAssertTrue(run.0.ranges.isEmpty); XCTAssertEqual(run.1?.pairRequests,0)
        }
        let wideGap = try spatialRun([0,0.7], colors: [0,0.2], spatial: [a,a], mode: .localRescueAndBridgeVeto)
        XCTAssertTrue(wideGap.0.ranges.isEmpty); XCTAssertEqual(wideGap.1?.pairRequests,0)
    }
    func testSpatialBridgeNeedsPositiveDistributedEvidenceRatherThanSimilarityOrUnknown() throws {
        let a = try spatialPattern(), b = try spatialPattern(999), flat = try spatialPattern(constant: true)
        let times: [Double] = [0,0.05,0.1,5,5.05,5.1,5.15], colors = [Float](repeating: 0,count: 7)
        let base = try spatialRun(times,colors: colors,spatial: Array(repeating: nil,count: 7),mode: nil)
        XCTAssertEqual(base.0.ranges.map(\.range),[try SequenceOrdinalRange(first: 0,last: 6)])
        let supported = try spatialRun(times,colors: colors,spatial: Array(repeating: a,count: 7),mode: .bridgeVetoOnly)
        XCTAssertEqual(supported.0.ranges,base.0.ranges); XCTAssertEqual(supported.1?.pairRequests,9)
        for right in [b,flat] {
            let run = try spatialRun(times,colors: colors,spatial: [a,a,a,right,right,right,right],mode: .bridgeVetoOnly)
            XCTAssertEqual(run.0.ranges.map(\.range),[try SequenceOrdinalRange(first: 0,last: 2),try SequenceOrdinalRange(first: 3,last: 6)])
            XCTAssertEqual(run.1?.pairRequests,9)
        }
        // Six supported pairs are not enough if the third left row has no supporting right member.
        let concentrated = try spatialRun(times,colors: colors,spatial: [a,a,b,a,a,a,a],mode: .bridgeVetoOnly)
        XCTAssertEqual(concentrated.1?.supportedPairs,6)
        XCTAssertEqual(concentrated.0.ranges.count,2)
    }
    func testSpatialDoesNotRescueLegacyBridgeRejectionOrGlobalAnchorDrift() throws {
        let a = try spatialPattern(), times: [Double] = [0,0.05,0.1,5,5.05,5.1]
        let run = try spatialRun(times,colors: [0,0,0,0.8,0.8,0.8],spatial: Array(repeating: a,count:6),mode: .localRescueAndBridgeVeto)
        XCTAssertEqual(run.0.ranges.count,2); XCTAssertEqual(run.1?.pairRequests,0)
        let driftColors: [Float] = [0,0.12,0.24,0.36,0.48]
        let drift = try spatialRun([0,0.1,0.2,0.3,0.4],colors:driftColors,spatial:Array(repeating:a,count:5),mode:.localRescueAndBridgeVeto)
        XCTAssertFalse(drift.0.ranges.contains { $0.range.first == 0 && $0.range.last == 4 })
    }
    func testSpatialBurstContextNeverVetoesIntervalEpochBridge() throws {
        let a = try spatialPattern(), b = try spatialPattern(999)
        let times: [Double] = [0,5,10,15,50,55,60,65], colors = [Float](repeating:0,count:8)
        let base = try spatialRun(times,colors:colors,spatial:Array(repeating:nil,count:8),mode:nil)
        let experiment = try spatialRun(times,colors:colors,spatial:[a,a,a,a,b,b,b,b],mode:.localRescueAndBridgeVeto)
        XCTAssertEqual(experiment.0.ranges,base.0.ranges); XCTAssertEqual(experiment.0.coverage,base.0.coverage)
        XCTAssertEqual(experiment.1?.pairRequests,0)
    }
    func testSpatialFeatureMissingIsHardErrorAndCancellationReleasesBuffers() throws {
        let a = try spatialPattern(), scope = try manifest(2)
        var config = SequenceDetectorConfiguration(); config.spatialExperiment = .init(mode:.localRescueAndBridgeVeto)
        var engine = try detector(scope,config), prep = SequenceObservationPreprocessor(manifest:scope)
        let first = prep.make(entry:scope.entries[0],evidence:evidence(scope.entries[0],seconds:0),feature:try feature(),spatialFeature:a)
        let second = prep.make(entry:scope.entries[1],evidence:evidence(scope.entries[1],seconds:0.1),feature:try feature(0.2),spatialFeature:a)
        try engine.consume(first); XCTAssertGreaterThan(engine.spatialManagedLiveBytes,0)
        var checks = 0
        XCTAssertThrowsError(try engine.consume(second,cancelled:{ checks += 1; return checks >= 80 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(engine.isStopped); XCTAssertEqual(engine.spatialManagedLiveBytes,0)
        let incomplete = try engine.finish()
        XCTAssertTrue(incomplete.ranges.isEmpty); XCTAssertTrue(incomplete.coverage.allSatisfy { $0.state == .incomplete })
        var broken = try detector(scope,config)
        let missing = SequenceObservation(input:first.input,feature:first.feature)
        XCTAssertThrowsError(try broken.consume(missing)) { XCTAssertEqual($0 as? SequenceDetectorError,.missingSpatialFeature) }
        XCTAssertEqual(broken.spatialManagedLiveBytes,0)
    }
    func testSpatialTraceOnOffCannotChangeSealedResultAndStaysFinite() throws {
        final class Collector: @unchecked Sendable {
            let lock = NSLock(); var events:[SequenceTraceEvent] = []
            func append(_ event:SequenceTraceEvent) { lock.lock(); defer { lock.unlock() }; events.append(event) }
        }
        let a = try spatialPattern(), collector = Collector(), times:[Double] = [0,0.1], colors:[Float] = [0,0.2]
        let off = try spatialRun(times,colors:colors,spatial:[a,a],mode:.localRescueAndBridgeVeto)
        let on = try spatialRun(times,colors:colors,spatial:[a,a],mode:.localRescueAndBridgeVeto,trace:{collector.append($0)})
        XCTAssertEqual(on.0,off.0)
        let events = collector.events.filter { $0.spatial != nil }
        XCTAssertEqual(events.count,1)
        for event in events {
            XCTAssertTrue(event.spatial?.isFinite == true)
            XCTAssertLessThanOrEqual(try event.encodedJSONLine().count,SequenceTraceLimits.maximumEventBytes)
        }
    }
}
