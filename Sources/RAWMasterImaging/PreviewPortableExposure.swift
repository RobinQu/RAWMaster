import Foundation
import RAWMasterCore
import RAWMasterImage

enum PreviewPortableExposure {
    static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_PORTABLE_METAL_PREVIEW"] == "1"

    static func eligibility(_ parameters: DevelopmentAdjustmentsV3, input: PreviewInteractiveInputDescriptor) -> Double? {
        guard enabled, (!input.sourceIsRAW || input.usesFlashRaw),
              input.contentRect == CGRect(origin: .zero, size: input.proxySize),
              parameters.light.enabled, parameters.light.exposure != 0,
              parameters.light == .init(enabled: true, exposure: parameters.light.exposure) else { return nil }
        var other = parameters
        other.light = .init()
        if other.legacyBasis?.isPixelNeutral == true { other.legacyBasis = nil }
        var neutral = parameters.neutralForSameSource
        neutral.rawDetails = parameters.rawDetails
        guard other == neutral else { return nil }
        return 2 * parameters.light.exposure
    }

    static func plan(ev: Double) throws -> RAWMasterImageKernel.RasterPlan {
        guard ev.isFinite else { throw DevelopmentError.invalidEncoding }
        let recipe = """
            {"version":1,"working":"extended-linear-srgb-premul-f32","output":"exposure","nodes":[
            {"id":"source","op":"source"},
            {"id":"exposure","op":"exposure","image":"source","ev":\(ev)}]}
            """
        return try RAWMasterImageKernel.RasterPlan(recipe: Data(recipe.utf8), backend: .cpu)
    }
}
