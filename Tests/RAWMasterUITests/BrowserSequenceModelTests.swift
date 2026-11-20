import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class BrowserSequenceModelTests: XCTestCase {
    @MainActor func testCandidateDecisionRatingTargetsOneFileAndPreservesComparison() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("Candidate", filenames: ["SHOT.ARW", "SHOT.JPG", "peer.jpg"])
        let files = try f.store.loadAssets(), raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" }), jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.select(jpeg); model.select(try XCTUnwrap(model.browserAssets.first { $0.filename == "peer.jpg" }), modifiers: .command); model.setMode(.compare)
        let selected = model.selectedIDs, focus = model.focusedID
        model.decideAsset(id: jpeg.id, decision: .keep, rating: 5)
        let changed = try f.store.loadAssets()
        XCTAssertEqual(changed.first { $0.id == jpeg.id }?.rating, 5)
        XCTAssertTrue(changed.filter { $0.id != jpeg.id }.allSatisfy { $0.rating == 0 && $0.decision == .undecided })
        XCTAssertEqual(model.selectedIDs, selected); XCTAssertEqual(model.focusedID, focus)
        XCTAssertEqual(Set(try f.store.loadReviewRecords().filter(\.reviewed).map(\.assetID)), [jpeg.id])
        model.undo()
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == jpeg.id }?.rating, 0)
        XCTAssertTrue(model.isReviewed(jpeg.id))
    }
    @MainActor func testExactCandidateDecisionUnderFilterRetainsReferenceAndFillsVacantSlot() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("DecisionFilter", filenames: (1...5).map { "\($0).jpg" })
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.filter = .undecided
        let files = model.browserAssets
        model.select(files[0]); model.select(files[1], modifiers: .command); model.setMode(.compare)
        model.decideAsset(id: files[0].id, decision: .keep, rating: 4)
        XCTAssertEqual(model.mode, .compare); XCTAssertEqual(model.compareAssets.count, 2)
        XCTAssertTrue(model.selectedIDs.contains(files[1].id)); XCTAssertFalse(model.selectedIDs.contains(files[0].id))
        XCTAssertTrue(model.selectedIDs.isSubset(of: Set(model.browserAssets.map(\.id))))
        XCTAssertEqual(model.filteredAssets.count, 4)
        let after = try f.store.loadAssets()
        XCTAssertTrue(after.filter { $0.id != files[0].id }.allSatisfy { $0.decision == .undecided && $0.rating == 0 })
        model.undo()
        let restored = try XCTUnwrap(f.store.loadAssets().first { $0.id == files[0].id })
        XCTAssertEqual(restored.decision, .undecided); XCTAssertEqual(restored.rating, 0)
        XCTAssertTrue(model.isReviewed(files[0].id)); XCTAssertEqual(model.filteredAssets.count, 5)
        XCTAssertEqual(model.compareAssets.count, 2); XCTAssertTrue(model.selectedIDs.contains(files[1].id))
    }
    @MainActor func testExactColorClearAndChangeUnderFilterReplenishComparisonAndUndoValues() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ColorFilter", filenames: (1...5).map { "\($0).jpg" })
        let files = try f.store.loadAssets()
        _ = try f.store.setColorLabel(ids: files.map(\.id), label: .blue)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.searchQuery.colorLabel = .blue
        let ordered = model.browserAssets
        model.select(ordered[0]); model.select(ordered[1], modifiers: .command); model.setMode(.compare)
        model.setColorLabel(nil, assetIDs: [ordered[0].id])
        XCTAssertNil(model.colorLabel(for: ordered[0].id)); XCTAssertEqual(model.filteredAssets.count, 4)
        XCTAssertEqual(model.compareAssets.count, 2); XCTAssertTrue(model.selectedIDs.contains(ordered[1].id))
        XCTAssertFalse(model.selectedIDs.contains(ordered[0].id))
        XCTAssertTrue(model.selectedIDs.isSubset(of: Set(model.browserAssets.map(\.id))))
        model.undo()
        XCTAssertEqual(model.colorLabel(for: ordered[0].id), .blue); XCTAssertEqual(model.filteredAssets.count, 5)
        model.setColorLabel(.red, assetIDs: [ordered[1].id])
        XCTAssertEqual(model.compareAssets.count, 2); XCTAssertFalse(model.selectedIDs.contains(ordered[1].id))
        XCTAssertTrue(model.selectedIDs.isSubset(of: Set(model.browserAssets.map(\.id))))
        XCTAssertTrue(ordered.filter { $0.id != ordered[1].id }.allSatisfy { model.colorLabel(for: $0.id) == .blue })
        model.undoLastColorLabel()
        XCTAssertEqual(model.colorLabel(for: ordered[1].id), .blue); XCTAssertEqual(model.filteredAssets.count, 5)
        XCTAssertEqual(model.compareAssets.count, 2)
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.decision == .undecided && $0.rating == 0 })
    }
    @MainActor func testExactCandidateTriageAffectsOnlyRequestedFileAndRejectsRating() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ExactTriage", screening: true)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        let files = model.browserAssets
        model.select(files[0]); model.select(files[1], modifiers: .command); model.setMode(.compare)
        let selection = model.selectedIDs
        model.decideAsset(id: files[0].id, decision: .keep)
        XCTAssertEqual(model.disposition(of: files[0].id), .passed)
        XCTAssertTrue(files.dropFirst().allSatisfy { model.disposition(of: $0.id) == .pending })
        XCTAssertEqual(model.selectedIDs, selection)
        model.decideAsset(id: files[1].id, rating: 5)
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == files[1].id }?.rating, 0)
        XCTAssertTrue(try f.store.loadReviewRecords().isEmpty)
        model.undo(); XCTAssertEqual(model.disposition(of: files[0].id), .pending)
    }
    @MainActor func testCompareProjectSwitchReturnsGridButKeepsTargetQuery() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let a = try await f.populate("A"), b = try await f.populate("B")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: b.projectID); model.searchQuery.minimumRating = 0; model.setMode(.single)
        model.selectScope(.project, id: a.projectID); model.setMode(.compare)
        model.selectScope(.project, id: b.projectID)
        XCTAssertEqual(model.mode, .grid); XCTAssertEqual(model.searchQuery.minimumRating, 0)
        model.setMode(.compare); model.showInspector = true
        XCTAssertFalse(model.showsRightSidebar); model.toggleRightSidebar(); XCTAssertFalse(model.showsRightSidebar)
        model.setMode(.single); XCTAssertTrue(model.showsRightSidebar)
    }
    @MainActor func testProjectRoundTripClearsOutgoingAndLegacyComparisonModesButRetainsQueries() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let a = try await f.populate("RoundtripA"), b = try await f.populate("RoundtripB")
        let bFiles = try f.store.loadAssets().filter { $0.projectID == b.projectID }
        _ = try f.store.saveProjectReviewState(ProjectReviewState(projectID: b.projectID,
            query: ProjectSearchQuery(minimumRating: 0), mode: "compare", focusedAssetID: bFiles[0].id,
            selectedAssetIDs: Array(bFiles.prefix(2)).map(\.id)))
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: a.projectID); model.searchQuery.filename = ".jpg"
        model.setMode(.compare)
        let aSelection = model.selectedIDs, aFocus = model.focusedID
        model.selectScope(.project, id: b.projectID)
        XCTAssertEqual(model.mode, .grid, "An explicit project switch normalizes an older saved comparison")
        XCTAssertEqual(model.searchQuery.minimumRating, 0)
        let outgoing = try XCTUnwrap(f.store.loadProjectReviewState(projectID: a.projectID))
        XCTAssertEqual(outgoing.mode, "grid"); XCTAssertEqual(outgoing.query.filename, ".jpg")
        XCTAssertEqual(Set(outgoing.selectedAssetIDs), aSelection); XCTAssertEqual(outgoing.focusedAssetID, aFocus)
        model.selectScope(.project, id: a.projectID)
        XCTAssertEqual(model.mode, .grid); XCTAssertEqual(model.searchQuery.filename, ".jpg")
        XCTAssertEqual(model.selectedIDs, aSelection); XCTAssertEqual(model.focusedID, aFocus)
        model.selectScope(.project, id: b.projectID)
        XCTAssertEqual(model.mode, .grid); XCTAssertEqual(model.searchQuery.minimumRating, 0)
    }
    @MainActor func testExactColorUpdatesDoNotExpandPairAndRemainUndoableAfterRestart() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ColorPair", filenames: ["SHOT.ARW", "SHOT.JPG"])
        let files = try f.store.loadAssets(), raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" }), jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        try f.store.setTags(ids: [jpeg.id], tags: ["text"])
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.select(jpeg)
        let selection = model.selectedIDs
        model.setColorLabel(.purple, assetIDs: [jpeg.id])
        XCTAssertEqual(model.colorLabel(for: jpeg.id), .purple); XCTAssertNil(model.colorLabel(for: raw.id))
        XCTAssertEqual(model.assetTags[jpeg.id], ["text"]); XCTAssertEqual(model.selectedIDs, selection)
        model.searchQuery.colorLabel = .purple; XCTAssertEqual(model.filteredAssets.map(\.id), [jpeg.id])
        model.saveBrowse(); model.flushProjectReviewState()
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(reopened.colorLabel(for: jpeg.id), .purple)
        reopened.undo(); XCTAssertNil(reopened.colorLabel(for: jpeg.id)); XCTAssertTrue(reopened.filteredAssets.isEmpty)
    }
    @MainActor func testConfirmRAWJPEGThenCreateSequenceRetainsBothRelationships() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("PairSequence", filenames: ["SHOT.ARW", "SHOT.JPG"])
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let files = model.browserAssets
        model.select(files[0]); model.select(files[1], modifiers: .command)
        model.confirmSelectedPair(); XCTAssertEqual(model.capturePairs.count, 1)
        let pair = try XCTUnwrap(model.capturePairs.first)
        model.saveGroup(name: "连拍序列", kind: "连拍", mergeIDs: [])
        let group = try XCTUnwrap(model.groups.first { $0.name == "连拍序列" })
        XCTAssertEqual(Set(group.assetIDs), Set(pair.assetIDs)); XCTAssertEqual(Set(group.includedAssetIDs), Set(pair.assetIDs))
        XCTAssertEqual(try f.store.loadCapturePairs().first?.id, pair.id)
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.isSequenceMember })
    }
    @MainActor func testCollapsingFilmstripPairRemapsCandidateWithoutLosingReference() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("CollapseCompare", filenames: ["SHOT.ARW", "SHOT.JPG", "peer.jpg"])
        let files = try f.store.loadAssets()
        let raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" }), jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        let peer = try XCTUnwrap(files.first { $0.filename == "peer.jpg" })
        let pair = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.togglePair(pair)
        model.select(peer); model.select(raw, modifiers: .command); model.setMode(.compare)
        model.togglePair(pair)
        XCTAssertEqual(model.mode, .compare); XCTAssertEqual(model.selectedIDs, [jpeg.id, peer.id])
        XCTAssertEqual(model.focusedID, jpeg.id); XCTAssertEqual(model.compareAssets.count, 2)
    }
    @MainActor func testClickedAssetEditorEligibilityDoesNotChangeGridSelectionOrMode() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("EditorContext")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let files = model.browserAssets; model.select(files[0])
        let selection = model.selectedIDs, focus = model.focusedID
        XCTAssertTrue(model.canOpenExternalEditor(assetID: files[1].id))
        XCTAssertEqual(model.selectedIDs, selection); XCTAssertEqual(model.focusedID, focus); XCTAssertEqual(model.mode, .grid)
    }
}
