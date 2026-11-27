import Foundation
import Combine
import RAWMasterCore

struct EditingInteractionContext: Hashable, Sendable {
    let workID: String
    let admissionFingerprint: String
    let sourceContentID: String
    let sourceGeneration: UInt64
    let draftBranchID: EditingDraftBranchID
    let draftBranchEpoch: UInt64
    var historyKey: DevelopmentHistoryKey {
        .init(workID: workID, admissionFingerprint: admissionFingerprint,
              sourceContentID: sourceContentID, branchID: draftBranchID)
    }
}
struct EditingControlID: Hashable { let group: DevelopmentAdjustmentID?; let name: String }
struct EditingCommandEvent {
    let context: EditingInteractionContext
    let control: EditingControlID
    let nativeInput: EditingPreviewInput?
    init(context: EditingInteractionContext, control: EditingControlID, nativeInput: EditingPreviewInput? = nil) {
        self.context = context; self.control = control; self.nativeInput = nativeInput
    }
}
struct EditingGestureToken: Hashable { let id: UUID; let context: EditingInteractionContext }
enum EditingGestureDisposition { case commit, cancel }
enum EditingInteractionInvalidationReason { case sourceInvalidated, termination, viewTeardown }
enum EditingDevelopmentPage: String, CaseIterable { case adjust = "调整", filters = "滤镜", crop = "裁切" }
enum EditingDevelopmentSessionError: Error, Equatable {
    case inactive, staleInteraction, unfinishedGesture, wrongGesture, recipeDiverged, commitRejected
    case missingSourceCapability, staleAnalysis, staleFrame, epochExhausted, invalidIdentity
}
struct EditingDisplayedFrameContext {
    let frameID: UUID
    let interaction: EditingInteractionContext
    let recipeFingerprint: String
    let stage: DevelopmentAnalysisStage
}
struct EditingDevelopmentAnalysisTicket {
    let operationID: UUID
    let context: EditingInteractionContext
    let expectedRecipeFingerprint: String
    let draftRecipeFingerprint: String
    let analysisRecipe: DevelopmentRecipe
    let stage: DevelopmentAnalysisStage
    let sessionStage: DevelopmentAnalysisStage
    let gesture: EditingGestureToken?
    let nativeInput: EditingPreviewInput?
}
struct EditingGeometryAnalysisTicket {
    let analysis: EditingDevelopmentAnalysisTicket
    let constraint: PhotosCropConstraint
    let input: DevelopmentCropAutoInputV1
}
struct EditingDevelopmentSaveTicket {
    let operationID: UUID
    let context: EditingInteractionContext
    let recipe: DevelopmentRecipe
}

/// Pure command transaction. Reading an old recipe has no promotion side effect; a no-op command
/// returns the exact old value. The caller publishes once after the entire command list validates.
enum EditingDevelopmentTransaction {
    static let maximumCommands = 64
    static func applying(_ commands: [DevelopmentAdjustmentCommand], to original: DevelopmentRecipe,
                         context: DevelopmentAdjustmentCommandContext,
                         noiseReduction: DevelopmentNoiseReductionSourceCapability?) throws -> DevelopmentRecipe {
        try original.validate()
        guard commands.count <= maximumCommands else { throw EditingError.invalidRecipe }
        guard !commands.isEmpty else { return original }
        let promoted = try original.promotingToV3()
        var candidate = promoted
        for command in commands {
            var resolved = command
            if case .setEnabled(.noiseReduction, true) = command {
                guard let noiseReduction else { throw EditingDevelopmentSessionError.missingSourceCapability }
                var parameters = candidate.adjustmentsV3!.noiseReduction
                parameters.enabled = true; parameters.sourceCapability = noiseReduction
                resolved = .setParameters(.noiseReduction(parameters))
            }
            candidate = try candidate.applying(resolved, context: context)
            if candidate.adjustmentsV3?.noiseReduction.enabled == true {
                guard let noiseReduction else { throw EditingDevelopmentSessionError.missingSourceCapability }
                try candidate.adjustmentsV3?.noiseReduction.validate(for: noiseReduction)
            }
        }
        if candidate == promoted { return original }
        if original.schemaVersion < 3 {
            // A neutral legacy geometry tag alone is not an edit. In particular, resetting an
            // already neutral old recipe must not create a new engine version/history entry.
            var neutralProjection = promoted
            var geometry = promoted.adjustmentsV3!.geometry; geometry.version = .adjustV3
            if geometry == DevelopmentGeometryV3() {
                neutralProjection.adjustmentsV3!.geometry = geometry
                if candidate == neutralProjection { return original }
            }
        }
        return candidate
    }
}

/// Owns only interaction identity and bounded metadata history. Controller remains the sole draft
/// recipe authority through synchronous read/commit closures. Native analysis belongs to the
/// Controller's owned driver and the existing PreviewService worker, not this history/session.
@MainActor final class EditingDevelopmentSession: ObservableObject {
    @Published private(set) var context: EditingInteractionContext?
    @Published private(set) var page: EditingDevelopmentPage = .adjust
    @Published private(set) var revision = UUID()
    struct PresetAmountSession {
        let record: DevelopmentPresetRecord
        let baseline: DevelopmentRecipe
        let amount: Double
        let context: EditingInteractionContext
        let priorAdoptions: [DevelopmentPresetAdoption]
    }
    static let presetAmountControl = "预设强度"
    private(set) var presetAmountSession: PresetAmountSession?
    var presetAdoptions: [DevelopmentPresetAdoption] { summaryUI.presetAdoptions }
    var presetAdoptionsChanged: (() -> Void)?
    private var publishedAdoptions: [DevelopmentPresetAdoption] = []

