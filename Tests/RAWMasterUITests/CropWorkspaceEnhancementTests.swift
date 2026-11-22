import AppKit
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class CropWorkspaceEnhancementTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for crop workspace")
        throw CancellationError()
    }

    @MainActor func testCropToolsShareHistoryFitAndCompletionWorkflow() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend()
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
            editingPreviewBackend: backend)
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait {
            if editing.work != nil && editing.preview != nil && editing.developmentToolsPaused {
                editing.beginDevelopmentInterface()
            }
            return editing.developmentContext != nil
        }
        var context = try XCTUnwrap(editing.developmentContext)
        let renderCountBeforeCrop = await backend.renderRequests.count
        editing.changeDevelopmentPage(.crop, context: context)
        context = try XCTUnwrap(editing.developmentContext)
        XCTAssertTrue(editing.cropEditing)
        let renderCountAfterCrop = await backend.renderRequests.count
        XCTAssertEqual(renderCountAfterCrop, renderCountBeforeCrop,
            "Entering crop with unchanged pixels must rebind presentation without rendering again")
        XCTAssertNotNil(editing.developmentCropFrame(context: context),
            "Reusing the image must immediately preserve a valid crop interaction frame")

        try editing.toggleDevelopmentCropAspectLock(context: context)
        XCTAssertEqual(editing.developmentSession.cropConstraint.aspect, .custom)
        XCTAssertEqual(editing.developmentSession.cropConstraint.customHeight, 1)
        XCTAssertGreaterThan(editing.developmentSession.cropConstraint.customWidth, 0)
        try editing.swapDevelopmentCropOrientation(context: context)
        XCTAssertEqual(editing.developmentSession.cropConstraint.orientation, .portrait)

        editing.cycleDevelopmentCropOverlay()
        XCTAssertEqual(editing.cropOverlayStyle, .goldenRatio)
        editing.turnDevelopmentCropOverlay()
        XCTAssertEqual(editing.cropOverlayTurn, 1)
        try editing.rotateDevelopmentCrop(context: context, counterclockwise: true)
        XCTAssertEqual(editing.developmentGeometry.lateOrientation.orientation, .rotate270)
        XCTAssertTrue(editing.developmentSession.canUndo)

        let reset = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        XCTAssertTrue(editing.handleDevelopmentKey(reset))
        XCTAssertEqual(editing.developmentGeometry.crop, .init())
        XCTAssertEqual(editing.developmentGeometry.straightenDegrees, 0)
        XCTAssertEqual(editing.developmentGeometry.verticalPerspective, 0)
        XCTAssertEqual(editing.developmentGeometry.horizontalPerspective, 0)

        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        XCTAssertTrue(editing.handleDevelopmentKey(enter))
        XCTAssertFalse(editing.cropEditing)
        XCTAssertEqual(editing.developmentSession.page, .adjust)
        await editing.shutdown()
    }

    @MainActor func testCropCancelRestoresEntryAndDoneReturnsToPreviousPage() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
            editingPreviewBackend: PhotosDevelopmentBackend())
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait {
            if editing.work != nil && editing.preview != nil && editing.developmentToolsPaused {
                editing.beginDevelopmentInterface()
            }
            return editing.developmentContext != nil
        }
        var context = try XCTUnwrap(editing.developmentContext)
        editing.changeDevelopmentPage(.filters, context: context)
        context = try XCTUnwrap(editing.developmentContext)
        let entryRecipe = editing.recipe
        let entryConstraint = editing.developmentSession.cropConstraint

        editing.toggleDevelopmentCrop(context: context)
        context = try XCTUnwrap(editing.developmentContext)
        XCTAssertTrue(editing.cropEditing)
        try editing.toggleDevelopmentCropAspectLock(context: context)
        try editing.rotateDevelopmentCrop(context: context)
        XCTAssertNotEqual(editing.recipe, entryRecipe)
        XCTAssertNotEqual(editing.developmentSession.cropConstraint, entryConstraint)

        editing.cancelDevelopmentCrop(context: context)
        context = try XCTUnwrap(editing.developmentContext)
        XCTAssertFalse(editing.cropEditing)
        XCTAssertEqual(editing.developmentSession.page, .filters)
        XCTAssertEqual(editing.recipe, entryRecipe)
        XCTAssertEqual(editing.developmentSession.cropConstraint, entryConstraint)
        XCTAssertFalse(editing.developmentSession.canUndo)
        XCTAssertTrue(editing.developmentSession.canRedo,
            "Cancel restores the entry cursor instead of appending a synthetic reset edit")

        editing.toggleDevelopmentCrop(context: context)
        context = try XCTUnwrap(editing.developmentContext)
        try editing.rotateDevelopmentCrop(context: context, counterclockwise: true)
        let completedRecipe = editing.recipe
        editing.completeDevelopmentCrop(context: context)
        XCTAssertFalse(editing.cropEditing)
        XCTAssertEqual(editing.developmentSession.page, .filters)
        XCTAssertEqual(editing.recipe, completedRecipe)
        XCTAssertNotEqual(editing.recipe, entryRecipe)
        await editing.shutdown()
    }
}
