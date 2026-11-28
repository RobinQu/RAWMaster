import AppKit
import Combine
import SwiftUI
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging
@testable import RAWMaster

final class PhotosDevelopmentIntegrationTests: XCTestCase {
    @MainActor func testBWSummaryV2SelectionIsExplicitAndRestrictedToQAImportedRAW() {
        func sampling(_ operation: DevelopmentAnalysisOperation = .summary(.blackAndWhite,amount:0.5), raw: Bool = true,
                      bundle: String? = "io.robinqu.RAWMaster.preview022", environment: [String:String] = ["RAWMASTER_QA_BW_SUMMARY_V2":"1"]) -> DevelopmentAnalysisSampling {
            EditingController.summarySampling(operation:operation,sourceIsRAW:raw,bundleIdentifier:bundle,environment:environment)
        }
        XCTAssertEqual(sampling(),.blackAndWhiteSummaryStripes32V2)
        XCTAssertEqual(sampling(environment:[:]),.legacy)
        XCTAssertEqual(sampling(environment:["RAWMASTER_QA_BW_SUMMARY_V2":"true"]),.legacy)
        XCTAssertEqual(sampling(bundle:nil),.legacy)
        XCTAssertEqual(sampling(bundle:"io.robinqu.RAWMaster"),.legacy)
        XCTAssertEqual(sampling(raw:false),.legacy)
        XCTAssertEqual(sampling(.automatic(.blackAndWhite)),.legacy)
        XCTAssertEqual(sampling(.summary(.color,amount:0.5)),.legacy)
    }

    @MainActor func testAdvancedDetailRequiresActualIndividualCapabilitiesAndRejectsDehaze() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let unavailable = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: PhotosDevelopmentBackend())
        try await ready(unavailable, asset: fixture.assets[0]); let absent = try await activate(unavailable)
        let original = unavailable.recipe
        XCTAssertTrue(unavailable.availableDevelopmentAdvancedDetailGroups.isEmpty)
        XCTAssertThrowsError(try unavailable.changeDevelopmentAdvancedDetail(.texture, change: .amount(0), context: absent))
        XCTAssertEqual(unavailable.recipe, original); XCTAssertFalse(unavailable.developmentSession.canUndo)
        await unavailable.shutdown()

        // Even an erroneous future Dehaze fact cannot expose a control in this closed phase.
        let backend = PhotosDevelopmentBackend(advancedDetailCapabilities: [.texture, .dehaze])
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        XCTAssertEqual(editing.availableDevelopmentAdvancedDetailGroups, [.texture])
        XCTAssertFalse(editing.availablePhotosGroups.contains(.texture), "Advanced controls stay inside the advanced disclosure")
        XCTAssertFalse(editing.supportsDevelopmentAutomatic(.texture))
        for group in [DevelopmentAdjustmentID.clarity, .dehaze] {
            XCTAssertThrowsError(try editing.changeDevelopmentAdvancedDetail(group, change: .amount(10), context: context))
        }
        let before = editing.recipe
        try editing.changeDevelopmentAdvancedDetail(.texture, change: .amount(0), context: context)
        try editing.changeDevelopmentAdvancedDetail(.texture, change: .reset, context: context)
        XCTAssertEqual(editing.recipe, before); XCTAssertFalse(editing.developmentSession.canUndo)
        let precise = 12.3456789
        try editing.changeDevelopmentAdvancedDetail(.texture, change: .amount(precise), context: context)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.texture.amount, precise)
        let accepted = editing.recipe
        for value in [Double.nan, .infinity, -.infinity, -100.01, 100.01] {
            XCTAssertThrowsError(try editing.changeDevelopmentAdvancedDetail(.texture, change: .amount(value), context: context))
        }
        XCTAssertEqual(editing.recipe, accepted)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, before)
        let requests = await backend.userRequests
        XCTAssertTrue(requests.isEmpty, "Manual detail changes must not open an analysis/Auto path")
        await editing.shutdown()
    }

    @MainActor func testAdvancedDetailOneGestureRemembersDisabledValuesAndResetsOnlyItsGroup() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: PhotosDevelopmentBackend(advancedDetailCapabilities: [.texture, .clarity]))
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        XCTAssertEqual(editing.availableDevelopmentAdvancedDetailGroups, [.texture, .clarity])
        try editing.updateDevelopmentLegacy(context: context, control: "legacy.whites") { basis in
            var color = basis.color ?? .init(); color.tones.whites = 25; basis.color = color
        }
        let before = editing.recipe, count = editing.developmentSession.history.entryCount
        let token = try editing.developmentSession.beginGesture(.init(group: .texture, name: "纹理"), context: context)
        for value in [10.0, 20.0, 35.0] {
            try editing.changeDevelopmentAdvancedDetail(.texture, change: .amount(value), context: context, gesture: token)
        }
        try editing.developmentSession.endGesture(token, .commit)
        XCTAssertEqual(editing.developmentSession.history.entryCount, count + 1)
        let textured = editing.recipe
        XCTAssertEqual(textured.adjustmentsV3?.advancedDetail.texture, .init(enabled: true, amount: 35))
        XCTAssertEqual(editing.developmentLegacyBasis.color?.tones.whites, 25)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, before)
        editing.undoDevelopment(context: context, redo: true); XCTAssertEqual(editing.recipe, textured)

        try editing.changeDevelopmentAdvancedDetail(.texture, change: .enabled(false), context: context)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.texture, .init(enabled: false, amount: 35))
        try editing.changeDevelopmentAdvancedDetail(.texture, change: .enabled(true), context: context)
        XCTAssertEqual(editing.recipe, textured)
        let cancelled = try editing.developmentSession.beginGesture(.init(group: .clarity, name: "Clarity"), context: context)
        try editing.changeDevelopmentAdvancedDetail(.clarity, change: .amount(-40), context: context, gesture: cancelled)
        try editing.developmentSession.endGesture(cancelled, .cancel)
        XCTAssertEqual(editing.recipe, textured)
        try editing.changeDevelopmentAdvancedDetail(.clarity, change: .amount(-100), context: context)
        let both = editing.recipe
        try editing.changeDevelopmentAdvancedDetail(.texture, change: .reset, context: context)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.texture, .init())
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.clarity, .init(enabled: true, amount: -100))
        XCTAssertEqual(editing.developmentLegacyBasis.color?.tones.whites, 25)
        XCTAssertEqual(try JSONDecoder().decode(DevelopmentRecipe.self, from: JSONEncoder().encode(editing.recipe)), editing.recipe)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, both)
        await editing.shutdown()
    }

    @MainActor func testAdvancedDetailFocusAndBranchRejectCapturedOldCallbacksIncludingNoop() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: PhotosDevelopmentBackend(advancedDetailCapabilities: [.texture, .clarity]))
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let token = try editing.developmentSession.beginGesture(.init(group: .texture, name: "纹理"), context: context)
        try editing.changeDevelopmentAdvancedDetail(.texture, change: .amount(20), context: context, gesture: token)
        editing.suspendDevelopmentFocus()
        let suspended = editing.recipe
        XCTAssertThrowsError(try editing.changeDevelopmentAdvancedDetail(.texture, change: .amount(20), context: context, gesture: token))
        XCTAssertThrowsError(try editing.changeDevelopmentAdvancedDetail(.clarity, change: .reset, context: context))
        XCTAssertThrowsError(try editing.developmentSession.endGesture(token, .commit))
        XCTAssertEqual(editing.recipe, suspended)
        let resumed = try await activate(editing)
        XCTAssertNotEqual(resumed.draftBranchEpoch, context.draftBranchEpoch)
        let late = try editing.developmentSession.beginGesture(.init(group: .clarity, name: "Clarity"), context: resumed)
        try editing.changeDevelopmentAdvancedDetail(.clarity, change: .amount(15), context: resumed, gesture: late)
        let version = try XCTUnwrap(editing.versions.first { $0.kind == .original })
        editing.selectVersion(version, continueEditing: true)
        let replacement = try await activate(editing, excluding: resumed.draftBranchID), current = editing.recipe
        XCTAssertNotEqual(replacement.draftBranchID, resumed.draftBranchID)
        XCTAssertThrowsError(try editing.changeDevelopmentAdvancedDetail(.clarity, change: .amount(99), context: resumed, gesture: late))
        XCTAssertThrowsError(try editing.developmentSession.endGesture(late, .commit))
        XCTAssertEqual(editing.recipe, current); XCTAssertFalse(editing.developmentSession.canUndo)
        await editing.shutdown()
    }
    @MainActor func testFocusResumesWithTheSameMeasurementAndRejectsAnOldPixelResult() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend()
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0])
        let original = try await activate(editing)
        try await promptWait { editing.developmentHistogram != nil }
        let first = editing.developmentHistogram, count = await backend.displayRequests.count
        editing.suspendDevelopmentFocus()
        XCTAssertNil(editing.developmentContext)
        XCTAssertEqual(editing.developmentHistogram, first)
        let resumed = try await activate(editing)
        XCTAssertNotEqual(resumed, original)
        await settled(editing)
        let afterFocus = await backend.displayRequests.count
        XCTAssertEqual(afterFocus, count)
        let gate = PhotosAnalysisGate()
        await backend.setDisplayGate(gate)
        do {
            editing.setRecipe { $0.exposureEV = 0.5 }
            try await promptWait { await gate.didEnter }
            editing.suspendDevelopmentFocus()
            let canceled = await gate.didCancel
            XCTAssertFalse(canceled)
            await backend.setDisplayGate(nil)
            _ = try await activate(editing)
            editing.setRecipe { $0.exposureEV = 1.0 }
            await gate.release()
            try await promptWait { await backend.displayRequests.last?.preview.recipe == editing.recipe && editing.developmentHistogram != nil }
            let total = await backend.displayRequests.count
            XCTAssertEqual(total, count + 2)
        } catch { await gate.release(); await editing.shutdown(); throw error }
        await editing.shutdown()
    }

    @MainActor func testDisplayHistogramUsesTypedBackgroundRequestWithoutChangingRecipeOrAutoRoute() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend()
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let before = editing.recipe
        for _ in 0..<200 { if editing.developmentHistogram != nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(editing.developmentHistogram); XCTAssertEqual(editing.recipe, before)
        let display = await backend.displayRequests
        XCTAssertFalse(display.isEmpty); XCTAssertTrue(display.allSatisfy { $0.operation.isDisplayHistogram && $0.stage == .workingImageBeforeGeometry })
        let userBefore = await backend.userRequests; XCTAssertTrue(userBefore.isEmpty)
        let completed = expectation(description: "original Auto route completed")
        var began = false, delivered = false
        let observer = editing.$developmentAnalysisBusy.sink { busy in
            if busy { began = true }
            if began, !busy, !delivered { delivered = true; completed.fulfill() }
        }
        editing.requestDevelopmentAutomatic(.light, context: context)
        await fulfillment(of: [completed], timeout: 5); observer.cancel()
        let requests = await backend.userRequests
        XCTAssertTrue(requests.contains { if case .automatic(let group) = $0.operation { return group == .light }; return false })
        XCTAssertFalse(requests.contains { $0.operation.isHistogram })
        await editing.shutdown()
    }
    @MainActor func testExplicitNaturalCurvesDenyAutoAndAdmitOnlySupportedPickerWithoutMutation() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        await settled(editing)
        let legacy = editing.developmentSession.parameters.curves
        XCTAssertEqual(legacy.algorithm, .legacyPCHIPV1)
        XCTAssertTrue(editing.supportsDevelopmentAutomatic(.curves))
        XCTAssertTrue(editing.supportsDevelopmentCurvePicker)
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .black), context: context)
        XCTAssertNotNil(editing.developmentPicker, "The same ready legacy entry point must be available")
        editing.cancelDevelopmentPicker(context: context)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for enabled in [false, true] {
            var natural = legacy
            natural.algorithm = .naturalCubicGamma512LumaV1; natural.enabled = enabled
            natural.rgb.curve = .init(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.45), .init(x: 1, y: 1)])
            try editing.developmentSession.apply(.setParameters(.curves(natural)),
                event: .init(context: context, control: .init(group: .curves, name: "Explicit natural capability")))
            await settled(editing)
            XCTAssertTrue(editing.availablePhotosGroups.contains(.curves), "Manual curves remain available")
            XCTAssertTrue(editing.supportsDevelopmentAutomatic(.light))
            XCTAssertFalse(editing.developmentAnalysisBusy)
            XCTAssertFalse(editing.supportsDevelopmentAutomatic(.curves))
            XCTAssertTrue(editing.supportsDevelopmentCurvePicker)
            let before = editing.recipe, bytes = try encoder.encode(editing.recipe)
            let entries = editing.developmentSession.history.entryCount
            let requestsBefore = await backend.userRequests
            editing.requestDevelopmentAutomatic(.curves, context: context)
            for channel in [DevelopmentCurveChannelV3ID.rgb, .red, .green, .blue] {
                for point in [DevelopmentCurvePickerPointV3.black, .midtone, .white, .addPoint] {
                    editing.beginDevelopmentPicker(.curve(channel: channel, point: point), context: context)
                    XCTAssertNotNil(editing.developmentPicker)
                    editing.cancelDevelopmentPicker(context: context)
                }
            }
            let requestsAfter = await backend.userRequests
            XCTAssertEqual(requestsAfter.map(\.operationID), requestsBefore.map(\.operationID))
            XCTAssertFalse(editing.developmentAnalysisBusy)
            XCTAssertEqual(editing.recipe, before)
            XCTAssertEqual(try encoder.encode(editing.recipe), bytes)
            XCTAssertEqual(editing.developmentSession.history.entryCount, entries)
            XCTAssertEqual(editing.developmentSession.parameters.curves.algorithm, .naturalCubicGamma512LumaV1)
        }
        let activeLevels = DevelopmentLevelsV3(enabled: true, rgb: .manual(.init(
            black: 0.1, shadows: 0.25, midtones: 0.5, highlights: 0.75, white: 0.9,
            outputBlack: 0, outputWhite: 1)))
        try editing.developmentSession.apply(.setParameters(.levels(activeLevels)),
            event: .init(context: context, control: .init(group: .levels, name: "Downstream levels")))
        await settled(editing)
        XCTAssertFalse(editing.supportsDevelopmentCurvePicker)
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .black), context: context)
        XCTAssertNil(editing.developmentPicker)
        try editing.developmentSession.apply(.setParameters(.levels(.init())),
            event: .init(context: context, control: .init(group: .levels, name: "Reset downstream levels")))
        try editing.developmentSession.apply(.setParameters(.curves(legacy)),
            event: .init(context: context, control: .init(group: .curves, name: "Explicit legacy capability")))
        await settled(editing)
        XCTAssertTrue(editing.supportsDevelopmentAutomatic(.curves))
        XCTAssertTrue(editing.supportsDevelopmentCurvePicker)
        await editing.shutdown()
    }

    @MainActor private func ready(_ editing: EditingController, asset: AssetRecord, timeout: Duration = .seconds(5)) async throws {
        editing.isPresented = true; editing.focus(asset)
        let deadline = ContinuousClock.now + timeout
        while editing.previews.primary.frame == nil, editing.previews.primary.error == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pane = editing.previews.primary
        _ = try XCTUnwrap(pane.frame, "Preview: \(pane.error ?? "no error"), rendering=\(pane.rendering), lease=\(String(describing: pane.currentSourceGeneration)), revision=\(pane.currentRevision), sourceReady=\(editing.sourceReady), stage=\(editing.stage)")
        XCTAssertNotNil(editing.work)
    }
    @MainActor private func activate(_ editing: EditingController, excluding old: EditingDraftBranchID? = nil) async throws -> EditingInteractionContext {
        let activated = expectation(description: "attested development branch activated")
        var received: EditingInteractionContext?
        let observation = editing.developmentSession.$context.sink { value in
            if let value, value.draftBranchID != old, received == nil { received = value; activated.fulfill() }
        }
        editing.beginDevelopmentInterface()
        await fulfillment(of: [activated], timeout: 5); observation.cancel()
        return try XCTUnwrap(received)
    }
    @MainActor private func settled(_ editing: EditingController) async {
        if editing.previews.primary.frame?.revision == editing.previews.primary.currentRevision,
           editing.previews.primary.frameRecipe == editing.recipe { return }
        let done = expectation(description: "current recipe frame delivered")
        var received = false
        let observation = editing.previews.primary.$frame.sink { frame in
            if frame?.revision == editing.previews.primary.currentRevision, !received { received = true; done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 5); observation.cancel()
    }
    @MainActor func testGlobalCapabilitiesAndResolvedWhiteBalanceEditsKeepSourceAndRememberedModes() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        XCTAssertEqual(editing.availablePhotosGroups.count, 11)
        XCTAssertFalse(editing.supportsDevelopmentAutomatic(.selectiveColor))
        XCTAssertTrue(editing.supportsDevelopmentAutomatic(.noiseReduction))
        XCTAssertFalse(editing.availablePhotosGroups.contains(.texture))
        XCTAssertEqual(editing.developmentNoiseReductionFieldIDs, ["amount"])
        let original = editing.recipe, baseline = try XCTUnwrap(editing.developmentWhiteBalanceBaseline)
        // Reading another display mode must preserve as-shot and all exact baseline bits.
        _ = PhotosWhiteBalanceStateEditing.adjustment(in: baseline, mode: .temperatureTint)
        _ = PhotosWhiteBalanceStateEditing.adjustment(in: baseline, mode: .skinTone)
        XCTAssertEqual(editing.recipe, original)
        let command = try PhotosWhiteBalanceStateEditing.command(state: baseline, mode: .temperatureTint, component: .temperature, value: 50)
        try editing.developmentSession.apply(command, event: .init(context: context, control: .init(group: .whiteBalance, name: "色温")))
        let resolved = try XCTUnwrap(editing.recipe.adjustmentsV3?.whiteBalance.resolvedState)
        if case .image(let source, let state) = resolved, case .image(_, let initial) = baseline {
            XCTAssertEqual(source, editing.developmentSession.source)
            XCTAssertEqual(state.gray, initial.gray); XCTAssertEqual(state.skin, initial.skin)
            XCTAssertEqual(state.temperatureOffset, 50)
            XCTAssertEqual(state.temperatureTint.temperature, 5000 * pow(2, 0.5), accuracy: 0.001)
            XCTAssertEqual(state.temperatureTint.tintBits, initial.temperatureTint.tintBits)
        } else { XCTFail("The image source may not be interpreted as a RAW white balance") }
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        let field = try XCTUnwrap(PhotosScalarField.fields(for: .noiseReduction, noiseReduction: .image).first)
        let nr = try PhotosAdjustmentCommands.scalar(field, group: .noiseReduction, value: 2.5,
            parameters: editing.developmentSession.parameters, noiseReduction: .image)
        try editing.developmentSession.apply(nr, event: .init(context: context, control: .init(group: .noiseReduction, name: "降噪")))
        XCTAssertEqual(editing.recipe.adjustmentsV3?.noiseReduction.sourceCapability, .image)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.noiseReduction.nonRawAmount, 2.5)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        await editing.shutdown()
    }
    @MainActor func testChangingDisplayedToolModeRevokesLateWhiteBalanceAutoWithoutWritingRecipe() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        await backend.setGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let before = editing.recipe
        editing.requestDevelopmentWhiteBalanceAutomatic(.neutralGray, context: context)
        await gate.waitUntilEntered()
        editing.cancelDevelopmentToolAnalysis(context: context)
        await gate.waitUntilCancelled()
        XCTAssertEqual(editing.recipe, before)
        XCTAssertEqual(editing.developmentContext, context)
        let ended = expectation(description: "revoked WB Auto actually joined")
        var delivered = false
        let observer = editing.$developmentAnalysisBusy.sink { busy in
            if !busy, !delivered { delivered = true; ended.fulfill() }
        }
        await gate.release(); await fulfillment(of: [ended], timeout: 5); observer.cancel()
        XCTAssertEqual(editing.recipe, before); XCTAssertFalse(editing.developmentSession.canUndo)
        await editing.shutdown()
    }
    @MainActor func testWhiteBalanceAutoKeepsOriginalSourceStageWithinTheSameInteractiveBranch() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let before = editing.recipe
        let completed = expectation(description: "mode-specific WB transaction committed")
        var began = false, delivered = false
        let observer = editing.$developmentAnalysisBusy.sink { busy in
            if busy { began = true }
            if began, !busy, !delivered { delivered = true; completed.fulfill() }
        }
        editing.requestDevelopmentWhiteBalanceAutomatic(.skinTone, context: context)
        await fulfillment(of: [completed], timeout: 5); observer.cancel()
        let requests = await backend.userRequests
        XCTAssertEqual(requests.last?.stage, .orientedSourceBeforeGeometry)
        let lastRequest = try XCTUnwrap(requests.last)
        if case .whiteBalanceAutomatic(let mode) = lastRequest.operation { XCTAssertEqual(mode, .skinTone) }
        else { XCTFail("WB Auto must preserve the displayed mode in its actual analysis request") }
        XCTAssertEqual(editing.developmentContext, context)
        XCTAssertEqual(editing.developmentSession.analysisStage, .workingImageBeforeGeometry)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.whiteBalance.adjustment, .skinTone(warmth: 0))
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, before)
        await editing.shutdown()
    }
    @MainActor func testCurvePickerUsesExactDisplayedGeometryInverseAndOneSourceBoundUndo() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        editing.setRecipe { $0.straightenDegrees = 8; $0.crop = .init(x: 0.1, y: 0.15, width: 0.7, height: 0.6) }
        await settled(editing)
        let before = editing.recipe
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .black), context: context)
        let picker = try XCTUnwrap(editing.developmentPicker), frame = try XCTUnwrap(editing.developmentPickerFrame(for: picker))
        let output = DevelopmentSourcePoint(x: 0.2, y: 0.7)
        let expected = try frame.mapping.sourcePoint(fromOutput: output)
        let completed = expectation(description: "source picker transaction joined")
        var requested = false, received = false
        let observation = editing.$developmentAnalysisBusy.sink { busy in
            if busy { requested = true }
            if requested, !busy, !received { received = true; completed.fulfill() }
        }
        editing.pickDevelopmentSource(output, frame: frame)
        await fulfillment(of: [completed], timeout: 5); observation.cancel()
        let requests = await backend.userRequests
        let lastRequest = try XCTUnwrap(requests.last)
        guard case .curvePicker(_, _, let point) = lastRequest.operation else { return XCTFail("Expected actual source picker operation") }
        XCTAssertEqual(point, expected)
        XCTAssertNotEqual(point, output, "A displayed cropped/straightened position is not a source coordinate")
        XCTAssertNil(editing.developmentPicker)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, before)
        await editing.shutdown()
    }
    @MainActor func testNaturalPickerBindsDisplayedGeometryAndCommitsOneUndoRedo() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let natural = DevelopmentCurvesV3(enabled: true, algorithm: .naturalCubicGamma512LumaV1)
        try editing.developmentSession.apply(.setParameters(.curves(natural)),
            event: .init(context: context, control: .init(group: .curves, name: "Natural picker fixture")))
        var geometry = editing.developmentGeometry
        geometry.straightenDegrees = 8; geometry.crop = .init(x: 0.1, y: 0.15, width: 0.7, height: 0.6)
        try editing.setDevelopmentGeometry(geometry, context: context, control: "Natural picker geometry fixture")
        XCTAssertEqual(editing.recipe.adjustmentsV3?.geometry.straightenDegrees, 8)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.geometry.crop, geometry.crop)
        XCTAssertEqual(editing.developmentContext, context)
        await settled(editing)
        let before = editing.recipe, entries = editing.developmentSession.history.entryCount
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .black), context: context)
        let picker = try XCTUnwrap(editing.developmentPicker)
        let frame = try XCTUnwrap(editing.developmentPickerFrame(for: picker))
        let point = DevelopmentSourcePoint(x: 0.2, y: 0.7)
        let expected = try frame.mapping.sourcePoint(fromOutput: point)
        let completed = expectation(description: "Natural picker transaction joined")
        var requested = false, joined = false
        let observer = editing.$developmentAnalysisBusy.sink { busy in
            if busy { requested = true }
            if requested, !busy, !joined { joined = true; completed.fulfill() }
        }
        editing.pickDevelopmentSource(point, frame: frame)
        await fulfillment(of: [completed], timeout: 5); observer.cancel()
        let requests = await backend.userRequests
        let request = try XCTUnwrap(requests.last)
        guard case .curvePicker(.rgb, .black, let sampled) = request.operation else { return XCTFail("Expected natural picker") }
        XCTAssertTrue(DevelopmentNaturalCurvePickerV1.isNatural(request))
        XCTAssertEqual(request.expectedRecipeFingerprint, try EditingFingerprint.of(before))
        XCTAssertEqual(request.presentedRecipeFingerprint, try EditingFingerprint.of(before))
        XCTAssertEqual(sampled, expected); XCTAssertNotEqual(sampled, point)
        let after = editing.recipe
        XCTAssertEqual(after.adjustmentsV3?.curves.rgb.inputBlack, 0.1)
        XCTAssertEqual(after.adjustmentsV3?.curves.algorithm, .naturalCubicGamma512LumaV1)
        XCTAssertEqual(editing.developmentSession.history.entryCount, entries + 1)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, before)
        editing.undoDevelopment(context: context, redo: true); XCTAssertEqual(editing.recipe, after)
        await editing.shutdown()
    }

    @MainActor func testNaturalPickerRejectsStaleFrameAndCancelsJoinedLateResultOnClose() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let natural = DevelopmentCurvesV3(enabled: true, algorithm: .naturalCubicGamma512LumaV1)
        try editing.developmentSession.apply(.setParameters(.curves(natural)),
            event: .init(context: context, control: .init(group: .curves, name: "Natural picker fixture")))
        await settled(editing)
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .black), context: context)
        let picker = try XCTUnwrap(editing.developmentPicker)
        let stale = try XCTUnwrap(editing.developmentPickerFrame(for: picker))
        let staleRecipeFingerprint = try EditingFingerprint.of(editing.recipe)
        var light = editing.developmentSession.parameters.light
        light.enabled = true; light.exposure = 0.3
        try editing.developmentSession.apply(.setParameters(.light(light)),
            event: .init(context: context, control: .init(group: .light, name: "Natural picker stale-recipe fixture")))
        XCTAssertEqual(editing.recipe.adjustmentsV3?.light.exposure, 0.3)
        XCTAssertNotEqual(try EditingFingerprint.of(editing.recipe), staleRecipeFingerprint)
        XCTAssertEqual(editing.developmentContext, context)
        editing.pickDevelopmentSource(.init(x: 0.4, y: 0.5), frame: stale)
        XCTAssertNil(editing.developmentPicker)
        let rejected = await backend.userRequests
        XCTAssertTrue(rejected.isEmpty)
        await settled(editing)

        let gate = PhotosAnalysisGate()
        await backend.setGate(gate)
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .black), context: context)
        let next = try XCTUnwrap(editing.developmentPicker)
        let current = try XCTUnwrap(editing.developmentPickerFrame(for: next))
        let before = editing.recipe
        editing.pickDevelopmentSource(.init(x: 0.4, y: 0.5), frame: current)
        await gate.waitUntilEntered()
        var stopped = false
        let shutdown = Task { await editing.shutdown(); stopped = true }
        await gate.waitUntilCancelled()
        XCTAssertNil(editing.developmentContext)
        XCTAssertFalse(stopped)
        await gate.release()
        await shutdown.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(editing.recipe, before)
    }

    @MainActor func testNaturalPickerRejectsLateResultAfterSameRecipePublicationEpochChanges() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let natural = DevelopmentCurvesV3(enabled: true, algorithm: .naturalCubicGamma512LumaV1)
        try editing.developmentSession.apply(.setParameters(.curves(natural)),
            event: .init(context: context, control: .init(group: .curves, name: "Natural picker fixture")))
        await settled(editing)
        let before = editing.recipe, entries = editing.developmentSession.history.entryCount
        let gate = PhotosAnalysisGate()
        await backend.setGate(gate)
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .black), context: context)
        let picker = try XCTUnwrap(editing.developmentPicker)
        let clicked = try XCTUnwrap(editing.developmentPickerFrame(for: picker))
        let pane = editing.previews.primary
        let epoch = try XCTUnwrap(pane.currentDevelopmentPickerPublicationEpoch(frameID: clicked.frameID))
        let source = try XCTUnwrap(editing.work?.source)
        editing.pickDevelopmentSource(.init(x: 0.4, y: 0.5), frame: clicked)
        await gate.waitUntilEntered()

        let beforeFrame = try XCTUnwrap(pane.frame)
        let changed = expectation(description: "Same source and recipe publish under replacement epoch")
        var observed = false
        let replacement = pane.$frame.sink { value in
            if let value, value.id != beforeFrame.id, !observed { observed = true; changed.fulfill() }
        }
        pane.submit(try .init(source: .raw(source), recipe: before, quality: .settled,
                             presentationID: "natural-picker-test-replacement-epoch"),
                    input: .capture(control: "fixture", phase: "discrete"))
        await fulfillment(of: [changed], timeout: 5); replacement.cancel()
        let newFrame = try XCTUnwrap(pane.frame)
        XCTAssertEqual(newFrame.leaseID, beforeFrame.leaseID)
        XCTAssertEqual(newFrame.generation, beforeFrame.generation)
        XCTAssertEqual(pane.frameRecipe, before)
        XCTAssertEqual(editing.developmentContext, context)
        let newEpoch = try XCTUnwrap(pane.currentDevelopmentPickerPublicationEpoch(frameID: newFrame.id))
        XCTAssertNotEqual(newEpoch, epoch)
        XCTAssertNil(pane.currentDevelopmentPickerPublicationEpoch(frameID: clicked.frameID))

        let joined = expectation(description: "Late analysis result actually joined")
        var notified = false
        let completion = editing.$developmentAnalysisBusy.sink { busy in
            if !busy, !notified { notified = true; joined.fulfill() }
        }
        await gate.release(); await fulfillment(of: [joined], timeout: 5); completion.cancel()
        XCTAssertEqual(editing.recipe, before)
        XCTAssertEqual(editing.developmentSession.history.entryCount, entries)
        await editing.shutdown()
    }

    @MainActor func testPickerRejectsLateFrameBranchAndOriginalComparisonOrCropModes() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(expandedCapabilities: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing); await settled(editing)
        editing.beginDevelopmentPicker(.selectiveColor(.red), context: context)
        let picker = try XCTUnwrap(editing.developmentPicker), oldFrame = try XCTUnwrap(editing.developmentPickerFrame(for: picker))
        editing.setRecipe { $0.exposureEV = 0.3 }
        editing.pickDevelopmentSource(.init(x: 0.5, y: 0.5), frame: oldFrame)
        XCTAssertNil(editing.developmentPicker)
        await settled(editing)
        editing.setDevelopmentOriginalHeld(true)
        editing.beginDevelopmentPicker(.whiteBalance(.neutralGray), context: context); XCTAssertNil(editing.developmentPicker)
        editing.setDevelopmentOriginalHeld(false); await settled(editing)
        editing.setComparisonMode(.wipeHorizontal)
        editing.beginDevelopmentPicker(.selectiveColor(.red), context: context); XCTAssertNil(editing.developmentPicker)
        editing.stopComparing()
        editing.cropEditing = true
        editing.beginDevelopmentPicker(.curve(channel: .rgb, point: .white), context: context); XCTAssertNil(editing.developmentPicker)
        editing.cropEditing = false
        let original = try XCTUnwrap(editing.versions.first { $0.kind == .original })
        editing.selectVersion(original, continueEditing: true)
        editing.pickDevelopmentSource(.init(x: 0.5, y: 0.5), frame: oldFrame)
        let requests = await backend.userRequests
        XCTAssertTrue(requests.isEmpty, "Rejected old pointer callbacks must never admit an analysis request")
        await editing.shutdown()
    }
    @MainActor func testSourceFactsUseExistingLeaseAndExplicitSameVersionSelectionCreatesNewBranch() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend()
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0])
        let context = try await activate(editing)
        XCTAssertEqual(editing.developmentSourceFacts?.sourceKind, .image)
        XCTAssertEqual(editing.developmentSession.noiseReductionCapability, .image)
        let original = try XCTUnwrap(editing.versions.first { $0.kind == .original })
        let token = try editing.developmentSession.beginGesture(.init(group: .light, name: "光效"), context: context)
        try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.4))),
            event: .init(context: context, control: .init(group: .light, name: "光效")), gesture: token)
        editing.selectVersion(original, continueEditing: true)
        let next = try await activate(editing, excluding: context.draftBranchID)
        XCTAssertNotEqual(next.draftBranchID, context.draftBranchID)
        XCTAssertEqual(editing.recipe, original.recipe)
        XCTAssertThrowsError(try editing.developmentSession.endGesture(token, .cancel))
        editing.undoDevelopment(context: context)
        XCTAssertEqual(editing.recipe, original.recipe); XCTAssertFalse(editing.developmentSession.canUndo)
        let opens = await backend.opens
        XCTAssertEqual(opens, 1, "Adjustment metadata/analysis may not open a second capture lease")
        await editing.shutdown()
    }
    @MainActor func testSummaryLatestPendingResultUsesOneGestureAndOriginalRecipeUndo() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(gate: nil)
        await backend.setGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0])
        let context = try await activate(editing), original = editing.recipe
        let token = try editing.developmentSession.beginGesture(.init(group: .light, name: "光效"), context: context)
        editing.requestDevelopmentSummary(.light, amount: 0.2, context: context, gesture: token)
        await gate.waitUntilEntered()
        for amount in [0.3, 0.5, 0.8] { editing.requestDevelopmentSummary(.light, amount: amount, context: context, gesture: token) }
        editing.finishDevelopmentSummary(token)
        let ended = expectation(description: "latest summary joined and gesture committed")
        var delivered = false
        let observation = editing.$developmentAnalysisBusy.sink { busy in
            if !busy, !delivered { delivered = true; ended.fulfill() }
        }
        await gate.release()
        await fulfillment(of: [ended], timeout: 5); observation.cancel()
        XCTAssertEqual(editing.recipe.adjustmentsV3?.light.brilliance, 0.8)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        editing.undoDevelopment(context: context)
        XCTAssertEqual(editing.recipe, original)
        let requests = await backend.userRequests
        XCTAssertEqual(requests.count, 2, "One active request and a latest1 pending value, not one task per slider event")
        XCTAssertEqual(requests.first?.presentedRecipeFingerprint, try EditingFingerprint.of(original))
        XCTAssertEqual(requests.first?.preview.recipe.schemaVersion, 3)
        await editing.shutdown()
    }
    @MainActor func testBlockedV1ProgressCannotCrossOriginalHoldAndReleaseFence() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        // The backend is scalar-only: this extension controls the actual Controller RAW progress path,
        // without decoding RAW or relying on V3's different engine string to retire a channel.
        let originalAsset = fixture.assets[0], source = fixture.root.appendingPathComponent("progress-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let rawURL = source.appendingPathComponent("progress.ARW")
        try Data(contentsOf: originalAsset.resolvedURL).write(to: rawURL)
        let progressSession = try await ImportService(store: fixture.store).importDirectory(source: source, destination: nil,
            projectName: "Progress RAW", mode: .reference, initialScreening: false, progress: { _ in })
        let rawAsset = try XCTUnwrap(fixture.store.loadAssets().first { $0.sessionID == progressSession.id })
        let initial = expectation(description: "initial RAW progress submitted")
        let blocked = expectation(description: "V1 exposure draft active")
        let resumed = expectation(description: "released draft submitted to a new registration")
        let backend = PhotosDevelopmentBackend(progressSubmitted: { count in
            if count == 1 { initial.fulfill() }
            if count == 2 { blocked.fulfill() }
            if count == 3 { resumed.fulfill() }
        })
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        editing.isPresented = true; editing.focus(rawAsset)
        await fulfillment(of: [initial], timeout: 5)
        let firstSubmissions = await backend.progressSubmissions
        let box = try XCTUnwrap(firstSubmissions.first?.box)
        let firstFrame = expectation(description: "initial frame delivered")
        var receivedFirst = false
        let firstObserver = editing.previews.primary.$frame.sink { frame in
            if frame != nil, !receivedFirst { receivedFirst = true; firstFrame.fulfill() }
        }
        box.finishActive(); await fulfillment(of: [firstFrame], timeout: 5); firstObserver.cancel()
        let initialFrameID = editing.previews.primary.frame?.id
        editing.setRecipe { $0.exposureEV = 0.7 }
        await fulfillment(of: [blocked], timeout: 5)
        XCTAssertEqual(editing.recipe.schemaVersion, 1)
        let draftPresentation = editing.developmentPreviewPresentationID
        editing.setDevelopmentOriginalHeld(true)
        XCTAssertNotEqual(editing.developmentPreviewPresentationID, draftPresentation)
        editing.setDevelopmentOriginalHeld(false)
        XCTAssertEqual(editing.developmentPreviewPresentationID, draftPresentation)
        // Complete the old active V1 request after the synchronous A -> original -> A transition.
        // Its engine/geometry/branch are identical to the new target, so the mode fence is decisive.
        box.finishActive()
        await fulfillment(of: [resumed], timeout: 5)
        let submissions = await backend.progressSubmissions
        let last = try XCTUnwrap(submissions.last)
        XCTAssertNotEqual(last.box.id, box.id)
        XCTAssertEqual(submissions.count, 3)
        XCTAssertEqual(last.request.recipe.schemaVersion, 1)
        XCTAssertEqual(last.request.recipe.exposureEV, 0.7)
        XCTAssertEqual(editing.previews.primary.frame?.id, initialFrameID, "Old active draft cannot publish across M mode")
        let finalFrame = expectation(description: "new target delivered")
        var receivedFinal = false
        let finalObserver = editing.previews.primary.$frame.sink { frame in
            if frame?.revision == last.request.revision, !receivedFinal { receivedFinal = true; finalFrame.fulfill() }
        }
        last.box.finishActive(); await fulfillment(of: [finalFrame], timeout: 5); finalObserver.cancel()
        XCTAssertEqual(editing.previews.primary.frameRecipe?.exposureEV, 0.7)
        await editing.shutdown()
    }
    @MainActor func testFocusLossCancelsPendingFactsAndLateFrameCannotReactivateSession() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let cancelled = expectation(description: "pending facts receive cancellation on focus loss")
        let gate = PhotosAnalysisGate(onCancellation: { cancelled.fulfill() })
        let backend = PhotosDevelopmentBackend()
        await backend.setFactsGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0])
        var activatedWhileBlurred = false
        let contextObserver = editing.developmentSession.$context.sink { if $0 != nil { activatedWhileBlurred = true } }
        editing.beginDevelopmentInterface(); await gate.waitUntilEntered()
        XCTAssertNil(editing.developmentContext)
        editing.suspendDevelopmentFocus()
        await fulfillment(of: [cancelled], timeout: 5)
        // A real late preview completion invokes updatePreviewPresentation while metadata is still held.
        let lateFrame = expectation(description: "late frame while window is not key")
        let priorRevision = editing.previews.primary.currentRevision
        var received = false
        let frameObserver = editing.previews.primary.$frame.sink { frame in
            if let frame, frame.revision > priorRevision, !received { received = true; lateFrame.fulfill() }
        }
        editing.setRecipe { $0.exposureEV = 0.25 }
        await fulfillment(of: [lateFrame], timeout: 5); frameObserver.cancel()
        let factsRequests = await backend.factsRequests
        XCTAssertEqual(factsRequests, 1, "Late frame must not reopen metadata admission while blurred")
        XCTAssertNil(editing.developmentContext)
        await gate.release()
        await editing.shutdown() // joins the held facts operation before assertions about late delivery
        contextObserver.cancel()
        XCTAssertFalse(activatedWhileBlurred)
        XCTAssertNil(editing.developmentContext)
    }
    @MainActor func testShutdownRevokesAnalysisBeforeJoiningItsOwnedChildAndNeverCommitsLateResult() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(gate: nil)
        await backend.setGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0])
        let context = try await activate(editing), before = editing.recipe
        editing.requestDevelopmentAutomatic(.light, context: context)
        await gate.waitUntilEntered()
        var stopped = false
        let shutdown = Task { await editing.shutdown(); stopped = true }
        await gate.waitUntilCancelled()
        XCTAssertNil(editing.developmentContext)
        XCTAssertFalse(stopped, "Controller must await its actual analysis child, not just revoke delivery")
        await gate.release(); await shutdown.value
        XCTAssertTrue(stopped); XCTAssertEqual(editing.recipe, before)
        XCTAssertFalse(editing.developmentSession.canUndo)
    }
}

