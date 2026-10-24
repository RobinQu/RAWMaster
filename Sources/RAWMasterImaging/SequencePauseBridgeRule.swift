import Foundation
import RAWMasterCore

public enum SequencePauseBridgeVerdict: String, Codable, Sendable { case notApplicable, retained, vetoed }
public enum SequencePauseBridgeReason: String, Codable, Sendable {
    case incompleteSupport, unavailableContext, sourceOrClockMismatch, incomparableSettings
    case counterContextUnavailable, continuousCounter, focusUnavailable, focusNotCohesive, focusOverlaps
    case appearanceNotSeparated, jointFocusAppearanceSeparation
}
public struct SequencePauseBridgeEvidence: Codable, Sendable, Equatable {
    public let verdict: SequencePauseBridgeVerdict
    public let reason: SequencePauseBridgeReason
    public let leftOverlaps, rightOverlaps, crossOverlaps: Int?
    public let histogramGap, luminanceGap, hashGap: Double?
    public var focusGeometryPassed: Bool { leftOverlaps == 3 && rightOverlaps == 3 && crossOverlaps == 0 }
    public var appearanceSeparationPassed: Bool {
        [histogramGap, luminanceGap, hashGap].allSatisfy { value in value.map { $0.isFinite && $0 > 0 } ?? false }
    }
    init(_ verdict: SequencePauseBridgeVerdict, _ reason: SequencePauseBridgeReason,
         leftOverlaps: Int? = nil, rightOverlaps: Int? = nil, crossOverlaps: Int? = nil,
         histogramGap: Double? = nil, luminanceGap: Double? = nil, hashGap: Double? = nil) {
        self.verdict = verdict; self.reason = reason; self.leftOverlaps = leftOverlaps
        self.rightOverlaps = rightOverlaps; self.crossOverlaps = crossOverlaps
        self.histogramGap = histogramGap; self.luminanceGap = luminanceGap; self.hashGap = hashGap
    }
}
struct SequenceFocusRectangle: Sendable, Equatable {
    let left, right, top, bottom: Int64
    func overlaps(_ other: Self) -> Bool {
        max(left, other.left) <= min(right, other.right) && max(top, other.top) <= min(bottom, other.bottom)
    }
}
/// A single, explicitly versioned development hypothesis. No labels, paths or sample IDs enter it.
public enum SequencePauseBridgeRule {
    static func rectangle(_ context: SequencePauseBridgeContext) -> SequenceFocusRectangle? {
        let focus = context.focus
        let names = ["sony.FocusLocation", "sony.FocusLocation2", "sony.FocusFrameSize",
                     "sony.FocusMode", "sony.AFTracking", "sony.CameraOrientation"]
        guard context.runtimeCohortComparable, (focus.state == .audited || focus.state == .runtimeExtracted), names.allSatisfy({ focus.fieldStates[$0] == .present }),
              focus.resolvedCodes["sony.FocusMode"] == 3,
              let tracking = focus.resolvedCodes["sony.AFTracking"], [1, 2].contains(tracking),
              let orientation = context.orientation, [1, 3, 6, 8].contains(orientation),
              focus.resolvedCodes["sony.CameraOrientation"] == orientation,
              let primary = focus.resolvedTuples["sony.FocusLocation"], primary.count == 4,
              let secondary = focus.resolvedTuples["sony.FocusLocation2"], secondary.count == 4,
              let frame = focus.resolvedTuples["sony.FocusFrameSize"], frame.count == 3,
              (primary + secondary + frame).allSatisfy({ (0...65535).contains($0) }),
              primary[0] > 0, primary[1] > 0, primary[0] == context.referenceWidth,
              primary[1] == context.referenceHeight, secondary[0] == primary[0], secondary[1] == primary[1],
              primary[2] <= primary[0], primary[3] <= primary[1],
              secondary[2] <= secondary[0], secondary[3] <= secondary[1],
              abs(primary[2] - secondary[2]) <= 1, abs(primary[3] - secondary[3]) <= 1,
              !(2 * primary[2] == primary[0] && 2 * primary[3] == primary[1]),
              !(2 * secondary[2] == secondary[0] && 2 * secondary[3] == secondary[1]),
              frame[0] > 0, frame[1] > 0, frame[2] != 0 else { return nil }
        let rectangle = SequenceFocusRectangle(left: 2 * Int64(primary[2]) - Int64(frame[0]),
            right: 2 * Int64(primary[2]) + Int64(frame[0]), top: 2 * Int64(primary[3]) - Int64(frame[1]),
            bottom: 2 * Int64(primary[3]) + Int64(frame[1]))
        guard rectangle.left >= 0, rectangle.top >= 0, rectangle.right <= 2 * Int64(primary[0]),
              rectangle.bottom <= 2 * Int64(primary[1]) else { return nil }
        return rectangle
    }
    static func gaps(cross: [SequenceFeatureDistance], left: [SequenceFeatureDistance], right: [SequenceFeatureDistance]) -> [Double]? {
        guard cross.count == 9, left.count == 3, right.count == 3 else { return nil }
        var result: [Double] = []
        for metric in [\SequenceFeatureDistance.histogram, \.luminance, \.hash] {
            let a = cross.map { Double($0[keyPath: metric]) }, b = left.map { Double($0[keyPath: metric]) }, c = right.map { Double($0[keyPath: metric]) }
            guard (a + b + c).allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            let gap = a.min()! - b.max()! - c.max()!
            guard gap.isFinite else { return nil }; result.append(gap)
        }
        return result
    }
    static func gap(_ first: SequencePauseBridgeContext, _ second: SequencePauseBridgeContext) -> Double? {
        guard let a = first.localSecond, let b = second.localSecond,
              let x = first.nanosecond, let y = second.nanosecond else { return nil }
        guard (0..<1_000_000_000).contains(x), (0..<1_000_000_000).contains(y) else { return nil }
        let (seconds, overflow) = b.subtractingReportingOverflow(a)
        guard !overflow else { return nil }
        return Double(seconds) + Double(y - x) / 1e9
    }
    static func decide(leftFeatures: [SequenceFrameFeature], rightFeatures: [SequenceFrameFeature],
                       leftContexts: [SequencePauseBridgeContext?], rightContexts: [SequencePauseBridgeContext?],
                       denseGapSeconds: Double, maximumBridgeSeconds: Double,
                       cancelled: () -> Bool) throws -> SequencePauseBridgeEvidence {
        try SequenceCaptureEvents.checkCancellation(cancelled)
        guard leftFeatures.count == 3, rightFeatures.count == 3, leftContexts.count == 3, rightContexts.count == 3 else {
            return .init(.notApplicable, .incompleteSupport)
        }
        let contexts = (leftContexts + rightContexts).compactMap { $0 }
        guard contexts.count == 6, (leftFeatures + rightFeatures).allSatisfy(\.isInformative) else {
            return .init(.notApplicable, .unavailableContext)
        }
        let first = contexts[0]
        guard first.cameraPartitionID != nil, contexts.allSatisfy({
            $0.cameraPartitionID == first.cameraPartitionID && $0.scopeFingerprint == first.scopeFingerprint
                && $0.focusAuditSeal == first.focusAuditSeal && $0.originalOffsetMinutes == first.originalOffsetMinutes
                && $0.orientation == first.orientation && $0.referenceWidth == first.referenceWidth && $0.referenceHeight == first.referenceHeight
        }) else { return .init(.notApplicable, .sourceOrClockMismatch) }
        guard first.settings.count == SequencePauseBridgeContext.settingFields.count,
              contexts.allSatisfy({ $0.settings == first.settings }) else { return .init(.notApplicable, .incomparableSettings) }
        guard denseGapSeconds.isFinite, maximumBridgeSeconds.isFinite, denseGapSeconds > 0,
              let pause = gap(contexts[2], contexts[3]), pause > denseGapSeconds, pause <= maximumBridgeSeconds,
              contexts.allSatisfy({ $0.releaseMode == 2 && ($0.sequenceNumber ?? 0) > 0
                && $0.sequenceNumber == $0.sequenceImageNumber }) else { return .init(.notApplicable, .counterContextUnavailable) }
        for indices in [[0, 1, 2], [3, 4, 5]] {
            for (a, b) in zip(indices, indices.dropFirst()) {
                guard let start = contexts[a].sequenceNumber, let end = contexts[b].sequenceNumber,
                      end > start, end - start == 1, let time = gap(contexts[a], contexts[b]), time > 0, time <= denseGapSeconds else {
                    return .init(.notApplicable, .counterContextUnavailable)
                }
            }
        }
        if contexts[3].sequenceNumber! > contexts[2].sequenceNumber!, contexts[3].sequenceNumber! - contexts[2].sequenceNumber! == 1 {
            return .init(.notApplicable, .continuousCounter)
        }
        let rectangles = contexts.compactMap(rectangle)
        guard rectangles.count == 6 else { return .init(.notApplicable, .focusUnavailable) }
        let intra = [(0, 1), (0, 2), (1, 2)]
        let leftOverlaps = intra.filter { rectangles[$0.0].overlaps(rectangles[$0.1]) }.count
        let rightOverlaps = intra.filter { rectangles[$0.0 + 3].overlaps(rectangles[$0.1 + 3]) }.count
        let crossOverlaps = (0..<3).reduce(0) { count, a in count + (3..<6).filter { rectangles[a].overlaps(rectangles[$0]) }.count }
        guard leftOverlaps == 3, rightOverlaps == 3 else {
            return .init(.retained, .focusNotCohesive, leftOverlaps: leftOverlaps, rightOverlaps: rightOverlaps, crossOverlaps: crossOverlaps)
        }
        guard crossOverlaps == 0 else {
            return .init(.retained, .focusOverlaps, leftOverlaps: leftOverlaps, rightOverlaps: rightOverlaps, crossOverlaps: crossOverlaps)
        }
        var cross: [SequenceFeatureDistance] = [], left: [SequenceFeatureDistance] = [], right: [SequenceFeatureDistance] = []
        for a in leftFeatures { for b in rightFeatures {
            try SequenceCaptureEvents.checkCancellation(cancelled); cross.append(a.distance(to: b))
        } }
        for (a, b) in intra {
            try SequenceCaptureEvents.checkCancellation(cancelled)
            left.append(leftFeatures[a].distance(to: leftFeatures[b])); right.append(rightFeatures[a].distance(to: rightFeatures[b]))
        }
        try SequenceCaptureEvents.checkCancellation(cancelled)
        guard let differences = gaps(cross: cross, left: left, right: right) else {
            return .init(.retained, .appearanceNotSeparated, leftOverlaps: leftOverlaps, rightOverlaps: rightOverlaps, crossOverlaps: crossOverlaps)
        }
        let veto = differences.allSatisfy { $0 > 0 }
        return .init(veto ? .vetoed : .retained, veto ? .jointFocusAppearanceSeparation : .appearanceNotSeparated,
            leftOverlaps: leftOverlaps, rightOverlaps: rightOverlaps, crossOverlaps: crossOverlaps,
            histogramGap: differences[0], luminanceGap: differences[1], hashGap: differences[2])
    }
}
