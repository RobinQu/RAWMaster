import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class EditingSnapshotTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for editing snapshot fixture")
        throw CancellationError()
    }

    @MainActor func testNamedSnapshotRestoresAsUndoableHistoryState() async throws {
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
        let session = editing.developmentSession
        let context = try XCTUnwrap(editing.developmentContext)
        let original = session.recipe

        let snapshot = try session.createSnapshot(name: "自然基底", context: context)
        XCTAssertEqual(session.snapshots.map(\.name), ["自然基底"])
        try session.renameSnapshot(id: snapshot.id, name: "柔和", context: context)
        XCTAssertEqual(session.snapshots.first?.name, "柔和")

        let exposure = try XCTUnwrap(PhotosScalarField.fields(for: .light, noiseReduction: nil).first { $0.id == "exposure" })
        let adjustment = try PhotosAdjustmentCommands.scalar(exposure, group: .light, value: 0.5,
            parameters: session.parameters, noiseReduction: nil)
        try session.apply(adjustment, event: .init(context: context,
            control: .init(group: .light, name: "调整曝光")))
        let changed = session.recipe
        XCTAssertNotEqual(changed, original)
        try session.restoreSnapshot(id: snapshot.id, context: context)
        XCTAssertEqual(session.recipe, original)
        XCTAssertEqual(session.historyItems.last?.title, "恢复快照 · 柔和")
        XCTAssertTrue(session.canUndo)

        try session.undo(context: context)
        XCTAssertEqual(session.recipe, changed)
        try session.restoreSnapshot(id: snapshot.id, context: context)
        XCTAssertEqual(session.recipe, original)
        try session.deleteSnapshot(id: snapshot.id, context: context)
        XCTAssertTrue(session.snapshots.isEmpty)
        await editing.shutdown()
    }
}