actor PhotosAnalysisGate {
    private var entered = false, cancelled = false, released = false
    private let onCancellation: (@Sendable () -> Void)?
    init(onCancellation: (@Sendable () -> Void)? = nil) { self.onCancellation = onCancellation }
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        entered = true; let waiting = enteredWaiters; enteredWaiters = []; waiting.forEach { $0.resume() }
        if !released { await withCheckedContinuation { held.append($0) } }
    }
    func noteCancellation() {
        if !cancelled { onCancellation?() }
        cancelled = true; let waiting = cancelledWaiters; cancelledWaiters = []; waiting.forEach { $0.resume() }
    }
    var hasReleased: Bool { released }
    var wasCancelled: Bool { cancelled }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func waitUntilCancelled() async { if !cancelled { await withCheckedContinuation { cancelledWaiters.append($0) } } }
    func release() { released = true; let waiting = held; held = []; waiting.forEach { $0.resume() } }
}

/// Test-only scalar backend. It never invokes the real image service, runtime or paid provider.
actor PhotosDevelopmentBackend: EditingPreviewBackend {
    private(set) var opens = 0
    private(set) var userRequests: [DevelopmentAnalysisRequest] = []
    private(set) var displayRequests: [DevelopmentAnalysisRequest] = []
    private var sources: [DevelopmentPreviewSessionID: (EditingSourceSnapshot, UInt64)] = [:]
    private var gate: PhotosAnalysisGate?
    private var factsGate: PhotosAnalysisGate?
    private var displayGate: PhotosAnalysisGate?
    private(set) var factsReturned = 0
    private(set) var displayReturned = 0
    private var failsNextRender = false
    private(set) var factsRequests = 0
    private let progressSubmitted: (@Sendable (Int) -> Void)?
    private var thumbnailGate: PhotosAnalysisGate?
    private var renderGate: PhotosAnalysisGate?
    private var thumbnailFailure: DevelopmentThumbnailError = .unsupportedGraph
    private var thumbnailSubmitted: (@Sendable () -> Void)?
    private(set) var thumbnailRequests: [DevelopmentThumbnailRequest] = []
    private(set) var thumbnailJoins = 0
    private let canonicalGesture: Bool
    private(set) var renderRequests: [DevelopmentPreviewRequest] = []
    private let filtersEnabled: Bool
    private let cropAutomaticEnabled: Bool
    private var cropAutomaticNoResult: DevelopmentCropAutoNoResultV1?
    private var cropOuterMismatch = false
    private let expandedCapabilities: Bool
    private let localCapabilitiesEnabled: Bool
    private let redEyeAutomaticEnabled: Bool
    private let genericRedEyeAdvertised: Bool
    private var redEyeAutomaticNoResult: DevelopmentLocalNoResult?
    private var redEyeAutomaticFailure: DevelopmentLocalPreparationError?
    private var localOuterMismatch = false
    private let advancedDetailCapabilities: Set<DevelopmentAdjustmentID>
    private let dehazeEnabled: Bool
    private let requiresPreparedDehazeForActiveRender: Bool
    private var dehazeNoResult: DevelopmentDehazeNoResult?
    private var dehazeOuterMismatch = false
    private var localNoResult = false
    private var nextLocalFailure: DevelopmentLocalPreparationError?
    struct ProgressSubmission: Sendable { let box: ProgressPresentationBox; let request: DevelopmentPreviewRequest }
    private(set) var progressSubmissions: [ProgressSubmission] = []
    private var progressBoxes: [ProgressPresentationBox] = []
    init(gate: PhotosAnalysisGate? = nil, expandedCapabilities: Bool = false, localCapabilitiesEnabled: Bool = false,
         redEyeAutomaticEnabled: Bool = false, genericRedEyeAdvertised: Bool = false, filtersEnabled: Bool = false,
         advancedDetailCapabilities: Set<DevelopmentAdjustmentID> = [],
         dehazeEnabled: Bool = false, requiresPreparedDehazeForActiveRender: Bool = false,
         progressSubmitted: (@Sendable (Int) -> Void)? = nil, cropAutomaticEnabled: Bool = false, canonicalGesture:Bool = false) {
        self.canonicalGesture=canonicalGesture
        self.gate = gate; self.expandedCapabilities = expandedCapabilities; self.progressSubmitted = progressSubmitted
        self.filtersEnabled = filtersEnabled; self.cropAutomaticEnabled = cropAutomaticEnabled
        self.localCapabilitiesEnabled = localCapabilitiesEnabled
        self.redEyeAutomaticEnabled = redEyeAutomaticEnabled; self.genericRedEyeAdvertised = genericRedEyeAdvertised
        self.advancedDetailCapabilities = advancedDetailCapabilities
        self.dehazeEnabled = dehazeEnabled
        self.requiresPreparedDehazeForActiveRender = requiresPreparedDehazeForActiveRender
    }
    func setThumbnailGate(_ gate: PhotosAnalysisGate) { thumbnailGate = gate }
    func setRenderGate(_ gate: PhotosAnalysisGate) { renderGate = gate }
    func setThumbnailFailure(_ error: DevelopmentThumbnailError) { thumbnailFailure = error }
    func setThumbnailSubmitted(_ callback: @escaping @Sendable () -> Void) { thumbnailSubmitted = callback }
    func thumbnails(_ request: DevelopmentThumbnailRequest, progress: @escaping @Sendable (DevelopmentThumbnailProgress) -> Void) async throws -> DevelopmentThumbnailReadyLease {
        thumbnailRequests.append(request); thumbnailSubmitted?(); progress(.init(registration: request.registration, completed: 0, total: request.kind.count))
        if let thumbnailGate { await withTaskCancellationHandler(operation: { await thumbnailGate.suspend() }, onCancel: { Task { await thumbnailGate.noteCancellation() } }) }
        throw thumbnailFailure
    }
    func joinThumbnails(_ registration: DevelopmentThumbnailRegistration) async { thumbnailJoins += 1 }
    func setFactsGate(_ gate: PhotosAnalysisGate) { factsGate = gate }
    func setDisplayGate(_ gate: PhotosAnalysisGate?) { displayGate = gate }
    private func noteProgress(_ box: ProgressPresentationBox, request: DevelopmentPreviewRequest) {
        progressSubmissions.append(.init(box: box, request: request)); progressSubmitted?(progressSubmissions.count)
    }
    func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel {
        guard progressSubmitted != nil else { throw DevelopmentPreviewError.invalidRequest }
        let box = ProgressPresentationBox(lease: lease, consumer: consumer); progressBoxes.append(box)
        let channel = box.channel()
        return .init(id: channel.id, snapshots: channel.snapshots, submit: { request in
            let receipt = try channel.submit(request)
            Task { await self.noteProgress(box, request: request) }
            return receipt
        }, noteActivity: channel.noteActivity)
    }
    func closeProgressChannel(_ id: PreviewProgressChannelID) async {
        if let box = progressBoxes.first(where: { $0.id == id }) { await box.close() }
    }
    func setGate(_ gate: PhotosAnalysisGate) { self.gate = gate }
    func setLocalNoResult(_ value: Bool) { localNoResult = value }
    func failNextLocal(_ error: DevelopmentLocalPreparationError) { nextLocalFailure = error }
    func setRedEyeAutomaticNoResult(_ reason: DevelopmentLocalNoResult) { redEyeAutomaticNoResult = reason }
    func setRedEyeAutomaticFailure(_ error: DevelopmentLocalPreparationError) { redEyeAutomaticFailure = error }
    func setLocalOuterMismatch() { localOuterMismatch = true }
    func setDehazeNoResult(_ value: DevelopmentDehazeNoResult) { dehazeNoResult = value }
    func setDehazeOuterMismatch() { dehazeOuterMismatch = true }
    func setCropAutomaticNoResult(_ reason: DevelopmentCropAutoNoResultV1) { cropAutomaticNoResult = reason }
    func setCropOuterMismatch() { cropOuterMismatch = true }
    func failNextRender() { failsNextRender = true }
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease {
        guard case .raw(let snapshot) = source else { throw DevelopmentPreviewError.invalidRequest }
        opens += 1; let id = DevelopmentPreviewSessionID(), generation = UInt64(opens)
        sources[id] = (snapshot, generation)
        let identity="photos-mock-\(generation)"
        let capability=canonicalGesture ? PreviewCanonicalGestureCapability(sessionID:id,sourceGeneration:generation,
            sourceIdentity:identity,nativeSize:.init(width:120,height:80)):nil
        return .init(id:id,generation:generation,sourceIdentity:identity,canonicalGesture:capability)
    }
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap {
        renderRequests.append(request)
        if let renderGate { await withTaskCancellationHandler(operation: { await renderGate.suspend() }, onCancel: { Task { await renderGate.noteCancellation() } }) }
        if requiresPreparedDehazeForActiveRender, let detail = request.recipe.adjustmentsV3?.advancedDetail,
           detail.dehaze.enabled, detail.dehaze.amount != 0, detail.preparedDehaze == nil {
            throw DevelopmentDehazePreparationError.preparationRequired
        }
        if failsNextRender { failsNextRender = false; throw DevelopmentError.unreadable }
        let geometry = request.recipe.adjustmentsV3?.geometry ?? DevelopmentGeometryV3(version: request.recipe.schemaVersion == 2 ? .legacyV2 : .legacyV1,
            straightenDegrees: request.recipe.straightenDegrees, crop: request.recipe.crop)
        let mapped = try geometry.mapping(sourceSize: .init(width: 120, height: 80))
        let size = CGSize(width: mapped.outputSize.width, height: mapped.outputSize.height)
        return .init(id: UUID(), image: NSImage(size: size), leaseID: request.sessionID,
            generation: request.sourceGeneration, consumerID: request.consumerID, revision: request.revision,
            quality: request.quality, nativeSize: size, outputSize: size, approximate: false)
    }
    func sourceFacts(_ lease: EditingPreviewLease) async throws -> DevelopmentSourceFacts {
        factsRequests += 1
        defer { factsReturned += 1 }
        if let factsGate {
            await withTaskCancellationHandler(operation: { await factsGate.suspend() }, onCancel: { Task { await factsGate.noteCancellation() } })
        }
        guard let (source, generation) = sources[lease.id], generation == lease.generation else { throw DevelopmentPreviewError.closed }
        let binding = DevelopmentLocalEditSourceBinding(sourceContentID: source.contentSHA256, exifOrientation: 1, orientedWidth: 120, orientedHeight: 80)
        let a: Set<DevelopmentAdjustmentID> = [.light, .color, .blackAndWhite, .curves, .levels]
        let b: Set<DevelopmentAdjustmentID> = [.whiteBalance, .definition, .selectiveColor, .noiseReduction, .sharpen, .vignette]
        let neutral = DevelopmentImageWhiteBalancePickV3(baseline: .identity, sampledLinearRGB: .init(red: 0.3, green: 0.3, blue: 0.3))
        let wb: DevelopmentResolvedWhiteBalanceV3? = expandedCapabilities ? .image(source: binding,
            state: .init(temperatureTint: .init(temperature: 5000, tint: 0), gray: neutral, skin: neutral)) : nil
        return .init(sourceBinding: binding,
            sourceGeneration: generation, sourceKind: .image, decoderVersion: "test", noiseReduction: .init(sourceCapability: .image, raw: nil),
            asShotWhiteBalance: nil, implementedAdjustments: (expandedCapabilities ? a.union(b) : a).union(localCapabilitiesEnabled ? [.retouch, .redEye] : []).union(advancedDetailCapabilities).union(dehazeEnabled ? [.dehaze] : []).union(filtersEnabled ? [.filter] : []),
            automaticAdjustments: (expandedCapabilities ? a.union(b.subtracting([.selectiveColor])) : a).union(genericRedEyeAdvertised ? [.redEye] : []), initialWhiteBalanceState: wb,
            supportedGeometryVersions: [.legacyV1, .legacyV2, .adjustV3, .projectiveV3_1],
            localDecoderContractFingerprint: localCapabilitiesEnabled ? String(repeating: "d", count: 64) : nil,
            localCapabilities: localCapabilitiesEnabled ? Set<DevelopmentLocalCapability>([.manualRetouch, .automaticDonor, .manualRedEye]).union(redEyeAutomaticEnabled ? [.automaticRedEye] : []) : [],
            dehazeContextV1: dehazeEnabled ? .init(source: binding, sourceGeneration: generation, decoderContractFingerprint: String(repeating: "e", count: 64)) : nil,
            supportedPhotoFilters: filtersEnabled ? Set(DevelopmentPhotoFilterV3.allCases) : [.original],
            photoFilterResourceVersion: filtersEnabled ? "test-catalog-v1" : nil, supportsCropAutomatic: cropAutomaticEnabled)
    }
    func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult {
        let facts = try await sourceFacts(.init(id: request.preview.sessionID, generation: request.preview.sourceGeneration))
        let value: DevelopmentAnalysisValue
        if request.operation.isDisplayHistogram {
            displayRequests.append(request)
            defer { displayReturned += 1 }
            if let displayGate {
                await withTaskCancellationHandler(operation: { await displayGate.suspend() }, onCancel: { Task { await displayGate.noteCancellation() } })
            }
            value = .displayHistogram(.init(luminance: Array(repeating: 1, count: 256), visibleSamples: 256,
                transparentSamples: 0, sampledSize: .init(width: 16, height: 16)))
        } else if case .histogram = request.operation {
            value = .histogram(.init(red: Array(repeating: 1, count: 256), green: Array(repeating: 1, count: 256),
                blue: Array(repeating: 1, count: 256), luminance: Array(repeating: 1, count: 256), visibleSamples: 256,
                transparentSamples: 0, sampledSize: .init(width: 16, height: 16)))
        } else {
            userRequests.append(request)
            if let gate {
                await withTaskCancellationHandler(operation: { await gate.suspend() }, onCancel: { Task { await gate.noteCancellation() } })
            }
            if let input = request.cropAutoInputV1 {
                // Transaction fixture only; no Vision detection or image-quality claim.
                let baseline = request.preview.recipe.adjustmentsV3!.geometry
                let resolution: DevelopmentGeometryResolutionV1
                if let reason = cropAutomaticNoResult { resolution = .noResult(reason) }
                else {
                    let candidate = try DevelopmentCropGeometryAutoV1.candidate(baseline: baseline,
                        sourceSize: facts.sourceBinding.sourceSize, absoluteDegrees: 3, aspectRatio: input.aspectRatio)
                    resolution = .candidate(candidate, .init(firstDegrees: 3, secondDegrees: 3.1,
                        firstConfidence: 1, secondConfidence: 1, verificationPair: .init(positiveRoll: .init(knownRollDegrees: 3, correctionDegrees: -3, confidence: 1),
                    negativeRoll: .init(knownRollDegrees: -3, correctionDegrees: 3, confidence: 1))))
                }
                value = .geometry(.init(binding: .init(sourceContentID: facts.sourceBinding.sourceContentID,
                    sourceGeneration: request.preview.sourceGeneration, expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage),
                    source: facts.sourceBinding, presentedRecipeFingerprint: request.presentedRecipeFingerprint, input: input, resolution: resolution))
            } else if let input = request.dehazeInputV1 {
                let prepared = DevelopmentPreparedDehazeV1(sourceBinding: input.context.source, inputFingerprint: input.inputFingerprint,
                    airlight: .init(red: 0.5, green: 0.75, blue: 1), algorithmVersion: input.algorithm.rawValue)
                let resolution: DevelopmentDehazeResolutionV1 = dehazeNoResult.map { .noResult($0) } ?? .prepared(prepared)
                value = .dehaze(.init(binding: .init(sourceContentID: input.context.source.sourceContentID,
                    sourceGeneration: request.preview.sourceGeneration, expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage),
                    presentedRecipeFingerprint: request.presentedRecipeFingerprint, input: input,
                    resolution: resolution))
            } else if let input = request.localInputV1 {
                if let failure = nextLocalFailure { nextLocalFailure = nil; throw failure }
                if request.operation == .redEyeAutomatic, let redEyeAutomaticFailure { throw redEyeAutomaticFailure }
                if request.operation == .redEyeAutomatic, let detail = request.preview.recipe.adjustmentsV3?.advancedDetail,
                   detail.dehaze.enabled, detail.dehaze.amount != 0, detail.preparedDehaze == nil {
                    throw DevelopmentDehazePreparationError.preparationRequired
                }
                let operations: [DevelopmentLocalEdit]
                switch request.operation {
                case .retouchSource(let stroke, let donor):
                    operations = [.init(id: request.operationID, sourceContentID: facts.sourceBinding.sourceContentID, tool: .retouch,
                        stroke: stroke, sourceSample: donor ?? .init(x: 0.25, y: 0.3))]
                case .retouch(let stroke, let donor, let mode):
                    operations = [.init(id: request.operationID, sourceContentID: facts.sourceBinding.sourceContentID, tool: .retouch,
                        stroke: stroke, sourceSample: donor ?? .init(x: 0.25, y: 0.3), retouchMode: mode)]
                case .redEyeAt(let point, let radius, let strength):
                    operations = [.init(id: request.operationID, sourceContentID: facts.sourceBinding.sourceContentID, tool: .redEye,
                        stroke: .init(points: [.init(position: point)], radiusInShortEdge: radius, strength: strength))]
                case .redEyeAutomatic:
                    // Typed transaction fixture only: these two circles do not claim detector/pixel qualification.
                    operations = [0.35, 0.65].enumerated().map { index, x in
                        .init(id: index == 0 ? request.operationID : UUID(), sourceContentID: facts.sourceBinding.sourceContentID, tool: .redEye,
                            stroke: .init(points: [.init(position: .init(x: x, y: 0.4))], radiusInShortEdge: 0.03))
                    }
                default: throw DevelopmentPreviewError.invalidRequest
                }
                value = .local(.init(binding: .init(sourceContentID: input.source.sourceContentID,
                    sourceGeneration: request.preview.sourceGeneration, expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage),
                    presentedRecipeFingerprint: request.presentedRecipeFingerprint, input: input,
                    resolution: request.operation == .redEyeAutomatic && redEyeAutomaticNoResult != nil
                        ? .noResult(redEyeAutomaticNoResult!)
                        : (localNoResult ? .noResult(input.targetTool == .retouch ? .noUsableDonor : .noRedPixels) : .append(operations))))
            } else {
            let purpose: DevelopmentAnalysisPurpose, parameters: [DevelopmentAdjustmentParametersV3]
            switch request.operation {
            case .summary(let group, let amount): purpose = .summary(group, amount: amount); parameters = [.light(.init(enabled: true, brilliance: amount))]
            case .selectiveColorPicker(let slot, _):
                var selective=request.preview.recipe.adjustmentsV3!.selectiveColor
                for required in DevelopmentSelectiveColorSlotV3.allCases where !selective.colors.contains(where:{$0.slot == required}){selective.colors.append(.init(slot:required))}
                guard let index=selective.colors.firstIndex(where:{$0.slot == slot})else{throw DevelopmentPreviewError.invalidRequest}
                selective.enabled=true;selective.colors[index].sampledColor = .init(red:0.8,green:0.1,blue:0.1);try selective.validate()
                purpose = .selectiveColorPicker;parameters = [.selectiveColor(selective)]
            case .whiteBalanceAutomatic(let mode):
                guard let baseline = facts.initialWhiteBalanceState, case .image(let source, var state) = baseline else { throw DevelopmentPreviewError.invalidRequest }
                state.selectedMode = mode
                purpose = .automatic(.whiteBalance)
                parameters = [.whiteBalance(.init(enabled: true, resolvedState: .image(source: source, state: state)))]
            case .curvePicker(let channel, let point, _):
                var curves = request.preview.recipe.adjustmentsV3!.curves; curves.enabled = true
                if point == .addPoint {
                    var target:DevelopmentCurveChannelV3
                    switch channel {case .rgb:target=curves.rgb;case .red:target=curves.red;case .green:target=curves.green;case .blue:target=curves.blue}
                    let y=try target.curve.value(at:0.5)
                    if let added=DevelopmentCurveInteraction.adding(target.curve,x:0.5,y:y){target.curve=added.0}
                    try target.validate()
                    switch channel {case .rgb:curves.rgb=target;case .red:curves.red=target;case .green:curves.green=target;case .blue:curves.blue=target}
                } else { curves.rgb.inputBlack = 0.1 }
                purpose = .curvesPicker; parameters = [.curves(curves)]
            default: purpose = .automatic(.light); parameters = [.light(.init(enabled: true, brilliance: 0.7))]
            }
            value = .resolved(.init(binding: .init(sourceContentID: facts.sourceBinding.sourceContentID,
                sourceGeneration: request.preview.sourceGeneration, expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage),
                purpose: purpose, parameters: parameters))
            }
        }
        let deliveredRevision = (dehazeOuterMismatch && request.dehazeInputV1 != nil || localOuterMismatch && request.localInputV1 != nil || cropOuterMismatch && request.cropAutoInputV1 != nil) ?  (request.preview.revision &+ 1) : request.preview.revision
        return .init(operationID: request.operationID, sessionID: request.preview.sessionID, consumerID: request.preview.consumerID,
            revision: deliveredRevision, role: request.preview.role, quality: request.preview.quality, actualRecipe: request.preview.recipe,
            clientCorrelation: request.preview.clientCorrelation, binding: .init(sourceContentID: facts.sourceBinding.sourceContentID,
                sourceGeneration: request.preview.sourceGeneration, expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage),
            sourceBinding: facts.sourceBinding, presentedRecipeFingerprint: request.presentedRecipeFingerprint, roi: request.roi,
            samplingRecipeFingerprint: request.dehazeInputV1?.dependencyRecipeFingerprint ?? request.expectedRecipeFingerprint, samplingVersion: request.operation.isDisplayHistogram ? DevelopmentDisplayHistogramV1.samplingVersion :
                (DevelopmentNaturalCurvePickerV1.isNatural(request) ? DevelopmentNaturalCurvePickerV1.samplingVersion : "test"), geometryMapping: try request.preview.recipe.promotingToV3().adjustmentsV3!.geometry.mapping(sourceSize: facts.sourceBinding.sourceSize), value: value)
    }
    func cancel(_ consumer: PreviewConsumerID) async {}
    func close(_ lease: DevelopmentPreviewSessionID) async { sources[lease] = nil }
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { throw DevelopmentPreviewError.invalidRequest }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testScopedGradingKeepsWhitesAndNeutralLegacyReadsDoNotPromote() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let original = editing.recipe
        try editing.updateDevelopmentLegacy(context: context, control: "legacy.white.zero") { basis in
            var color = basis.color ?? .init(); color.tones.whites = 0; basis.color = color
        }
        let owner = PhotosGradingInteraction(editing: editing, context: context, region: .shadows)
        try owner.change(.init()); owner.cancel()
        try owner.begin(); try owner.change(.init()); try owner.finish()
        XCTAssertThrowsError(try owner.change(.init(hueDegrees: .nan)))
        XCTAssertEqual(editing.recipe, original); XCTAssertNil(owner.token); XCTAssertFalse(editing.developmentSession.canUndo)
        try editing.updateDevelopmentLegacy(context: context, control: "legacy.whites") { basis in
            var color = basis.color ?? .init(); color.tones.whites = 35; basis.color = color
        }
        let whiteRecipe = editing.recipe
        XCTAssertEqual(whiteRecipe.schemaVersion, 2)
        try owner.begin()
        try owner.change(.init(hueDegrees: 45, saturation: 20, luminance: 3))
        try owner.change(.init(hueDegrees: 60, saturation: 40, luminance: 6))
        try owner.finish()
        XCTAssertEqual(editing.developmentSession.history.entryCount, 2)
        XCTAssertEqual(editing.developmentLegacyBasis.color?.tones.whites, 35)
        XCTAssertEqual(editing.developmentLegacyBasis.color?.grading.shadows.saturation, 40)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, whiteRecipe)
        // A bare promotion command is intentionally a no-op in the UI transaction layer.
        // Make an actual V3 edit before asserting its legacy-basis storage path.
        try editing.developmentSession.apply(.setEnabled(.light, true), event: .init(context: context, control: .init(group: .light, name: "fixture.enable")))
        XCTAssertEqual(editing.recipe.schemaVersion, 3)
        XCTAssertEqual(try XCTUnwrap(editing.recipe.adjustmentsV3?.legacyBasis?.color).tones.whites, 35)
        try editing.updateDevelopmentLegacy(context: context, control: "legacy.whites") { basis in
            var color = basis.color ?? .init(); color.tones.whites = -20; basis.color = color
        }
        let v3White = editing.recipe
        XCTAssertEqual(v3White.adjustmentsV3?.legacyBasis?.color?.tones.whites, -20)
        try owner.begin(); try owner.change(.init(hueDegrees: 120, saturation: 30)); owner.cancel()
        XCTAssertEqual(editing.recipe, v3White)
        try editing.recipe.validate()
        await editing.shutdown()
    }
    @MainActor func testScopedGradingRegionReplacementRejectsCapturedOldCallbacksWithoutCancellingNewGesture() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let original = editing.recipe
        let control = PhotosScopedGradingControl(frame: .init(x: 0, y: 0, width: 220, height: 180))
        control.bind(editing: editing, context: context, region: .shadows, wheel: .init())
        let old = try XCTUnwrap(control.owner), oldChange = try XCTUnwrap(control.onChange), oldUndo = try XCTUnwrap(control.undoAction)
        control.beginInteraction(); oldChange(.init(hueDegrees: 45, saturation: 40))
        XCTAssertNotEqual(editing.recipe, original)
        control.bind(editing: editing, context: context, region: .highlights, wheel: .init())
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        control.beginInteraction(); control.onChange?(.init(hueDegrees: 210, saturation: 25))
        let newToken = editing.developmentSession.activeGesture, current = editing.recipe
        let oldUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .init(x: 160, y: 90),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        control.mouseUp(with: oldUp)
        oldChange(.init(hueDegrees: 90, saturation: 60)); oldUndo()
        XCTAssertThrowsError(try old.change(.init(hueDegrees: 80, saturation: 20)))
        XCTAssertEqual(editing.recipe, current); XCTAssertEqual(editing.developmentSession.activeGesture, newToken)
        control.endInteraction()
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        XCTAssertEqual(editing.developmentLegacyBasis.color?.grading.highlights.saturation, 25)
        XCTAssertEqual(editing.developmentLegacyBasis.color?.grading.shadows.saturation, 0)
        control.detach()
        await editing.shutdown()
    }
    @MainActor func testScopedGradingKeyRepeatEndsOnceAndEscapeCancelsWithCapturedDeadlineFence() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let control = PhotosScopedGradingControl(frame: .init(x: 0, y: 0, width: 220, height: 180))
        control.bind(editing: editing, context: context, region: .midtones, wheel: .init())
        func key(_ type: NSEvent.EventType, code: UInt16, repeated: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code))
        }
        control.keyDown(with: try key(.keyDown, code: 126))
        let first = try XCTUnwrap(control.keySequenceID), token = editing.developmentSession.activeGesture
        control.keyDown(with: try key(.keyDown, code: 126, repeated: true))
        XCTAssertEqual(editing.developmentSession.activeGesture, token)
        XCTAssertEqual(editing.developmentLegacyBasis.color?.grading.midtones.saturation, 2)
        control.keyUp(with: try key(.keyUp, code: 126))
        XCTAssertNil(editing.developmentSession.activeGesture); XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        let committed = editing.recipe
        control.keyDown(with: try key(.keyDown, code: 124))
        let second = try XCTUnwrap(control.keySequenceID)
        control.finishKeySequence(first)
        XCTAssertEqual(control.keySequenceID, second, "An old missing-key-up fallback cannot end the new sequence")
        control.keyDown(with: try key(.keyDown, code: 53))
        XCTAssertEqual(editing.recipe, committed); XCTAssertNil(control.keySequenceID)
        XCTAssertNil(editing.developmentSession.activeGesture); XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        control.keyDown(with: try key(.keyDown, code: 124, repeated: true))
        XCTAssertEqual(editing.recipe, committed, "A repeat after cancellation cannot re-admit a gesture")
        control.keyDown(with: try key(.keyDown, code: 124))
        control.finishKeySequence(try XCTUnwrap(control.keySequenceID))
        XCTAssertEqual(editing.developmentSession.history.entryCount, 2)
        control.detach(); await editing.shutdown()
    }
    @MainActor func testScopedGradingFocusObserverOrderViewTeardownAndBranchReplacementCancelOldScope() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(editing, asset: fixture.assets[0]); var context = try await activate(editing)
        let original = editing.recipe
        let control = PhotosScopedGradingControl(frame: .init(x: 0, y: 0, width: 220, height: 180))
        for nativeFirst in [true, false] {
            control.bind(editing: editing, context: context, region: .global, wheel: .init())
            let old = try XCTUnwrap(control.owner)
            control.beginInteraction(); control.onChange?(.init(hueDegrees: 45, saturation: 40))
            if nativeFirst { control.cancelTracking(); editing.suspendDevelopmentFocus() }
            else { editing.suspendDevelopmentFocus(); control.cancelTracking() }
            XCTAssertEqual(editing.recipe, original); XCTAssertNil(editing.developmentContext)
            XCTAssertThrowsError(try old.change(.init(hueDegrees: 90, saturation: 30)))
            context = try await activate(editing)
        }
        control.bind(editing: editing, context: context, region: .global, wheel: .init())
        control.beginInteraction(); control.onChange?(.init(hueDegrees: 45, saturation: 40))
        editing.endDevelopmentInterface()
        XCTAssertEqual(editing.recipe, original); XCTAssertNil(editing.developmentContext)
        context = try await activate(editing)
        control.bind(editing: editing, context: context, region: .global, wheel: .init())
        let old = try XCTUnwrap(control.owner)
        control.beginInteraction(); control.onChange?(.init(hueDegrees: 45, saturation: 40))
        let version = try XCTUnwrap(editing.versions.first { $0.kind == .original })
        editing.selectVersion(version, continueEditing: true)
        _ = try await activate(editing, excluding: context.draftBranchID)
        let after = editing.recipe
        XCTAssertThrowsError(try old.change(.init(hueDegrees: 90, saturation: 30)))
        XCTAssertEqual(editing.recipe, after); XCTAssertFalse(editing.developmentSession.canUndo)
        control.detach(); await editing.shutdown()
    }
    @MainActor func testPreviewRetryClearsRevokedInteractionAndRecoversSettledCropWithoutRecipeWrites() async throws {
        for endsNormally in [false, true] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend()
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            let context = try await cropReady(editing, asset: fixture.assets[0])
            let token = try editing.developmentSession.beginGesture(.init(group: nil, name: "crop.vertical"), context: context)
            var geometry = editing.developmentGeometry; geometry.verticalPerspective = 5
            if endsNormally {
                try editing.setDevelopmentGeometry(geometry, context: context, gesture: token, control: "crop.vertical")
                try editing.developmentSession.endGesture(token, .commit)
                await currentCropPreview(editing)
            }
            await backend.failNextRender()
            let failed = expectation(description: endsNormally ? "next discrete render failed after normal end" : "active gesture render failed without native end")
            var observedError = false
            let errorObserver = editing.previews.primary.$error.sink { error in
                if error != nil, !observedError { observedError = true; failed.fulfill() }
            }
            if endsNormally {
                // An identical settled request is correctly deduplicated. A real next edit
                // exercises the failure/Retry path with the previous gesture already ended.
                geometry.verticalPerspective = 6
                try editing.setDevelopmentGeometry(geometry, context: context, control: "crop.vertical")
            }
            else { try editing.setDevelopmentGeometry(geometry, context: context, gesture: token, control: "crop.vertical") }
            await fulfillment(of: [failed], timeout: 5); errorObserver.cancel()
            let beforeRetry = editing.recipe
            var writes = 0
            let recipeObserver = editing.$recipe.dropFirst().sink { _ in writes += 1 }
            let restored = expectation(description: "new retry scope")
            var newContext: EditingInteractionContext?
            let scopeObserver = editing.developmentSession.$context.sink { value in
                if let value, value != context, newContext == nil { newContext = value; restored.fulfill() }
            }
            editing.retryPreview()
            await fulfillment(of: [restored], timeout: 5); scopeObserver.cancel()
            await currentCropPreview(editing)
            let current = try XCTUnwrap(newContext)
            XCTAssertNotEqual(current.sourceGeneration, context.sourceGeneration)
            XCTAssertFalse(editing.previewInteracting)
            XCTAssertEqual(editing.previews.primary.frame?.quality, .settled)
            XCTAssertNotNil(editing.developmentCropFrame(context: current))
            XCTAssertEqual(editing.recipe, beforeRetry); XCTAssertEqual(writes, 0)
            let revision = editing.previews.primary.currentRevision
            XCTAssertThrowsError(try editing.developmentSession.endGesture(token, .commit))
            XCTAssertEqual(editing.previews.primary.currentRevision, revision, "Old end cannot submit another preview")
            XCTAssertEqual(editing.recipe, beforeRetry)
            recipeObserver.cancel()
            editing.undoDevelopment(context: current)
            await currentCropPreview(editing)
            XCTAssertNotNil(editing.developmentCropFrame(context: current))
            await editing.shutdown()
        }
    }
    @MainActor private func cropReady(_ editing: EditingController, asset: AssetRecord) async throws -> EditingInteractionContext {
        try await ready(editing, asset: asset)
        let first = try await activate(editing)
        editing.changeDevelopmentPage(.crop, context: first)
        let context = try XCTUnwrap(editing.developmentContext)
        await currentCropPreview(editing)
        XCTAssertNotNil(editing.developmentCropFrame(context: context))
        return context
    }
    @MainActor private func currentCropPreview(_ editing: EditingController) async {
        if editing.previews.primary.frame?.revision == editing.previews.primary.currentRevision { return }
        let completed = expectation(description: "current crop identity preview delivered")
        var delivered = false
        let observer = editing.previews.primary.$frame.sink { frame in
            if frame?.revision == editing.previews.primary.currentRevision, !delivered { delivered = true; completed.fulfill() }
        }
        await fulfillment(of: [completed], timeout: 5); observer.cancel()
    }
    @MainActor private func cropViewport(_ frame: EditingDevelopmentCropFrame) -> ImageCanvasViewportSnapshot {
        let size = CGSize(width: 640, height: 480)
        return .init(frameID: frame.frameID, viewportSize: size, imagePixelSize: frame.outputPixelSize,
            imageRect: ImageViewportGeometry.imageRect(pixelSize: frame.outputPixelSize, viewport: size, transform: .init(), backingScale: 2),
            backingScale: 2, transform: .init())
    }
    private func cropEvent(_ phase: ImageCanvasPointerPhase, id: UUID, began: UUID,
                           viewport: ImageCanvasViewportSnapshot, point: CGPoint,
                           modifiers: UInt64 = 0) -> ImageCanvasPointerEvent {
        .init(phase: phase, gestureID: id, beganFrameID: began, viewport: viewport, locationInView: point,
            pressure: 1, supportsPressure: false, modifiersRawValue: modifiers, eventTimestamp: 123)
    }
    @MainActor func testManualCropReadsDoNotPromoteAndLockedAngleDragNeverAccumulatesShrink() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend()
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        let context = try await cropReady(editing, asset: fixture.assets[0])
        let original = editing.recipe
        XCTAssertEqual(original.schemaVersion, 1); XCTAssertFalse(editing.developmentSession.canUndo)
        _ = try editing.developmentCropPlane(context: context)
        XCTAssertEqual(editing.recipe, original)
        let lock = PhotosCropConstraint(aspect: .wide)
        try editing.setDevelopmentCropConstraint(lock, context: context)
        let beforeDrag = editing.recipe
        let token = try editing.developmentSession.beginGesture(.init(group: nil, name: "crop.straighten"), context: context)
        var first: NormalizedCrop?
        for angle in [8.0, 19.0, 8.0] {
            var geometry = editing.developmentGeometry; geometry.straightenDegrees = angle
            try editing.setDevelopmentGeometry(geometry, context: context, gesture: token, control: "crop.straighten")
            if first == nil { first = editing.developmentGeometry.crop }
        }
        XCTAssertEqual(editing.developmentGeometry.crop, first)
        let plane = try editing.developmentCropPlane(context: context)
        let crop = editing.developmentGeometry.crop
        XCTAssertEqual(crop.width * plane.rect.width / (crop.height * plane.rect.height), 16.0 / 9, accuracy: 1e-12)
        try editing.developmentSession.endGesture(token, .commit)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 2, "Preset plus the entire angle gesture")
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, beforeDrag)
        var perspective = editing.developmentGeometry; perspective.verticalPerspective = 11
        try editing.setDevelopmentGeometry(perspective, context: context, control: "crop.vertical")
        XCTAssertEqual(editing.developmentGeometry.version, .projectiveV3_1)
        let beforeTurn = editing.recipe
        try editing.rotateDevelopmentCrop(context: context)
        XCTAssertEqual(editing.developmentGeometry.lateOrientation.orientation, .rotate90)
        XCTAssertEqual(editing.developmentGeometry.clockwiseQuarterTurns, perspective.clockwiseQuarterTurns)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, beforeTurn)
        try editing.flipDevelopmentCrop(vertical: false, context: context)
        XCTAssertEqual(editing.developmentGeometry.lateOrientation.orientation, .flipHorizontal)
        XCTAssertEqual(editing.developmentGeometry.flipHorizontal, perspective.flipHorizontal)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, beforeTurn)
        try editing.resetDevelopmentCrop(context: context)
        XCTAssertEqual(editing.developmentGeometry, DevelopmentGeometryV3())
        await editing.shutdown()
    }
    @MainActor func testClockwiseCropRotationWithSingleAxisFlipPreservesMappedSourcePoints() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        let context = try await cropReady(editing, asset: fixture.assets[0])
        let sourceSize = try XCTUnwrap(editing.developmentSession.source).sourceSize
        for quarter in 0..<4 {
            for horizontal in [true, false] {
                // Binary fractions make all crop edges integral on the actual 120x80 source,
                // isolating direction/source preservation from independent inward rounding.
                let before = DevelopmentGeometryV3(crop: .init(x: 0.125, y: 0.25, width: 0.5, height: 0.375),
                    clockwiseQuarterTurns: quarter, flipHorizontal: horizontal, flipVertical: !horizontal)
                try editing.setDevelopmentGeometry(before, context: context)
                let originalRecipe = editing.recipe, beforeMapping = try before.mapping(sourceSize: sourceSize)
                try editing.rotateDevelopmentCrop(context: context)
                let afterMapping = try editing.developmentGeometry.mapping(sourceSize: sourceSize)
                XCTAssertEqual(afterMapping.outputSize.width, beforeMapping.outputSize.height)
                XCTAssertEqual(afterMapping.outputSize.height, beforeMapping.outputSize.width)
                for output in [DevelopmentSourcePoint(x: 0, y: 0), .init(x: 1, y: 1),
                               .init(x: 0.2, y: 0.3), .init(x: 0.7, y: 0.8)] {
                    let source = try beforeMapping.sourcePoint(fromOutput: output)
                    let rotated = try XCTUnwrap(afterMapping.outputPoint(fromSource: source))
                    // Clockwise in the displayed top-left coordinate system, for both flip axes.
                    XCTAssertEqual(rotated.x, 1 - output.y, accuracy: 1e-12)
                    XCTAssertEqual(rotated.y, output.x, accuracy: 1e-12)
                    let restoredSource = try afterMapping.sourcePoint(fromOutput: .init(x: 1 - output.y, y: output.x))
                    XCTAssertEqual(restoredSource.x, source.x, accuracy: 1e-12)
                    XCTAssertEqual(restoredSource.y, source.y, accuracy: 1e-12)
                }
                editing.undoDevelopment(context: context)
                XCTAssertEqual(editing.recipe, originalRecipe, "The rotation is one undoable transaction")
            }
        }
        await editing.shutdown()
    }
    @MainActor func testLateCropCommandsPreserveProjectedSourcePointsAndAllPreGeometry() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        let context = try await cropReady(editing, asset: fixture.assets[0])
        let sourceSize = try XCTUnwrap(editing.developmentSession.source).sourceSize
        for quarter in 0..<4 {
            for horizontal in [true, false] {
                for projected in [false, true] {
                    for operation in [DevelopmentLateOperationV3.rotateClockwise, .flipHorizontal, .flipVertical] {
                        var before = DevelopmentGeometryV3(version: .projectiveV3_1, straightenDegrees: 13,
                            verticalPerspective: projected ? 7 : 0, horizontalPerspective: projected ? -9 : 0,
                            crop: .init(x: 0.13, y: 0.21, width: 0.57, height: 0.49),
                            clockwiseQuarterTurns: quarter, flipHorizontal: horizontal, flipVertical: !horizontal)
                        // Exercise composition after a pre-existing late operation as well as identity.
                        if quarter % 2 == 1 { before = try before.applyingLateOperation(.flipHorizontal) }
                        try editing.setDevelopmentGeometry(before, context: context)
                        let original = editing.recipe, beforeMap = try before.mapping(sourceSize: sourceSize)
                        switch operation {
                        case .rotateClockwise: try editing.rotateDevelopmentCrop(context: context)
                        case .flipHorizontal: try editing.flipDevelopmentCrop(vertical: false, context: context)
                        case .flipVertical: try editing.flipDevelopmentCrop(vertical: true, context: context)
                        }
                        let after = editing.developmentGeometry, afterMap = try after.mapping(sourceSize: sourceSize)
                        XCTAssertEqual(after.clockwiseQuarterTurns, before.clockwiseQuarterTurns)
                        XCTAssertEqual(after.flipHorizontal, before.flipHorizontal); XCTAssertEqual(after.flipVertical, before.flipVertical)
                        XCTAssertEqual(after.straightenDegrees, before.straightenDegrees)
                        XCTAssertEqual(after.verticalPerspective, before.verticalPerspective)
                        XCTAssertEqual(after.horizontalPerspective, before.horizontalPerspective)
                        for point in [DevelopmentSourcePoint(x: 0.2, y: 0.3), .init(x: 0.7, y: 0.8)] {
                            let oldPlanePoint = DevelopmentSourcePoint(
                                x: (before.crop.x + before.crop.width * point.x) * beforeMap.cropPlane.rect.width,
                                y: (before.crop.y + before.crop.height * point.y) * beforeMap.cropPlane.rect.height)
                            let sourcePixels = cropMatrixPoint(beforeMap.cropPlane.inverseMatrix, oldPlanePoint)
                            let source = DevelopmentSourcePoint(x: sourcePixels.x / Double(sourceSize.width), y: sourcePixels.y / Double(sourceSize.height))
                            let expected: DevelopmentSourcePoint
                            switch operation {
                            case .rotateClockwise: expected = .init(x: beforeMap.cropPlane.rect.height - oldPlanePoint.y, y: oldPlanePoint.x)
                            case .flipHorizontal: expected = .init(x: beforeMap.cropPlane.rect.width - oldPlanePoint.x, y: oldPlanePoint.y)
                            case .flipVertical: expected = .init(x: oldPlanePoint.x, y: beforeMap.cropPlane.rect.height - oldPlanePoint.y)
                            }
                            let actual = cropMatrixPoint(afterMap.cropPlane.forwardMatrix, sourcePixels)
                            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9); XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9)
                            let output = try XCTUnwrap(afterMap.outputPoint(fromSource: source))
                            // Final inward raster origin comes from Core, not an assumed exact
                            // rotation of an already-rounded bitmap (fractional P/trim plane).
                            XCTAssertEqual(output.x, (expected.x - afterMap.cropPlane.actualRasterRect.x) / Double(afterMap.outputSize.width), accuracy: 1e-10)
                            XCTAssertEqual(output.y, (expected.y - afterMap.cropPlane.actualRasterRect.y) / Double(afterMap.outputSize.height), accuracy: 1e-10)
                            let restored = try afterMap.sourcePoint(fromOutput: output)
                            XCTAssertEqual(restored.x, source.x, accuracy: 1e-10); XCTAssertEqual(restored.y, source.y, accuracy: 1e-10)
                        }
                        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
                    }
                }
            }
        }
        await editing.shutdown()
    }
    private func cropMatrixPoint(_ matrix: [Double], _ point: DevelopmentSourcePoint) -> DevelopmentSourcePoint {
        let denominator = matrix[6] * point.x + matrix[7] * point.y + matrix[8]
        return .init(x: (matrix[0] * point.x + matrix[1] * point.y + matrix[2]) / denominator,
                     y: (matrix[3] * point.x + matrix[4] * point.y + matrix[5]) / denominator)
    }
    @MainActor func testLateRotationRejectsOldFrameMouseUpAndReflectedStraightenKeepsDisplayDirection() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        let context = try await cropReady(editing, asset: fixture.assets[0])
        let geometry = DevelopmentGeometryV3(version: .projectiveV3_1, straightenDegrees: 11, verticalPerspective: 7,
            horizontalPerspective: -8, crop: .init(x: 0.13, y: 0.21, width: 0.57, height: 0.49), flipHorizontal: true)
        try editing.setDevelopmentGeometry(geometry, context: context)
        await currentCropPreview(editing)
        let frame = try XCTUnwrap(editing.developmentCropFrame(context: context)), viewport = cropViewport(frame)
        let rect = PhotosCropInteraction.screenRect(geometry.crop, imageRect: viewport.imageRect, plane: frame.plane)
        let tracker = PhotosCropTrackingController(editing: editing, context: context), id = UUID()
        let start = CGPoint(x: rect.minX, y: rect.midY)
        XCTAssertTrue(tracker.pointer(cropEvent(.began, id: id, began: frame.frameID, viewport: viewport, point: start)))
        let beforeRotate = editing.recipe
        try editing.rotateDevelopmentCrop(context: context)
        let rotated = editing.recipe
        await currentCropPreview(editing)
        XCTAssertNotEqual(editing.previews.primary.frame?.id, frame.frameID)
        XCTAssertFalse(tracker.pointer(cropEvent(.ended, id: id, began: frame.frameID, viewport: viewport, point: start)))
        XCTAssertEqual(editing.recipe, rotated)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, beforeRotate)

        for reflected in [false, true] {
            var before = DevelopmentGeometryV3()
            if reflected { before = try before.applyingLateOperation(.flipHorizontal) }
            try editing.setDevelopmentGeometry(before, context: context)
            await currentCropPreview(editing)
            let frame = try XCTUnwrap(editing.developmentCropFrame(context: context)), viewport = cropViewport(frame)
            let tracker = PhotosCropTrackingController(editing: editing, context: context), id = UUID()
            let start = CGPoint(x: viewport.imageRect.maxX + 14, y: viewport.imageRect.minY - 14)
            let end = CGPoint(x: start.x + 35, y: start.y + 8)
            let center = CGPoint(x: viewport.imageRect.midX, y: viewport.imageRect.midY)
            let delta = (atan2(end.y - center.y, end.x - center.x) - atan2(start.y - center.y, start.x - center.x)) * 180 / .pi
            XCTAssertTrue(tracker.pointer(cropEvent(.began, id: id, began: frame.frameID, viewport: viewport, point: start)))
            XCTAssertTrue(tracker.pointer(cropEvent(.ended, id: id, began: frame.frameID, viewport: viewport, point: end)))
            XCTAssertEqual(editing.developmentGeometry.straightenDegrees, reflected ? delta : -delta, accuracy: 1e-10)
            editing.undoDevelopment(context: context); XCTAssertEqual(editing.developmentGeometry, before)
        }
        await editing.shutdown()
    }
    @MainActor func testCropShiftRotationSnapsToFifteenDegrees() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        let context = try await cropReady(editing, asset: fixture.assets[0])
        let frame = try XCTUnwrap(editing.developmentCropFrame(context: context)), viewport = cropViewport(frame)
        let tracker = PhotosCropTrackingController(editing: editing, context: context), id = UUID()
        let start = CGPoint(x: viewport.imageRect.maxX + 14, y: viewport.imageRect.minY - 14)
        let end = CGPoint(x: start.x + 35, y: start.y + 8)
        let center = CGPoint(x: viewport.imageRect.midX, y: viewport.imageRect.midY)
        let delta = (atan2(end.y - center.y, end.x - center.x) - atan2(start.y - center.y, start.x - center.x)) * 180 / .pi
        XCTAssertTrue(tracker.pointer(cropEvent(.began, id: id, began: frame.frameID, viewport: viewport, point: start)))
        XCTAssertTrue(tracker.pointer(cropEvent(.ended, id: id, began: frame.frameID, viewport: viewport, point: end,
            modifiers: UInt64(NSEvent.ModifierFlags.shift.rawValue))))
        XCTAssertEqual(editing.developmentGeometry.straightenDegrees, (-delta / 15).rounded() * 15, accuracy: 1e-10)
        await editing.shutdown()
    }

    @MainActor func testCropNativePointerUsesContinuousPlaneOneUndoAndViewportCancelCannotCommit() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        let context = try await cropReady(editing, asset: fixture.assets[0])
        let frame = try XCTUnwrap(editing.developmentCropFrame(context: context)), viewport = cropViewport(frame)
        let tracker = PhotosCropTrackingController(editing: editing, context: context), original = editing.recipe
        let start = CGPoint(x: viewport.imageRect.minX, y: viewport.imageRect.midY), moved = CGPoint(x: start.x + 50, y: start.y)
        tracker.hover(.init(viewport: viewport, locationInView: start, modifiersRawValue: 0))
        XCTAssertEqual(tracker.hoveredHandle, .left)
        tracker.hover(.init(viewport: viewport, locationInView: .init(x: viewport.imageRect.minX - 14,
            y: viewport.imageRect.minY - 14), modifiersRawValue: 0))
        XCTAssertEqual(tracker.hoveredHandle, .straighten)
        tracker.hover(.init(viewport: viewport, locationInView: nil, modifiersRawValue: 0))
        XCTAssertNil(tracker.hoveredHandle)
        let id = UUID()
        XCTAssertTrue(tracker.pointer(cropEvent(.began, id: id, began: frame.frameID, viewport: viewport, point: start)))
        XCTAssertTrue(tracker.pointer(cropEvent(.changed, id: id, began: frame.frameID, viewport: viewport, point: moved)))
        XCTAssertGreaterThan(editing.developmentGeometry.crop.x, 0)
        tracker.updateViewport(.init(frameID: frame.frameID, viewportSize: .init(width: 800, height: 480), imagePixelSize: viewport.imagePixelSize,
            imageRect: viewport.imageRect, backingScale: 2, transform: .init()))
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        XCTAssertFalse(tracker.pointer(cropEvent(.ended, id: id, began: frame.frameID, viewport: viewport, point: moved)))
        let second = UUID()
        XCTAssertTrue(tracker.pointer(cropEvent(.began, id: second, began: frame.frameID, viewport: viewport, point: start)))
        XCTAssertTrue(tracker.pointer(cropEvent(.changed, id: second, began: frame.frameID, viewport: viewport, point: moved)))
        XCTAssertTrue(tracker.pointer(cropEvent(.ended, id: second, began: frame.frameID, viewport: viewport, point: moved)))
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        await editing.shutdown()
    }
    @MainActor func testStraightenPointerContinuesAcrossItsOwnFrameAndRejectsOldBranchMouseUp() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        let context = try await cropReady(editing, asset: fixture.assets[0])
        let frame = try XCTUnwrap(editing.developmentCropFrame(context: context)), viewport = cropViewport(frame)
        let tracker = PhotosCropTrackingController(editing: editing, context: context), original = editing.recipe
        let start = CGPoint(x: viewport.imageRect.maxX + 14, y: viewport.imageRect.minY - 14)
        let changed = CGPoint(x: start.x + 35, y: start.y + 8), ended = CGPoint(x: start.x + 55, y: start.y + 15)
        let id = UUID()
        XCTAssertTrue(tracker.pointer(cropEvent(.began, id: id, began: frame.frameID, viewport: viewport, point: start)))
        XCTAssertTrue(tracker.pointer(cropEvent(.changed, id: id, began: frame.frameID, viewport: viewport, point: changed)))
        await currentCropPreview(editing)
        let newer = try XCTUnwrap(editing.previews.primary.frame)
        XCTAssertNotEqual(newer.id, frame.frameID)
        let newViewport = ImageCanvasViewportSnapshot(frameID: newer.id, viewportSize: viewport.viewportSize, imagePixelSize: newer.outputSize,
            imageRect: ImageViewportGeometry.imageRect(pixelSize: newer.outputSize, viewport: viewport.viewportSize, transform: .init(), backingScale: 2), backingScale: 2, transform: .init())
        tracker.updateViewport(newViewport)
        let duringRotation = try XCTUnwrap(tracker.overlayPresentation(),
            "The grid and crop boundary must remain visible while a rotated frame is in flight")
        XCTAssertEqual(duringRotation.frame.frameID, frame.frameID)
        XCTAssertEqual(duringRotation.viewport, viewport)
        XCTAssertTrue(tracker.pointer(cropEvent(.ended, id: id, began: frame.frameID, viewport: newViewport, point: ended)))
        XCTAssertNotNil(tracker.overlayPresentation(), "The overlay also survives the post-drag settling render")
        await currentCropPreview(editing)
        let settled = try XCTUnwrap(editing.previews.primary.frame)
        let settledViewport = ImageCanvasViewportSnapshot(frameID: settled.id, viewportSize: viewport.viewportSize,
            imagePixelSize: settled.outputSize, imageRect: ImageViewportGeometry.imageRect(pixelSize: settled.outputSize,
                viewport: viewport.viewportSize, transform: .init(), backingScale: 2), backingScale: 2, transform: .init())
        tracker.updateViewport(settledViewport)
        XCTAssertEqual(tracker.overlayPresentation()?.frame.frameID, settled.id,
            "Once rotation settles, the overlay returns to the current frame")
        XCTAssertNotEqual(editing.developmentGeometry.straightenDegrees, 0)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        await currentCropPreview(editing)
        let version = try XCTUnwrap(editing.versions.first { $0.kind == .original })
        let current = try XCTUnwrap(editing.developmentCropFrame(context: context)), currentViewport = cropViewport(current)
        let late = UUID(), handlePoint = CGPoint(x: currentViewport.imageRect.minX, y: currentViewport.imageRect.midY)
        XCTAssertTrue(tracker.pointer(cropEvent(.began, id: late, began: current.frameID, viewport: currentViewport, point: handlePoint)))
        editing.selectVersion(version, continueEditing: true)
        _ = try await activate(editing, excluding: context.draftBranchID)
        let after = editing.recipe
        XCTAssertFalse(tracker.pointer(cropEvent(.ended, id: late, began: current.frameID, viewport: currentViewport, point: ended)))
        XCTAssertEqual(editing.recipe, after); XCTAssertFalse(editing.developmentSession.canUndo)
        await editing.shutdown()
    }
    @MainActor func testCropFocusAndNativeResignObserversCancelDeterministicallyInEitherOrder() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        var context = try await cropReady(editing, asset: fixture.assets[0])
        let original = editing.recipe
        for nativeFirst in [true, false] {
            let frame = try XCTUnwrap(editing.developmentCropFrame(context: context)), viewport = cropViewport(frame)
            let tracker = PhotosCropTrackingController(editing: editing, context: context), id = UUID()
            let start = CGPoint(x: viewport.imageRect.minX, y: viewport.imageRect.midY), moved = CGPoint(x: start.x + 40, y: start.y)
            XCTAssertTrue(tracker.pointer(cropEvent(.began, id: id, began: frame.frameID, viewport: viewport, point: start)))
            XCTAssertTrue(tracker.pointer(cropEvent(.changed, id: id, began: frame.frameID, viewport: viewport, point: moved)))
            XCTAssertNotEqual(editing.recipe, original)
            if nativeFirst { tracker.cancel(); editing.suspendDevelopmentFocus() }
            else { editing.suspendDevelopmentFocus(); tracker.cancel() }
            XCTAssertEqual(editing.recipe, original)
            XCTAssertNil(editing.developmentContext); XCTAssertNil(editing.developmentSession.activeGesture)
            XCTAssertEqual(editing.developmentSession.history.entryCount, 0)
            XCTAssertFalse(tracker.pointer(cropEvent(.ended, id: id, began: frame.frameID, viewport: viewport, point: moved)))
            context = try await activate(editing)
            await currentCropPreview(editing)
            XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        }
        await editing.shutdown()
    }
    @MainActor func testOriginalHoldCancelsCropGestureAndAnalysisErrorsGiveActionableCopy() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        let context = try await cropReady(editing, asset: fixture.assets[0]), original = editing.recipe
        let token = try editing.developmentSession.beginGesture(.init(group: nil, name: "crop"), context: context)
        var geometry = editing.developmentGeometry; geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        try editing.setDevelopmentGeometry(geometry, context: context, gesture: token)
        editing.setDevelopmentOriginalHeld(true)
        XCTAssertEqual(editing.recipe, original); XCTAssertNil(editing.developmentSession.activeGesture)
        XCTAssertThrowsError(try editing.developmentSession.endGesture(token, .commit))
        let skin = editing.developmentAnalysisFailureMessage(DevelopmentAnalysisError.noVisibleSamples,
            operation: .whiteBalancePicker(sourcePoint: .init(x: 0.5, y: 0.5), mode: .skinTone(warmth: 0)), title: "白平衡取样")
        let gray = editing.developmentAnalysisFailureMessage(DevelopmentAnalysisError.noVisibleSamples,
            operation: .whiteBalancePicker(sourcePoint: .init(x: 0.5, y: 0.5), mode: .neutralGray(warmth: 0)), title: "白平衡取样")
        XCTAssertTrue(skin.contains("清晰的肤色")); XCTAssertTrue(gray.contains("灰色或白色")); XCTAssertNotEqual(skin, gray)
        let unsupported = editing.developmentAnalysisFailureMessage(DevelopmentV3Error.unsupportedNativeParameters, operation: .automatic(.noiseReduction), title: "降噪")
        XCTAssertFalse(unsupported.contains("RAWMasterImaging")); XCTAssertFalse(unsupported.contains("错误0"))
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor private func localFrame(_ editing: EditingController, context: EditingInteractionContext) async throws -> (EditingDevelopmentLocalFrame, ImageCanvasViewportSnapshot) {
        await settled(editing)
        let bitmap = try XCTUnwrap(editing.previews.primary.frame)
        editing.developmentLocalInput.frameWasDrawn(.init(frameID: bitmap.id, drawBeganUptimeNanoseconds: 1,
            drawReturnedUptimeNanoseconds: 2, imagePixelWidth: Int(bitmap.outputSize.width), imagePixelHeight: Int(bitmap.outputSize.height)))
        let frame = try XCTUnwrap(editing.developmentLocalFrame(context: context))
        let viewport = ImageCanvasViewportSnapshot(frameID: bitmap.id, viewportSize: .init(width: 640, height: 480), imagePixelSize: bitmap.outputSize,
            imageRect: ImageViewportGeometry.imageRect(pixelSize: bitmap.outputSize, viewport: .init(width: 640, height: 480), transform: .init(), backingScale: 2),
            backingScale: 2, transform: .init())
        editing.developmentLocalInput.updateViewport(viewport, context: context)
        return (frame, viewport)
    }
    private func localEvent(_ phase: ImageCanvasPointerPhase, id: UUID, frame: EditingDevelopmentLocalFrame,
                            viewport: ImageCanvasViewportSnapshot, source: DevelopmentSourcePoint,
                            option: Bool = false, tablet: Bool = false, pressure: Double = 0) throws -> ImageCanvasPointerEvent {
        let output = try XCTUnwrap(try frame.mapping.outputPoint(fromSource: source))
        return .init(phase: phase, gestureID: id, beganFrameID: frame.frameID, viewport: viewport,
            locationInView: .init(x: viewport.imageRect.minX + output.x * viewport.imageRect.width,
                                  y: viewport.imageRect.minY + output.y * viewport.imageRect.height),
            pressure: pressure, supportsPressure: tablet, modifiersRawValue: option ? UInt64(NSEvent.ModifierFlags.option.rawValue) : 0, eventTimestamp: 1)
    }
    @MainActor private func localFinished(_ editing: EditingController) async {
        if !editing.developmentAnalysisBusy { return }
        let finished = expectation(description: "local owned analysis completed")
        var delivered = false
        let observer = editing.$developmentAnalysisBusy.sink { busy in
            if !busy, !delivered { delivered = true; finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 5); observer.cancel()
    }
    @MainActor func testRepairDraftRetriesAndPublishesOneUndoableChange() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        addTeardownBlock { await editing.shutdown() }
        try await ready(editing, asset: fixture.assets[0])
        let context = try await activate(editing), original = editing.recipe
        let session = editing.developmentSession
        editing.setComparisonMode(.wipeHorizontal)
        let compare = editing.comparison
        editing.toggleDevelopmentRepair()
        editing.completeDevelopmentRepair()
        XCTAssertEqual(editing.recipe, original)
        XCTAssertEqual(session.history.entryCount, 0)
        XCTAssertEqual(editing.comparison, compare)
        editing.toggleDevelopmentRepair()
        XCTAssertTrue(editing.repairEditing)
        XCTAssertFalse(editing.comparing)
        editing.developmentLocalInput.setSize(3)

        func addStroke(at point: DevelopmentSourcePoint) async throws -> UUID {
            let (frame, viewport) = try await localFrame(editing, context: context), id = UUID()
            let input = editing.developmentLocalInput
            XCTAssertTrue(input.pointer(try localEvent(.began, id: id, frame: frame, viewport: viewport, source: point), context: context))
            XCTAssertTrue(input.pointer(try localEvent(.ended, id: id, frame: frame, viewport: viewport, source: point), context: context))
            return id
        }
        let first = try await addStroke(at: .init(x: 0.58, y: 0.55))
        await localFinished(editing)
        XCTAssertEqual(session.parameters.localEdits.operations.map(\.id), [first])
        XCTAssertEqual(editing.recipe, original)
        XCTAssertEqual(session.history.entryCount, 0)
        XCTAssertFalse(editing.isDirty)
        editing.openExport()
        XCTAssertFalse(editing.showExport, "A pending tool cannot publish the committed or staged recipe from the current edit entry")
        await backend.failNextLocal(.staleInput)
        _ = try await addStroke(at: .init(x: 0.61, y: 0.58))
        await localFinished(editing)
        XCTAssertNotNil(editing.repairFailure)
        XCTAssertNotNil(editing.repairCompletionReason)
        XCTAssertEqual(session.parameters.localEdits.operations.count, 1)
        editing.retryDevelopmentRepair()
        await localFinished(editing)
        let expected = session.parameters.localEdits.operations
        XCTAssertEqual(expected.count, 2)
        let requests = await backend.userRequests
        XCTAssertEqual(requests.suffix(3).compactMap { $0.localInputV1?.prefixCount }, [0, 1, 1])
        XCTAssertNil(editing.repairFailure)
        editing.undoDevelopment(context: context); XCTAssertEqual(session.parameters.localEdits.operations.count, 1)
        editing.undoDevelopment(context: context, redo: true); XCTAssertEqual(session.parameters.localEdits.operations, expected)
        XCTAssertEqual(editing.recipe, original)

        editing.completeDevelopmentRepair()
        XCTAssertFalse(editing.repairEditing)
        XCTAssertNil(editing.developmentLocalInput.tool)
        XCTAssertEqual(editing.comparison, compare)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.localEdits.operations, expected)
        XCTAssertEqual(session.history.entryCount, 1)
        XCTAssertEqual(session.undoTitle, "完成修复")
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        editing.undoDevelopment(context: context, redo: true)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.localEdits.operations, expected)

        editing.toggleDevelopmentRepair()
        editing.removeDevelopmentLocalOperation(first, context: context)
        XCTAssertEqual(session.parameters.localEdits.operations.count, 1)
        editing.suspendDevelopmentFocus()
        XCTAssertTrue(editing.repairEditing, "A focus change keeps the tool draft")
        editing.beginDevelopmentInterface()
        let gate = PhotosAnalysisGate(); await backend.setGate(gate)
        _ = try await addStroke(at: .init(x: 0.65, y: 0.58))
        await gate.waitUntilEntered()
        editing.cancelDevelopmentRepair()
        await gate.waitUntilCancelled(); await gate.release(); await localFinished(editing)
        XCTAssertFalse(editing.repairEditing)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.localEdits.operations, expected)
        XCTAssertEqual(session.history.entryCount, 1)
        XCTAssertNil(editing.repairFailure)
    }
    @MainActor func testLocalRetouchUsesActualProjectedSourceDonorAndOneAtomicHistoryEntry() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        var geometry = DevelopmentGeometryV3(version: .projectiveV3_1, straightenDegrees: 7, verticalPerspective: 5,
            horizontalPerspective: -4, crop: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8), flipHorizontal: true)
        geometry = try geometry.applyingLateOperation(.rotateClockwise)
        try editing.setDevelopmentGeometry(geometry, context: context)
        editing.selectDevelopmentLocalTool(.retouch, context: context)
        let input = editing.developmentLocalInput; input.setSize(3)
        let (frame, viewport) = try await localFrame(editing, context: context)
        let original = editing.recipe, entries = editing.developmentSession.history.entryCount
        let donor = DevelopmentSourcePoint(x: 0.35, y: 0.4), selectID = UUID()
        XCTAssertTrue(input.pointer(try localEvent(.began, id: selectID, frame: frame, viewport: viewport, source: donor, option: true), context: context))
        XCTAssertTrue(input.pointer(try localEvent(.ended, id: selectID, frame: frame, viewport: viewport, source: donor, option: true), context: context))
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentAnalysisBusy)
        let strokeID = UUID(), first = DevelopmentSourcePoint(x: 0.52, y: 0.52), last = DevelopmentSourcePoint(x: 0.58, y: 0.55)
        XCTAssertTrue(input.pointer(try localEvent(.began, id: strokeID, frame: frame, viewport: viewport, source: first), context: context))
        XCTAssertTrue(input.pointer(try localEvent(.changed, id: strokeID, frame: frame, viewport: viewport, source: .init(x: 0.56, y: 0.54)), context: context))
        XCTAssertTrue(input.pointer(try localEvent(.ended, id: strokeID, frame: frame, viewport: viewport, source: last), context: context))
        await localFinished(editing)
        let operation = try XCTUnwrap(editing.recipe.adjustmentsV3?.localEdits.operations.first)
        XCTAssertEqual(operation.id, strokeID)
        XCTAssertEqual(operation.tool, .retouch); XCTAssertEqual(operation.stroke.points.count, 3)
        XCTAssertEqual(operation.sourceSample!.x, donor.x, accuracy: 1e-10); XCTAssertEqual(operation.sourceSample!.y, donor.y, accuracy: 1e-10)
        XCTAssertEqual(operation.stroke.points.first!.position.x, first.x, accuracy: 1e-10)
        XCTAssertEqual(operation.stroke.points.last!.position.y, last.y, accuracy: 1e-10)
        XCTAssertTrue(operation.stroke.points.allSatisfy { $0.pressure == 1 }, "Ordinary mouse pressure zero is not zero strength")
        XCTAssertEqual(operation.stroke.radiusInShortEdge, 3.0 / 80)
        XCTAssertEqual(editing.developmentSession.history.entryCount, entries + 1)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.localEdits.sourceBinding, frame.source)
        XCTAssertNil(input.donor, "Donor admission is invalidated when its ordered recipe prefix changes")
        let recordedRequests = await backend.userRequests
        let request = try XCTUnwrap(recordedRequests.last)
        XCTAssertEqual(request.localInputV1?.targetTool, .retouch)
        XCTAssertEqual(request.presentedRecipeFingerprint, try EditingFingerprint.of(original))
        XCTAssertEqual(request.expectedRecipeFingerprint, try EditingFingerprint.of(original.promotingToV3()))
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        await editing.shutdown()
    }
    @MainActor func testLocalNoResultDoesNotPromoteAndRedEyeAutomaticDonorOrderedEditsDeleteResetReplay() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let original = editing.recipe
        await backend.setLocalNoResult(true)
        editing.selectDevelopmentLocalTool(.retouch, context: context)
        let input = editing.developmentLocalInput; input.setSize(3)
        var (frame, viewport) = try await localFrame(editing, context: context)
        func click(_ point: DevelopmentSourcePoint) throws {
            let id = UUID()
            XCTAssertTrue(input.pointer(try localEvent(.began, id: id, frame: frame, viewport: viewport, source: point), context: context))
            XCTAssertTrue(input.pointer(try localEvent(.ended, id: id, frame: frame, viewport: viewport, source: point), context: context))
        }
        try click(.init(x: 0.6, y: 0.55)); await localFinished(editing)
        XCTAssertEqual(editing.recipe, original); XCTAssertEqual(editing.recipe.schemaVersion, 1)
        XCTAssertFalse(editing.developmentSession.canUndo); XCTAssertNotNil(editing.message)
        await backend.setLocalNoResult(false)
        editing.selectDevelopmentLocalTool(.redEye, context: context); input.setSize(3)
        (frame, viewport) = try await localFrame(editing, context: context)
        try click(.init(x: 0.6, y: 0.55)); await localFinished(editing)
        XCTAssertEqual(editing.recipe.schemaVersion, 3)
        let red = try XCTUnwrap(editing.recipe.adjustmentsV3?.localEdits.operations.first)
        XCTAssertEqual(red.tool, .redEye); XCTAssertEqual(red.stroke.points.count, 1); XCTAssertNil(red.sourceSample)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        editing.selectDevelopmentLocalTool(.retouch, context: context); input.setSize(3)
        (frame, viewport) = try await localFrame(editing, context: context)
        try click(.init(x: 0.65, y: 0.6)); await localFinished(editing)
        let edits = try XCTUnwrap(editing.recipe.adjustmentsV3?.localEdits)
        XCTAssertEqual(edits.operations.map(\.tool), [.redEye, .retouch]); XCTAssertNotNil(edits.operations.last?.sourceSample)
        let retouch = try XCTUnwrap(edits.operations.last)
        try editing.developmentSession.apply(.setEnabled(.retouch, false), event: .init(context: context, control: .init(group: .retouch, name: "关闭修饰")))
        XCTAssertEqual(editing.recipe.adjustmentsV3?.localEdits.operations, edits.operations)
        editing.undoDevelopment(context: context); XCTAssertTrue(editing.developmentSession.parameters.localEdits.retouchEnabled)
        editing.removeDevelopmentLocalOperation(red.id, context: context)
        XCTAssertEqual(editing.developmentSession.parameters.localEdits.operations.map(\.id), [retouch.id])
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.developmentSession.parameters.localEdits.operations.map(\.id), edits.operations.map(\.id))
        try editing.developmentSession.apply(.reset(.retouch), event: .init(context: context, control: .init(group: .retouch, name: "复位修饰")))
        XCTAssertEqual(editing.developmentSession.parameters.localEdits.operations.map(\.id), [red.id])
        let persisted = try JSONEncoder().encode(editing.recipe)
        XCTAssertEqual(try DevelopmentRecipe.decodeJSON(persisted), editing.recipe)
        await editing.shutdown()
    }
    @MainActor func testLocalViewportOriginalAndZeroPressureRevokeStrokeWithoutWritesOrLateUp() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        editing.selectDevelopmentLocalTool(.retouch, context: context)
        let input = editing.developmentLocalInput; input.setSize(3)
        var (frame, viewport) = try await localFrame(editing, context: context)
        let original = editing.recipe, point = DevelopmentSourcePoint(x: 0.6, y: 0.55)
        let zero = UUID()
        XCTAssertTrue(input.pointer(try localEvent(.began, id: zero, frame: frame, viewport: viewport, source: point, tablet: true), context: context))
        XCTAssertTrue(input.pointer(try localEvent(.ended, id: zero, frame: frame, viewport: viewport, source: point, tablet: true), context: context))
        XCTAssertFalse(editing.developmentAnalysisBusy); XCTAssertEqual(editing.recipe, original)
        let id = UUID()
        XCTAssertTrue(input.pointer(try localEvent(.began, id: id, frame: frame, viewport: viewport, source: point), context: context))
        input.updateViewport(.init(frameID: frame.frameID, viewportSize: .init(width: 641, height: 480), imagePixelSize: viewport.imagePixelSize,
            imageRect: viewport.imageRect, backingScale: 2, transform: .init()), context: context)
        XCTAssertFalse(input.pointer(try localEvent(.ended, id: id, frame: frame, viewport: viewport, source: point), context: context))
        (frame, viewport) = try await localFrame(editing, context: context)
        let held = UUID()
        XCTAssertTrue(input.pointer(try localEvent(.began, id: held, frame: frame, viewport: viewport, source: point), context: context))
        editing.setDevelopmentOriginalHeld(true)
        XCTAssertFalse(input.pointer(try localEvent(.ended, id: held, frame: frame, viewport: viewport, source: point), context: context))
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        editing.setDevelopmentOriginalHeld(false)
        (frame, viewport) = try await localFrame(editing, context: context)
        input.setPanHeld(true)
        XCTAssertFalse(input.pointer(try localEvent(.began, id: UUID(), frame: frame, viewport: viewport, source: point), context: context))
        input.setPanHeld(false)
        let recordedRequests = await backend.userRequests
        XCTAssertEqual(recordedRequests.count, 0)
        editing.selectDevelopmentLocalTool(.redEye, context: context); input.setSize(3)
        let (eyeFrame, eyeViewport) = try await localFrame(editing, context: context), click = UUID()
        XCTAssertTrue(input.pointer(try localEvent(.began, id: click, frame: eyeFrame, viewport: eyeViewport, source: point, tablet: true, pressure: 0.8), context: context))
        XCTAssertTrue(input.pointer(try localEvent(.ended, id: click, frame: eyeFrame, viewport: eyeViewport, source: point, tablet: true, pressure: 0), context: context))
        await localFinished(editing)
        XCTAssertEqual(editing.developmentSession.parameters.localEdits.operations.first?.stroke.strength, 0.8,
            "A real tablet click must not vanish when lift reports zero pressure")
        await editing.shutdown()
    }
    @MainActor func testLocalLateBranchResultCannotAppendAndTerminationJoinsOwnedAnalysis() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(gate: nil, localCapabilitiesEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let old = try await activate(editing)
        editing.selectDevelopmentLocalTool(.retouch, context: old); editing.developmentLocalInput.setSize(3)
        let (frame, viewport) = try await localFrame(editing, context: old)
        await backend.setGate(gate)
        let id = UUID(), point = DevelopmentSourcePoint(x: 0.6, y: 0.55)
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.began, id: id, frame: frame, viewport: viewport, source: point), context: old))
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.ended, id: id, frame: frame, viewport: viewport, source: point), context: old))
        await gate.waitUntilEntered()
        let version = try XCTUnwrap(editing.versions.first { $0.kind == .original })
        editing.selectVersion(version, continueEditing: true)
        _ = try await activate(editing, excluding: old.draftBranchID)
        let after = editing.recipe
        await gate.release(); await localFinished(editing)
        XCTAssertEqual(editing.recipe, after); XCTAssertFalse(editing.developmentSession.canUndo)
        let context = try XCTUnwrap(editing.developmentContext)
        let second = PhotosAnalysisGate(); await backend.setGate(second)
        editing.selectDevelopmentLocalTool(.retouch, context: context); editing.developmentLocalInput.setSize(3)
        let (current, currentViewport) = try await localFrame(editing, context: context), pendingID = UUID()
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.began, id: pendingID, frame: current, viewport: currentViewport, source: point), context: context))
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.ended, id: pendingID, frame: current, viewport: currentViewport, source: point), context: context))
        await second.waitUntilEntered()
        var stopped = false
        let shutdown = Task { await editing.shutdown(); stopped = true }
        await second.waitUntilCancelled()
        XCTAssertFalse(stopped); XCTAssertNil(editing.developmentContext)
        await second.release(); await shutdown.value
        XCTAssertTrue(stopped); XCTAssertEqual(editing.recipe, after)
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testCancelledLocalPreparationIgnoresLateBackendResultSilently() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let original = editing.recipe
        editing.selectDevelopmentLocalTool(.retouch, context: context); editing.developmentLocalInput.setSize(3)
        let (frame, viewport) = try await localFrame(editing, context: context)
        await backend.setGate(gate)
        let id = UUID(), point = DevelopmentSourcePoint(x: 0.6, y: 0.55)
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.began, id: id, frame: frame, viewport: viewport, source: point), context: context))
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.ended, id: id, frame: frame, viewport: viewport, source: point), context: context))
        await gate.waitUntilEntered()
        editing.cancelDevelopmentLocalInput()
        await gate.waitUntilCancelled(); await gate.release(); await localFinished(editing)
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        XCTAssertNil(editing.message, "An explicit cancellation must not become a stale-analysis error")
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testLocalSpacePanPreservesFieldEditorPriorityAndNeverRevivesCancelledStroke() async throws {
        let application = NSApplication.shared, previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular { _ = application.setActivationPolicy(.regular) }
        XCTAssertEqual(application.activationPolicy(), .regular, "Native test host has regular activation policy")
        defer { _ = application.setActivationPolicy(previousPolicy) }
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        editing.selectDevelopmentLocalTool(.retouch, context: context); editing.developmentLocalInput.setSize(3)
        let (frame, viewport) = try await localFrame(editing, context: context)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.orderOut(nil); window.close() }
        window.title = "RAWMaster local Space test"
        let field = NSTextField(frame: .init(x: 0, y: 0, width: 160, height: 30))
        field.stringValue = "Field editor owns Space"
        window.contentView?.addSubview(field); window.center(); window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        func diagnostic(_ stage: String) {
            print("Local Space host", stage, "active", application.isActive, "key", window.isKeyWindow,
                  "ownKey", NSApp.keyWindow === window, "visible", window.isVisible,
                  "responder", String(describing: window.firstResponder.map { type(of: $0) }),
                  "fieldEditor", field.currentEditor() is NSTextView,
                  "panHeld", editing.developmentLocalInput.panHeld, "collecting", editing.developmentLocalInput.collecting)
        }
        func awaitHost(_ name: String, _ condition: @escaping @MainActor () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            diagnostic(name + " failed")
            throw NSError(domain: "RAWMasterTestHost", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
        }
        do {
            try await awaitHost("actual application and own key window") {
                application.isActive && NSApp.keyWindow === window && window.isKeyWindow && window.isVisible
            }
        } catch {
            if !application.isActive { throw XCTSkip("WindowServer did not activate the xctest host; run native window acceptance for this axis") }
            throw error
        }
        XCTAssertTrue(window.makeFirstResponder(field), "Native field accepts first responder")
        field.selectText(nil)
        try await awaitHost("actual field editor ready for Space") {
            NSApp.keyWindow === window && field.currentEditor() is NSTextView && window.firstResponder === field.currentEditor()
        }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertTrue(NSApp.keyWindow === window)
        XCTAssertTrue(window.firstResponder === editor)
        diagnostic("field ready")
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertFalse(editing.handleDevelopmentKey(space), "Text editing keeps its space key")
        XCTAssertFalse(editing.developmentLocalInput.panHeld)
        let nativeCanvas = ImageCanvas(frame: .init(x: 0, y: 40, width: 200, height: 100)); window.contentView?.addSubview(nativeCanvas)
        XCTAssertTrue(window.makeFirstResponder(nativeCanvas))
        try await awaitHost("actual canvas responder ready for Space") {
            NSApp.keyWindow === window && window.firstResponder === nativeCanvas && field.currentEditor() == nil
        }
        diagnostic("canvas ready")
        let id = UUID(), point = DevelopmentSourcePoint(x: 0.6, y: 0.55), original = editing.recipe
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.began, id: id, frame: frame, viewport: viewport, source: point), context: context))
        XCTAssertTrue(editing.handleDevelopmentKey(space)); XCTAssertTrue(editing.developmentLocalInput.panHeld)
        XCTAssertFalse(editing.developmentLocalInput.collecting)
        XCTAssertFalse(editing.developmentLocalInput.pointer(try localEvent(.ended, id: id, frame: frame, viewport: viewport, source: point), context: context))
        editing.setDevelopmentLocalPanHeld(false) // the Root-owned key-up hook
        XCTAssertFalse(editing.developmentLocalInput.panHeld); XCTAssertEqual(editing.recipe, original)
        XCTAssertTrue(editing.handleDevelopmentKey(space)); editing.suspendDevelopmentFocus()
        editing.setDevelopmentLocalPanHeld(false)
        XCTAssertFalse(editing.developmentLocalInput.panHeld); XCTAssertEqual(editing.recipe, original)
        XCTAssertFalse(editing.developmentSession.canUndo)
        diagnostic("focus release complete")
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    private func resolvedDehaze(_ projection: DevelopmentDehazeProjectionV1) -> DevelopmentResolvedDehazeV1 {
        .init(binding: .init(sourceContentID: projection.input.context.source.sourceContentID,
            sourceGeneration: projection.input.context.sourceGeneration, expectedRecipeFingerprint: projection.expectedRecipeFingerprint,
            stage: .workingImageBeforeGeometry), presentedRecipeFingerprint: projection.presentedRecipeFingerprint,
            input: projection.input, resolution: .prepared(.init(sourceBinding: projection.input.context.source,
                inputFingerprint: projection.input.inputFingerprint, airlight: .init(red: 0.5, green: 0.75, blue: 1), algorithmVersion: projection.input.algorithm.rawValue)))
    }
    @MainActor func testExplicitDehazeChoicePreservesStoredVersionsAndUsesV2OnlyForNewIntent() {
        func choose(_ p:DevelopmentAdvancedDetailV3 = .init(),_ wanted:Double? = 25)->DevelopmentDehazeAlgorithm {
            EditingController.dehazePreparationAlgorithm(parameters:p,wantedAmount:wanted)
        }
        XCTAssertEqual(choose(),.positiveColorGuideV2)
        XCTAssertEqual(choose(.init(),-25),.positiveColorGuideV2)
        XCTAssertEqual(choose(.init(),0),.v1);XCTAssertEqual(choose(.init(),nil),.v1)
        for amount in [-25.0,25] {
            XCTAssertEqual(choose(.init(dehaze:.init(enabled:false,amount:amount))),.v1)
            XCTAssertEqual(choose(.init(dehazeAlgorithmVersion:1)),.v1)
            XCTAssertEqual(choose(.init(dehazeAlgorithmVersion:2)),.positiveColorGuideV2)
        }
    }

    @MainActor func testExplicitDehazeV2AndLegacyReprepareKeepVersionThroughPauseAndReset() async throws {
        let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
        let backend=PhotosDevelopmentBackend(dehazeEnabled:true)
        let editing=try EditingController(store:fixture.store,libraryURL:fixture.library,defaults:fixture.defaults,previewBackend:backend)
        try await ready(editing,asset:fixture.assets[0]);let scope=try await activate(editing)
        let input=editing.developmentDehazeInput
        XCTAssertFalse(editing.supportsDevelopmentAutomatic(.dehaze))
        editing.requestDevelopmentAutomatic(.dehaze,context:scope)
        let absent=await backend.userRequests;XCTAssertTrue(absent.isEmpty)
        try input.commit(-25,context:scope);await localFinished(editing)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze?.algorithmVersion,2)
        try input.commit(25,context:scope)
        var requests=await backend.userRequests
        XCTAssertEqual(requests.count,1,"Moving across zero keeps the one prepared version")
        XCTAssertEqual(requests.first?.dehazeInputV1?.algorithm,.positiveColorGuideV2)
        try editing.developmentSession.apply(.setParameters(.color(.init(enabled:true,saturation:0.1))),
            event:.init(context:scope,control:.init(group:.color,name:"color")))
        XCTAssertNil(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.dehazeAlgorithmVersion,2)
        let reopened=try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(editing.recipe))
        editing.setRecipe{$0=reopened}
        try input.commit(40,context:scope);await localFinished(editing)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze?.algorithmVersion,2)
        try editing.resetDevelopmentDehaze(context:scope)
        // A persisted old nonzero recipe without an estimate retains its v1 request semantics.
        editing.setRecipe { value in
            value.adjustmentsV3!.advancedDetail.dehaze = .init(enabled:false,amount:20)
        }
        try input.commit(30,context:scope);await localFinished(editing)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze?.algorithmVersion,1)
        try editing.developmentSession.apply(.setParameters(.color(.init(enabled:true,saturation:0.2))),
            event:.init(context:scope,control:.init(group:.color,name:"color")))
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.dehazeAlgorithmVersion,1)
        let legacyReopened=try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(editing.recipe))
        editing.setRecipe{$0=legacyReopened}
        try input.commit(35,context:scope);await localFinished(editing)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze?.algorithmVersion,1)
        try editing.resetDevelopmentDehaze(context:scope)
        XCTAssertNil(editing.recipe.adjustmentsV3?.advancedDetail.dehazeAlgorithmVersion)
        try input.commit(25,context:scope);await localFinished(editing)
        requests=await backend.userRequests
        XCTAssertEqual(requests.compactMap{$0.dehazeInputV1?.algorithm},[.positiveColorGuideV2,.positiveColorGuideV2,.v1,.v1,.positiveColorGuideV2])
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze?.algorithmVersion,2)
        await editing.shutdown()
    }

    @MainActor func testDehazeHeldLatestScalarWaitsForReleaseThenPromotesOriginalInOneUndo() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(dehazeEnabled: true)
        await backend.setGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        XCTAssertTrue(editing.supportsDevelopmentDehaze); XCTAssertFalse(editing.supportsDevelopmentAutomatic(.dehaze))
        let input = editing.developmentDehazeInput, original = editing.recipe
        let first = try input.begin(context: context)
        XCTAssertNil(first.gesture)
        try input.change(20, token: first); try input.change(40, token: first)
        let beforeRequests = await backend.userRequests
        XCTAssertTrue(beforeRequests.isEmpty); XCTAssertEqual(editing.recipe, original)
        try input.end(first); await gate.waitUntilEntered()
        let latest = try input.begin(context: context)
        try input.change(60, token: latest); try input.change(70, token: latest)
        await gate.release(); await localFinished(editing)
        XCTAssertTrue(input.waitingForRelease); XCTAssertEqual(editing.recipe, original)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 0)
        editing.saveDevelopment(context: context)
        XCTAssertFalse(editing.saving, "A held, unapplied scalar cannot silently be treated as saved")
        try input.end(latest)
        let accepted = editing.recipe
        XCTAssertEqual(accepted.adjustmentsV3?.advancedDetail.dehaze, .init(enabled: true, amount: 70))
        XCTAssertNotNil(accepted.adjustmentsV3?.advancedDetail.preparedDehaze)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1); XCTAssertFalse(input.hasPendingInput)
        let requests = await backend.userRequests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.preview.recipe, try original.promotingToV3())
        XCTAssertEqual(request.presentedRecipeFingerprint, try EditingFingerprint.of(original))
        XCTAssertEqual(request.expectedRecipeFingerprint, try EditingFingerprint.of(request.preview.recipe))
        XCTAssertEqual(request.dehazeInputV1?.algorithm,.positiveColorGuideV2)
        XCTAssertEqual(request.dehazeInputV1, try editing.recipe.prospectiveDehazeInputV1(context: request.dehazeInputV1!.context,algorithm:.positiveColorGuideV2).input)
        XCTAssertNil(request.localInputV1)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        editing.undoDevelopment(context: context, redo: true); XCTAssertEqual(editing.recipe, accepted)
        let opens = await backend.opens; XCTAssertEqual(opens, 1)
        await editing.shutdown()
    }
    @MainActor func testDehazeZeroRevokesButJoinsOriginalChildBeforeAnotherUserRequestAndNoResultStaysClean() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(dehazeEnabled: true)
        await backend.setGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing), original = editing.recipe
        let input = editing.developmentDehazeInput
        try input.commit(0, context: context)
        let zeroRequests = await backend.userRequests; XCTAssertTrue(zeroRequests.isEmpty)
        try input.commit(30, context: context); await gate.waitUntilEntered()
        try input.commit(0, context: context); await gate.waitUntilCancelled()
        XCTAssertTrue(input.cancelling); XCTAssertTrue(editing.developmentAnalysisBusy)
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        editing.requestDevelopmentAutomatic(.light, context: context)
        let blockedRequests = await backend.userRequests
        XCTAssertEqual(blockedRequests.count, 1, "The existing owner must actually join the canceled child before admitting another")
        await gate.release(); await localFinished(editing)
        let completedRequests = await backend.userRequests
        XCTAssertEqual(completedRequests.count, 2); XCTAssertFalse(input.cancelling)
        XCTAssertNil(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1, "Only the later Light Auto contributes history")
        await editing.shutdown()
        for reason in [DevelopmentDehazeNoResult.insufficientVisibleSamples, .airlightOutsideDomain] {
            let sample = try EditingWorkflowTests.Fixture(); defer { sample.clean() }
            let noResult = PhotosDevelopmentBackend(dehazeEnabled: true); await noResult.setDehazeNoResult(reason)
            let controller = try EditingController(store: sample.store, libraryURL: sample.library, defaults: sample.defaults, previewBackend: noResult)
            try await ready(controller, asset: sample.assets[0]); let scope = try await activate(controller), before = controller.recipe
            try controller.developmentDehazeInput.commit(-25, context: scope); await localFinished(controller)
            XCTAssertEqual(controller.recipe, before); XCTAssertFalse(controller.developmentSession.canUndo)
            XCTAssertFalse(controller.isDirty); XCTAssertFalse(controller.developmentDehazeInput.hasPendingInput)
            XCTAssertNotNil(controller.message); XCTAssertFalse(controller.message?.contains("RAWMaster") == true)
            await controller.shutdown()
        }
    }
    @MainActor func testDehazeSourceBranchEpochFocusOriginalComparisonAndCropRevokeLateResultAndOldUp() async throws {
        for action in ["original", "comparison", "crop", "focus", "branch", "source", "shutdown"] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(dehazeEnabled: true)
            await backend.setGate(gate)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing), original = editing.recipe
            let input = editing.developmentDehazeInput, old = try input.begin(context: context)
            try input.change(30, token: old); try input.end(old); await gate.waitUntilEntered()
            var stopped = false
            var termination: Task<Void, Never>?
            switch action {
            case "original": editing.setDevelopmentOriginalHeld(true)
            case "comparison": editing.setComparisonMode(.wipeHorizontal)
            case "crop": editing.changeDevelopmentPage(.crop, context: context)
            case "focus": editing.suspendDevelopmentFocus()
            case "branch":
                let version = try XCTUnwrap(editing.versions.first { $0.kind == .original })
                editing.selectVersion(version, continueEditing: true)
                let replacement = try await activate(editing, excluding: context.draftBranchID)
                let fresh = try input.begin(context: replacement)
                try input.change(12, token: fresh)
                XCTAssertThrowsError(try editing.setDevelopmentDehazeEnabled(false, context: context))
                XCTAssertThrowsError(try editing.resetDevelopmentDehaze(context: context))
                XCTAssertEqual(input.tracking, fresh, "An old header must not cancel new-branch tracking")
                try input.end(fresh, cancelled: true)
            case "shutdown": termination = Task { await editing.shutdown(); stopped = true }
            default: editing.retryPreview()
            }
            await gate.waitUntilCancelled()
            if termination != nil { XCTAssertFalse(stopped, "Shutdown must join this actual Dehaze analysis child") }
            XCTAssertFalse(input.hasPendingInput, action)
            XCTAssertThrowsError(try input.change(90, token: old), action)
            XCTAssertThrowsError(try input.end(old), action)
            await gate.release()
            if let termination { await termination.value } else { await localFinished(editing) }
            XCTAssertEqual(editing.recipe, original, action); XCTAssertFalse(editing.developmentSession.canUndo, action)
            XCTAssertNil(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze, action)
            await editing.shutdown()
        }
    }
    @MainActor func testDehazeCurrentContextAndFullDraftFencesCannotBeReplacedByEqualInputOrResultContext() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: PhotosDevelopmentBackend(dehazeEnabled: true))
        try await ready(editing, asset: fixture.assets[0]); let scope = try await activate(editing), original = editing.recipe
        let projection = try editing.developmentDehazeProjection(context: scope), resolved = resolvedDehaze(projection)
        let session = editing.developmentSession, ticket = try session.admitAnalysis(context: scope)
        session.currentDehazeContext = { _ in nil }
        XCTAssertThrowsError(try session.acceptDehazeAnalysis(resolved, ticket: ticket, expectedInput: projection.input, wantedAmount: 30, title: "fixture"))
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(session.canUndo)
        session.currentDehazeContext = { [weak editing] context in try editing?.admittedDevelopmentDehazeContext(context: context) }
        var geometry = DevelopmentGeometryV3(); geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        try session.apply(.setGeometry(geometry), event: .init(context: scope, control: .init(group: nil, name: "crop")))
        let downstream = editing.recipe, changed = try editing.developmentDehazeProjection(context: scope)
        XCTAssertEqual(changed.input.inputFingerprint, projection.input.inputFingerprint)
        XCTAssertNotEqual(changed.presentedRecipeFingerprint, projection.presentedRecipeFingerprint)
        XCTAssertThrowsError(try session.acceptDehazeAnalysis(resolved, ticket: ticket, expectedInput: projection.input, wantedAmount: 30, title: "old draft"))
        XCTAssertEqual(editing.recipe, downstream); XCTAssertEqual(session.history.entryCount, 1)
        let currentTicket = try session.admitAnalysis(context: scope)
        let wrong = DevelopmentResolvedDehazeV1(binding: resolvedDehaze(changed).binding,
            presentedRecipeFingerprint: String(repeating: "f", count: 64), input: changed.input, resolution: resolvedDehaze(changed).resolution)
        XCTAssertThrowsError(try session.acceptDehazeAnalysis(wrong, ticket: currentTicket, expectedInput: changed.input, wantedAmount: 30, title: "wrong fp"))
        XCTAssertEqual(editing.recipe, downstream)
        let newer = try session.admitAnalysis(context: scope)
        try session.cancelAnalysis(operationID: currentTicket.operationID, context: scope)
        XCTAssertTrue(try session.acceptDehazeAnalysis(resolvedDehaze(changed), ticket: newer, expectedInput: changed.input, wantedAmount: 30, title: "new ticket"), "Old cancellation must not cancel a newer ticket")
        await editing.shutdown()

        let outer = try EditingWorkflowTests.Fixture(); defer { outer.clean() }
        let backend = PhotosDevelopmentBackend(dehazeEnabled: true); await backend.setDehazeOuterMismatch()
        let rejected = try EditingController(store: outer.store, libraryURL: outer.library, defaults: outer.defaults, previewBackend: backend)
        try await ready(rejected, asset: outer.assets[0]); let context = try await activate(rejected), before = rejected.recipe
        try rejected.developmentDehazeInput.commit(30, context: context); await localFinished(rejected)
        XCTAssertEqual(rejected.recipe, before); XCTAssertFalse(rejected.developmentSession.canUndo)
        XCTAssertFalse(rejected.developmentDehazeInput.hasPendingInput)
        await rejected.shutdown()
    }
    @MainActor func testReadyDehazeSliderAndUpstreamPauseShareHistoryWhileLocalAndGeometryKeepPreparedValue() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, advancedDetailCapabilities: [.texture, .clarity], dehazeEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        try editing.updateDevelopmentLegacy(context: context, control: "legacy.whites") { basis in
            var color = basis.color ?? .init(); color.tones.whites = 25; basis.color = color
        }
        let input = editing.developmentDehazeInput
        try input.commit(40, context: context); await localFinished(editing)
        let count = editing.developmentSession.history.entryCount
        let token = try input.begin(context: context); XCTAssertNotNil(token.gesture)
        try input.change(50, token: token); try input.change(60, token: token); try input.end(token)
        XCTAssertEqual(editing.developmentSession.history.entryCount, count + 1)
        let active = editing.recipe
        for group in ["light", "legacy", "texture"] {
            if group == "light" {
                try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.3))),
                    event: .init(context: context, control: .init(group: .light, name: "light")))
            } else if group == "legacy" {
                try editing.updateDevelopmentLegacy(context: context, control: "legacy.grading") { basis in
                    var color = basis.color ?? .init(); color.grading.shadows = .init(hueDegrees: 45, saturation: 20); basis.color = color
                }
            } else { try editing.changeDevelopmentAdvancedDetail(.texture, change: .amount(20), context: context) }
            XCTAssertNil(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze, group)
            XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.dehaze, .init(enabled: false, amount: 60), group)
            XCTAssertTrue(editing.message?.contains("数量已保留") == true, group)
            editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, active, group)
        }
        editing.selectDevelopmentLocalTool(.retouch, context: context); editing.developmentLocalInput.setSize(3)
        let (frame, viewport) = try await localFrame(editing, context: context)
        let id = UUID(), point = DevelopmentSourcePoint(x: 0.6, y: 0.55)
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.began, id: id, frame: frame, viewport: viewport, source: point), context: context))
        XCTAssertTrue(editing.developmentLocalInput.pointer(try localEvent(.ended, id: id, frame: frame, viewport: viewport, source: point), context: context))
        await localFinished(editing)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.localEdits.operations.count, 1)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze, active.adjustmentsV3?.advancedDetail.preparedDehaze)
        var geometry = editing.developmentGeometry; geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        try editing.setDevelopmentGeometry(geometry, context: context)
        XCTAssertEqual(editing.developmentDehazeStatus, .ready)
        XCTAssertEqual(editing.developmentLegacyBasis.color?.tones.whites, 25)
        try editing.setDevelopmentDehazeEnabled(false, context: context)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.dehaze.amount, 60)
        try editing.setDevelopmentDehazeEnabled(true, context: context)
        try input.commit(0, context: context)
        let zero = editing.recipe
        XCTAssertNotNil(zero.adjustmentsV3?.advancedDetail.preparedDehaze)
        try editing.resetDevelopmentDehaze(context: context)
        XCTAssertNil(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, zero)
        XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(editing.recipe)), editing.recipe)
        let requests = await backend.userRequests
        XCTAssertEqual(requests.filter { if case .prepareDehaze = $0.operation { return true }; return false }.count, 1)
        await editing.shutdown()
    }
    @MainActor func testDehazeMetadataPreparationWorksWithMissingAWhileOrdinaryBitmapFailsAndCapabilityIsAttested() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(dehazeEnabled: true, requiresPreparedDehazeForActiveRender: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); _ = try await activate(editing)
        var missing = try editing.recipe.promotingToV3()
        missing.adjustmentsV3!.advancedDetail.dehaze = .init(enabled: true, amount: 40)
        editing.setRecipe { $0 = missing }
        editing.retryPreview()
        let scope = try await activate(editing)
        let failed = expectation(description: "ordinary bitmap explicitly requires preparation")
        var delivered = false
        let observation = editing.previews.primary.$error.sink { value in
            if value != nil, !delivered { delivered = true; failed.fulfill() }
        }
        await fulfillment(of: [failed], timeout: 5); observation.cancel()
        XCTAssertTrue(editing.previews.primary.canInspectDevelopmentSource)
        XCTAssertFalse(editing.previews.primary.currentFrameWasDrawn)
        XCTAssertTrue(editing.supportsDevelopmentDehaze)
        _ = try editing.developmentDehazeProjection(context: scope)
        try editing.developmentDehazeInput.commit(50, context: scope); await localFinished(editing); await settled(editing)
        XCTAssertEqual(editing.developmentDehazeStatus, .ready)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.dehaze.amount, 50)
        XCTAssertEqual(editing.previews.primary.frameRecipe, editing.recipe)
        await editing.shutdown()

        let absent = try EditingWorkflowTests.Fixture(); defer { absent.clean() }
        let borrowed = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, advancedDetailCapabilities: [.dehaze])
        let unavailable = try EditingController(store: absent.store, libraryURL: absent.library, defaults: absent.defaults, previewBackend: borrowed)
        try await ready(unavailable, asset: absent.assets[0]); let context = try await activate(unavailable), before = unavailable.recipe
        XCTAssertNotNil(unavailable.developmentSourceFacts?.localDecoderContractFingerprint)
        XCTAssertNil(unavailable.developmentSourceFacts?.dehazeContextV1); XCTAssertFalse(unavailable.supportsDevelopmentDehaze)
        XCTAssertThrowsError(try unavailable.developmentDehazeInput.commit(20, context: context))
        XCTAssertEqual(unavailable.recipe, before); XCTAssertFalse(unavailable.developmentSession.canUndo)
        await unavailable.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testDehazeMenuUndoRedoCancelsPendingWithoutMovingHistoryAndOldContextCannotCancelNewIntent() async throws {
        for withHistory in [false, true] {
            for redo in [false, true] {
                let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
                let backend = PhotosDevelopmentBackend(dehazeEnabled: true), gate = PhotosAnalysisGate()
                await backend.setGate(gate)
                let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
                try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
                if withHistory {
                    try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.2))),
                        event: .init(context: context, control: .init(group: .light, name: "fixture history")))
                }
                let before = editing.recipe, count = editing.developmentSession.history.entryCount
                try editing.developmentDehazeInput.commit(40, context: context); await gate.waitUntilEntered()
                editing.undoDevelopment(context: context, redo: redo) // exact command-menu Controller entry
                await gate.waitUntilCancelled()
                XCTAssertFalse(editing.developmentDehazeInput.hasPendingInput)
                XCTAssertTrue(editing.developmentAnalysisBusy, "Menu cancellation still awaits its actual child")
                XCTAssertEqual(editing.recipe, before); XCTAssertEqual(editing.developmentSession.history.entryCount, count)
                await gate.release(); await localFinished(editing)
                XCTAssertEqual(editing.recipe, before); XCTAssertEqual(editing.developmentSession.history.entryCount, count)

                editing.suspendDevelopmentFocus()
                let fresh = try await activate(editing), next = PhotosAnalysisGate()
                await backend.setGate(next)
                try editing.developmentDehazeInput.commit(50, context: fresh); await next.waitUntilEntered()
                let operation = editing.developmentDehazeInput.operationID
                editing.undoDevelopment(context: context, redo: redo)
                XCTAssertTrue(editing.developmentDehazeInput.hasPendingInput)
                XCTAssertEqual(editing.developmentDehazeInput.operationID, operation, "Old menu scope must not revoke a new intent")
                editing.undoDevelopment(context: fresh, redo: redo); await next.waitUntilCancelled()
                XCTAssertTrue(editing.developmentAnalysisBusy)
                await next.release(); await localFinished(editing)
                XCTAssertEqual(editing.recipe, before); XCTAssertEqual(editing.developmentSession.history.entryCount, count)
                await editing.shutdown()
            }
        }
    }
    @MainActor func testDehazeLiveExportRejectsBlockedAndHeldPreparationWithoutCreatingCandidates() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(dehazeEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.2))),
            event: .init(context: context, control: .init(group: .light, name: "live edit")))
        let before = editing.recipe, versions = editing.versions.count
        for held in [false, true] {
            editing.openExport()
            XCTAssertTrue(editing.showExport)
            XCTAssertEqual(editing.exportVersion?.recipe, before)
            editing.showExport = false
            let gate = PhotosAnalysisGate(); await backend.setGate(gate)
            try editing.developmentDehazeInput.commit(40, context: context); await gate.waitUntilEntered()
            if held {
                let token = try editing.developmentDehazeInput.begin(context: context)
                try editing.developmentDehazeInput.change(70, token: token)
                await gate.release(); await localFinished(editing)
                XCTAssertTrue(editing.developmentDehazeInput.waitingForRelease)
                XCTAssertFalse(editing.developmentAnalysisBusy)
            }
            editing.openExport()
            XCTAssertFalse(editing.showExport, "Pending preparation must not freeze a stale export")
            XCTAssertFalse(editing.saving)
            XCTAssertEqual(editing.exportVersion?.recipe, before)
            editing.showExport = false
            XCTAssertEqual(editing.versions.count, versions); XCTAssertEqual(editing.recipe, before)
            editing.developmentDehazeInput.cancel()
            if !held { await gate.waitUntilCancelled(); await gate.release(); await localFinished(editing) }
            XCTAssertEqual(editing.versions.count, versions); XCTAssertEqual(editing.recipe, before)
        }
        editing.openExport()
        XCTAssertTrue(editing.showExport)
        XCTAssertEqual(editing.exportVersionID, editing.draftParentID)
        XCTAssertEqual(editing.exportVersion?.recipe, before)
        try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.3))),
            event: .init(context: context, control: .init(group: .light, name: "later live edit")))
        XCTAssertEqual(editing.exportVersion?.recipe, editing.recipe,
            "The export sheet reads the current live recipe without a draft-save transaction")
        XCTAssertEqual(editing.versions.count, versions)
        XCTAssertEqual(editing.work?.adoptedVersionID, editing.versions.first { $0.kind == .original }?.id)
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testRedEyeAutomaticCapabilityAndDedicatedWholeSourceDispatchNeedNoDraw() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let unavailableBackend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true)
        let unavailable = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: unavailableBackend)
        try await ready(unavailable, asset: fixture.assets[0]); let absent = try await activate(unavailable)
        XCTAssertFalse(unavailable.supportsDevelopmentRedEyeAutomatic())
        unavailable.requestDevelopmentRedEyeAutomatic(context: absent)
        let absentRequests = await unavailableBackend.userRequests
        XCTAssertTrue(absentRequests.isEmpty); XCTAssertFalse(unavailable.developmentAnalysisBusy)
        await unavailable.shutdown()

        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, redEyeAutomaticEnabled: true, genericRedEyeAdvertised: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        XCTAssertTrue(editing.supportsDevelopmentRedEyeAutomatic())
        XCTAssertFalse(editing.previews.primary.currentFrameWasDrawn)
        XCTAssertNil(editing.developmentLocalFrame(context: context)); XCTAssertNil(editing.developmentLocalInput.tool)
        let tracking = try editing.developmentSession.beginGesture(.init(group: .curves, name: "active adjustment"), context: context)
        editing.requestDevelopmentRedEyeAutomatic(context: context)
        XCTAssertEqual(editing.developmentSession.activeGesture, tracking)
        let whileTracking = await backend.userRequests; XCTAssertTrue(whileTracking.isEmpty)
        try editing.developmentSession.endGesture(tracking, .cancel)
        editing.developmentLocalInput.setSize(7, tool: .redEye)
        editing.requestDevelopmentAutomatic(.redEye, context: context)
        let beforeAuto = await backend.userRequests; XCTAssertTrue(beforeAuto.isEmpty)
        editing.requestDevelopmentAutomatic(nil, context: context); await localFinished(editing)
        var requests = await backend.userRequests
        XCTAssertEqual(requests.map(\.operation), [.automatic(nil)], "Enhance must not dispatch whole-image RedEye")
        editing.requestDevelopmentRedEyeAutomatic(context: context); await localFinished(editing)
        requests = await backend.userRequests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.operation, .redEyeAutomatic); XCTAssertEqual(request.stage, .workingImageBeforeGeometry)
        XCTAssertEqual(request.roi, .init()); XCTAssertEqual(request.localInputV1?.targetTool, .redEye)
        XCTAssertEqual(editing.developmentLocalInput.size(for: .redEye), 7)
        XCTAssertNil(editing.developmentLocalInput.tool)
        XCTAssertTrue(editing.developmentSession.parameters.localEdits.operations.allSatisfy { $0.sourceSample == nil && $0.tool == .redEye })
        let opens = await backend.opens; XCTAssertEqual(opens, 1)
        await editing.shutdown()
    }

    @MainActor func testRedEyeAutomaticBatchEnablesProjectedPrefixAtomicallyAndKeepsOneUndo() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, redEyeAutomaticEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        try editing.updateDevelopmentLegacy(context: context, control: "legacy.whites") { basis in
            var color = basis.color ?? .init(); color.tones.whites = 25; basis.color = color
        }
        let original = editing.recipe, count = editing.developmentSession.history.entryCount
        let gate = PhotosAnalysisGate(); await backend.setGate(gate)
        var writes = 0; let observation = editing.$recipe.dropFirst().sink { _ in writes += 1 }
        editing.requestDevelopmentRedEyeAutomatic(context: context); await gate.waitUntilEntered()
        editing.requestDevelopmentRedEyeAutomatic(context: context)
        XCTAssertTrue(editing.developmentRedEyeAutomaticInProgress); XCTAssertEqual(editing.recipe, original)
        XCTAssertEqual(writes, 0); XCTAssertEqual(editing.developmentSession.history.entryCount, count)
        let pending = await backend.userRequests; XCTAssertEqual(pending.count, 1)
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.presentedRecipeFingerprint, try EditingFingerprint.of(original))
        XCTAssertEqual(request.preview.recipe, try original.promotingToV3())
        XCTAssertFalse(request.preview.recipe.adjustmentsV3!.localEdits.redEyeEnabled)
        await gate.release(); await localFinished(editing); observation.cancel()
        XCTAssertEqual(writes, 1); XCTAssertEqual(editing.developmentSession.history.entryCount, count + 1)
        let applied = editing.recipe, operations = editing.developmentSession.parameters.localEdits.operations
        XCTAssertEqual(operations.count, 2); XCTAssertEqual(Set(operations.map(\.id)).count, 2)
        XCTAssertTrue(editing.developmentSession.parameters.localEdits.redEyeEnabled)
        XCTAssertEqual(editing.developmentLegacyBasis.color?.tones.whites, 25)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        editing.undoDevelopment(context: context, redo: true); XCTAssertEqual(editing.recipe, applied)
        try editing.developmentSession.apply(.setEnabled(.redEye, false), event: .init(context: context, control: .init(group: .redEye, name: "关闭红眼")))
        let disabled = editing.recipe
        editing.requestDevelopmentRedEyeAutomatic(context: context); await localFinished(editing)
        let all = await backend.userRequests, next = try XCTUnwrap(all.last)
        let facts = try XCTUnwrap(editing.developmentSourceFacts)
        let projection = try disabled.prospectiveLocalInputV1(source: facts.sourceBinding, sourceGeneration: context.sourceGeneration,
            decoderContractFingerprint: XCTUnwrap(facts.localDecoderContractFingerprint), targetTool: .redEye)
        XCTAssertEqual(next.localInputV1, projection.input); XCTAssertEqual(next.localInputV1?.prefixCount, 2)
        XCTAssertTrue(projection.recipe.adjustmentsV3!.localEdits.redEyeEnabled)
        XCTAssertEqual(editing.developmentSession.parameters.localEdits.operations.count, 4)
        XCTAssertEqual(Array(editing.developmentSession.parameters.localEdits.operations.prefix(2)), operations)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, disabled)
        await editing.shutdown()
    }

    @MainActor func testRedEyeAutomaticNoResultBudgetAndRemainingCapacityNeverWriteOrPartiallyAppend() async throws {
        for outcome in ["no-eyes", "no-red", "no-visible", "budget", "capacity"] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, redEyeAutomaticEnabled: true)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
            switch outcome {
            case "no-eyes": await backend.setRedEyeAutomaticNoResult(.noConfidentEyes)
            case "no-red": await backend.setRedEyeAutomaticNoResult(.noRedPixels)
            case "no-visible": await backend.setRedEyeAutomaticNoResult(.noVisibleSamples)
            case "budget": await backend.setRedEyeAutomaticFailure(.localWorkBudgetExceeded) // Backend's >64/detector/work failure contract.
            default:
                let source = try XCTUnwrap(editing.developmentSession.source)
                var payload = DevelopmentAdjustmentsV3()
                let existing = (0..<127).map { _ in DevelopmentLocalEdit(id: UUID(), sourceContentID: source.sourceContentID, tool: .redEye,
                    stroke: .init(points: [.init(position: .init(x: 0.4, y: 0.4))], radiusInShortEdge: 0.03)) }
                payload.localEdits = .init(sourceBinding: source, redEyeEnabled: false, operations: existing)
                editing.setRecipe { $0 = .init(adjustmentsV3: payload) }
            }
            let before = editing.recipe, count = editing.developmentSession.history.entryCount, dirty = editing.isDirty
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(before)
            var writes = 0; let observation = editing.$recipe.dropFirst().sink { _ in writes += 1 }
            editing.requestDevelopmentRedEyeAutomatic(context: context); await localFinished(editing); observation.cancel()
            XCTAssertEqual(editing.recipe, before, outcome); XCTAssertEqual(try encoder.encode(editing.recipe), bytes, outcome)
            XCTAssertEqual(writes, 0, outcome); XCTAssertEqual(editing.developmentSession.history.entryCount, count, outcome)
            XCTAssertEqual(editing.isDirty, dirty, outcome)
            if outcome == "no-eyes" || outcome == "no-red" { XCTAssertTrue(editing.message?.contains("可调整大小后手动点选") == true) }
            if outcome == "budget" { XCTAssertTrue(editing.message?.contains("本次未应用") == true) }
            await editing.shutdown()
        }
    }

    @MainActor func testRedEyeAutomaticMenuAndKeyboardUndoCancelPendingAndJoinWithoutMovingHistory() async throws {
        // This selection must work independently of tests that happen to initialize AppKit first.
        _ = NSApplication.shared
        for withHistory in [false, true] {
            for keyboard in [false, true] {
                for redo in [false, true] {
                    let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
                    let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, redEyeAutomaticEnabled: true)
                    let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
                    try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
                    if withHistory { try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.2))),
                        event: .init(context: context, control: .init(group: .light, name: "fixture history"))) }
                    let before = editing.recipe, count = editing.developmentSession.history.entryCount
                    let gate = PhotosAnalysisGate(); await backend.setGate(gate)
                    editing.requestDevelopmentRedEyeAutomatic(context: context); await gate.waitUntilEntered()
                    if keyboard {
                        let flags: NSEvent.ModifierFlags = redo ? [.command, .shift] : [.command]
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                            timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
                        XCTAssertTrue(editing.handleDevelopmentKey(event))
                    } else { editing.undoDevelopment(context: context, redo: redo) }
                    await gate.waitUntilCancelled()
                    XCTAssertTrue(editing.developmentAnalysisBusy); XCTAssertTrue(editing.developmentRedEyeAutomaticCancelling)
                    editing.undoDevelopment(context: context, redo: redo) // Even another menu command during actual retirement is consumed.
                    XCTAssertEqual(editing.recipe, before); XCTAssertEqual(editing.developmentSession.history.entryCount, count)
                    editing.saveDevelopment(context: context); editing.openExport()
                    XCTAssertFalse(editing.saving)
                    await gate.release(); await localFinished(editing)
                    XCTAssertFalse(editing.developmentRedEyeAutomaticInProgress)
                    XCTAssertEqual(editing.recipe, before); XCTAssertEqual(editing.developmentSession.history.entryCount, count)
                    await editing.shutdown()
                }
            }
        }
    }

    @MainActor func testRedEyeAutomaticScopeRevocationAndOldContextNeverAppendOrCancelNewIntent() async throws {
        for action in ["original", "comparison", "crop", "focus", "branch", "source", "shutdown"] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, redEyeAutomaticEnabled: true)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing), before = editing.recipe
            let gate = PhotosAnalysisGate(); await backend.setGate(gate)
            editing.requestDevelopmentRedEyeAutomatic(context: context); await gate.waitUntilEntered()
            var stopped = false; var termination: Task<Void, Never>?
            switch action {
            case "original": editing.setDevelopmentOriginalHeld(true)
            case "comparison": editing.setComparisonMode(.wipeHorizontal)
            case "crop": editing.changeDevelopmentPage(.crop, context: context)
            case "focus": editing.suspendDevelopmentFocus()
            case "branch":
                let version = try XCTUnwrap(editing.versions.first { $0.kind == .original })
                editing.selectVersion(version, continueEditing: true)
                _ = try await activate(editing, excluding: context.draftBranchID)
            case "shutdown": termination = Task { await editing.shutdown(); stopped = true }
            default: editing.retryPreview()
            }
            await gate.waitUntilCancelled()
            if termination != nil { XCTAssertFalse(stopped) }
            await gate.release()
            if let termination { await termination.value } else { await localFinished(editing) }
            XCTAssertEqual(editing.recipe, before, action); XCTAssertFalse(editing.developmentSession.canUndo, action)
            if action == "focus" || action == "branch" {
                let fresh = try await activate(editing), next = PhotosAnalysisGate(); await backend.setGate(next)
                editing.requestDevelopmentRedEyeAutomatic(context: fresh); await next.waitUntilEntered()
                editing.cancelDevelopmentRedEyeAutomatic(context: context); editing.undoDevelopment(context: context)
                editing.requestDevelopmentRedEyeAutomatic(context: context)
                XCTAssertTrue(editing.developmentRedEyeAutomaticInProgress)
                editing.cancelDevelopmentRedEyeAutomatic(context: fresh); await next.waitUntilCancelled()
                await next.release(); await localFinished(editing)
                XCTAssertEqual(editing.recipe, before)
            }
            await editing.shutdown()
        }
    }

    @MainActor func testRedEyeAutomaticPreservesPreparedDehazeRejectsMissingAirlightAndFullDraftOrOuterMismatch() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(localCapabilitiesEnabled: true, redEyeAutomaticEnabled: true,
            dehazeEnabled: true, requiresPreparedDehazeForActiveRender: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let held = try editing.developmentDehazeInput.begin(context: context)
        try editing.developmentDehazeInput.change(20, token: held)
        editing.requestDevelopmentRedEyeAutomatic(context: context)
        let whileHeld = await backend.userRequests; XCTAssertTrue(whileHeld.isEmpty)
        XCTAssertEqual(editing.developmentDehazeInput.tracking, held)
        try editing.developmentDehazeInput.end(held, cancelled: true)
        try editing.developmentDehazeInput.commit(40, context: context); await localFinished(editing)
        let active = editing.recipe, prepared = active.adjustmentsV3?.advancedDetail.preparedDehaze
        XCTAssertNotNil(prepared)
        editing.requestDevelopmentRedEyeAutomatic(context: context); await localFinished(editing)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.advancedDetail.preparedDehaze, prepared)
        let local = editing.recipe
        XCTAssertEqual(local.adjustmentsV3?.localEdits.operations.count, 2)
        XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(local)), local)
        let first = try XCTUnwrap(local.adjustmentsV3?.localEdits.operations.first)
        editing.removeDevelopmentLocalOperation(first.id, context: context)
        XCTAssertEqual(editing.developmentSession.parameters.localEdits.operations.count, 1)
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, local)
        try editing.developmentSession.apply(.reset(.redEye), event: .init(context: context, control: .init(group: .redEye, name: "复位红眼")))
        XCTAssertEqual(editing.recipe, active)
        for mismatch in ["draft", "outer", "missing-A"] {
            if mismatch == "missing-A" {
                var missing = active; missing.adjustmentsV3!.advancedDetail.preparedDehaze = nil
                editing.setRecipe { $0 = missing }
            }
            let gate = PhotosAnalysisGate(); await backend.setGate(gate)
            let before = editing.recipe
            editing.requestDevelopmentRedEyeAutomatic(context: context); await gate.waitUntilEntered()
            var expected = before
            if mismatch == "draft" {
                var geometry = editing.developmentGeometry; geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                try editing.setDevelopmentGeometry(geometry, context: context); expected = editing.recipe
                XCTAssertEqual(expected.adjustmentsV3?.advancedDetail.preparedDehaze, prepared)
            } else if mismatch == "outer" { await backend.setLocalOuterMismatch() }
            await gate.release(); await localFinished(editing)
            XCTAssertEqual(editing.recipe, expected, mismatch)
            if mismatch == "missing-A" { XCTAssertTrue(editing.message?.contains("去朦胧") == true) }
        }
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testManagedThumbnailRequestUsesPrimaryScopeAndUnsupportedNeverWritesRecipe() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(), editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let before = editing.recipe, owner = editing.developmentThumbnails
        let failed = expectation(description: "typed unsupported graph visible")
        var received = false
        let observer = owner.$errors.sink { value in if value["light"] != nil, !received { received = true; failed.fulfill() } }
        owner.setVisible(.summary(.light), true, context: context)
        await fulfillment(of: [failed], timeout: 5); observer.cancel()
        let requests = await backend.thumbnailRequests, request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.presentationMode, .managedImage); XCTAssertEqual(request.target, .summary128)
        XCTAssertEqual(request.preview.consumerID, editing.previews.primary.consumerID)
        XCTAssertEqual(request.preview.recipe, try before.promotingToV3())
        XCTAssertEqual(request.presentedRecipeFingerprint, try EditingFingerprint.of(before))
        XCTAssertGreaterThan(request.registration.visibleGeneration, 0)
        XCTAssertEqual(editing.recipe, before); XCTAssertFalse(editing.developmentSession.canUndo)
        XCTAssertTrue(owner.sets.isEmpty, "Unsupported is a typed state, never a fake bitmap")
        await editing.shutdown()
    }
    @MainActor func testManagedThumbnailOffscreenCancelsOnlyItsChildAndShutdownJoins() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(), gate = PhotosAnalysisGate()
        await backend.setThumbnailGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing), before = editing.recipe
        editing.developmentThumbnails.setVisible(.summary(.color), true, context: context); await gate.waitUntilEntered()
        editing.developmentThumbnails.setVisible(.summary(.color), false, context: context)
        await gate.waitUntilCancelled()
        XCTAssertTrue(editing.developmentThumbnails.sets.isEmpty); XCTAssertEqual(editing.recipe, before)
        var stopped = false
        let closing = Task { await editing.shutdown(); stopped = true }
        await Task.yield(); XCTAssertFalse(stopped, "Owned thumbnail child is actually still suspended")
        await gate.release(); await closing.value
        XCTAssertTrue(stopped); XCTAssertTrue(editing.developmentThumbnails.sets.isEmpty)
        let requests = await backend.thumbnailRequests; XCTAssertEqual(requests.count, 1)
        let joins = await backend.thumbnailJoins; XCTAssertEqual(joins, 1)
    }
    @MainActor func testPhotoFilterFactsSelectionOriginalMemoryAndIntensityShareTypedHistory() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let absent = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(absent, asset: fixture.assets[0]); let old = try await activate(absent)
        XCTAssertEqual(absent.availableDevelopmentFilters, [.original])
        XCTAssertThrowsError(try absent.changeDevelopmentFilter(.vivid, context: old))
        XCTAssertFalse(absent.developmentSession.canUndo); await absent.shutdown()
        let backend = PhotosDevelopmentBackend(filtersEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); var context = try await activate(editing), original = editing.recipe
        XCTAssertEqual(editing.availableDevelopmentFilters.count, DevelopmentPhotoFilterV3.allCases.count)
        editing.changeDevelopmentPage(.filters, context: context); context = try XCTUnwrap(editing.developmentContext)
        XCTAssertEqual(editing.recipe, original)
        try editing.changeDevelopmentFilter(.vividWarm, context: context)
        let token = try editing.developmentSession.beginGesture(.init(group: .filter, name: "滤镜强度"), context: context)
        let entries = editing.developmentSession.history.entryCount
        for amount in [20.0, 40.0, 70.0] {
            var filter = editing.developmentSession.parameters.filter; filter.intensity = amount
            try editing.developmentSession.apply(.setParameters(.filter(filter)), event: .init(context: context, control: .init(group: .filter, name: "滤镜强度")), gesture: token)
        }
        try editing.developmentSession.endGesture(token, .commit)
        XCTAssertEqual(editing.developmentSession.history.entryCount, entries + 1)
        try editing.changeDevelopmentFilter(.original, context: context)
        XCTAssertFalse(editing.developmentSession.parameters.filter.enabled)
        XCTAssertEqual(editing.developmentSession.parameters.filter.selection, .vividWarm)
        XCTAssertEqual(editing.developmentSession.parameters.filter.intensity, 70)
        editing.undoDevelopment(context: context); XCTAssertTrue(editing.developmentSession.parameters.filter.enabled)
        try editing.developmentSession.apply(.reset(.filter), event: .init(context: context, control: .init(group: .filter, name: "复位滤镜")))
        XCTAssertEqual(editing.developmentSession.parameters.filter, .init())
        let requests = await backend.userRequests; XCTAssertTrue(requests.isEmpty)
        await editing.shutdown()
    }
    @MainActor func testManagedThumbnailOldContextCannotRegisterAfterFocusEpochChanges() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend()
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let old = try await activate(editing)
        editing.suspendDevelopmentFocus(); let fresh = try await activate(editing)
        XCTAssertNotEqual(old, fresh)
        editing.developmentThumbnails.setVisible(.summary(.light), true, context: old)
        let requests = await backend.thumbnailRequests; XCTAssertTrue(requests.isEmpty)
        let registration = DevelopmentThumbnailRegistration(visibleGeneration: 9)
        editing.setDevelopmentOriginalHeld(true)
        XCTAssertThrowsError(try editing.developmentThumbnailRequest(.summary(.light), registration: registration))
        editing.setDevelopmentOriginalHeld(false)
        let current = try editing.developmentThumbnailRequest(.summary(.light), registration: registration)
        XCTAssertEqual(current.registration, registration)
        XCTAssertEqual(current.preview.sourceGeneration, fresh.sourceGeneration)
        await editing.shutdown()
    }
}

