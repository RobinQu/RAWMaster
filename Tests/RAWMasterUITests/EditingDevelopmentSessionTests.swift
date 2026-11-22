import Foundation
import Combine
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class EditingDevelopmentSessionTests: XCTestCase {
    @MainActor private final class Draft {
        var recipe: DevelopmentRecipe
        var publications = 0
        var commitAttempts = 0
        var rejectCommit = false
        init(_ recipe: DevelopmentRecipe) { self.recipe = recipe }
    }
    private let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "a", count: 64),
        exifOrientation: 6, orientedWidth: 2400, orientedHeight: 3600)
    private var admission: String { String(repeating: "b", count: 64) }
    @MainActor private func make(_ recipe: DevelopmentRecipe = .init(), limits: DevelopmentUndoHistory.Limits = .init(),
                                 capability: DevelopmentNoiseReductionSourceCapability = .image) throws
        -> (Draft, EditingDevelopmentSession, EditingInteractionContext) {
        let draft = Draft(recipe)
        let session = EditingDevelopmentSession(historyLimits: limits, readRecipe: { draft.recipe }, commitRecipe: { recipe, _ in
            draft.commitAttempts += 1
            if draft.rejectCommit { throw EditingDevelopmentSessionError.commitRejected }
            draft.recipe = recipe; draft.publications += 1
        })
        let context = try session.activate(workID: "work", admissionFingerprint: admission, source: source,
                                          sourceGeneration: 1, noiseReduction: capability)
        return (draft, session, context)
    }
    private func event(_ context: EditingInteractionContext, group: DevelopmentAdjustmentID = .light) -> EditingCommandEvent {
        .init(context: context, control: .init(group: group, name: group.photosTitle))
    }
    @MainActor func testSuperResolutionAndPhotographicDenoiseInNormalImageSession() throws {
        let (draft, session, context) = try make(capability: .image)
        let baseline = draft.recipe
        try session.apply(.setAIDenoise(.init(model: .photoVGG7Chroma, amount: 30)), event: event(context))
        let denoised = draft.recipe
        XCTAssertEqual(denoised.adjustmentsV3?.aiDenoise?.model, .photoVGG7Chroma)
        try session.apply(.setSuperResolution(.photoUpconv7), event: event(context))
        let enhanced = draft.recipe
        XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(enhanced)), enhanced)
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, denoised)
        try session.redo(context: context)
        XCTAssertEqual(draft.recipe, enhanced)
        try session.apply(.setSuperResolution(nil), event: event(context))
        try session.apply(.setAIDenoise(nil), event: event(context))
        XCTAssertEqual(draft.recipe, try denoised.applying(.setAIDenoise(nil)))
        // The draft began as v1. Ordinary edits persist v3; undo restores the exact original schema.
        for _ in 0..<4 { try session.undo(context: context) }
        XCTAssertEqual(draft.recipe, baseline)
        XCTAssertThrowsError(try session.apply(.setAIDenoise(.init(model: .appleRAW9)), event: event(context)))
    }
    @MainActor func testAIDenoiseAmountGestureUndoRedoAndSwitchOff() throws {
        let (draft, session, context) = try make(capability: .raw)
        let baseline = draft.recipe
        let event = EditingCommandEvent(context: context, control: .init(group: nil, name: "AI 降噪量"))
        try session.apply(.setAIDenoise(.init(model: .appleRAW9)), event: event)
        let selected = draft.recipe
        let gesture = try session.beginGesture(event.control, context: context)
        for amount in [62, 71, 83] {
            try session.apply(.setAIDenoise(.init(model: .appleRAW9, amount: amount)), event: event, gesture: gesture)
        }
        try session.endGesture(gesture, .commit)
        let adjusted = draft.recipe
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, selected)
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, baseline)
        try session.redo(context: context)
        try session.redo(context: context)
        XCTAssertEqual(draft.recipe, adjusted)
        try session.apply(.setAIDenoise(nil), event: event)
        XCTAssertNil(draft.recipe.adjustmentsV3?.aiDenoise)
    }

    @MainActor func testRawDetailsCanUndoToOlderDecoderAndRedo() throws {
        let (draft, session, context) = try make(capability: .raw)
        let old = draft.recipe
        try session.apply(.setRawDetails(.bayerAHD), event: event(context))
        XCTAssertEqual(draft.recipe.adjustmentsV3?.rawDetails, .bayerAHD)
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, old)
        try session.redo(context: context)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.rawDetails, .bayerAHD)
    }

    @MainActor func testGradingLUTStackAndMaskUndoRedo() throws {
        let (draft, session, context) = try make()
        let baseline = draft.recipe
        let stack = DevelopmentLUTStack(layers: [.init(cube: .warm, amount: 25), .init(cube: .monochrome, amount: 80)])
        try session.apply(.setGradingLUTs(stack), event: event(context))
        let layered = draft.recipe
        try session.apply(.setMasks([.init(kind: .radial, adjustments: .init(gradingLUT: .init(cube: .monochrome)))]), event: event(context))
        let masked = draft.recipe
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, layered)
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, baseline)
        try session.redo(context: context)
        try session.redo(context: context)
        XCTAssertEqual(draft.recipe, masked)
    }
    @MainActor func testReadingPresentationAndDefaultResetNeverPromotesLegacyRecipe() throws {
        let legacy = try DevelopmentRecipe().promotingToV2()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(legacy)
        let (draft, session, context) = try make(legacy)
        _ = session.parameters; _ = session.canUndo
        try session.setExpanded(.curves, expanded: true, context: context)
        try session.setOptionsExpanded(.light, expanded: true, context: context)
        XCTAssertFalse(try session.apply(.reset(.light), event: event(context)))
        XCTAssertFalse(try session.apply(.setEnabled(.blackAndWhite, false), event: event(context, group: .blackAndWhite)))
        XCTAssertFalse(try session.apply(.resetAll, event: event(context)))
        XCTAssertEqual(draft.recipe, legacy)
        XCTAssertEqual(try encoder.encode(draft.recipe), bytes)
        XCTAssertEqual(draft.publications, 0); XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.parameters.blackAndWhite.intensity, 0.5)
        XCTAssertEqual(session.parameters.sharpen.edges, 0.22)
        XCTAssertEqual(session.parameters.sharpen.falloff, 0.69)
        XCTAssertEqual(session.parameters.vignette.radius, 0.5)
    }
    @MainActor func testOneGesturePromotesAndPublishesChangesButCreatesOneUndoEntry() throws {
        let (draft, session, context) = try make()
        let before = draft.recipe
        let token = try session.beginGesture(event(context).control, context: context)
        try session.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.25))), event: event(context), gesture: token)
        try session.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.5))), event: event(context), gesture: token)
        XCTAssertEqual(draft.publications, 2); XCTAssertEqual(session.history.entryCount, 0); XCTAssertTrue(session.canUndo)
        try session.endGesture(token, .commit)
        XCTAssertEqual(session.history.entryCount, 1)
        let after = draft.recipe
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, before); XCTAssertTrue(session.canRedo)
        try session.redo(context: context)
        XCTAssertEqual(draft.recipe, after); XCTAssertEqual(session.history.entryCount, 1)
    }
    @MainActor func testInvalidAtomicBatchNeverPublishesPartialCandidateOrHistory() throws {
        let (draft, session, context) = try make()
        let before = draft.recipe
        XCTAssertThrowsError(try session.applyAtomically([
            .setParameters(.light(.init(enabled: true, exposure: 0.3))),
            .setParameters(.sharpen(.init(enabled: true, intensity: .nan)))
        ], title: "invalid", event: event(context)))
        XCTAssertEqual(draft.recipe, before); XCTAssertEqual(draft.publications, 0)
        XCTAssertEqual(session.history.entryCount, 0)
    }
    @MainActor func testDisablePreservesParametersAndResetRestoresTypedDefaults() throws {
        let (draft, session, context) = try make()
        try session.apply(.setParameters(.sharpen(.init(enabled: true, intensity: 0.8, edges: 0.7, falloff: 0.3))), event: event(context, group: .sharpen))
        try session.apply(.setEnabled(.sharpen, false), event: event(context, group: .sharpen))
        XCTAssertEqual(draft.recipe.adjustmentsV3?.sharpen.intensity, 0.8)
        try session.apply(.setEnabled(.sharpen, true), event: event(context, group: .sharpen))
        XCTAssertEqual(draft.recipe.adjustmentsV3?.sharpen.edges, 0.7)
        try session.apply(.reset(.sharpen), event: event(context, group: .sharpen))
        XCTAssertEqual(draft.recipe.adjustmentsV3?.sharpen, DevelopmentSharpenV3())
        XCTAssertFalse(PhotosAdjustmentCommands.isModified(.sharpen, in: session.parameters))
    }
    @MainActor func testImageNoiseReductionEnableSetsActualDomainWithoutReinterpretingInactiveValues() throws {
        let parameters = DevelopmentAdjustmentsV3(noiseReduction: .init(luminanceNoise: 0.3, colorNoise: -0.2, detail: 1.2, nonRawAmount: 2.4))
        let (draft, session, context) = try make(.init(adjustmentsV3: parameters))
        XCTAssertEqual(PhotosScalarField.fields(for: .noiseReduction, noiseReduction: .image).count, 1)
        XCTAssertEqual(PhotosScalarField.fields(for: .noiseReduction, noiseReduction: .raw).count, 3)
        try session.apply(.setEnabled(.noiseReduction, true), event: event(context, group: .noiseReduction))
        let actual = try XCTUnwrap(draft.recipe.adjustmentsV3?.noiseReduction)
        XCTAssertEqual(actual.sourceCapability, .image); XCTAssertEqual(actual.nonRawAmount, 2.4)
        XCTAssertEqual(actual.luminanceNoise, 0.3); XCTAssertEqual(actual.detail, 1.2)
        XCTAssertThrowsError(try session.apply(.setParameters(.noiseReduction(.init(enabled: true, sourceCapability: .raw))),
            event: event(context, group: .noiseReduction)))
        try session.apply(.reset(.noiseReduction), event: event(context, group: .noiseReduction))
        XCTAssertEqual(draft.recipe.adjustmentsV3?.noiseReduction.sourceCapability, .raw)
        XCTAssertEqual(session.noiseReductionCapability, .image)
    }
    @MainActor func testSameWorkSameSourceSameRecipeBranchReplacementRejectsEveryOldCallback() throws {
        let (draft, session, contextA) = try make(.init(adjustmentsV3: .init()))
        let analysis = try session.admitAnalysis(context: contextA)
        let oldFrame = EditingDisplayedFrameContext(frameID: UUID(), interaction: contextA,
            recipeFingerprint: try EditingFingerprint.of(draft.recipe), stage: .workingImageBeforeGeometry)
        try session.validateDisplayedFrame(oldFrame)
        let token = try session.beginGesture(event(contextA).control, context: contextA)
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.4))), event: event(contextA), gesture: token)
        try session.prepareForBranchReplacement(context: contextA)
        // The gesture was cancelled while A still owned the draft; B has identical baseline content.
        let contextB = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 1, noiseReduction: .image)
        let before = draft.recipe, publications = draft.publications
        XCTAssertNotEqual(contextA.draftBranchID, contextB.draftBranchID)
        XCTAssertThrowsError(try session.endGesture(token, .commit)) // late mouseUp
        XCTAssertThrowsError(try session.endGesture(token, .cancel)) // late Escape
        XCTAssertThrowsError(try session.undo(context: contextA)) // queued old Cmd-Z
        XCTAssertThrowsError(try session.acceptAnalysis(resolved(analysis), ticket: analysis, title: "自动"))
        XCTAssertThrowsError(try session.validateDisplayedFrame(oldFrame))
        XCTAssertEqual(draft.recipe, before); XCTAssertEqual(draft.publications, publications)
        XCTAssertEqual(session.context, contextB); XCTAssertFalse(session.canUndo)
    }
    @MainActor func testStageAndFocusEpochRejectOldEventsButRetainStableBranchHistory() throws {
        let (draft, session, first) = try make()
        let original = draft.recipe
        let token = try session.beginGesture(event(first).control, context: first)
        try session.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.2))), event: event(first), gesture: token)
        let second = try session.changePage(.filters, context: first)
        XCTAssertEqual(second.draftBranchID, first.draftBranchID)
        XCTAssertNotEqual(second.draftBranchEpoch, first.draftBranchEpoch)
        XCTAssertThrowsError(try session.endGesture(token, .cancel))
        XCTAssertThrowsError(try session.undo(context: first))
        XCTAssertTrue(session.canUndo)
        try session.suspend(context: second)
        let resumed = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 2,
                                          branchID: first.draftBranchID, noiseReduction: .image)
        XCTAssertThrowsError(try session.undo(context: second))
        try session.undo(context: resumed)
        XCTAssertEqual(draft.recipe, original); XCTAssertTrue(session.canRedo)
        let third = try session.changeAnalysisStage(.orientedSourceBeforeGeometry, context: resumed)
        XCTAssertThrowsError(try session.redo(context: resumed))
        try session.redo(context: third); XCTAssertEqual(draft.recipe.adjustmentsV3?.light.brilliance, 0.2)
    }
    @MainActor func testSaveTicketsKeepBranchHistoryAndNeverOverwriteLaterDraftOrNewBranch() throws {
        let (draft, session, context) = try make()
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.2))), event: event(context))
        let save = try session.makeSaveTicket(context: context), saved = draft.recipe
        try session.apply(.setParameters(.color(.init(enabled: true, vibrance: 0.4))), event: event(context, group: .color))
        XCTAssertTrue(session.acceptsSaveCompletion(save)); XCTAssertEqual(save.recipe, saved)
        XCTAssertNotEqual(draft.recipe, saved); XCTAssertEqual(session.context, context)
        XCTAssertEqual(session.history.entryCount, 2)
        let laterSave = try session.makeSaveTicket(context: context)
        XCTAssertFalse(session.acceptsSaveCompletion(save)); XCTAssertTrue(session.acceptsSaveCompletion(laterSave))
        try session.prepareForBranchReplacement(context: context)
        _ = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 1)
        let newBranchDraft = draft.recipe
        XCTAssertFalse(session.acceptsSaveCompletion(laterSave)); XCTAssertEqual(draft.recipe, newBranchDraft)
    }
    @MainActor func testLegacyAnalysisUsesExactUnpublishedPromotedRecipeAndOneAtomicUndo() throws {
        let legacy = try DevelopmentRecipe(exposureEV: 0.4).promotingToV2()
        let (draft, session, context) = try make(legacy)
        let ticket = try session.admitAnalysis(context: context)
        XCTAssertEqual(draft.recipe, legacy); XCTAssertEqual(draft.publications, 0)
        XCTAssertEqual(ticket.analysisRecipe.schemaVersion, 3)
        XCTAssertEqual(ticket.expectedRecipeFingerprint, try EditingFingerprint.of(ticket.analysisRecipe))
        try session.acceptAnalysis(resolved(ticket), ticket: ticket, title: "自动光效")
        XCTAssertEqual(draft.publications, 1); XCTAssertEqual(session.history.entryCount, 1)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.legacyBasis?.exposureEV, 0.4)
        try session.undo(context: context); XCTAssertEqual(draft.recipe, legacy)
    }
    @MainActor func testManualEditInvalidatesAnalysisAndFailedCommitDoesNotMoveUndoCursor() throws {
        let (draft, session, context) = try make()
        let ticket = try session.admitAnalysis(context: context)
        var cancelled: [UUID] = []
        session.invalidateAnalysis = { cancelled.append($0) }
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.2))), event: event(context))
        XCTAssertEqual(cancelled, [ticket.operationID])
        XCTAssertThrowsError(try session.acceptAnalysis(resolved(ticket), ticket: ticket, title: "旧自动"))
        let after = draft.recipe
        draft.rejectCommit = true
        XCTAssertThrowsError(try session.undo(context: context))
        XCTAssertEqual(draft.recipe, after); XCTAssertTrue(session.canUndo); XCTAssertFalse(session.canRedo)
    }
    @MainActor func testInvalidationWithRejectedRestoreRevokesWithoutAnyRecipeWriteAndBranchCancelAlsoFailsClosed() throws {
        for reason in [EditingInteractionInvalidationReason.sourceInvalidated, .termination, .viewTeardown] {
            let (draft, session, context) = try make(.init(adjustmentsV3: .init()))
            let save = try session.makeSaveTicket(context: context)
            let analysis = try session.admitAnalysis(context: context)
            let token = try session.beginGesture(event(context).control, context: context)
            try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.2))), event: event(context), gesture: token)
            let current = draft.recipe, attempts = draft.commitAttempts
            draft.rejectCommit = true
            try session.invalidate(context: context, reason: reason)
            XCTAssertEqual(draft.commitAttempts, attempts, "Invalid source/owner must not attempt the rejected begin-snapshot restore")
            XCTAssertEqual(draft.recipe, current)
            XCTAssertNil(session.context); XCTAssertNil(session.source); XCTAssertNil(session.activeGesture)
            XCTAssertNil(session.noiseReductionCapability)
            XCTAssertFalse(session.canUndo); XCTAssertFalse(session.canRedo)
            XCTAssertFalse(session.acceptsSaveCompletion(save))
            XCTAssertThrowsError(try session.endGesture(token, .commit))
            XCTAssertThrowsError(try session.endGesture(token, .cancel))
            XCTAssertThrowsError(try session.undo(context: context))
            XCTAssertThrowsError(try session.makeSaveTicket(context: context))
            XCTAssertThrowsError(try session.admitAnalysis(context: context))
            XCTAssertThrowsError(try session.acceptAnalysis(resolved(analysis), ticket: analysis, title: "旧自动"))
        }
        // Normal branch replacement still tries to restore its valid original draft, but a rejected
        // write propagates only after its old scope is closed, never leaving tracking admitted.
        let (draft, session, context) = try make()
        let token = try session.beginGesture(event(context).control, context: context)
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.3))), event: event(context), gesture: token)
        draft.rejectCommit = true
        XCTAssertThrowsError(try session.prepareForBranchReplacement(context: context))
        XCTAssertNil(session.context); XCTAssertNil(session.source); XCTAssertNil(session.activeGesture)
        XCTAssertThrowsError(try session.undo(context: context))

        // When actual analysis is pending, the cancellation callback observes already-closed
        // admission, including the save/frame gates; native join remains the backend owner's job.
        let (pendingDraft, pending, pendingContext) = try make(.init(adjustmentsV3: .init()))
        let save = try pending.makeSaveTicket(context: pendingContext)
        let ticket = try pending.admitAnalysis(context: pendingContext)
        let frame = EditingDisplayedFrameContext(frameID: UUID(), interaction: pendingContext,
            recipeFingerprint: try EditingFingerprint.of(pendingDraft.recipe), stage: .workingImageBeforeGeometry)
        var cancellation: UUID?
        var observedClosedAdmission = false
        func assertRejected(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
            do {
                try operation()
                XCTFail("Revoked scope admitted an operation", file: file, line: line)
            } catch { /* Expected: the old scope must reject synchronously. */ }
        }
        let observation = pending.$context.sink { value in
            guard value == nil else { return }
            observedClosedAdmission = true
            XCTAssertFalse(pending.acceptsSaveCompletion(save))
            assertRejected { _ = try pending.makeSaveTicket(context: pendingContext) }
            assertRejected { try pending.validateDisplayedFrame(frame) }
        }
        pending.invalidateAnalysis = { id in
            cancellation = id
            XCTAssertNil(pending.context); XCTAssertNil(pending.source); XCTAssertNil(pending.activeGesture)
            XCTAssertFalse(pending.acceptsSaveCompletion(save))
            assertRejected { try pending.validateDisplayedFrame(frame) }
        }
        try pending.invalidate(context: pendingContext, reason: .termination)
        observation.cancel()
        pending.invalidateAnalysis = nil
        XCTAssertEqual(cancellation, ticket.operationID)
        XCTAssertTrue(observedClosedAdmission)
    }
    @MainActor func testExternallyDivergedGestureSuspendRevokesScopeEvenWhenEndingGestureThrows() throws {
        for disposition in [EditingGestureDisposition.commit, .cancel] {
            let (draft, session, context) = try make(.init(adjustmentsV3: .init()))
            let save = try session.makeSaveTicket(context: context)
            let analysis = try session.admitAnalysis(context: context)
            let token = try session.beginGesture(event(context).control, context: context)
            try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.2))), event: event(context), gesture: token)
            // Simulate the sole recipe authority replacing data independently of this UI gesture.
            draft.recipe = .init(adjustmentsV3: .init(light: .init(enabled: true, exposure: 0.7)))
            let external = draft.recipe, attempts = draft.commitAttempts
            XCTAssertThrowsError(try session.suspend(context: context, disposition: disposition)) { error in
                XCTAssertEqual(error as? EditingDevelopmentSessionError, .recipeDiverged)
            }
            XCTAssertEqual(draft.recipe, external); XCTAssertEqual(draft.commitAttempts, attempts)
            XCTAssertNil(session.context); XCTAssertNil(session.source); XCTAssertNil(session.activeGesture)
            XCTAssertFalse(session.canUndo); XCTAssertFalse(session.canRedo)
            XCTAssertFalse(session.acceptsSaveCompletion(save))
            XCTAssertThrowsError(try session.endGesture(token, .commit))
            XCTAssertThrowsError(try session.endGesture(token, .cancel))
            XCTAssertThrowsError(try session.undo(context: context))
            XCTAssertThrowsError(try session.makeSaveTicket(context: context))
            XCTAssertThrowsError(try session.acceptAnalysis(resolved(analysis), ticket: analysis, title: "旧自动"))
            let next = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 2)
            XCTAssertGreaterThan(next.draftBranchEpoch, context.draftBranchEpoch)
            XCTAssertThrowsError(try session.undo(context: context))
            XCTAssertEqual(draft.recipe, external)
        }
    }
    @MainActor func testHistoryBoundsEntriesBranchesAndConservativeBytesWithoutDroppingDraft() throws {
        let (draft, session, context) = try make(limits: .init(entriesPerBranch: 2, bytesPerBranch: 100_000, totalBytes: 150_000, branches: 2))
        for value in [0.1, 0.2, 0.3, 0.4] {
            try session.apply(.setParameters(.light(.init(enabled: true, exposure: value))), event: event(context))
        }
        XCTAssertEqual(session.history.entryCount, 2)
        for _ in 0..<3 {
            let previous = try XCTUnwrap(session.context)
            try session.prepareForBranchReplacement(context: previous)
            let next = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 1)
            try session.apply(.setEnabled(.light, !session.parameters.light.enabled), event: event(next))
        }
        XCTAssertLessThanOrEqual(session.history.branchCount, 2)
        XCTAssertLessThanOrEqual(session.history.totalCost, 150_000)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.light.exposure, 0.4)
        let (smallDraft, small, smallContext) = try make(limits: .init(bytesPerBranch: 1024, totalBytes: 1024))
        try small.apply(.setParameters(.light(.init(enabled: true, exposure: 0.6))), event: event(smallContext))
        XCTAssertEqual(smallDraft.recipe.adjustmentsV3?.light.exposure, 0.6)
        XCTAssertFalse(small.canUndo); XCTAssertEqual(small.history.totalCost, 0)
    }
    func testNumericAndMousePressureInputsHaveExplicitFiniteContracts() throws {
        for invalid in ["", "-", "1,5", "nan", "inf", "1e2", "2.1"] {
            XCTAssertNil(DevelopmentNumericText.parse(invalid, range: -2...2))
        }
        XCTAssertEqual(DevelopmentNumericText.parse("-1.5", range: -2...2), -1.5)
        XCTAssertEqual(EditingPointerPressure.normalized(reported: 0, supportsPressure: false), 1)
        XCTAssertEqual(EditingPointerPressure.normalized(reported: 0.25, supportsPressure: true), 0.25)
        XCTAssertNil(EditingPointerPressure.normalized(reported: .nan, supportsPressure: true))
        XCTAssertNil(EditingPointerPressure.normalized(reported: 1.1, supportsPressure: true))
    }
    private func resolved(_ ticket: EditingDevelopmentAnalysisTicket) -> DevelopmentResolvedAdjustmentCommand {
        .init(binding: .init(sourceContentID: source.sourceContentID, sourceGeneration: ticket.context.sourceGeneration,
            expectedRecipeFingerprint: ticket.expectedRecipeFingerprint, stage: ticket.stage), purpose: .automatic(.light),
            parameters: [.light(.init(enabled: true, exposure: 0.7))])
    }
}

