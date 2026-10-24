import Foundation
import ImageIO
import Darwin
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

struct SequenceFixtureCaseBehavior: Encodable {
    let id: String
    let assetCount: Int
    let manifestSHA256, metadataSHA256, truthSHA256: String
    let policyFingerprint: String
    let result: SequenceAnalysisResult
    let evaluation: ProbeEvaluation
    let completeGroupTruth: Bool
    let unknownAssetIDs: [String]
    let integrityValidated: Bool
    let qualityAccepted: Bool
    let evidenceLimitations: [String]
    let classificationFailures: [String]
}
struct SequenceFixtureBaseline: Encodable {
    let schemaVersion = 1
    let datasetID: String
    let indexSHA256: String
    let referencePlatform: SequenceFixturePlatform
    let cases: [SequenceFixtureCaseBehavior]
}
struct SequenceFixturePlatform: Encodable {
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let architecture: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()
    let swift = ProcessInfo.processInfo.environment["RAWMASTER_SEQUENCE_FIXTURE_SWIFT_VERSION"] ?? "not-injected-by-direct-swift-test"
    let decoder = "ImageIO native SequenceCaptureReader"
    let imageIOBundleVersion = Bundle(identifier: "com.apple.ImageIO")?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "macOS system ImageIO"
}
struct SequenceFixtureReport: Encodable {
    let schemaVersion = 1
    let runID, mode, datasetID, indexSHA256: String
    let integrityValidated, behaviorValidated, qualityAccepted: Bool
    let platform: SequenceFixturePlatform
    let referencePlatform: String
    let qualityMeaning = "Strict human-label evaluation under user-declared single-source scopes; stable behavior does not imply quality acceptance or unseen validation."
    let cases: [SequenceFixtureCaseBehavior]
}

