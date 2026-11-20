import AppKit
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
import RAWMasterImaging

/// Save keeps the existing real tiny PNG/archive path; only preview completion is controlled.
final class EditingSavePreviewHandoffTests: XCTestCase {
    @MainActor private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Save handoff did not complete", file: file, line: line)
        throw SaveHandoffFailure.timeout
    }
    @MainActor func testSaveWaitsForActualPreviewRetirementThenRestoresLatestDraft() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let backend = ControllablePreviewBackend(hold: true), probe = SaveHandoffProbe()
        let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults, previewBackend: backend)
        editing.isPresented = true; editing.focus(f.assets[0])
        try await wait { await backend.requests.count == 1 }
        await backend.finish(0); try await wait { editing.preview != nil }
        let original = try XCTUnwrap(editing.work?.originalVersionID)
        editing.setRecipe { $0.exposureEV = 0.5 }
        try await wait { await backend.requests.count == 2 }
        let frozen = editing.recipe
        editing.developmentSaveRenderWillBeginHook = {
            let count = await backend.closed.count
            try await probe.begin(closedLeases: count)
        }
        editing.saveDevelopment()
        editing.setActualPixels(true); editing.setActualPixels(false)
        editing.setRecipe { $0.exposureEV = 0.75 }; editing.requestPreview()
        await Task.yield()
        let requestedWhileSaving = await backend.requests.count, started = await probe.starts
        XCTAssertEqual(requestedWhileSaving, 2, "Fit/detail/new recipe cannot reopen a preview during Save")
        XCTAssertEqual(started, 0, "Cancelling an uncooperative preview is not a completed join")
        XCTAssertTrue(editing.saving); XCTAssertNil(editing.preview)
        await backend.finish(1)
        try await wait { !editing.saving && editing.versions.count == 2 }
        let closedAtRender = await probe.closedAtRender
        XCTAssertEqual(closedAtRender, [1], "The old source lease closes before real PNG rendering begins")
        XCTAssertEqual(editing.selectedVersion?.recipe, frozen)
        XCTAssertEqual(editing.recipe.exposureEV, 0.75)
        XCTAssertEqual(editing.work?.adoptedVersionID, original)
        try await wait { await backend.requests.count == 3 }
        let restored = await backend.requests.last
        XCTAssertEqual(restored?.recipe, editing.recipe, "Restore reads the latest draft, not the frozen saved recipe")
        await backend.finish(2); try await wait { editing.preview != nil }
        await editing.shutdown()
    }
    @MainActor func testSaveCompletionAndFailureRestoreNewFocusWithoutSelectingOldCandidate() async throws {
        for fail in [false, true] {
            let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
            let backend = ControllablePreviewBackend(hold: true), probe = SaveHandoffProbe(fail: fail)
            let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults, previewBackend: backend)
            editing.isPresented = true; editing.focus(f.assets[0])
            try await wait { await backend.requests.count == 1 }
            let oldWork = try XCTUnwrap(editing.work)
            editing.developmentSaveRenderWillBeginHook = {
                let count = await backend.closed.count
                try await probe.begin(closedLeases: count)
            }
            editing.saveDevelopment()
            editing.focus(f.assets[1])
            try await wait { editing.work?.source.assetID == f.assets[1].id }
            let newOriginal = try XCTUnwrap(editing.work?.originalVersionID)
            editing.setRecipe { $0.exposureEV = 0.9 }; editing.requestPreview()
            let before = await backend.opens
            XCTAssertEqual(before, 1)
            await backend.finish(0)
            try await wait { let count = await backend.requests.count; return !editing.saving && count == 2 }
            let restored = await backend.requests.last, opened = await backend.openedAssetIDs
            XCTAssertEqual(opened, [f.assets[0].id, f.assets[1].id])
            XCTAssertEqual(restored?.recipe.exposureEV, 0.9)
            XCTAssertEqual(editing.selectedVersionID, newOriginal)
            XCTAssertEqual(editing.work?.adoptedVersionID, newOriginal)
            let oldVersions = try f.store.loadEditingVersions(workID: oldWork.id)
            XCTAssertEqual(oldVersions.count, fail ? 1 : 2)
            XCTAssertEqual(try f.store.photoWork(id: oldWork.id).adoptedVersionID, oldWork.originalVersionID)
            await backend.finish(1); try await wait { editing.preview != nil }
            await editing.shutdown()
        }
    }
    @MainActor func testShutdownWhileSaveRetiresPreviewJoinsWithoutStartingPNGOrRestoringView() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let backend = ControllablePreviewBackend(hold: true), probe = SaveHandoffProbe()
        let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults, previewBackend: backend)
        editing.isPresented = true; editing.focus(f.assets[0])
        try await wait { await backend.requests.count == 1 }
        let work = try XCTUnwrap(editing.work)
        editing.developmentSaveRenderWillBeginHook = {
            let count = await backend.closed.count
            try await probe.begin(closedLeases: count)
        }
        editing.saveDevelopment()
        var joined = false
        let shutdown = Task { await editing.shutdown(); joined = true }
        await Task.yield(); XCTAssertFalse(joined)
        await backend.finish(0); await shutdown.value
        let starts = await probe.starts, opens = await backend.opens
        XCTAssertEqual(starts, 0); XCTAssertEqual(opens, 1)
        XCTAssertTrue(joined); XCTAssertFalse(editing.saving); XCTAssertNil(editing.preview)
        XCTAssertEqual(try f.store.loadEditingVersions(workID: work.id).count, 1)
    }
}

private enum SaveHandoffFailure: Error { case expected, timeout }
private actor SaveHandoffProbe {
    private(set) var starts = 0
    private(set) var closedAtRender: [Int] = []
    private let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func begin(closedLeases: Int) throws {
        starts += 1; closedAtRender.append(closedLeases)
        if fail { throw SaveHandoffFailure.expected }
    }
}
