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
        var context = try XCTUnwrap(editing.developmentContext)
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
        let historyBeforeHover = session.history.entryCount
        editing.previewDevelopmentSnapshot(id: snapshot.id, context: context)
        try await wait { editing.filterHoverFrame != nil }
        XCTAssertEqual(session.recipe, changed)
        XCTAssertEqual(session.history.entryCount, historyBeforeHover)

        editing.suspendDevelopmentFocus()
        editing.suspendDevelopmentFocus()
        let presentation = try XCTUnwrap(editing.developmentPresentationContext)
        XCTAssertNil(editing.developmentContext)
        XCTAssertNil(editing.filterHoverFrame)
        XCTAssertEqual(session.snapshots(in: presentation).map(\.name), ["柔和"])
        XCTAssertThrowsError(try session.restoreSnapshot(id: snapshot.id, context: context))
        editing.beginDevelopmentInterface()
        try await wait { editing.developmentContext != nil }
        context = try XCTUnwrap(editing.developmentContext)
        XCTAssertEqual(session.snapshots.map(\.id), [snapshot.id])
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

    @MainActor func testRenameKeepsItsSelectedRowAndBranchWhileTheWindowYieldsFocus() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editor = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        do {
            let other = try LibraryStore(databaseURL: fixture.library)
            editor.isPresented = true
            editor.focus(fixture.assets[0]); editor.beginDevelopmentInterface()
            try await wait { editor.developmentContext != nil }
            let context = try XCTUnwrap(editor.developmentContext)
            let scope = DevelopmentSnapshotScope(workID: context.workID, parentVersionID: try XCTUnwrap(editor.draftParentID), appearance: .compatibility)
            let first = try editor.developmentSession.createSnapshot(context: context)
            let second = try editor.developmentSession.createSnapshot(context: context)
            let request = try XCTUnwrap(editor.snapshotRenameRequest(for: second))
            editor.suspendDevelopmentFocus()
            XCTAssertNil(editor.developmentContext)
            for invalid in ["   ", String(repeating: "雪", count: 61)] {
                XCTAssertThrowsError(try editor.renameSnapshot(request, to: invalid)) { error in
                    guard case DevelopmentSnapshotError.invalidName = error else { return XCTFail("Unexpected error \(error)") }
                }
            }
            let fullName = String(repeating: "雪", count: 60)
            try editor.renameSnapshot(request, to: fullName)
            XCTAssertEqual(try other.developmentSnapshots(in: scope).last?.name, fullName)
            try editor.renameSnapshot(request, to: " 雪景彩色 ")
            XCTAssertEqual(try other.developmentSnapshots(in: scope).map(\.name), [first.name, "雪景彩色"])
            XCTAssertEqual(editor.developmentSession.snapshots(in: try XCTUnwrap(editor.developmentPresentationContext)).last?.name, "雪景彩色")
            _ = try other.updateDevelopmentSnapshots(in: scope, .delete(second.id))
            XCTAssertThrowsError(try editor.renameSnapshot(request, to: "已删除")) { error in
                guard case DevelopmentSnapshotError.missing = error else { return XCTFail("Unexpected error \(error)") }
            }
            let stale = try XCTUnwrap(editor.snapshotRenameRequest(for: first))
            editor.focus(fixture.assets[1]); editor.beginDevelopmentInterface()
            try await wait { editor.developmentContext?.workID != nil && editor.developmentContext?.workID != context.workID }
            XCTAssertThrowsError(try editor.renameSnapshot(stale, to: "其他照片")) { error in
                guard case DevelopmentSnapshotError.changedContext = error else { return XCTFail("Unexpected error \(error)") }
            }
            XCTAssertEqual(try other.developmentSnapshots(in: scope).map(\.name), [first.name])
        } catch { await editor.shutdown(); throw error }
        await editor.shutdown()
    }
}
