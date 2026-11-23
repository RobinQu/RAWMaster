import Foundation

public enum DevelopmentPresetError: LocalizedError, Equatable {
    case invalid, conflict, unsupportedAmount, differentSource, missingOriginal, unavailable, semanticMask, nonReusableMask, needsPreparation

    public var errorDescription: String? {
        switch self {
        case .invalid: return "预设格式、字段或数值无效。"
        case .conflict: return "预设版本已经改变，请重新选择。"
        case .unsupportedAmount: return "此配方包含只能完整采用的设置。"
        case .differentSource: return "这份完整配方仅适用于保存时的原始照片。"
        case .missingOriginal: return "原始文件缺失或校验失败。"
        case .unavailable: return "此预设的必要条件尚未满足。"
        case .nonReusableMask: return "可跨片复用未手绘修边的主体、背景、天空和水面。点选、框选和旧版像素蒙版只属于当前照片。"
        case .needsPreparation: return "请先在当前照片准备选区，核对后采用。"
        case .semanticMask: return "这份旧蒙版没有可核验的原片标识。请在本张重新准备该选区，或选择要保存的字段。"
        }
    }
}

public enum DevelopmentPresetField: String, Codable, CaseIterable, Sendable {
    case exposure, brilliance, highlights, shadows, whites, brightness, contrast, blackPoint
    case saturation, vibrance, cast, grading, curves, filter, legacyBasis

    public var name: String {
        switch self {
        case .exposure: return "曝光"
        case .brilliance: return "鲜明度"
        case .highlights: return "高光"
        case .shadows: return "阴影"
        case .whites: return "白色色阶"
        case .brightness: return "亮度"
        case .contrast: return "对比度"
        case .blackPoint: return "黑点"
        case .saturation: return "饱和度"
        case .vibrance: return "自然饱和度"
        case .cast: return "色偏"
        case .grading: return "色彩分级"
        case .curves: return "曲线"
        case .filter: return "滤镜"
        case .legacyBasis: return "旧版显影基底"
        }
    }
}

/// nil inherits the destination. Values are in RAWMaster's native recipe units, including explicit zero.
public struct DevelopmentPresetPatch: Codable, Equatable, Sendable {
    public var exposure, brilliance, highlights, shadows, whites, brightness, contrast, blackPoint: Double?
    public var saturation, vibrance, cast: Double?
    public var brillianceVersion: DevelopmentBrillianceVersion?
    public var curves: DevelopmentCurvesV3?
    public var pointRGB, pointRed, pointGreen, pointBlue: DevelopmentCurve?
    private static let pointChannels: [(KeyPath<Self, DevelopmentCurve?>, WritableKeyPath<DevelopmentCurvesV3, DevelopmentCurveChannelV3>)] = [
        (\.pointRGB, \.rgb), (\.pointRed, \.red), (\.pointGreen, \.green), (\.pointBlue, \.blue)
    ]
    public var filter: DevelopmentFilterV3?
    public var legacyBasis: DevelopmentLegacyBasis?
    public private(set) var legacyFields: DevelopmentPresetLegacyFields?
    public var grading: DevelopmentColorGrading?
    public var semanticMasks: [DevelopmentPresetMaskIntent]?
    public var resetLensBlur: Bool?
    public private(set) var fullRecipe: DevelopmentRecipe?
    public private(set) var boundSourceID: String?
    public private(set) var fullRecipeReference: String?
    public var hasFullRecipe: Bool { fullRecipe != nil || fullRecipeReference != nil }

    func referencing(_ hash: String) -> Self {
        var copy = self
        copy.fullRecipeReference = hash
        copy.fullRecipe = nil
        return copy
    }
    public init() {}

    /// A mapped absolute exposure can explicitly clear just the destination legacy EV contribution.
    public mutating func setLegacyExposureEV(_ ev: Double) {
        var values = legacyFields ?? DevelopmentPresetLegacyFields(exposure: ev, color: nil, fields: [.exposure])
        values.setExposureEV(ev)
        legacyFields = values
    }

