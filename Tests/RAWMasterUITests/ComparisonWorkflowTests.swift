import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class ComparisonWorkflowTests: XCTestCase {
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
