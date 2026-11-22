import Foundation

/// Stored alongside draft/version metadata. Pixel identity and the portable recipe are independent of the catalog.
public struct DevelopmentPresetAdoption: Codable, Equatable, Sendable {
    public let presetID, name: String
    public let version: Int
    public let amount: Double
    public let sourceID, baselineFingerprint, resultFingerprint: String
    public let sourceSHA256: String?
    public let fields, assetHashes: [String]
    public let omitted: String?
    public let policy: String

    public init(record: DevelopmentPresetRecord, sourceID: String, amount: Double, baseline: DevelopmentRecipe,
                result: DevelopmentRecipe, masks: [DevelopmentMaskLayerV3]?) throws {
        presetID = record.id
        name = record.name
        version = record.version
        self.amount = amount
        self.sourceID = sourceID
        sourceSHA256 = record.sourceSHA256
        baselineFingerprint = try EditingFingerprint.of(baseline)
        resultFingerprint = try EditingFingerprint.of(result)
        var included = record.patch.fields.map(\.rawValue).sorted()
        let depthApproximation = record.metadata["reconstruction"] == "nativeDepthCircleV1" && record.patch.fullRecipe != nil
        if depthApproximation { included.append("effects.lensBlur") }
        else if record.patch.fullRecipe != nil { included.append("fullRecipe") }
        if record.patch.resetLensBlur == true { included.append("resetLensBlur") }
        included += (record.patch.semanticMasks ?? []).map { "mask." + $0.target.rawValue }
        fields = included
        omitted = record.metadata["confirmedOmissions"]
        if depthApproximation { policy = "nativeDepthApproximation" }
        else { policy = record.metadata["semanticReconstruction"] == "true" ? "reconstructed" : (omitted == nil ? "strict" : "confirmedSubset") }
        let resolved = masks ?? record.patch.fullRecipe?.adjustmentsV3?.masks ?? []
        assetHashes = Array(Set(resolved.compactMap(\.semanticSnapshot).flatMap { [$0.pngSHA256] + $0.modelHashes })).sorted()
    }

    public var estimatedBytes: Int {
        512 + presetID.utf8.count + name.utf8.count + fields.reduce(0) { $0 + $1.utf8.count }
            + (omitted?.utf8.count ?? 0) + assetHashes.count * 80
    }
}
