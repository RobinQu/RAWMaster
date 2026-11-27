import AppKit
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

@MainActor final class VirtualCopyGridTests: XCTestCase {
    func testPagedOffscreenSelectionAcrossRestartAndUndoChain() async throws {
        let f = try ProjectReviewUITests.Fixture()
        defer { f.clean() }
        let filenames = (0..<125).map { String(format: "photo-%03d.jpg", $0) }
        let project = try await f.populate("Renditions", filenames: filenames).projectID
        let original = try XCTUnwrap(f.store.loadAssets().first(where: { $0.filename == "photo-085.jpg" }))
        let copy = try f.store.createVirtualCopy(of: original, name: "Black and White")
        let ids = [original.id, copy.id]
        _ = try f.store.saveProjectReviewState(.init(projectID: project, sort: .filename, mode: "grid", focusedAssetID: copy.id, selectedAssetIDs: ids))
        f.defaults.set("project", forKey: "browse.scope")
        f.defaults.set(project, forKey: "browse.id")
        let start = ProcessInfo.processInfo.systemUptime
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, usesPagedLibrary: true)
        try await wait { model.catalogGrid?.watermark != nil && model.browserAssets.count == 60 }
        let firstPage = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(model.selectedIDs, Set(ids))
        XCTAssertEqual(model.scopeFileCount, 125)
        XCTAssertEqual(model.focusedAsset?.id, copy.id)
        model.openSelectionExport()
        await model.pendingGridExport?.value
        XCTAssertEqual(Set(model.workbenchExportCandidates.map(\.id)), Set(ids))
        model.activateWorkflow(.library)
        model.catalogGrid?.loadMore()
        try await wait { model.browserAssets.count >= 120 }
        model.catalogGrid?.loadMore()
        try await wait { model.browserAssets.count == 126 }
        let items = model.browserAssets
        XCTAssertEqual(items.firstIndex(where: { $0.id == copy.id }), items.firstIndex(where: { $0.id == original.id }).map { $0 + 1 })
        let physical = Set(items.map(\.physicalAssetID))
        XCTAssertEqual(physical.count, 125)
        XCTAssertEqual(Set(items.map(\.id)).count, 126)
        print("Virtual-copy grid 125 files, 126 renditions, first 60 in \(Int(firstPage * 1000)) ms")
        model.searchQuery = ProjectSearchQuery(filename: "Black and White")
        try await wait { model.browserAssets.map(\.id) == [copy.id] }
        model.searchQuery = ProjectSearchQuery()
        try await wait { model.catalogGrid?.watermark != nil && model.browserAssets.count >= 60 }
        let presentation = copy.projecting(original)
        model.requestVirtualCopy(.rename, for: presentation)
        try await model.commitVirtualCopy(XCTUnwrap(model.virtualCopyRequest), name: "Silver")
        try await wait { model.focusedAsset?.id == copy.id && model.catalogGrid?.watermark != nil }
        model.requestVirtualCopy(.remove, for: presentation)
        try await model.commitVirtualCopy(XCTUnwrap(model.virtualCopyRequest), name: "")
        XCTAssertTrue(try f.store.virtualCopies().isEmpty)
        model.undo()
        XCTAssertEqual(try f.store.virtualCopies().map(\.name), ["Silver"])
        model.undo()
        XCTAssertEqual(try f.store.virtualCopies().map(\.name), ["Black and White"])
    }

    func testGridRendersAndCachesRenditionsByWorkAndRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg")
        let original = try NativePresentedCanvasTests.register(source: fixture, library: library, requiresRAW: false)
        let store = try LibraryStore(databaseURL: library)
        let work = try store.createPhotoWork(source: store.captureEditingSourceSnapshot(assetID: original.id))
        var color = try store.editingVersion(id: work.originalVersionID).recipe.promotingToV3()
        color.adjustmentsV3?.color = .init(enabled: true, saturation: 0.35)
        _ = try store.saveLiveDevelopmentState(workID: work.id, recipe: color, parentVersionID: work.originalVersionID, expectedRevision: 0)
        let copy = try store.createVirtualCopy(of: original, name: "Silver").projecting(original)
        let copyWork = try store.photoWork(id: copy.id)
        var grayscale = color
        grayscale.adjustmentsV3?.blackAndWhite.enabled = true
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        model.selectScope(.project, id: original.projectID)
        let sourceThumbnail = try await model.libraryRenditionPreview(original, maxPixel: 96)
        let initialCopy = try await model.libraryRenditionPreview(copy, maxPixel: 96)
        XCTAssertGreaterThan(chroma(sourceThumbnail), 2)
        XCTAssertEqual(chroma(sourceThumbnail), chroma(initialCopy), accuracy: 0.1)
        let before = model.renditionPreviewKey(for: copy)
        _ = try store.saveLiveDevelopmentState(workID: copy.id, recipe: grayscale, parentVersionID: copyWork.originalVersionID, expectedRevision: 0)
        model.reload()
        XCTAssertNotEqual(model.renditionPreviewKey(for: copy), before)
        let blackAndWhite = try await model.libraryRenditionPreview(copy, maxPixel: 96)
        XCTAssertLessThan(chroma(blackAndWhite), 1.5)
        let unchanged = try await model.libraryRenditionPreview(original, maxPixel: 96)
        XCTAssertTrue(unchanged === sourceThumbnail)
        let full = try await model.libraryRenditionPreview(copy, maxPixel: 0)
        XCTAssertGreaterThan(full.size.width, blackAndWhite.size.width)
        XCTAssertLessThan(chroma(full), 1.5)
    }

    private func chroma(_ image: NSImage) -> Double {
        guard let photo = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .nan }
        var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(photo, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return stride(from: 0, to: rgba.count, by: 4).reduce(0.0) { sum, i in
            let r = rgba[i], g = rgba[i + 1], b = rgba[i + 2]
            return sum + Double(max(r,g,b) - min(r,g,b))
        } / 1024
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(condition())
    }
}
