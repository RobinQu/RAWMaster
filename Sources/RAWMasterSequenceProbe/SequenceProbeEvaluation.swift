import Foundation
import RAWMasterCore
import RAWMasterImaging

struct ProbeGroupEvaluation: Encodable {
    let id: String
    let kind: SequenceKind
    let memberCount: Int
    let exactMembership: Bool
    let exactMembershipAndType: Bool
    let typedMemberCount: Int
    let missingMembers: [String]
    let extraMembers: [String]
}
struct ProbeNegativeEvaluation: Encodable {
    let from: String
    let to: String
    let decidable: Bool
    let merged: Bool
    let reasons: [String]
}
struct ProbeEvaluation: Encodable {
    let metricDefinition = "manifest-adjacent-edges-v2; positive edges require consecutive ordinals in the same labeled group; only explicit adjacent negative edges enter acceptance"
    let nativeDeviceIdentityVerified = false
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let trueNegative: Int
    let unknownPositivePairs: Int
    let unknownNegativePairs: Int
    let unlabeledPairsExcluded: Bool
    let precision: Double?
    let recall: Double?
    let typedCoverage: Double?
    let exactGroupFraction: Double?
    let groups: [ProbeGroupEvaluation]
    let negativePairs: [ProbeNegativeEvaluation]
    let coverageCounts: [String: Int]
    let unknownCount: Int
    let sourceDeclarationPartitionID: String?
    let knownCameraMakes: [String]
    let knownCameraModels: [String]
    let sourceAssertionMismatchOrdinals: [Int]
    let sourceDeclarationContradictions: [String]
    let acceptanceConfigured: Bool
    let qualityUnderAssumption: Bool
    let sourceDeclaredByUser: Bool
    let acceptedWithinDeclaredSourceScope: Bool
    let failures: [String]
}
enum ProbeEvaluator {
    static func evaluate(_ analysis: ProbeAnalysis, labels: ProbeLabels, policy: ProbePolicy) throws -> ProbeEvaluation {
        let manifest = analysis.manifest, result = analysis.result
        try policy.validate()
        try labels.validate(assetIDs: manifest.entries.map(\.assetID))
        let expectedToken = try SequenceAnalysisToken.make(manifest: manifest, versions: policy.detector.versions(order: manifest.orderVersion), policyFingerprint: policy.detector.fingerprint)
        try result.validate(manifest: manifest, expectedToken: expectedToken, observations: analysis.observations)
        guard analysis.featuresAvailable.count == manifest.entries.count else { throw SequenceProbeError.invalid("Missing feature coverage") }
        let ordinals = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.assetID, $0.ordinal) })
        var membership: [Int: Int] = [:], coverage: [Int: SequenceCoverageRange] = [:], counts: [String: Int] = [:]
        for part in result.coverage {
            counts[part.state.rawValue, default: 0] += part.range.count
            for ordinal in part.range.first...part.range.last { coverage[ordinal] = part }
        }
        for (index, group) in result.ranges.enumerated() { for ordinal in group.range.first...group.range.last { membership[ordinal] = index } }
        func sameGroup(_ a: Int, _ b: Int) -> Bool { membership[a] != nil && membership[a] == membership[b] }
        func issues(_ ordinal: Int) -> [String] {
            var reasons = analysis.observations[ordinal].validationIssues(manifest: manifest, versions: result.token.versions).map(\.rawValue)
            if !analysis.featuresAvailable[ordinal] { reasons.append("feature-unavailable") }
            guard let part = coverage[ordinal] else { return reasons + ["coverage-missing"] }
            // Valid standalone endpoints may legitimately be insufficient only for sequence membership.
            if part.state == .unreadable || part.state == .incomplete { reasons.append(part.state.rawValue) }
            reasons += part.reasons.filter { $0 != .noSequenceSupport }.map(\.rawValue)
            if part.state == .insufficient && Set(part.reasons) != Set([SequenceReason.noSequenceSupport]) { reasons.append("insufficient-not-a-decidable-standalone") }
            return Array(Set(reasons)).sorted()
        }
        func pairIssues(_ a: Int, _ b: Int) -> [String] {
            var reasons = issues(a) + issues(b)
            let first = analysis.observations[a], second = analysis.observations[b]
            if first.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint) == nil || first.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint) != second.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint) { reasons.append("source-not-comparable") }
            if first.clock == nil || first.clock != second.clock { reasons.append("clock-not-comparable") }
            return Array(Set(reasons)).sorted()
        }
        func canonicalCameraValue(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
        // ProbePolicy supplies one declaration for the ENTIRE content-bound manifest.
        // Clock/preview/read barriers and unlabeled context must not reset known counterevidence.
        let knownMakes = Set(analysis.observations.compactMap { canonicalCameraValue($0.evidence?.cameraMake) }).sorted()
        let knownModels = Set(analysis.observations.compactMap { canonicalCameraValue($0.evidence?.cameraModel) }).sorted()
        let mismatchOrdinals = analysis.observations.filter { input in
            input.entry.barrier == .assertionMismatch || input.barrier == .assertionMismatch
                || input.validationIssues(manifest: manifest, versions: result.token.versions).contains(.assertionMismatch)
                || coverage[input.entry.ordinal]?.reasons.contains(.assertionMismatch) == true
        }.map { $0.entry.ordinal }
        var sourceContradictions: [String] = []
        if !mismatchOrdinals.isEmpty { sourceContradictions.append("explicit-assertion-mismatch") }
        if policy.sourceAssertion != nil {
            if knownMakes.count > 1 { sourceContradictions.append("conflicting-known-camera-makes") }
            if knownModels.count > 1 { sourceContradictions.append("conflicting-known-camera-models") }
        }
        let declarationPartition = policy.sourceAssertion.map { "manifest-assertion:\($0.id):revision:\($0.revision):\(manifest.contentFingerprint)" }
        var tp = 0, fp = 0, fn = 0, tn = 0, unknownPositive = 0, unknownNegative = 0
        var evaluatedGroups: [ProbeGroupEvaluation] = [], typedMembers = 0, labeledMembers = 0
        for group in labels.groups {
            let indices = group.assetIDs.map { ordinals[$0]! }
            let labeledOrdinals = Set(indices)
            // Adjacency is defined by the complete input manifest, never by filtering
            // the truth members and zipping across an intervening or missing row.
            for left in indices where labeledOrdinals.contains(left + 1) {
                if sameGroup(left, left + 1) { tp += 1 }
                else { fn += 1; if !pairIssues(left, left + 1).isEmpty { unknownPositive += 1 } }
            }
            let desired = Set(group.assetIDs)
            let overlapping = result.ranges.filter { detected in group.assetIDs.contains { detected.range.first...detected.range.last ~= ordinals[$0]! } }
            let predictedIDs = Set(overlapping.flatMap { detected in (detected.range.first...detected.range.last).map { manifest.entries[$0].assetID } })
            let exact = overlapping.count == 1 && predictedIDs == desired
            let exactType = exact && overlapping.first?.kind == group.kind
            let typed = indices.filter { ordinal in membership[ordinal].map { result.ranges[$0].kind == group.kind && group.kind != .sequence } ?? false }.count
            typedMembers += typed; labeledMembers += group.assetIDs.count
            evaluatedGroups.append(ProbeGroupEvaluation(id: group.id, kind: group.kind, memberCount: group.assetIDs.count, exactMembership: exact, exactMembershipAndType: exactType, typedMemberCount: typed,
                missingMembers: desired.subtracting(predictedIDs).sorted(), extraMembers: predictedIDs.subtracting(desired).sorted()))
        }
        var negatives: [ProbeNegativeEvaluation] = []
        for pair in labels.negativePairs {
            let a = ordinals[pair.from]!, b = ordinals[pair.to]!, reasons = pairIssues(a, b)
            let merged = sameGroup(a, b), decidable = reasons.isEmpty
            if merged { fp += 1 }
            else if decidable { tn += 1 }
            if !decidable { unknownNegative += 1 }
            negatives.append(ProbeNegativeEvaluation(from: pair.from, to: pair.to, decidable: decidable, merged: merged, reasons: reasons))
        }
        let precision = tp + fp > 0 ? Double(tp) / Double(tp + fp) : nil
        let recall = tp + fn > 0 ? Double(tp) / Double(tp + fn) : nil
        let typed = labeledMembers > 0 ? Double(typedMembers) / Double(labeledMembers) : nil
        let exactFraction = labels.groups.isEmpty ? nil : Double(evaluatedGroups.filter(\.exactMembershipAndType).count) / Double(labels.groups.count)
        var failures: [String] = []
        if !analysis.sourcesUnchanged { failures.append("source-integrity-not-proven") }
        if !sourceContradictions.isEmpty { failures.append("source-declaration-contradicted") }
        if unknownNegative > 0 { failures.append("acceptanceIncomplete: every confirmed negative boundary must be decidable") }
        if fp > 0 { failures.append("confirmed-negative-boundary-merged") }
        if let gate = policy.acceptance {
            if tp + fn < gate.minimumPositivePairs { failures.append("positive-support-below-frozen-minimum") }
            if labels.negativePairs.count < gate.minimumNegativePairs { failures.append("negative-support-below-frozen-minimum") }
            if precision.map({ $0 >= gate.minimumPrecision }) != true { failures.append("precision-unmet-or-undefined") }
            if recall.map({ $0 >= gate.minimumRecall }) != true { failures.append("recall-unmet-or-undefined") }
            if typed.map({ $0 >= gate.minimumTypedCoverage }) != true { failures.append("typed-coverage-unmet-or-undefined") }
            if exactFraction.map({ $0 >= gate.minimumExactGroupFraction }) != true { failures.append("exact-whole-group-unmet-or-undefined") }
        } else { failures.append("acceptanceNotConfigured") }
        let quality = failures.isEmpty, declared = policy.sourceAssertion?.declaredByUser == true
        return ProbeEvaluation(truePositive: tp, falsePositive: fp, falseNegative: fn, trueNegative: tn, unknownPositivePairs: unknownPositive, unknownNegativePairs: unknownNegative,
            unlabeledPairsExcluded: true, precision: precision, recall: recall, typedCoverage: typed, exactGroupFraction: exactFraction,
            groups: evaluatedGroups, negativePairs: negatives, coverageCounts: counts,
            unknownCount: manifest.entries.filter { !issues($0.ordinal).isEmpty }.count,
            sourceDeclarationPartitionID: declarationPartition, knownCameraMakes: knownMakes, knownCameraModels: knownModels,
            sourceAssertionMismatchOrdinals: mismatchOrdinals, sourceDeclarationContradictions: sourceContradictions,
            acceptanceConfigured: policy.acceptance != nil, qualityUnderAssumption: quality, sourceDeclaredByUser: declared, acceptedWithinDeclaredSourceScope: quality && declared, failures: failures)
    }
}