    func restorePresetAdoptions(_ adoptions: [DevelopmentPresetAdoption], for expected: DevelopmentRecipe) {
        guard recipe == expected, summaryUI.presetAdoptions.isEmpty, !adoptions.isEmpty,
              adoptions.allSatisfy({ $0.sourceID == context?.sourceContentID }) else { return }
        summaryUI.presetAdoptions = adoptions
        history.updateCurrentUI(summaryUI, current: expected)
        publishedAdoptions = adoptions
    }
    var presetCapabilityIssue: ((DevelopmentPresetRecord, EditingInteractionContext) -> String?)?
    @Published private(set) var expandedSections: Set<String> = []
    var expandedGroups: Set<DevelopmentAdjustmentID> {
        Set(expandedSections.compactMap(DevelopmentAdjustmentID.init(rawValue:)))
    }
    private struct SectionDisclosure {
        var expanded: Set<String> = []
        var initialized: Set<String> = []
    }
    private var sectionDisclosures: [DevelopmentHistoryKey: SectionDisclosure] = [:]
    @Published private(set) var expandedOptions: Set<DevelopmentAdjustmentID> = []
    @Published private(set) var cropConstraint = PhotosCropConstraint()
    private var cropConstraintKey: DevelopmentHistoryKey?
    private(set) var history: DevelopmentUndoHistory
    /// Named recipe pointers are scoped to the same source/branch identity as undo history.
    /// Restoring one creates a normal history entry instead of moving or destroying the cursor.
    private var snapshotStorage: [DevelopmentHistoryKey: [DevelopmentSnapshot]] = [:]
    var snapshotCatalog: ((EditingInteractionContext, DevelopmentSnapshotEdit?) throws -> [DevelopmentSnapshot])?

    func reloadSnapshots(context: EditingInteractionContext) throws {
        if let snapshotCatalog {
            snapshotStorage[context.historyKey] = try snapshotCatalog(context, nil)
        }
    }
    func displayPersistedSnapshots(_ rows: [DevelopmentSnapshot], in context: EditingInteractionContext) {
        snapshotStorage[context.historyKey] = rows
        revision = UUID()
    }
    private var summaryUI = DevelopmentSummaryUIState()
    private(set) var source: DevelopmentLocalEditSourceBinding?
    private(set) var analysisStage: DevelopmentAnalysisStage = .workingImageBeforeGeometry
    private(set) var noiseReductionCapability: DevelopmentNoiseReductionSourceCapability?
    private let readRecipe: () -> DevelopmentRecipe
    private let commitRecipe: (DevelopmentRecipe, EditingCommandEvent) throws -> Void
    private var acceptingInput = false
    private var epoch: UInt64 = 0
    private struct Gesture {
        let token: EditingGestureToken
        let control: EditingControlID
        let before: DevelopmentRecipe
        let beforeUI: DevelopmentSummaryUIState
        var lastApplied: DevelopmentRecipe
    }
    private var gesture: Gesture?
    private var pendingAnalysis: EditingDevelopmentAnalysisTicket?
    private var latestSave: EditingDevelopmentSaveTicket?
    /// Only forwards cancellation to the real owner later; it does not claim native work has joined.
    var invalidateAnalysis: ((UUID) -> Void)?
    var gestureActivityChanged: ((EditingControlID, Bool) -> Void)?
    var currentDehazeContext: ((EditingInteractionContext) throws -> DevelopmentDehazeContextV1?)?
    /// Dynamic, source/generation-fenced facts from the real Controller; never a stored activation snapshot.
    var currentGrainSamplingVersions: ((EditingInteractionContext) throws -> Set<DevelopmentGrainSamplingVersion>)?
    func grainSamplingVersions(context expected: EditingInteractionContext, gesture: EditingGestureToken? = nil) throws -> Set<DevelopmentGrainSamplingVersion> {
        try validateInteraction(expected, gesture: gesture)
        guard let provider = currentGrainSamplingVersions else {
            if noiseReductionCapability == .raw { throw EditingDevelopmentSessionError.missingSourceCapability }
            return []
        }
        let versions = try provider(expected)
        try validateInteraction(expected, gesture: gesture)
        return noiseReductionCapability == .raw ? versions:[]
    }

    init(historyLimits: DevelopmentUndoHistory.Limits = .init(),
         readRecipe: @escaping () -> DevelopmentRecipe,
         commitRecipe: @escaping (DevelopmentRecipe, EditingCommandEvent) throws -> Void) {
        self.history = .init(limits: historyLimits)
        self.readRecipe = readRecipe; self.commitRecipe = commitRecipe
    }
    var recipe: DevelopmentRecipe { readRecipe() }
    /// A UI-only projection. It never calls promotingToV3 or changes the current recipe.
    var parameters: DevelopmentAdjustmentsV3 { recipe.adjustmentsV3 ?? .init() }
    var summaryAmounts: [DevelopmentAdjustmentID: Double] {
        guard acceptingInput, context != nil else { return [:] }
        return summaryUI.validating(for: recipe).amounts
    }
    var canUndo: Bool { acceptingInput && context != nil && (history.canUndo || gesture.map { $0.before != $0.lastApplied } == true) }
    var canRedo: Bool { acceptingInput && context != nil && gesture == nil && history.canRedo }
    var undoTitle: String? { history.undoTitle }
    var redoTitle: String? { history.redoTitle }
    var historyItems: [DevelopmentHistoryItem] { history.items }
    var snapshots: [DevelopmentSnapshot] {
        context.map { snapshots(in: $0) } ?? []
    }

    func snapshots(in presentation: EditingInteractionContext) -> [DevelopmentSnapshot] {
        snapshotStorage[presentation.historyKey] ?? []
    }

    var activeGesture: EditingGestureToken? { gesture?.token }
    var activeControl: EditingControlID? { gesture?.control }
    func beginningRecipe(for token: EditingGestureToken) throws -> DevelopmentRecipe {
        try validateInteraction(token.context, gesture: token)
        guard let gesture else { throw EditingDevelopmentSessionError.wrongGesture }
        return gesture.before
    }
    func validateInteraction(_ expected: EditingInteractionContext, gesture token: EditingGestureToken? = nil) throws {
        try require(expected)
        if let token {
            guard let gesture, gesture.token == token, token.context == expected else { throw EditingDevelopmentSessionError.wrongGesture }
            guard gesture.lastApplied == recipe else { throw EditingDevelopmentSessionError.recipeDiverged }
        } else if gesture != nil { throw EditingDevelopmentSessionError.unfinishedGesture }
    }

