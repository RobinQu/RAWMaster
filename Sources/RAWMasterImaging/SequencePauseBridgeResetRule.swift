import Foundation

/// Additive v2 hypothesis for an audited Sony cohort. A pause or counter restart alone
/// never separates a group. Recorded tracking loss, a stable changed focus code,
/// disjoint display locations and a separated color cohort must agree.
enum SequencePauseBridgeResetRule {
    static func stableCode(_ name: String, in contexts: ArraySlice<SequencePauseBridgeContext>,
                           allowed: (Int) -> Bool) -> Int? {
        guard contexts.count == 3, let first = contexts.first?.focus.resolvedCodes[name], allowed(first),
              contexts.allSatisfy({ $0.focus.fieldStates[name] == .present && $0.focus.resolvedCodes[name] == first }) else { return nil }
        return first
    }

    static func decide(leftFeatures: [SequenceFrameFeature], rightFeatures: [SequenceFrameFeature],
                       leftContexts: [SequencePauseBridgeContext?], rightContexts: [SequencePauseBridgeContext?],
                       denseGapSeconds: Double, maximumBridgeSeconds: Double,
                       fallback: SequencePauseBridgeEvidence, cancelled: () -> Bool) throws -> SequencePauseBridgeEvidence {
        try SequenceCaptureEvents.checkCancellation(cancelled)
        guard leftFeatures.count == 3, rightFeatures.count == 3, leftContexts.count == 3, rightContexts.count == 3,
              (leftFeatures + rightFeatures).allSatisfy(\.isInformative) else { return fallback }
        let contexts = (leftContexts + rightContexts).compactMap { $0 }
        guard contexts.count == 6, contexts.allSatisfy(\.resetCohortComparable) else { return fallback }
        let first = contexts[0]
        guard first.cameraPartitionID != nil, contexts.allSatisfy({
            $0.cameraPartitionID == first.cameraPartitionID && $0.scopeFingerprint == first.scopeFingerprint
                && $0.focusAuditSeal == first.focusAuditSeal && $0.originalOffsetMinutes == first.originalOffsetMinutes
                && $0.orientation == first.orientation && $0.referenceWidth == first.referenceWidth
                && $0.referenceHeight == first.referenceHeight
        }), first.settings.count == SequencePauseBridgeContext.settingFields.count,
            contexts.allSatisfy({ $0.settings == first.settings }) else { return fallback }
        guard denseGapSeconds.isFinite, maximumBridgeSeconds.isFinite, denseGapSeconds > 0,
              let pause = SequencePauseBridgeRule.gap(contexts[2], contexts[3]),
              pause > denseGapSeconds, pause <= maximumBridgeSeconds,
              contexts.allSatisfy({ $0.releaseMode == 2 && ($0.sequenceNumber ?? 0) > 0
                && $0.sequenceNumber == $0.sequenceImageNumber }),
              contexts[3].sequenceNumber! < contexts[2].sequenceNumber! else { return fallback }
        for indices in [[0, 1, 2], [3, 4, 5]] {
            for (a, b) in zip(indices, indices.dropFirst()) {
                guard let start = contexts[a].sequenceNumber, let end = contexts[b].sequenceNumber,
                      end > start, end - start == 1,
                      let gap = SequencePauseBridgeRule.gap(contexts[a], contexts[b]),
                      gap > 0, gap <= denseGapSeconds else { return fallback }
            }
        }
        let left = contexts.prefix(3), right = contexts.suffix(3)
        guard let leftTracking = stableCode("sony.AFTracking", in: left, allowed: { [1, 2].contains($0) }),
              let rightTracking = stableCode("sony.AFTracking", in: right, allowed: { $0 == 0 }),
              // Compare raw-byte equality only; 0 and 255 are unavailable/saturated sentinels.
              let leftPosition = stableCode("sony.FocusPosition2", in: left, allowed: { (1..<255).contains($0) }),
              let rightPosition = stableCode("sony.FocusPosition2", in: right, allowed: { (1..<255).contains($0) }),
              leftPosition != rightPosition else { return fallback }

        // Tracking-off display locations are not object boxes. They contribute only when
        // both recorded tuples agree, dimensions/orientation match and all cross pairs disjoin.
        let rectangles = contexts.compactMap { SequencePauseBridgeRule.rectangle($0, allowTrackingOff: true) }
        let valid = rectangles.count == 6
        let intra = [(0, 1), (0, 2), (1, 2)]
        let leftOverlaps = valid ? intra.filter { rectangles[$0.0].overlaps(rectangles[$0.1]) }.count : nil
        let rightOverlaps = valid ? intra.filter { rectangles[$0.0 + 3].overlaps(rectangles[$0.1 + 3]) }.count : nil
        let crossOverlaps = valid ? (0..<3).reduce(0) { count, a in count + (3..<6).filter { rectangles[a].overlaps(rectangles[$0]) }.count } : nil
        var crossDistances: [SequenceFeatureDistance] = [], leftDistances: [SequenceFeatureDistance] = [], rightDistances: [SequenceFeatureDistance] = []
        for a in leftFeatures { for b in rightFeatures {
            try SequenceCaptureEvents.checkCancellation(cancelled)
            crossDistances.append(a.distance(to: b))
        } }
        for (a, b) in intra {
            try SequenceCaptureEvents.checkCancellation(cancelled)
            leftDistances.append(leftFeatures[a].distance(to: leftFeatures[b]))
            rightDistances.append(rightFeatures[a].distance(to: rightFeatures[b]))
        }
        let gaps = SequencePauseBridgeRule.gaps(cross: crossDistances, left: leftDistances, right: rightDistances)
        let histogramSeparated = gaps.map { $0[0] > 0 } ?? false
        let disjoint = crossOverlaps == 0
        let veto = valid && disjoint && histogramSeparated
        try SequenceCaptureEvents.checkCancellation(cancelled)
        return .init(veto ? .vetoed : .retained, veto ? .jointFocusResetHistogramSeparation : .focusResetNotSeparated,
            leftOverlaps: leftOverlaps, rightOverlaps: rightOverlaps, crossOverlaps: crossOverlaps,
            histogramGap: gaps?[0], luminanceGap: gaps?[1], hashGap: gaps?[2],
            focusReset: SequenceFocusResetEvidence(counterRestart: true, leftTrackingCode: leftTracking,
                rightTrackingCode: rightTracking, leftFocusPositionCode: leftPosition, rightFocusPositionCode: rightPosition,
                validDisplayRegions: valid, disjointDisplayRegions: disjoint, histogramSeparated: histogramSeparated))
    }
}
