import Foundation
import RAWMasterCore
import RAWMasterImage

enum PreviewPortableCurvesLevels {
    static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_PORTABLE_CURVES_PREVIEW"] == "1"

    static func qualifies(_ p: DevelopmentAdjustmentsV3) -> Bool {
        let curvesActive = DevelopmentColorEngineV3.curvesActive(p.curves)
        guard curvesActive || DevelopmentColorEngineV3.levelsActive(p.levels) else { return false }
        if curvesActive {
            guard p.curves.algorithm == .legacyPCHIPV1, p.curves.parametric?.isActive != true,
                  (p.curves.refineSaturation ?? 0) == 0 else { return false }
        }
        // The legacy stage checks the F32 endpoints, including inactive channels when levels are active.
        guard channels(p.curves).allSatisfy({ Float($0.1.inputBlack) < Float($0.1.inputWhite) }) else { return false }

        var remaining = p
        remaining.curves = .init()
        remaining.levels = .init()
        if remaining.legacyBasis?.isPixelNeutral == true { remaining.legacyBasis = nil }
        var neutral = p.neutralForSameSource
        neutral.rawDetails = p.rawDetails
        return remaining == neutral || PreviewPortableBasic.qualifies(remaining)
    }

    static func plan(_ p: DevelopmentAdjustmentsV3, backend: RAWMasterImageKernel.Backend = .cpu) throws -> RAWMasterImageKernel.RasterPlan {
        try RAWMasterImageKernel.RasterPlan(recipe: recipe(p), backend: backend)
    }

    static func recipe(_ p: DevelopmentAdjustmentsV3) throws -> Data {
        try p.validate()
        guard qualifies(p) else { throw DevelopmentV3Error.invalidGraph }
        var node: [String: Any] = ["id": "curves-levels", "op": "curves_levels_v3", "image": "basic"]
        if DevelopmentColorEngineV3.curvesActive(p.curves) {
            var curves: [String: Any] = [:]
            for (name, channel) in channels(p.curves) {
                if channel.curve.isNeutral && channel.inputBlack == 0 && channel.inputWhite == 1 { continue }
                curves[name] = ["points": channel.curve.points.map { ["x": $0.x, "y": $0.y] },
                                "inputBlack": channel.inputBlack, "inputWhite": channel.inputWhite]
            }
            node["curves"] = curves
        }
        if DevelopmentColorEngineV3.levelsActive(p.levels) {
            var levels: [String: Any] = [:]
            let l = p.levels
            for (name, channel) in [("luminance", l.luminance), ("rgb", l.rgb), ("red", l.red),
                                    ("green", l.green), ("blue", l.blue)] {
                guard case .manual(let handles) = channel else { continue }
                levels[name] = ["black": handles.black, "shadows": handles.shadows, "midtones": handles.midtones,
                                "highlights": handles.highlights, "white": handles.white,
                                "outputBlack": handles.outputBlack, "outputWhite": handles.outputWhite]
            }
            node["levels"] = levels
        }
        // The identity basic node keeps the same GPU topology when a point adjustment is added later.
        let recipe: [String: Any] = ["version": 2, "working": "extended-linear-srgb-premul-f32",
                                      "output": "curves-levels",
                                      "nodes": [["id": "source", "op": "source"], PreviewPortableBasic.node(p), node]]
        return try JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys])
    }

    private static func channels(_ curves: DevelopmentCurvesV3) -> [(String, DevelopmentCurveChannelV3)] {
        [("rgb", curves.rgb), ("red", curves.red), ("green", curves.green), ("blue", curves.blue)]
    }
}