extension EditingDevelopmentSessionTests {
    private func summaryResult(_ ticket: EditingDevelopmentAnalysisTicket, group: DevelopmentAdjustmentID = .light,
                               amount: Double, parameters: DevelopmentAdjustmentParametersV3? = nil) -> DevelopmentResolvedAdjustmentCommand {
        let value: DevelopmentAdjustmentParametersV3
        if let parameters { value = parameters }
        else {
            switch group {
            case .color: value = .color(.init(enabled: true, saturation: amount))
            case .blackAndWhite: value = .blackAndWhite(.init(enabled: true, intensity: 0.5 + amount * 0.5))
            default: value = .light(.init(enabled: true, exposure: amount))
            }
        }
        return .init(binding: .init(sourceContentID: ticket.context.sourceContentID, sourceGeneration: ticket.context.sourceGeneration,
            expectedRecipeFingerprint: ticket.expectedRecipeFingerprint, stage: ticket.stage), purpose: .summary(group, amount: amount), parameters: [value])
    }
    @MainActor private func acceptSummary(_ session: EditingDevelopmentSession, context: EditingInteractionContext,
                                         group: DevelopmentAdjustmentID = .light, amount: Double,
                                         gesture: EditingGestureToken? = nil) throws {
        let ticket = try session.admitAnalysis(context: context, gesture: gesture)
        try session.acceptAnalysis(summaryResult(ticket, group: group, amount: amount), ticket: ticket, title: "summary")
    }

