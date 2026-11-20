import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class GroupEditingWorkflowTests: XCTestCase {
    private func storedGroup(_ fixture: ProjectReviewUITests.Fixture, name: String) throws -> CaptureGroup {
        try XCTUnwrap(fixture.store.loadGroups().first { $0.name == name })
    }

    @MainActor func testSelectionCreatesOutsideGroupButRemovesInsideGroupWithoutChangingOtherMemberships() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("SelectionActions", filenames: ["a.jpg", "b.jpg", "c.jpg"])
        let files = try f.store.loadAssets()
        let order = [files[2].id, files[0].id, files[1].id]
        try f.store.createGroup(ids: order, name: "Target", kind: "延时")
        try f.store.createGroup(ids: [files[0].id, files[1].id], name: "Other", kind: "HDR")
        let target = try storedGroup(f, name: "Target"), other = try storedGroup(f, name: "Other")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.select(files[0]); model.select(files[1], modifiers: .command)
        XCTAssertTrue(model.canCreateGroup); XCTAssertEqual(model.groupSelectionActionTitle, "创建拍摄组…")
        model.performGroupSelectionAction()
        XCTAssertTrue(model.showGroups); XCTAssertNil(model.groupEditingID)
        model.showGroups = false
        model.selectScope(.group, id: target.id)
        model.selectedIDs = [files[0].id, files[2].id]
        XCTAssertFalse(model.canCreateGroup); XCTAssertTrue(model.canPerformGroupSelectionAction)
        XCTAssertEqual(model.groupSelectionActionTitle, "从拍摄组中移除")
        model.performGroupSelectionAction()
        let preview = try XCTUnwrap(model.groupPreview)
        guard case .removeMembers(let id, let ids) = preview.request else { return XCTFail("Group selection must remove, not create") }
        XCTAssertEqual(id, target.id); XCTAssertEqual(Set(ids), Set([files[0].id, files[2].id]))
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        XCTAssertEqual(try storedGroup(f, name: "Target").assetIDs, [files[1].id])
        XCTAssertEqual(try storedGroup(f, name: "Other").assetIDs, other.assetIDs)
        model.undo()
        XCTAssertEqual(try storedGroup(f, name: "Target").assetIDs, order)
    }

    @MainActor func testClickedPhotoMembershipNeverExpandsOtherSelectionOrConfirmedRAWJPEGPartner() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ExactClicked", filenames: ["SHOT.ARW", "SHOT.JPG", "target.jpg", "selected.jpg"])
        let files = try f.store.loadAssets()
        let raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" })
        let jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        let target = try XCTUnwrap(files.first { $0.filename == "target.jpg" })
        let selected = try XCTUnwrap(files.first { $0.filename == "selected.jpg" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        try f.store.createGroup(ids: [target.id], name: "Target", kind: "延时")
        let group = try storedGroup(f, name: "Target")
        let beforeBytes = try files.map { try Data(contentsOf: $0.resolvedURL) }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.select(selected); model.select(target, modifiers: .command)
        let selection = model.selectedIDs, focus = model.focusedID, mode = model.mode
        XCTAssertTrue(model.membershipGroups(for: jpeg.id, containing: false).contains { $0.id == group.id })
        model.previewPhotoMembership(assetID: jpeg.id, groupID: group.id, adding: true)
        let appendPreview = try XCTUnwrap(model.groupPreview)
        guard case .addMembers(let id, let ids) = appendPreview.request else { return XCTFail("Expected clicked-photo append") }
        XCTAssertEqual(id, group.id); XCTAssertEqual(ids, [jpeg.id])
        XCTAssertEqual(model.selectedIDs, selection); XCTAssertEqual(model.focusedID, focus); XCTAssertEqual(model.mode, mode)
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        XCTAssertEqual(try storedGroup(f, name: "Target").assetIDs, [target.id, jpeg.id])
        XCTAssertEqual(model.selectedIDs, selection); XCTAssertEqual(model.focusedID, focus)
        model.previewPhotoMembership(assetID: jpeg.id, groupID: group.id, adding: false)
        let removePreview = try XCTUnwrap(model.groupPreview)
        guard case .removeMembers(_, let removal) = removePreview.request else { return XCTFail("Expected clicked-photo removal") }
        XCTAssertEqual(removal, [jpeg.id]); XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        XCTAssertEqual(try storedGroup(f, name: "Target").assetIDs, [target.id])
        XCTAssertFalse(model.groups.contains { $0.assetIDs.contains(raw.id) })
        XCTAssertEqual(model.selectedIDs, selection); XCTAssertEqual(model.focusedID, focus); XCTAssertEqual(model.mode, mode)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0.resolvedURL) }, beforeBytes)
    }

    @MainActor func testMembershipRequiresSameProjectVisibleClickedPhotoAndRechecksFilteredAdditionAtApply() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let a = try await f.populate("ProjectA"), b = try await f.populate("ProjectB")
        let all = try f.store.loadAssets()
        let files = all.filter { $0.projectID == a.projectID }, foreign = all.filter { $0.projectID == b.projectID }
        try f.store.createGroup(ids: [files[0].id], name: "Local", kind: "延时")
        try f.store.createGroup(ids: [foreign[0].id], name: "Foreign", kind: "延时")
        let local = try storedGroup(f, name: "Local"), other = try storedGroup(f, name: "Foreign")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: a.projectID)
        XCTAssertFalse(model.membershipGroups(for: files[1].id, containing: false).contains { $0.id == other.id })
        model.previewPhotoMembership(assetID: files[1].id, groupID: other.id, adding: true)
        XCTAssertNil(model.groupPreview)
        model.searchQuery.filename = files[0].filename
        XCTAssertTrue(model.membershipGroups(for: files[1].id, containing: false).isEmpty)
        model.previewPhotoMembership(assetID: files[1].id, groupID: local.id, adding: true)
        XCTAssertNil(model.groupPreview)
        XCTAssertFalse(model.previewGroup(.addMembers(groupID: local.id, assetIDs: [files[1].id]), showSheet: false))
        model.clearProjectSearch()
        model.previewPhotoMembership(assetID: files[1].id, groupID: local.id, adding: true)
        XCTAssertNotNil(model.groupPreview)
        let historyCount = try f.store.loadGroupCommands().count
        model.searchQuery.filename = files[0].filename
        XCTAssertFalse(model.applyGroupPreview(), "A filtered-away clicked addition cannot be applied from an old preview")
        XCTAssertEqual(try f.store.loadGroupCommands().count, historyCount)
        XCTAssertEqual(try storedGroup(f, name: "Local").assetIDs, [files[0].id])
    }

    @MainActor func testBusyAndTimelapseBlockCreationMembershipAndApplicationWithoutConsumingPreview() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("Busy")
        let files = try f.store.loadAssets()
        try f.store.createGroup(ids: [files[0].id], name: "Target", kind: "延时")
        let group = try storedGroup(f, name: "Target")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        model.select(files[1])
        model.previewPhotoMembership(assetID: files[1].id, groupID: group.id, adding: true)
        let previewID = try XCTUnwrap(model.groupPreview).id
        let history = try f.store.loadGroupCommands().count
        model.qualityAnalysisRunning = true
        XCTAssertFalse(model.canCreateGroup); XCTAssertFalse(model.canEditGroup(group.id))
        XCTAssertTrue(model.membershipGroups(for: files[1].id, containing: false).isEmpty)
        XCTAssertFalse(model.applyGroupPreview()); XCTAssertEqual(model.groupPreview?.id, previewID)
        model.qualityAnalysisRunning = false; model.showTimelapse = true
        XCTAssertFalse(model.canCreateGroup); XCTAssertFalse(model.canEditGroup(group.id)); XCTAssertFalse(model.applyGroupPreview())
        XCTAssertEqual(try f.store.loadGroupCommands().count, history)
        model.showTimelapse = false
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        XCTAssertEqual(model.undoCount, 1)
    }

    @MainActor func testNewCreateRequiresExplicitSelectionBothAtPreviewAndAtCommit() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("ExplicitCreate")
        let files = try f.store.loadAssets()
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.select(files[0])
        XCTAssertFalse(model.previewGroup(.createWithProperties(assetIDs: [files[0].id, files[1].id], name: "Too broad", kind: "延时", locked: false), showSheet: false))
        XCTAssertTrue(try f.store.loadGroups().isEmpty)
        XCTAssertTrue(model.previewGroup(.createWithProperties(assetIDs: [files[0].id], name: "Selected", kind: "校准", locked: false), showSheet: false))
        model.select(files[1])
        XCTAssertFalse(model.applyGroupPreview()); XCTAssertTrue(try f.store.loadGroups().isEmpty)
        model.select(files[0]); XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        let created = try storedGroup(f, name: "Selected")
        XCTAssertEqual(created.assetIDs, [files[0].id]); XCTAssertFalse(created.locked)
    }

    @MainActor func testPropertyDraftSavesEveryEditableFieldInOneUndoAndSurvivesReopen() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("Properties")
        let files = try f.store.loadAssets()
        try f.store.createGroup(ids: files.map(\.id), name: "Original", kind: "连拍")
        let original = try storedGroup(f, name: "Original")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.group, id: original.id); model.editGroup(original.id)
        XCTAssertTrue(model.showGroups)
        var draft = GroupEditorDrafts(group: original, defaultName: "Unused")
        draft.properties.name = "Changed"; draft.properties.kind = "校准"; draft.properties.locked = false
        let request = draft.request(editing: original, selectedIDs: model.actionAssetIDs, movedIDs: [], compatibleGroups: model.manageableGroups)
        guard case .updateProperties(let id, let name, let kind, let locked) = request else { return XCTFail("Default workflow must save all properties atomically") }
        XCTAssertEqual(id, original.id); XCTAssertEqual(name, "Changed"); XCTAssertEqual(kind, "校准"); XCTAssertFalse(locked)
        XCTAssertTrue(model.previewGroup(request, showSheet: false)); XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        XCTAssertEqual(model.undoCount, 1)
        let edited = try storedGroup(f, name: "Changed")
        XCTAssertEqual(edited.kind, "校准"); XCTAssertFalse(edited.locked); XCTAssertEqual(edited.assetIDs, original.assetIDs)
        model.undo()
        XCTAssertEqual(model.undoCount, 0)
        let restored = try storedGroup(f, name: "Original")
        XCTAssertEqual(restored.kind, original.kind); XCTAssertEqual(restored.locked, original.locked)
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(reopened.groups.first { $0.id == original.id }?.name, "Original")
    }

    func testPropertiesMergeAndSplitDraftsRetainSeparateEditsAndConsumeTheirOwnVisibleFields() {
        let first = CaptureGroup(id: "one", projectID: "p", name: "Original", kind: "延时", assetIDs: ["a", "b"], includedAssetIDs: ["a", "b"])
        let second = CaptureGroup(id: "two", projectID: "p", name: "Second", assetIDs: ["c"], includedAssetIDs: ["c"])
        var drafts = GroupEditorDrafts(group: first, defaultName: "Unused")
        drafts.properties = GroupPropertiesDraft(name: "Properties draft", kind: "校准", locked: false)
        drafts.workflow = .merge; drafts.merge.name = "Merge draft"; drafts.merge.kind = "HDR"; drafts.mergeIDs.insert(second.id)
        drafts.workflow = .split; drafts.split.name = "Split draft"; drafts.split.kind = "星空"
        guard case .split(let id, let moved, let splitName, let splitKind) = drafts.request(editing: first, selectedIDs: [], movedIDs: ["b"], compatibleGroups: [first, second]) else { return XCTFail("Expected split") }
        XCTAssertEqual(id, first.id); XCTAssertEqual(moved, ["b"]); XCTAssertEqual(splitName, "Split draft"); XCTAssertEqual(splitKind, "星空")
        drafts.workflow = .merge
        guard case .merge(let mergeIDs, let mergeName, let mergeKind) = drafts.request(editing: first, selectedIDs: [], movedIDs: [], compatibleGroups: [second, first]) else { return XCTFail("Expected merge") }
        XCTAssertEqual(mergeIDs, [first.id, second.id]); XCTAssertEqual(mergeName, "Merge draft"); XCTAssertEqual(mergeKind, "HDR")
        drafts.workflow = .properties
        XCTAssertEqual(drafts.properties, GroupPropertiesDraft(name: "Properties draft", kind: "校准", locked: false))
        guard case .createWithProperties(let createdIDs, let newName, let newKind, let locked) = drafts.request(editing: nil, selectedIDs: ["a"], movedIDs: [], compatibleGroups: []) else { return XCTFail("Creation must consume all displayed properties") }
        XCTAssertEqual(createdIDs, ["a"]); XCTAssertEqual(newName, "Properties draft"); XCTAssertEqual(newKind, "校准"); XCTAssertFalse(locked)
    }

    @MainActor func testCatalogPropertyEntryTargetsClickedGroupReturnsToCatalogAndRetainsCurrentEmptyDetail() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("CatalogEditing")
        let files = try f.store.loadAssets()
        try f.store.createGroup(ids: [files[0].id, files[1].id], name: "Clicked", kind: "延时")
        try f.store.createGroup(ids: [files[2].id], name: "Unrelated empty", kind: "HDR")
        let target = try storedGroup(f, name: "Clicked"), unrelated = try storedGroup(f, name: "Unrelated empty")
        _ = try f.store.commitGroupCommand(f.store.previewGroupCommand(.removeMembers(groupID: unrelated.id, assetIDs: unrelated.assetIDs)))
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.openSequenceCatalog(); model.sequenceCatalogQuery = "Clicked"; model.sequenceCatalogType = .timelapse
        XCTAssertTrue(model.canOpenCatalogGroupProperties(target.id)); XCTAssertFalse(model.canOpenCatalogGroupProperties(unrelated.id))
        model.openCatalogGroupProperties(target.id)
        XCTAssertEqual(model.scope, .group); XCTAssertEqual(model.scopeID, target.id); XCTAssertEqual(model.groupEditingID, target.id)
        XCTAssertTrue(model.showGroups); XCTAssertTrue(model.canReturnToCatalog)
        model.showGroups = false; model.returnToCatalog()
        XCTAssertEqual(model.scope, .sequences); XCTAssertEqual(model.sequenceCatalogAnchorID, target.id)
        XCTAssertEqual(model.sequenceCatalogQuery, "Clicked"); XCTAssertEqual(model.sequenceCatalogType, .timelapse)
        model.openCatalogSequence(id: target.id)
        model.selectedIDs = Set(target.assetIDs); model.performGroupSelectionAction()
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        model.reload()
        XCTAssertEqual(model.scope, .group); XCTAssertEqual(model.scopeID, target.id, "Removing all members must not lose the current detail")
        XCTAssertTrue(model.scopedAssets.isEmpty); XCTAssertTrue(model.canEditGroup(target.id))
        XCTAssertFalse(model.visibleGroups.contains { $0.id == target.id }); XCTAssertFalse(model.sequenceCatalogItems.contains { $0.id == target.id })
        XCTAssertFalse(model.canEditGroup(unrelated.id))
        XCTAssertFalse(model.previewGroup(.updateProperties(groupID: unrelated.id, name: "Forbidden", kind: "HDR", locked: false), showSheet: false))
        model.editGroup(target.id); XCTAssertTrue(model.showGroups)
        XCTAssertTrue(model.previewGroup(.updateProperties(groupID: target.id, name: "Named empty", kind: "校准", locked: false), showSheet: false))
        let propertyCommandID = try XCTUnwrap(model.groupPreview).id
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        XCTAssertFalse(try storedGroup(f, name: "Named empty").locked)
        model.openGroupHistory()
        XCTAssertTrue(model.previewGroup(.restore(commandID: propertyCommandID), showSheet: false), model.errorMessage ?? "")
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        let restoredEmpty = try storedGroup(f, name: "Clicked")
        XCTAssertEqual(restoredEmpty.kind, target.kind); XCTAssertEqual(restoredEmpty.locked, target.locked)
        XCTAssertTrue(restoredEmpty.assetIDs.isEmpty); XCTAssertTrue(restoredEmpty.includedAssetIDs.isEmpty)
        // Historical one-field operations can exist on an empty group, but cannot use the new
        // full-property history exception to broaden empty-scope mutation permissions.
        let oldLock = try f.store.commitGroupCommand(f.store.previewGroupCommand(.setLocked(groupID: target.id, locked: false)))
        model.reload()
        let commandCount = try f.store.loadGroupCommands().count
        XCTAssertFalse(model.previewGroup(.restore(commandID: oldLock.id), showSheet: false))
        XCTAssertEqual(try f.store.loadGroupCommands().count, commandCount)
        model.showGroupHistory = false
        model.returnToCatalog(); XCTAssertEqual(model.scope, .sequences)
        XCTAssertFalse(model.canOpenCatalogGroupProperties(target.id), "An empty group is not added to catalog visibility")
    }

    @MainActor func testTriageMembershipStaysInSessionAndHistoryRemainsReadOnly() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let published = try await f.populate("Published")
        let staged = try await f.populate("Staged", screening: true)
        let all = try f.store.loadAssets()
        let liveFiles = all.filter { $0.sessionID == published.id }, stagedFiles = all.filter { $0.sessionID == staged.id }
        try f.store.createGroup(ids: [liveFiles[0].id], name: "Published group", kind: "延时")
        try f.store.createGroup(ids: [stagedFiles[0].id], name: "Staged group", kind: "延时")
        let liveGroup = try storedGroup(f, name: "Published group"), stagedGroup = try storedGroup(f, name: "Staged group")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: staged.id); XCTAssertTrue(model.isTriageScope)
        XCTAssertFalse(model.membershipGroups(for: stagedFiles[1].id, containing: false).contains { $0.id == liveGroup.id })
        model.previewPhotoMembership(assetID: stagedFiles[1].id, groupID: liveGroup.id, adding: true); XCTAssertNil(model.groupPreview)
        model.previewPhotoMembership(assetID: stagedFiles[1].id, groupID: stagedGroup.id, adding: true)
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        model.selectTriageGroup(stagedGroup.id)
        XCTAssertFalse(model.canCreateGroup); XCTAssertEqual(model.groupSelectionActionTitle, "从拍摄组中移除")
        model.selectedIDs = [stagedFiles[0].id]; model.performGroupSelectionAction()
        XCTAssertTrue(model.applyGroupPreview(), model.errorMessage ?? "")
        XCTAssertEqual(try storedGroup(f, name: "Staged group").assetIDs, [stagedFiles[1].id])
        XCTAssertEqual(try storedGroup(f, name: "Published group").assetIDs, liveGroup.assetIDs)
        model.selectTriageGroup(nil); model.prepareCompletion(); model.acknowledgeManualCompletion(true)
        XCTAssertTrue(model.completeTriage(), model.errorMessage ?? "")
        model.selectScope(.session, id: staged.id); XCTAssertTrue(model.isHistoryScope)
        XCTAssertFalse(model.canCreateGroup); XCTAssertFalse(model.canEditGroup(stagedGroup.id))
        XCTAssertTrue(model.membershipGroups(for: stagedFiles[1].id, containing: true).isEmpty)
        XCTAssertFalse(model.previewGroup(.updateProperties(groupID: stagedGroup.id, name: "History edit", kind: "HDR", locked: false), showSheet: false))
    }
}
