import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class ProjectReviewUITests: XCTestCase {
    struct Fixture {
        let root: URL
        let library: URL
        let store: LibraryStore
        let defaults: UserDefaults
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster007UI-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            store = try LibraryStore(databaseURL: library)
            defaults = UserDefaults(suiteName: "RAWMaster007UI-" + UUID().uuidString)!
        }
        func populate(_ name: String, filenames: [String] = ["one.jpg", "two.jpg", "three.jpg"], screening: Bool = false) async throws -> ImportSession {
            let source = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZikAAAAASUVORK5CYII=")!
            for filename in filenames { try bytes.write(to: source.appendingPathComponent(filename)) }
            return try await ImportService(store: store).importDirectory(source: source, destination: nil, projectName: name, mode: .reference, initialScreening: screening, progress: { _ in })
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor func testSearchAppliesWholeQueryPerFileAndDoesNotExpandHiddenPartner() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Pair", filenames: ["SHOT.ARW", "SHOT.JPG", "other.jpg"])
        let files = try f.store.loadAssets()
        let raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" }), jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        _ = try f.store.updateSelection(ids: [raw.id], decision: nil, rating: 5)
        try f.store.setTags(ids: [jpeg.id], tags: ["bird"])
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.searchQuery = ProjectSearchQuery(minimumRating: 5, tags: ["bird"])
        XCTAssertTrue(model.filteredAssets.isEmpty, "Members must not combine their separate matching evidence")
        XCTAssertTrue(model.actionAssetIDs.isEmpty)
        model.searchQuery = ProjectSearchQuery(tags: ["bird"])
        XCTAssertEqual(model.browserAssets.map(\.id), [jpeg.id])
        model.select(jpeg)
        XCTAssertEqual(model.actionAssetIDs, [jpeg.id])
        model.prepareTagMutation(text: "selected-only", mode: .add, showSheet: false)
        XCTAssertEqual(model.tagPreview?.assetIDs, [jpeg.id])
        XCTAssertTrue(model.applyTagMutation())
        XCTAssertFalse((try f.store.loadTags()[raw.id] ?? []).contains("selected-only"))
        model.decide(.keep)
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == raw.id }?.decision, .undecided)
        model.clearProjectSearch()
        XCTAssertEqual(model.scopedAssets.count, 3)
        XCTAssertFalse(model.actionAssetIDs.contains(raw.id), "The pair has differing decisions and must remain separate")
    }

    @MainActor func testProjectStatesRestoreIndependentlyAcrossSwitchesAndRestart() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try await f.populate("A"), b = try await f.populate("B")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: a.projectID)
        model.searchQuery.filename = "one"
        model.setMode(.single)
        let aFocus = model.focusedID
        model.selectScope(.project, id: b.projectID)
        XCTAssertTrue(model.searchQuery.isEmpty)
        model.reviewSort = .filename
        model.select(model.browserAssets[0]); model.select(model.browserAssets[1], modifiers: .command)
        model.setMode(.compare); model.syncCompare = false; model.saveBrowse()
        let bSelection = model.selectedIDs
        model.selectScope(.project, id: a.projectID)
        XCTAssertEqual(model.searchQuery.filename, "one")
        XCTAssertEqual(model.focusedID, aFocus)
        XCTAssertEqual(model.mode, .grid, "Leaving comparison for another project returns to its grid while preserving the query")
        model.selectScope(.project, id: b.projectID)
        XCTAssertTrue(model.searchQuery.isEmpty)
        XCTAssertEqual(model.reviewSort, .filename)
        XCTAssertEqual(model.mode, .grid, "A project round trip must not reopen the previous comparison")
        XCTAssertEqual(model.selectedIDs, bSelection)
        XCTAssertFalse(model.syncCompare)
        model.saveBrowse(); model.flushProjectReviewState()
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(reopened.scopeID, b.projectID)
        XCTAssertEqual(reopened.selectedIDs, bSelection)
        XCTAssertEqual(reopened.mode, .grid)
        reopened.selectScope(.project, id: a.projectID)
        XCTAssertEqual(reopened.searchQuery.filename, "one")
        XCTAssertEqual(reopened.focusedID, aFocus)
    }

    @MainActor func testOldRatingsAndBrowsingDoNotInventReviewedAndUndoKeepsReviewed() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Review")
        let first = try XCTUnwrap(f.store.loadAssets().first)
        _ = try f.store.updateSelection(ids: [first.id], decision: .keep, rating: 5)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.select(first); model.setMode(.single)
        XCTAssertEqual(model.projectProgress?.reviewedFiles, 0)
        model.decide(.reject)
        XCTAssertEqual(model.projectProgress?.reviewedFiles, 1)
        model.undo()
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == first.id }?.decision, .keep)
        XCTAssertTrue(model.isReviewed(first.id))
        model.markSelectedReviewed(false)
        XCTAssertEqual(model.projectProgress?.reviewedFiles, 0)
        model.searchQuery.review = .unreviewed
        model.select(first); model.markSelectedReviewed(true)
        XCTAssertFalse(model.filteredAssets.contains { $0.id == first.id })
        XCTAssertFalse(model.actionAssetIDs.contains(first.id))
    }

    @MainActor func testBatchTagsPreserveUniqueTagsAndHavePersistentSafeHistory() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Tags", filenames: ["one.jpg", "two.jpg"])
        let files = try f.store.loadAssets()
        try f.store.setTags(ids: [files[0].id], tags: ["a", "b"])
        try f.store.setTags(ids: [files[1].id], tags: ["b", "c"])
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.select(files[0]); model.select(files[1], modifiers: .command)
        XCTAssertEqual(model.selectedTagSummary.common, ["b"])
        XCTAssertEqual(model.selectedTagSummary.mixed, ["a", "c"])
        model.prepareTagMutation(text: "d", mode: .add, showSheet: false)
        let commandID = try XCTUnwrap(model.tagPreview).id
        XCTAssertTrue(model.applyTagMutation())
        XCTAssertEqual(try f.store.loadTags()[files[0].id], ["a", "b", "d"])
        XCTAssertEqual(try f.store.loadTags()[files[1].id], ["b", "c", "d"])
        model.saveBrowse(); model.flushProjectReviewState()
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        reopened.restoreTagCommand(commandID)
        XCTAssertEqual(try f.store.loadTags()[files[0].id], ["a", "b"])
        XCTAssertEqual(try f.store.loadTags()[files[1].id], ["b", "c"])
        reopened.select(files[0]); reopened.select(files[1], modifiers: .command)
        reopened.prepareTagMutation(text: "b", mode: .remove, showSheet: false)
        XCTAssertTrue(reopened.applyTagMutation())
        XCTAssertEqual(try f.store.loadTags()[files[0].id], ["a"])
        XCTAssertEqual(try f.store.loadTags()[files[1].id], ["c"])
        reopened.prepareTagMutation(text: "", mode: .replace, showSheet: false)
        XCTAssertEqual(reopened.tagPreview?.changedAssetIDs.count, 2)
        XCTAssertTrue(reopened.applyTagMutation())
        XCTAssertEqual(try f.store.loadTags()[files[0].id], [])
        XCTAssertEqual(try f.store.loadTags()[files[1].id], [])
    }

    @MainActor func testTagPreviewRejectsChangedSelectionQueryAndConcurrentTags() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Stale", filenames: ["one.jpg", "two.jpg"])
        let files = try f.store.loadAssets()
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.select(files[0]); model.select(files[1], modifiers: .command)
        model.prepareTagMutation(text: "new", mode: .add, showSheet: false)
        model.select(files[0])
        model.select(files[1], modifiers: .command)
        XCTAssertFalse(model.applyTagMutation())
        XCTAssertTrue(try f.store.loadTags().isEmpty)
        model.select(files[0])
        model.prepareTagMutation(text: "new", mode: .add, showSheet: false)
        model.searchQuery.filename = "one"
        XCTAssertFalse(model.applyTagMutation())
        let matching = try XCTUnwrap(model.browserAssets.first)
        model.select(matching)
        model.prepareTagMutation(text: "new", mode: .add, showSheet: false)
        try f.store.setTags(ids: [matching.id], tags: ["concurrent"])
        XCTAssertFalse(model.applyTagMutation())
        XCTAssertEqual(try f.store.loadTags()[matching.id], ["concurrent"])
    }

    @MainActor func testSearchDoesNotPolluteTriageAndEmptyResultsCanBeCleared() async throws {
        let f = try Fixture(); defer { f.clean() }
        let project = try await f.populate("Existing")
        let staging = try await f.populate("Staging", screening: true)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: project.projectID)
        model.searchQuery.filename = "no-match"
        XCTAssertTrue(model.filteredAssets.isEmpty)
        XCTAssertFalse(model.scopedAssets.isEmpty)
        XCTAssertTrue(model.hasSearchConditions)
        XCTAssertNil(model.focusedID)
        model.selectScope(.session, id: staging.id)
        XCTAssertTrue(model.isTriageScope)
        XCTAssertEqual(model.filteredAssets.count, 3)
        XCTAssertFalse(model.supportsProjectSearch)
        model.markSelectedReviewed(true)
        XCTAssertTrue(try f.store.loadReviewRecords().isEmpty)
        model.selectScope(.project, id: project.projectID)
        XCTAssertEqual(model.searchQuery.filename, "no-match")
        model.clearProjectSearch()
        XCTAssertEqual(model.browserAssets.count, 3)
        XCTAssertNotNil(model.focusedID)
    }

    @MainActor func testCompareLimitsVisibleSelectionAndRestoresOnlyFourPanels() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Compare", filenames: (1...6).map { "\($0).jpg" })
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.selectedIDs = Set(model.scopedAssets.map(\.id)); model.focusedID = model.scopedAssets.last?.id
        model.setMode(.compare)
        XCTAssertEqual(model.selectedIDs.count, 4)
        XCTAssertEqual(model.comparisonPanels.count, 4)
        XCTAssertTrue(model.selectedIDs.contains(try XCTUnwrap(model.focusedID)))
        model.saveBrowse(); model.flushProjectReviewState()
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(reopened.mode, .compare)
        XCTAssertEqual(reopened.selectedIDs.count, 4)
        XCTAssertEqual(reopened.comparisonPanels.count, 4)
    }

    @MainActor func testNewSheetsDoNotHandlePhotoDecisionKeys() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Keys")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 0)!
        model.toggleSearchFilters(); XCTAssertFalse(model.handleKey(event))
        model.hideSearchFilters(); model.showTagPreview = true; XCTAssertFalse(model.handleKey(event))
        model.showTagPreview = false; model.showTagHistory = true; XCTAssertFalse(model.handleKey(event))
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.decision == .undecided })
    }

    @MainActor func testLiveSearchPresentationCollapsesWithoutClearingAndKeepsInspectorPreference() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Live")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        XCTAssertFalse(model.showSearchField); XCTAssertFalse(model.showSearchFilters)
        model.focusProjectSearch(); let firstRequest = model.searchFocusRequest
        model.focusProjectSearch()
        XCTAssertEqual(model.searchFocusRequest, firstRequest + 1)
        XCTAssertTrue(model.editSearchQuery { $0.filename = "one" })
        XCTAssertEqual(model.filteredAssets.map(\.filename), ["one.jpg"])
        model.showInspector = false
        model.hideSearchField()
        XCTAssertFalse(model.showSearchField); XCTAssertFalse(model.showSearchFilters)
        XCTAssertTrue(model.hasSearchConditions); XCTAssertEqual(model.searchConditionChips.count, 1)
        model.toggleProjectSearchField(); XCTAssertTrue(model.showSearchField)
        model.toggleProjectSearchField(); XCTAssertFalse(model.showSearchField)
        XCTAssertEqual(model.searchQuery.filename, "one")
        XCTAssertFalse(model.showInspector)
        model.hideSearchFilters()
        XCTAssertFalse(model.showInspector, "Closing filters restores the original hidden inspector")
        model.toggleSearchFilters(); model.showPhotoInformation()
        XCTAssertFalse(model.showSearchFilters); XCTAssertTrue(model.showInspector)
        model.saveBrowse(); model.flushProjectReviewState()
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(reopened.filteredAssets.map(\.filename), ["one.jpg"])
        XCTAssertFalse(reopened.showSearchField); XCTAssertFalse(reopened.showSearchFilters)
        XCTAssertFalse(reopened.searchControlsOwnKeyboard, "Restored queries cannot steal editing focus")
    }

    @MainActor func testInvalidLiveEditsKeepLastValidQueryResultsAndPersistedState() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Atomic")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        XCTAssertTrue(model.editSearchQuery { $0.filename = "one"; $0.minimumRating = 0; $0.maximumRating = 4 })
        model.flushProjectReviewState()
        let query = model.effectiveSearchQuery, result = model.filteredAssets.map(\.id)
        let stored = try XCTUnwrap(f.store.loadProjectReviewState(projectID: session.projectID))
        XCTAssertFalse(model.editSearchQuery { $0.minimumRating = 5 })
        XCTAssertNotNil(model.searchValidationMessage); XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.effectiveSearchQuery, query); XCTAssertEqual(model.filteredAssets.map(\.id), result)
        model.flushProjectReviewState()
        XCTAssertEqual(try f.store.loadProjectReviewState(projectID: session.projectID)?.revision, stored.revision)
        XCTAssertFalse(model.editSearchQuery { $0.capturedFrom = Date(timeIntervalSince1970: 20); $0.capturedBefore = Date(timeIntervalSince1970: 10) })
        XCTAssertEqual(model.effectiveSearchQuery, query)
        XCTAssertFalse(model.editSearchQuery { $0.filename = String(repeating: "a", count: 1025) })
        XCTAssertTrue(model.editSearchQuery { _ in })
        XCTAssertNil(model.searchValidationMessage)
        model.flushProjectReviewState()
        XCTAssertEqual(try f.store.loadProjectReviewState(projectID: session.projectID)?.revision, stored.revision, "Unchanged valid text must not rescan or resave")
    }

    @MainActor func testIndividualSearchChipsPreserveOtherConditionsAndTagRelation() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Chips")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        XCTAssertTrue(model.editSearchQuery {
            $0.filename = "one"; $0.tags = ["a", "b"]; $0.tagMatch = .any; $0.decision = .keep
            $0.minimumRating = 2; $0.capturedFrom = Date(timeIntervalSince1970: 10); $0.capturedBefore = Date(timeIntervalSince1970: 20)
        })
        XCTAssertEqual(model.filter, .keep)
        model.removeSearchCondition(.tag("A"))
        XCTAssertEqual(model.searchQuery.tags, ["b"]); XCTAssertEqual(model.searchQuery.tagMatch, .any)
        XCTAssertEqual(model.searchQuery.minimumRating, 2); XCTAssertEqual(model.searchQuery.filename, "one")
        model.removeSearchCondition(.decision)
        XCTAssertEqual(model.filter, .all); XCTAssertNil(model.effectiveSearchQuery.decision)
        model.removeSearchCondition(.dates)
        XCTAssertNil(model.searchQuery.capturedFrom); XCTAssertNil(model.searchQuery.capturedBefore)
        XCTAssertEqual(model.searchQuery.tags, ["b"])
        model.clearProjectSearch()
        XCTAssertTrue(model.searchConditionChips.isEmpty); XCTAssertEqual(model.filteredAssets.count, 3)
    }

    @MainActor func testExplicitSearchScopeCarriesQueryButSidebarRestoresIndependentProjectState() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try await f.populate("ScopeA"), b = try await f.populate("ScopeB")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: a.projectID)
        model.editSearchQuery { $0.filename = "one" }
        model.toggleSearchFilters(); model.selectSearchScope(nil)
        XCTAssertEqual(model.scope, .all); XCTAssertEqual(model.filteredAssets.count, 2)
        XCTAssertTrue(model.showSearchFilters); XCTAssertEqual(model.searchPanelProjectID, a.projectID)
        XCTAssertEqual(try f.store.loadProjectReviewState(projectID: a.projectID)?.query.filename, "one")
        model.editSearchQuery { $0.filename = "two" }
        model.selectScope(.project, id: b.projectID)
        XCTAssertTrue(model.searchQuery.isEmpty); XCTAssertFalse(model.showSearchFilters)
        model.selectScope(.project, id: a.projectID)
        XCTAssertEqual(model.searchQuery.filename, "one"); XCTAssertEqual(model.filteredAssets.count, 1)
    }

    @MainActor func testSearchKeyboardOwnershipBlocksControlKeysButOpenPanelAllowsPhotoKeys() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate("Ownership")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let first = try XCTUnwrap(model.focusedAsset)
        func event(_ text: String, code: UInt16 = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        model.toggleSearchFilters()
        for text in ["p", "x", "u", "0", "5"] { XCTAssertFalse(model.handleKey(try event(text))) }
        XCTAssertFalse(model.handleKey(try event("", code: 124)))
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.decision == .undecided && $0.rating == 0 })
        model.select(first)
        XCTAssertTrue(model.showSearchFilters); XCTAssertFalse(model.searchControlsOwnKeyboard)
        XCTAssertTrue(model.handleKey(try event("p")))
        XCTAssertEqual(try f.store.loadAssets().first(where: { $0.id == first.id })?.decision, .keep)
        model.focusProjectSearch()
        let coordinator = ProjectToolbarSearchField.Coordinator(model: model)
        XCTAssertTrue(coordinator.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(model.showSearchField); XCTAssertFalse(model.showSearchFilters, "Unified search Escape collapses details while the grid search row stays visible")
        model.toggleSearchFilters()
        model.searchControlsOwnKeyboard = true
        XCTAssertTrue(model.handleKey(try event("", code: 53)))
        XCTAssertFalse(model.showSearchFilters)
        model.showTagPreview = true; model.focusProjectSearch(); XCTAssertFalse(model.showSearchField)
        model.showTagPreview = false
        model.selectScope(.session, id: session.id); model.focusProjectSearch()
        XCTAssertFalse(model.showSearchField); XCTAssertFalse(model.canActivateProjectSearch)
    }

    @MainActor func testTagCompletionReplacesOnlyFinalFragmentAndHandlesSeparators() async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try await f.populate("Complete", filenames: ["one.jpg"])
        try f.store.setTags(ids: [try XCTUnwrap(f.store.loadAssets().first).id], tags: ["Bird", "Trip", "Forest"])
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(model.tagSuggestions(for: "bi"), ["Bird"])
        XCTAssertEqual(model.completingTag("bi", with: "Bird"), "Bird")
        XCTAssertEqual(Set(model.completingTag("Trip, bi", with: "Bird").components(separatedBy: ", ")), ["Trip", "Bird"])
        XCTAssertTrue(model.tagSuggestions(for: "Trip, ").contains("Bird"))
        XCTAssertEqual(Set(model.completingTag("Trip；bi", with: "Bird").components(separatedBy: ", ")), ["Trip", "Bird"])
        XCTAssertEqual(model.completingTag("Bird, bi", with: "Bird"), "Bird")
    }

    @MainActor func testTagHistoryRestoresOnlyWholeCommandsInCurrentProject() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try await f.populate("A", filenames: ["a.jpg"]), b = try await f.populate("B", filenames: ["b.jpg"])
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: a.projectID)
        model.prepareTagMutation(text: "A-only", mode: .add, showSheet: false)
        let aCommand = try XCTUnwrap(model.tagPreview).id
        XCTAssertTrue(model.applyTagMutation())
        XCTAssertTrue(model.scopedTagCommands.contains { $0.id == aCommand })
        XCTAssertTrue(model.tagCommandScopeLabel(try XCTUnwrap(model.scopedTagCommands.first)).contains("A"))
        model.selectScope(.project, id: b.projectID)
        XCTAssertFalse(model.scopedTagCommands.contains { $0.id == aCommand })
        model.restoreTagCommand(aCommand)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(try f.store.loadTags().values.contains(["A-only"]))
        model.selectScope(.all)
        model.selectedIDs = Set(model.browserAssets.map(\.id))
        model.prepareTagMutation(text: "Across", mode: .add, showSheet: false)
        let allCommand = try XCTUnwrap(model.tagPreview).id
        XCTAssertTrue(model.applyTagMutation())
        XCTAssertTrue(model.scopedTagCommands.contains { $0.id == allCommand })
        model.selectScope(.project, id: a.projectID)
        XCTAssertFalse(model.scopedTagCommands.contains { $0.id == allCommand })
        model.searchQuery.tags = ["no-match"]
        XCTAssertTrue(model.scopedTagCommands.contains { $0.id == aCommand }, "History uses whole project, even when its files no longer match")
    }

    @MainActor func testAutoAdvanceUsesVisibleRatingOrderWhenDecisionOrReviewDropsFocus() async throws {
        let f = try Fixture(); defer { f.clean() }
        let project = try await f.populate("Order", filenames: ["A.jpg", "B.jpg", "C.jpg"])
        let files = try f.store.loadAssets()
        let a = try XCTUnwrap(files.first { $0.filename == "A.jpg" }), b = try XCTUnwrap(files.first { $0.filename == "B.jpg" }), c = try XCTUnwrap(files.first { $0.filename == "C.jpg" })
        for (asset, rating) in [(a,4),(b,5),(c,1)] { _ = try f.store.updateSelection(ids: [asset.id], decision: .keep, rating: rating) }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: project.projectID)
        model.reviewSort = .ratingDescending; model.filter = .keep; model.autoAdvance = true
        XCTAssertEqual(model.browserAssets.map(\.id), [b.id, a.id, c.id])
        model.select(b); model.decide(.reject)
        XCTAssertEqual(model.focusedID, a.id)
        XCTAssertEqual(model.selectedIDs, [a.id])
        model.clearProjectSearch(); model.searchQuery.review = .unreviewed
        model.select(a); model.markSelectedReviewed(true)
        XCTAssertEqual(model.focusedID, c.id)
        XCTAssertEqual(model.selectedIDs, [c.id])
    }

    @MainActor func testExportFreezesMatchingFilesAndDoesNotCopyHiddenCompanion() async throws {
        let f = try Fixture(); defer { f.clean() }
        let project = try await f.populate("Export", filenames: ["SHOT.ARW", "SHOT.JPG", "other.jpg"])
        let files = try f.store.loadAssets()
        let raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" }), jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        _ = try f.store.updateSelection(ids: files.map(\.id), decision: .keep, rating: nil)
        try f.store.setTags(ids: [jpeg.id], tags: ["matching"])
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: project.projectID); model.searchQuery.tags = ["matching"]
        let selection = try XCTUnwrap(model.exportSelection(ids: model.filteredAssets.map(\.id), formats: .both))
        XCTAssertEqual(selection.assetIDs, [jpeg.id]); XCTAssertEqual(selection.missingFormats.count, 1)
        let destination = f.root.appendingPathComponent("out")
        model.export(ids: model.filteredAssets.map(\.id), destination: destination.path, formats: .both)
        model.clearProjectSearch()
        for _ in 0..<500 { if !model.isBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage)
        let report = try XCTUnwrap(model.exportReport)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: URL(fileURLWithPath: report.manifestPath)))
        XCTAssertEqual(manifest.items.map { $0.asset.id }, [jpeg.id])
        XCTAssertEqual(manifest.allowedAssetIDs, [jpeg.id]); XCTAssertEqual(report.copied, 1)
    }

    @MainActor func testStartingImportPreservesOutgoingProjectQueryAndFocus() async throws {
        let f = try Fixture(); defer { f.clean() }
        let project = try await f.populate("Original")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: project.projectID)
        model.searchQuery.filename = "one"; model.decide(.keep); model.filter = .keep
        let focus = model.focusedID
        let incoming = f.root.appendingPathComponent("Incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let original = try XCTUnwrap(model.filteredAssets.first)
        try FileManager.default.copyItem(at: original.resolvedURL, to: incoming.appendingPathComponent("new.jpg"))
        model.startImport(source: incoming.path, destination: "", name: "New", mode: .reference, projectID: nil)
        for _ in 0..<500 { if !model.isBusy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage)
        model.selectScope(.project, id: project.projectID)
        XCTAssertEqual(model.searchQuery.filename, "one"); XCTAssertEqual(model.filter, .keep)
        XCTAssertEqual(model.focusedID, focus)
    }

    @MainActor func testProjectStateConflictDoesNotOverwriteOrRepeatUntilReopened() async throws {
        let f = try Fixture(); defer { f.clean() }
        let project = try await f.populate("Conflict")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: project.projectID)
        model.saveBrowse(); model.flushProjectReviewState()
        var external = try XCTUnwrap(f.store.loadProjectReviewState(projectID: project.projectID))
        external.query.filename = "external"
        _ = try f.store.saveProjectReviewState(external)
        model.searchQuery.filename = "one"; model.flushProjectReviewState()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try f.store.loadProjectReviewState(projectID: project.projectID)?.query.filename, "external")
        model.errorMessage = nil; model.searchQuery.filename = "two"; model.flushProjectReviewState()
        XCTAssertNil(model.errorMessage, "A failed project save stays blocked until reload, without repeat errors for each interaction")
        model.selectScope(.project, id: project.projectID)
        XCTAssertEqual(model.searchQuery.filename, "external")
        model.searchQuery.filename = "three"; model.flushProjectReviewState()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try f.store.loadProjectReviewState(projectID: project.projectID)?.query.filename, "three")
    }
}