final class ThumbnailAdoptionValidationTests: XCTestCase {
    private func fixture(_ filter: DevelopmentFilterV3, kind: DevelopmentThumbnailKind = .summary(.light), producerVersion: String? = nil) throws -> (DevelopmentThumbnailRequest, DevelopmentThumbnailSetDescriptor) {
        var payload = DevelopmentAdjustmentsV3(); payload.filter = filter
        let recipe = DevelopmentRecipe(adjustmentsV3: payload), fingerprint = try EditingFingerprint.of(recipe)
        let request = DevelopmentThumbnailRequest(registration: .init(visibleGeneration: 1),
            preview: .init(sessionID: .init(), sourceGeneration: 1, consumerID: .init(), role: .primary, revision: 1, recipe: recipe, quality: .settled),
            expectedRecipeFingerprint: fingerprint, kind: kind, target: kind == .filters ? .filters192 : .summary128, presentationMode: .managedImage,
            basis: .currentCanonical, expectedPhotoFilterResourceVersion: producerVersion)
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "a", count: 64), exifOrientation: 1, orientedWidth: 120, orientedHeight: 80)
        // Metadata only. No image lease, pixels, backing allocation or device qualification is invented.
        let tiles = (0..<kind.count).map { index in DevelopmentThumbnailTileDescriptor(index: index,
            summaryAmount: kind == .filters ? nil : Double(index) * 0.5 - 1,
            filter: kind == .filters ? DevelopmentPhotoFilterV3.allCases[index] : nil,
            actualRecipe: recipe, actualRecipeFingerprint: fingerprint, width: 120, height: 80,
            allocation: .init(allocationID: UUID(), residentCPUBytes: 38400, residentGPUBytes: 0, unionBytes: 38400, bytesPerRow: 480),
            storageFormat: "fixture", destinationColorSpace: "sRGB", destinationICCProfileSHA256: String(repeating: "b", count: 64), alphaPolicy: "premultiplied") }
        let descriptor = DevelopmentThumbnailSetDescriptor(registration: request.registration, actualRequest: request.preview, sourceBinding: source,
            expectedRecipeFingerprint: fingerprint, presentedRecipeFingerprint: fingerprint, kind: kind, target: request.target, contractVersion: 1,
            pipelineVersion: "fixture", proxyInputFingerprint: String(repeating: "c", count: 64), proxyWidth: 120, proxyHeight: 80, proxyEncoding: "fixture",
            sourceToProxy: [1,0,0,1,0,0], bakedBaseEV: 0, candidateNativeEV: Array(repeating: 0, count: kind.count), approximationVersion: "fixture",
            preparationCold: false, preparationNanoseconds: 0, bakedStages: [], unbakedStages: [], tiles: tiles, presentationMode: .managedImage,
            presentationVersion: "thumbnail-managed-rgba8-provider-v1", photoFilterResourceVersion: producerVersion)
        return (request, descriptor)
    }
    @MainActor func testSummaryFilterBypassAllowsNoProducerResource() throws {
        for filter in [DevelopmentFilterV3(enabled: true, selection: .vivid, intensity: 0),
                       .init(enabled: false, selection: .vivid, intensity: 100),
                       .init(enabled: true, selection: .original, intensity: 100)] {
            let (request, descriptor) = try fixture(filter)
            for current in [nil, "catalog-v1"] as [String?] {
                XCTAssertNoThrow(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: request, source: descriptor.sourceBinding, resourceVersion: current))
            }
        }
    }
    @MainActor func testActiveSummaryRequiresActualNonemptyMatchingResource() throws {
        let filter = DevelopmentFilterV3(enabled: true, selection: .vivid, intensity: 50)
        for producer in [nil, "catalog-v1", "wrong"] as [String?] {
            let (request, descriptor) = try fixture(filter, producerVersion: producer)
            for current in [nil, "", "catalog-v1"] as [String?] {
                if producer == "catalog-v1", current == "catalog-v1" {
                    XCTAssertNoThrow(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: request, source: descriptor.sourceBinding, resourceVersion: current))
                } else {
                    XCTAssertThrowsError(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: request, source: descriptor.sourceBinding, resourceVersion: current))
                }
            }
        }
    }
    @MainActor func testFiltersGridAlwaysRequiresResourceEvenWhenCurrentFilterIsZero() throws {
        for producer in [nil, "catalog-v1"] as [String?] {
            let (request, descriptor) = try fixture(.init(enabled: true, selection: .vivid, intensity: 0), kind: .filters, producerVersion: producer)
            if producer == nil { XCTAssertThrowsError(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: request, source: descriptor.sourceBinding, resourceVersion: "catalog-v1")) }
            else { XCTAssertNoThrow(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: request, source: descriptor.sourceBinding, resourceVersion: "catalog-v1")) }
        }
    }
    @MainActor func testBypassDoesNotWeakenRegistrationOrSourceFence() throws {
        let (request, descriptor) = try fixture(.init(enabled: true, selection: .vivid, intensity: 0))
        let other = DevelopmentThumbnailRequest(registration: .init(visibleGeneration: 1), preview: request.preview,
            expectedRecipeFingerprint: request.expectedRecipeFingerprint, kind: request.kind, target: request.target, presentationMode: .managedImage)
        XCTAssertThrowsError(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: other, source: descriptor.sourceBinding, resourceVersion: nil))
        XCTAssertThrowsError(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: request,
            source: .init(sourceContentID: String(repeating: "d", count: 64), exifOrientation: 1, orientedWidth: 120, orientedHeight: 80), resourceVersion: nil))
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testB7bCanonicalBridgePreservesDetailViewportAndSeparatesCacheKeys() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let registration = DevelopmentThumbnailRegistration(visibleGeneration: 7)
        let fit = try editing.developmentThumbnailRequest(.summary(.light), registration: registration)
        XCTAssertEqual(fit.basis, .currentCanonical); XCTAssertEqual(fit.preview.quality, .settled)
        XCTAssertNil(fit.expectedPhotoFilterResourceVersion); XCTAssertNoThrow(try fit.validate())
        editing.setActualPixels(true); await settled(editing)
        let detail = try editing.developmentThumbnailRequest(.summary(.light), registration: registration)
        XCTAssertEqual(detail.basis, .currentCanonical); XCTAssertEqual(detail.preview.quality, .detail)
        XCTAssertEqual(detail.preview.viewport.maxPixel, 0); XCTAssertNil(detail.expectedPhotoFilterResourceVersion)
        XCTAssertNoThrow(try detail.validate())
        XCTAssertEqual(detail.preview.sessionID, fit.preview.sessionID)
        XCTAssertEqual(detail.preview.consumerID, fit.preview.consumerID)
        XCTAssertEqual(detail.presentedRecipeFingerprint, fit.presentedRecipeFingerprint)
        let baseKey = EditingThumbnailPresentation.cacheKey(detail, context: context)
        let changedBasis = DevelopmentThumbnailRequest(registration: registration, preview: detail.preview,
            expectedRecipeFingerprint: detail.expectedRecipeFingerprint, kind: detail.kind, target: detail.target,
            presentationMode: .managedImage, basis: .settledFit)
        XCTAssertThrowsError(try changedBasis.validate(), "Detail cannot masquerade as a settledFit request")
        XCTAssertNotEqual(baseKey, EditingThumbnailPresentation.cacheKey(changedBasis, context: context))
        let differentResource = DevelopmentThumbnailRequest(registration: registration, preview: detail.preview,
            expectedRecipeFingerprint: detail.expectedRecipeFingerprint, kind: detail.kind, target: detail.target,
            presentationMode: .managedImage, basis: .currentCanonical, expectedPhotoFilterResourceVersion: "another-catalog")
        XCTAssertNotEqual(baseKey, EditingThumbnailPresentation.cacheKey(differentResource, context: context))
        // Isolate quality and viewport from the ordinary revision difference between FIT and detail.
        for (quality, viewport) in [(PreviewQuality.settled, PreviewViewport(maxPixel: 0)), (.detail, .init(maxPixel: 2400))] {
            let preview = DevelopmentPreviewRequest(sessionID: detail.preview.sessionID, sourceGeneration: detail.preview.sourceGeneration,
                consumerID: detail.preview.consumerID, role: detail.preview.role, revision: detail.preview.revision,
                recipe: detail.preview.recipe, quality: quality, viewport: viewport)
            let changed = DevelopmentThumbnailRequest(registration: registration, preview: preview,
                expectedRecipeFingerprint: detail.expectedRecipeFingerprint, kind: detail.kind, target: detail.target,
                presentationMode: .managedImage, basis: .currentCanonical)
            XCTAssertNotEqual(baseKey, EditingThumbnailPresentation.cacheKey(changed, context: context))
        }
        let resumedContext = EditingInteractionContext(workID: context.workID,
            admissionFingerprint: context.admissionFingerprint, sourceContentID: context.sourceContentID,
            sourceGeneration: context.sourceGeneration, draftBranchID: context.draftBranchID,
            draftBranchEpoch: context.draftBranchEpoch + 1)
        let resumedPreview = DevelopmentPreviewRequest(sessionID: detail.preview.sessionID,
            sourceGeneration: detail.preview.sourceGeneration, consumerID: detail.preview.consumerID,
            role: detail.preview.role, revision: detail.preview.revision + 1, recipe: detail.preview.recipe,
            quality: detail.preview.quality, viewport: detail.preview.viewport)
        let resumed = DevelopmentThumbnailRequest(registration: registration, preview: resumedPreview,
            expectedRecipeFingerprint: detail.expectedRecipeFingerprint,
            presentedRecipeFingerprint: detail.presentedRecipeFingerprint, kind: detail.kind, target: detail.target,
            presentationMode: .managedImage, basis: detail.basis)
        XCTAssertEqual(baseKey, EditingThumbnailPresentation.cacheKey(resumed, context: resumedContext),
            "Focus-only epoch and preview revision changes must reuse the displayed image set")
        await editing.shutdown()
    }
    @MainActor func testB7bBridgePassesActualFilterCatalogForGridAndNonzeroSummary() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: PhotosDevelopmentBackend(filtersEnabled: true))
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let registration = DevelopmentThumbnailRegistration(visibleGeneration: 8)
        let grid = try editing.developmentThumbnailRequest(.filters, registration: registration)
        XCTAssertEqual(grid.expectedPhotoFilterResourceVersion, editing.developmentSourceFacts?.photoFilterResourceVersion)
        XCTAssertEqual(grid.expectedPhotoFilterResourceVersion, "test-catalog-v1")
        XCTAssertEqual(grid.basis, .currentCanonical); XCTAssertEqual(grid.target, .filters192)
        XCTAssertNoThrow(try grid.validate())
        try editing.changeDevelopmentFilter(.vivid, context: context)
        let summary = try editing.developmentThumbnailRequest(.summary(.color), registration: registration)
        XCTAssertEqual(summary.expectedPhotoFilterResourceVersion, "test-catalog-v1")
        XCTAssertEqual(summary.preview.recipe.adjustmentsV3?.filter, .init(enabled: true, selection: .vivid, intensity: 100))
        XCTAssertEqual(summary.basis, .currentCanonical); XCTAssertNoThrow(try summary.validate())
        await editing.shutdown()
    }
}

