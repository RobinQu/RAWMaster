import XCTest
import SwiftUI
import RAWMasterCore
@testable import RAWMaster

final class SequenceBrowserLayoutTests: XCTestCase {
    private func asset(_ id: String) -> AssetRecord {
        AssetRecord(id: id, sessionID: "session", projectID: "project", sourcePath: "/photos/" + id + ".jpg")
    }
    private func group(_ id: String, _ members: [String]) -> CaptureGroup {
        CaptureGroup(id: id, projectID: "project", name: "序列 " + id, assetIDs: members, includedAssetIDs: members)
    }

    func testInterleavedGroupsBecomeAdjacentRunsWithoutChangingOrder() {
        let photos = ["a", "b", "c", "d", "e"].map(asset)
        let first = group("A", ["a", "b", "d"]), second = group("B", ["c"])
        let layout = BrowserSequenceLayout(assets: photos, groups: [second, first])
        XCTAssertEqual(layout.segments.flatMap(\.assets).map(\.id), photos.map(\.id))
        XCTAssertEqual(layout.segments.map { $0.group?.id }, ["A", "B", "A", nil])
        XCTAssertEqual(layout.segments.map(\.isContinuation), [false, false, true, false])
        XCTAssertEqual(Set(layout.segments.flatMap(\.assets).map(\.id)).count, photos.count)
    }

    func testOverlappingMembershipHasDeterministicPrimaryAndAdditionalGroups() {
        let photos = ["a", "b", "c"].map(asset)
        let first = group("A", ["a", "b"]), second = group("B", ["b", "c"])
        let layout = BrowserSequenceLayout(assets: photos, groups: [second, first])
        XCTAssertEqual(layout.memberships["b"]?.map(\.id), ["A", "B"])
        XCTAssertEqual(layout.primaryGroupID(containing: "b"), "A")
        let reversedInput = BrowserSequenceLayout(assets: photos, groups: [first, second])
        XCTAssertEqual(layout.segments.map(\.id), reversedInput.segments.map(\.id))
        let scoped = BrowserSequenceLayout(assets: photos, groups: [first, second], preferredGroupID: "B")
        XCTAssertEqual(scoped.primaryGroupID(containing: "b"), "B")
        XCTAssertEqual(scoped.segments.flatMap(\.assets).map(\.id), ["a", "b", "c"])
    }

    func testCollapsedPairRepresentativeKeepsRawOnlySequenceMembershipWithoutAddingHiddenFiles() {
        let photos = [asset("jpeg"), asset("other")]
        let rawSequence = group("A", ["raw", "outside-filter"])
        let layout = BrowserSequenceLayout(assets: photos, groups: [rawSequence], representedIDs: ["jpeg": ["jpeg", "raw"]])
        XCTAssertEqual(layout.primaryGroupID(containing: "jpeg"), "A")
        XCTAssertEqual(layout.memberships["jpeg"]?.map(\.id), ["A"])
        XCTAssertEqual(layout.segments.flatMap(\.assets).map(\.id), ["jpeg", "other"])
        XCTAssertNil(layout.memberships["raw"])
        XCTAssertNil(layout.memberships["outside-filter"])
        let expanded = BrowserSequenceLayout(assets: [asset("raw"), asset("jpeg")], groups: [rawSequence])
        XCTAssertEqual(expanded.primaryGroupID(containing: "raw"), "A")
        XCTAssertNil(expanded.primaryGroupID(containing: "jpeg"), "Expanded file cards show their own explicit memberships")
    }

    func testCollapseOnlyChangesPresentationAndCanRevealEveryHiddenRun() {
        let photos = ["a", "b", "c", "d"].map(asset)
        let sequence = group("A", ["a", "c"])
        let layout = BrowserSequenceLayout(assets: photos, groups: [sequence])
        let selection = Set(["a", "c"])
        var collapsed: Set<String> = ["A"]
        XCTAssertEqual(layout.visibleAssets(collapsedGroupIDs: collapsed).map(\.id), ["b", "d"])
        XCTAssertEqual(sequence.assetIDs, ["a", "c"])
        XCTAssertEqual(selection, ["a", "c"], "Presentation collapse has no selection mutation API")
        collapsed.remove(layout.primaryGroupID(containing: "c")!)
        XCTAssertEqual(layout.visibleAssets(collapsedGroupIDs: collapsed).map(\.id), photos.map(\.id))
        XCTAssertEqual(layout.segments.flatMap(\.assets).map(\.id), photos.map(\.id))
    }

