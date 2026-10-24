import XCTest
import Foundation
import RAWMasterCore
@testable import RAWMasterImaging

final class SequenceMetadataEvidenceTests: XCTestCase {
    let current = String(repeating: "a", count: 64), original = String(repeating: "b", count: 64)
    let lineage = String(repeating: "c", count: 64), key = String(repeating: "d", count: 64)
    private func runtime(numbers: [String:String] = [:], states: [String:SequenceMetadataFieldState] = [:], opaque: [String:String] = [:], sourceHash: String? = nil) -> SequenceMetadataFileEvidence {
        let evidence = SequenceCaptureEvidence(assetID: "asset0000", contentHash: sourceHash ?? original,
            extractorVersion: SequenceMetadataEvidenceLoader.originalExtractor,
            time: SequenceTimestampParser.parse(original: "2026:10:02 12:12:13", subseconds: "001", offset: "+08:00"),
            cameraMake: "SONY", cameraModel: "ILCE-1M2", exposureSeconds: 0.01)
        return SequenceMetadataFileEvidence(assetID: "asset0000", currentSHA256: current, originalSHA256: original,
            auditSeal: lineage, keyID: key, originalFormat: .arw, originalCapture: evidence,
            fieldStates: states, resolvedNumbers: numbers, opaqueCandidates: opaque)
    }
    private func manifest() throws -> SequenceInputManifest {
        try SequenceInputManifest(scopeID: "unit", sessionID: "unit", orderVersion: SequenceBaseOrder.version,
            entries: [SequenceManifestEntry(assetID: "asset0000", ordinal: 0, contentHash: current)])
    }
    private func snapshot(_ file: SequenceMetadataFileEvidence) -> SequenceMetadataSnapshot {
        SequenceMetadataSnapshot(auditSeal: lineage, fingerprint: lineage, v1IndexSHA256: lineage, caseManifestSHA256: lineage, files: [file])
    }
    func testOriginalLineageNeverSubstitutesCurrentIdentityAndRetainsStrictPrecision() throws {
        let file = runtime()
        try snapshot(file).validateBindings(manifest: manifest())
        XCTAssertEqual(file.originalCapture.contentHash, original); XCTAssertNotEqual(file.originalCapture.contentHash,current)
        XCTAssertEqual(file.originalCapture.time.subsecondsRaw,"001")
        XCTAssertEqual(file.originalCapture.time.local?.nanosecond,1_000_000)
        XCTAssertEqual(file.originalCapture.time.offsetMinutes,480)
        XCTAssertNotNil(file.originalCapture.time.utcInstant)
        XCTAssertThrowsError(try snapshot(runtime(sourceHash:current)).validateBindings(manifest:manifest()))
        let wrong = try SequenceInputManifest(scopeID:"unit",sessionID:"unit",orderVersion:SequenceBaseOrder.version,
            entries:[SequenceManifestEntry(assetID:"asset0000",ordinal:0,contentHash:original)])
        XCTAssertThrowsError(try snapshot(file).validateBindings(manifest:wrong))
    }
    func testConflictingNumbersAndUnusableOrPlainPrivateCandidateCannotBePromoted() throws {
        XCTAssertThrowsError(try snapshot(runtime(numbers:["sony.SequenceNumber":"1"],states:["sony.SequenceNumber":.conflicting])).validateBindings(manifest:manifest()))
        XCTAssertThrowsError(try snapshot(runtime(numbers:["exif.SerialNumber":"123456"],states:["exif.SerialNumber":.present])).validateBindings(manifest:manifest()))
        XCTAssertThrowsError(try snapshot(runtime(numbers:["GPSLatitude":"20"],states:["GPSLatitude":.present])).validateBindings(manifest:manifest()))
        XCTAssertThrowsError(try snapshot(runtime(states:["exif.SerialNumber":.present],opaque:["exif.SerialNumber":"plain-private-value"])).validateBindings(manifest:manifest()))
        XCTAssertThrowsError(try snapshot(runtime(states:["exif.SerialNumber":.conflicting],opaque:["exif.SerialNumber":key])).validateBindings(manifest:manifest()))
        try snapshot(runtime(numbers:["exif.ExposureTime":"0.000001"],states:["exif.ExposureTime":.present,"exif.SerialNumber":.present],opaque:["exif.SerialNumber":key])).validateBindings(manifest:manifest())
    }
    func testNumericFactsRejectNonfiniteAndKeepExactDecimalText() throws {
        for invalid in ["NaN","inf","1_000","1x","1e99999"] {
            XCTAssertThrowsError(try snapshot(runtime(numbers:["exif.ISO":invalid],states:["exif.ISO":.present])).validateBindings(manifest:manifest()))
        }
        let exact = "0.123456789123456789"
        let file = runtime(numbers:["exif.ExposureTime":exact],states:["exif.ExposureTime":.present])
        try snapshot(file).validateBindings(manifest:manifest()); XCTAssertEqual(file.resolvedNumbers["exif.ExposureTime"],exact)
    }
    func testCuratedLoaderBindsExactBytesAndV1ProvenanceWithoutJPEGTimeRepair() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let v1=root.appendingPathComponent("v1"),v2=root.appendingPathComponent("v2")
        try FileManager.default.createDirectory(at:v1,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:v2,withIntermediateDirectories:true)
        let indexBytes=Data("{}".utf8);try indexBytes.write(to:v1.appendingPathComponent("index.json"))
        let v1Hash=SequenceMetadataEvidenceLoader.sha256(indexBytes)
        let manifestObject:[String:Any] = ["files":[["assetID":"asset0000","ordinal":0,"jpegSHA256":current,"sourceCapture":["sha256":original]]]]
        let manifestBytes=try JSONSerialization.data(withJSONObject:manifestObject,options:.sortedKeys)
        let manifestURL=v1.appendingPathComponent("manifest.json");try manifestBytes.write(to:manifestURL)
        let manifestHash=SequenceMetadataEvidenceLoader.sha256(manifestBytes)
        let states=Dictionary(uniqueKeysWithValues:SequenceMetadataEvidenceLoader.allFields.map { ($0,"absent") })
        let capture:[String:Any] = ["dateTimeOriginalRaw":"2026:10:02 12:12:13","subsecTimeOriginalRaw":"001","offsetTimeOriginalRaw":"+08:00","exposureSeconds":0.01,"cameraMake":"SONY","cameraModel":"ILCE-1M2","orientation":1]
        let file:[String:Any] = ["assetID":"asset0000","ordinal":0,"currentSHA256":current,"originalSHA256":original,"originalFormat":"arw","capture":capture,"fieldStates":states,"resolvedNumbers":[:],"opaqueCandidates":[:],"qualifiedFieldSources":[:],"auditWarningCount":0]
        let dto:[String:Any] = ["schemaVersion":2,"recipeVersion":SequenceMetadataEvidenceLoader.recipeVersion,"caseID":"unit","auditSeal":SequenceMetadataEvidenceLoader.acceptedAuditSeal,"auditRowsSHA256":lineage,"registrySHA256":lineage,"normalizerVersion":"qualified-parser-facts-v1.1","keyID":key,"v1IndexSHA256":v1Hash,"caseManifestSHA256":manifestHash,"files":[file]]
        let bytes=try JSONSerialization.data(withJSONObject:dto,options:.sortedKeys),caseURL=v2.appendingPathComponent("case.json")
        try bytes.write(to:caseURL);let caseHash=SequenceMetadataEvidenceLoader.sha256(bytes)
        let item=SequenceMetadataFixtureIndex.Case(id:"unit",assetCount:1,path:"case.json",sha256:caseHash,caseManifestSHA256:manifestHash)
        let index=SequenceMetadataFixtureIndex(schemaVersion:2,datasetID:SequenceMetadataEvidenceLoader.datasetID,recipeVersion:SequenceMetadataEvidenceLoader.recipeVersion,
            auditSeal:SequenceMetadataEvidenceLoader.acceptedAuditSeal,auditRowsSHA256:lineage,registrySHA256:lineage,normalizerVersion:"qualified-parser-facts-v1.1",v1IndexSHA256:v1Hash,assetCount:1,cases:[item])
        let loaded=try SequenceMetadataEvidenceLoader.loadCase(item,index:index,metadataRoot:v2,v1Root:v1,v1ManifestURL:manifestURL)
        XCTAssertEqual(loaded.fingerprint,caseHash);XCTAssertEqual(loaded.files[0].originalCapture.time.offsetMinutes,480)
        let nativeCurrent=SequenceCaptureEvidence(assetID:"asset0000",contentHash:current,extractorVersion:SequenceCaptureReader.extractorVersion,
            time:SequenceTimestampParser.parse(original:"2026:10:02 12:12:13",subseconds:"001",offset:nil))
        XCTAssertNil(nativeCurrent.time.offsetMinutes);XCTAssertEqual(try Data(contentsOf:manifestURL),manifestBytes)
        try Data("{}".utf8).write(to:caseURL)
        XCTAssertThrowsError(try SequenceMetadataEvidenceLoader.loadCase(item,index:index,metadataRoot:v2,v1Root:v1,v1ManifestURL:manifestURL))
    }
    func testMetadataPathCannotEscapeOrAliasExternalFile() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        for path in ["/etc/passwd","../outside","x/../y","x//y","x\\y"] { XCTAssertThrowsError(try SequenceMetadataEvidenceLoader.resolve(path,root:root)) }
        let alias=root.appendingPathComponent("alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root.deletingLastPathComponent())
        XCTAssertThrowsError(try SequenceMetadataEvidenceLoader.resolve("alias/outside",root:root))
    }
}