extension ThumbnailAdoptionValidationTests {
    @MainActor func testB7bAdoptionRequiresRequestedCatalogForActiveButKeepsZeroBypass() throws {
        for amount in [0.0, 50.0] {
            let (request, descriptor) = try fixture(.init(enabled: true, selection: .vivid, intensity: amount), producerVersion: "catalog-v1")
            for wanted in [nil, "wrong", "catalog-v1"] as [String?] {
                let changed = DevelopmentThumbnailRequest(registration: request.registration, preview: request.preview,
                    expectedRecipeFingerprint: request.expectedRecipeFingerprint, presentedRecipeFingerprint: request.presentedRecipeFingerprint,
                    kind: request.kind, target: request.target, presentationMode: .managedImage,
                    basis: .currentCanonical, expectedPhotoFilterResourceVersion: wanted)
                if amount == 0 || wanted == "catalog-v1" {
                    XCTAssertNoThrow(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: changed,
                        source: descriptor.sourceBinding, resourceVersion: "catalog-v1"))
                } else {
                    XCTAssertThrowsError(try EditingThumbnailPresentation.validateAdoptionDescriptor(descriptor, request: changed,
                        source: descriptor.sourceBinding, resourceVersion: "catalog-v1"))
                }
            }
        }
    }
}

@MainActor private final class ThumbnailViewportHarnessModel: ObservableObject {
    @Published var height: CGFloat = 0
    var measuredRect: CGRect = .zero
    var measured: (() -> Void)?
    func record(_ rect: CGRect) { measuredRect = rect; if rect.width > 0 && rect.height > 0 { measured?() } }
}
private struct ThumbnailViewportHarness: View {
    @ObservedObject var model: ThumbnailViewportHarnessModel
    let editing: EditingController
    let context: EditingInteractionContext
    let kind: DevelopmentThumbnailKind
    var body: some View {
        Color.clear.frame(width: 240, height: 48)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { model.record(geometry.frame(in: .named("photos.inspector.scroll"))) }
                    .onChange(of: geometry.frame(in: .named("photos.inspector.scroll"))) { _, rect in model.record(rect) }
            })
            .modifier(PhotosThumbnailVisibility(editing: editing, context: context, kind: kind, viewportHeight: model.height))
            .frame(width: 300, height: 120, alignment: .topLeading)
            .coordinateSpace(name: "photos.inspector.scroll")
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor private func thumbnailIdle(_ owner: EditingThumbnailPresentation) async {
        if !owner.driving { return }
        let done = expectation(description: "actual thumbnail parent and child cleanup returned")
        var finished = false
        let observer = owner.$driving.sink { busy in if !busy, !finished { finished = true; done.fulfill() } }
        await fulfillment(of: [done], timeout: 5); observer.cancel()
    }
    @MainActor func testThumbnailVisibilityRealHostRecomputesUnchangedRectWhenViewportBecomesPositiveForAllKinds() async throws {
        _ = NSApplication.shared
        for kind in [DevelopmentThumbnailKind.summary(.light), .summary(.color), .summary(.blackAndWhite), .filters] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(filtersEnabled: true)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            try await ready(editing, asset: fixture.assets[0]); var context = try await activate(editing)
            if kind == .filters { editing.changeDevelopmentPage(.filters, context: context); context = try XCTUnwrap(editing.developmentContext) }
            let model = ThumbnailViewportHarnessModel(), measured = expectation(description: "real host measured nonzero rect at viewport zero")
            var receivedMeasurement = false
            model.measured = { if !receivedMeasurement { receivedMeasurement = true; measured.fulfill() } }
            let host = NSHostingView(rootView: ThumbnailViewportHarness(model: model, editing: editing, context: context, kind: kind))
            let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            await fulfillment(of: [measured], timeout: 5)
            XCTAssertTrue(window.isVisible); XCTAssertGreaterThan(host.bounds.width, 0)
            let rect = model.measuredRect, initial = await backend.thumbnailRequests
            XCTAssertGreaterThan(rect.height, 0); XCTAssertTrue(initial.isEmpty)
            XCTAssertFalse(editing.developmentThumbnails.state(kind).isBusy)
            let submitted = expectation(description: "same rect with positive viewport admits exactly one request")
            await backend.setThumbnailSubmitted { submitted.fulfill() }
            model.height = 120; host.layoutSubtreeIfNeeded()
            await fulfillment(of: [submitted], timeout: 5); await thumbnailIdle(editing.developmentThumbnails)
            XCTAssertEqual(model.measuredRect, rect, "The regression must exercise height change rather than a changed CGRect")
            let requests = await backend.thumbnailRequests; XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.kind, kind)
            XCTAssertEqual(editing.developmentThumbnails.state(kind), .unavailable)
            XCTAssertFalse(editing.developmentThumbnails.state(kind).isBusy)
            model.height = 0; host.layoutSubtreeIfNeeded()
            window.orderOut(nil); window.close(); await editing.shutdown()
        }
    }
    @MainActor func testThumbnailTypedTerminalsExitBusyAndOrdinaryRefreshCannotLoop() async throws {
        for error in [DevelopmentThumbnailError.awaitingSource, .staleSource, .superseded, .closed, .cancelled, .unsupportedGraph, .budgetUnavailable] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(); await backend.setThumbnailFailure(error)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing); await settled(editing)
            let before = editing.recipe, owner = editing.developmentThumbnails
            owner.setVisible(.summary(.light), true, context: context); await thumbnailIdle(owner)
            XCTAssertFalse(owner.state(.summary(.light)).isBusy)
            XCTAssertTrue(owner.sets.isEmpty); XCTAssertEqual(editing.recipe, before)
            XCTAssertFalse(editing.developmentSession.canUndo)
            if error == .unsupportedGraph { XCTAssertEqual(owner.state(.summary(.light)), .unavailable) }
            else if error == .budgetUnavailable { XCTAssertEqual(owner.state(.summary(.light)), .failed) }
            else { XCTAssertEqual(owner.state(.summary(.light)), .waitingForSource) }
            for _ in 0..<20 { owner.refresh(); owner.setVisible(.summary(.light), true, context: context) }
            XCTAssertFalse(owner.driving, "Same key/witness must not start another operation")
            let once = await backend.thumbnailRequests; XCTAssertEqual(once.count, 1)
            owner.retry(.summary(.light), context: context); await thumbnailIdle(owner)
            let retried = await backend.thumbnailRequests; XCTAssertEqual(retried.count, 2)
            await editing.shutdown()
        }
    }
    @MainActor func testThumbnailAwaitingSourceRetriesOnceOnlyWhenActualMatchingCanonicalFrameArrives() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(); await backend.setThumbnailFailure(.awaitingSource)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing); await settled(editing)
        let prior = try XCTUnwrap(editing.developmentThumbnailCanonicalWitness())
        let render = PhotosAnalysisGate(); await backend.setRenderGate(render)
        editing.setActualPixels(true); await render.waitUntilEntered()
        XCTAssertNil(editing.developmentThumbnailCanonicalWitness(), "Old FIT frame cannot witness a current detail request")
        let owner = editing.developmentThumbnails
        owner.setVisible(.summary(.color), true, context: context); await thumbnailIdle(owner)
        let first = await backend.thumbnailRequests; XCTAssertEqual(first.count, 1)
        XCTAssertEqual(owner.state(.summary(.color)), .waitingForSource)
        for _ in 0..<10 { owner.refresh() }; XCTAssertFalse(owner.driving)
        let second = expectation(description: "one automatic retry follows the actual current frame")
        await backend.setThumbnailSubmitted { second.fulfill() }
        await render.release(); await fulfillment(of: [second], timeout: 5); await thumbnailIdle(owner)
        let witness = try XCTUnwrap(editing.developmentThumbnailCanonicalWitness())
        XCTAssertNotEqual(witness.frameID, prior.frameID); XCTAssertEqual(witness.quality, "detail"); XCTAssertEqual(witness.viewportMaximumPixel, 0)
        let requests = await backend.thumbnailRequests; XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].preview.revision, requests[1].preview.revision, "This is same-key readiness, not a new recipe/revision retry")
        for _ in 0..<20 { owner.refresh() }; XCTAssertFalse(owner.driving)
        let stable = await backend.thumbnailRequests; XCTAssertEqual(stable.count, 2)
        await backend.setThumbnailSubmitted { } // Explicit retry is separate from the one automatic notification.
        owner.retry(.summary(.color), context: context); await thumbnailIdle(owner)
        let manual = await backend.thumbnailRequests; XCTAssertEqual(manual.count, 3)
        await editing.shutdown()
    }
    @MainActor func testThumbnailNewVisibilityWaitsForOldChildJoinAndOldRetryCannotTouchNewEpoch() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(), gate = PhotosAnalysisGate(); await backend.setThumbnailGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let old = try await activate(editing), before = editing.recipe
        let owner = editing.developmentThumbnails
        owner.setVisible(.summary(.light), true, context: old); await gate.waitUntilEntered()
        editing.suspendDevelopmentFocus(); await Task.yield()
        let thumbnailCancelled = await gate.wasCancelled
        XCTAssertFalse(thumbnailCancelled, "Focus loss retains thumbnail work and adopted image sets")
        let fresh = try await activate(editing)
        owner.setVisible(.summary(.color), true, context: fresh)
        owner.retry(.summary(.light), context: old); owner.setVisible(.summary(.color), false, context: old)
        let blocked = await backend.thumbnailRequests; XCTAssertEqual(blocked.count, 1)
        await gate.release(); await thumbnailIdle(owner)
        let finished = await backend.thumbnailRequests; XCTAssertEqual(finished.count, 2)
        XCTAssertEqual(finished.last?.kind, .summary(.color))
        XCTAssertEqual(owner.state(.summary(.color)), .unavailable)
        XCTAssertEqual(editing.recipe, before); XCTAssertFalse(editing.developmentSession.canUndo)
        await editing.shutdown()
    }
    @MainActor func testThumbnailCanonicalWitnessRejectsWrongPresentationAndModeWithoutChangingRecipe() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing); await settled(editing)
        let before = editing.recipe
        XCTAssertNotNil(editing.developmentThumbnailCanonicalWitness())
        XCTAssertNil(editing.previews.primary.thumbnailCanonicalWitness(recipe: before, presentationID: "old-mode"))
        var other = before; other.exposureEV += 0.25
        XCTAssertNil(editing.previews.primary.thumbnailCanonicalWitness(recipe: other, presentationID: editing.developmentPreviewPresentationID))
        editing.setDevelopmentOriginalHeld(true); XCTAssertNil(editing.developmentThumbnailCanonicalWitness())
        editing.setDevelopmentOriginalHeld(false); await settled(editing)
        XCTAssertNotNil(editing.developmentThumbnailCanonicalWitness())
        editing.suspendDevelopmentFocus(); XCTAssertNil(editing.developmentThumbnailCanonicalWitness())
        editing.developmentThumbnails.retry(.summary(.light), context: context)
        XCTAssertEqual(editing.recipe, before); XCTAssertFalse(editing.developmentSession.canUndo)
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testThumbnailDiagnosticsAreLazyBoundedFiniteAndHaveNoAssociationOrIdentityPayload() throws {
        var limiter = ThumbnailDiagnosticLimiter(), collections = 0
        let make: () -> ThumbnailDiagnosticPayload = {
            collections += 1
            return .init(reason: .gateFailed, flags: [.scopeMatch: true, .noActiveGesture: false],
                numbers: [.x: 12.5, .width: .infinity, .height: .nan, .visibleCount: 3],
                failedGate: .noActiveGesture, state: .waitingForSource)
        }
        for _ in 0..<200 { XCTAssertNil(limiter.collect(enabled: false, stage: .requestGate, kind: .summary(.light), make)) }
        XCTAssertEqual(collections, 0, "Disabled diagnostics must not collect or consume the lifetime allowance")
        let kinds: [DevelopmentThumbnailKind] = [.summary(.light), .summary(.color), .summary(.blackAndWhite), .filters]
        var rows: [[String: Any]] = []
        for index in 0..<200 {
            if let row = limiter.collect(enabled: true, stage: .requestGate, kind: kinds[index % 4], make) { rows.append(row) }
        }
        XCTAssertEqual(collections, 127); XCTAssertEqual(rows.count, 128)
        XCTAssertEqual(rows.last?["stage"] as? String, "overflow")
        XCTAssertEqual(rows.last?["count"] as? Int, 128)
        XCTAssertEqual(Set(rows.dropLast().compactMap { $0["kind"] as? String }), Set(["light", "color", "blackAndWhite", "filters"]))
        let allowed = Set(["stage", "reason", "kind", "scopeMatch", "noActiveGesture", "x", "visibleCount", "failedGate", "state", "count"])
        for row in rows {
            XCTAssertTrue(Set(row.keys).isSubset(of: allowed))
            XCTAssertNil(row["width"]); XCTAssertNil(row["height"])
            XCTAssertNil(row["operationID"]); XCTAssertNil(row["inputKind"])
            XCTAssertTrue(JSONSerialization.isValidJSONObject(row))
            _ = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        }
        XCTAssertEqual(rows.first?["failedGate"] as? String, "noActiveGesture")
        XCTAssertNil(limiter.collect(enabled: true, stage: .visibility, kind: .filters, make))
        XCTAssertEqual(collections, 127, "Overflow cannot collect again after a source/scope change")
    }

    func testThumbnailImageTrackingRequiresImagesToBeginButEndsOnceAfterTheyDisappear() {
        var tracking = PhotosThumbnailTracking(), begins = 0, ends = 0
        if tracking.begin(hasImages: false) { begins += 1 }
        XCTAssertFalse(tracking.active); XCTAssertEqual(begins, 0)
        if tracking.begin(hasImages: true) { begins += 1 }
        XCTAssertTrue(tracking.active)
        // A summary edit may detach all images. That does not replace the mounted input owner.
        if tracking.begin(hasImages: false) { begins += 1 }
        XCTAssertTrue(tracking.active); XCTAssertEqual(begins, 1)
        if tracking.end() { ends += 1 }
        if tracking.end() { ends += 1 } // late up or teardown cannot finish another sequence
        XCTAssertFalse(tracking.active); XCTAssertEqual(ends, 1)
        XCTAssertFalse(tracking.begin(hasImages: false), "An idle Retry/status cannot revive an image drag")
        XCTAssertTrue(tracking.begin(hasImages: true)); XCTAssertTrue(tracking.end())
    }

    @MainActor func testThumbnailHostedRetryIsAnAccessibleActionWithoutStartingSummaryTracking() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAXValue = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousAXValue, forAttribute: enhancedUI) }
        func axValue(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        func nodes(_ root: NSObject) -> [NSObject] {
            var pending = [root], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
            while let node = pending.popLast(), seen.count < 512 {
                guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
                result.append(node)
                pending += ((axValue(node, "accessibilityChildren") as? [Any]) ?? []).compactMap { $0 as? NSObject }
            }
            return result
        }
        for kind in [DevelopmentThumbnailKind.summary(.light), .summary(.color), .summary(.blackAndWhite), .filters] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(filtersEnabled: true)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            try await ready(editing, asset: fixture.assets[0]); var context = try await activate(editing)
            if kind == .filters { editing.changeDevelopmentPage(.filters, context: context); context = try XCTUnwrap(editing.developmentContext) }
            let owner = editing.developmentThumbnails, original = editing.recipe
            owner.setVisible(kind, true, context: context); await thumbnailIdle(owner)
            var interactions = 0, changes = 0
            let host = NSHostingView(rootView: PhotosThumbnailStrip(owner: owner, kind: kind, value: 0, context: context,
                interaction: { _ in interactions += 1 }, change: { _ in changes += 1 }).frame(width: 316, height: 48))
            let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 344, height: 48), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            window.orderFront(nil); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let identifier = "photos.\(kind.presentationKey).thumbnail.retry"
            func retryNode() -> NSObject? {
                nodes(window).first { axValue($0, "accessibilityIdentifier") as? String == identifier
                    && axValue($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue }
            }
            let rendered = expectation(description: "actual visible production Retry AX button \(kind.presentationKey)")
            let materialization = Task { @MainActor in
                for _ in 0..<100 {
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    if retryNode() != nil { rendered.fulfill(); return }
                    do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
                }
            }
            await fulfillment(of: [rendered], timeout: 3); materialization.cancel(); await materialization.value
            XCTAssertTrue(window.isVisible); XCTAssertEqual(host.bounds.height, 48)
            let button = try XCTUnwrap(retryNode(), "An unmaterialized/hidden action must fail")
            XCTAssertFalse(nodes(window).contains { axValue($0, "accessibilityLabel") as? String == "效果强度" },
                "Idle status is not replaced by an adjustable-image accessibility node")
            let submitted = expectation(description: "real AX Retry invokes owner and exactly one existing backend child")
            await backend.setThumbnailSubmitted { submitted.fulfill() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(button.responds(to: selector))
            let implementation = try XCTUnwrap(button.method(for: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let press = unsafeBitCast(implementation, to: Press.self)
            XCTAssertTrue(press(button, selector))
            await fulfillment(of: [submitted], timeout: 5); await thumbnailIdle(owner)
            let requests = await backend.thumbnailRequests
            XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests.last?.kind, kind)
            XCTAssertEqual(interactions, 0); XCTAssertEqual(changes, 0)
            XCTAssertNil(editing.developmentSession.activeGesture)
            XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
            owner.setVisible(kind, false, context: context); await thumbnailIdle(owner)
            await editing.shutdown()
        }
    }

    @MainActor func testThumbnailAdmissionStillRejectsActiveGestureAndOriginalAndRestoresWithoutRecipeWrites() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let original = editing.recipe, registration = DevelopmentThumbnailRegistration(visibleGeneration: 9)
        XCTAssertNoThrow(try editing.developmentThumbnailRequest(.summary(.light), registration: registration))
        let token = try editing.developmentSession.beginGesture(.init(group: .light, name: "diagnostic-gate"), context: context)
        XCTAssertThrowsError(try editing.developmentThumbnailRequest(.summary(.light), registration: registration)) { error in
            XCTAssertEqual(ThumbnailDiagnosticReason.error(error), .staleSource)
        }
        try editing.developmentSession.endGesture(token, .cancel)
        XCTAssertNoThrow(try editing.developmentThumbnailRequest(.summary(.light), registration: registration))
        editing.setDevelopmentOriginalHeld(true)
        XCTAssertThrowsError(try editing.developmentThumbnailRequest(.summary(.light), registration: registration))
        editing.setDevelopmentOriginalHeld(false)
        XCTAssertNoThrow(try editing.developmentThumbnailRequest(.summary(.light), registration: registration))
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testProductionInspectorNeverMountsOrSchedulesAdjustmentThumbnails() async throws {
        _ = NSApplication.shared
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(filtersEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing); await settled(editing)
        let original = editing.recipe
        let initial = await backend.thumbnailRequests
        XCTAssertTrue(initial.isEmpty, "No thumbnail work may precede the real view attachment")

        let host = NSHostingView(rootView: NativeEditingInspector(editing: editing).frame(width: 360, height: 700))
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 360, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFront(nil); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(window.isVisible); XCTAssertEqual(host.bounds.size, NSSize(width: 360, height: 700))
        XCTAssertEqual(editing.developmentSession.expandedGroups, Set([.whiteBalance]))
        var requests = await backend.thumbnailRequests
        XCTAssertTrue(requests.isEmpty, "Light, color and black-and-white controls must not generate effect strips")
        for kind in [DevelopmentThumbnailKind.summary(.light), .summary(.color), .summary(.blackAndWhite)] {
            XCTAssertEqual(editing.developmentThumbnails.state(kind), .idle)
        }

        editing.changeDevelopmentPage(.filters, context: context)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        requests = await backend.thumbnailRequests
        XCTAssertTrue(requests.isEmpty, "Text-only filter selection must not generate a thumbnail grid")
        XCTAssertEqual(editing.developmentThumbnails.state(.filters), .idle)
        XCTAssertEqual(editing.recipe, original); XCTAssertFalse(editing.developmentSession.canUndo)
        XCTAssertNil(editing.developmentSession.activeGesture)
        await editing.shutdown()
    }

    func testPresenceControlsBelongToEffectsNavigation() {
        let presence:Set<DevelopmentAdjustmentID>=[.texture,.clarity,.dehaze]
        XCTAssertTrue(presence.isSubset(of:Set(PhotosAdjustmentDestination.effects.groups)))
        XCTAssertTrue(presence.isDisjoint(with:PhotosAdjustmentDestination.basic.groups))
        XCTAssertTrue(PhotosAdjustmentDestination.basic.groups.contains(.definition))
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testSummaryControllerMenuUndoKeyboardRedoRestoreExactAmountAndOtherGroupEditsKeepIt() async throws {
        _ = NSApplication.shared
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend()
        await backend.setGate(gate)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let original = editing.recipe, amount = 0.5164835164835164
        var notified: [Double] = []
        let notification = editing.objectWillChange.sink {
            if let amount = editing.developmentSummaryAmounts[.light] { notified.append(amount) }
        }
        let token = try editing.developmentSession.beginGesture(.init(group: .light, name: "光效"), context: context)
        editing.requestDevelopmentSummary(.light, amount: amount, context: context, gesture: token)
        await gate.waitUntilEntered()
        editing.finishDevelopmentSummary(token)
        let ended = expectation(description: "successful summary amount published and same gesture ended")
        var received = false
        let observation = editing.developmentSession.$revision.sink { _ in
            if editing.developmentSummaryAmounts[.light] == amount, editing.developmentSession.activeGesture == nil, !received {
                received = true; ended.fulfill()
            }
        }
        await gate.release(); await fulfillment(of: [ended], timeout: 5); observation.cancel()
        let summarized = editing.recipe
        XCTAssertEqual(editing.developmentSummaryAmounts[.light]?.bitPattern, amount.bitPattern)
        XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
        XCTAssertTrue(notified.contains { $0.bitPattern == amount.bitPattern }, "The existing Controller observation must notify the unchanged Inspector projection")
        editing.undoDevelopment(context: context) // real menu entry point
        XCTAssertEqual(editing.recipe, original); XCTAssertNil(editing.developmentSummaryAmounts[.light])
        let redo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "Z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(editing.handleDevelopmentKey(redo))
        XCTAssertEqual(editing.recipe, summarized)
        XCTAssertEqual(editing.developmentSummaryAmounts[.light]?.bitPattern, amount.bitPattern)
        editing.setRecipe(control: "manual-other-group") { $0.adjustmentsV3?.color.vibrance = 0.3 }
        XCTAssertEqual(editing.developmentSummaryAmounts[.light]?.bitPattern, amount.bitPattern)
        editing.setRecipe(control: "manual-light") { $0.adjustmentsV3?.light.brilliance = 0.2 }
        XCTAssertNil(editing.developmentSummaryAmounts[.light])
        editing.undoDevelopment(context: context)
        XCTAssertEqual(editing.developmentSummaryAmounts[.light]?.bitPattern, amount.bitPattern)
        XCTAssertTrue(editing.handleDevelopmentKey(redo)); XCTAssertNil(editing.developmentSummaryAmounts[.light])
        notification.cancel()
        let requests = await backend.userRequests
        XCTAssertEqual(requests.count, 1, "Undo/Redo metadata must not rerun summary analysis")
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testCropAutomaticMetadataAdmissionUsesDedicatedOperationAndUncroppedVisibleFingerprint() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let absentBackend = PhotosDevelopmentBackend()
        let absent = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: absentBackend)
        let unavailable = try await cropReady(absent, asset: fixture.assets[0])
        absent.requestDevelopmentCropAutomatic(context: unavailable)
        let denied = await absentBackend.userRequests
        XCTAssertTrue(denied.isEmpty); XCTAssertNotNil(absent.developmentCropAutomaticUnavailableReason)
        await absent.shutdown()

        let backend = PhotosDevelopmentBackend(cropAutomaticEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        let context = try await cropReady(editing, asset: fixture.assets[0])
        var geometry = editing.developmentGeometry; geometry.crop = .init(x: 0.1, y: 0.2, width: 0.75, height: 0.65)
        try editing.setDevelopmentGeometry(geometry, context: context)
        await currentCropPreview(editing)
        let original = editing.recipe, count = editing.developmentSession.history.entryCount, adopted = editing.work?.adoptedVersionID
        XCTAssertFalse(editing.previews.primary.currentFrameWasDrawn)
        XCTAssertTrue(editing.cropEditing)
        editing.requestDevelopmentCropAutomatic(context: context); await localFinished(editing)
        let requests = await backend.userRequests, request = try XCTUnwrap(requests.last)
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(request.operation, .cropAutomatic)
        XCTAssertEqual(request.stage, .orientedSourceBeforeGeometry); XCTAssertEqual(request.roi, .init())
        XCTAssertEqual(request.preview.recipe, try original.promotingToV3())
        XCTAssertNotEqual(request.presentedRecipeFingerprint, try EditingFingerprint.of(original))
        var uncropped = original; uncropped.crop = .init()
        XCTAssertEqual(request.presentedRecipeFingerprint, try EditingFingerprint.of(uncropped))
        XCTAssertEqual(request.cropAutoInputV1?.baselineGeometryFingerprint, try EditingFingerprint.of(geometry))
        XCTAssertEqual(editing.developmentGeometry.straightenDegrees, 3)
        XCTAssertEqual(editing.developmentSession.history.entryCount, count + 1)
        let after = editing.recipe
        editing.undoDevelopment(context: context); XCTAssertEqual(editing.recipe, original)
        editing.undoDevelopment(context: context, redo: true); XCTAssertEqual(editing.recipe, after)
        XCTAssertEqual(editing.work?.adoptedVersionID, adopted)
        geometry = editing.developmentGeometry; geometry.verticalPerspective = 5
        try editing.setDevelopmentGeometry(geometry, context: context)
        XCTAssertTrue(editing.developmentCropAutomaticUnavailableReason?.contains("透视") == true)
        editing.requestDevelopmentCropAutomatic(context: context)
        let afterPerspective = await backend.userRequests; XCTAssertEqual(afterPerspective.count, 1)
        XCTAssertEqual(editing.developmentGeometry.verticalPerspective, 5)
        await editing.shutdown()
    }
    @MainActor func testCropAutomaticNoResultAndWrongOuterEnvelopeNeverPromoteOrWrite() async throws {
        for outcome in ["noHorizon", "unchanged", "wrongEnvelope"] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(cropAutomaticEnabled: true)
            if outcome == "wrongEnvelope" { await backend.setCropOuterMismatch() }
            else { await backend.setCropAutomaticNoResult(outcome == "unchanged" ? .unchanged : .noHorizon) }
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            let context = try await cropReady(editing, asset: fixture.assets[0]), original = editing.recipe
            var writes = 0; let observer = editing.$recipe.dropFirst().sink { _ in writes += 1 }
            editing.requestDevelopmentCropAutomatic(context: context); await localFinished(editing); observer.cancel()
            XCTAssertEqual(editing.recipe, original, outcome); XCTAssertEqual(writes, 0, outcome)
            XCTAssertFalse(editing.isDirty); XCTAssertFalse(editing.developmentSession.canUndo)
            XCTAssertEqual(editing.developmentSession.history.entryCount, 0)
            XCTAssertFalse(editing.developmentCropAutomaticInProgress)
            if outcome != "wrongEnvelope" { XCTAssertTrue(editing.message?.contains("未更改裁切") == true) }
            await editing.shutdown()
        }
    }
    @MainActor func testCropAutomaticBlockedChildCancellationJoinsWithoutUndoingHistoryOrAcceptingLateResult() async throws {
        _ = NSApplication.shared
        for action in ["menuEmpty", "keyboardEmpty", "menu", "keyboard", "original", "comparison", "tracking", "constraint", "focus", "branch", "source", "close"] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(cropAutomaticEnabled: true)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            let context = try await cropReady(editing, asset: fixture.assets[0])
            if !action.hasSuffix("Empty") {
                try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.25))),
                    event: .init(context: context, control: .init(group: .light, name: "prior history")))
            }
            await currentCropPreview(editing)
            let before = editing.recipe, count = editing.developmentSession.history.entryCount
            let gate = PhotosAnalysisGate(); await backend.setGate(gate)
            editing.requestDevelopmentCropAutomatic(context: context); await gate.waitUntilEntered()
            let requests = await backend.userRequests; XCTAssertEqual(requests.count, 1, action)
            var token: EditingGestureToken?
            switch action {
            case "menu", "menuEmpty": editing.undoDevelopment(context: context)
            case "keyboard", "keyboardEmpty":
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
                XCTAssertTrue(editing.handleDevelopmentKey(event))
            case "original": editing.setDevelopmentOriginalHeld(true)
            case "comparison": editing.setComparisonMode(.wipeHorizontal)
            case "tracking": token = try editing.developmentSession.beginGesture(.init(group: nil, name: "crop"), context: context)
            case "constraint":
                var constraint = editing.developmentSession.cropConstraint; constraint.customWidth = 6
                try editing.developmentSession.setCropConstraint(constraint, context: context)
            case "focus": editing.suspendDevelopmentFocus()
            case "branch": editing.selectVersion(try XCTUnwrap(editing.versions.first { $0.kind == .original }), continueEditing: true)
            case "source": editing.focus(fixture.assets[1])
            default: editing.endDevelopmentInterface()
            }
            await gate.waitUntilCancelled()
            XCTAssertTrue(editing.developmentAnalysisBusy, action)
            XCTAssertTrue(editing.developmentCropAutomaticInProgress, action)
            if ["menuEmpty", "keyboardEmpty", "menu", "keyboard", "original", "comparison", "tracking", "constraint"].contains(action) {
                XCTAssertEqual(editing.recipe, before, action)
                XCTAssertEqual(editing.developmentSession.history.entryCount, count, action)
                editing.requestDevelopmentCropAutomatic(context: context)
                let stillOne = await backend.userRequests; XCTAssertEqual(stillOne.count, 1, "No new request before actual child join: \(action)")
            }
            await gate.release(); await localFinished(editing)
            XCTAssertFalse(editing.developmentCropAutomaticInProgress, action)
            XCTAssertEqual(editing.developmentGeometry.straightenDegrees, 0, action)
            if let token { try editing.developmentSession.endGesture(token, .cancel) }
            if ["menuEmpty", "keyboardEmpty", "menu", "keyboard", "original", "comparison", "constraint"].contains(action) { XCTAssertEqual(editing.recipe, before, action) }
            await editing.shutdown()
        }
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testCropAutomaticSharedBackendEarlyCancellationKeepsControllerBusyUntilActualServiceWorkerReturns() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), source = fixture.root.appendingPathComponent("worker-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("actual-worker-source.png")
        try bytes.write(to: file)
        let workerSession = try await ImportService(store: fixture.store).importDirectory(source: source, destination: nil,
            projectName: "Actual worker", mode: .reference, initialScreening: false, progress: { _ in })
        let asset = try XCTUnwrap(fixture.store.loadAssets().first { $0.sessionID == workerSession.id })
        let gate = CropAutoNativeWorkerGate(); defer { gate.release.signal() }
        let service = DevelopmentPreviewService(analysisOverride: { request, source in
            guard request.operation == .cropAutomatic else { throw DevelopmentV3Error.unsupportedAnalysis }
            gate.entered.fulfill(); gate.release.wait()
            let binding = DevelopmentAnalysisBinding(sourceContentID: source.sourceContentID,
                sourceGeneration: request.preview.sourceGeneration, expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage)
            let resolved = DevelopmentResolvedGeometryV1(binding: binding, source: source,
                presentedRecipeFingerprint: request.presentedRecipeFingerprint, input: try XCTUnwrap(request.cropAutoInputV1), resolution: .noResult(.noHorizon))
            return .init(operationID: request.operationID, sessionID: request.preview.sessionID, consumerID: request.preview.consumerID,
                revision: request.preview.revision, role: request.preview.role, quality: request.preview.quality, actualRecipe: request.preview.recipe,
                clientCorrelation: request.preview.clientCorrelation, binding: binding, sourceBinding: source,
                presentedRecipeFingerprint: request.presentedRecipeFingerprint, roi: request.roi,
                samplingRecipeFingerprint: try EditingFingerprint.of(DevelopmentAnalysisEngine.samplingRecipe(request)),
                samplingVersion: try DevelopmentAnalysisEngine.validatedSamplingVersion(request),
                geometryMapping: try request.preview.recipe.adjustmentsV3!.geometry.mapping(sourceSize: source.sourceSize), value: .geometry(resolved))
        }, renderOverride: { _, _ in
            .init(image: NSImage(size: .init(width: 320, height: 256)), nativeSize: .init(width: 320, height: 256),
                outputSize: .init(width: 320, height: 256), bytes: 320 * 256 * 4)
        })
        let joinEntered = expectation(description: "App reached actual captured-operation Service join after early cancellation delivery")
        let backend = CropAutoActualJoinWitnessBackend(service: service, joinEntered: joinEntered)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: backend)
        let context = try await cropReady(editing, asset: asset), before = editing.recipe
        XCTAssertNil(editing.developmentCropAutomaticUnavailableReason)
        editing.requestDevelopmentCropAutomatic(context: context)
        await fulfillment(of: [gate.entered], timeout: 5)
        // The witness only observes entry into the real Shared adapter join. It does not hold
        // a Task or synthesize completion; only Service's synchronous native override is blocked.
        editing.cancelDevelopmentCropAutomatic(context: context)
        await fulfillment(of: [joinEntered], timeout: 5)
        let held = await service.statistics(), heldAnalysis = await service.analysisStatistics()
        XCTAssertEqual(held.activeNativeRenders, 1); XCTAssertEqual(heldAnalysis.active, 1)
        XCTAssertTrue(editing.developmentAnalysisBusy); XCTAssertTrue(editing.developmentCropAutomaticCancelling)
        XCTAssertEqual(editing.recipe, before); XCTAssertFalse(editing.developmentSession.canUndo)
        editing.requestDevelopmentCropAutomatic(context: context)
        gate.release.signal(); await localFinished(editing)
        let joined = await service.analysisStatistics()
        XCTAssertEqual(joined.active, 0); XCTAssertEqual(joined.maximumActive, 1)
        XCTAssertFalse(editing.developmentCropAutomaticInProgress); XCTAssertEqual(editing.recipe, before)
        await editing.shutdown(); await service.closeAll()
        let closed = await service.statistics(); XCTAssertEqual(closed.activeNativeRenders, 0); XCTAssertEqual(closed.pendingRequests, 0)
    }
}

