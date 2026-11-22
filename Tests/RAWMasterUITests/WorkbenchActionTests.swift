import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class WorkbenchActionTests: XCTestCase {
    @MainActor func testPhotoExportCapturesOneFileWithoutCollapsedPartnerOrKeptPeers() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ExactPhoto", filenames: ["SHOT.ARW", "SHOT.JPG", "other.jpg"])
        let files = try f.store.loadAssets()
        let raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" })
        let jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        _ = try f.store.updateSelection(ids: files.map(\.id), decision: .keep, rating: nil)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.select(jpeg); model.setMode(.single)
        model.openPhotoExport()
        XCTAssertTrue(model.exportWorkspacePresented)
        XCTAssertEqual(model.requestedWorkbenchExportMode, .original)
        XCTAssertFalse(model.showExport || model.editing?.showExport == true)
        XCTAssertEqual(model.workbenchExportContext, .photo(id: jpeg.id))
        XCTAssertEqual(model.explicitExportAssets.map(\.id), [jpeg.id])
        let preview = try XCTUnwrap(model.exportSelection(ids: [jpeg.id], formats: .both, exactAssetIDs: [jpeg.id]))
        XCTAssertEqual(preview.assetIDs, [jpeg.id])
        model.select(raw)
        XCTAssertEqual(model.workbenchExportContext.exactAssetIDs, [jpeg.id], "Original delivery keeps its selected physical file")
    }

    @MainActor func testExactPhotoExportCopiesAndListsOnlyJPEGAcrossFormats() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ExactDelivery", filenames: ["SHOT.ARW", "SHOT.JPG", "other.jpg"])
        let files = try f.store.loadAssets()
        let raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" })
        let jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        let peer = try XCTUnwrap(files.first { $0.filename == "other.jpg" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        _ = try f.store.updateSelection(ids: files.map(\.id), decision: .keep, rating: nil)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.select(jpeg); model.setMode(.single)
        XCTAssertEqual(model.filteredAssets.count, 3, "The allowlist must restrict a fully visible project, not rely on search")
        XCTAssertEqual(Set(model.actionAssetIDs), Set([raw.id, jpeg.id]), "The collapsed pair would normally expand the selection")
        for formats in [ExportFormats.both, .allOriginals] {
            let preview = try XCTUnwrap(model.exportSelection(ids: [jpeg.id], formats: formats, exactAssetIDs: [jpeg.id]))
            let target = f.root.appendingPathComponent("delivery-" + formats.rawValue)
            model.export(ids: [jpeg.id], destination: target.path, formats: formats, exactAssetIDs: [jpeg.id])
            model.select(peer)
            for _ in 0..<500 {
                if !model.isBusy { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage)
            let report = try XCTUnwrap(model.exportReport)
            XCTAssertEqual(report.copied, 1)
            XCTAssertEqual(report.failed, formats == .both ? 1 : 0, "An explicitly excluded companion is reported as missing only when both formats were requested")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: URL(fileURLWithPath: report.manifestPath)))
            XCTAssertEqual(manifest.items.map { $0.asset.id }, [jpeg.id])
            XCTAssertEqual(manifest.items.filter(\.copyRequested).map { $0.asset.id }, preview.assetIDs)
            XCTAssertEqual(manifest.requestedAssetIDs, [jpeg.id]); XCTAssertEqual(manifest.allowedAssetIDs, [jpeg.id])
            let copied = try XCTUnwrap(manifest.items.first)
            XCTAssertEqual(copied.status, "copied")
            let copiedURL = URL(fileURLWithPath: try XCTUnwrap(copied.outputPath))
            XCTAssertEqual(try Data(contentsOf: copiedURL), try Data(contentsOf: jpeg.resolvedURL))
            let csvURL = URL(fileURLWithPath: report.manifestPath).deletingPathExtension().appendingPathExtension("csv")
            let csv = try String(contentsOf: csvURL, encoding: .utf8)
            XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 2, "Exactly one CSV data row")
            XCTAssertTrue(csv.contains(jpeg.id)); XCTAssertTrue(csv.contains(jpeg.filename))
            for excluded in [raw, peer] {
                XCTAssertFalse(csv.contains(excluded.id)); XCTAssertFalse(csv.contains(excluded.filename))
            }
            let outputURLs = try XCTUnwrap(FileManager.default.enumerator(at: URL(fileURLWithPath: report.destinationPath), includingPropertiesForKeys: nil)?.allObjects as? [URL])
            let deliveredImages = outputURLs.filter { ["jpg", "arw"].contains($0.pathExtension.lowercased()) }
            XCTAssertEqual(deliveredImages.map { $0.resolvingSymlinksInPath() }, [copiedURL.resolvingSymlinksInPath()], "No unlisted RAW or kept peer can be copied")
        }
    }

    @MainActor func testBatchExportCapturesCurrentSelectionAndProjectEntryResetsIntent() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("Batch")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let files = model.browserAssets
        model.select(files[0]); model.select(files[1], modifiers: .command)
        let ids = model.actionAssetIDs
        model.openSelectionExport()
        XCTAssertEqual(model.workbenchExportContext, .selection(ids: ids))
        model.selectedIDs = [files[2].id]
        XCTAssertEqual(Set(model.explicitExportAssets.map(\.id)), Set(ids))
        model.openProjectExport()
        XCTAssertEqual(model.workbenchExportContext, .project)
    }

    func testExternalEditorReceivesIndependentWritableBytesEvenFromSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterEditor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.jpg"), link = root.appendingPathComponent("linked.jpg")
        let originalBytes = Data([1, 3, 5, 7])
        try originalBytes.write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: original.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let copies = root.appendingPathComponent("copies")
        let copy = try ExternalEditorCopy.prepare(source: link, filename: "linked.jpg", directory: copies)
        let second = try ExternalEditorCopy.prepare(source: original, filename: "linked.jpg", directory: copies)
        XCTAssertNotEqual(copy, second)
        XCTAssertFalse(try copy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        XCTAssertEqual(try Data(contentsOf: copy), originalBytes)
        try Data([2, 4, 6]).write(to: copy)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: second), originalBytes)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)
        XCTAssertNotEqual(mode.intValue & 0o200, 0)
    }
}
