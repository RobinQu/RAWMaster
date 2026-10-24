import Foundation
import RAWMasterCore

public struct SequenceCaptureMember: Codable, Sendable, Equatable {
    public let assetID, currentSHA256, originalSHA256: String
    public let ordinal, contentVersion: Int
    public init(assetID: String, currentSHA256: String, originalSHA256: String, ordinal: Int, contentVersion: Int) {
        self.assetID = assetID; self.currentSHA256 = currentSHA256; self.originalSHA256 = originalSHA256
        self.ordinal = ordinal; self.contentVersion = contentVersion
    }
}
public struct SequenceConfirmedCapturePair: Codable, Sendable, Equatable {
    public let captureID, confirmationSource, scopeSnapshotFingerprint: String
    public let confirmationRevision: Int
    public let members: [SequenceCaptureMember]
    public init(captureID: String, confirmationSource: String, scopeSnapshotFingerprint: String,
                confirmationRevision: Int, members: [SequenceCaptureMember]) {
        self.captureID = captureID; self.confirmationSource = confirmationSource
        self.scopeSnapshotFingerprint = scopeSnapshotFingerprint; self.confirmationRevision = confirmationRevision; self.members = members
    }
}
public enum SequenceAssociationPolicy: String, Codable, Sendable { case strict, assumeCorroborated }
public enum SequenceMetadataRescuePolicy: String, Codable, Sendable { case continuationOnly, allowShortRestart }
public enum SequenceCaptureEventBasis: String, Codable, Sendable { case singleton, confirmed, assumed }
public struct SequenceCaptureFileInput: Sendable {
    public let entry: SequenceManifestEntry
    public let currentEvidence: SequenceCaptureEvidence?
    public let metadata: SequenceMetadataFileEvidence
    public let contentVersion: Int
    public let feature: SequenceFrameFeature?
    public let readBarrier: SequenceReason?
    public init(entry: SequenceManifestEntry, currentEvidence: SequenceCaptureEvidence?, metadata: SequenceMetadataFileEvidence,
                contentVersion: Int, feature: SequenceFrameFeature?, readBarrier: SequenceReason? = nil) {
        self.entry = entry; self.currentEvidence = currentEvidence; self.metadata = metadata
        self.contentVersion = contentVersion; self.feature = feature; self.readBarrier = readBarrier
    }
    public var member: SequenceCaptureMember {
        SequenceCaptureMember(assetID: entry.assetID, currentSHA256: metadata.currentSHA256,
            originalSHA256: metadata.originalSHA256, ordinal: entry.ordinal, contentVersion: contentVersion)
    }
}
public struct SequenceCaptureProposal: Codable, Sendable, Equatable {
    public let proposalID, scopeSnapshotFingerprint: String
    public let members: [SequenceCaptureMember]
    public let evidenceCodes: [String]
    public init(proposalID: String, scopeSnapshotFingerprint: String, members: [SequenceCaptureMember], evidenceCodes: [String]) {
        self.proposalID = proposalID; self.scopeSnapshotFingerprint = scopeSnapshotFingerprint
        self.members = members; self.evidenceCodes = evidenceCodes
    }
}
public struct SequenceCaptureEvent: Codable, Sendable, Equatable {
    public let eventID: String
    public let eventOrdinal: Int
    public let members: [SequenceCaptureMember]
    public let representativeAssetID: String
    public let basis: SequenceCaptureEventBasis
    public let proofID: String?
    public init(eventID: String, eventOrdinal: Int, members: [SequenceCaptureMember], representativeAssetID: String,
                basis: SequenceCaptureEventBasis, proofID: String?) {
        self.eventID = eventID; self.eventOrdinal = eventOrdinal; self.members = members
        self.representativeAssetID = representativeAssetID; self.basis = basis; self.proofID = proofID
    }
}
public struct SequenceCaptureEventMap: Codable, Sendable, Equatable {
    public let events: [SequenceCaptureEvent]
    public let fileToEvent: [Int]
    public let proposals: [SequenceCaptureProposal]
    public let fingerprint, scopeSnapshotFingerprint: String
    public let associationHypothesisAssumed: Bool
    public init(events: [SequenceCaptureEvent], fileToEvent: [Int], proposals: [SequenceCaptureProposal],
                fingerprint: String, scopeSnapshotFingerprint: String, associationHypothesisAssumed: Bool) {
        self.events = events; self.fileToEvent = fileToEvent; self.proposals = proposals; self.fingerprint = fingerprint
        self.scopeSnapshotFingerprint = scopeSnapshotFingerprint; self.associationHypothesisAssumed = associationHypothesisAssumed
    }
    public func validate(files: [SequenceCaptureFileInput], manifest: SequenceInputManifest, metadata: SequenceMetadataSnapshot,
                         confirmedPairs: [SequenceConfirmedCapturePair], policy: SequenceAssociationPolicy) throws {
        let expected = try SequenceCaptureEvents.make(files: files, manifest: manifest, metadata: metadata,
            confirmedPairs: confirmedPairs, policy: policy)
        guard self == expected else { throw SequenceMetadataError.invalid("Capture event map is stale, forged or incomplete") }
    }
}
public enum SequenceMetadataError: Error, Equatable { case invalid(String) }