    private static let lightFields: [(DevelopmentPresetField, WritableKeyPath<Self, Double?>, WritableKeyPath<DevelopmentLightV3, Double>)] = [
        (.exposure, \.exposure, \.exposure), (.brilliance, \.brilliance, \.brilliance),
        (.highlights, \.highlights, \.highlights), (.shadows, \.shadows, \.shadows),
        (.whites, \.whites, \.whites), (.brightness, \.brightness, \.brightness),
        (.contrast, \.contrast, \.contrast), (.blackPoint, \.blackPoint, \.blackPoint)
    ]
    private static let colorFields: [(DevelopmentPresetField, WritableKeyPath<Self, Double?>, WritableKeyPath<DevelopmentColorV3, Double>)] = [
        (.saturation, \.saturation, \.saturation), (.vibrance, \.vibrance, \.vibrance), (.cast, \.cast, \.cast)
    ]

    public var fields: Set<DevelopmentPresetField> {
        var result = Set(Self.lightFields.compactMap { self[keyPath: $0.1] == nil ? nil : $0.0 })
        result.formUnion(Self.colorFields.compactMap { self[keyPath: $0.1] == nil ? nil : $0.0 })
        if curves != nil || Self.pointChannels.contains(where: { self[keyPath: $0.0] != nil }) { result.insert(.curves) }
        if filter != nil { result.insert(.filter) }
        if legacyBasis != nil { result.insert(.legacyBasis) }
        if grading != nil { result.insert(.grading) }
        if let legacyFields { result.formUnion(legacyFields.fields) }
        return result
    }

    public var isEmpty: Bool { fields.isEmpty && !hasFullRecipe && semanticMasks == nil && resetLensBlur == nil }

    public init(capturing recipe: DevelopmentRecipe, fields: Set<DevelopmentPresetField>, maskIDs: Set<UUID> = []) throws {
        self.init()
        guard let p = try recipe.promotingToV3().adjustmentsV3 else { throw DevelopmentPresetError.invalid }
        let basis = p.legacyBasis
        let old = DevelopmentPresetLegacyFields(exposure: basis?.exposureEV ?? 0, color: basis?.color, fields: fields)
        if !old.fields.isEmpty && !fields.contains(.legacyBasis) { legacyFields = old }
        for (field, patchKey, valueKey) in Self.lightFields where fields.contains(field) {
            self[keyPath: patchKey] = p.light.enabled ? p.light[keyPath: valueKey] : 0
        }
        if fields.contains(.brilliance) { brillianceVersion = p.light.brillianceVersion }
        for (field, patchKey, valueKey) in Self.colorFields where fields.contains(field) {
            self[keyPath: patchKey] = p.color.enabled ? p.color[keyPath: valueKey] : 0
        }
        if fields.contains(.curves) { curves = p.curves }
        if fields.contains(.filter) { filter = p.filter }
        if fields.contains(.legacyBasis) { legacyBasis = p.legacyBasis }
        if fields.contains(.grading), legacyBasis == nil { grading = p.legacyBasis?.color?.grading ?? .init() }
        if !maskIDs.isEmpty {
            let layers = p.masks.filter { maskIDs.contains($0.id) }
            guard layers.count == maskIDs.count else { throw DevelopmentPresetError.nonReusableMask }
            semanticMasks = try layers.map(DevelopmentPresetMaskIntent.init(capturing:))
        }
        guard !isEmpty else { throw DevelopmentPresetError.invalid }
        try validate()
    }

    /// Full fidelity is an explicit source-local operation. Ordinary cross-photo presets only carry selected fields.
    public init(fullRecipe recipe: DevelopmentRecipe, sourceID: String) throws {
        self.init()
        fullRecipe = recipe
        boundSourceID = sourceID
        try validate()
    }