    /// Call prepareForBranchReplacement BEFORE replacing Controller's recipe, then activate the
    /// already installed draft. Explicit selectVersion/continueFrom omit branchID, even for same data.
    /// A remembered draft may resume its stable branchID, with a fresh interaction epoch.
    @discardableResult func activate(workID: String, admissionFingerprint: String,
                                    source: DevelopmentLocalEditSourceBinding, sourceGeneration: UInt64,
                                    branchID: EditingDraftBranchID = .init(),
                                    stage: DevelopmentAnalysisStage = .workingImageBeforeGeometry,
                                    noiseReduction: DevelopmentNoiseReductionSourceCapability? = nil) throws -> EditingInteractionContext {
        guard gesture == nil else { throw EditingDevelopmentSessionError.unfinishedGesture }
        guard !workID.isEmpty, workID.utf8.count <= 1024, EditingFingerprint.isSHA256(admissionFingerprint) else {
            throw EditingDevelopmentSessionError.invalidIdentity
        }
        try source.validate(); try recipe.validate(); try advanceEpoch()
        acceptingInput = false; invalidatePendingAnalysis()
        let next = EditingInteractionContext(workID: workID, admissionFingerprint: admissionFingerprint,
            sourceContentID: source.sourceContentID, sourceGeneration: sourceGeneration,
            draftBranchID: branchID, draftBranchEpoch: epoch)
        try reloadSnapshots(context: next)
        self.source = source; noiseReductionCapability = noiseReduction; analysisStage = stage
        if cropConstraintKey != next.historyKey {
            cropConstraint = .init(orientation: source.orientedWidth >= source.orientedHeight ? .landscape : .portrait)
            cropConstraintKey = next.historyKey
        }
        expandedSections = sectionDisclosures[next.historyKey]?.expanded ?? []
        context = next; history.activate(next.historyKey, current: recipe)
        summaryUI = history.currentUI(current: recipe); acceptingInput = true; publish()
        return next
    }
    func prepareForBranchReplacement(context expected: EditingInteractionContext) throws {
        try suspend(context: expected, disposition: .cancel)
    }
    /// A normal focus/branch transition may finish or restore its valid draft, but failure must not
    /// leave its input scope alive. The caller receives the write/divergence error after revocation.
    func suspend(context expected: EditingInteractionContext, disposition: EditingGestureDisposition = .commit) throws {
        try require(expected)
        defer { revokeInteraction(expected) }
        if let gesture { try endGesture(gesture.token, disposition) }
    }
    /// No recipe read/restore/commit is permitted once the source or owner is invalid. Revocation
    /// is synchronous and cannot depend on Controller accepting another draft write during close.
    func invalidate(context expected: EditingInteractionContext, reason: EditingInteractionInvalidationReason) throws {
        try require(expected)
        revokeInteraction(expected)
    }
    @discardableResult func changePage(_ page: EditingDevelopmentPage, context expected: EditingInteractionContext) throws -> EditingInteractionContext {
        try require(expected)
        guard self.page != page else { return expected }
        if let gesture { try endGesture(gesture.token, .commit) }
        try advanceEpoch(); acceptingInput = false; invalidatePendingAnalysis(); self.page = page
        let next = replacingEpoch(expected); context = next; acceptingInput = true; publish(); return next
    }
    @discardableResult func changeAnalysisStage(_ stage: DevelopmentAnalysisStage, context expected: EditingInteractionContext) throws -> EditingInteractionContext {
        try require(expected)
        guard stage != analysisStage else { return expected }
        if let gesture { try endGesture(gesture.token, .commit) }
        try advanceEpoch(); acceptingInput = false; invalidatePendingAnalysis(); analysisStage = stage
        let next = replacingEpoch(expected); context = next; acceptingInput = true; publish(); return next
    }
    func setCropConstraint(_ value: PhotosCropConstraint, context expected: EditingInteractionContext) throws {
        try require(expected)
        guard let source else { throw EditingDevelopmentSessionError.inactive }
        _ = try value.ratio(source: source.sourceSize)
        if value != cropConstraint { invalidatePendingAnalysis() }
        cropConstraint = value
    }
    func setExpanded(_ id: DevelopmentAdjustmentID, expanded: Bool, context expected: EditingInteractionContext) throws {
        try require(expected)
        if let gesture, gesture.control.group == id { try endGesture(gesture.token, .commit) }
        updateDisclosure(id.rawValue, expanded: expanded, key: expected.historyKey)
    }
    func setExpanded(section: String, expanded: Bool, context expected: EditingInteractionContext) throws {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        updateDisclosure(section, expanded: expanded, key: expected.historyKey)
    }
    func openFirstSectionIfNeeded(_ sections: [String], context expected: EditingInteractionContext) throws {
        try require(expected)
        guard let first = sections.first else { return }
        if sections.contains(where: { sectionDisclosures[expected.historyKey]?.initialized.contains($0) == true }) { return }
        sectionDisclosures[expected.historyKey, default: .init()].initialized.formUnion(sections)
        updateDisclosure(first, expanded: true, key: expected.historyKey)
    }
    private func updateDisclosure(_ section: String, expanded: Bool, key: DevelopmentHistoryKey) {
        var value = sectionDisclosures[key, default: .init()]
        value.initialized.insert(section)
        if expanded { value.expanded.insert(section) } else { value.expanded.remove(section) }
        sectionDisclosures[key] = value
        expandedSections = value.expanded
    }
    func setOptionsExpanded(_ id: DevelopmentAdjustmentID, expanded: Bool, context expected: EditingInteractionContext) throws {
        try require(expected)
        if let gesture, gesture.control.group == id { try endGesture(gesture.token, .commit) }
        if expanded { expandedOptions.insert(id) } else { expandedOptions.remove(id) }
    }
    func beginGesture(_ control: EditingControlID, context expected: EditingInteractionContext) throws -> EditingGestureToken {
        try require(expected)
        guard gesture == nil else { throw EditingDevelopmentSessionError.unfinishedGesture }
        invalidatePendingAnalysis()
        let token = EditingGestureToken(id: UUID(), context: expected)
        gesture = .init(token: token, control: control, before: recipe, beforeUI: summaryUI.validating(for: recipe), lastApplied: recipe)
        gestureActivityChanged?(control, true)
        try require(expected)
        return token
    }
    func endPresetAmountSession() {
        guard presetAmountSession != nil else { return }
        presetAmountSession = nil
        publish()
    }

