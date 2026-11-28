import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class ComparisonWorkflowTests: XCTestCase {
    @MainActor func testImportedCameraClockSortComparisonAndDeliveryStayConsistentOffline() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let source = f.root.appendingPathComponent("camera")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(context.makeImage())
        func write(_ name: String, _ date: String? = nil, _ fraction: String? = nil, _ offset: String? = nil) throws {
            let url = source.appendingPathComponent(name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            var exif: [CFString: String] = [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = date
            exif[kCGImagePropertyExifSubsecTimeOriginal] = fraction
            exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try write("later.jpg", "2026:11:28 22:30:00", "006", "+00:00")
        try write("earlier.jpg", "2026:11:29 00:30:00", "005", "+02:00")
        try write("no-time.jpg")
        let session = try await ImportService(store: f.store).importDirectory(source: source, destination: nil,
            projectName: "Clock", mode: .reference, progress: { _ in })
        XCTAssertEqual(session.completed, 3)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.reviewSort = .capturedAscending
        XCTAssertEqual(model.browserAssets.map(\.filename), ["earlier.jpg", "later.jpg", "no-time.jpg"])
        model.reviewSort = .capturedDescending
        XCTAssertEqual(model.browserAssets.map(\.filename), ["later.jpg", "earlier.jpg", "no-time.jpg"])
        let original = try XCTUnwrap(model.browserAssets.first(where: { $0.filename == "earlier.jpg" }))
        let later = try XCTUnwrap(model.browserAssets.first(where: { $0.filename == "later.jpg" }))
        XCTAssertEqual(try XCTUnwrap(later.capturedAt).timeIntervalSince(XCTUnwrap(original.capturedAt)), 0.001, accuracy: 0.000001)
        let expected = "2026-11-29 00:30:00.005 +02:00"
        XCTAssertEqual(ComparisonSnapshot.read(asset: original, histogram: false).values["拍摄时间"], expected)
        XCTAssertEqual(try PhotoExportFilename.stem(for: original, ordinal: 1, template: "{name}-{captureDate}", exportDate: Date()), "earlier-20261129")
        try FileManager.default.removeItem(at: original.resolvedURL)
        try f.store.refreshAvailability(ids: [original.id])
        let reopened = try LibraryStore(databaseURL: f.library)
        let offline = try XCTUnwrap(reopened.loadAssets().first(where: { $0.id == original.id }))
        XCTAssertEqual(offline.availability, .missing)
        XCTAssertEqual(ComparisonSnapshot.read(asset: offline, histogram: false).values["拍摄时间"], expected)
    }

    @MainActor func testCandidateNavigationPreservesReferencesAndSelectionBounds() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("CompareSelection", filenames: (1...6).map { "\($0).jpg" })
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let files = model.browserAssets
        model.select(files[0]); model.select(files[1], modifiers: .command); model.setMode(.compare)
        model.select(files[2])
        XCTAssertEqual(model.mode, .compare)
        XCTAssertEqual(model.selectedIDs, [files[0].id, files[2].id])
        XCTAssertEqual(model.focusedID, files[2].id)
        model.select(files[2], modifiers: .command)
        XCTAssertEqual(model.selectedIDs.count, 2, "A command click cannot destroy the last reference")
        model.move(1)
        XCTAssertEqual(model.selectedIDs, [files[0].id, files[3].id])
        model.select(files[4], modifiers: .command); model.select(files[5], modifiers: .command)
        XCTAssertEqual(model.selectedIDs.count, 4)
        model.select(files[1], modifiers: .command)
        XCTAssertEqual(model.selectedIDs.count, 4)
        XCTAssertTrue(model.selectedIDs.contains(files[0].id))
        XCTAssertTrue(model.selectedIDs.contains(files[1].id))
        XCTAssertFalse(model.selectedIDs.contains(files[5].id))
    }

    @MainActor func testChangedFilterReplenishesComparisonAndSearchCannotOwnHiddenControls() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("CompareFilter")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let files = model.browserAssets
        model.focusProjectSearch()
        XCTAssertTrue(model.showSearchFilters)
        model.showInspector = false
        model.select(files[0]); model.select(files[1], modifiers: .command); model.setMode(.compare)
        XCTAssertFalse(model.showsRightSidebar, "Comparison tools live below the filmstrip; the right sidebar is hidden")
        XCTAssertFalse(model.showInspector, "Photo inspector preference is independent")
        model.toggleRightSidebar(); XCTAssertFalse(model.showsRightSidebar)
        model.toggleRightSidebar(); XCTAssertFalse(model.showsRightSidebar)
        XCTAssertFalse(model.canActivateProjectSearch)
        XCTAssertFalse(model.showSearchFilters); XCTAssertFalse(model.searchControlsOwnKeyboard)
        model.focusProjectSearch(); XCTAssertFalse(model.showSearchField)
        _ = try f.store.updateSelection(ids: [files[0].id], decision: .reject, rating: nil)
        model.reload(); model.filter = .undecided
        XCTAssertEqual(model.compareAssets.count, 2)
        XCTAssertFalse(model.selectedIDs.contains(files[0].id))
        model.setMode(.single); XCTAssertFalse(model.showsRightSidebar)
        model.focusProjectSearch()
        XCTAssertFalse(model.canActivateProjectSearch); XCTAssertFalse(model.showSearchField)
        model.setMode(.grid)
        XCTAssertTrue(model.canActivateProjectSearch)
        XCTAssertEqual(model.filter, .undecided)
    }

    func testHistogramCountsEachColorChannelAndNormalizesByPixelCount() {
        let histogram = RGBHistogram.sample(rgba: [255,0,0,255, 0,255,0,255, 255,0,0,255, 0,0,255,255])
        XCTAssertEqual(histogram.red[255], 0.5)
        XCTAssertEqual(histogram.green[255], 0.25)
        XCTAssertEqual(histogram.blue[255], 0.25)
        XCTAssertEqual(histogram.red.reduce(0,+), 1, accuracy: 0.000001)
        XCTAssertEqual(histogram.green.reduce(0,+), 1, accuracy: 0.000001)
        XCTAssertEqual(histogram.blue.reduce(0,+), 1, accuracy: 0.000001)
        XCTAssertEqual(RGBHistogram.sample(rgba: []).red.reduce(0,+), 0)
    }

    func testExposureDescriptionHandlesMalformedAndTinyExifValues() {
        XCTAssertEqual(ComparisonSnapshot.exposureDescription(seconds: 0.004), "1/250 s")
        XCTAssertEqual(ComparisonSnapshot.exposureDescription(seconds: 2), "2.0 s")
        for value in [Double.nan, Double.infinity, -1, 0] {
            XCTAssertEqual(ComparisonSnapshot.exposureDescription(seconds: value), "—")
        }
        XCTAssertTrue(ComparisonSnapshot.exposureDescription(seconds: Double.leastNonzeroMagnitude).hasSuffix(" s"))
    }

    func testUnavailableMetadataKeepsFileFactsWithoutInventedExifOrHistogram() {
        let asset = AssetRecord(sessionID: "s", projectID: "p", sourcePath: "/missing/photo.jpg", fileSize: 512, camera: "Camera", availability: .missing)
        let result = ComparisonSnapshot.read(asset: asset, histogram: true)
        XCTAssertEqual(result.values["文件名"], "photo.jpg")
        XCTAssertEqual(result.values["相机"], "Camera")
        XCTAssertNil(result.values["镜头"])
        XCTAssertNil(result.histogram)
        XCTAssertNotNil(result.error)
    }
}