enum SequenceFixtureHarness {
    static let baselineRelativePath = "baselines/behavior-v1.json"
    static let captureKeys: Set<String> = ["dateTimeOriginalRaw", "subsecTimeOriginalRaw", "offsetTimeOriginalRaw", "exposureSeconds", "cameraMake", "cameraModel", "orientation"]
    static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func loadIndex(root: URL) throws -> (SequenceFixtureIndex, Data) {
        let data = try Data(contentsOf: SequenceFixtureFiles.resolve("index.json", root: root))
        try SequenceFixtureFiles.checkJSONWhitelist(data, allowed: [
            "$root": ["schemaVersion", "datasetID", "converterVersion", "assetCount", "recipe", "cases"],
            "recipe": ["maximumPixel", "jpegQuality", "colorSpace", "orientation", "rawMode", "exposureAbsoluteToleranceSeconds", "exposureRelativeTolerance"],
            "cases": ["id", "assetCount", "manifestPath", "metadataPath", "truthPath", "manifestSHA256", "metadataSHA256", "truthSHA256", "completeGroupTruth", "unknownAssetIDs"]
        ], type: "index")
        let value = try decode(SequenceFixtureIndex.self, data: data); try value.validate()
        return (value, data)
    }
    static func verifiedSidecar(_ relative: String, expectedHash: String, root: URL) throws -> (Data, URL) {
        let url = try SequenceFixtureFiles.resolve(relative, root: root)
        let data = try Data(contentsOf: url)
        guard SequenceProbeRun.sha256(data) == expectedHash else { throw SequenceFixtureError.invalid("Fixture sidecar hash mismatch: \(relative)") }
        return (data, url)
    }
    static func runCase(_ item: SequenceFixtureIndex.Case, datasetRoot: URL, recipe: SequenceFixtureIndex.Recipe) throws -> SequenceFixtureCaseBehavior {
        let (manifestData, manifestURL) = try verifiedSidecar(item.manifestPath, expectedHash: item.manifestSHA256, root: datasetRoot)
        try SequenceFixtureFiles.checkJSONWhitelist(manifestData, allowed: [
            "$root": ["schemaVersion", "scopeID", "sessionID", "orderVersion", "files"],
            "files": ["assetID", "ordinal", "relativePath", "jpegSHA256", "width", "height", "sourceCapture"],
            "sourceCapture": ["relativePath", "originalExtension", "sha256"]
        ], type: "manifest")
        let fixture = try decode(SequenceFixtureManifest.self, data: manifestData)
        try fixture.validate(expectedCount: item.assetCount)
        let description = try decode(ProbeManifest.self, data: manifestData); try description.validate()
        let caseRoot = manifestURL.deletingLastPathComponent()
        let physicalFiles = try FileManager.default.contentsOfDirectory(at: caseRoot.appendingPathComponent("files"), includingPropertiesForKeys: nil)
        guard physicalFiles.count == item.assetCount,
              Set(physicalFiles.map(\.lastPathComponent)) == Set(fixture.files.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent })
        else { throw SequenceFixtureError.invalid("Fixture physical JPEG inventory does not match full manifest") }
        let (metadataData, _) = try verifiedSidecar(item.metadataPath, expectedHash: item.metadataSHA256, root: datasetRoot)
        try SequenceFixtureFiles.checkJSONWhitelist(metadataData, allowed: [
            "$root": ["schemaVersion", "caseID", "assets"],
            "assets": ["assetID", "sourceCapture", "expectedJPEG", "exposureRoundtrip", "sourceIntegrity"],
            "sourceCapture": captureKeys, "expectedJPEG": captureKeys,
            "exposureRoundtrip": ["actualSeconds", "absoluteDifferenceSeconds", "allowedDifferenceSeconds"],
            "sourceIntegrity": ["sha256Before", "sha256After", "credentialUnchanged"]
        ], type: "metadata")
        let metadata = try decode(SequenceFixtureMetadata.self, data: metadataData)
        guard metadata.schemaVersion == 1, metadata.caseID == item.id, metadata.assets.count == fixture.files.count,
              metadata.assets.map(\.assetID) == fixture.files.map(\.assetID) else { throw SequenceFixtureError.invalid("Metadata asset order mismatch") }
        if item.id == "dji187-context376" { try validateDJIPairs(fixture) }
        let config = SequenceDetectorConfiguration()
        // Preserve the reviewed Probe protocol. Missing known negatives are evidence gaps, never invented labels.
        let minimumPositive = ["burst123": 122, "burst14-context38": 13, "burst48-context72": 47,
            "interval427-context439": 426, "burst193-context217": 192, "dji187-context376": 373][item.id]!
        let policy = ProbePolicy(schemaVersion: 2, detector: config,
            sourceAssertion: ProbeSourceAssertion(id: "fixture-declared-\(item.id)", revision: 0, declaredByUser: true,
                provenance: "User-declared single-source batch, checked against all derivative JPEG metadata; not native-device verification"),
            acceptance: ProbeAcceptance(minimumPositivePairs: minimumPositive, minimumRecall: 0.95, minimumTypedCoverage: 0.8,
                minimumExactGroupFraction: 1, minimumPrecision: 0.95, minimumNegativePairs: item.id == "interval427-context439" ? 1 : 2),
            maximumDurationSeconds: 600, deterministicSeed: 0)
        let analysis = try SequenceProbeRun.analyze(manifest: description, root: manifestURL.deletingLastPathComponent(), policy: policy)
        guard analysis.sourcesUnchanged, analysis.manifest.entries.count == fixture.files.count,
              analysis.observations.count == fixture.files.count,
              analysis.featuresAvailable.count == fixture.files.count, analysis.featuresAvailable.allSatisfy({ $0 })
        else { throw SequenceFixtureError.invalid("Incomplete native JPEG reader pipeline") }
        for ordinal in fixture.files.indices {
            let file = fixture.files[ordinal], source = analysis.sources[ordinal], entry = analysis.manifest.entries[ordinal]
            guard source.assetID == file.assetID, entry.assetID == file.assetID, entry.ordinal == file.ordinal,
                  source.beforeSHA256 == file.jpegSHA256, source.afterSHA256 == file.jpegSHA256,
                  entry.contentHash == file.jpegSHA256, source.errors.isEmpty,
                  let evidence = analysis.observations[ordinal].evidence
            else { throw SequenceFixtureError.invalid("Actual derivative identity or metadata missing at \(item.id):\(ordinal)") }
            try validateMetadata(metadata.assets[ordinal], evidence: evidence, sourceHash: file.sourceCapture.sha256, recipe: recipe)
            let url = try SequenceFixtureFiles.resolve(file.relativePath, root: manifestURL.deletingLastPathComponent())
            try validateJPEG(url, file: file)
        }
        // Truth is not loaded until an immutable analysis seal exists. No sidecar repairs observation inputs.
        let (_, evaluation) = try SequenceProbeRun.sealThenEvaluate(analysis, policy: policy) {
            let (data, _) = try verifiedSidecar(item.truthPath, expectedHash: item.truthSHA256, root: datasetRoot)
            try SequenceFixtureFiles.checkJSONWhitelist(data, allowed: [
                "$root": ["schemaVersion", "role", "groups", "negativePairs"],
                "groups": ["id", "kind", "assetIDs"], "negativePairs": ["from", "to"]
            ], type: "truth")
            let truth = try decode(ProbeLabels.self, data: data)
            try truth.validate(assetIDs: fixture.files.map(\.assetID))
            let unknown = Set(item.unknownAssetIDs)
            guard truth.role == "development-regression-fixture",
                  truth.groups.allSatisfy({ unknown.isDisjoint(with: $0.assetIDs) }),
                  truth.negativePairs.allSatisfy({ !unknown.contains($0.from) && !unknown.contains($0.to) })
            else { throw SequenceFixtureError.invalid("Unknown extent used as labeled positive/negative truth") }
            if item.id == "dji187-context376" {
                guard truth.negativePairs.isEmpty, truth.groups.count == 1, truth.groups[0].kind == .interval,
                      truth.groups[0].assetIDs == Array(fixture.files.prefix(374)).map(\.assetID)
                else { throw SequenceFixtureError.invalid("DJI double-format/unknown extent truth changed") }
            }
            return truth
        }
        var limitations = evaluation.failures.filter {
            $0.contains("support") || $0.contains("acceptanceIncomplete") || $0 == "acceptanceNotConfigured" || $0 == "source-declaration-contradicted"
        }
        if evaluation.unknownPositivePairs > 0 { limitations.append("positive-pairs-not-decidable: \(evaluation.unknownPositivePairs)") }
        if !item.completeGroupTruth { limitations.append("full-group-extent-not-labeled; DJI0188 remains unknown") }
        let classification = evaluation.failures.filter { !limitations.contains($0) }
        return SequenceFixtureCaseBehavior(id: item.id, assetCount: fixture.files.count, manifestSHA256: item.manifestSHA256,
            metadataSHA256: item.metadataSHA256, truthSHA256: item.truthSHA256, policyFingerprint: try config.fingerprint,
            result: analysis.result, evaluation: evaluation, completeGroupTruth: item.completeGroupTruth,
            unknownAssetIDs: item.unknownAssetIDs, integrityValidated: true,
            qualityAccepted: evaluation.acceptedWithinDeclaredSourceScope && item.completeGroupTruth,
            evidenceLimitations: limitations, classificationFailures: classification)
    }
    static func validateDJIPairs(_ manifest: SequenceFixtureManifest) throws {
        guard manifest.files.count == 376 else { throw SequenceFixtureError.invalid("DJI assets dropped") }
        for pair in 0..<188 {
            let a = manifest.files[pair * 2], b = manifest.files[pair * 2 + 1]
            let aURL = URL(fileURLWithPath: a.sourceCapture.relativePath), bURL = URL(fileURLWithPath: b.sourceCapture.relativePath)
            guard a.assetID != b.assetID, a.relativePath != b.relativePath,
                  aURL.deletingPathExtension() == bURL.deletingPathExtension(),
                  a.sourceCapture.originalExtension.uppercased() == "DNG", b.sourceCapture.originalExtension.uppercased() == "JPG"
            else { throw SequenceFixtureError.invalid("DJI DNG/JPG pairing collapsed, reordered or overwritten") }
        }
    }
    static func validateMetadata(_ asset: SequenceFixtureMetadata.Asset, evidence: SequenceCaptureEvidence,
                                 sourceHash: String, recipe: SequenceFixtureIndex.Recipe) throws {
        let expected = asset.expectedJPEG, original = asset.sourceCapture
        guard asset.assetID == evidence.assetID, evidence.orientation == 1, expected.orientation == 1,
              (1...8).contains(original.orientation), evidence.time.isConsistent,
              expected.dateTimeOriginalRaw == original.dateTimeOriginalRaw,
              expected.subsecTimeOriginalRaw == original.subsecTimeOriginalRaw,
              expected.offsetTimeOriginalRaw == original.offsetTimeOriginalRaw,
              expected.cameraMake == original.cameraMake, expected.cameraModel == original.cameraModel,
              expected.exposureSeconds == original.exposureSeconds,
              evidence.time.originalRaw == expected.dateTimeOriginalRaw,
              evidence.time.subsecondsRaw == expected.subsecTimeOriginalRaw,
              evidence.time.offsetRaw == expected.offsetTimeOriginalRaw,
              evidence.cameraMake == expected.cameraMake, evidence.cameraModel == expected.cameraModel,
              asset.sourceIntegrity.credentialUnchanged,
              asset.sourceIntegrity.sha256Before == sourceHash, asset.sourceIntegrity.sha256After == sourceHash
        else { throw SequenceFixtureError.invalid("Native JPEG metadata/source-integrity roundtrip failed: \(asset.assetID)") }
        let roundtrip = asset.exposureRoundtrip
        switch (expected.exposureSeconds, evidence.exposureSeconds) {
        case (nil, nil):
            guard roundtrip.actualSeconds == nil, roundtrip.absoluteDifferenceSeconds == nil,
                  roundtrip.allowedDifferenceSeconds == recipe.exposureAbsoluteToleranceSeconds else { throw SequenceFixtureError.invalid("Missing exposure was fabricated") }
        case (.some(let expectedSeconds), .some(let actual)):
            let allowed = max(recipe.exposureAbsoluteToleranceSeconds, abs(expectedSeconds) * recipe.exposureRelativeTolerance)
            let difference = abs(actual - expectedSeconds)
            guard expectedSeconds.isFinite, expectedSeconds > 0, actual.isFinite, difference <= allowed,
                  roundtrip.actualSeconds == actual, roundtrip.allowedDifferenceSeconds == allowed,
                  roundtrip.absoluteDifferenceSeconds == difference else { throw SequenceFixtureError.invalid("Exposure roundtrip exceeded bound: \(asset.assetID)") }
        default: throw SequenceFixtureError.invalid("Exposure presence changed: \(asset.assetID)")
        }
    }
    static func validateJPEG(_ url: URL, file: SequenceFixtureManifest.File) throws {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  decoded.width == file.width, decoded.height == file.height,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == file.width,
                  (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == file.height,
                  (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue == 1
            else { throw SequenceFixtureError.invalid("JPEG format/dimensions/orientation incorrect: \(file.assetID)") }
            func inspect(_ value: Any) throws {
                if let fields = value as? [String: Any] {
                    for (key, child) in fields {
                        let normalized = key.lowercased().filter { $0.isLetter }
                        guard !normalized.contains("gps"), !normalized.contains("serial"), !normalized.contains("makernote"),
                              !normalized.contains("ownername"), !normalized.contains("usercomment")
                        else { throw SequenceFixtureError.invalid("Private metadata leaked in fixture JPEG: \(key)") }
                        try inspect(child)
                    }
                } else if let values = value as? [Any] { for child in values { try inspect(child) } }
            }
            try inspect(properties)
        }
    }
    static func assertBaseline(_ baselineData: Data, current: SequenceFixtureBaseline) throws -> String {
        let baseline = try JSONSerialization.jsonObject(with: baselineData) as? [String: Any]
        let actual = try JSONSerialization.jsonObject(with: encoded(current)) as? [String: Any]
        guard baseline?["schemaVersion"] as? Int == 1,
              baseline?["datasetID"] as? String == current.datasetID,
              baseline?["indexSHA256"] as? String == current.indexSHA256,
              let expectedCases = baseline?["cases"], let currentCases = actual?["cases"],
              try SequenceFixtureFiles.canonicalJSON(expectedCases) == SequenceFixtureFiles.canonicalJSON(currentCases)
        else { throw SequenceFixtureError.invalid("JPEG behavior/quality metrics drifted from approved baseline; review platform and result differences, do not silently update") }
        guard let platform = baseline?["referencePlatform"] else { throw SequenceFixtureError.invalid("Baseline missing reference platform") }
        return String(decoding: try SequenceFixtureFiles.canonicalJSON(platform), as: UTF8.self)
    }
    static func write<T: Encodable>(_ value: T, to path: String, outside fixtureRoot: URL) throws {
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = fixtureRoot.standardizedFileURL.resolvingSymlinksInPath()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let protectedRoots = [root, repository.appendingPathComponent("Tests/RAWMasterImagingTests/Fixtures"),
            repository.appendingPathComponent("Tests/Fixtures/SequenceGroupingInputs")].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard protectedRoots.allSatisfy({ target.path != $0 && !target.path.hasPrefix($0 + "/") }) else {
            throw SequenceFixtureError.invalid("Test output cannot modify fixture dataset or human truth")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded(value).write(to: target, options: .atomic)
    }
}
