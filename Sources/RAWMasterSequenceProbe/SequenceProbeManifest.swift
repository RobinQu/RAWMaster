import Foundation
import RAWMasterCore
import RAWMasterImaging

enum SequenceProbeError: Error { case invalid(String) }

struct ProbeManifest: Codable {
    struct File: Codable { let assetID: String; let ordinal: Int; let relativePath: String }
    let schemaVersion: Int
    let scopeID: String
    let sessionID: String
    let orderVersion: String
    let files: [File]
    func validate() throws {
        guard schemaVersion == 1, !scopeID.isEmpty, !sessionID.isEmpty,
              orderVersion == SequenceBaseOrder.version, !files.isEmpty,
              Set(files.map(\.assetID)).count == files.count,
              Set(files.map(\.relativePath)).count == files.count else { throw SequenceProbeError.invalid("Invalid explicit manifest") }
        for (index, file) in files.enumerated() {
            let parts = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard file.ordinal == index, !file.assetID.isEmpty, !file.relativePath.hasPrefix("/"),
                  !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !file.relativePath.contains("\0") else { throw SequenceProbeError.invalid("Unsafe or unordered manifest entry") }
        }
    }
    func urls(root: URL) throws -> [URL] {
        try validate()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        return try files.map { file in
            let url = root.appendingPathComponent(file.relativePath).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { throw SequenceProbeError.invalid("Manifest path escapes explicit source root") }
            return url
        }
    }
}
struct ProbeSourceAssertion: Codable {
    let id: String
    let revision: Int
    let declaredByUser: Bool
    let provenance: String
}
struct ProbeAcceptance: Codable {
    let minimumPositivePairs: Int
    let minimumRecall: Double
    let minimumTypedCoverage: Double
    let minimumExactGroupFraction: Double
    let minimumPrecision: Double
    let minimumNegativePairs: Int
    func validate() throws {
        guard minimumPositivePairs > 0, minimumNegativePairs > 0,
              minimumPrecision >= 0.95,
              [minimumRecall, minimumTypedCoverage, minimumExactGroupFraction, minimumPrecision].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 })
        else { throw SequenceProbeError.invalid("Acceptance must freeze nonzero support/coverage and precision >=95%") }
    }
}
struct ProbeBoundedTrace: Codable {
    static let supportedVersion = "sequence-probe-jsonl-v1"
    static let framingReserveBytes = 32 * 1024
    let version: String
    let limits: SequenceTraceLimits
    let maximumFileBytes: Int
    init(version: String = ProbeBoundedTrace.supportedVersion,
         limits: SequenceTraceLimits = .init(maximumBytes: 32 * 1024 * 1024 - ProbeBoundedTrace.framingReserveBytes),
         maximumFileBytes: Int = 32 * 1024 * 1024) {
        self.version = version; self.limits = limits; self.maximumFileBytes = maximumFileBytes
    }
    func validate() throws {
        guard version == Self.supportedVersion, maximumFileBytes >= Self.framingReserveBytes,
              maximumFileBytes <= 32 * 1024 * 1024,
              (0...64_000).contains(limits.maximumEvents),
              (0...512).contains(limits.maximumEventsPerFrame),
              limits.maximumBytes >= 0,
              limits.maximumBytes <= maximumFileBytes - Self.framingReserveBytes
        else { throw SequenceProbeError.invalid("Invalid bounded trace version or limits") }
    }
}
struct ProbePolicy: Codable {
    let schemaVersion: Int
    let detector: SequenceDetectorConfiguration
    let sourceAssertion: ProbeSourceAssertion?
    let acceptance: ProbeAcceptance?
    let maximumDurationSeconds: Double
    let deterministicSeed: Int
    let boundedTrace: ProbeBoundedTrace?
    init(schemaVersion: Int, detector: SequenceDetectorConfiguration, sourceAssertion: ProbeSourceAssertion?,
         acceptance: ProbeAcceptance?, maximumDurationSeconds: Double, deterministicSeed: Int,
         boundedTrace: ProbeBoundedTrace? = nil) {
        self.schemaVersion = schemaVersion; self.detector = detector; self.sourceAssertion = sourceAssertion
        self.acceptance = acceptance; self.maximumDurationSeconds = maximumDurationSeconds
        self.deterministicSeed = deterministicSeed; self.boundedTrace = boundedTrace
    }
    func validate() throws {
        try detector.validate(); try acceptance?.validate(); try boundedTrace?.validate()
        guard (schemaVersion == 2 || schemaVersion == 3), (schemaVersion == 3 || boundedTrace == nil), deterministicSeed == 0,
              maximumDurationSeconds.isFinite, maximumDurationSeconds > 0,
              sourceAssertion.map({ !$0.id.isEmpty && $0.revision >= 0 && !$0.provenance.isEmpty }) ?? true
        else { throw SequenceProbeError.invalid("Invalid explicit policy") }
    }
}
struct ProbeLabels: Codable {
    struct Group: Codable { let id: String; let kind: SequenceKind; let assetIDs: [String] }
    struct Negative: Codable { let from: String; let to: String }
    let schemaVersion: Int
    let role: String
    let groups: [Group]
    let negativePairs: [Negative]
    func validate(assetIDs: [String]) throws {
        let allowed = Set(assetIDs)
        let ordinals = Dictionary(uniqueKeysWithValues: assetIDs.enumerated().map { ($0.element, $0.offset) })
        var used = Set<String>(), groupIDs = Set<String>(), negatives = Set<String>()
        guard schemaVersion == 1, !role.isEmpty else { throw SequenceProbeError.invalid("Invalid labels") }
        for group in groups {
            guard !group.id.isEmpty, groupIDs.insert(group.id).inserted, group.assetIDs.count >= 2,
                  Set(group.assetIDs).count == group.assetIDs.count, Set(group.assetIDs).isSubset(of: allowed),
                  used.isDisjoint(with: group.assetIDs) else { throw SequenceProbeError.invalid("Invalid complete-group label") }
            used.formUnion(group.assetIDs)
        }
        for pair in negativePairs {
            let key = [pair.from, pair.to].sorted().joined(separator: "\0")
            guard pair.from != pair.to, allowed.contains(pair.from), allowed.contains(pair.to),
                  abs(ordinals[pair.from]! - ordinals[pair.to]!) == 1, negatives.insert(key).inserted,
                  !groups.contains(where: { $0.assetIDs.contains(pair.from) && $0.assetIDs.contains(pair.to) })
            else { throw SequenceProbeError.invalid("Negative labels must be explicit manifest-adjacent, unique and noncontradictory") }
        }
    }
}