    /// Preview, click and Amount all resolve against the same immutable pre-adoption recipe.
    func previewPreset(_ record: DevelopmentPresetRecord, context expected: EditingInteractionContext,
                       revision expectedRevision: UUID, preparedMasks: [DevelopmentMaskLayerV3]? = nil) throws -> DevelopmentRecipe {
        try validateInteraction(expected)
        guard revision == expectedRevision else { throw EditingDevelopmentSessionError.staleInteraction }
        return try resolvePreset(record, baseline: recipe, amount: 1, context: expected, preparedMasks: preparedMasks)
    }

    private func resolvePreset(_ record: DevelopmentPresetRecord, baseline: DevelopmentRecipe, amount: Double,
                               context expected: EditingInteractionContext, preparedMasks: [DevelopmentMaskLayerV3]?) throws -> DevelopmentRecipe {
        guard record.reason(for: expected.sourceContentID) == nil, presetCapabilityIssue?(record, expected) == nil else { throw DevelopmentPresetError.unavailable }
        if amount != 1, !record.supportsAmount(from: baseline) { throw DevelopmentPresetError.unsupportedAmount }
        if let full = record.patch.fullRecipe {
            guard amount == 1, record.patch.boundSourceID == expected.sourceContentID else { throw DevelopmentPresetError.differentSource }
            try record.patch.validate()
            if let p = full.adjustmentsV3 {
                let target = try commandContext()
                try DevelopmentMaskLayerV3.validateSource(p.masks, expected: target.source)
                let validated = try EditingDevelopmentTransaction.applying([.setParameters(.filter(p.filter))], to: full,
                    context: target, noiseReduction: noiseReductionCapability)
                guard validated == full else { throw DevelopmentPresetError.unavailable }
            }
            return full
        }
        var patch = record.patch
        let intents = patch.semanticMasks
        patch.semanticMasks = nil
        var commands = try patch.commands(from: baseline, amount: amount)
        if let intents {
            guard amount == 1, let preparedMasks, intents.count == preparedMasks.count,
                  let source, let p = try baseline.promotingToV3().adjustmentsV3 else { throw DevelopmentPresetError.needsPreparation }
            for (intent, layer) in zip(intents, preparedMasks) {
                guard let snapshot = layer.semanticSnapshot, snapshot.source == source, snapshot.target == intent.target,
                      !snapshot.wasRefined, snapshot.prompt.isEmpty, layer.kind == .subject,
                      layer.name == intent.name, layer.enabled == intent.enabled, layer.inverted == intent.inverted,
                      layer.opacity == intent.opacity, layer.adjustments == intent.adjustments else {
                    throw DevelopmentPresetError.needsPreparation
                }
            }
            commands.append(.setMasks(p.masks + preparedMasks))
        } else if preparedMasks != nil { throw DevelopmentPresetError.invalid }
        return try EditingDevelopmentTransaction.applying(commands, to: baseline, context: try commandContext(),
                                                          noiseReduction: noiseReductionCapability)
    }

