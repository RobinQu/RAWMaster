import Foundation

public enum PresetLensBlurAssessment: Equatable, Sendable {
    case approximate(PresetLensBlurReconstruction)
    case unavailable(String)
}

/// Parameters with native controls. A prepared record belongs to one photo and lives only in the editor.
public struct PresetLensBlurReconstruction: Equatable, Sendable {
    public let presetSHA256: String
    public let amount, catEyeAmount, bokehBoost: Double

    public func prepare(record: DevelopmentPresetRecord, baseline: DevelopmentRecipe, sourceID: String,
                        scene: DevelopmentSceneDepthV1?, focus: DevelopmentSourcePoint?,
                        focusRange: Double?) throws -> DevelopmentPresetRecord {
        guard EditingFingerprint.isSHA256(sourceID), record.id == "xmp." + presetSHA256,
              record.sourceSHA256 == presetSHA256 else { throw DevelopmentPresetError.differentSource }
        var recipe = try baseline.promotingToV3()
        var effects = recipe.adjustmentsV3?.effects ?? .init()
        let seed = effects.lensBlur
        var blur = seed ?? .init()
        for map in [scene, blur.sceneDepth].compactMap({ $0 }) {
            guard map.sourceSHA256 == sourceID else { throw DevelopmentPresetError.differentSource }
            try map.validate()
        }
        if blur.renderDepth == nil {
            guard let scene else { throw DevelopmentPresetError.unavailable }
            blur.sceneDepth = scene
        }
        if seed == nil {
            guard let focus, let focusRange else { throw DevelopmentPresetError.unavailable }
            try blur.focus(at: focus)
            blur.focusRange = focusRange
        }
        blur.enabled = true
        blur.amount = amount
        blur.bokehStyle = .circle
        blur.catEyeAmount = catEyeAmount
        blur.bokehBoost = bokehBoost
        blur.visualiseDepth = nil
        try blur.validate()
        effects.lensBlur = blur
        recipe.adjustmentsV3?.effects = effects
        var result = record
        result.blockingReasons = []
        result.patch = try DevelopmentPresetPatch(fullRecipe: recipe, sourceID: sourceID)
        result.metadata["reconstruction"] = "nativeDepthCircleV1"
        result.metadata["evidence"] = "使用本张焦点、深度与 RAWMaster 圆形散景近似"
        result.metadata["confirmedOmissions"] = "Adobe 四点焦段、高光阈值和猫眼缩放使用本机行为"
        try result.validate()
        return result
    }
}

extension DevelopmentPresetExchange {
    public static func lensBlurAssessment(for record: DevelopmentPresetRecord,
                                          catalog: DevelopmentPresetCatalog) throws -> PresetLensBlurAssessment {
        guard let sha = record.sourceSHA256 else { throw DevelopmentPresetError.unavailable }
        return try lensBlurAssessment(for: record, original: catalog.originalData(sha256: sha))
    }

    static func lensBlurAssessment(for record: DevelopmentPresetRecord, original: Data) throws -> PresetLensBlurAssessment {
        guard record.kind == .imported, record.metadata["origin"] == "adobeBuiltin", record.metadata["capability"] == "lensBlur",
              record.metadata["lensBlurActive"] == "true", record.metadata["omitted"] == "LensBlur",
              record.metadata["sourceRestriction"] == nil, record.metadata["unverifiedProcess"] == nil,
              let sha = record.sourceSHA256, record.id == "xmp." + sha, hash(original) == sha,
              try migrationRules().contains(where: { $0.sha256 == sha && $0.path.hasPrefix("Premium/Adaptive - Blur Background/") }) else {
            return .unavailable("仅可从已核验的内置镜头模糊原件准备")
        }
        let values = try CameraRawXMP.read(original).lensBlur
        let supportedKeys: Set<String> = ["Version", "Active", "BlurAmount", "FocalRange", "BokehShape", "BokehShapeDetail",
            "BokehAspect", "BokehRotation", "HighlightsBoost", "HighlightsThreshold", "CatEyeAmount", "CatEyeScale", "SphericalAberration"]
        guard Set(values.keys) == supportedKeys, values["Version"] == "1", values["Active"] == "true",
              values["FocalRange"] == "0 0 100 100", values["HighlightsThreshold"] == "50", values["CatEyeScale"] == "100" else {
            return .unavailable("该版本、焦段或光斑控制超出已验证的映射范围")
        }
        if values["BokehShape"] != "0" { return .unavailable("该光圈形状与球差组合需要独立的光学映射") }
        if values["SphericalAberration"] != "0" { return .unavailable("本机散景缺少可独立设置的球差") }
        if values["BokehAspect"] != "0" { return .unavailable("本机散景缺少对应的光斑长宽比控制") }
        if values["BokehShapeDetail"] != "0" || values["BokehRotation"] != "0" {
            return .unavailable("本机散景缺少该光圈细节与旋转角控制")
        }
        func fraction(_ key: String) -> Double? {
            guard let raw = values[key], let number = Double(raw), number.isFinite, (0...100).contains(number) else { return nil }
            return number / 100
        }
        guard let amount = fraction("BlurAmount"), amount > 0,
              let eye = fraction("CatEyeAmount"), let boost = fraction("HighlightsBoost") else {
            return .unavailable("散景强度、猫眼或高光数量超出本机范围")
        }
        return .approximate(.init(presetSHA256: sha, amount: amount, catEyeAmount: eye, bokehBoost: boost))
    }
}
