import Foundation
import RAWMasterCore
@testable import RAWMasterSequenceProbe

enum SequenceFixtureError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let text): return text } }
}

struct SequenceFixtureIndex: Decodable {
    struct Recipe: Decodable {
        let maximumPixel: Int
        let jpegQuality: Double
        let colorSpace: String
        let orientation: Int
        let rawMode: String
        let exposureAbsoluteToleranceSeconds: Double
        let exposureRelativeTolerance: Double
    }
    struct Case: Decodable {
        let id: String
        let assetCount: Int
        let manifestPath, metadataPath, truthPath: String
        let manifestSHA256, metadataSHA256, truthSHA256: String
        let completeGroupTruth: Bool
        let unknownAssetIDs: [String]
    }
    static let expectedCounts = ["burst123": 123, "burst14-context38": 38, "burst48-context72": 72,
        "interval427-context439": 439, "burst193-context217": 217, "dji187-context376": 376]
    let schemaVersion: Int
    let datasetID, converterVersion: String
    let assetCount: Int
    let recipe: Recipe
    let cases: [Case]
    func validate() throws {
        guard schemaVersion == 1, datasetID == "sequence-grouping-jpeg-v1", !converterVersion.isEmpty,
              assetCount == 1265, cases.count == 6, Set(cases.map(\.id)).count == 6,
              Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0.assetCount) }) == Self.expectedCounts,
              cases.reduce(0, { $0 + $1.assetCount }) == assetCount,
              recipe.maximumPixel == 1024, recipe.jpegQuality == 0.8, recipe.colorSpace == "sRGB",
              recipe.orientation == 1, recipe.rawMode == "embedded-preview-only",
              recipe.exposureAbsoluteToleranceSeconds == 1e-8, recipe.exposureRelativeTolerance == 1e-6
        else { throw SequenceFixtureError.invalid("Fixture case inventory, version, or conversion recipe changed") }
        for item in cases {
            for path in [item.manifestPath, item.metadataPath, item.truthPath] { try SequenceFixtureFiles.validateRelativePath(path) }
            guard item.truthPath.hasPrefix("truth/"), !item.manifestPath.hasPrefix("truth/"),
                  !item.metadataPath.hasPrefix("truth/"),
                  [item.manifestSHA256, item.metadataSHA256, item.truthSHA256].allSatisfy(SequenceFixtureFiles.isDigest)
            else { throw SequenceFixtureError.invalid("Invalid fixture sidecar identity") }
            let dji = item.id == "dji187-context376"
            guard item.completeGroupTruth == !dji,
                  item.unknownAssetIDs == (dji ? ["asset0374", "asset0375"] : [])
            else { throw SequenceFixtureError.invalid("Fixture truth extent or unknown DJI0188 scope changed") }
        }
    }
}

struct SequenceFixtureManifest: Decodable {
    struct SourceCapture: Decodable {
        let relativePath, originalExtension, sha256: String
    }
    struct File: Decodable {
        let assetID: String
        let ordinal: Int
        let relativePath, jpegSHA256: String
        let width, height: Int
        let sourceCapture: SourceCapture
    }
    let schemaVersion: Int
    let scopeID, sessionID, orderVersion: String
    let files: [File]
    func validate(expectedCount: Int) throws {
        guard schemaVersion == 1, files.count == expectedCount,
              Set(files.map(\.assetID)).count == files.count,
              Set(files.map(\.relativePath)).count == files.count,
              Set(files.map { $0.sourceCapture.relativePath }).count == files.count
        else { throw SequenceFixtureError.invalid("Fixture manifest lost/duplicated original assets") }
        for (ordinal, file) in files.enumerated() {
            try SequenceFixtureFiles.validateRelativePath(file.relativePath)
            try SequenceFixtureFiles.validateRelativePath(file.sourceCapture.relativePath)
            guard file.ordinal == ordinal, file.assetID == String(format: "asset%04d", ordinal),
                  file.relativePath == "files/\(file.assetID).jpg",
                  SequenceFixtureFiles.isDigest(file.jpegSHA256), SequenceFixtureFiles.isDigest(file.sourceCapture.sha256),
                  file.width > 0, file.height > 0, max(file.width, file.height) <= 1024,
                  !file.sourceCapture.originalExtension.isEmpty,
                  URL(fileURLWithPath: file.sourceCapture.relativePath).pathExtension == file.sourceCapture.originalExtension
            else { throw SequenceFixtureError.invalid("Fixture ordinal, identity, dimensions, or source provenance invalid") }
        }
    }
}

