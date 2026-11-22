import Foundation

/// Older photos store exposure and tone/curve adjustments in a different render stage and numeric domain.
public struct DevelopmentPresetLegacyFields: Codable, Equatable, Sendable {
    public private(set) var exposureEV: Double?
    public private(set) var tones: [String: Double] = [:]
    public private(set) var curves: DevelopmentCurves?
    private static let toneFields: [(DevelopmentPresetField, WritableKeyPath<DevelopmentTones, Double>)] = [
        (.contrast, \.contrast), (.highlights, \.highlights), (.shadows, \.shadows), (.whites, \.whites),
        (.blackPoint, \.blacks), (.vibrance, \.vibrance), (.saturation, \.saturation)
    ]
    public var fields: Set<DevelopmentPresetField> {
        var result = Set(tones.keys.compactMap(DevelopmentPresetField.init(rawValue:)))
        if exposureEV != nil { result.insert(.exposure) }
        if curves != nil { result.insert(.curves) }
        return result
    }
    init(exposure: Double, color: DevelopmentColorAdjustments?, fields: Set<DevelopmentPresetField>) {
        if fields.contains(.exposure) { exposureEV = exposure }
        let values = color ?? .init()
        for (field, key) in Self.toneFields where fields.contains(field) { tones[field.rawValue] = values.tones[keyPath: key] }
        if fields.contains(.curves) { curves = values.curves }
    }
    mutating func setExposureEV(_ value: Double) { exposureEV = value }
    public func validate() throws {
        if let exposureEV, !(-10...10).contains(exposureEV) { throw DevelopmentPresetError.invalid }
        let supported = Set(Self.toneFields.map { $0.0.rawValue })
        guard !fields.isEmpty, Set(tones.keys).isSubset(of: supported), tones.values.allSatisfy({ (-100...100).contains($0) }) else {
            throw DevelopmentPresetError.invalid
        }
        try curves?.validate()
    }
    func applying(to old: DevelopmentLegacyBasis?, amount: Double) throws -> DevelopmentLegacyBasis? {
        var basis: DevelopmentLegacyBasis = old ?? DevelopmentLegacyBasis(version: .v1)
        func mix(_ a: Double, _ b: Double) -> Double { amount == 1 ? b : a + (b - a) * amount }
        if let exposureEV { basis.exposureEV = mix(basis.exposureEV, exposureEV) }
        var color: DevelopmentColorAdjustments = basis.color ?? DevelopmentColorAdjustments()
        let original = color
        for (field, key) in Self.toneFields {
            if let value = tones[field.rawValue] { color.tones[keyPath: key] = mix(color.tones[keyPath: key], value) }
        }
        if let curves {
            func channels(_ value: DevelopmentCurves) -> DevelopmentCurvesV3 {
                .init(enabled: true, rgb: .init(curve: value.rgb), red: .init(curve: value.red),
                      green: .init(curve: value.green), blue: .init(curve: value.blue))
            }
            let result = try DevelopmentPresetPatch.mixCurves(from: channels(color.curves), to: channels(curves), amount: amount)
            color.curves = .init(rgb: result.rgb.curve, red: result.red.curve, green: result.green.curve, blue: result.blue.curve)
        }
        if color != original { basis.version = .v2; basis.color = color }
        try basis.validate()
        return old == nil && basis.isPixelNeutral ? nil : basis
    }
}
