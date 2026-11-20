import AppKit
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class LibraryCatalogTests: XCTestCase {
    @MainActor func testCatalogDetailBackKeepsIndependentQueriesStatusTypeAndAnchors() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("CatalogHistory", screening: true)
        let ids = try f.store.loadAssets().map(\.id)
        try f.store.createGroup(ids: ids, name: "Night Sequence", kind: "延时")
        let group = try XCTUnwrap(f.store.loadGroups().first)
        let completion = try f.store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
        XCTAssertTrue(completion.canCommit); _ = try f.store.commitCompletion(completion)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.openImportCatalog(); model.importCatalogQuery = "history"; model.importCatalogStatus = .history
        model.openCatalogSession(id: session.id)
        XCTAssertEqual(model.scope, .session); XCTAssertEqual(model.mode, .grid); XCTAssertTrue(model.isHistoryScope)
        XCTAssertTrue(model.canReturnToCatalog); XCTAssertEqual(model.catalogParentTitle, "导入记录")
        model.setMode(.single); model.returnToCatalog()
        XCTAssertEqual(model.scope, .imports); XCTAssertEqual(model.mode, .grid)
        XCTAssertEqual(model.importCatalogQuery, "history"); XCTAssertEqual(model.importCatalogStatus, .history)
        XCTAssertEqual(model.importCatalogAnchorID, session.id)
        model.openSequenceCatalog(); model.sequenceCatalogQuery = "night"; model.sequenceCatalogType = .timelapse
        model.openCatalogSequence(id: group.id)
        XCTAssertEqual(model.scope, .group); XCTAssertEqual(model.mode, .grid); XCTAssertEqual(model.scopedAssets.map(\.id), group.assetIDs)
        model.returnToCatalog()
        XCTAssertEqual(model.scope, .sequences); XCTAssertEqual(model.sequenceCatalogQuery, "night")
        XCTAssertEqual(model.sequenceCatalogType, .timelapse); XCTAssertEqual(model.sequenceCatalogAnchorID, group.id)
        XCTAssertEqual(model.importCatalogQuery, "history"); XCTAssertEqual(model.importCatalogStatus, .history)
    }

    @MainActor func testCatalogStartupAndReloadHaveNoPhotoSelectionOrMode() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("Startup")
        let id = try XCTUnwrap(f.store.loadAssets().first?.id)
        for destination in [AppModel.Scope.imports, .sequences] {
            f.defaults.set(destination.rawValue, forKey: "browse.scope")
            f.defaults.set(id, forKey: "browse.focus"); f.defaults.set("compare", forKey: "browse.mode")
            let model = AppModel(libraryURL: f.library, defaults: f.defaults)
            XCTAssertEqual(model.scope, destination); XCTAssertEqual(model.mode, .grid)
            XCTAssertTrue(model.scopedAssets.isEmpty); XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertNil(model.focusedAsset)
            XCTAssertFalse(model.showsRightSidebar); XCTAssertFalse(model.supportsProjectSearch)
            model.selectedIDs = [id]; model.focusedID = id; model.mode = .single; model.actualPixels = true
            model.reload()
            XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertNil(model.focusedID); XCTAssertFalse(model.actualPixels)
            XCTAssertEqual(model.mode, .grid); XCTAssertTrue(model.actionAssetIDs.isEmpty)
            model.saveBrowse()
            XCTAssertEqual(f.defaults.string(forKey: "browse.scope"), destination.rawValue)
        }
    }

    @MainActor func testCatalogGuardsPhotoCommandsUndoAndFocusRoutesToItsOwnSearch() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("Guarded")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let file = try XCTUnwrap(model.browserAssets.first)
        model.setColorLabel(.blue, assetIDs: [file.id]); XCTAssertTrue(model.canUndo)
        model.openImportCatalog(); XCTAssertFalse(model.canUndo)
        model.selectedIDs = [file.id]; model.focusedID = file.id
        let oldUndoCount = model.undoCount
        model.decideAsset(id: file.id, decision: .keep, rating: 5)
        model.decide(.reject); model.setColorLabel(.red, assetIDs: [file.id]); model.updateTags("unexpected")
        model.undo(); model.undoLastColorLabel(); model.toggleRightSidebar()
        model.setMode(.compare); model.setMode(.single)
        XCTAssertEqual(model.mode, .grid); XCTAssertFalse(model.showsRightSidebar)
        XCTAssertFalse(model.canExport); XCTAssertFalse(model.canMaintainPairs); XCTAssertFalse(model.canOpenExternalEditor(assetID: file.id))
        XCTAssertTrue(model.actionAssetIDs.isEmpty); XCTAssertNil(model.exportSelection(ids: [file.id], formats: .allOriginals))
        XCTAssertEqual(model.undoCount, oldUndoCount); XCTAssertEqual(model.colorLabel(for: file.id), .blue)
        XCTAssertFalse(model.previewGroup(.create(assetIDs: [file.id], name: "Unexpected", kind: "连拍"), showSheet: false))
        model.editGroup(); XCTAssertFalse(model.showGroups)
        for text in ["p", "x", "u", "g", "e", "c", "z", "5"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
            XCTAssertFalse(model.handleKey(event))
        }
        let focus = model.catalogSearchFocusRequest
        model.focusCurrentSearch(); XCTAssertEqual(model.catalogSearchFocusRequest, focus + 1)
        model.focusProjectSearch(); XCTAssertFalse(model.showSearchField); XCTAssertFalse(model.showSearchFilters)
        XCTAssertFalse(model.searchControlsOwnKeyboard)
        let saved = try XCTUnwrap(f.store.loadAssets().first { $0.id == file.id })
        XCTAssertEqual(saved.decision, .undecided); XCTAssertEqual(saved.rating, 0)
        XCTAssertNil(try f.store.loadTags()[file.id])
        model.reload(); model.openImport(); XCTAssertTrue(model.showImport, "Import remains a global action")
    }

    @MainActor func testCatalogNavigationPreservesProjectQueryAndClearsComparisonRoundtrip() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ProjectState")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.searchQuery.minimumRating = 0; model.setMode(.compare)
        let ids = model.selectedIDs, focus = model.focusedID
        model.openSequenceCatalog()
        let state = try XCTUnwrap(f.store.loadProjectReviewState(projectID: session.projectID))
        XCTAssertEqual(state.mode, "grid"); XCTAssertEqual(state.query.minimumRating, 0)
        XCTAssertEqual(Set(state.selectedAssetIDs), ids); XCTAssertEqual(state.focusedAssetID, focus)
        model.sequenceCatalogQuery = "unrelated collection query"
        model.selectScope(.project, id: session.projectID)
        XCTAssertEqual(model.mode, .grid); XCTAssertEqual(model.searchQuery.minimumRating, 0)
        XCTAssertEqual(model.selectedIDs, ids); XCTAssertEqual(model.focusedID, focus)
        XCTAssertFalse(model.canReturnToCatalog)
    }

    @MainActor func testSessionCatalogSearchStatusOrderAndActualFileCounts() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        var old = try await f.populate("History", filenames: ["SHOT.ARW", "SHOT.JPG", "extra.jpg"], screening: true)
        var active = try await f.populate("Active", screening: true)
        old.createdAt = Date(timeIntervalSince1970: 10); active.createdAt = Date(timeIntervalSince1970: 20)
        try f.store.saveSession(old); try f.store.saveSession(active)
        let oldFiles = try f.store.loadAssets().filter { $0.sessionID == old.id }
        _ = try f.store.confirmCapturePair(rawAssetID: try XCTUnwrap(oldFiles.first { $0.filename == "SHOT.ARW" }?.id), jpegAssetID: try XCTUnwrap(oldFiles.first { $0.filename == "SHOT.JPG" }?.id))
        let completed = try f.store.previewCompletion(sessionID: old.id, acknowledgeManualAnalysis: true)
        XCTAssertTrue(completed.canCommit); _ = try f.store.commitCompletion(completed)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults); model.openImportCatalog()
        XCTAssertEqual(model.importCatalogItems.map(\.id), [active.id, old.id])
        let item = try XCTUnwrap(model.importCatalogItems.first { $0.id == old.id })
        XCTAssertEqual(item.fileCount, 3); XCTAssertEqual(item.captureCount, 2); XCTAssertEqual(item.coverAssets.count, 2)
        XCTAssertEqual(item.statusTitle, "已完成初筛")
        let activeItem = try XCTUnwrap(model.importCatalogItems.first { $0.id == active.id })
        XCTAssertEqual(activeItem.session.status, "completed", "Byte ingestion is complete while screening remains pending")
        XCTAssertEqual(activeItem.statusTitle, "待初筛")
        model.importCatalogStatus = .active; model.importCatalogQuery = "待初筛"
        XCTAssertEqual(model.importCatalogItems.map(\.id), [active.id])
        model.importCatalogStatus = .history; model.importCatalogQuery = "已完成初筛"
        XCTAssertEqual(model.importCatalogItems.map(\.id), [old.id])
        model.importCatalogStatus = .history; model.importCatalogQuery = "HISTORY"
        XCTAssertEqual(model.importCatalogItems.map(\.id), [old.id])
        model.importCatalogQuery = "missing"; XCTAssertTrue(model.importCatalogItems.isEmpty)
    }

    @MainActor func testSequenceCatalogUsesAdmittedMembershipAndCanonicalTypesWithoutPairItems() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("SequenceTypes", filenames: ["SHOT.ARW", "SHOT.JPG", "peer.jpg"])
        let files = try f.store.loadAssets().filter { $0.sessionID == session.id }
        _ = try f.store.confirmCapturePair(rawAssetID: try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" }?.id), jpegAssetID: try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" }?.id))
        try f.store.createGroup(ids: files.map(\.id), name: "Seq10", kind: "间隔")
        try f.store.createGroup(ids: files.map(\.id), name: "Seq2", kind: "连拍")
        try f.store.createGroup(ids: files.map(\.id), name: "Custom", kind: "My RAW+JPEG workflow")
        let staged = try await f.populate("Staging", screening: true)
        try f.store.createGroup(ids: f.store.loadAssets().filter { $0.sessionID == staged.id }.map(\.id), name: "Pending", kind: "间隔拍摄")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults); model.openSequenceCatalog()
        XCTAssertEqual(model.sequenceCatalogItems.map(\.title), ["Custom", "Seq2", "Seq10"])
        XCTAssertEqual(model.sequenceCatalogItems.count, 3, "CapturePair is not itself a shooting sequence; staging stays in its session")
        let interval = try XCTUnwrap(model.sequenceCatalogItems.first { $0.title == "Seq10" })
        XCTAssertEqual(interval.fileCount, 3); XCTAssertEqual(interval.captureCount, 2); XCTAssertEqual(interval.includedFileCount, 3)
        XCTAssertTrue(model.isTimelapseGroup(interval.group)); XCTAssertTrue(model.canComposeTimelapse(groupID: interval.id))
        model.sequenceCatalogType = .timelapse; XCTAssertEqual(model.sequenceCatalogItems.map(\.id), [interval.id])
        model.sequenceCatalogType = .other; XCTAssertEqual(model.sequenceCatalogItems.map(\.title), ["Custom"])
        model.sequenceCatalogQuery = "nomatch"; XCTAssertTrue(model.sequenceCatalogItems.isEmpty)
        for alias in ["延时", "间隔", "间隔拍摄", "timelapse", "time-lapse", "interval"] { XCTAssertEqual(SequenceCatalogType.classify(alias), .timelapse) }
        model.openCatalogSession(id: staged.id)
        XCTAssertTrue(model.isTriageScope); XCTAssertEqual(model.triageSessionGroups.map(\.name), ["Pending"])
        let group = try XCTUnwrap(model.triageSessionGroups.first); model.selectTriageGroup(group.id)
        XCTAssertEqual(Set(model.scopedAssets.map(\.id)), Set(group.assetIDs))
    }

    @MainActor func testSequenceCardCountsOnlyAdmittedMembersWithoutRewritingGroup() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("PartialAdmission", screening: true)
        let files = try f.store.loadAssets().filter { $0.sessionID == session.id }
        try f.store.createGroup(ids: files.map(\.id), name: "Partial", kind: "连拍")
        let group = try XCTUnwrap(f.store.loadGroups().first)
        let excluded = files[0].id
        try f.store.setSequenceMembership(ids: [excluded], included: false, groupID: group.id)
        _ = try f.store.updateTriage(ids: [excluded], disposition: .excluded)
        let completion = try f.store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true)
        XCTAssertTrue(completion.canCommit); _ = try f.store.commitCompletion(completion)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults); model.openSequenceCatalog()
        let item = try XCTUnwrap(model.sequenceCatalogItems.first { $0.id == group.id })
        XCTAssertEqual(item.fileCount, 2); XCTAssertEqual(item.captureCount, 2); XCTAssertEqual(item.includedFileCount, 2)
        XCTAssertFalse(item.coverAssets.contains { $0.id == excluded })
        XCTAssertEqual(item.group.assetIDs.count, 3, "Catalog statistics must not remove historical members")
        model.openCatalogSequence(id: group.id)
        XCTAssertEqual(model.scopedAssets.count, 2); XCTAssertFalse(model.scopedAssets.contains { $0.id == excluded })
    }

    @MainActor func testExplicitGroupHistoryRestoreRemainsAvailableFromCatalogButImplicitUndoIsBlocked() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("HistoryRestore")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.selectedIDs = Set(model.browserAssets.map(\.id)); model.saveGroup(name: "Before", kind: "连拍", mergeIDs: [])
        let id = try XCTUnwrap(model.groups.first?.id)
        XCTAssertTrue(model.previewGroup(.rename(groupID: id, name: "After"), showSheet: false)); XCTAssertTrue(model.applyGroupPreview())
        let rename = try XCTUnwrap(model.groupHistory.first { if case .rename = $0.request { return true }; return false })
        model.openSequenceCatalog(); model.openGroupHistory()
        XCTAssertTrue(model.showGroupHistory)
        XCTAssertTrue(model.previewGroup(.restore(commandID: rename.id), showSheet: false)); XCTAssertTrue(model.applyGroupPreview())
        XCTAssertEqual(model.groups.first { $0.id == id }?.name, "Before")
        XCTAssertEqual(model.scope, .sequences); XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertFalse(model.canUndo)
        model.undo(); XCTAssertEqual(model.groups.first { $0.id == id }?.name, "Before")
    }

    @MainActor func testStagingGroupHistoryCanRestoreAfterRestartInsideItsSession() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("StagingHistory", screening: true)
        let original = AppModel(libraryURL: f.library, defaults: f.defaults)
        original.openCatalogSession(id: session.id)
        XCTAssertTrue(original.isTriageScope)
        original.selectedIDs = Set(original.browserAssets.map(\.id))
        original.saveGroup(name: "Staging Before", kind: "连拍", mergeIDs: [])
        let group = try XCTUnwrap(original.groups.first { $0.name == "Staging Before" })
        XCTAssertTrue(original.previewGroup(.rename(groupID: group.id, name: "Staging After"), showSheet: false))
        XCTAssertTrue(original.applyGroupPreview()); original.saveBrowse()
        let rename = try XCTUnwrap(original.groupHistory.first {
            if case .rename(let id, _) = $0.request { return id == group.id }; return false
        })
        let restarted = AppModel(libraryURL: f.library, defaults: f.defaults)
        restarted.openSequenceCatalog(); restarted.openGroupHistory()
        XCTAssertFalse(restarted.previewGroup(.restore(commandID: rename.id), showSheet: false),
            "A global sequence catalog cannot restore unadmitted staging members")
        XCTAssertEqual(restarted.groups.first { $0.id == group.id }?.name, "Staging After")
        restarted.showGroupHistory = false
        restarted.openCatalogSession(id: session.id); restarted.openGroupHistory()
        XCTAssertTrue(restarted.isTriageScope); XCTAssertTrue(restarted.showGroupHistory)
        XCTAssertTrue(restarted.previewGroup(.restore(commandID: rename.id), showSheet: false))
        XCTAssertTrue(restarted.applyGroupPreview())
        let restored = try XCTUnwrap(restarted.groups.first { $0.id == group.id })
        XCTAssertEqual(restored.name, "Staging Before"); XCTAssertEqual(restored.kind, "连拍")
        XCTAssertEqual(restored.assetIDs, group.assetIDs); XCTAssertEqual(restored.includedAssetIDs, group.includedAssetIDs)
        XCTAssertEqual(restarted.scope, .session); XCTAssertEqual(restarted.scopeID, session.id)
        XCTAssertTrue(restarted.isTriageScope); XCTAssertEqual(restarted.catalogParentTitle, "导入记录")
        XCTAssertEqual(try f.store.loadGroups().first { $0.id == group.id }?.name, "Staging Before")
    }

    @MainActor func testExpiredDetailStartupReturnsToItsCatalogAndClearsStalePhotoState() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("Existing")
        let photoID = try XCTUnwrap(f.store.loadAssets().first?.id)
        for (missing, destination) in [(AppModel.Scope.session, AppModel.Scope.imports), (.group, .sequences), (.project, .all)] {
            f.defaults.set(missing.rawValue, forKey: "browse.scope"); f.defaults.set("deleted", forKey: "browse.id")
            f.defaults.set("compare", forKey: "browse.mode"); f.defaults.set(photoID, forKey: "browse.focus")
            f.defaults.set("keep", forKey: "browse.filter")
            let model = AppModel(libraryURL: f.library, defaults: f.defaults)
            XCTAssertEqual(model.scope, destination); XCTAssertEqual(model.scopeID, "")
            XCTAssertEqual(model.mode, .grid); XCTAssertNil(model.focusedID); XCTAssertTrue(model.selectedIDs.isEmpty)
            XCTAssertFalse(model.actualPixels); XCTAssertEqual(model.filter, .all)
        }
    }

    @MainActor func testStaleCatalogObjectsReturnToParent() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.openCatalogSession(id: "deleted"); XCTAssertEqual(model.scope, .imports)
        model.openCatalogSequence(id: "deleted"); XCTAssertEqual(model.scope, .sequences)
        XCTAssertTrue(model.scopedAssets.isEmpty); XCTAssertFalse(model.canReturnToCatalog)
    }
}
