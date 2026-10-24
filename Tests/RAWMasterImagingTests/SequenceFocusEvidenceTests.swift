import XCTest
import Foundation
import RAWMasterCore
@testable import RAWMasterImaging

final class SequenceFocusEvidenceTests: XCTestCase {
    private let current = String(repeating: "a", count: 64), original = String(repeating: "b", count: 64)
    private let lineage = String(repeating: "c", count: 64), metadataSHA = String(repeating: "d", count: 64)
    private func fixture(audited: Bool = true) throws -> (SequenceInputManifest, SequenceMetadataSnapshot, [String: Any]) {
        let entry = SequenceManifestEntry(assetID: "asset0000", ordinal: 0, contentHash: current)
        let manifest = try SequenceInputManifest(scopeID: "focus-unit", sessionID: "focus-unit", orderVersion: SequenceBaseOrder.version, entries: [entry])
        let evidence = SequenceCaptureEvidence(assetID: entry.assetID, contentHash: original,
            extractorVersion: SequenceMetadataEvidenceLoader.originalExtractor,
            time: SequenceTimestampParser.parse(original: "2026:10:02 12:00:00", subseconds: "001", offset: "+08:00"),
            cameraMake: "SONY", cameraModel: audited ? "ILCE-1M2" : "ILCE-7RM5")
        let file = SequenceMetadataFileEvidence(assetID: entry.assetID, currentSHA256: current, originalSHA256: original,
            auditSeal: lineage, keyID: lineage, originalFormat: .arw, originalCapture: evidence,
            fieldStates: [:], resolvedNumbers: [:], opaqueCandidates: [:])
        let metadata = SequenceMetadataSnapshot(auditSeal: lineage, fingerprint: metadataSHA, v1IndexSHA256: lineage, caseManifestSHA256: lineage, files: [file])
        var states = Dictionary(uniqueKeysWithValues: SequenceFocusSnapshot.allFields.map { ($0, "present") })
        states["exif.SubjectDistance"] = "absent"
        let codes = Dictionary(uniqueKeysWithValues: SequenceFocusSnapshot.codeFields.map { ($0, 3) })
        let tuples = ["sony.FocusLocation": [8640, 5760, 3000, 2000], "sony.FocusLocation2": [8640, 5760, 3000, 2000],
            "sony.FocusFrameSize": [100, 80, 0], "sony.FlexibleSpotPosition": [320, 240]]
        let sources = Dictionary(uniqueKeysWithValues: SequenceFocusSnapshot.allFields.map { field -> (String, [String]) in
            let tag = field.split(separator: ".").last!
            return (field, field == "exif.SubjectDistance" ? [] : ["MakerNotes:Sony:" + String(tag)])
        })
        let row: [String: Any] = ["assetID": entry.assetID, "ordinal": 0, "currentSHA256": current, "originalSHA256": original,
            "state": audited ? "audited" : "outsideAuditedCohort", "fieldStates": audited ? states : [:],
            "resolvedCodes": audited ? codes : [:], "resolvedTuples": audited ? tuples : [:],
            "qualifiedFieldSources": audited ? sources : [:], "auditWarningCount": audited ? (0 as Any) : NSNull()]
        let dto: [String: Any] = ["schemaVersion": 1, "recipeVersion": SequenceFocusEvidenceLoader.recipeVersion, "caseID": "unit",
            "focusAuditSeal": SequenceFocusEvidenceLoader.acceptedAuditSeal, "focusRowsSHA256": SequenceFocusEvidenceLoader.acceptedRowsSHA256,
            "focusRegistrySHA256": SequenceFocusEvidenceLoader.acceptedRegistrySHA256, "normalizerVersion": SequenceFocusEvidenceLoader.normalizerVersion,
            "metadataV2IndexSHA256": SequenceFocusEvidenceLoader.metadataV2IndexSHA256, "metadataSnapshotFingerprint": metadataSHA,
            "v1IndexSHA256": lineage, "caseManifestSHA256": lineage, "files": [row]]
        return (manifest, metadata, dto)
    }
    private func load(_ object: [String: Any], manifest: SequenceInputManifest, metadata: SequenceMetadataSnapshot,
                      audited: Bool, indexCaseSHA256: String? = nil) throws -> SequenceFocusSnapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try bytes.write(to: root.appendingPathComponent("case.json"))
        let item = SequenceFocusFixtureIndex.Case(id: "unit", assetCount: 1, auditedAssetCount: audited ? 1 : 0,
            path: "case.json", sha256: SequenceMetadataEvidenceLoader.sha256(bytes), metadataSnapshotFingerprint: metadataSHA, caseManifestSHA256: lineage)
        let authorized = SequenceFocusFixtureIndex.Case(id: item.id, assetCount: item.assetCount, auditedAssetCount: item.auditedAssetCount,
            path: item.path, sha256: indexCaseSHA256 ?? item.sha256, metadataSnapshotFingerprint: item.metadataSnapshotFingerprint, caseManifestSHA256: item.caseManifestSHA256)
        let index = SequenceFocusFixtureIndex(schemaVersion: 1, datasetID: SequenceFocusEvidenceLoader.datasetID,
            recipeVersion: SequenceFocusEvidenceLoader.recipeVersion, focusAuditSeal: SequenceFocusEvidenceLoader.acceptedAuditSeal,
            focusRowsSHA256: SequenceFocusEvidenceLoader.acceptedRowsSHA256, focusRegistrySHA256: SequenceFocusEvidenceLoader.acceptedRegistrySHA256,
            normalizerVersion: SequenceFocusEvidenceLoader.normalizerVersion, metadataV2IndexSHA256: SequenceFocusEvidenceLoader.metadataV2IndexSHA256,
            v1IndexSHA256: lineage, assetCount: 1, auditedAssetCount: audited ? 1 : 0, outsideAuditedCohortCount: audited ? 0 : 1, cases: [authorized])
        return try SequenceFocusEvidenceLoader.loadCase(item, index: index, focusRoot: root, metadata: metadata, manifest: manifest)
    }
    func testAuditedFocusBindsBothContentsAndPreservesUninterpretedValidity() throws {
        let (manifest, metadata, dto) = try fixture()
        let focus = try load(dto, manifest: manifest, metadata: metadata, audited: true)
        XCTAssertEqual(focus.files[0].originalSHA256, original); XCTAssertEqual(focus.files[0].currentSHA256, current)
        XCTAssertEqual(focus.files[0].resolvedTuples["sony.FocusFrameSize"], [100, 80, 0])
        XCTAssertEqual(focus.files[0].fieldStates["exif.SubjectDistance"], .absent)
        XCTAssertEqual(focus.metadataSnapshotFingerprint, metadata.fingerprint)
        XCTAssertNotEqual(try focus.boundFingerprint(manifest: manifest, metadata: metadata), focus.fingerprint)
        XCTAssertEqual(metadata.files[0].originalCapture.time.subsecondsRaw, "001")
    }
    func testMissingConflictingPromotedOrStaleFocusFactsAreRejected() throws {
        let (manifest, metadata, dto) = try fixture()
        for change in ["missing-state", "conflicting-promoted", "bad-tuple", "wrong-current", "wrong-original", "wrong-scope", "wrong-source"] {
            var object = dto, files = try XCTUnwrap(dto["files"] as? [[String: Any]])
            var row = files[0]
            switch change {
            case "missing-state":
                var states = row["fieldStates"] as! [String: String]; states.removeValue(forKey: "sony.FocusMode"); row["fieldStates"] = states
            case "conflicting-promoted":
                var states = row["fieldStates"] as! [String: String]; states["sony.FocusMode"] = "conflicting"; row["fieldStates"] = states
            case "bad-tuple":
                var values = row["resolvedTuples"] as! [String: [Int]]; values["sony.FocusLocation"] = [8640, 5760, 65536, 2]; row["resolvedTuples"] = values
            case "wrong-current": row["currentSHA256"] = original
            case "wrong-original": row["originalSHA256"] = current
            case "wrong-scope": object["metadataSnapshotFingerprint"] = lineage
            default:
                var sources = row["qualifiedFieldSources"] as! [String: [String]]; sources["sony.FocusMode"] = ["MakerNotes:Sony:Unrequested:FocusMode"]; row["qualifiedFieldSources"] = sources
            }
            files[0] = row; object["files"] = files
            XCTAssertThrowsError(try load(object, manifest: manifest, metadata: metadata, audited: true), change)
        }
    }
    func testCaseIdentityMustBeAuthorizedByTheVerifiedIndex() throws {
        let (manifest, metadata, dto) = try fixture()
        XCTAssertThrowsError(try load(dto, manifest: manifest, metadata: metadata, audited: true, indexCaseSHA256: lineage))
    }
    func testOutsideAuditedCohortCannotCarryFactsOrNewVerificationClaim() throws {
        let (manifest, metadata, dto) = try fixture(audited: false)
        let focus = try load(dto, manifest: manifest, metadata: metadata, audited: false)
        XCTAssertEqual(focus.files[0].state, .outsideAuditedCohort)
        XCTAssertTrue(focus.files[0].fieldStates.isEmpty)
        for change in ["fieldStates", "auditWarningCount"] {
            var object = dto, files = dto["files"] as! [[String: Any]]
            files[0][change] = change == "fieldStates" ? (["sony.FocusMode": "absent"] as Any) : (0 as Any)
            object["files"] = files
            XCTAssertThrowsError(try load(object, manifest: manifest, metadata: metadata, audited: false))
        }
    }
}
