import Foundation
import RAWMasterCore
import RAWMasterImage

/// A legacy V2 color-wheel stage with the original verified RAW as its only optical input.
struct PreviewPortableGrading {
    static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_PORTABLE_GRADING_HALF_FIT"] == "1"
    private let grading: DevelopmentColorGrading

    init?(_ parameters: DevelopmentAdjustmentsV3) {
        guard parameters.rawDecoder == .flashRaw031, parameters.rawDetails == nil,
              let basis = parameters.legacyBasis, basis.version == .v2,
              basis.exposureEV == 0, basis.whiteBalance == .asShot,
              let color = basis.color, !color.grading.isNeutral, color.tones.isNeutral,
              color.curves.isNeutral else { return nil }
        var permitted = parameters.neutralForSameSource
        permitted.legacyBasis = basis
        guard permitted == parameters else { return nil }
        grading = color.grading
    }

    func plan() throws -> RAWMasterImageKernel.RasterPlan {
        let wheels = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grading))
        let recipe: [String: Any] = [
            "version": 2, "working": "extended-linear-srgb-premul-f32", "output": "grading",
            "nodes": [
                ["id": "source", "op": "source"],
                ["id": "grading", "op": "color_grading_v2", "image": "source", "grading": wheels],
            ],
        ]
        return try .init(recipe: JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys]), backend: .cpu)
    }
}