struct SequenceFixtureMetadata: Decodable {
    struct Capture: Decodable {
        let dateTimeOriginalRaw, subsecTimeOriginalRaw, offsetTimeOriginalRaw: String?
        let exposureSeconds: Double?
        let cameraMake, cameraModel: String?
        let orientation: Int
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case dateTimeOriginalRaw, subsecTimeOriginalRaw, offsetTimeOriginalRaw
            case exposureSeconds, cameraMake, cameraModel, orientation
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // A missing key must not silently become a nil/wildcard expectation.
            for key in CodingKeys.allCases where !values.contains(key) {
                throw SequenceFixtureError.invalid("Missing explicit nullable metadata key: \(key.stringValue)")
            }
            dateTimeOriginalRaw = try values.decodeIfPresent(String.self, forKey: .dateTimeOriginalRaw)
            subsecTimeOriginalRaw = try values.decodeIfPresent(String.self, forKey: .subsecTimeOriginalRaw)
            offsetTimeOriginalRaw = try values.decodeIfPresent(String.self, forKey: .offsetTimeOriginalRaw)
            exposureSeconds = try values.decodeIfPresent(Double.self, forKey: .exposureSeconds)
            cameraMake = try values.decodeIfPresent(String.self, forKey: .cameraMake)
            cameraModel = try values.decodeIfPresent(String.self, forKey: .cameraModel)
            orientation = try values.decode(Int.self, forKey: .orientation)
        }
    }
    struct Exposure: Decodable {
        let actualSeconds, absoluteDifferenceSeconds, allowedDifferenceSeconds: Double?
    }
    struct Integrity: Decodable {
        let sha256Before, sha256After: String
        let credentialUnchanged: Bool
    }
    struct Asset: Decodable {
        let assetID: String
        let sourceCapture, expectedJPEG: Capture
        let exposureRoundtrip: Exposure
        let sourceIntegrity: Integrity
    }
    let schemaVersion: Int
    let caseID: String
    let assets: [Asset]
}

enum SequenceFixtureFiles {
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validateRelativePath(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0"),
              !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw SequenceFixtureError.invalid("Unsafe fixture relative path: \(value)") }
    }
    static func resolve(_ relative: String, root: URL) throws -> URL {
        try validateRelativePath(relative)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let result = canonicalRoot.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(canonicalRoot.path + "/") else { throw SequenceFixtureError.invalid("Fixture path escaped dataset") }
        return result
    }
    static func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }
    static func checkJSONWhitelist(_ data: Data, allowed: [String: Set<String>], type: String) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        func visit(_ value: Any, scope: String) throws {
            if let dictionary = value as? [String: Any] {
                guard let permitted = allowed[scope], Set(dictionary.keys).isSubset(of: permitted) else {
                    throw SequenceFixtureError.invalid("Unexpected public sidecar field in \(type).\(scope)")
                }
                for (key, child) in dictionary { try visit(child, scope: key) }
            } else if let values = value as? [Any] {
                for child in values { try visit(child, scope: scope) }
            } else if let text = value as? String {
                guard !text.hasPrefix("/"), !text.contains("file://"), !text.contains("/Volumes/"), !text.contains("/Users/") else {
                    throw SequenceFixtureError.invalid("Private absolute path in fixture sidecar")
                }
            }
        }
        try visit(object, scope: "$root")
    }
}
