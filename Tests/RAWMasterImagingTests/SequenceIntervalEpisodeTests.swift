import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

private final class EpisodeTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SequenceTraceEvent] = []
    func append(_ event: SequenceTraceEvent) {
        lock.lock(); defer { lock.unlock() }
        if stored.count < 8192 { stored.append(event) }
    }
    var events: [SequenceTraceEvent] { lock.lock(); defer { lock.unlock() }; return stored }
}

extension SequenceDetectorTests {
    private func episodeRun(_ times: [Double], colors: [Float]? = nil, traced: Bool = true,
                            cancel: Bool = false, sealed: Bool = true, badAt: Int? = nil,
                            config: SequenceDetectorConfiguration = .init())
        throws -> (SequenceAnalysisResult, [SequenceTraceEvent]) {
        let scope = try manifest(times.count), sink = EpisodeTraceCollector()
        let token = try SequenceAnalysisToken.make(manifest: scope, versions: config.versions(order: scope.orderVersion), policyFingerprint: config.fingerprint)
        let observer: (@Sendable (SequenceTraceEvent) -> Void)?
        if traced { observer = { sink.append($0) } } else { observer = nil }
        var engine = try SequenceDetector(manifest: scope, token: token, configuration: config, trace: observer)
        var prepare = SequenceObservationPreprocessor(manifest: scope), observations: [SequenceAssetInput] = []
        for i in times.indices {
            let observation = prepare.make(entry: scope.entries[i], evidence: evidence(scope.entries[i], seconds: times[i]),
                feature: i == badAt ? nil : try feature(colors?[i] ?? 0))
            observations.append(observation.input); try engine.consume(observation)
        }
        if cancel { engine.cancel() }
        let result = try engine.finish(sealedInputComplete: sealed)
        try result.validate(manifest: scope, expectedToken: token, observations: observations)
        XCTAssertLessThanOrEqual(engine.managedPeakEstimateBytes, config.memoryBudgetBytes)
        return (result, sink.events)
    }
    func testBoundedWeakEpochAndStartupNeedTheLaterStableSeed() throws {
        let times: [Double] = [0, 14, 19, 24, 67, 72, 77, 82, 87]
        let on = try episodeRun(times), off = try episodeRun(times, traced: false)
        XCTAssertEqual(on.0, off.0)
        XCTAssertEqual(on.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 8)])
        XCTAssertEqual(on.0.ranges.first?.kind, .interval)
        XCTAssertTrue(on.1.contains { $0.reason == .weakConfirmed })
        XCTAssertTrue(on.1.contains { $0.reason == .startupAccepted && $0.ordinal == 0 })
        XCTAssertTrue(try episodeRun([0, 5, 10]).0.ranges.isEmpty)
        XCTAssertTrue(try episodeRun([0, 14, 19, 24, 67, 72, 77]).0.ranges.isEmpty)
    }
    func testNewEpochMayHaveANewPhaseButOrdinaryPhaseConflictCannotReset() throws {
        let paused = try episodeRun([0, 5, 10, 15, 44.2, 49.2, 54.2, 59.2])
        XCTAssertEqual(paused.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 7)])
        XCTAssertTrue(paused.1.contains { $0.reason == .epochAccepted })
        let ordinary = try episodeRun([0, 5, 10, 15, 21, 26, 31, 36])
        XCTAssertFalse(ordinary.0.ranges.contains { $0.range.count == 8 })
        XCTAssertFalse(ordinary.1.contains { $0.reason == .epochPending && $0.accepted })
    }
    func testEpochFrequenciesCannotDriftThroughPairwiseCompatibility() throws {
        let times: [Double] = [0, 5, 10, 15, 45, 50.2, 55.4, 60.6, 90.6, 96, 101.4, 106.8]
        let result = try episodeRun(times)
        XCTAssertTrue(result.1.contains { $0.reason == .epochAccepted })
        XCTAssertFalse(result.0.ranges.contains { $0.range.count == 12 })
        let different = try episodeRun([0, 5, 10, 15, 45, 51, 57, 63])
        XCTAssertEqual(different.0.ranges.count, 2)
        XCTAssertFalse(different.1.contains { $0.reason == .epochAccepted })
    }
    func testStartupUsesTotalPeriodBoundAndMaximumOfAllFixedRepresentatives() throws {
        let limited = try episodeRun([0, 20, 25, 30, 35])
        XCTAssertEqual(limited.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 1, last: 4)])
        // Keep a single outlying representative beyond the rescue hard cap, not just the ordinary cap.
        let rejected = try episodeRun([0, 14, 19, 24, 29], colors: [0, 0, 0, 0.36, 0])
        XCTAssertEqual(rejected.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 1, last: 4)])
        let event = try XCTUnwrap(rejected.1.first { $0.stage == .startup && $0.reason == .structuralRescueRejected })
        XCTAssertEqual(event.aggregation, .maximum)
        XCTAssertEqual(event.rightRepresentative0, 1); XCTAssertEqual(event.rightRepresentative1, 2)
        XCTAssertEqual(event.rightRepresentative2, 3)
        XCTAssertGreaterThan(try XCTUnwrap(event.histogram), try XCTUnwrap(event.histogramLimit))
        let accepted = try episodeRun([0, 14, 19, 24, 29])
        XCTAssertEqual(accepted.0.ranges.first?.range.first, 0)
    }
    func testSteadyIntervalDoesNotAcquireANewGlobalColorVeto() throws {
        let times = (0..<24).map { Double($0) * 5 }
        let colors = (0..<24).map { Float($0) / 30 }
        let result = try episodeRun(times, colors: colors)
        XCTAssertEqual(result.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 23)])
    }
    func testBothStartupAndStableSeedAnchorsSurvivePause() throws {
        let result = try episodeRun([0, 14, 19, 24, 29, 34, 39, 44, 74, 79, 84, 89],
            colors: [0.2, 0, 0, 0, 0, 0.1, 0.2, 0.3, 0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(result.0.ranges.first?.range.first, 0)
        XCTAssertFalse(result.0.ranges.contains { $0.range.count == 12 })
        XCTAssertTrue(result.1.contains { $0.stage == .anchor && $0.anchorIndex == 1 && !$0.accepted })
    }
    func testPauseUsesThreeByThreeMedianRatherThanMaximum() throws {
        let result = try episodeRun([0, 5, 10, 15, 45, 50, 55, 60], colors: [0, 0, 0.3, 0, 0, 0, 0, 0])
        XCTAssertEqual(result.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 7)])
        let bridge = try XCTUnwrap(result.1.first { $0.stage == .bridge && $0.accepted })
        XCTAssertEqual(bridge.histogram, 0)
        XCTAssertEqual(bridge.leftSupport, 3); XCTAssertEqual(bridge.rightSupport, 3)
        XCTAssertEqual(bridge.aggregation, .median)
        XCTAssertEqual(bridge.leftRepresentative0, 1); XCTAssertEqual(bridge.leftRepresentative1, 2)
        XCTAssertEqual(bridge.leftRepresentative2, 3)
        XCTAssertEqual(bridge.rightRepresentative0, 4); XCTAssertEqual(bridge.rightRepresentative1, 5)
        XCTAssertEqual(bridge.rightRepresentative2, 6)
    }
    func testRightBackConfirmationCannotRelaxTheOriginalEpisodePauseLimit() throws {
        let result = try episodeRun([0, 5, 10, 15, 45, 50.2, 55.4, 117.4, 122.6, 127.8, 133])
        // The right 5.2s epochs are compatible in period but their internal 62s pause
        // exceeds the original left reference's 60s bound. They may form a separate episode.
        XCTAssertEqual(result.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 3),
            try SequenceOrdinalRange(first: 4, last: 10)])
        XCTAssertFalse(result.0.ranges.contains { $0.range.count == 11 })
        let rejected = try XCTUnwrap(result.1.first {
            $0.stage == .episode && $0.reason == .epochRejected && $0.referencePeriod == 5
                && ($0.gapSeconds ?? 0) > 61.99 && ($0.gapSeconds ?? 0) < 62.01
        })
        XCTAssertEqual(try XCTUnwrap(rejected.upperGapBound), 60, accuracy: 0.00001)
        XCTAssertFalse(rejected.accepted)
    }
    func testUnprovedPauseTailAtEOFRemainsLooseAndAtCancelIncomplete() throws {
        let times: [Double] = [0, 5, 10, 15, 45, 50, 55]
        let eof = try episodeRun(times)
        XCTAssertEqual(eof.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 3)])
        XCTAssertEqual(eof.0.coverage.last?.state, .insufficient)
        for cancelled in [true, false] {
            let result = try episodeRun(times, cancel: cancelled, sealed: cancelled)
            XCTAssertEqual(result.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 3)])
            XCTAssertEqual(result.0.coverage.last?.state, .incomplete)
            XCTAssertEqual(result.0, try episodeRun(times, traced: false, cancel: cancelled, sealed: cancelled).0)
        }
    }
    func testCancelAfterJoiningStillPreservesOnlyThePreviouslyClosedLeftBoundary() throws {
        let result = try episodeRun([0, 5, 10, 15, 45, 50, 55, 60, 65], cancel: true)
        XCTAssertEqual(result.0.ranges.map(\.range), [try SequenceOrdinalRange(first: 0, last: 3)])
        XCTAssertEqual(result.0.coverage.last?.range, try SequenceOrdinalRange(first: 4, last: 8))
        XCTAssertEqual(result.0.coverage.last?.state, .incomplete)
    }
    func testPendingOverflowDoesNotRevisitTheEvictedRowOrLoseTheClosedLeft() throws {
        var times: [Double] = [0, 5, 10, 15, 45]
        for i in 0..<13 { times.append(times.last! + (i.isMultiple(of: 2) ? 1.1 : 4.7)) }
        let result = try episodeRun(times)
        XCTAssertTrue(result.1.contains { $0.reason == .pendingEvicted && $0.ordinal == 4 })
        XCTAssertEqual(result.0.ranges.first?.range, try SequenceOrdinalRange(first: 0, last: 3))
        XCTAssertFalse(result.0.ranges.contains { $0.range.first == 4 })
    }
    func testHardBarrierCannotBeBackfilledByAnEpisode() throws {
        let times: [Double] = [0, 14, 19, 24, 67, 72, 77, 82, 87]
        let result = try episodeRun(times, badAt: 3)
        XCTAssertFalse(result.0.ranges.contains { $0.range.first < 3 && $0.range.last > 3 })
        XCTAssertTrue(result.0.coverage.contains { $0.state == .unreadable && $0.range.first <= 3 && $0.range.last >= 3 })
    }
}