    func testSharedGridKeepsFollowingPhotosInThePartiallyFilledSequenceRow() {
        let photos = (0..<9).map { asset(String($0)) }
        let layout = BrowserSequenceLayout(assets: photos, groups: [group("A", ["1", "2", "3", "4"])])
        let items = layout.gridItems(collapsedGroupIDs: [])
        let geometry = SequenceGridGeometry(width: 610)
        XCTAssertEqual(geometry.columns, 3)
        XCTAssertEqual(items.map(\.asset.id), photos.map(\.id))
        // Row 1 holds the final two sequence photos followed immediately by an outsider.
        XCTAssertEqual(Array(items[3...5]).map(\.asset.id), ["3", "4", "5"])
        XCTAssertEqual(geometry.connections(at: 4, in: items), [.leading, .top])
        XCTAssertEqual(geometry.connections(at: 5, in: items), [])
        XCTAssertEqual(geometry.connections(at: 2, in: items), [.leading], "Row wrapping must not fill the outsider's cell or the entire row gutter")
    }

    func testGridFillDoesNotJoinDifferentGroupsOrSeparatedRuns() {
        let layout = BrowserSequenceLayout(assets: ["a", "b", "c", "d"].map(asset),
            groups: [group("A", ["a", "c"]), group("B", ["b", "d"])])
        let items = layout.gridItems(collapsedGroupIDs: [])
        let geometry = SequenceGridGeometry(width: 400)
        XCTAssertEqual(geometry.columns, 2)
        for index in items.indices { XCTAssertEqual(geometry.connections(at: index, in: items), []) }
    }

    func testCollapsedSequenceUsesOneCellAndPreservesFollowingOrder() {
        let photos = ["a", "b", "c", "d", "e"].map(asset)
        let layout = BrowserSequenceLayout(assets: photos, groups: [group("A", ["a", "b", "d"])])
        let items = layout.gridItems(collapsedGroupIDs: ["A"])
        XCTAssertEqual(items.map(\.asset.id), ["a", "c", "d", "e"])
        XCTAssertEqual(items.map(\.collapsed), [true, false, true, false])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertEqual(layout.gridItems(collapsedGroupIDs: []).map(\.asset.id), photos.map(\.id))
    }

    func testGridResizeRecomputesConnectionsWithoutChangingPhotoOrder() {
        let layout = BrowserSequenceLayout(assets: (0..<7).map { asset(String($0)) },
            groups: [group("A", ["1", "2", "3", "4"])])
        let items = layout.gridItems(collapsedGroupIDs: [])
        let wide = SequenceGridGeometry(width: 820)
        XCTAssertEqual(wide.columns, 4)
        XCTAssertEqual(wide.connections(at: 2, in: items), [.leading, .trailing])
        XCTAssertEqual(wide.connections(at: 4, in: items), [])
        let narrow = SequenceGridGeometry(width: 180)
        XCTAssertEqual(narrow.columns, 1)
        XCTAssertLessThanOrEqual(narrow.cellWidth, 180)
        XCTAssertEqual(narrow.connections(at: 2, in: items), [.top, .bottom])
    }

    func testGroupHeaderAppearsOnlyAtSegmentStartAndWrapUsesContinuation() {
        let layout = BrowserSequenceLayout(assets: (0..<9).map { asset(String($0)) },
            groups: [group("A", ["1", "2", "3", "4", "7"])])
        let items = layout.gridItems(collapsedGroupIDs: [])
        let geometry = SequenceGridGeometry(width: 610)
        XCTAssertEqual(items.indices.map { geometry.header(at: $0, in: items) },
            [.none, .start, .none, .continuation, .none, .none, .none, .start, .none])
        XCTAssertEqual(geometry.headerHeight(inRowContaining: 0, items: items), 16)
        XCTAssertEqual(geometry.headerHeight(inRowContaining: 4, items: items), 12)
        let wide = SequenceGridGeometry(width: 820)
        XCTAssertEqual(wide.header(at: 3, in: items), .none)
        XCTAssertEqual(wide.header(at: 4, in: items), .continuation)
    }

    func testOrdinaryRowsHaveNoReservedGroupTitleSpace() {
        let layout = BrowserSequenceLayout(assets: (0..<9).map { asset(String($0)) },
            groups: [group("A", ["1", "2"])])
        let items = layout.gridItems(collapsedGroupIDs: [])
        let geometry = SequenceGridGeometry(width: 610)
        for index in 3..<9 {
            XCTAssertEqual(geometry.header(at: index, in: items), .none)
            XCTAssertEqual(geometry.headerHeight(inRowContaining: index, items: items), 0)
        }
    }

    func testCollapsedRunsKeepExactlyOneHeaderEach() {
        let layout = BrowserSequenceLayout(assets: ["a", "b", "c", "d", "e"].map(asset),
            groups: [group("A", ["a", "b", "d"])])
        let items = layout.gridItems(collapsedGroupIDs: ["A"])
        let geometry = SequenceGridGeometry(width: 610)
        XCTAssertEqual(items.indices.map { geometry.header(at: $0, in: items) }, [.start, .none, .start, .none])
        XCTAssertEqual(items.map(\.asset.id), ["a", "c", "d", "e"])
    }
}
