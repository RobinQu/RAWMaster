import XCTest
import RAWMasterCore
@testable import RAWMaster

final class GroupWorkflowTests: XCTestCase {
    @MainActor func testRuntimeUndoInterleavesSelectionsAndGroupCommandsInActionOrder() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 2)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let asset = try XCTUnwrap(model.assets.first)
        model.select(asset); model.saveGroup(name: "Original", kind: "连拍", mergeIDs: [])
        let groupID = try XCTUnwrap(model.groups.first?.id)
        model.decide(.keep)
        XCTAssertTrue(model.previewGroup(.rename(groupID: groupID, name: "Renamed"), showSheet: false))
        XCTAssertTrue(model.applyGroupPreview())
        model.decide(rating: 5)
        XCTAssertEqual(model.undoCount, 4)
        model.undo()
        XCTAssertEqual(model.assets.first?.rating, 0); XCTAssertEqual(model.assets.first?.decision, .keep)
        XCTAssertEqual(model.groups.first?.name, "Renamed")
        model.undo()
        XCTAssertEqual(model.groups.first?.name, "Original"); XCTAssertEqual(model.assets.first?.decision, .keep)
        model.undo()
        XCTAssertEqual(model.assets.first?.decision, .undecided); XCTAssertEqual(model.groups.count, 1)
        model.undo()
        XCTAssertTrue(model.groups.isEmpty); XCTAssertEqual(model.undoCount, 0)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testRestartHistoryRestoreIsNewUndoableAction() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 1)
        let original = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        original.saveGroup(name: "Before", kind: "Custom purpose", mergeIDs: [])
        let id = try XCTUnwrap(original.groups.first?.id)
        XCTAssertTrue(original.previewGroup(.rename(groupID: id, name: "After"), showSheet: false))
        XCTAssertTrue(original.applyGroupPreview())
        let reopened = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        XCTAssertEqual(reopened.undoCount, 0, "Restart does not claim a persistent photo/runtime undo stack")
        let rename = try XCTUnwrap(reopened.groupHistory.first { if case .rename = $0.request { return true }; return false })
        XCTAssertTrue(rename.restoreStatus.isAvailable)
        reopened.openGroupHistory()
        XCTAssertTrue(reopened.previewGroup(.restore(commandID: rename.id), showSheet: false))
        XCTAssertTrue(reopened.applyGroupPreview())
        XCTAssertEqual(reopened.groups.first?.name, "Before"); XCTAssertEqual(reopened.undoCount, 1)
        reopened.undo()
        XCTAssertEqual(reopened.groups.first?.name, "After"); XCTAssertEqual(reopened.undoCount, 0)
        XCTAssertEqual(reopened.groups.first?.kind, "Custom purpose")
    }

    @MainActor func testMergeCannotCommitUntilEveryParticipationConflictIsExplicit() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 3)
        let ids = try fixture.store.loadAssets().map(\.id)
        try fixture.store.createGroup(ids: Array(ids.prefix(2)), name: "Burst", kind: "连拍")
        try fixture.store.createGroup(ids: [ids[0], ids[2]], name: "HDR", kind: "HDR")
        let stored = try fixture.store.loadGroups()
        let second = try XCTUnwrap(stored.first { $0.name == "HDR" })
        try fixture.store.setSequenceMembership(ids: [ids[0]], included: false, groupID: second.id)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let before = model.groups
        XCTAssertTrue(model.previewGroup(.merge(groupIDs: before.map(\.id), name: "Merged", kind: "其他")))
        XCTAssertTrue(model.showGroupReview)
        XCTAssertEqual(model.groupPreview?.inclusionConflicts.map(\.assetID), [ids[0]])
        XCTAssertFalse(model.applyGroupPreview())
        XCTAssertEqual(model.groups.count, 2); XCTAssertEqual(model.undoCount, 0)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.applyGroupPreview(resolutions: [ids[0]: false]))
        let merged = try XCTUnwrap(model.groups.first)
        XCTAssertEqual(model.groups.count, 1); XCTAssertFalse(merged.includedAssetIDs.contains(ids[0]))
        XCTAssertEqual(Set(merged.assetIDs), Set(ids))
        model.undo()
        XCTAssertEqual(Set(model.groups.map(\.id)), Set(before.map(\.id)))
        XCTAssertEqual(model.groups.first { $0.id == second.id }?.includedAssetIDs, second.includedAssetIDs.filter { $0 != ids[0] })
    }

    @MainActor func testSplitRetainsOrderAndParticipationAndRepairsOutOfScopeFocus() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 4)
        let ids = try fixture.store.loadAssets().map(\.id)
        try fixture.store.createGroup(ids: ids, name: "Sequence", kind: "延时")
        let id = try XCTUnwrap(try fixture.store.loadGroups().first?.id)
        try fixture.store.setSequenceMembership(ids: [ids[3]], included: false, groupID: id)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.group, id: id)
        model.select(try XCTUnwrap(model.assets.first { $0.id == ids[1] }))
        model.selectedIDs = [ids[3], ids[1]]; model.actualPixels = true
        XCTAssertTrue(model.previewGroup(.split(groupID: id, movedAssetIDs: [ids[1], ids[3]], newName: "Split", newKind: "星空"), showSheet: false))
        XCTAssertEqual(model.groups.count, 1, "Preview must not create formal groups")
        let after = try XCTUnwrap(model.groupPreview?.after.first { $0.name == "Split" })
        XCTAssertEqual(after.assetIDs, [ids[1], ids[3]])
        XCTAssertEqual(after.includedAssetIDs, [ids[1]])
        XCTAssertTrue(model.applyGroupPreview())
        XCTAssertEqual(model.groups.first { $0.id == id }?.assetIDs, [ids[0], ids[2]])
        XCTAssertEqual(model.focusedID, ids[2]); XCTAssertFalse(model.actualPixels, "A replacement focus starts at fit rather than silently requesting RAW detail")
        XCTAssertTrue(model.selectedIDs.isSubset(of: Set(model.scopedAssets.map(\.id))))
        model.undo()
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertEqual(model.groups.first?.assetIDs, ids)
        XCTAssertEqual(model.groups.first?.includedAssetIDs, Array(ids.prefix(3)))
        XCTAssertFalse(model.previewGroup(.split(groupID: id, movedAssetIDs: ids, newName: "Invalid", newKind: "HDR"), showSheet: false))
        XCTAssertEqual(model.groups.count, 1)
    }

    @MainActor func testProtectedRemoveRequiresReviewAndDoesNotFollowPhotoRejection() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 2)
        let ids = try fixture.store.loadAssets().map(\.id)
        try fixture.store.createGroup(ids: ids, name: "Protected HDR", kind: "HDR")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let group = try XCTUnwrap(model.groups.first)
        XCTAssertTrue(group.locked)
        model.selectScope(.group, id: group.id); model.selectedIDs = Set(ids)
        model.decide(.reject)
        XCTAssertEqual(model.groups.first?.assetIDs, ids)
        XCTAssertEqual(model.groups.first?.includedAssetIDs, ids)
        model.removeFromGroup()
        XCTAssertTrue(model.showGroupReview)
        XCTAssertEqual(model.groups.first?.assetIDs, ids)
        XCTAssertFalse(model.groupPreview?.warnings.isEmpty ?? true)
        XCTAssertTrue(model.applyGroupPreview())
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertTrue(model.groups.first?.assetIDs.isEmpty == true)
        XCTAssertEqual(model.scope, .group); XCTAssertNil(model.focusedID); XCTAssertTrue(model.selectedIDs.isEmpty)
        model.undo()
        XCTAssertEqual(model.groups.first?.assetIDs, ids)
        XCTAssertTrue(model.assets.allSatisfy { $0.decision == .reject })
    }

    @MainActor func testStalePreviewAndUndoConflictKeepStateAndStackForReview() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 1)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.saveGroup(name: "First", kind: "待分类", mergeIDs: [])
        let id = try XCTUnwrap(model.groups.first?.id)
        XCTAssertTrue(model.previewGroup(.rename(groupID: id, name: "Preview"), showSheet: false))
        try fixture.store.renameGroup(id: id, name: "Concurrent")
        XCTAssertFalse(model.applyGroupPreview())
        XCTAssertNotNil(model.groupPreview); XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.undoCount, 1)
        model.refreshGroupPreview()
        XCTAssertNotNil(model.groupPreview); XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.applyGroupPreview())
        XCTAssertEqual(model.undoCount, 2)
        try fixture.store.renameGroup(id: id, name: "Later")
        model.undo()
        XCTAssertEqual(model.undoCount, 2, "A failed undo must not discard or silently skip its chronological entry")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.store.loadGroups().first?.name, "Later")
    }

    @MainActor func testPurposeAndExplicitUnlockPersistAndUndoIndividually() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 1)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.saveGroup(name: "Legacy", kind: "校准", mergeIDs: [])
        let id = try XCTUnwrap(model.groups.first?.id)
        XCTAssertTrue(model.previewGroup(.setKind(groupID: id, kind: "Custom calibration"), showSheet: false)); XCTAssertTrue(model.applyGroupPreview())
        XCTAssertTrue(model.previewGroup(.setLocked(groupID: id, locked: false), showSheet: false)); XCTAssertTrue(model.applyGroupPreview())
        let reopened = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        XCTAssertEqual(reopened.groups.first?.kind, "Custom calibration"); XCTAssertEqual(reopened.groups.first?.locked, false)
        model.undo(); XCTAssertEqual(model.groups.first?.locked, true)
        model.undo(); XCTAssertEqual(model.groups.first?.kind, "校准")
    }
}
