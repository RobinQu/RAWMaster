import AppKit
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class ImmersiveEditingWorkflowTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for immersive editing state")
    }

    @MainActor func testCompleteDevelopmentSavesCandidateBeforeLeavingWithoutAdoptionOrDuplicate() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let original = try Data(contentsOf: fixture.assets[0].resolvedURL)
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.isPresented = true
        controller.focus(fixture.assets[0])
        try await wait { controller.work != nil }
        let work = try XCTUnwrap(controller.work)
        controller.setRecipe { $0.exposureEV = 0.5 }
        controller.completeDevelopment()
        try await wait { !controller.isPresented }
        let versions = try fixture.store.loadEditingVersions(workID: work.id)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.first(where: { $0.kind == .development })?.recipe.exposureEV, 0.5)
        XCTAssertEqual(try fixture.store.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
        XCTAssertEqual(try Data(contentsOf: fixture.assets[0].resolvedURL), original)

        controller.isPresented = true
        controller.focus(fixture.assets[0])
        try await wait { controller.work != nil }
        XCTAssertFalse(controller.isDirty)
        controller.completeDevelopment()
        try await wait { !controller.isPresented }
        XCTAssertEqual(try fixture.store.loadEditingVersions(workID: work.id).count, 2,
            "Completing an unchanged photo must not create a duplicate version")
        await controller.shutdown()
    }

    @MainActor func testFailedCompletionKeepsEditorAndDraftOpen() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.isPresented = true
        controller.focus(fixture.assets[0])
        try await wait { controller.work != nil }
        controller.archivePublicationHook = { kind in
            if kind == .development { throw NSError(domain: NSOSStatusErrorDomain, code: -42) }
        }
        controller.setRecipe { $0.exposureEV = 0.25 }
        controller.completeDevelopment()
        try await wait { !controller.saving && controller.message?.hasPrefix("保存失败") == true }
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(controller.isDirty)
        XCTAssertEqual(controller.recipe.exposureEV, 0.25)
        await controller.shutdown()
    }

    @MainActor func testKeyboardEntryCompletionSelectionAndRangeNavigation() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0])
        model.setMode(.single)
        func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(model.handleKey(key("d", code: 2)))
        XCTAssertTrue(model.isNativeEditing)
        try await wait { model.editing?.work != nil }
        XCTAssertTrue(model.handleKey(key("\r", code: 36, modifiers: .command)))
        XCTAssertFalse(model.isNativeEditing)

        model.setMode(.grid)
        model.select(fixture.assets[0])
        XCTAssertTrue(model.handleKey(key(" ", code: 49)))
        XCTAssertFalse(model.selectedIDs.contains(fixture.assets[0].id))
        XCTAssertTrue(model.handleKey(key(" ", code: 49)))
        XCTAssertTrue(model.selectedIDs.contains(fixture.assets[0].id))
        XCTAssertTrue(model.handleKey(key("", code: 124, modifiers: .shift)))
        XCTAssertEqual(model.selectedIDs, Set(fixture.assets.map(\.id)))
        XCTAssertEqual(model.focusedID, fixture.assets[1].id)
        await model.editing?.shutdown()
    }
}
