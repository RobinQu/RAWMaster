import RAWMasterCore

/// App-only provenance for the three summary controls. Never encoded into a recipe or inferred
/// from pixels. Fixed fields bound storage independently of the number of slider input events.
struct DevelopmentSummaryUIState: Equatable {
    enum Parameters: Equatable {
        case light(DevelopmentLightV3), color(DevelopmentColorV3), blackAndWhite(DevelopmentBlackAndWhiteV3)
        init?(_ group: DevelopmentAdjustmentID, recipe: DevelopmentRecipe) {
            let parameters = recipe.adjustmentsV3 ?? .init()
            switch group {
            case .light:
                var value = parameters.light; value.enabled = false; self = .light(value)
            case .color:
                var value = parameters.color; value.enabled = false; self = .color(value)
            case .blackAndWhite:
                var value = parameters.blackAndWhite; value.enabled = false; self = .blackAndWhite(value)
            default: return nil
            }
        }
    }
    private struct Known: Equatable { let amount: Double; let parameters: Parameters }
    private var light: Known?
    private var color: Known?
    private var blackAndWhite: Known?
    var presetAdoptions: [DevelopmentPresetAdoption] = []
    var presetAuditBytes: Int { presetAdoptions.reduce(0) { $0 + $1.estimatedBytes } }
    init() {}
    static let groups: [DevelopmentAdjustmentID] = [.light, .color, .blackAndWhite]
    static let conservativeCost = 1024
    var isEmpty: Bool { light == nil && color == nil && blackAndWhite == nil && presetAdoptions.isEmpty }
    var amounts: [DevelopmentAdjustmentID: Double] {
        var result: [DevelopmentAdjustmentID: Double] = [:]
        for group in Self.groups { if let known = value(group) { result[group] = known.amount } }
        return result
    }
    private func value(_ group: DevelopmentAdjustmentID) -> Known? {
        switch group { case .light: return light; case .color: return color; case .blackAndWhite: return blackAndWhite; default: return nil }
    }
    private mutating func set(_ known: Known?, for group: DevelopmentAdjustmentID) {
        switch group { case .light: light = known; case .color: color = known; case .blackAndWhite: blackAndWhite = known; default: break }
    }
    func validating(for recipe: DevelopmentRecipe) -> Self {
        var result = self
        for group in Self.groups {
            if let known = value(group), Parameters(group, recipe: recipe) != known.parameters { result.set(nil, for: group) }
        }
        return result
    }
    func reconciling(to recipe: DevelopmentRecipe, commands: [DevelopmentAdjustmentCommand] = []) -> Self {
        var result = validating(for: recipe)
        for command in commands {
            switch command {
            case .reset(let group): result.set(nil, for: group)
            case .resetAll: result = .init()
            default: break
            }
        }
        return result
    }
    mutating func remember(group: DevelopmentAdjustmentID, amount: Double, recipe: DevelopmentRecipe) {
        guard amount.isFinite, (-1...1).contains(amount), let parameters = Parameters(group, recipe: recipe) else { return }
        set(.init(amount: amount, parameters: parameters), for: group)
    }
}
