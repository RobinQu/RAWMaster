import Foundation
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class EditingLiveWorkflowTests: XCTestCase {
    @MainActor private final class Draft {
        var recipe = DevelopmentRecipe()
    }

    @MainActor private func historyFixture() throws -> (Draft, EditingDevelopmentSession, EditingInteractionContext) {
        let draft = Draft()
        let session = EditingDevelopmentSession(readRecipe: { draft.recipe }, commitRecipe: { recipe, _ in
            draft.recipe = recipe
        })
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "a", count: 64),
            exifOrientation: 1, orientedWidth: 2400, orientedHeight: 1600)
        let context = try session.activate(workID: "work", admissionFingerprint: String(repeating: "b", count: 64),
            source: source, sourceGeneration: 1, noiseReduction: .image)
        return (draft, session, context)
    }

    @MainActor func testHistoryListRestoresInitialIntermediateAndFutureStates() throws {
        let (draft, session, context) = try historyFixture()
        func event(_ title: String, group: DevelopmentAdjustmentID) -> EditingCommandEvent {
            .init(context: context, control: .init(group: group, name: title))
        }
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.2))),
            event: event("光效 · 曝光", group: .light))
        try session.apply(.setParameters(.color(.init(enabled: true, saturation: 0.3))),
            event: event("颜色 · 饱和度", group: .color))
        XCTAssertEqual(session.historyItems.map(\.position), [-1, 0, 1])
        XCTAssertEqual(session.historyItems.filter { $0.isCurrent }.map(\.position), [1])

        try session.restoreHistory(position: 0, context: context)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.light.exposure, 0.2)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.color.saturation ?? 0, 0)
        XCTAssertTrue(session.canUndo); XCTAssertTrue(session.canRedo)

        try session.restoreHistory(position: -1, context: context)
        XCTAssertEqual(draft.recipe, DevelopmentRecipe())
        XCTAssertFalse(session.canUndo); XCTAssertTrue(session.canRedo)

        try session.redo(context: context)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.light.exposure, 0.2)
        try session.restoreHistory(position: 1, context: context)
        XCTAssertEqual(draft.recipe.adjustmentsV3?.color.saturation, 0.3)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor func testHistoryRestoreStartsANewBranchAndRejectsStalePhotoContext() throws {
        let (draft, session, context) = try historyFixture()
        func event(_ title: String, group: DevelopmentAdjustmentID) -> EditingCommandEvent {
            .init(context: context, control: .init(group: group, name: title))
        }
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.2))),
            event: event("光效 · 曝光", group: .light))
        try session.apply(.setParameters(.light(.init(enabled: true, exposure: 0.4))),
            event: event("光效 · 再次曝光", group: .light))
        try session.restoreHistory(position: -1, context: context)
        try session.apply(.setParameters(.color(.init(enabled: true, saturation: 0.4))),
            event: event("颜色 · 饱和度", group: .color))
        XCTAssertEqual(session.history.entryCount, 1)
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(session.historyItems.map(\.position), [-1, 0])

        let fresh = try session.activate(workID: "work", admissionFingerprint: context.admissionFingerprint,
            source: try XCTUnwrap(session.source), sourceGeneration: 2,
            branchID: context.draftBranchID, noiseReduction: .image)
        let unchanged = draft.recipe
        XCTAssertThrowsError(try session.restoreHistory(position: 0, context: context))
        XCTAssertEqual(draft.recipe, unchanged)
        try session.undo(context: fresh)
        XCTAssertEqual(draft.recipe, DevelopmentRecipe())
    }

    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for live editing state", file: file, line: line)
    }

    @MainActor func testLiveEditSurvivesImmediatePhotoSwitchAndControllerReopenWithoutSaveAction() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0])
        try await wait { controller.work != nil }
        let workID = try XCTUnwrap(controller.work).id

        controller.setRecipe { $0.exposureEV = 0.75 }
        controller.openExport()
        XCTAssertTrue(controller.showExport)
        XCTAssertEqual(controller.exportVersion?.recipe.exposureEV, 0.75)
        controller.showExport = false

        // Deliberately navigate before the coalescing delay. The frozen write must still finish.
        controller.focus(fixture.assets[1])
        try await wait { controller.work?.source.assetID == fixture.assets[1].id }
        try await wait {
            (try? fixture.store.photoWork(id: workID).liveRecipe?.exposureEV) == 0.75
        }
        controller.focus(fixture.assets[0])
        try await wait { controller.work?.source.assetID == fixture.assets[0].id }
        XCTAssertEqual(controller.recipe.exposureEV, 0.75)
        XCTAssertFalse(controller.isDirty)
        await controller.shutdown()

        let reopened = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        reopened.focus(fixture.assets[0])
        try await wait { reopened.work != nil }
        XCTAssertEqual(reopened.recipe.exposureEV, 0.75)
        XCTAssertFalse(reopened.isDirty)
        XCTAssertEqual(reopened.work?.adoptedVersionID, reopened.work?.originalVersionID)
        XCTAssertEqual(try fixture.store.loadEditingVersions(workID: workID).count, 1)
        await reopened.shutdown()
    }

    @MainActor func testShutdownJoinsTheLastCoalescedLiveMetadataWrite() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0])
        try await wait { controller.work != nil }
        let workID = try XCTUnwrap(controller.work).id
        controller.setRecipe { $0.exposureEV = 0.9 }
        await controller.shutdown()
        XCTAssertEqual(try fixture.store.photoWork(id: workID).liveRecipe?.exposureEV, 0.9)
        XCTAssertEqual(try fixture.store.loadEditingVersions(workID: workID).count, 1)
    }
}