    @MainActor func testSummaryGestureOneUndoRestoresExactAmountAndManualRedoRemainsCustom() throws {
        let (draft, session, context) = try make()
        let original = draft.recipe, amount = 0.5164835164835164
        let token = try session.beginGesture(event(context).control, context: context)
        try acceptSummary(session, context: context, amount: 0.25, gesture: token)
        try acceptSummary(session, context: context, amount: amount, gesture: token)
        XCTAssertEqual(session.summaryAmounts[.light]?.bitPattern, amount.bitPattern)
        XCTAssertEqual(session.history.entryCount, 0)
        try session.endGesture(token, .commit)
        let summarized = draft.recipe
        XCTAssertEqual(session.history.entryCount, 1)
        try session.undo(context: context)
        XCTAssertEqual(draft.recipe, original); XCTAssertNil(session.summaryAmounts[.light])
        try session.redo(context: context)
        XCTAssertEqual(draft.recipe, summarized); XCTAssertEqual(session.summaryAmounts[.light]?.bitPattern, amount.bitPattern)
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.8))), event: event(context))
        XCTAssertNil(session.summaryAmounts[.light], "A manual edit must not infer a summary amount")
        try session.undo(context: context); XCTAssertEqual(session.summaryAmounts[.light]?.bitPattern, amount.bitPattern)
        try session.redo(context: context); XCTAssertNil(session.summaryAmounts[.light])
        XCTAssertEqual(draft.recipe.adjustmentsV3?.light.exposure, 0.8)
    }

    @MainActor func testSummaryAmountsRemainIndependentAcrossOtherGroupsEnableAndReset() throws {
        let (draft, session, context) = try make()
        try acceptSummary(session, context: context, amount: 0.4)
        try acceptSummary(session, context: context, group: .color, amount: 0.2)
        try acceptSummary(session, context: context, group: .blackAndWhite, amount: -0.3)
        let all: [DevelopmentAdjustmentID: Double] = [.light: 0.4, .color: 0.2, .blackAndWhite: -0.3]
        XCTAssertEqual(session.summaryAmounts, all)
        try session.apply(.setParameters(.sharpen(.init(enabled: true, intensity: 0.7))), event: event(context, group: .sharpen))
        XCTAssertEqual(session.summaryAmounts, all)
        try session.apply(.setEnabled(.light, false), event: event(context))
        XCTAssertEqual(session.summaryAmounts, all); XCTAssertFalse(session.parameters.light.enabled)
        try session.apply(.setEnabled(.light, true), event: event(context))
        XCTAssertEqual(session.summaryAmounts, all)
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.7))), event: event(context))
        XCTAssertEqual(session.summaryAmounts, [.color: 0.2, .blackAndWhite: -0.3])
        try session.undo(context: context); XCTAssertEqual(session.summaryAmounts, all)
        try session.apply(.reset(.color), event: event(context, group: .color))
        XCTAssertEqual(session.summaryAmounts, [.light: 0.4, .blackAndWhite: -0.3])
        try session.undo(context: context); XCTAssertEqual(session.summaryAmounts, all)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.sharpen.intensity, 0.7)
        try session.apply(.resetAll, event: event(context)); XCTAssertTrue(session.summaryAmounts.isEmpty)
        try session.undo(context: context); XCTAssertEqual(session.summaryAmounts, all)
    }

    @MainActor func testSummaryNoOpOnlyUpdatesEndpointWithoutRecipeWriteOrHistoricalSnapshotRewrite() throws {
        let original = DevelopmentRecipe(adjustmentsV3: .init(light: .init(enabled: true, exposure: 0.7)))
        let (draft, session, context) = try make(original)
        let fp = try EditingFingerprint.of(original)
        let first = try session.admitAnalysis(context: context)
        try session.acceptAnalysis(summaryResult(first, amount: 0.25, parameters: .light(session.parameters.light)), ticket: first, title: "same parameters")
        XCTAssertEqual(draft.recipe, original); XCTAssertEqual(try EditingFingerprint.of(draft.recipe), fp)
        XCTAssertEqual(draft.publications, 0); XCTAssertEqual(session.history.entryCount, 0)
        XCTAssertFalse(session.canUndo); XCTAssertEqual(session.summaryAmounts[.light], 0.25)
        XCTAssertEqual(session.history.totalCost, DevelopmentSummaryUIState.conservativeCost)
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.8))), event: event(context))
        XCTAssertNil(session.summaryAmounts[.light]); XCTAssertEqual(session.history.entryCount, 1)
        try session.undo(context: context); XCTAssertEqual(session.summaryAmounts[.light], 0.25)
        let writes = draft.publications, count = session.history.entryCount
        let current = try session.admitAnalysis(context: context)
        try session.acceptAnalysis(summaryResult(current, amount: 0.6, parameters: .light(session.parameters.light)), ticket: current, title: "UI only")
        XCTAssertEqual(session.summaryAmounts[.light], 0.6)
        XCTAssertEqual(draft.publications, writes); XCTAssertEqual(session.history.entryCount, count)
        try session.redo(context: context); XCTAssertNil(session.summaryAmounts[.light])
        try session.undo(context: context)
        XCTAssertEqual(session.summaryAmounts[.light], 0.25, "The later UI-only endpoint cannot overwrite an immutable beforeUI snapshot")
        XCTAssertEqual(draft.recipe, original)
    }

    @MainActor func testSummaryCancelRejectedCommitAndLateResultCannotReplaceCurrentMetadata() throws {
        let (draft, session, context) = try make()
        try acceptSummary(session, context: context, amount: 0.25)
        let baseline = draft.recipe, count = session.history.entryCount
        let token = try session.beginGesture(event(context).control, context: context)
        try acceptSummary(session, context: context, amount: 0.6, gesture: token)
        XCTAssertEqual(session.summaryAmounts[.light], 0.6)
        try session.endGesture(token, .cancel)
        XCTAssertEqual(draft.recipe, baseline); XCTAssertEqual(session.summaryAmounts[.light], 0.25)
        XCTAssertEqual(session.history.entryCount, count)
        draft.rejectCommit = true
        XCTAssertThrowsError(try session.undo(context: context))
        XCTAssertEqual(session.summaryAmounts[.light], 0.25); XCTAssertEqual(draft.recipe, baseline)
        let rejected = try session.admitAnalysis(context: context)
        XCTAssertThrowsError(try session.acceptAnalysis(summaryResult(rejected, amount: 0.8), ticket: rejected, title: "reject"))
        XCTAssertEqual(session.summaryAmounts[.light], 0.25); XCTAssertEqual(session.history.entryCount, count)
        draft.rejectCommit = false
        let late = try session.admitAnalysis(context: context)
        try session.prepareForBranchReplacement(context: context)
        let fresh = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 1)
        XCTAssertNotEqual(fresh.draftBranchID, context.draftBranchID); XCTAssertTrue(session.summaryAmounts.isEmpty)
        let writes = draft.publications
        XCTAssertThrowsError(try session.acceptAnalysis(summaryResult(late, amount: 0.9), ticket: late, title: "late"))
        XCTAssertEqual(draft.publications, writes); XCTAssertTrue(session.summaryAmounts.isEmpty)
        XCTAssertThrowsError(try session.redo(context: context))
    }

    @MainActor func testSummarySaveFocusResumePreservesBranchButNewBranchAndSourceDoNotBorrowMetadata() throws {
        let (draft, session, context) = try make()
        try acceptSummary(session, context: context, amount: 0.55)
        let ticket = try session.makeSaveTicket(context: context)
        XCTAssertTrue(session.acceptsSaveCompletion(ticket)); XCTAssertEqual(session.summaryAmounts[.light], 0.55)
        try session.suspend(context: context); XCTAssertTrue(session.summaryAmounts.isEmpty)
        let resumed = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 2,
            branchID: context.draftBranchID, noiseReduction: .image)
        XCTAssertEqual(session.summaryAmounts[.light], 0.55)
        XCTAssertFalse(session.acceptsSaveCompletion(ticket)); XCTAssertEqual(draft.recipe, ticket.recipe)
        try session.prepareForBranchReplacement(context: resumed)
        let fresh = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 2)
        XCTAssertTrue(session.summaryAmounts.isEmpty, "Explicit continue/select creates a new branch, even with identical recipe")
        try session.suspend(context: fresh)
        let other = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "c", count: 64), exifOrientation: 6, orientedWidth: 2400, orientedHeight: 3600)
        _ = try session.activate(workID: "work", admissionFingerprint: admission, source: other, sourceGeneration: 3, branchID: context.draftBranchID)
        XCTAssertTrue(session.summaryAmounts.isEmpty, "A different admitted source cannot use the old branch's amounts")
    }

    @MainActor func testSummaryExternalControllerCommitKeepsUnchangedGroupAndRecordsManualCustomProvenance() throws {
        let (draft, session, context) = try make()
        try acceptSummary(session, context: context, amount: 0.4)
        let beforeColor = draft.recipe
        draft.recipe.adjustmentsV3?.color = .init(enabled: true, vibrance: 0.3)
        try session.recordControllerCommit(before: beforeColor, after: draft.recipe, event: event(context, group: .color))
        XCTAssertEqual(session.summaryAmounts[.light], 0.4)
        let beforeLight = draft.recipe
        draft.recipe.adjustmentsV3?.light.exposure = 0.8
        try session.recordControllerCommit(before: beforeLight, after: draft.recipe, event: event(context))
        XCTAssertNil(session.summaryAmounts[.light])
        try session.undo(context: context); XCTAssertEqual(session.summaryAmounts[.light], 0.4)
        try session.redo(context: context); XCTAssertNil(session.summaryAmounts[.light])
        // A divergent recipe cannot recover old provenance simply by activating the old history key.
        try session.suspend(context: context)
        draft.recipe.adjustmentsV3?.light.exposure = 0.1
        _ = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 2, branchID: context.draftBranchID)
        XCTAssertTrue(session.summaryAmounts.isEmpty); XCTAssertFalse(session.canUndo)
    }

    @MainActor func testSummarySidecarsAreChargedAndEvictedWithHistoryIncludingUIOnlyEndpoints() throws {
        let before = DevelopmentRecipe(adjustmentsV3: .init()), after = DevelopmentRecipe(adjustmentsV3: .init(light: .init(enabled: true, exposure: 0.5)))
        var state = DevelopmentSummaryUIState(); state.remember(group: .light, amount: 0.5, recipe: after)
        func key(_ value: String) -> DevelopmentHistoryKey {
            .init(workID: value, admissionFingerprint: admission, sourceContentID: source.sourceContentID, branchID: .init())
        }
        let first = key("first")
        var history = DevelopmentUndoHistory(limits: .init(entriesPerBranch: 1, bytesPerBranch: 100_000, totalBytes: 100_000, branches: 2))
        history.activate(first, current: before)
        history.record(before: before, after: after, title: "summary", afterUI: state)
        XCTAssertEqual(history.totalCost, DevelopmentUndoHistory.metadataCost(before) + DevelopmentUndoHistory.metadataCost(after) + 3 * 1024)
        XCTAssertEqual(history.currentUI(current: after).amounts[.light], 0.5)
        for value in ["second", "third"] {
            history.activate(key(value), current: after)
            history.updateCurrentUI(state, current: after)
        }
        XCTAssertEqual(history.branchCount, 2); XCTAssertLessThanOrEqual(history.totalCost, 100_000)
        history.activate(first, current: after)
        XCTAssertTrue(history.currentUI(current: after).isEmpty, "The evicted branch's metadata must not live in an independent cache")
        XCTAssertFalse(history.canUndo)
        var small = DevelopmentUndoHistory(limits: .init(bytesPerBranch: 1024, totalBytes: 1024))
        small.activate(key("small"), current: before)
        small.record(before: before, after: after, title: "oversized recipe history", afterUI: state)
        XCTAssertFalse(small.canUndo); XCTAssertEqual(small.totalCost, 1024)
        XCTAssertEqual(small.currentUI(current: after).amounts[.light], 0.5)
        var none = DevelopmentUndoHistory(limits: .init(bytesPerBranch: 0, totalBytes: 0))
        none.activate(key("none"), current: after); none.updateCurrentUI(state, current: after)
        XCTAssertEqual(none.totalCost, 0); XCTAssertTrue(none.currentUI(current: after).isEmpty)
    }
}