/// Observes the real product adapter boundary without delaying or replacing any operation.
private actor CropAutoActualJoinWitnessBackend: EditingPreviewBackend {
    let shared: SharedEditingPreviewBackend
    let joinEntered: XCTestExpectation
    init(service: DevelopmentPreviewService, joinEntered: XCTestExpectation) {
        shared = .init(service: service); self.joinEntered = joinEntered
    }
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { try await shared.open(source) }
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap { try await shared.render(request) }
    func cancel(_ consumer: PreviewConsumerID) async { await shared.cancel(consumer) }
    func cancelAndJoin(_ consumer: PreviewConsumerID) async { await shared.cancelAndJoin(consumer) }
    func close(_ lease: DevelopmentPreviewSessionID) async { await shared.close(lease) }
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { try await shared.revalidate(lease, source: source) }
    func sourceFacts(_ lease: EditingPreviewLease) async throws -> DevelopmentSourceFacts { try await shared.sourceFacts(lease) }
    func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult { try await shared.analyze(request) }
    func joinAnalysis(_ request: DevelopmentAnalysisRequest) async {
        joinEntered.fulfill()
        await shared.joinAnalysis(request)
    }
    func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel {
        try await shared.makeProgressChannel(lease, consumer: consumer)
    }
    func closeProgressChannel(_ id: PreviewProgressChannelID) async { await shared.closeProgressChannel(id) }
}

private final class CropAutoNativeWorkerGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "actual Service detached analysis worker entered")
    let release = DispatchSemaphore(value: 0)
}


extension PhotosDevelopmentIntegrationTests {
    @MainActor func testSaveJoinsHeldMetadataHistogramAndThumbnailOwnersBeforeRealPNG() async throws {
        // Metadata needs an inactive context; histogram/thumbnails require an active one.
        // Separate fixtures preserve those real admission rules instead of fabricating concurrency.
        for (resource, failSave) in [("metadata", false), ("histogram", false), ("thumbnail", false), ("histogram", true)] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let backend = PhotosDevelopmentBackend(), gate = PhotosAnalysisGate(), starts = PhotosSaveStartCounter()
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            try await ready(editing, asset: fixture.assets[0])
            if resource == "metadata" {
                await backend.setFactsGate(gate)
                editing.beginDevelopmentInterface()
            } else {
                let context = try await activate(editing)
                await settled(editing)
                for _ in 0..<1000 { if editing.developmentHistogram != nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
                XCTAssertNotNil(editing.developmentHistogram)
                if resource == "thumbnail" {
                    await backend.setThumbnailGate(gate)
                    editing.developmentThumbnails.setVisible(.summary(.color), true, context: context)
                } else {
                    await backend.setDisplayGate(gate)
                    try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.2))),
                        event: .init(context: context, control: .init(group: .light, name: "Save histogram fixture")))
                }
            }
            await gate.waitUntilEntered()
            let factsBefore = await backend.factsRequests, displayBefore = await backend.displayRequests.count
            let thumbnailBefore = await backend.thumbnailRequests.count
            let original = try XCTUnwrap(editing.work?.originalVersionID), frozen = editing.recipe
            let contextBefore = editing.developmentContext, historyCount = editing.developmentSession.history.entryCount
            editing.developmentSaveRenderWillBeginHook = {
                let released = await gate.hasReleased
                XCTAssertTrue(released, "Save must join the held \(resource) owner, not only cancel it")
                if resource == "thumbnail" {
                    let joins = await backend.thumbnailJoins
                    XCTAssertEqual(joins, 1, "The actual old thumbnail driver completed its join")
                } else if resource == "histogram" {
                    let returned = await backend.displayReturned
                    XCTAssertEqual(returned, displayBefore)
                } else {
                    let returned = await backend.factsReturned
                    XCTAssertEqual(returned, factsBefore)
                }
                await starts.begin()
                if failSave { throw NSError(domain: "SaveHandoffExpectedFailure", code: 1) }
            }
            editing.saveDevelopment()
            await gate.waitUntilCancelled()
            editing.requestPreview(); editing.prepareDevelopmentSessionIfNeeded(); editing.developmentThumbnails.refresh()
            let calls = await starts.count
            XCTAssertEqual(calls, 0); XCTAssertTrue(editing.saving)
            XCTAssertEqual(editing.developmentContext, contextBefore, "Own retirement must not invalidate the frozen Save ticket")
            let factsHeld = await backend.factsRequests, displaysHeld = await backend.displayRequests.count
            let thumbnailsHeld = await backend.thumbnailRequests.count
            XCTAssertEqual(factsHeld, factsBefore); XCTAssertEqual(displaysHeld, displayBefore); XCTAssertEqual(thumbnailsHeld, thumbnailBefore)
            await gate.release()
            for _ in 0..<1000 { if !editing.saving { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertFalse(editing.saving)
            let count = await starts.count; XCTAssertEqual(count, 1)
            XCTAssertEqual(editing.selectedVersion?.kind, failSave ? .original : .development)
            if !failSave { XCTAssertEqual(editing.selectedVersion?.recipe, frozen) }
            XCTAssertEqual(editing.recipe, frozen); XCTAssertEqual(editing.work?.adoptedVersionID, original)
            for _ in 0..<1000 {
                if let current = editing.developmentContext, current != contextBefore,
                   current.sourceGeneration == editing.previews.primary.currentSourceGeneration { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let current = try XCTUnwrap(editing.developmentContext)
            XCTAssertNotEqual(current, contextBefore)
            XCTAssertEqual(current.sourceGeneration, editing.previews.primary.currentSourceGeneration)
            XCTAssertEqual(editing.developmentSession.history.entryCount, historyCount)
            if let old = contextBefore {
                XCTAssertEqual(current.draftBranchID, old.draftBranchID)
                XCTAssertThrowsError(try editing.developmentSession.apply(.setEnabled(.light, true),
                    event: .init(context: old, control: .init(group: .light, name: "retired lease"))))
            }
            try editing.developmentSession.apply(.setParameters(.light(.init(enabled: true, brilliance: 0.25))),
                event: .init(context: current, control: .init(group: .light, name: "after Save")))
            let changed = editing.recipe
            editing.undoDevelopment(context: current); XCTAssertEqual(editing.recipe, frozen)
            editing.undoDevelopment(context: current, redo: true); XCTAssertEqual(editing.recipe, changed)
            await editing.shutdown()
        }
    }
}
actor PhotosSaveStartCounter {
    private(set) var count = 0
    func begin() { count += 1 }
}


extension PhotosDevelopmentIntegrationTests {
    @MainActor func testCanonicalGestureEarlyFrameEndResumesCurrentHistogramAndVisibleThumbnails() async throws {
        let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
        let backend=PhotosDevelopmentBackend(canonicalGesture:true)
        let editing=try EditingController(store:fixture.store,libraryURL:fixture.library,defaults:fixture.defaults,previewBackend:backend)
        do {
            try await ready(editing,asset:fixture.assets[0]);let context=try await activate(editing)
            await settled(editing)
            let token=try editing.developmentSession.beginGesture(.init(group:.color,name:"颜色 · 饱和度"),context:context)
            try editing.developmentSession.apply(.setParameters(.color(.init(enabled:true,saturation:0.2))),
                event:.init(context:context,control:.init(group:.color,name:"颜色 · 饱和度")),gesture:token)
            await settled(editing)
            let frame=try XCTUnwrap(editing.previews.primary.frame)
            XCTAssertEqual(frame.quality,.settled);XCTAssertTrue(editing.previewInteracting)
            XCTAssertTrue(editing.previews.primary.canonicalGestureRequestActive)
            editing.developmentThumbnails.setVisible(.summary(.color),true,context:context)
            let beforeRenders=await backend.renderRequests.count
            let beforeThumbs=await backend.thumbnailRequests.count
            let beforeHist=await backend.displayRequests.filter{$0.preview.revision == frame.revision}.count
            XCTAssertEqual(beforeHist,0)
            try editing.developmentSession.endGesture(token,.commit)
            XCTAssertNil(editing.developmentSession.activeGesture);XCTAssertFalse(editing.previewInteracting)
            for _ in 0..<500 {
                let hist=await backend.displayRequests.contains{$0.preview.revision == frame.revision}
                let thumbs=await backend.thumbnailRequests.contains{$0.preview.revision == frame.revision}
                if hist && thumbs {break};try await Task.sleep(nanoseconds:5_000_000)
            }
            let hist=await backend.displayRequests.filter{$0.preview.revision == frame.revision}
            let thumbs=await backend.thumbnailRequests.filter{$0.preview.revision == frame.revision}
            XCTAssertEqual(hist.count,1);XCTAssertEqual(thumbs.count,1)
            XCTAssertEqual(hist.first?.preview.recipe,editing.recipe);XCTAssertEqual(thumbs.first?.preview.recipe,editing.recipe)
            let afterRenders=await backend.renderRequests.count,afterThumbs=await backend.thumbnailRequests.count
            XCTAssertEqual(afterRenders,beforeRenders,"End refresh must not rerender the main image")
            XCTAssertEqual(afterThumbs,beforeThumbs+1);XCTAssertEqual(editing.previews.primary.frame?.id,frame.id)
            let changed=editing.recipe
            editing.undoDevelopment(context:context);XCTAssertNotEqual(editing.recipe,changed)
            editing.undoDevelopment(context:context,redo:true);XCTAssertEqual(editing.recipe,changed)
        }catch {await editing.shutdown();throw error}
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testPromptDispatchValidCommitCancelsOnlyDisplayHistogramBeforeItsReturn() async throws {
        for enabled in [false, true] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let display = PhotosAnalysisGate(), user = PhotosAnalysisGate(), render = PhotosAnalysisGate()
            let backend = PhotosDevelopmentBackend(gate: user, canonicalGesture: true)
            await backend.setDisplayGate(display)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
                previewBackend: backend, promptCanonicalDispatch: enabled)
            do {
                try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
                try await promptWait { await display.didEnter }
                editing.requestDevelopmentAutomatic(.light, context: context)
                try await promptWait { await user.didEnter }
                let before = editing.recipe
                editing.setRecipe { $0 = before }
                editing.setRecipe { $0.exposureEV = .nan }
                XCTAssertEqual(editing.recipe, before)
                let unchangedCancelled = await display.didCancel; XCTAssertFalse(unchangedCancelled)
                let unchangedUserCancelled = await user.didCancel; XCTAssertFalse(unchangedUserCancelled)
                let changed = try DevelopmentRecipe().applying(.promoteToV3)
                    .applying(.setParameters(.color(.init(enabled: true, saturation: 0.2))))
                XCTAssertEqual(editing.previews.primary.supportsPromptCanonicalDispatch(changed), enabled)
                await backend.setRenderGate(render)
                editing.setRecipe { $0 = changed }
                try await promptWait { await render.didEnter }
                if enabled { try await promptWait { await display.didCancel } }
                // Existing recipe-authority invalidation already revokes stale Auto in both arms.
                // The new cancellation must not replace or weaken that independent lifecycle.
                try await promptWait { await user.didCancel }
                let displayCancelled = await display.didCancel, userCancelled = await user.didCancel
                let displayReleased = await display.hasReleased, returned = await backend.displayReturned
                XCTAssertEqual(displayCancelled, enabled)
                XCTAssertTrue(userCancelled, "The original stale-user-analysis cancellation stays identical in both arms")
                XCTAssertFalse(displayReleased); XCTAssertEqual(returned, 0)
                XCTAssertEqual(editing.recipe, changed, "New preview has entered without waiting for the old histogram result")
                await display.release(); await user.release(); await render.release()
                try await promptWait { await backend.displayRequests.count >= 2 && editing.developmentHistogram != nil }
                let lastHistogram = await backend.displayRequests.last
                XCTAssertEqual(lastHistogram?.preview.recipe, changed)
                XCTAssertEqual(editing.recipe, changed, "Late user analysis cannot replace the newer committed recipe")
            } catch {
                await display.release(); await user.release(); await render.release(); await editing.shutdown(); throw error
            }
            await display.release(); await user.release(); await render.release(); await editing.shutdown()
            XCTAssertEqual(editing.previews.primary.ownedOperationCount, 0)
        }
    }
    @MainActor func testPromptDispatchNeedsLiveSupportedCapabilityBeforeEarlyHistogramCancellation() async throws {
        for capable in [false, true] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let display = PhotosAnalysisGate(), backend = PhotosDevelopmentBackend(canonicalGesture: capable)
            await backend.setDisplayGate(display)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
                previewBackend: backend, promptCanonicalDispatch: true)
            do {
                try await ready(editing, asset: fixture.assets[0]); _ = try await activate(editing)
                try await promptWait { await display.didEnter }
                var unsupported = try DevelopmentRecipe().applying(.promoteToV3)
                    .applying(.setParameters(.color(.init(enabled: true, saturation: 0.2))))
                unsupported.adjustmentsV3?.blackAndWhite.grain = 0.3
                XCTAssertFalse(editing.previews.primary.supportsPromptCanonicalDispatch(unsupported))
                let beforeCount = await backend.renderRequests.count
                editing.setRecipe { $0 = unsupported }
                try await promptWait { await backend.renderRequests.count > beforeCount }
                let cancelled = await display.didCancel; XCTAssertFalse(cancelled)
                await display.release()
            } catch { await display.release(); await editing.shutdown(); throw error }
            await display.release(); await editing.shutdown()
        }
    }
    @MainActor private func promptWait(_ condition: () async -> Bool) async throws {
        for _ in 0..<600 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Prompt dispatch fixture timed out")
        throw PromptDispatchTestFailure.timeout
    }
}
private enum PromptDispatchTestFailure: Error { case timeout }
extension PhotosAnalysisGate {
    var didEnter: Bool { entered }
    var didCancel: Bool { cancelled }
}