    @discardableResult
    func adoptPreset(_ record: DevelopmentPresetRecord, amount: Double = 1, context expected: EditingInteractionContext,
                     revision expectedRevision: UUID, adjustingAmount: Bool = false, gesture token: EditingGestureToken? = nil,
                     preparedMasks: [DevelopmentMaskLayerV3]? = nil) throws -> Bool {
        try validateInteraction(expected, gesture: token)
        guard revision == expectedRevision else { throw EditingDevelopmentSessionError.staleInteraction }
        let before = recipe
        let anchor = presetAmountSession
        if adjustingAmount {
            guard anchor?.record == record, anchor?.context == expected else { throw EditingDevelopmentSessionError.staleInteraction }
        }
        let baseline: DevelopmentRecipe, priorAdoptions: [DevelopmentPresetAdoption]
        if let anchor, anchor.record == record, anchor.context == expected, record.patch.semanticMasks == nil {
            baseline = anchor.baseline
            priorAdoptions = anchor.priorAdoptions
        } else {
            baseline = before
            priorAdoptions = summaryUI.presetAdoptions
        }
        let after = try resolvePreset(record, baseline: baseline, amount: amount, context: expected, preparedMasks: preparedMasks)
        try validateInteraction(expected, gesture: token)
        guard revision == expectedRevision, recipe == before else { throw EditingDevelopmentSessionError.recipeDiverged }
        let next = PresetAmountSession(record: record, baseline: baseline, amount: amount, context: expected, priorAdoptions: priorAdoptions)
        if after == before {
            if anchor?.record != record || anchor?.amount != amount {
                presetAmountSession = next
                publish(keepingPreset: true)
            }
            return false
        }
        let beforeUI = summaryUI.validating(for: before)
        var afterUI = beforeUI.reconciling(to: after)
        afterUI.presetAdoptions = priorAdoptions
        var resultFingerprint: String?
        if after != baseline {
            let adoption = try DevelopmentPresetAdoption(record:record, sourceID:expected.sourceContentID, amount:amount,
                                                        baseline:baseline, result:after, masks:preparedMasks)
            afterUI.presetAdoptions.append(adoption)
            resultFingerprint = adoption.resultFingerprint
        }
        let omitted = record.metadata["confirmedOmissions"].map { " · 略过 " + String($0.prefix(160)) } ?? ""
        let action = record.metadata["semanticReconstruction"] == "true" ? "本张重建 · " : "预设 · "
        let title = adjustingAmount ? Self.presetAmountControl : action + record.name + omitted
        invalidatePendingAnalysis()
        try commit(after, event: .init(context: expected, control: .init(group: nil, name: title),
            nativeInput: .capture(control: adjustingAmount ? "preset.amount" : "preset.apply",
                phase: token == nil ? "discrete" : "change", nativeEvent: true, gestureID: token?.id)))
        summaryUI = afterUI
        if token != nil { gesture?.lastApplied = after }
        else {
            summaryUI = history.record(before: before, after: after, title: title, beforeUI: beforeUI,
                                       afterUI: afterUI, afterFingerprint:resultFingerprint)
        }
        presetAmountSession = next
        publish(keepingPreset: true)
        return true
    }
    @discardableResult func apply(_ command: DevelopmentAdjustmentCommand, event: EditingCommandEvent,
                                 gesture token: EditingGestureToken? = nil) throws -> Bool {
        try applyAtomically([command], title: event.control.name, event: event, gesture: token)
    }
    @discardableResult func applyAtomically(_ commands: [DevelopmentAdjustmentCommand], title: String,
                                           event: EditingCommandEvent, gesture token: EditingGestureToken? = nil) throws -> Bool {
        try applyTransaction(commands, title: title, event: event, gesture: token, stage: analysisStage)
    }
    @discardableResult private func applyTransaction(_ commands: [DevelopmentAdjustmentCommand], title: String,
                                                    event: EditingCommandEvent, gesture token: EditingGestureToken?,
                                                    stage: DevelopmentAnalysisStage,
                                                    summary: (DevelopmentAdjustmentID, Double)? = nil) throws -> Bool {
        try require(event.context)
        if let token {
            guard token.context == event.context, let current = gesture, current.token == token else {
                throw EditingDevelopmentSessionError.wrongGesture
            }
            guard recipe == current.lastApplied else { gesture = nil; summaryUI = .init(); publish(); throw EditingDevelopmentSessionError.recipeDiverged }
        } else if gesture != nil { throw EditingDevelopmentSessionError.unfinishedGesture }
        let before = recipe, beforeUI = summaryUI.validating(for: recipe)
        let editingGrain = commands.contains { if case .setBlackAndWhiteGrain = $0 { return true }; return false }
        let after = try EditingDevelopmentTransaction.applying(commands, to: before, context: try commandContext(stage: stage, editingGrain: editingGrain),
                                                               noiseReduction: noiseReductionCapability)
        var afterUI = beforeUI.reconciling(to: after, commands: commands)
        if let (group, amount) = summary { afterUI.remember(group: group, amount: amount, recipe: after) }
        guard after != before else {
            // UI-only acceptance has the same scope fence as a recipe commit. A reentrant
            // context provider must not label a replacement draft or a different gesture.
            try require(event.context)
            guard recipe == before else { throw EditingDevelopmentSessionError.recipeDiverged }
            if let token, gesture?.token != token { throw EditingDevelopmentSessionError.wrongGesture }
            if summaryUI != afterUI {
                summaryUI = afterUI
                if token == nil { history.updateCurrentUI(afterUI, current: after); summaryUI = history.currentUI(current: after) }
                publish()
            }
            return false
        }
        invalidatePendingAnalysis()
        try commit(after, event: event)
        summaryUI = afterUI
        if token != nil { gesture?.lastApplied = after }
        else {
            history.record(before: before, after: after, title: title, beforeUI: beforeUI, afterUI: afterUI)
            summaryUI = history.currentUI(current: after)
        }
        publish(); return true
    }
    func endGesture(_ token: EditingGestureToken, _ disposition: EditingGestureDisposition) throws {
        try require(token.context)
        guard let current = gesture, current.token == token else { throw EditingDevelopmentSessionError.wrongGesture }
        guard recipe == current.lastApplied else { gesture = nil; summaryUI = .init(); publish(); throw EditingDevelopmentSessionError.recipeDiverged }
        invalidatePendingAnalysis()
        switch disposition {
        case .commit:
            history.record(before: current.before, after: recipe, title: current.control.name,
                beforeUI: current.beforeUI, afterUI: summaryUI)
            summaryUI = history.currentUI(current: recipe)
        case .cancel:
            if recipe != current.before { try commit(current.before, event: .init(context: token.context, control: current.control)) }
            summaryUI = current.beforeUI.validating(for: recipe)
            history.updateCurrentUI(summaryUI, current: recipe); summaryUI = history.currentUI(current: recipe)
        }
        gesture = nil; gestureActivityChanged?(current.control, false)
        publish(keepingPreset: disposition == .commit && current.control.name == Self.presetAmountControl)
    }
    /// Existing legacy controls still use Controller's validated recipe mutation. Observe that
    /// sole write without converting legacy math or creating a second recipe authority.
    func recordControllerCommit(before: DevelopmentRecipe, after: DevelopmentRecipe, event: EditingCommandEvent) throws {
        try require(event.context)
        guard recipe == after else { throw EditingDevelopmentSessionError.recipeDiverged }
        invalidatePendingAnalysis()
        let beforeUI = summaryUI.validating(for: before)
        if var current = gesture {
            guard current.lastApplied == before else { throw EditingDevelopmentSessionError.recipeDiverged }
            summaryUI = beforeUI.reconciling(to: after)
            current.lastApplied = after; gesture = current
        } else {
            history.record(before: before, after: after, title: event.control.name,
                beforeUI: beforeUI, afterUI: beforeUI.reconciling(to: after))
            summaryUI = history.currentUI(current: after)
        }
        publish()
    }
    func undo(context expected: EditingInteractionContext, input: EditingPreviewInput? = nil) throws {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        guard let candidate = history.undoCandidate(current: recipe) else {
            if history.canUndo { history.clearActive(); summaryUI = .init(); publish(); throw EditingDevelopmentSessionError.recipeDiverged }
            return // The editing keyboard owner still consumes the event when no recipe history exists.
        }
        invalidatePendingAnalysis(); try commit(candidate, event: .init(context: expected, control: .init(group: nil, name: "撤销"), nativeInput: input))
        history.didUndo(); summaryUI = history.currentUI(current: recipe); publish()
    }
    func redo(context expected: EditingInteractionContext, input: EditingPreviewInput? = nil) throws {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        guard let candidate = history.redoCandidate(current: recipe) else {
            if history.canRedo { history.clearActive(); summaryUI = .init(); publish(); throw EditingDevelopmentSessionError.recipeDiverged }
            return
        }
        invalidatePendingAnalysis(); try commit(candidate, event: .init(context: expected, control: .init(group: nil, name: "重做"), nativeInput: input))
        history.didRedo(); summaryUI = history.currentUI(current: recipe); publish()
    }
    func restoreHistory(position: Int, context expected: EditingInteractionContext, input: EditingPreviewInput? = nil) throws {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        guard let candidate = history.restorationCandidate(position: position, current: recipe) else {
            throw EditingDevelopmentSessionError.recipeDiverged
        }
        guard candidate.recipe != recipe else { return }
        invalidatePendingAnalysis()
        try commit(candidate.recipe, event: .init(context: expected,
            control: .init(group: nil, name: "恢复历史状态"), nativeInput: input))
        history.didRestore(position: position)
        summaryUI = history.currentUI(current: recipe); publish()
    }
    func restoreHistory(recipe target: DevelopmentRecipe, context expected: EditingInteractionContext,
                        input: EditingPreviewInput? = nil) throws {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        guard recipe != target else { return }
        guard let position = history.restorationPosition(for: target, current: recipe) else {
            throw EditingDevelopmentSessionError.recipeDiverged
        }
        try restoreHistory(position: position, context: expected, input: input)
    }
    @discardableResult
    func createSnapshot(name: String? = nil, context expected: EditingInteractionContext) throws -> DevelopmentSnapshot {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        let id = UUID()
        let items = try changeSnapshots(.create(id: id, name: name, createdAt: .now, recipe: recipe,
            adoptions: presetAdoptions.isEmpty ? nil : presetAdoptions), context: expected)
        guard let snapshot = items.first(where: { $0.id == id }) else { throw EditingDevelopmentSessionError.commitRejected }
        return snapshot
    }
    func renameSnapshot(id: DevelopmentSnapshot.ID, name: String, context expected: EditingInteractionContext) throws {
        try require(expected)
        _ = try changeSnapshots(.rename(id, name), context: expected)
    }
    func deleteSnapshot(id: DevelopmentSnapshot.ID, context expected: EditingInteractionContext) throws {
        try require(expected)
        _ = try changeSnapshots(.delete(id), context: expected)
    }
    private func changeSnapshots(_ edit: DevelopmentSnapshotEdit, context: EditingInteractionContext) throws -> [DevelopmentSnapshot] {
        var items: [DevelopmentSnapshot]
        if let snapshotCatalog {
            items = try snapshotCatalog(context, edit)
        } else {
            items = snapshots(in: context)
            try edit.apply(to: &items)
        }
        snapshotStorage[context.historyKey] = items
        publish()
        return items
    }
    func restoreSnapshot(id: DevelopmentSnapshot.ID, context expected: EditingInteractionContext) throws {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        guard let key = context?.historyKey,
              let snapshot = snapshotStorage[key]?.first(where: { $0.id == id }) else { return }
        let before = recipe, beforeUI = summaryUI.validating(for: recipe)
        var afterUI = beforeUI.reconciling(to: snapshot.recipe)
        afterUI.presetAdoptions = snapshot.presetAdoptions ?? []
        guard snapshot.recipe != recipe else {
            if afterUI != beforeUI {
                summaryUI = afterUI
                history.updateCurrentUI(afterUI, current: recipe)
                publish()
            }
            return
        }
        invalidatePendingAnalysis()
        let input = EditingPreviewInput.capture(control: "snapshot.restore", phase: "discrete", nativeEvent: true)
        try commit(snapshot.recipe, event: .init(context: expected,
            control: .init(group: nil, name: "恢复快照 · " + snapshot.name), nativeInput: input))
        history.record(before: before, after: snapshot.recipe, title: "恢复快照 · " + snapshot.name,
            beforeUI: beforeUI, afterUI: afterUI)
        summaryUI = history.currentUI(current: recipe); publish()
    }
    func cancelAnalysis(context expected: EditingInteractionContext) throws {
        try require(expected); invalidatePendingAnalysis()
    }
    func cancelAnalysis(operationID: UUID, context expected: EditingInteractionContext) throws {
        try require(expected)
        if pendingAnalysis?.operationID == operationID { invalidatePendingAnalysis() }
    }
    /// An admission envelope only. It neither runs Auto nor invents an available native capability.
    func admitAnalysis(context expected: EditingInteractionContext, operationID: UUID = UUID(),
                       gesture token: EditingGestureToken? = nil, input: EditingPreviewInput? = nil,
                       stage requestedStage: DevelopmentAnalysisStage? = nil) throws -> EditingDevelopmentAnalysisTicket {
        try require(expected)
        if let token {
            guard let gesture, gesture.token == token, token.context == expected,
                  gesture.lastApplied == recipe else { throw EditingDevelopmentSessionError.wrongGesture }
        } else { guard gesture == nil else { throw EditingDevelopmentSessionError.unfinishedGesture } }
        invalidatePendingAnalysis()
        // Analyze this exact, ephemeral V3 snapshot. Promotion stays unpublished until the resolved
        // command commits, and Core verifies the fingerprint of the recipe it actually analyzes.
        let draft = recipe, analyzed = try draft.promotingToV3()
        let ticket = EditingDevelopmentAnalysisTicket(operationID: operationID, context: expected,
            expectedRecipeFingerprint: try EditingFingerprint.of(analyzed),
            draftRecipeFingerprint: try EditingFingerprint.of(draft), analysisRecipe: analyzed,
            stage: requestedStage ?? analysisStage, sessionStage: analysisStage, gesture: token, nativeInput: input)
        pendingAnalysis = ticket; return ticket
    }
    func acceptAnalysis(_ result: DevelopmentResolvedAdjustmentCommand, ticket: EditingDevelopmentAnalysisTicket,
                        title: String) throws {
        try require(ticket.context)
        guard pendingAnalysis?.operationID == ticket.operationID, pendingAnalysis?.stage == ticket.stage,
              ticket.sessionStage == analysisStage, result.binding.stage == ticket.stage,
              ticket.draftRecipeFingerprint == (try EditingFingerprint.of(recipe)),
              result.binding.expectedRecipeFingerprint == ticket.expectedRecipeFingerprint else {
            throw EditingDevelopmentSessionError.staleAnalysis
        }
        pendingAnalysis = nil
        // WB analyzes the original source stage without changing the interactive session's stage
        // or epoch. Only this captured analysis transaction gets the matching Core context.
        let summary: (DevelopmentAdjustmentID, Double)?
        if case .summary(let group, let amount) = result.purpose { summary = (group, amount) } else { summary = nil }
        try applyTransaction([.applyAnalysis(result)], title: title,
            event: .init(context: ticket.context, control: .init(group: nil, name: title), nativeInput: ticket.nativeInput),
            gesture: ticket.gesture, stage: ticket.stage, summary: summary)
    }
    func admitGeometryAnalysis(context expected: EditingInteractionContext, operationID: UUID,
                               input: EditingPreviewInput?) throws -> EditingGeometryAnalysisTicket {
        try validateInteraction(expected)
        guard page == .crop, let source else { throw EditingDevelopmentSessionError.inactive }
        let constraint = cropConstraint
        let analyzed = try recipe.promotingToV3()
        guard let geometry = analyzed.adjustmentsV3?.geometry else { throw EditingDevelopmentSessionError.inactive }
        let cropInput = try DevelopmentCropAutoInputV1(geometry: geometry, aspectRatio: constraint.ratio(source: source.sourceSize))
        let ticket = try admitAnalysis(context: expected, operationID: operationID, input: input, stage: .orientedSourceBeforeGeometry)
        return .init(analysis: ticket, constraint: constraint, input: cropInput)
    }
    /// Crop presentation may intentionally be uncropped. Its captured visible fingerprint and the
    /// complete original draft fingerprint are independent gates; neither substitutes for the other.
    @discardableResult func acceptGeometryAnalysis(_ result: DevelopmentResolvedGeometryV1,
        ticket geometryTicket: EditingGeometryAnalysisTicket, expectedPresentedFingerprint: String,
        title: String) throws -> Bool {
        let ticket = geometryTicket.analysis
        try require(ticket.context)
        guard page == .crop, ticket.gesture == nil, gesture == nil,
              pendingAnalysis?.operationID == ticket.operationID, pendingAnalysis?.stage == ticket.stage,
              ticket.sessionStage == analysisStage, ticket.stage == .orientedSourceBeforeGeometry,
              let source, source == result.source,
              result.binding.sourceContentID == source.sourceContentID,
              result.binding.sourceGeneration == ticket.context.sourceGeneration,
              result.binding.stage == ticket.stage,
              result.binding.expectedRecipeFingerprint == ticket.expectedRecipeFingerprint,
              result.presentedRecipeFingerprint == expectedPresentedFingerprint,
              EditingFingerprint.isSHA256(expectedPresentedFingerprint),
              ticket.draftRecipeFingerprint == (try EditingFingerprint.of(recipe)),
              ticket.expectedRecipeFingerprint == (try EditingFingerprint.of(ticket.analysisRecipe)),
              ticket.expectedRecipeFingerprint == (try EditingFingerprint.of(recipe.promotingToV3())),
              cropConstraint == geometryTicket.constraint,
              let baseline = ticket.analysisRecipe.adjustmentsV3?.geometry else {
            throw EditingDevelopmentSessionError.staleAnalysis
        }
        let currentInput = try DevelopmentCropAutoInputV1(geometry: baseline, aspectRatio: cropConstraint.ratio(source: source.sourceSize))
        guard currentInput == geometryTicket.input, result.input == currentInput else { throw EditingDevelopmentSessionError.staleAnalysis }
        let candidate = try result.validatedCandidate(baseline: baseline, expectedSource: source, expectedInput: currentInput)
        pendingAnalysis = nil
        guard let candidate else { return false }
        return try applyTransaction([.setGeometry(candidate)], title: title,
            event: .init(context: ticket.context, control: .init(group: nil, name: "crop.auto"), nativeInput: ticket.nativeInput),
            gesture: nil, stage: ticket.stage)
    }
    func makeSaveTicket(context expected: EditingInteractionContext) throws -> EditingDevelopmentSaveTicket {
        try require(expected)
        if let gesture { try endGesture(gesture.token, .commit) }
        let ticket = EditingDevelopmentSaveTicket(operationID: UUID(), context: expected, recipe: recipe)
        latestSave = ticket; return ticket
    }
    /// Local Core batches consume the ORIGINAL draft so legacy presented fingerprints remain
    /// fenced. Generic scalar transactions intentionally promote before applying their command.
    @discardableResult func acceptLocalAnalysis(_ result: DevelopmentResolvedLocalBatch,
        ticket: EditingDevelopmentAnalysisTicket, expectedInput: DevelopmentLocalInputV1, title: String) throws -> Bool {
        try require(ticket.context)
        guard ticket.gesture == nil, gesture == nil,
              pendingAnalysis?.operationID == ticket.operationID, pendingAnalysis?.stage == ticket.stage,
              ticket.sessionStage == analysisStage, ticket.stage == .workingImageBeforeGeometry,
              ticket.draftRecipeFingerprint == (try EditingFingerprint.of(recipe)),
              result.binding.expectedRecipeFingerprint == ticket.expectedRecipeFingerprint,
              result.presentedRecipeFingerprint == ticket.draftRecipeFingerprint, result.input == expectedInput else {
            throw EditingDevelopmentSessionError.staleAnalysis
        }
        let before = recipe, beforeUI = summaryUI.validating(for: recipe)
        let current = try commandContext(stage: ticket.stage)
        let context = DevelopmentAdjustmentCommandContext(source: current.source, sourceGeneration: current.sourceGeneration,
            analysisStage: current.analysisStage, sourceCapability: current.sourceCapability, localInputV1: expectedInput,
            dehazeContextV1: current.dehazeContextV1)
        let after = try before.applying(.appendResolvedLocalBatch(result), context: context)
        pendingAnalysis = nil
        guard after != before else { return false }
        try commit(after, event: .init(context: ticket.context, control: .init(group: nil, name: title), nativeInput: ticket.nativeInput))
        history.record(before: before, after: after, title: title, beforeUI: beforeUI, afterUI: beforeUI.reconciling(to: after))
        summaryUI = history.currentUI(current: after); publish(); return true
    }
    /// As with local batches, Core must see the ORIGINAL draft, not a prematurely promoted value.
    @discardableResult func acceptDehazeAnalysis(_ result: DevelopmentResolvedDehazeV1,
        ticket: EditingDevelopmentAnalysisTicket, expectedInput: DevelopmentDehazeInputV1,
        wantedAmount: Double, title: String) throws -> Bool {
        try require(ticket.context)
        guard ticket.gesture == nil, gesture == nil,
              pendingAnalysis?.operationID == ticket.operationID, pendingAnalysis?.stage == ticket.stage,
              ticket.sessionStage == analysisStage, ticket.stage == .workingImageBeforeGeometry,
              ticket.draftRecipeFingerprint == (try EditingFingerprint.of(recipe)),
              result.binding.expectedRecipeFingerprint == ticket.expectedRecipeFingerprint,
              result.presentedRecipeFingerprint == ticket.draftRecipeFingerprint, result.input == expectedInput else {
            throw EditingDevelopmentSessionError.staleAnalysis
        }
        let before = recipe, beforeUI = summaryUI.validating(for: recipe), current = try commandContext(stage: ticket.stage)
        guard let actual = current.dehazeContextV1,
              try before.prospectiveDehazeInputV1(context: actual, algorithm: expectedInput.algorithm).input == expectedInput else {
            throw DevelopmentDehazePreparationError.staleInput
        }
        let after = try before.applying(.applyPreparedDehaze(result, wantedAmount: wantedAmount), context: current)
        pendingAnalysis = nil
        guard after != before else { return false }
        try commit(after, event: .init(context: ticket.context, control: .init(group: .dehaze, name: title), nativeInput: ticket.nativeInput))
        history.record(before: before, after: after, title: title, beforeUI: beforeUI, afterUI: beforeUI.reconciling(to: after))
        summaryUI = history.currentUI(current: after); publish(); return true
    }
    /// Caller may update only the saved baseline/selection when true. This never replaces the draft
    /// recipe, changes branchID/epoch, moves the history cursor or auto-adopts a candidate.
    func acceptsSaveCompletion(_ ticket: EditingDevelopmentSaveTicket) -> Bool {
        acceptingInput && context == ticket.context && latestSave?.operationID == ticket.operationID
    }
    /// Only the identity gate; source/output projection and pointer admission await the renderer's
    /// real geometry map. A reused bitmap/frame ID does not make an old branch context current.
    func validateDisplayedFrame(_ frame: EditingDisplayedFrameContext) throws {
        try require(frame.interaction)
        guard frame.stage == analysisStage, frame.recipeFingerprint == (try EditingFingerprint.of(recipe)) else {
            throw EditingDevelopmentSessionError.staleFrame
        }
    }
    private func require(_ expected: EditingInteractionContext) throws {
        guard acceptingInput, let context else { throw EditingDevelopmentSessionError.inactive }
        guard context == expected else { throw EditingDevelopmentSessionError.staleInteraction }
    }
    private func commandContext(stage: DevelopmentAnalysisStage? = nil, editingGrain: Bool = false) throws -> DevelopmentAdjustmentCommandContext {
        guard let source, let context else { throw EditingDevelopmentSessionError.inactive }
        let dehaze = try currentDehazeContext?(context)
        if let dehaze {
            try dehaze.validate()
            guard dehaze.source == source, dehaze.sourceGeneration == context.sourceGeneration else {
                throw DevelopmentDehazePreparationError.staleInput
            }
        }
        let grainVersions = editingGrain ? (try currentGrainSamplingVersions?(context) ?? []):[]
        try require(context) // A reentrant metadata provider cannot authorize a replacement branch.
        return .init(source: source, sourceGeneration: context.sourceGeneration, analysisStage: stage ?? analysisStage,
                     sourceCapability: noiseReductionCapability, dehazeContextV1: dehaze,
                     supportedGrainSamplingVersions: grainVersions)
    }
    private func commit(_ candidate: DevelopmentRecipe, event: EditingCommandEvent) throws {
        try require(event.context); try candidate.validate(); try commitRecipe(candidate, event)
        try require(event.context)
        guard recipe == candidate else { throw EditingDevelopmentSessionError.commitRejected }
    }
    private func advanceEpoch() throws {
        guard epoch < .max else { throw EditingDevelopmentSessionError.epochExhausted }
        epoch += 1
    }
    private func replacingEpoch(_ old: EditingInteractionContext) -> EditingInteractionContext {
        .init(workID: old.workID, admissionFingerprint: old.admissionFingerprint, sourceContentID: old.sourceContentID,
              sourceGeneration: old.sourceGeneration, draftBranchID: old.draftBranchID, draftBranchEpoch: epoch)
    }
    private func invalidatePendingAnalysis() {
        if let pendingAnalysis { self.pendingAnalysis = nil; invalidateAnalysis?(pendingAnalysis.operationID) }
    }
    private func revokeInteraction(_ expected: EditingInteractionContext) {
        // Do not revoke a different scope created by a reentrant Controller publication.
        guard context == expected else { return }
        let cancelledOperation = pendingAnalysis?.operationID
        let activeControl = gesture?.control
        // @Published sends before storing the new value. Close the separate gate first so a
        // synchronous observer cannot admit an old callback while context's nil is being published.
        acceptingInput = false
        context = nil; source = nil; gesture = nil; summaryUI = .init(); noiseReductionCapability = nil
        pendingAnalysis = nil; latestSave = nil; history.deactivate()
        // Even epoch exhaustion cannot prevent closing. Future activate() then fails closed.
        if epoch < .max { epoch += 1 }
        publish()
        if let activeControl { gestureActivityChanged?(activeControl, false) }
        // All admission is already closed when the external cancellation owner is notified.
        if let cancelledOperation { invalidateAnalysis?(cancelledOperation) }
    }
    private func publish(keepingPreset: Bool = false) {
        if !keepingPreset { presetAmountSession = nil }
        revision = UUID()
        if publishedAdoptions != summaryUI.presetAdoptions {
            publishedAdoptions = summaryUI.presetAdoptions
            if context != nil { presetAdoptionsChanged?() }
        }
    }
}

enum EditingPointerPressure {
    static func normalized(reported: Double, supportsPressure: Bool) -> Double? {
        guard supportsPressure else { return 1 }
        guard reported.isFinite, (0...1).contains(reported) else { return nil }
        return reported
    }
}