extension EditingDevelopmentSessionTests {
    @MainActor func testSummaryUIOnlyAcceptanceRejectsReentrantScopeRevocationWithoutRecipeOrMetadataWrite() throws {
        let original = DevelopmentRecipe(adjustmentsV3: .init(light: .init(enabled: true, exposure: 0.7)))
        let (draft, session, context) = try make(original)
        let initial = try session.admitAnalysis(context: context)
        try session.acceptAnalysis(summaryResult(initial, amount: 0.25, parameters: .light(session.parameters.light)), ticket: initial, title: "known")
        XCTAssertEqual(session.summaryAmounts[.light], 0.25); XCTAssertEqual(draft.publications, 0)
        let late = try session.admitAnalysis(context: context)
        let same = summaryResult(late, amount: 0.6, parameters: .light(session.parameters.light))
        session.currentDehazeContext = { expected in
            try session.invalidate(context: expected, reason: .sourceInvalidated)
            return nil
        }
        XCTAssertThrowsError(try session.acceptAnalysis(same, ticket: late, title: "reentrant UI-only result"))
        XCTAssertNil(session.context); XCTAssertTrue(session.summaryAmounts.isEmpty)
        XCTAssertEqual(draft.recipe, original); XCTAssertEqual(draft.publications, 0); XCTAssertEqual(draft.commitAttempts, 0)
    }
}

