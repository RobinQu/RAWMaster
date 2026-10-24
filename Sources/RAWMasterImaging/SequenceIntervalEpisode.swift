import Foundation

/// Closed feasible period interval. Empty intersections are rejection, never a reset.
struct SequencePeriodInterval: Sendable, Equatable {
    let lower: Double
    let upper: Double
    init?(lower: Double, upper: Double) {
        guard lower.isFinite, upper.isFinite, lower > 0, lower <= upper else { return nil }
        self.lower = lower; self.upper = upper
    }
    func intersecting(_ other: Self) -> Self? {
        Self(lower: max(lower, other.lower), upper: min(upper, other.upper))
    }
    /// Uses the exact already-accepted step count and tolerance; never re-quantizes a gap.
    func accepting(gap: Double, elapsed: Double, steps: Int, cycle: Int,
                   tolerance: Double, pointUncertainty: Double,
                   previousUncertainty: Double, originUncertainty: Double) -> Self? {
        guard steps > 0, cycle > 0, gap.isFinite, elapsed.isFinite,
              [tolerance, pointUncertainty, previousUncertainty, originUncertainty].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let localTolerance = tolerance + pointUncertainty + previousUncertainty
        let phaseTolerance = tolerance + pointUncertainty + originUncertainty
        let lower = max(self.lower, (gap - localTolerance) / Double(steps), (elapsed - phaseTolerance) / Double(cycle))
        let upper = min(self.upper, (gap + localTolerance) / Double(steps), (elapsed + phaseTolerance) / Double(cycle))
        return Self(lower: lower, upper: upper)
    }
}

struct SequenceIntervalConsensus: Sendable, Equatable {
    let referencePeriod: Double
    private(set) var feasible: SequencePeriodInterval
    init?(referencePeriod: Double, certificate: SequencePeriodInterval, relativeTolerance: Double) {
        guard referencePeriod.isFinite, referencePeriod > 0, relativeTolerance.isFinite,
              relativeTolerance > 0, relativeTolerance < 0.5,
              let envelope = SequencePeriodInterval(lower: referencePeriod * (1 - relativeTolerance),
                  upper: referencePeriod * (1 + relativeTolerance)),
              let feasible = envelope.intersecting(certificate) else { return nil }
        self.referencePeriod = referencePeriod; self.feasible = feasible
    }
    func accepting(_ certificate: SequencePeriodInterval) -> Self? {
        guard let next = feasible.intersecting(certificate) else { return nil }
        var copy = self; copy.feasible = next; return copy
    }
    /// P_left is the frozen last accepted period of the left epoch, not a right-fit estimate.
    func acceptsPause(gap: Double, leftPeriod: Double, leftUncertainty: Double, rightUncertainty: Double,
                      configuration c: SequenceDetectorConfiguration) -> Bool {
        guard gap.isFinite, leftPeriod.isFinite, leftPeriod > 0,
              leftUncertainty.isFinite, rightUncertainty.isFinite,
              leftUncertainty >= 0, rightUncertainty >= 0 else { return false }
        let lower = Double(c.maximumMissingFrames + 1) * leftPeriod
            + max(c.absoluteCadenceTolerance, c.relativeCadenceTolerance * leftPeriod) + leftUncertainty + rightUncertainty
        let upper = min(c.maximumEpisodePausePeriods * referencePeriod, c.maximumEpisodePauseSeconds)
        return gap > lower && gap <= upper
    }
}
