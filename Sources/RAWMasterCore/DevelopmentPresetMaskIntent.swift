import Foundation

/// Portable photographic intent. A catalog entry contains no pixels, source binding, point prompts or photo-local layer IDs.
public struct DevelopmentPresetMaskIntent: Codable, Equatable, Sendable {
    public let target: DevelopmentSemanticTarget
    public let name: String
    public let enabled, inverted: Bool
    public let opacity: Double
    public let adjustments: DevelopmentMaskAdjustmentsV3
    public let generator: String
    public let modelHashes: [String]

    public init(target: DevelopmentSemanticTarget, name: String, adjustments: DevelopmentMaskAdjustmentsV3) throws {
        self.target = target
        self.name = name
        self.adjustments = adjustments
        enabled = true
        inverted = false
        opacity = 1
        generator = "external-semantic-intent"
        modelHashes = []
        try validate()
    }

    public init(capturing layer: DevelopmentMaskLayerV3) throws {
        guard layer.kind == .subject, let snapshot = layer.semanticSnapshot,
              !snapshot.wasRefined, snapshot.prompt.isEmpty,
              [.subject, .background, .sky, .water].contains(snapshot.target) else {
            throw DevelopmentPresetError.nonReusableMask
        }
        try layer.validate()
        target = snapshot.target
        name = layer.name
        enabled = layer.enabled
        inverted = layer.inverted
        opacity = layer.opacity
        adjustments = layer.adjustments
        generator = snapshot.generator
        modelHashes = snapshot.modelHashes
        try validate()
    }

    public func validate() throws {
        guard [.subject, .background, .sky, .water].contains(target), !name.isEmpty, name.count <= 128,
              (0...1).contains(opacity), (1...96).contains(generator.count), modelHashes.count <= 4,
              modelHashes.allSatisfy(EditingFingerprint.isSHA256) else { throw DevelopmentPresetError.nonReusableMask }
        try adjustments.validate()
    }

    public func configuring(_ fresh: DevelopmentMaskLayerV3, source: DevelopmentLocalEditSourceBinding) throws -> DevelopmentMaskLayerV3 {
        try validate()
        guard let snapshot = fresh.semanticSnapshot, fresh.kind == .subject, snapshot.source == source,
              snapshot.target == target, snapshot.prompt.isEmpty, !snapshot.wasRefined else { throw DevelopmentPresetError.nonReusableMask }
        var resolved = fresh
        resolved.id = UUID()
        resolved.name = name
        resolved.enabled = enabled
        resolved.inverted = inverted
        resolved.opacity = opacity
        resolved.adjustments = adjustments
        try resolved.validate()
        return resolved
    }
}