extension EditingDevelopmentSessionTests {
    @MainActor private func cropTicket(_ session: EditingDevelopmentSession, _ context: EditingInteractionContext) throws -> EditingGeometryAnalysisTicket {
        let cropContext = try session.changePage(.crop, context: context)
        return try session.admitGeometryAnalysis(context: cropContext, operationID: UUID(), input: nil)
    }
    private func geometryResult(_ ticket: EditingGeometryAnalysisTicket, noResult: DevelopmentCropAutoNoResultV1? = nil,
                                presented: String? = nil, generation: UInt64? = nil, expected: String? = nil,
                                stage: DevelopmentAnalysisStage = .orientedSourceBeforeGeometry) throws -> DevelopmentResolvedGeometryV1 {
        let baseline = try XCTUnwrap(ticket.analysis.analysisRecipe.adjustmentsV3?.geometry)
        let resolution: DevelopmentGeometryResolutionV1
        if let noResult { resolution = .noResult(noResult) }
        else {
            let geometry = try DevelopmentCropGeometryAutoV1.candidate(baseline: baseline, sourceSize: source.sourceSize,
                absoluteDegrees: 3, aspectRatio: ticket.input.aspectRatio)
            resolution = .candidate(geometry, .init(firstDegrees: 3, secondDegrees: 3.2, firstConfidence: 1,
                secondConfidence: 1, verificationPair: .init(positiveRoll: .init(knownRollDegrees: 3, correctionDegrees: -3, confidence: 1),
                    negativeRoll: .init(knownRollDegrees: -3, correctionDegrees: 3, confidence: 1))))
        }
        return .init(binding: .init(sourceContentID: source.sourceContentID,
            sourceGeneration: generation ?? ticket.analysis.context.sourceGeneration,
            expectedRecipeFingerprint: expected ?? ticket.analysis.expectedRecipeFingerprint, stage: stage),
            source: source, presentedRecipeFingerprint: presented ?? ticket.analysis.draftRecipeFingerprint,
            input: ticket.input, resolution: resolution)
    }
    @MainActor func testCropAutomaticLegacyCandidateIsOneAtomicUndoAndKeepsWholeGeometryAndOtherGroups() throws {
        var legacy = DevelopmentRecipe(); legacy.crop = .init(x: 0.13, y: 0.21, width: 0.72, height: 0.61); legacy.exposureEV = 0.5
        let (draft, session, context) = try make(legacy)
        let cropContext = try session.changePage(.crop, context: context)
        let constraint = PhotosCropConstraint(aspect: .square)
        try session.setCropConstraint(constraint, context: cropContext)
        let ticket = try session.admitGeometryAnalysis(context: cropContext, operationID: UUID(), input: nil)
        let actualVisible = String(repeating: "d", count: 64) // Captured uncropped request identity, distinct from full original draft.
        let result = try geometryResult(ticket, presented: actualVisible)
        XCTAssertNotEqual(ticket.analysis.draftRecipeFingerprint, actualVisible)
        XCTAssertTrue(try session.acceptGeometryAnalysis(result, ticket: ticket, expectedPresentedFingerprint: actualVisible, title: "自动拉直与裁切"))
        XCTAssertEqual(draft.publications, 1); XCTAssertEqual(session.history.entryCount, 1)
        let after = draft.recipe
        XCTAssertEqual(after.adjustmentsV3?.geometry.straightenDegrees, 3)
        XCTAssertEqual(after.adjustmentsV3?.legacyBasis?.exposureEV, 0.5)
        XCTAssertEqual(session.cropConstraint, constraint)
        try session.undo(context: cropContext); XCTAssertEqual(draft.recipe, legacy)
        try session.redo(context: cropContext); XCTAssertEqual(draft.recipe, after)
        XCTAssertEqual(session.history.entryCount, 1)
    }
    @MainActor func testCropAutomaticNoResultConsumesOnlyItsTicketWithoutPromotionWritesOrHistory() throws {
        for reason in [DevelopmentCropAutoNoResultV1.noHorizon, .unsupportedGeometry, .unchanged, .failedVerification] {
            let (draft, session, context) = try make()
            let ticket = try cropTicket(session, context), before = draft.recipe
            let result = try geometryResult(ticket, noResult: reason)
            XCTAssertFalse(try session.acceptGeometryAnalysis(result, ticket: ticket,
                expectedPresentedFingerprint: ticket.analysis.draftRecipeFingerprint, title: "自动拉直与裁切"))
            XCTAssertEqual(draft.recipe, before); XCTAssertEqual(draft.publications, 0); XCTAssertEqual(draft.commitAttempts, 0)
            XCTAssertFalse(session.canUndo); XCTAssertEqual(session.history.entryCount, 0)
            XCTAssertThrowsError(try session.acceptGeometryAnalysis(result, ticket: ticket,
                expectedPresentedFingerprint: ticket.analysis.draftRecipeFingerprint, title: "late duplicate"))
        }
    }
    @MainActor func testCropAutomaticRejectsBindingFullDraftAndCompleteConstraintChangesWithoutWriting() throws {
        for mutation in ["generation", "expected", "stage", "visible", "fullDraft", "constraint", "tracking"] {
            let (draft, session, context) = try make()
            let ticket = try cropTicket(session, context), original = draft.recipe
            let result = try geometryResult(ticket, noResult: .noHorizon,
                generation: mutation == "generation" ? 2 : nil,
                expected: mutation == "expected" ? String(repeating: "e", count: 64) : nil,
                stage: mutation == "stage" ? .workingImageBeforeGeometry : .orientedSourceBeforeGeometry)
            if mutation == "fullDraft" { draft.recipe.exposureEV = 0.25 }
            if mutation == "constraint" {
                var constraint = session.cropConstraint; constraint.customWidth = 6; constraint.customHeight = 4
                // Same effective freeform ratio, but a different complete captured selection must revoke.
                try session.setCropConstraint(constraint, context: ticket.analysis.context)
            }
            var tracking: EditingGestureToken?
            if mutation == "tracking" { tracking = try session.beginGesture(.init(group: nil, name: "crop"), context: ticket.analysis.context) }
            let before = draft.recipe
            XCTAssertThrowsError(try session.acceptGeometryAnalysis(result, ticket: ticket,
                expectedPresentedFingerprint: mutation == "visible" ? String(repeating: "f", count: 64) : ticket.analysis.draftRecipeFingerprint,
                title: "must reject"), mutation)
            XCTAssertEqual(draft.recipe, before, mutation); XCTAssertEqual(draft.publications, 0, mutation)
            XCTAssertEqual(session.history.entryCount, 0, mutation)
            if let tracking { try session.endGesture(tracking, .cancel) }
            if mutation != "fullDraft" { XCTAssertEqual(draft.recipe, original, mutation) }
        }
    }
    @MainActor func testCropAutomaticOldBranchCannotWriteOrClearTheNewAnalysisTicket() throws {
        let (draft, session, context) = try make()
        let old = try cropTicket(session, context), oldResult = try geometryResult(old)
        try session.suspend(context: old.analysis.context)
        let replacement = try session.activate(workID: "work", admissionFingerprint: admission, source: source, sourceGeneration: 1)
        let current = try cropTicket(session, replacement), currentResult = try geometryResult(current, noResult: .unchanged)
        XCTAssertThrowsError(try session.acceptGeometryAnalysis(oldResult, ticket: old,
            expectedPresentedFingerprint: old.analysis.draftRecipeFingerprint, title: "old branch"))
        XCTAssertFalse(try session.acceptGeometryAnalysis(currentResult, ticket: current,
            expectedPresentedFingerprint: current.analysis.draftRecipeFingerprint, title: "current no-result"))
        XCTAssertEqual(draft.publications, 0); XCTAssertFalse(session.canUndo)
    }
    @MainActor func testCropAutomaticUsesCurrentContextAndRejectsReentrantRevocationBeforeAnyCommit() throws {
        let (draft, session, context) = try make()
        let ticket = try cropTicket(session, context), result = try geometryResult(ticket)
        session.currentDehazeContext = { expected in
            try session.suspend(context: expected)
            return nil
        }
        XCTAssertThrowsError(try session.acceptGeometryAnalysis(result, ticket: ticket,
            expectedPresentedFingerprint: ticket.analysis.draftRecipeFingerprint, title: "revoked finalizer"))
        XCTAssertEqual(draft.publications, 0); XCTAssertEqual(draft.commitAttempts, 0)
        XCTAssertNil(session.context); XCTAssertFalse(session.canUndo)
    }
}