extension PhotosDevelopmentIntegrationTests {
    @MainActor private func numberEditor(_ editing: EditingController, context: EditingInteractionContext,
                                        didWrite: @escaping () -> Void = {}) -> DevelopmentNumberNativeEditorFixture {
        DevelopmentNumberNativeEditorFixture(.init(value: editing.recipe.adjustmentsV3?.color.saturation ?? 0,
            range: -1...1, digits: 2, enabled: true, write: { value in
                do {
                    try editing.developmentSession.apply(.setParameters(.color(.init(enabled: true, saturation: value))),
                        event: .init(context: context, control: .init(group: .color, name: "颜色 · 饱和度数字")))
                    didWrite()
                } catch { XCTFail("A current frozen numeric setter must be admitted: \(error)") }
            }, invalid: { _ in }), owner: editing.developmentNumberInputOwner)
    }
    @MainActor private func waitForNumberSave(_ editing: EditingController) async {
        for _ in 0..<1000 { if !editing.saving { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(editing.saving)
    }
    @MainActor func testOwnedNativeNumberFlushKeepsCurrentDraftAcrossWorkAndViewNavigation() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        var hosts: [DevelopmentNumberNativeEditorFixture] = []
        do {
            try await ready(editing, asset: fixture.assets[0]); let firstContext = try await activate(editing)
            var writes = 0
            let first = numberEditor(editing, context: firstContext, didWrite: { writes += 1 }); hosts.append(first)
            _ = try first.enter("0.74"); let firstToken = try XCTUnwrap(first.coordinator.token)
            editing.focus(fixture.assets[1])
            XCTAssertEqual(writes, 1, "Focus must flush the current owner before invalidation and draft capture")
            try await ready(editing, asset: fixture.assets[1]); let secondContext = try await activate(editing)
            let untouched = editing.recipe
            XCTAssertNotEqual(firstContext.workID, secondContext.workID)
            XCTAssertEqual(first.coordinator.session.submit("0.9", markedText: false, token: firstToken), .consumed)
            editing.developmentNumberInputOwner.finishCurrentEdit()
            XCTAssertEqual(editing.recipe, untouched); XCTAssertEqual(writes, 1)
            XCTAssertThrowsError(try editing.developmentSession.apply(.setEnabled(.color, true),
                event: .init(context: firstContext, control: .init(group: .color, name: "stale numeric callback"))))
            editing.focus(fixture.assets[0])
            try await ready(editing, asset: fixture.assets[0]); let returned = try await activate(editing)
            XCTAssertEqual(editing.recipe.adjustmentsV3?.color.saturation, 0.74)
            let changed = editing.recipe
            editing.undoDevelopment(context: returned); XCTAssertNotEqual(editing.recipe, changed)
            editing.undoDevelopment(context: returned, redo: true); XCTAssertEqual(editing.recipe, changed)
            var committedBeforeBranch: Double?
            let branch = numberEditor(editing, context: returned, didWrite: {
                writes += 1; committedBeforeBranch = editing.recipe.adjustmentsV3?.color.saturation
            }); hosts.append(branch)
            _ = try branch.enter("0.35")
            let original = try XCTUnwrap(editing.versions.first(where: { $0.kind == .original }))
            editing.selectVersion(original, continueEditing: true)
            XCTAssertEqual(committedBeforeBranch, 0.35); XCTAssertEqual(writes, 2)
            XCTAssertNil(branch.coordinator.token)
            let replacement = try await activate(editing, excluding: returned.draftBranchID)
            XCTAssertThrowsError(try editing.developmentSession.apply(.setEnabled(.color, true),
                event: .init(context: returned, control: .init(group: .color, name: "replaced numeric branch"))))
            let final = numberEditor(editing, context: replacement, didWrite: { writes += 1 }); hosts.append(final)
            _ = try final.enter("0.41")
            editing.isPresented = false
            XCTAssertEqual(editing.recipe.adjustmentsV3?.color.saturation, 0.41)
            XCTAssertEqual(writes, 3); XCTAssertNil(final.coordinator.token)
            editing.developmentNumberInputOwner.finishCurrentEdit(); XCTAssertEqual(writes, 3)
        } catch { hosts.forEach { $0.close() }; await editing.shutdown(); throw error }
        hosts.forEach { $0.close() }; await editing.shutdown()
    }
    @MainActor func testOwnedNativeNumberSaveAndDraftExportFreezeSubmittedValueExactlyOnce() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        var hosts: [DevelopmentNumberNativeEditorFixture] = []
        do {
            try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
            let original = try XCTUnwrap(editing.work?.originalVersionID)
            var writes = 0
            let editor = numberEditor(editing, context: context, didWrite: { writes += 1 }); hosts.append(editor)
            _ = try editor.enter("0.74")
            editing.saveDevelopment(context: context)
            XCTAssertTrue(editing.saving); XCTAssertEqual(writes, 1)
            XCTAssertEqual(editing.recipe.adjustmentsV3?.color.saturation, 0.74)
            await waitForNumberSave(editing)
            XCTAssertEqual(editing.selectedVersion?.kind, .development)
            XCTAssertEqual(editing.selectedVersion?.recipe.adjustmentsV3?.color.saturation, 0.74)
            XCTAssertNotNil(editing.selectedVersion?.artifact)
            XCTAssertEqual(editing.work?.adoptedVersionID, original)
            for _ in 0..<1000 {
                if let now = editing.developmentContext,
                   now.sourceGeneration == editing.previews.primary.currentSourceGeneration { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let current = try XCTUnwrap(editing.developmentContext)
            let exportEditor = numberEditor(editing, context: current, didWrite: { writes += 1 }); hosts.append(exportEditor)
            _ = try exportEditor.enter("0.62")
            editing.openExport()
            XCTAssertEqual(writes, 2)
            XCTAssertTrue(editing.showExport); XCTAssertFalse(editing.saving)
            XCTAssertEqual(editing.exportVersion?.recipe.adjustmentsV3?.color.saturation, 0.62)
            XCTAssertEqual(editing.versions.count, 2)
            XCTAssertEqual(editing.work?.adoptedVersionID, original)
            editing.developmentNumberInputOwner.finishCurrentEdit(); XCTAssertEqual(writes, 2)
        } catch { hosts.forEach { $0.close() }; await editing.shutdown(); throw error }
        hosts.forEach { $0.close() }; await editing.shutdown()
    }
    @MainActor func testOwnedNativeNumberInvalidationAndReentrantSaveCannotWriteOrSaveNewOwner() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend())
        var hosts: [DevelopmentNumberNativeEditorFixture] = []
        do {
            try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
            let initial = editing.recipe
            var writes = 0
            let invalidated = numberEditor(editing, context: context, didWrite: { writes += 1 }); hosts.append(invalidated)
            _ = try invalidated.enter("0.74")
            editing.retryPreview() // Actual source/context invalidation cancels, rather than submits.
            editing.developmentNumberInputOwner.finishCurrentEdit()
            XCTAssertTrue(invalidated.window.makeFirstResponder(invalidated.other))
            XCTAssertEqual(writes, 0); XCTAssertEqual(editing.recipe, initial)
            await settled(editing); let fresh = try await activate(editing)
            let reentrant = numberEditor(editing, context: fresh, didWrite: {
                writes += 1; editing.focus(fixture.assets[1])
            }); hosts.append(reentrant)
            _ = try reentrant.enter("0.74")
            editing.saveDevelopment(context: fresh)
            XCTAssertEqual(writes, 1); XCTAssertFalse(editing.saving)
            try await ready(editing, asset: fixture.assets[1]); let next = try await activate(editing)
            XCTAssertEqual(editing.versions.count, 1, "No Save may be captured against the new focus after reentrant invalidation")
            XCTAssertEqual(editing.selectedVersion?.kind, .original)
            let terminated = numberEditor(editing, context: next, didWrite: { writes += 1 }); hosts.append(terminated)
            _ = try terminated.enter("0.62")
            let beforeShutdown = editing.recipe
            await editing.shutdown()
            XCTAssertEqual(writes, 1); XCTAssertEqual(editing.recipe, beforeShutdown)
            XCTAssertTrue(terminated.window.makeFirstResponder(terminated.other)); XCTAssertEqual(writes, 1)
        } catch { hosts.forEach { $0.close() }; await editing.shutdown(); throw error }
        hosts.forEach { $0.close() }; await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testFilterFavoritesPersistAndKeepStableDisplayOrder() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(filtersEnabled: true)
        var editing: EditingController? = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing!, asset: fixture.assets[0]); _ = try await activate(editing!)
        editing!.toggleDevelopmentFilterFavorite(.vivid)
        XCTAssertTrue(editing!.favoriteDevelopmentFilters.contains(.vivid))
        XCTAssertEqual(editing!.displayDevelopmentFilters.first, .vivid)
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "editing.filterFavorites.v1"), ["vivid"])
        await editing!.shutdown(); editing = nil
        let restored = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend(filtersEnabled: true))
        XCTAssertEqual(restored.favoriteDevelopmentFilters, [.vivid])
        await restored.shutdown()
    }

    @MainActor func testFilterHoverUsesIndependentConsumerAndNeverCommitsRecipeOrHistory() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(filtersEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let before = editing.recipe, undo = editing.developmentSession.canUndo
        editing.previewDevelopmentFilter(.vivid, context: context)
        for _ in 0..<200 {
            if editing.filterHoverFrame != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(editing.filterHoverFrame)
        XCTAssertEqual(editing.recipe, before); XCTAssertEqual(editing.developmentSession.canUndo, undo)
        let requests = await backend.renderRequests
        let hover = try XCTUnwrap(requests.last(where: { $0.recipe.adjustmentsV3?.filter.selection == .vivid }))
        XCTAssertNotEqual(hover.consumerID, editing.previews.primary.consumerID)
        XCTAssertEqual(hover.quality, .interactive)
        editing.cancelDevelopmentFilterHover()
        XCTAssertNil(editing.filterHoverFrame); XCTAssertNil(editing.hoveredDevelopmentFilter)
        XCTAssertEqual(editing.recipe, before); XCTAssertEqual(editing.developmentSession.canUndo, undo)
        await editing.shutdown()
    }

    @MainActor func testFilterHoverCrossingAndLateFrameCannotOverrideCommittedPresentation() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(filtersEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0]); let context = try await activate(editing)
        let committed = editing.recipe, history = editing.developmentSession.history.entryCount
        editing.previewDevelopmentFilter(.vivid, context: context)
        for _ in 0..<200 where editing.filterHoverFrame == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let vivid = try XCTUnwrap(editing.filterHoverFrame)
        editing.previewDevelopmentFilter(.noir, context: context)
        for _ in 0..<200 where editing.filterHoverFrame == nil || editing.filterHoverFrame?.revision == vivid.revision { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(editing.hoveredDevelopmentFilter, .noir)
        XCTAssertGreaterThan(try XCTUnwrap(editing.filterHoverFrame).revision, vivid.revision)
        XCTAssertEqual(editing.recipe, committed); XCTAssertEqual(editing.developmentSession.history.entryCount, history)
        let gate = PhotosAnalysisGate(); await backend.setRenderGate(gate)
        editing.previewDevelopmentFilter(.vividWarm, context: context); await gate.waitUntilEntered()
        editing.setComparisonMode(.wipeHorizontal)
        XCTAssertNil(editing.filterHoverFrame); XCTAssertNil(editing.hoveredDevelopmentFilter)
        await gate.release()
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(editing.filterHoverFrame); XCTAssertTrue(editing.comparing)
        XCTAssertEqual(editing.recipe, committed); XCTAssertEqual(editing.developmentSession.history.entryCount, history)
        await editing.shutdown()
    }

    @MainActor func testFilterFavoritesIgnoreCorruptUnknownAndOriginalIDs() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        fixture.defaults.set(["broken", "vivid", "original", "noir"], forKey: "editing.filterFavorites.v1")
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: PhotosDevelopmentBackend(filtersEnabled: true))
        XCTAssertEqual(editing.favoriteDevelopmentFilters, [.vivid, .noir])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "editing.filterFavorites.v1"), ["noir", "vivid"])
        await editing.shutdown()
    }

    @MainActor func testActualFilterThumbnailContentKeySkipsFilterOnlyAndRetainsImagesThroughColorChanges() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0,
            interactiveEvaluation: .proxyV1))
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: SharedEditingPreviewBackend(service: service))
        editing.isPresented = true
        try await ready(editing, asset: fixture.assets[0], timeout: .seconds(20)); var context = try await activate(editing)
        let expectedFilters = DevelopmentPhotoFilterV3.allCases
        XCTAssertEqual(editing.availableDevelopmentFilters, expectedFilters)
        let owner = editing.developmentThumbnails, id = DevelopmentThumbnailKind.filters.presentationKey
        owner.setVisible(.filters, true, context: context)
        let initialDeadline = ContinuousClock.now + .seconds(30)
        while owner.sets[id] == nil, ContinuousClock.now < initialDeadline {
            // A late source reload can replace the activation context; re-attach the strip to it.
            if let live = editing.developmentContext, live != context {
                context = live
                owner.setVisible(.filters, true, context: live)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Test-owned images would keep their presentation lease alive through the shutdown check.
        let firstKey = try {
            let first = try XCTUnwrap(owner.sets[id], owner.errors[id] ?? "Expected complete classic thumbnail set")
            XCTAssertEqual(first.images.count, DevelopmentThumbnailKind.filters.count)
            XCTAssertEqual(first.images.count, expectedFilters.filter { !$0.isSpektrafilm }.count)
            return first.key
        }()
        let initialCompleted = await service.thumbnailStatistics().completed
        try editing.changeDevelopmentFilter(.vivid, context: context)
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(owner.sets[id]?.key, firstKey)
        let selectionCompleted = await service.thumbnailStatistics().completed
        XCTAssertEqual(selectionCompleted, initialCompleted, "Filter selection must not rebuild candidates")
        var blankFrames = 0
        for step in 1...8 {
            var color = DevelopmentColorV3(); color.enabled = true; color.saturation = Double(step) * 0.03
            try editing.developmentSession.apply(.setParameters(.color(color)),
                event: .init(context: context, control: .init(group: .color, name: "饱和度")))
            for _ in 0..<20 {
                if owner.sets[id] == nil { blankFrames += 1 }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        for _ in 0..<3000 where owner.sets[id]?.key == firstKey || owner.isRefreshing(.filters) {
            if owner.sets[id] == nil { blankFrames += 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(owner.sets[id]?.key, firstKey)
        XCTAssertEqual(owner.sets[id]?.images.count, DevelopmentThumbnailKind.filters.count)
        XCTAssertEqual(owner.sets[id]?.images.count, expectedFilters.filter { !$0.isSpektrafilm }.count)
        XCTAssertEqual(blankFrames, 0)
        let changedCompleted = await service.thumbnailStatistics().completed
        XCTAssertGreaterThan(changedCompleted, initialCompleted)
        owner.invalidate()
        await editing.shutdown(); await service.closeAll()
        var finalStatistics = await service.thumbnailStatistics()
        for _ in 0..<500 where finalStatistics.unionBytes != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            finalStatistics = await service.thumbnailStatistics()
        }
        XCTAssertEqual(finalStatistics.unionBytes, 0)
    }

    @MainActor func testActualFilterSaveArchivesCanonicalRecipeAndLeavesSourceUntouched() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let service = DevelopmentPreviewService()
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: SharedEditingPreviewBackend(service: service))
        try await ready(editing, asset: fixture.assets[0], timeout: .seconds(20)); let context = try await activate(editing)
        try editing.changeDevelopmentFilter(.noir, context: context)
        let current = try XCTUnwrap(editing.work), source = current.source
        let before = try RenderFiles.hash(source.sourceLocation)
        editing.saveDevelopment(context: context)
        for _ in 0..<500 where editing.saving { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(editing.saving); XCTAssertEqual(editing.message, "已保存初修候选。采用后才会成为当前版本。")
        let saved = try XCTUnwrap(editing.versions.last(where: { $0.kind == .development }))
        XCTAssertEqual(saved.recipe.adjustmentsV3?.filter.selection, .noir)
        XCTAssertEqual(saved.recipe.adjustmentsV3?.filter.enabled, true); XCTAssertNotNil(saved.artifact)
        let persisted = try await Task.detached { try fixture.store.loadEditingVersions(workID: current.id) }.value
        XCTAssertTrue(persisted.contains(where: { $0.id == saved.id && $0.recipe == saved.recipe }))
        XCTAssertEqual(try RenderFiles.hash(source.sourceLocation), before)
        await editing.shutdown(); await service.closeAll()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testDevelopmentPresetHoverNeverCommitsOrRequestsDirectoryThumbnailsAndBlocksUnavailableSources() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(filtersEnabled: true)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        try await ready(editing, asset: fixture.assets[0])
        let context = try await activate(editing)
        let before = editing.recipe, history = editing.developmentSession.history.entryCount
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.75
        var record = DevelopmentPresetRecord(id: "native", name: "曝光", group: "个人", kind: .user, patch: patch)
        editing.previewDevelopmentPreset(record, context: context)
        for _ in 0..<200 where editing.filterHoverFrame == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(editing.filterHoverFrame)
        XCTAssertEqual(editing.hoveredPresetID, record.id)
        let thumbnails = await backend.thumbnailRequests
        let analysis = await backend.userRequests
        XCTAssertTrue(thumbnails.isEmpty)
        XCTAssertTrue(analysis.isEmpty)
        XCTAssertEqual(editing.recipe, before)
        XCTAssertEqual(editing.developmentSession.history.entryCount, history)
        record.blockingReasons = ["缺少配置文件"]
        editing.previewDevelopmentPreset(record, context: context)
        XCTAssertNil(editing.filterHoverFrame)
        XCTAssertThrowsError(try editing.developmentSession.adoptPreset(record, context: context, revision: editing.developmentSession.revision))
        await editing.shutdown()
    }
}

extension PhotosDevelopmentIntegrationTests {
    @MainActor func testSupersededLiveWriteCannotRetryOverNewerBranchAfterPhotoSwitch() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store:fixture.store, libraryURL:fixture.library, defaults:fixture.defaults,
                                           previewBackend:PhotosDevelopmentBackend())
        try await ready(editing,asset:fixture.assets[0])
        let first = try await activate(editing), work = try XCTUnwrap(editing.work)
        let alternate = try fixture.store.appendEditingVersion(.init(workID:work.id, parentVersionID:work.originalVersionID,
            kind:.development, source:work.source, recipe:editing.recipe))
        func record(_ id:String, _ ev:Double) -> DevelopmentPresetRecord {
            var patch = DevelopmentPresetPatch(); patch.exposure = ev
            return .init(id:id,name:id,group:"个人",kind:.user,patch:patch)
        }
        let entered = expectation(description:"old SQLite compare-and-swap admitted")
        let hold = PhotosAnalysisGate()
        editing.liveStateCASWillBeginHook = { id,recipe in
            if id == work.id, recipe.adjustmentsV3?.light.exposure == 0.25, !(await hold.hasReleased) {
                entered.fulfill()
                await hold.suspend()
            }
        }
        do {
            let session = editing.developmentSession
            try session.adoptPreset(record("first",0.25),context:first,revision:session.revision)
            await fulfillment(of:[entered],timeout:5)
            editing.selectVersion(alternate,continueEditing:true)
            let next = try await activate(editing,excluding:first.draftBranchID)
            try session.adoptPreset(record("last",0.75),context:next,revision:session.revision)
            let chosen = editing.recipe, receipts = session.presetAdoptions
            // This photo's newest pending write still owns its branch after focus moves on.
            editing.focus(fixture.assets[1])
            var accepted = try fixture.store.photoWork(id:work.id)
            for _ in 0..<500 where accepted.livePresetAdoptions?.first?.presetID != "last" {
                try await Task.sleep(nanoseconds:10_000_000)
                accepted = try fixture.store.photoWork(id:work.id)
            }
            XCTAssertEqual(accepted.liveParentVersionID,alternate.id)
            XCTAssertEqual(accepted.liveRecipe,chosen)
            XCTAssertEqual(accepted.livePresetAdoptions,receipts)
            XCTAssertEqual(receipts.map(\.presetID),["last"])
            // A's old CAS now loses to B. Joining every pending database attempt makes
            // the final read sensitive to an incorrect rebase/retry, even with no open UI.
            await hold.release(); await editing.shutdown()
            XCTAssertEqual(try fixture.store.photoWork(id:work.id),accepted)
        } catch {
            await hold.release(); await editing.shutdown()
            throw error
        }
    }

    @MainActor func testDevelopmentPresetAdoptionPersistsThroughRealSaveAndVerifiedDatabaseBackup() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = DevelopmentPreviewService()
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: SharedEditingPreviewBackend(service: service))
        try await ready(editing, asset: fixture.assets[0])
        let ctx = try await activate(editing), work = try XCTUnwrap(editing.work)
        let catalog = DevelopmentPresetCatalog(root: root.appendingPathComponent("presets"))
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.5
        let row = try catalog.create(name: "低反差", group: "纪实", patch: patch)
        let original = editing.recipe
        try editing.developmentSession.adoptPreset(row, context: ctx, revision: editing.developmentSession.revision)
        let baked = editing.recipe
        let receipt = try XCTUnwrap(editing.developmentSession.presetAdoptions.first)
        // All three synchronous writes occur inside one autosave debounce window.
        try editing.developmentSession.undo(context:ctx)
        XCTAssertEqual(editing.recipe,original)
        XCTAssertTrue(editing.developmentSession.presetAdoptions.isEmpty)
        try editing.developmentSession.redo(context:ctx)
        XCTAssertEqual(editing.developmentSession.presetAdoptions,[receipt])
        var persisted = try fixture.store.photoWork(id: work.id)
        for _ in 0..<500 where persisted.livePresetAdoptions?.first?.presetID != row.id {
            try await Task.sleep(nanoseconds: 10_000_000)
            persisted = try fixture.store.photoWork(id: work.id)
        }
        XCTAssertEqual(persisted.liveRecipe, baked)
        XCTAssertEqual(persisted.livePresetAdoptions?.first?.sourceID, ctx.sourceContentID)
        XCTAssertEqual(persisted.livePresetAdoptions,[receipt])
        XCTAssertEqual(receipt.baselineFingerprint,try EditingFingerprint.of(original))
        XCTAssertEqual(receipt.resultFingerprint,try EditingFingerprint.of(baked))
        editing.saveDevelopment(context: ctx)
        for _ in 0..<500 where editing.saving { try await Task.sleep(nanoseconds: 10_000_000) }
        let version = try XCTUnwrap(editing.versions.last(where: { $0.kind == .development }))
        XCTAssertEqual(version.presetAdoptions?.first?.presetID, row.id)
        XCTAssertEqual(version.presetAdoptions?.first?.version, row.version)
        XCTAssertEqual(version.presetAdoptions?.first?.fields, ["exposure"])
        XCTAssertEqual(version.presetAdoptions?.first?.resultFingerprint, try EditingFingerprint.of(baked))
        await editing.shutdown()
        let closedDraft = try LibraryStore(databaseURL:fixture.library).photoWork(id:work.id)
        XCTAssertEqual(closedDraft.liveParentVersionID,version.id)
        XCTAssertEqual(closedDraft.liveRecipe,baked)
        XCTAssertEqual(closedDraft.livePresetAdoptions,[receipt])
        try catalog.delete(row)
        let backup = root.appendingPathComponent("backup")
        _ = try fixture.store.backupEditingLibrary(to: backup)
        let restored = try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: root.appendingPathComponent("restored.sqlite"),
            archiveRoot: root.appendingPathComponent("restored-archive"))
        let frozen = try restored.editingVersion(id: version.id)
        XCTAssertEqual(frozen.recipe, baked)
        XCTAssertEqual(frozen.presetAdoptions, version.presetAdoptions)
        XCTAssertEqual(frozen.artifact?.sha256, version.artifact?.sha256)
        await service.closeAll()
    }

    @MainActor func testSaveThenImmediateCloseReopensLaterDraftOnNewParent() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store:fixture.store,libraryURL:fixture.library,defaults:fixture.defaults,
                                           previewBackend:PhotosDevelopmentBackend())
        try await ready(editing,asset:fixture.assets[0])
        let context = try await activate(editing), work = try XCTUnwrap(editing.work)
        var patch = DevelopmentPresetPatch(); patch.exposure = 0.35
        let preset = DevelopmentPresetRecord(id:"during-save",name:"柔光",group:"个人",kind:.user,patch:patch)
        try editing.developmentSession.adoptPreset(preset,context:context,revision:editing.developmentSession.revision)
        let frozen = editing.recipe, receipts = editing.developmentSession.presetAdoptions
        let hold = PhotosAnalysisGate(), entered = expectation(description:"immutable candidate render started")
        editing.developmentSaveRenderWillBeginHook = { entered.fulfill(); await hold.suspend() }
        editing.saveDevelopment(context:context)
        await fulfillment(of:[entered],timeout:10)
        editing.setRecipe(control:"color.saturation",nativeEvent:true) { $0.adjustmentsV3?.color = .init(enabled:true,saturation:0.2) }
        let later = editing.recipe
        XCTAssertNotEqual(later,frozen)
        await hold.release()
        for _ in 0..<1000 where editing.saving { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertFalse(editing.saving)
        let version = try XCTUnwrap(editing.selectedVersion)
        XCTAssertEqual(version.kind,.development)
        XCTAssertEqual(version.recipe,frozen)
        XCTAssertEqual(version.presetAdoptions,receipts)
        await editing.shutdown()
        let reopenedStore = try LibraryStore(databaseURL:fixture.library)
        let persisted = try reopenedStore.photoWork(id:work.id)
        XCTAssertEqual(persisted.liveParentVersionID,version.id)
        XCTAssertEqual(persisted.liveRecipe,later)
        XCTAssertEqual(persisted.livePresetAdoptions,receipts)
        let reopened = try EditingController(store:reopenedStore,libraryURL:fixture.library,defaults:fixture.defaults,
                                             previewBackend:PhotosDevelopmentBackend())
        try await ready(reopened,asset:fixture.assets[0])
        _ = try await activate(reopened)
        XCTAssertEqual(reopened.draftParentID,version.id)
        XCTAssertEqual(reopened.recipe,later)
        XCTAssertEqual(reopened.developmentSession.presetAdoptions,receipts)
        await reopened.shutdown()
    }
}
