import Foundation
import CryptoKit

public enum SemanticMaskKind: String, Codable, Sendable {
    case subject, background, landscape, object, person
}

public struct MaskModelIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let sha256: String
    public init(id: String, sha256: String) { self.id = id; self.sha256 = sha256 }
    public init(model: MaskAIModel) { id = model.rawValue; sha256 = model.expectedSHA256 }
}

public struct MaskSourceBinding: Codable, Equatable, Sendable {
    public let sourceContentID: String
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let analysisWidth: Int
    public let analysisHeight: Int
    public let exifOrientation: Int

    public init(sourceContentID: String, nativeWidth: Int, nativeHeight: Int,
                analysisWidth: Int, analysisHeight: Int, exifOrientation: Int) {
        self.sourceContentID = sourceContentID
        self.nativeWidth = nativeWidth; self.nativeHeight = nativeHeight
        self.analysisWidth = analysisWidth; self.analysisHeight = analysisHeight
        self.exifOrientation = exifOrientation
    }

    public init(info: RAWSourceInfo) {
        self.init(sourceContentID: info.sourceSHA256,
                  nativeWidth: info.nativeWidth, nativeHeight: info.nativeHeight,
                  analysisWidth: info.analysisWidth, analysisHeight: info.analysisHeight,
                  exifOrientation: info.exifOrientation)
    }

    public func validate() throws {
        guard sourceContentID.count == 64, sourceContentID.allSatisfy({ $0.isHexDigit }),
              nativeWidth > 0, nativeHeight > 0, analysisWidth > 0, analysisHeight > 0,
              (1...8).contains(exifOrientation) else {
            throw MaskAIError.invalidInput("Invalid semantic mask source binding.")
        }
    }
}

public struct SemanticMaskDescriptor: Codable, Equatable, Sendable {
    public static let analysisInputVersion = "neutral-oriented-srgb-rgba8-v1"
    public static let algorithmVersion = "mask-ai-native-v1"

    public let kind: SemanticMaskKind
    /// Landscape target, person part, or `main` for subject/background/object.
    public let target: String
    public let personIndex: Int?
    public let objectPrompt: ObjectPrompt?
    public let source: MaskSourceBinding
    public let models: [MaskModelIdentity]
    public let analysisInputVersion: String
    public let algorithmVersion: String

    public init(kind: SemanticMaskKind, target: String = "main", personIndex: Int? = nil,
                objectPrompt: ObjectPrompt? = nil, source: MaskSourceBinding,
                models: [MaskModelIdentity]) {
        self.kind = kind; self.target = target; self.personIndex = personIndex
        self.objectPrompt = objectPrompt; self.source = source; self.models = models
        analysisInputVersion = Self.analysisInputVersion
        algorithmVersion = Self.algorithmVersion
    }

    public func validate() throws {
        try source.validate()
        guard !target.isEmpty, !models.isEmpty, models.allSatisfy({ !$0.id.isEmpty && $0.sha256.count == 64 }),
              analysisInputVersion == Self.analysisInputVersion, algorithmVersion == Self.algorithmVersion else {
            throw MaskAIError.invalidInput("Invalid semantic mask descriptor.")
        }
        switch kind {
        case .subject, .background:
            guard target == "main", personIndex == nil, objectPrompt == nil else { throw MaskAIError.invalidInput("Unexpected subject parameters.") }
        case .landscape:
            guard LandscapeMaskTarget(rawValue: target) != nil, personIndex == nil, objectPrompt == nil else { throw MaskAIError.invalidInput("Invalid landscape target.") }
        case .object:
            guard target == "main", personIndex == nil, let objectPrompt else { throw MaskAIError.invalidInput("Object descriptor needs a prompt.") }
            _ = try objectPrompt.validated()
        case .person:
            guard PersonMaskTarget(rawValue: target) != nil, objectPrompt == nil else { throw MaskAIError.invalidInput("Invalid person target.") }
            if let personIndex, personIndex < 0 { throw MaskAIError.invalidInput("Person index cannot be negative.") }
        }
    }

    public var cacheKey: String {
        get throws {
            try validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

public struct MaskSnapshotReference: Codable, Equatable, Sendable {
    public let id: String
    public let descriptorKey: String
    public let contentSHA256: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
}

public struct MaskSnapshot: Codable, Equatable, Sendable {
    public let reference: MaskSnapshotReference
    public let descriptor: SemanticMaskDescriptor
    public let createdAt: Date

    public func loadMask(from store: MaskSnapshotStore) throws -> MaskImage { try store.load(reference) }
}
