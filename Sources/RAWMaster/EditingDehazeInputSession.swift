import Foundation
import Combine
import RAWMasterCore

struct EditingDehazeAmountToken: Hashable {
    let id: UUID
    let context: EditingInteractionContext
    let draftFingerprint: String
    let gesture: EditingGestureToken?
}

/// One scalar intent and at most one resolved metadata record. No Task, worker, bitmap or history.
@MainActor final class EditingDehazeInputSession: ObservableObject {
    private weak var editing: EditingController?
    @Published private(set) var wantedAmount: Double?
    @Published private(set) var tracking: EditingDehazeAmountToken?
    @Published private(set) var preparing = false
    @Published private(set) var waitingForRelease = false
    @Published private(set) var cancelling = false
    private var retiringID: UUID?
    private struct Intent {
        let id: UUID
        let context: EditingInteractionContext
        let projection: DevelopmentDehazeProjectionV1
        var resolved: (DevelopmentResolvedDehazeV1, EditingDevelopmentAnalysisTicket)?
    }
    private var intent: Intent?
    private var revoking = false
    var hasPendingInput: Bool { tracking != nil || intent != nil }
    var operationID: UUID? { intent?.id }
    init(editing: EditingController) { self.editing = editing }
    func begin(context: EditingInteractionContext) throws -> EditingDehazeAmountToken {
        guard let editing, !revoking, tracking == nil else { throw EditingDevelopmentSessionError.unfinishedGesture }
        let projection = try editing.developmentDehazeProjection(context: context)
        let ready = try editing.recipe.dehazePreparationStatusV1(context: projection.input.context) == .ready
        let gesture: EditingGestureToken?
        if intent == nil && ready {
            gesture = try editing.developmentSession.beginGesture(.init(group: .dehaze, name: "去朦胧"), context: context)
        } else { gesture = nil }
        let token = EditingDehazeAmountToken(id: UUID(), context: context,
            draftFingerprint: projection.presentedRecipeFingerprint, gesture: gesture)
        tracking = token
        return token
    }
    func change(_ amount: Double, token: EditingDehazeAmountToken) throws {
        guard let editing, !revoking, tracking == token, amount.isFinite, (-100...100).contains(amount) else {
            throw EditingDevelopmentSessionError.staleInteraction
        }
        if let gesture = token.gesture {
            try editing.applyDevelopmentDehazeAmount(amount, context: token.context, gesture: gesture)
        } else {
            // Every Controller recipe write revokes this token. Recheck current source/scope
            // here; full draft/projection fingerprints are verified at end and commit.
            _ = try editing.validateDevelopmentDehazeInput(context: token.context)
            wantedAmount = amount
            if amount == 0, intent != nil {
                let id = intent!.id; clearIntent(); retire(id, context: token.context)
                wantedAmount = 0 // this active, unpublished scalar gesture still owns its final value
            }
        }
    }
    func end(_ token: EditingDehazeAmountToken, cancelled: Bool = false) throws {
        guard let editing, !revoking, tracking == token else { throw EditingDevelopmentSessionError.staleInteraction }
        tracking = nil
        if let gesture = token.gesture {
            try editing.developmentSession.endGesture(gesture, cancelled ? .cancel : .commit)
            return
        }
        if cancelled { cancel(); return }
        let current = try editing.developmentDehazeProjection(context: token.context,
            algorithm: intent?.projection.input.algorithm, wantedAmount: wantedAmount)
        guard current.presentedRecipeFingerprint == token.draftFingerprint else { cancel(); throw EditingDevelopmentSessionError.staleInteraction }
        guard let wantedAmount, wantedAmount != 0 else { cancel(); return }
        if intent != nil { try commitIfReady(); return }
        let id = UUID()
        intent = .init(id: id, context: token.context, projection: current)
        preparing = true
        editing.enqueueDevelopmentDehaze(current, operationID: id, context: token.context)
    }
    func commit(_ amount: Double, context: EditingInteractionContext) throws {
        let token = try begin(context: context)
        do { try change(amount, token: token); try end(token) }
        catch { if tracking == token { cancel() }; throw error }
    }
    func receive(_ resolved: DevelopmentResolvedDehazeV1, ticket: EditingDevelopmentAnalysisTicket) throws {
        guard var pending = intent, pending.id == ticket.operationID, pending.context == ticket.context else {
            throw EditingDevelopmentSessionError.staleAnalysis
        }
        pending.resolved = (resolved, ticket); intent = pending
        preparing = false; waitingForRelease = tracking != nil
        try commitIfReady()
    }
    private func commitIfReady() throws {
        guard let editing, tracking == nil, let pending = intent, let (result, ticket) = pending.resolved else { return }
        guard editing.developmentSession.activeGesture == nil, let amount = wantedAmount, amount != 0 else { cancel(); return }
        let current = try editing.developmentDehazeProjection(context: pending.context, algorithm: pending.projection.input.algorithm)
        guard current.presentedRecipeFingerprint == pending.projection.presentedRecipeFingerprint,
              current.input == pending.projection.input else { cancel(); throw EditingDevelopmentSessionError.staleAnalysis }
        clearIntent()
        try editing.acceptDevelopmentDehaze(result, ticket: ticket, expectedInput: pending.projection.input, wantedAmount: amount)
    }
    func analysisRevoked(_ id: UUID) {
        guard intent?.id == id else { return }
        let previous = revoking; revoking = true; defer { revoking = previous }
        tracking = nil; clearIntent()
    }
    func recipeWillChange(preservingTracking: Bool) { if !preservingTracking { cancel(commitReadyGesture: true) } }
    func gestureChanged(_ control: EditingControlID, active: Bool) {
        guard !revoking else { return }
        if active, control.group != .dehaze { cancel() }
        if !active, let token = tracking, let gesture = token.gesture, editing?.developmentSession.activeGesture != gesture { tracking = nil }
    }
    func cancel(commitReadyGesture: Bool = false) {
        guard !revoking else { return }
        revoking = true; defer { revoking = false }
        let token = tracking, pending = intent
        tracking = nil; clearIntent()
        if let pending { retire(pending.id, context: pending.context) }
        if let gesture = token?.gesture { try? editing?.developmentSession.endGesture(gesture, commitReadyGesture ? .commit : .cancel) }
    }
    private func retire(_ id: UUID, context: EditingInteractionContext) {
        if editing?.revokeDevelopmentDehazeAnalysis(id, context: context) == true { retiringID = id; cancelling = true }
    }
    func analysisOwnerFinished(_ id: UUID) {
        if retiringID == id { retiringID = nil; cancelling = false }
        // A superseded/malformed delivery must not leave a permanent preparing indicator.
        if let pending = intent, pending.id == id, pending.resolved == nil {
            analysisRevoked(id)
            _ = editing?.revokeDevelopmentDehazeAnalysis(id, context: pending.context)
        }
    }
    private func clearIntent() {
        let previous = revoking; revoking = true; defer { revoking = previous }
        intent = nil; wantedAmount = nil; preparing = false; waitingForRelease = false
    }
}