    public func validate() throws {
        guard resetLensBlur != false else { throw DevelopmentPresetError.invalid }
        if let semanticMasks {
            guard (1...DevelopmentMaskLayerV3.maximumLayers).contains(semanticMasks.count) else { throw DevelopmentPresetError.invalid }
            try semanticMasks.forEach { try $0.validate() }
        }
        guard brillianceVersion == nil || brilliance != nil else { throw DevelopmentPresetError.invalid }
        if let ref = fullRecipeReference {
            guard EditingFingerprint.isSHA256(ref), fullRecipe == nil, fields.isEmpty, semanticMasks == nil,
                  resetLensBlur == nil, let boundSourceID, EditingFingerprint.isSHA256(boundSourceID) else { throw DevelopmentPresetError.invalid }
            return
        }
        if let fullRecipe {
            guard fields.isEmpty, semanticMasks == nil, resetLensBlur == nil, let boundSourceID, EditingFingerprint.isSHA256(boundSourceID) else { throw DevelopmentPresetError.invalid }
            try fullRecipe.validate()
            if let p = fullRecipe.adjustmentsV3 {
                for layer in p.masks where layer.kind == .subject {
                    guard let snapshot = layer.semanticSnapshot else { throw DevelopmentPresetError.semanticMask }
                    guard snapshot.source.sourceContentID == boundSourceID else { throw DevelopmentPresetError.differentSource }
                }
                guard p.light.clippingPreview == nil, p.selectiveColor.visualiseRange == nil,
                      p.selectiveColor.visualiseIsolation == nil else { throw DevelopmentPresetError.invalid }
                if let binding = p.localEdits.sourceBinding, binding.sourceContentID != boundSourceID {
                    throw DevelopmentPresetError.differentSource
                }
            }
            return
        }
        guard boundSourceID == nil else { throw DevelopmentPresetError.invalid }
        var light = DevelopmentLightV3(enabled: true)
        for (_, key, target) in Self.lightFields { if let value = self[keyPath: key] { light[keyPath: target] = value } }
        light.brillianceVersion = brillianceVersion
        try light.validate()
        var color = DevelopmentColorV3(enabled: true)
        for (_, key, target) in Self.colorFields { if let value = self[keyPath: key] { color[keyPath: target] = value } }
        try color.validate()
        for (key, _) in Self.pointChannels {
            if let point = self[keyPath: key] {
                guard curves == nil else { throw DevelopmentPresetError.invalid }
                try point.validate()
            }
        }
        try curves?.validate()
        try filter?.validate()
        try legacyFields?.validate()
        guard legacyBasis == nil || (grading == nil && legacyFields == nil) else { throw DevelopmentPresetError.invalid }
        try legacyBasis?.validate()
        try grading?.validate()
    }

    /// Return validated native adjustment commands so preview and adoption run through the same edit transaction.
    public func commands(from original: DevelopmentRecipe, amount: Double) throws -> [DevelopmentAdjustmentCommand] {
        try validate()
        guard semanticMasks == nil else { throw DevelopmentPresetError.needsPreparation }
        guard !hasFullRecipe, amount.isFinite, (0...1).contains(amount),
              let p = try original.promotingToV3().adjustmentsV3 else { throw DevelopmentPresetError.invalid }
        guard amount != 0 else { return [] }
        if amount != 1 && (filter != nil || resetLensBlur != nil || legacyBasis != nil || brillianceVersion != nil || (brilliance != nil && p.light.brillianceVersion != nil)) {
            throw DevelopmentPresetError.unsupportedAmount
        }
        func interpolate(_ old: Double, _ new: Double) -> Double { amount == 1 ? new : old + (new - old) * amount }
        var commands: [DevelopmentAdjustmentCommand] = []
        var light = p.light
        for (_, key, target) in Self.lightFields {
            if let value = self[keyPath: key] {
                light[keyPath: target] = interpolate(p.light.enabled ? p.light[keyPath: target] : 0, value)
                if value != 0 { light.enabled = true }
            }
        }
        if brilliance != nil { light.brillianceVersion = brillianceVersion }
        if light != p.light { try light.validate(); commands.append(.setParameters(.light(light))) }
        var color = p.color
        for (_, key, target) in Self.colorFields {
            if let value = self[keyPath: key] {
                color[keyPath: target] = interpolate(p.color.enabled ? p.color[keyPath: target] : 0, value)
                if value != 0 { color.enabled = true }
            }
        }
        if color != p.color { try color.validate(); commands.append(.setParameters(.color(color))) }
        var curveTarget = curves
        for (key, channel) in Self.pointChannels {
            if let point = self[keyPath: key] {
                if curveTarget == nil { curveTarget = p.curves }
                curveTarget?[keyPath: channel].curve = point
                curveTarget?.enabled = true
            }
        }
        if let curveTarget {
            let value = try Self.mixCurves(from: p.curves, to: curveTarget, amount: amount)
            if value != p.curves { commands.append(.setParameters(.curves(value))) }
        }
        if let filter, filter != p.filter { commands.append(.setParameters(.filter(filter))) }
        var mergedBasis = legacyBasis ?? p.legacyBasis
        if let legacyFields { mergedBasis = try legacyFields.applying(to: mergedBasis, amount: amount) }
        if let grading {
            let prior = mergedBasis?.color?.grading ?? .init()
            let mixed = Self.mixGrading(prior, grading, amount: amount)
            if mixed != prior {
                var basis: DevelopmentLegacyBasis = mergedBasis ?? DevelopmentLegacyBasis(version: .v2, color: DevelopmentColorAdjustments())
                basis.version = .v2
                if basis.color == nil { basis.color = .init() }
                basis.color?.grading = mixed
                mergedBasis = basis
            }
        }
        if mergedBasis != p.legacyBasis { commands.append(.setLegacyBasis(mergedBasis)) }
        if resetLensBlur == true, var effects = p.effects, effects.lensBlur != nil {
            effects.lensBlur = nil
            commands.append(.setEffects(effects))
        }
        return commands
    }

