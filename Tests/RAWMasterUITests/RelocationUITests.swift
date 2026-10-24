import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster
@testable import RAWMasterImaging

final class RelocationUITests: XCTestCase {
    @MainActor func testPreviewThenConfirmPreservesPhotoIdentityAndBrowseState() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let imported = try await fixture.populate(count: 1)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let original = try XCTUnwrap(model.assets.first)
        model.select(original); model.decide(.keep, rating: 4)
        model.saveGroup(name: "Retained group", kind: "连拍", mergeIDs: [])
        let group = try XCTUnwrap(model.groups.first)
        model.selectScope(.group, id: group.id); model.setMode(.single); model.actualPixels = true
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: fixture.source, to: moved)
        let selected = model.selectedIDs, focus = model.focusedID, reveal = model.navigationReveal
        let pipelineBefore = await ImagePipeline.shared.testingSnapshot()
        model.prepareRelocation(sessionID: imported.id, assetIDs: [original.id])
        model.startRelocation(root: moved)
        XCTAssertTrue(model.relocationIsRunning)
        // Starting another task synchronously must not replace the active relocation job.
        model.startImport(source: moved.path, destination: "", name: "Should not start", mode: .reference, projectID: nil)
        model.export(ids: [original.id], destination: fixture.root.appendingPathComponent("export-should-not-exist").path)
        try await waitForJob(model)
        XCTAssertNil(model.errorMessage)
        let preview = try XCTUnwrap(model.relocationReport)
        XCTAssertEqual(preview.status, "review")
        XCTAssertEqual(preview.matchedCount, 1)
        XCTAssertEqual(try fixture.store.loadAssets().first?.currentPath, original.currentPath, "Scanning is read only until the explicit confirmation")
        XCTAssertEqual(model.selectedIDs, selected); XCTAssertEqual(model.focusedID, focus)
        model.confirmRelocation(); try await waitForJob(model)
        let recovered = try XCTUnwrap(model.assets.first)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.relocationReport?.committedCount, 1)
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.currentPath, moved.appendingPathComponent(original.filename).path)
        XCTAssertEqual(recovered.sourcePath, original.sourcePath)
        XCTAssertEqual(recovered.decision, .keep); XCTAssertEqual(recovered.rating, 4)
        XCTAssertEqual(model.groups.first?.assetIDs, group.assetIDs)
        XCTAssertEqual(model.selectedIDs, selected); XCTAssertEqual(model.focusedID, focus)
        XCTAssertEqual(model.scope, .group); XCTAssertEqual(model.scopeID, group.id)
        XCTAssertEqual(model.mode, .single); XCTAssertTrue(model.actualPixels)
        XCTAssertEqual(model.navigationReveal, reveal)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("export-should-not-exist").path))
        let pipelineAfter = await ImagePipeline.shared.testingSnapshot()
        XCTAssertEqual(pipelineAfter.detailRequests, pipelineBefore.detailRequests)
        XCTAssertEqual(pipelineAfter.previewRequests, pipelineBefore.previewRequests)
    }

    @MainActor func testAmbiguousCandidatesRequireExplicitChoiceAndPersistAcrossReopen() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let imported = try await fixture.populate(count: 1)
        let original = try XCTUnwrap(try fixture.store.loadAssets().first)
        let moved = fixture.root.appendingPathComponent("duplicates")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let first = moved.appendingPathComponent("first.jpg"), second = moved.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: original.url, to: first)
        try FileManager.default.copyItem(at: original.url, to: second)
        try FileManager.default.removeItem(at: fixture.source)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.prepareRelocation(sessionID: imported.id, assetIDs: [original.id]); model.startRelocation(root: moved)
        try await waitForJob(model)
        let item = try XCTUnwrap(model.relocationReport?.items.first)
        XCTAssertEqual(item.status, .ambiguous); XCTAssertEqual(item.candidates.count, 2)
        XCTAssertNil(item.selectedPath); XCTAssertEqual(model.relocationReport?.matchedCount, 0)
        model.confirmRelocation()
        XCTAssertFalse(model.isBusy); XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.store.loadAssets().first?.currentPath, original.currentPath)
        model.chooseRelocationCandidate(assetID: original.id, path: second.path)
        XCTAssertEqual(model.relocationReport?.matchedCount, 1)
        let reopened = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        reopened.reviewRelocation(try XCTUnwrap(reopened.relocationHistory.first))
        XCTAssertTrue(reopened.showRelocation)
        XCTAssertEqual(reopened.relocationAssetIDs, [original.id])
        XCTAssertEqual(reopened.relocationReport?.items.first?.selectedPath, second.path)
        reopened.chooseRelocationCandidate(assetID: original.id, path: nil)
        XCTAssertEqual(reopened.relocationReport?.matchedCount, 0)
        reopened.chooseRelocationCandidate(assetID: original.id, path: first.path)
        reopened.confirmRelocation(); try await waitForJob(reopened)
        XCTAssertEqual(reopened.assets.first?.currentPath, first.path)
        XCTAssertEqual(reopened.relocationReport?.committedCount, 1)
    }

    @MainActor func testManagedRelocationKeepsOriginalSourceDistinct() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 1)
        let originalManagedRoot = fixture.root.appendingPathComponent("managed")
        let copied = try await ImportService(store: fixture.store).importDirectory(source: fixture.source, destination: originalManagedRoot, projectName: "Managed", mode: .copy, progress: { _ in })
        let original = try XCTUnwrap(try fixture.store.loadAssets(sessionID: copied.id).first)
        let moved = fixture.root.appendingPathComponent("managed-moved")
        try FileManager.default.moveItem(at: originalManagedRoot, to: moved)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.prepareRelocation(sessionID: copied.id, assetIDs: [original.id], role: .managed)
        XCTAssertEqual(model.relocationRole, .managed)
        XCTAssertEqual(model.relocationScopeCount, 1)
        model.startRelocation(root: moved); try await waitForJob(model)
        XCTAssertEqual(model.relocationReport?.role, .managed)
        XCTAssertEqual(model.relocationReport?.matchedCount, 1)
        model.confirmRelocation(); try await waitForJob(model)
        let recovered = try XCTUnwrap(model.assets.first { $0.id == original.id })
        XCTAssertEqual(recovered.resolvedSourceURL, original.resolvedSourceURL)
        XCTAssertEqual(recovered.sourcePath, original.sourcePath)
        XCTAssertTrue(recovered.resolvedURL.path.hasPrefix(moved.path + "/"))
        XCTAssertEqual(recovered.effectiveManagedPath, recovered.currentPath)
        XCTAssertEqual(recovered.effectiveSourcePath, original.effectiveSourcePath)
        XCTAssertEqual(model.relocationReport?.committedCount, 1)
    }

    @MainActor func testInvalidScanIsVisibleAndDoesNotReplaceBusinessPaths() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let imported = try await fixture.populate(count: 1)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let original = try XCTUnwrap(model.assets.first)
        model.prepareRelocation(sessionID: imported.id)
        model.startRelocation(root: fixture.root.appendingPathComponent("does-not-exist"))
        try await waitForJob(model)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.relocationIsRunning)
        XCTAssertEqual(model.relocationReport?.status, "failed")
        XCTAssertFalse(model.relocationReport?.scanComplete ?? true)
        XCTAssertEqual(try fixture.store.loadAssets().first?.currentPath, original.currentPath)
        model.confirmRelocation()
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(try fixture.store.loadAssets().first?.currentPath, original.currentPath)
    }

    @MainActor private func waitForJob(_ model: AppModel) async throws {
        for _ in 0..<1000 {
            if !model.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.cancelJob(); XCTFail("Relocation did not finish within 10 seconds")
    }
}
