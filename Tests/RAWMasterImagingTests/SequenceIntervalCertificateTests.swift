import XCTest
@testable import RAWMasterImaging

final class SequenceIntervalCertificateTests: XCTestCase {
    func testCertificateIntersectsActualGapAndOriginUsingAcceptedSteps() throws {
        let initial = try XCTUnwrap(SequencePeriodInterval(lower: 4.6, upper: 5.4))
        let first = try XCTUnwrap(initial.accepting(gap: 10.0, elapsed: 10.0, steps: 2, cycle: 2,
            tolerance: 0.4, pointUncertainty: 0.001, previousUncertainty: 0.001, originUncertainty: 0.001))
        XCTAssertEqual(first.lower, 4.799, accuracy: 0.000001)
        XCTAssertEqual(first.upper, 5.201, accuracy: 0.000001)
        let second = try XCTUnwrap(first.accepting(gap: 5.0, elapsed: 15.0, steps: 1, cycle: 3,
            tolerance: 0.4, pointUncertainty: 0.001, previousUncertainty: 0.001, originUncertainty: 0.001))
        XCTAssertGreaterThanOrEqual(second.lower, first.lower); XCTAssertLessThanOrEqual(second.upper, first.upper)
        XCTAssertEqual(second.lower, 4.866, accuracy: 0.000001)
        XCTAssertEqual(second.upper, 5.134, accuracy: 0.000001)
        XCTAssertNil(initial.accepting(gap: 10, elapsed: 10, steps: 1, cycle: 1, tolerance: 0.4,
            pointUncertainty: 0.001, previousUncertainty: 0.001, originUncertainty: 0.001))
    }
    func testGlobalConsensusDoesNotFollowPairwiseOverlappingEpochDrift() throws {
        let a = try XCTUnwrap(SequencePeriodInterval(lower: 4.8, upper: 5.2))
        let b = try XCTUnwrap(SequencePeriodInterval(lower: 5.1, upper: 5.3))
        let c = try XCTUnwrap(SequencePeriodInterval(lower: 5.25, upper: 5.5))
        XCTAssertNotNil(b.intersecting(c))
        let consensus = try XCTUnwrap(SequenceIntervalConsensus(referencePeriod: 5, certificate: a, relativeTolerance: 0.08))
        let narrowed = try XCTUnwrap(consensus.accepting(b))
        XCTAssertEqual(narrowed.referencePeriod, 5)
        XCTAssertEqual(narrowed.feasible.lower, 5.1); XCTAssertEqual(narrowed.feasible.upper, 5.2)
        XCTAssertNil(narrowed.accepting(c))
    }
    func testPauseRequiresBeyondOldMissingExplanationAndHonorsFrozenLeftPeriod() throws {
        let c = SequenceDetectorConfiguration()
        let state = try XCTUnwrap(SequenceIntervalConsensus(referencePeriod: 5,
            certificate: XCTUnwrap(SequencePeriodInterval(lower: 4.8, upper: 5.2)), relativeTolerance: c.relativeCadenceTolerance))
        let lower = 4 * 5.0 + max(c.absoluteCadenceTolerance, c.relativeCadenceTolerance * 5) + 0.001 + 0.001
        XCTAssertFalse(state.acceptsPause(gap: lower, leftPeriod: 5, leftUncertainty: 0.001, rightUncertainty: 0.001, configuration: c))
        XCTAssertTrue(state.acceptsPause(gap: lower + 0.001, leftPeriod: 5, leftUncertainty: 0.001, rightUncertainty: 0.001, configuration: c))
        XCTAssertTrue(state.acceptsPause(gap: 22, leftPeriod: 5, leftUncertainty: 0.001, rightUncertainty: 0.001, configuration: c))
        XCTAssertFalse(state.acceptsPause(gap: 22, leftPeriod: 6, leftUncertainty: 0.001, rightUncertainty: 0.001, configuration: c))
        XCTAssertTrue(state.acceptsPause(gap: 60, leftPeriod: 5, leftUncertainty: 0.001, rightUncertainty: 0.001, configuration: c))
        XCTAssertFalse(state.acceptsPause(gap: 60.001, leftPeriod: 5, leftUncertainty: 0.001, rightUncertainty: 0.001, configuration: c))
    }
    func testInvalidCertificatesAndUnboundedResearchConfigurationAreRejected() throws {
        XCTAssertNil(SequencePeriodInterval(lower: .nan, upper: 5))
        XCTAssertNil(SequencePeriodInterval(lower: 5, upper: .infinity))
        XCTAssertNil(SequencePeriodInterval(lower: 6, upper: 5))
        let interval = try XCTUnwrap(SequencePeriodInterval(lower: 4, upper: 6))
        XCTAssertNil(interval.accepting(gap: 5, elapsed: 5, steps: 0, cycle: 1, tolerance: 0.1,
            pointUncertainty: 0.001, previousUncertainty: 0.001, originUncertainty: 0.001))
        for bad in [Double.nan, .infinity, -1, 0] {
            var c = SequenceDetectorConfiguration(); c.maximumEpisodePausePeriods = bad
            XCTAssertThrowsError(try c.validate())
            c = .init(); c.maximumEpisodePauseSeconds = bad; XCTAssertThrowsError(try c.validate())
            c = .init(); c.maximumStartupPeriods = bad; XCTAssertThrowsError(try c.validate())
        }
        var c = SequenceDetectorConfiguration(); c.anchorCount = 1
        XCTAssertThrowsError(try c.validate())
    }
}