    public func supportsAmount(from base: DevelopmentRecipe) -> Bool {
        !isEmpty && !hasFullRecipe && semanticMasks == nil && (try? commands(from: base, amount: 0.5)) != nil
    }

    private static func mixGrading(_ baseline: DevelopmentColorGrading, _ target: DevelopmentColorGrading, amount: Double) -> DevelopmentColorGrading {
        if amount == 1 { return target }
        let a = baseline.isEnabled ? baseline : DevelopmentColorGrading()
        let b = target.isEnabled ? target : DevelopmentColorGrading()
        func mix(_ old: Double, _ new: Double) -> Double { old + (new - old) * amount }
        func wheel(_ old: DevelopmentGradingWheel, _ new: DevelopmentGradingWheel) -> DevelopmentGradingWheel {
            let start = old.saturation == 0 ? new.hueDegrees : old.hueDegrees
            let end = new.saturation == 0 ? start : new.hueDegrees
            let arc = (end - start + 540).truncatingRemainder(dividingBy: 360) - 180
            let hue = (start + amount * arc + 360).truncatingRemainder(dividingBy: 360)
            return .init(hueDegrees: hue, saturation: mix(old.saturation, new.saturation), luminance: mix(old.luminance, new.luminance))
        }
        return .init(shadows: wheel(a.shadows, b.shadows), midtones: wheel(a.midtones, b.midtones),
            highlights: wheel(a.highlights, b.highlights), global: wheel(a.global, b.global),
            blending: mix(a.blending, b.blending), balance: mix(a.balance, b.balance))
    }

    static func mixCurves(from old: DevelopmentCurvesV3, to target: DevelopmentCurvesV3, amount: Double) throws -> DevelopmentCurvesV3 {
        if amount == 1 || old == target { return target }
        guard old.parametric == nil, target.parametric == nil, old.refineSaturation == nil, target.refineSaturation == nil,
              !old.enabled || !target.enabled || old.algorithm == target.algorithm else {
            throw DevelopmentPresetError.unsupportedAmount
        }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        var result = target
        result.enabled = old.enabled || target.enabled
        if !target.enabled { result.algorithm = old.algorithm }
        for channel in [\DevelopmentCurvesV3.rgb, \.red, \.green, \.blue] {
            let a = old.enabled ? old[keyPath: channel] : .init()
            let b = target.enabled ? target[keyPath: channel] : .init()
            let ax = a.curve.points.map(\.x), bx = b.curve.points.map(\.x)
            guard ax == bx || a.curve.isNeutral || b.curve.isNeutral else { throw DevelopmentPresetError.unsupportedAmount }
            let xs = a.curve.isNeutral ? bx : ax
            let points = xs.enumerated().map { index, x in
                DevelopmentCurvePoint(x: x, y: mix(a.curve.isNeutral ? x : a.curve.points[index].y,
                                                    b.curve.isNeutral ? x : b.curve.points[index].y))
            }
            result[keyPath: channel] = .init(curve: .init(points: points), inputBlack: mix(a.inputBlack, b.inputBlack),
                                              inputWhite: mix(a.inputWhite, b.inputWhite))
        }
        try result.validate()
        return result
    }

}
