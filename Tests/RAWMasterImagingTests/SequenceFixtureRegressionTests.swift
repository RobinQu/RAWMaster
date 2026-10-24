import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequenceFixtureRegressionTests: XCTestCase {
    func testFullOfflineDataset() throws {
        let environment = ProcessInfo.processInfo.environment
        let requireQuality = environment["RAWMASTER_SEQUENCE_FIXTURE_REQUIRE_QUALITY"] == "1"
        let candidatePath = environment["RAWMASTER_SEQUENCE_FIXTURE_RECORD_CANDIDATE"]
        guard !(requireQuality && candidatePath != nil) else { throw SequenceFixtureError.invalid("Cannot record and require quality in one run") }
        let runID = environment["RAWMASTER_SEQUENCE_FIXTURE_RUN_ID"] ?? UUID().uuidString
        let fixtureRoot = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/SequenceGrouping/v1", isDirectory: true)
        let (index, indexData) = try SequenceFixtureHarness.loadIndex(root: fixtureRoot)
        var behaviors: [SequenceFixtureCaseBehavior] = []
        for item in index.cases {
            let value = try autoreleasepool { try SequenceFixtureHarness.runCase(item, datasetRoot: fixtureRoot, recipe: index.recipe) }
            behaviors.append(value)
            print("JPEG fixture \(value.id): native integrity PASS; human quality \(value.qualityAccepted ? "PASS" : "UNMET"); TP=\(value.evaluation.truePositive), FP=\(value.evaluation.falsePositive), FN=\(value.evaluation.falseNegative); evidence limitations=\(value.evidenceLimitations)")
        }
        let baseline = SequenceFixtureBaseline(datasetID: index.datasetID, indexSHA256: SequenceProbeRun.sha256(indexData),
            referencePlatform: SequenceFixturePlatform(), cases: behaviors)
        let referencePlatform: String
        let behaviorValidated: Bool
        if let candidatePath {
            try SequenceFixtureHarness.write(baseline, to: candidatePath, outside: fixtureRoot)
            referencePlatform = "unapproved candidate; current platform recorded in candidate file"
            behaviorValidated = false
            print("Wrote unapproved JPEG behavior candidate to \(candidatePath); no human-quality acceptance implied")
        } else {
            let baselineURL = try SequenceFixtureFiles.resolve(SequenceFixtureHarness.baselineRelativePath, root: fixtureRoot)
            referencePlatform = try SequenceFixtureHarness.assertBaseline(Data(contentsOf: baselineURL), current: baseline)
            behaviorValidated = true
        }
        let report = SequenceFixtureReport(runID: runID, mode: candidatePath != nil ? "candidate" : requireQuality ? "quality" : "regression",
            datasetID: index.datasetID, indexSHA256: baseline.indexSHA256, integrityValidated: true,
            behaviorValidated: behaviorValidated, qualityAccepted: behaviors.allSatisfy(\.qualityAccepted),
            platform: SequenceFixturePlatform(), referencePlatform: referencePlatform, cases: behaviors)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reportPath = environment["RAWMASTER_SEQUENCE_FIXTURE_REPORT"] ?? repository.appendingPathComponent("output/validation/sequence-fixtures-regression.json").path
        // No report claiming a completed evaluation is emitted until all integrity and baseline checks pass.
        try SequenceFixtureHarness.write(report, to: reportPath, outside: fixtureRoot)
        XCTAssertEqual(behaviors.count, 6)
        XCTAssertEqual(behaviors.reduce(0) { $0 + $1.assetCount }, 1265)
        if requireQuality {
            for item in behaviors where !item.qualityAccepted {
                XCTFail("Human quality unmet for \(item.id): classification=\(item.classificationFailures); evidence=\(item.evidenceLimitations). Report: \(reportPath)")
            }
        }
    }
}

final class SequenceFixtureSchemaTests: XCTestCase {
    func testUnsafePathsAndMissingExplicitNullableMetadataAreRejected() throws {
        for value in ["/Volumes/source.jpg", "../source.jpg", "a/../b", "a//b", "a\\b", "a/./b", ""] {
            XCTAssertThrowsError(try SequenceFixtureFiles.validateRelativePath(value))
        }
        let explicit = Data(#"{"dateTimeOriginalRaw":null,"subsecTimeOriginalRaw":null,"offsetTimeOriginalRaw":null,"exposureSeconds":null,"cameraMake":null,"cameraModel":null,"orientation":1}"#.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(SequenceFixtureMetadata.Capture.self, from: explicit))
        var values = try JSONSerialization.jsonObject(with: explicit) as! [String: Any]
        values.removeValue(forKey: "offsetTimeOriginalRaw")
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceFixtureMetadata.Capture.self, from: JSONSerialization.data(withJSONObject: values)))
    }
    func testSidecarWhitelistRejectsPrivateFieldsAndAbsolutePaths() throws {
        let allowed: [String: Set<String>] = ["$root": ["name"]]
        XCTAssertNoThrow(try SequenceFixtureFiles.checkJSONWhitelist(Data(#"{"name":"relative.jpg"}"#.utf8), allowed: allowed, type: "synthetic"))
        for text in [#"{"name":"relative.jpg","serialNumber":"secret"}"#, #"{"name":"/Users/private/photo.jpg"}"#] {
            XCTAssertThrowsError(try SequenceFixtureFiles.checkJSONWhitelist(Data(text.utf8), allowed: allowed, type: "synthetic"))
        }
    }
    func testDJISeparateFormatAssetsCannotBeCollapsedOrReordered() throws {
        func manifest(reversed: Bool = false, duplicate: Bool = false) throws -> SequenceFixtureManifest {
            let digest = String(repeating: "a", count: 64)
            let files: [[String: Any]] = (0..<376).map { ordinal in
                let id = String(format: "asset%04d", duplicate && ordinal == 1 ? 0 : ordinal)
                let number = ordinal / 2 + 1
                let ext = (ordinal % 2 == 0) != reversed ? "DNG" : "JPG"
                return ["assetID": id, "ordinal": ordinal, "relativePath": "files/\(id).jpg", "jpegSHA256": digest,
                    "width": 1024, "height": 768,
                    "sourceCapture": ["relativePath": String(format: "DCIM/DJI_%04d.%@", number, ext), "originalExtension": ext, "sha256": digest]]
            }
            let object: [String: Any] = ["schemaVersion": 1, "scopeID": "synthetic", "sessionID": "synthetic", "orderVersion": SequenceBaseOrder.version, "files": files]
            return try JSONDecoder().decode(SequenceFixtureManifest.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let valid = try manifest()
        XCTAssertNoThrow(try valid.validate(expectedCount: 376))
        XCTAssertNoThrow(try SequenceFixtureHarness.validateDJIPairs(valid))
        XCTAssertThrowsError(try SequenceFixtureHarness.validateDJIPairs(manifest(reversed: true)))
        XCTAssertThrowsError(try manifest(duplicate: true).validate(expectedCount: 376))
    }
}
