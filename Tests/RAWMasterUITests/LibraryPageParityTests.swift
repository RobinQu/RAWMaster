import Foundation
import XCTest
import RAWMasterCore
import RAWMasterLibrary
@testable import RAWMaster

final class LibraryPageParityTests: XCTestCase {
    func testExistingCatalogMatchesLegacyFilteredOrderAndBulkScope() throws {
        guard let source = ProcessInfo.processInfo.environment["RM_CATALOG_BACKUP"] else { throw XCTSkip("需要实拍资料库的一致副本") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let catalog = root.appendingPathComponent("library.sqlite")
        try fm.copyItem(at: URL(fileURLWithPath: source), to: catalog)
        let store = try LibraryStore(databaseURL: catalog)
        let snapshot = try LibrarySnapshot.read(store: store, groupingSessionID: nil)
        let admitted = Set(snapshot.admissions.map(\.assetID))
        let reviewed = Set(snapshot.reviewRecords.filter(\.reviewed).map(\.assetID))
        let index = root.appendingPathComponent("search.sqlite")
        let engine = try LibraryEngine.shared()
        let filters: [(ProjectSearchQuery,ProjectReviewSort,String?)] = [
            (.init(),.original,nil), (.init(),.capturedAscending,nil), (.init(),.filename,nil),
            (.init(),.capturedDescending,nil), (.init(minimumRating: 3),.ratingDescending,nil),
            (.init(filename:"DSC"),.filename,nil), (.init(filename:"照片"),.original,nil), (.init(filename:"鸟"),.original,nil),
            (.init(camera:snapshot.assets.compactMap(\.camera).first),.capturedDescending,nil),
            (.init(availability:.available,review:.unreviewed),.capturedAscending,nil),
            (.init(),.original,snapshot.admissions.first?.projectID)]
        for (q, sort, project) in filters {
            let allowed = snapshot.assets.filter { admitted.contains($0.id) && (project == nil || $0.projectID == project) }
            let expected = try AssetSearchEngine.filter(assets: allowed, query:q, tags:snapshot.assetTags, reviewedIDs:reviewed,
                                                       sort:sort,colorLabels:snapshot.assetColorLabels).map(\.id)
            var request = CatalogGridRequest(query:q,sort:sort.rawValue,projectID:project,includeOrderedIDs:true)
            var ids: [String] = []
            repeat {
                let page = try engine.request("page",at:catalog,index:index,payload:request,as:CatalogGridPage<AssetRecord>.self)
                XCTAssertEqual(page.status,"ok")
                if request.cursor == nil {
                    XCTAssertEqual(page.totalFiles,expected.count)
                    XCTAssertTrue(page.orderedAssetIDs == expected, "批量范围 \(sort.rawValue)，期望 \(expected.count) 条；首个差异 \(zip(page.orderedAssetIDs ?? [],expected).first { $0 != $1 }.map { "\($0.0)/\($0.1)" } ?? "长度不同")")
                }
                ids += try XCTUnwrap(page.items).map(\.assetID)
                request.cursor = page.nextCursor
                request.includeOrderedIDs = false
            } while request.cursor != nil
            XCTAssertTrue(ids == expected, "分页 \(sort.rawValue)，\(ids.count)/\(expected.count) 条")
        }
    }
}
