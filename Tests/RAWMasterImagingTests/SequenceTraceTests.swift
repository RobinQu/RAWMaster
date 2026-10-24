import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

private final class SequenceTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SequenceTraceEvent] = []
    func append(_ event: SequenceTraceEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var events: [SequenceTraceEvent] { lock.lock(); defer { lock.unlock() }; return stored }
}

extension SequenceDetectorTests {
    private func traceRun(_ times: [Double], enabled: Bool, limits: SequenceTraceLimits = .init(),
                          config: SequenceDetectorConfiguration = .init(), cancelAfter: Int? = nil,
                          badAt: Int? = nil) throws -> (SequenceAnalysisResult, SequenceTraceSummary?, [SequenceTraceEvent]) {
        let scope = try manifest(times.count), collector = SequenceTraceCollector()
        let token = try SequenceAnalysisToken.make(manifest: scope, versions: config.versions(order: scope.orderVersion), policyFingerprint: config.fingerprint)
        let observer: (@Sendable (SequenceTraceEvent) -> Void)?
        if enabled { observer = { event in collector.append(event) } } else { observer = nil }
        var engine = try SequenceDetector(manifest: scope, token: token, configuration: config,
            trace: observer, traceLimits: limits)
        var prepare = SequenceObservationPreprocessor(manifest: scope)
        for (ordinal, seconds) in times.enumerated() {
            if cancelAfter == ordinal { engine.cancel(); break }
            do {
                try engine.consume(prepare.make(entry: scope.entries[ordinal],
                    evidence: evidence(scope.entries[ordinal], seconds: seconds),
                    feature: ordinal == badAt ? nil : try feature()))
            } catch SequenceDetectorError.budgetExceeded { break }
        }
        return (try engine.finish(), engine.traceSummary, collector.events)
    }
    func testTraceOnOffProducesExactlyEqualResultsAcrossActualDecisionBranches() throws {
        let scenarios: [[Double]] = [[0, 0.05, 0.1, 9.1, 9.15, 9.2], [0, 2, 4, 6, 10, 12, 14],
            [0, 13.967, 19.046, 24.053, 67.38, 72.38, 77.38, 82.38, 87.38]]
        var observed = Set<SequenceTraceStage>()
        for times in scenarios {
            let off = try traceRun(times, enabled: false), on = try traceRun(times, enabled: true)
            XCTAssertEqual(off.0, on.0); XCTAssertNil(off.1)
            XCTAssertEqual(on.1?.droppedEvents, 0); XCTAssertEqual(on.1?.invalidEvents, 0)
            for event in on.2 { observed.insert(event.stage) }
            XCTAssertEqual(on.1?.encodedBytes, try on.2.reduce(0) { try $0 + $1.encodedJSONLine().count })
            XCTAssertTrue(on.2.allSatisfy { (try? $0.encodedJSONLine().count).map { $0 <= 4096 } == true })
        }
        XCTAssertTrue(observed.contains(.cadence)); XCTAssertTrue(observed.contains(.anchor))
        XCTAssertTrue(observed.contains(.bridge)); XCTAssertTrue(observed.contains(.output))
    }
    func testTraceCountByteAndPerConsumeCapsDoNotChangeClassification() throws {
        let times = (0..<12).map { Double($0) * 0.05 }
        let off = try traceRun(times, enabled: false)
        for limits in [SequenceTraceLimits(maximumEvents: 3), SequenceTraceLimits(maximumBytes: 700),
                       SequenceTraceLimits(maximumEventsPerFrame: 1), SequenceTraceLimits(maximumEvents: 0)] {
            let on = try traceRun(times, enabled: true, limits: limits)
            XCTAssertEqual(off.0, on.0); XCTAssertTrue(try XCTUnwrap(on.1).incomplete)
            XCTAssertLessThanOrEqual(on.2.count, limits.maximumEvents)
            XCTAssertLessThanOrEqual(try XCTUnwrap(on.1).encodedBytes, limits.maximumBytes)
            for events in Dictionary(grouping: on.2, by: \.processingOrdinal).values {
                XCTAssertLessThanOrEqual(events.count, limits.maximumEventsPerFrame)
            }
        }
    }
    func testTraceCancellationMissingPreviewAndBudgetFailurePreserveResults() throws {
        let times = (0..<12).map { Double($0) * 0.05 }
        let offCancel = try traceRun(times, enabled: false, cancelAfter: 5)
        let onCancel = try traceRun(times, enabled: true, cancelAfter: 5)
        XCTAssertEqual(offCancel.0, onCancel.0)
        XCTAssertTrue(onCancel.2.contains { $0.reason == .cancelled })
        let offBarrier = try traceRun(times, enabled: false, badAt: 4)
        let onBarrier = try traceRun(times, enabled: true, badAt: 4)
        XCTAssertEqual(offBarrier.0, onBarrier.0)
        XCTAssertTrue(onBarrier.2.contains { $0.barrier == .missingEmbeddedPreview })
        var config = SequenceDetectorConfiguration(); config.memoryBudgetBytes = 1024
        let offBudget = try traceRun(times, enabled: false, config: config)
        let onBudget = try traceRun(times, enabled: true, config: config)
        XCTAssertEqual(offBudget.0, onBudget.0)
        XCTAssertTrue(onBudget.2.contains { $0.reason == .budgetExceeded })
    }
    func testTraceRejectsNonFiniteEventsAndUntrustedDecodedLimits() throws {
        let collector = SequenceTraceCollector()
        let trace = SequenceTraceRecorder(limits: .init(), sink: { collector.append($0) })
        trace.beginFrame(0)
        for number in [Double.nan, .infinity, -.infinity] {
            var event = SequenceTraceEvent(ordinal: 0, stage: .cadence, reason: .passed, accepted: true)
            event.gapSeconds = number; trace.emit(event)
        }
        XCTAssertTrue(collector.events.isEmpty); XCTAssertEqual(trace.summary.invalidEvents, 3)
        XCTAssertTrue(trace.summary.incomplete)
        let json = Data("{\"maximumEvents\":64001,\"maximumBytes\":10,\"maximumEventsPerFrame\":1}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceTraceLimits.self, from: json))
        let good = SequenceTraceLimits(maximumEvents: 9, maximumBytes: 800, maximumEventsPerFrame: 2)
        XCTAssertEqual(try JSONDecoder().decode(SequenceTraceLimits.self, from: JSONEncoder().encode(good)), good)
        let summary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace.summary)) as? [String: Any]
        XCTAssertEqual(summary?["incomplete"] as? Bool, true)
    }
}
