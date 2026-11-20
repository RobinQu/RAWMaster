import SwiftUI
import RAWMasterCore

/// These are RAWMaster's versioned amount units, not a claim of Photos/ACR slider equivalence.
enum PhotosAdvancedDetailEditing {
    static let groups: [DevelopmentAdjustmentID] = [.texture, .clarity]
    static let amountRange: ClosedRange<Double> = -100...100
    enum Change { case amount(Double), enabled(Bool), reset }

    static func value(_ group: DevelopmentAdjustmentID, in parameters: DevelopmentAdjustmentsV3) throws -> DevelopmentDetailAmountV3 {
        switch group {
        case .texture: return parameters.advancedDetail.texture
        case .clarity: return parameters.advancedDetail.clarity
        default: throw EditingError.invalidRecipe
        }
    }
    static func command(_ group: DevelopmentAdjustmentID, change: Change,
                        parameters: DevelopmentAdjustmentsV3) throws -> DevelopmentAdjustmentCommand? {
        let current = try value(group, in: parameters)
        var next = current
        switch change {
        case .amount(let amount):
            guard amount.isFinite, amountRange.contains(amount) else { throw EditingError.invalidRecipe }
            // Confirming an unchanged zero must not enable a group or promote an old recipe.
            guard amount != current.amount else { return nil }
            next.amount = amount; next.enabled = true
        case .enabled(let enabled): next.enabled = enabled
        case .reset: next = .init()
        }
        try next.validate()
        guard next != current else { return nil }
        switch group {
        case .texture: return .setParameters(.texture(next))
        case .clarity: return .setParameters(.clarity(next))
        default: throw EditingError.invalidRecipe
        }
    }
}

/// Kept inside the existing advanced disclosure, separately enabled and reset per operator.
/// The Controller intersects this closed UI list with the actual renderer's source facts.
struct PhotosAdvancedDetailControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    var body: some View {
        ForEach(editing.availableDevelopmentAdvancedDetailGroups, id: \.self) { group in
            PhotosAdjustmentSection(id: group, expanded: true,
                enabled: session.parameters.isEnabled(group),
                modified: PhotosAdjustmentCommands.isModified(group, in: session.parameters),
                onExpand: {},
                onEnable: { enabled in discrete(group, .enabled(enabled)) },
                onReset: { discrete(group, .reset) },
                showsDisclosure: false) {
                    PhotosRecipeValueRow(session: session, context: context, title: "数量", control: "advanced." + group.rawValue,
                        value: amount(group), range: PhotosAdvancedDetailEditing.amountRange,
                        apply: { value, token in
                            try editing.changeDevelopmentAdvancedDetail(group, change: .amount(value), context: context, gesture: token)
                        }, onError: report)
                        .accessibilityIdentifier("photos." + group.rawValue + ".amount")
                }
        }
    }
    private func amount(_ group: DevelopmentAdjustmentID) -> Double {
        (try? PhotosAdvancedDetailEditing.value(group, in: session.parameters).amount) ?? 0
    }
    private func discrete(_ group: DevelopmentAdjustmentID, _ change: PhotosAdvancedDetailEditing.Change) {
        perform {
            guard session.context == context else { throw EditingDevelopmentSessionError.staleInteraction }
            if let token = session.activeGesture { try session.endGesture(token, .commit) }
            try editing.changeDevelopmentAdvancedDetail(group, change: change, context: context)
        }
    }
    private func report(_ error: Error) {
        if session.context == context { editing.message = "细节调整未应用，请检查数值或等待照片准备完成。" }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { report(error) } }
}
