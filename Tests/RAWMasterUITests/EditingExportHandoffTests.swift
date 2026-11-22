import ImageIO
import XCTest
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

@MainActor
final class EditingExportHandoffTests: XCTestCase {
    func testColdEditorExportsFrozenLiveCropAndSelectedVersionOfProjectPhoto() async throws {
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg")
        let original = fixture.source.appendingPathComponent("flight.v2.jpg")
        try FileManager.default.copyItem(at: sample, to: original)
        let session = try await ImportService(store: fixture.store).importDirectory(source: fixture.source,
            destination: nil, projectName: "Export handoff", mode: .reference, progress: { _ in })
        let asset = try XCTUnwrap(fixture.store.loadAssets(sessionID: session.id).first)
        let source = try fixture.store.captureEditingSourceSnapshot(assetID: asset.id)
        let work = try fixture.store.createPhotoWork(source: source)
        var recipe = DevelopmentRecipe()
        recipe.crop = .init(x: 0.25, y: 0, width: 0.5, height: 1)
        _ = try fixture.store.saveLiveDevelopmentState(workID: work.id, recipe: recipe,
            parentVersionID: work.originalVersionID, expectedRevision: 0)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
                             editingPreviewBackend: PhotosDevelopmentBackend())
        model.selectScope(.project, id: session.projectID)
        model.setMode(.single)
        model.select(asset)
        let editing = try XCTUnwrap(model.editing)
        editing.focusSnapshotHook = { _ in Thread.sleep(forTimeInterval: 0.1) }
        model.openPhotoExport(.render)
        XCTAssertTrue(model.exportWorkspacePresented)
        XCTAssertTrue(editing.loading)
        XCTAssertFalse(model.showExport || editing.showExport)
        XCTAssertEqual(model.requestedWorkbenchExportMode, .render)
        let destination = fixture.root.appendingPathComponent("delivery")
        let files = try await model.exportWorkbenchPhotos(directory: destination, namingTemplate: "{name}-{index}",
            configuration: .init(format: .jpeg8), includedIDs: [asset.id]) { _, _, _ in }
        let cropped = try XCTUnwrap(files.first)
        XCTAssertEqual(cropped.lastPathComponent, "flight.v2-0001.jpg")
        XCTAssertEqual(try dimensions(cropped), CGSize(width: 512, height: 684))
        XCTAssertFalse(editing.showExport || model.showExport)
        model.activateWorkflow(.edit)
        editing.stage = .versions
        let savedOriginal = try XCTUnwrap(editing.versions.first { $0.id == work.originalVersionID })
        editing.selectVersion(savedOriginal)
        model.openExportWorkspace(.render)
        let frozen = try await editing.workbenchExportInput(for: asset.id)
        XCTAssertEqual(frozen?.1.id, savedOriginal.id)
        XCTAssertEqual(frozen?.1.recipe, savedOriginal.recipe)
        editing.stage = .development
        editing.setRecipe { $0.crop = .init(x: 0, y: 0, width: 0.5, height: 0.5) }
        let preview = try await model.workbenchExportPreview(for: asset, maxPixel: 1024)
        XCTAssertEqual(CGSize(width: preview.image.width, height: preview.image.height), CGSize(width: 1024, height: 684))
        let full = try await model.exportWorkbenchPhotos(directory: destination, namingTemplate: "version-{index}",
            configuration: .init(format: .tiff16), includedIDs: [asset.id]) { _, _, _ in }
        XCTAssertEqual(try dimensions(XCTUnwrap(full.first)), CGSize(width: 1024, height: 684))
        editing.stage = .versions
        model.activateWorkflow(.edit)
        XCTAssertEqual(editing.stage, .versions)
        XCTAssertEqual(editing.selectedVersionID, savedOriginal.id)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: sample))
        await editing.shutdown()
    }

    func testOfflineSelectedArchiveExportsWhileOriginalRemainsMissing() async throws {
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let asset = fixture.assets[0]
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: asset.projectID)
        model.setMode(.single)
        model.select(asset)
        model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait { editing.work != nil && !editing.loading }
        editing.setRecipe { $0.crop = .init(x: 0, y: 0, width: 0.5, height: 1) }
        editing.saveDevelopment()
        try await wait { !editing.saving && editing.versions.contains { $0.artifact != nil } }
        let archived = try XCTUnwrap(editing.versions.first { $0.artifact != nil })
        let hidden = fixture.root.appendingPathComponent("unmounted.png")
        try FileManager.default.moveItem(at: asset.resolvedURL, to: hidden)
        let position = try XCTUnwrap(model.assets.firstIndex { $0.id == asset.id })
        model.assets[position].availability = .missing
        try await wait { !editing.loading && !editing.sourceReady && editing.work != nil }
        editing.stage = .versions
        editing.selectVersion(archived)
        model.openExportWorkspace(.render)
        let target = fixture.root.appendingPathComponent("archive-delivery")
        let files = try await model.exportWorkbenchPhotos(directory: target, namingTemplate: "archived",
            configuration: .init(format: .png16), includedIDs: [asset.id]) { _, _, _ in }
        XCTAssertEqual(try dimensions(XCTUnwrap(files.first)), CGSize(width: 60, height: 80))
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.resolvedURL.path))
        XCTAssertEqual(editing.exportVersionID, archived.id)
        XCTAssertFalse(editing.showExport || model.showExport)
        await editing.shutdown()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out preparing editing export")
    }

    private func dimensions(_ url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }
}