public enum SequenceCaptureEvents {
    public static let version = "capture-events-corroborated-v1"
    static let deviceFields: Set<String> = ["exif.SerialNumber", "exif.CameraSerialNumber", "sony.SerialNumber", "sony.InternalSerialNumber", "dji.SensorID"]
    static let settingFields = ["exif.ExposureTime", "exif.ISO", "exif.FNumber", "exif.FocalLength", "exif.ExposureProgram"]
    struct Scope: Encodable {
        let version: String
        let manifest: SequenceInputManifest
        let metadata: SequenceMetadataSnapshot
        let versions: [Int]
        let evidence: [SequenceCaptureEvidence?]
        let barriers: [SequenceReason?]
        let features: [Bool]
    }
    public static func scopeSnapshotFingerprint(files: [SequenceCaptureFileInput], manifest: SequenceInputManifest,
                                                 metadata: SequenceMetadataSnapshot) throws -> String {
        try SequenceFingerprint.digest(Scope(version: version, manifest: manifest, metadata: metadata,
            versions: files.map(\.contentVersion), evidence: files.map(\.currentEvidence),
            barriers: files.map(\.readBarrier), features: files.map { $0.feature != nil }))
    }
    static func canonicalCamera(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    private static func canonicalDecimal(_ text: String) -> String? {
        guard text.utf8.count <= 256,
              text.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[Ee][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil else { return nil }
        var unsigned = text.lowercased()
        let negative = unsigned.first == "-"
        if unsigned.first == "+" || negative { unsigned.removeFirst() }
        let parts = unsigned.split(separator: "e", omittingEmptySubsequences: false)
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let fractionCount = mantissa.count == 2 ? mantissa[1].count : 0
        var digits = mantissa.joined()
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return "0" }
        var trailingZeros = 0
        while digits.last == "0" { digits.removeLast(); trailingZeros += 1 }
        // Decimal has finite precision. Never let its parser round different facts equal.
        guard digits.count <= 38 else { return nil }
        let (fractionAdjusted, underflow) = exponent.subtractingReportingOverflow(fractionCount)
        let (power, overflow) = fractionAdjusted.addingReportingOverflow(trailingZeros)
        guard !underflow, !overflow else { return nil }
        return (negative ? "-" : "") + digits + "e" + String(power)
    }
    static func decimal(_ text: String?) -> Decimal? {
        guard let text, let exact = canonicalDecimal(text),
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: value).doubleValue.isFinite,
              canonicalDecimal(NSDecimalNumber(decimal: value).stringValue) == exact else { return nil }
        return value
    }
    static func isRaw(_ format: SequenceOriginalFormat) -> Bool { format == .arw || format == .dng }
    static func checkCancellation(_ cancelled: () -> Bool) throws { if Task.isCancelled || cancelled() { throw CancellationError() } }
    static func fileIssue(_ file: SequenceCaptureFileInput) -> SequenceReason? {
        // A persistent protection marker must not turn a transient read failure into
        // checked insufficiency. The original entry still retains its protection.
        let barriers = [file.entry.barrier, file.readBarrier].compactMap { $0 }
        for transient in [SequenceReason.incomplete, .unreadable, .missingEmbeddedPreview] {
            if barriers.contains(transient) { return transient }
        }
        guard let current = file.currentEvidence else { return .unreadable }
        guard file.feature != nil else { return .missingEmbeddedPreview }
        if let issue = file.entry.barrier ?? file.readBarrier { return issue }
        guard current.time.isConsistent, current.time.local != nil else { return .invalidTimestamp }
        let original = file.metadata.originalCapture
        guard original.time.isConsistent, original.time.local != nil else { return .invalidTimestamp }
        guard current.time.local == original.time.local else { return .invalidTimestamp }
        if let offset = current.time.offsetMinutes, offset != original.time.offsetMinutes { return .invalidClockPartition }
        if let a = canonicalCamera(current.cameraMake), let b = canonicalCamera(original.cameraMake), a != b { return .assertionMismatch }
        if let a = canonicalCamera(current.cameraModel), let b = canonicalCamera(original.cameraModel), a != b { return .assertionMismatch }
        if let a = current.exposureSeconds, let b = original.exposureSeconds {
            guard a.isFinite, b.isFinite, a > 0, b > 0, abs(a-b) <= max(1e-8, abs(b)*1e-6) else { return .contentMismatch }
        } else if current.exposureSeconds != nil || original.exposureSeconds != nil { return .insufficientEvidence }
        return nil
    }
    static func validateFiles(_ files: [SequenceCaptureFileInput], _ manifest: SequenceInputManifest,
                              _ metadata: SequenceMetadataSnapshot) throws {
        try metadata.validateBindings(manifest: manifest)
        guard files.count == manifest.entries.count, files.count <= 30_000 else { throw SequenceMetadataError.invalid("Metadata file scope incomplete or too large") }
        try metadata.runtimeProof?.validateInputs(files: files)
        var profiles: [String: (Set<String>, Set<String>)] = [:]
        var devices: [String: [String: Set<String>]] = [:]
        for (ordinal, file) in files.enumerated() {
            guard file.entry == manifest.entries[ordinal], file.metadata == metadata.files[ordinal], file.contentVersion >= 0,
                  file.metadata.assetID == file.entry.assetID,
                  (file.metadata.originalFormat != .unknown || metadata.runtimeProof != nil),
                  file.metadata.keyID == metadata.files.first?.keyID,
                  file.metadata.originalCapture.extractorVersion == (metadata.runtimeProof == nil ? SequenceMetadataEvidenceLoader.originalExtractor : SequenceRuntimeMetadataProof.extractorVersion),
                  file.metadata.originalCapture.assetID == file.entry.assetID,
                  file.metadata.originalCapture.contentHash == file.metadata.originalSHA256,
                  file.entry.contentHash.map({ $0 == file.metadata.currentSHA256 }) ?? (file.entry.barrier != nil || file.readBarrier != nil),
                  file.currentEvidence.map({ $0.assetID == file.entry.assetID && $0.contentHash == file.metadata.currentSHA256 && $0.evidenceRevision == file.entry.evidenceRevision }) ?? true
            else { throw SequenceMetadataError.invalid("Current/audited file identity or order mismatch") }
            guard let camera = file.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint) else { continue }
            var profile = profiles[camera] ?? ([], [])
            for evidence in [file.currentEvidence, file.metadata.originalCapture] {
                if let make = canonicalCamera(evidence?.cameraMake) { profile.0.insert(make) }
                if let model = canonicalCamera(evidence?.cameraModel) { profile.1.insert(model) }
            }
            profiles[camera] = profile
            for field in deviceFields where file.metadata.fieldStates[field] == .present {
                if let value = file.metadata.opaqueCandidates[field] {
                    devices[camera, default: [:]][file.metadata.keyID+":"+field, default: []].insert(value)
                }
            }
        }
        guard profiles.values.allSatisfy({ $0.0.count <= 1 && $0.1.count <= 1 }),
              devices.values.allSatisfy({ $0.values.allSatisfy({ $0.count <= 1 }) })
        else { throw SequenceMetadataError.invalid("Full-source metadata contradicts the declared camera scope") }
    }
    struct Bucket: Hashable {
        let camera: String
        let second: Int64
        let offset: Int?
    }
    struct EventIdentity: Encodable { let scope, version, basis, proof: String; let ids: [String] }
    struct MapIdentity: Encodable {
        let version, scope: String
        let policy: SequenceAssociationPolicy
        let events: [SequenceCaptureEvent]
        let proposals: [SequenceCaptureProposal]
        let confirmations: [SequenceConfirmedCapturePair]
    }
    public static func make(files: [SequenceCaptureFileInput], manifest: SequenceInputManifest, metadata: SequenceMetadataSnapshot,
                            confirmedPairs: [SequenceConfirmedCapturePair], policy: SequenceAssociationPolicy,
                            cancelled: () -> Bool = { false }) throws -> SequenceCaptureEventMap {
        try validateFiles(files, manifest, metadata)
        let scope = try scopeSnapshotFingerprint(files: files, manifest: manifest, metadata: metadata)
        var buckets: [Bucket: [Int]] = [:]
        for file in files {
            try checkCancellation(cancelled)
            let time = file.metadata.originalCapture.time
            if let camera = file.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint),
               time.isConsistent, let local = time.local {
                buckets[Bucket(camera: camera, second: local.civilSecond, offset: time.offsetMinutes), default: []].append(file.entry.ordinal)
            }
        }
        var proposals: [SequenceCaptureProposal] = []
        for indices in buckets.values where indices.count == 2 {
            try checkCancellation(cancelled)
            let a = files[indices[0]], b = files[indices[1]]
            guard indices[1] == indices[0]+1, fileIssue(a) == nil, fileIssue(b) == nil,
                  (isRaw(a.metadata.originalFormat) && b.metadata.originalFormat == .jpeg)
                    || (isRaw(b.metadata.originalFormat) && a.metadata.originalFormat == .jpeg),
                  a.metadata.currentSHA256 != b.metadata.currentSHA256, a.metadata.originalSHA256 != b.metadata.originalSHA256,
                  a.metadata.originalCapture.time.local == b.metadata.originalCapture.time.local,
                  a.metadata.originalCapture.time.subsecondDigits == b.metadata.originalCapture.time.subsecondDigits,
                  a.currentEvidence?.time.offsetMinutes == b.currentEvidence?.time.offsetMinutes,
                  a.metadata.keyID == b.metadata.keyID else { continue }
            let common = deviceFields.filter { a.metadata.fieldStates[$0] == .present && b.metadata.fieldStates[$0] == .present
                && a.metadata.opaqueCandidates[$0] != nil && b.metadata.opaqueCandidates[$0] != nil }
            guard !common.isEmpty, common.allSatisfy({ a.metadata.opaqueCandidates[$0] == b.metadata.opaqueCandidates[$0] }),
                  settingFields.allSatisfy({ field in
                      a.metadata.fieldStates[field] == .present && b.metadata.fieldStates[field] == .present
                        && decimal(a.metadata.resolvedNumbers[field]) != nil
                        && decimal(a.metadata.resolvedNumbers[field]) == decimal(b.metadata.resolvedNumbers[field])
                  }) else { continue }
            let members = [a.member, b.member]
            let id = try SequenceFingerprint.digest(EventIdentity(scope: manifest.scopeID, version: version,
                basis: "proposal", proof: scope, ids: members.map(\.assetID)))
            proposals.append(SequenceCaptureProposal(proposalID: id, scopeSnapshotFingerprint: scope, members: members,
                evidenceCodes: ["declared-camera-scope", "two-member-full-scope-time-bucket", "native-raw-jpeg", "five-exact-settings", "common-device-candidates-not-capture-identity"]))
        }
        proposals.sort { $0.members[0].ordinal < $1.members[0].ordinal }
        var pairs: [Int: (members: [SequenceCaptureMember], basis: SequenceCaptureEventBasis, proof: String)] = [:]
        var used = Set<Int>(), confirmationIDs = Set<String>()
        for pair in confirmedPairs.sorted(by: { $0.captureID < $1.captureID }) {
            try checkCancellation(cancelled)
            let members = pair.members.sorted { $0.ordinal < $1.ordinal }
            guard !pair.captureID.isEmpty, !pair.confirmationSource.isEmpty, pair.confirmationRevision >= 0,
                  pair.scopeSnapshotFingerprint == scope, confirmationIDs.insert(pair.captureID).inserted,
                  members.count == 2, members[1].ordinal == members[0].ordinal+1,
                  members.allSatisfy({ files.indices.contains($0.ordinal) && files[$0.ordinal].member == $0 && !used.contains($0.ordinal) })
            else { throw SequenceMetadataError.invalid("Stale, overlapping or invalid confirmed capture pair") }
            let a = files[members[0].ordinal], b = files[members[1].ordinal]
            guard fileIssue(a) == nil, fileIssue(b) == nil, a.metadata.originalSHA256 != b.metadata.originalSHA256,
                  (isRaw(a.metadata.originalFormat) && b.metadata.originalFormat == .jpeg)
                    || (isRaw(b.metadata.originalFormat) && a.metadata.originalFormat == .jpeg),
                  a.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint) != nil,
                  a.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint) == b.entry.camera.partitionID(manifestFingerprint: manifest.contentFingerprint),
                  a.currentEvidence?.time.local == b.currentEvidence?.time.local,
                  a.currentEvidence?.time.offsetMinutes == b.currentEvidence?.time.offsetMinutes,
                  a.metadata.originalCapture.time.offsetMinutes == b.metadata.originalCapture.time.offsetMinutes
            else { throw SequenceMetadataError.invalid("Confirmed pair crosses a source, format, time or read barrier") }
            pairs[members[0].ordinal] = (members, .confirmed, pair.captureID+":"+String(pair.confirmationRevision))
            used.formUnion(members.map(\.ordinal))
        }
        if policy == .assumeCorroborated {
            for proposal in proposals where proposal.members.allSatisfy({ !used.contains($0.ordinal) }) {
                pairs[proposal.members[0].ordinal] = (proposal.members, .assumed, proposal.proposalID)
                used.formUnion(proposal.members.map(\.ordinal))
            }
        }
        var events: [SequenceCaptureEvent] = [], mapping: [Int] = [], ordinal = 0
        while ordinal < files.count {
            try checkCancellation(cancelled)
            let pair = pairs[ordinal]
            let members = pair?.members ?? [files[ordinal].member]
            let basis = pair?.basis ?? .singleton
            let proof = pair?.proof ?? "singleton"
            let representative = members.first(where: { isRaw(files[$0.ordinal].metadata.originalFormat) }) ?? members[0]
            let eventID = try SequenceFingerprint.digest(EventIdentity(scope: manifest.scopeID, version: version,
                basis: basis.rawValue, proof: proof, ids: members.map(\.assetID)))
            events.append(SequenceCaptureEvent(eventID: eventID, eventOrdinal: events.count, members: members,
                representativeAssetID: representative.assetID, basis: basis, proofID: pair?.proof))
            mapping.append(contentsOf: repeatElement(events.count-1, count: members.count))
            ordinal += members.count
        }
        let fingerprint = try SequenceFingerprint.digest(MapIdentity(version: version, scope: scope, policy: policy,
            events: events, proposals: proposals, confirmations: confirmedPairs.sorted { $0.captureID < $1.captureID }))
        return SequenceCaptureEventMap(events: events, fileToEvent: mapping, proposals: proposals, fingerprint: fingerprint,
            scopeSnapshotFingerprint: scope, associationHypothesisAssumed: events.contains { $0.basis == .assumed })
    }
}
