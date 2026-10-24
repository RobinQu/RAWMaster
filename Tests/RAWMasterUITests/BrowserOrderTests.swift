import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class BrowserOrderTests: XCTestCase {
    @MainActor func testScrambledRegistrationShowsEveryFrameInNaturalOrderWithoutChangingStoredData() throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let project = ProjectRecord(name: "Unsorted discovery")
        try fixture.store.saveProject(project)
        let session = ImportSession(projectID: project.id, projectName: project.name,
            sourcePath: fixture.source.path, mode: .reference)
        try fixture.store.saveSession(session)
        let names = ["DSC01510.ARW", "DSC01497.ARW", "DSC01500.ARW", "DSC01498.ARW", "DSC01499.ARW"]
        for (index, name) in names.enumerated() {
            _ = try fixture.store.register(AssetRecord(sessionID: session.id, projectID: project.id,
                sourcePath: fixture.source.appendingPathComponent(name).path,
                decision: index == 0 ? .reject : .undecided, rating: index, importState: .ready))
        }
        let stored = try fixture.store.loadAssets()
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.session, id: session.id)
        XCTAssertEqual(model.filteredAssets.map(\.filename), names.sorted())
        XCTAssertEqual(Set(model.filteredAssets.map(\.id)), Set(stored.map(\.id)), "Sorting must never filter rejected or near-identical frames")
        let focus = model.filteredAssets[1]
        model.select(focus); model.reload()
        XCTAssertEqual(model.focusedID, focus.id)
        model.move(1)
        XCTAssertEqual(model.focusedAsset?.filename, "DSC01499.ARW")
        let reopened = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        XCTAssertEqual(reopened.assets.map(\.id), model.assets.map(\.id))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(stored), try encoder.encode(fixture.store.loadAssets()), "Browse order must not rewrite decisions, ratings, identity or storage order")
    }

    @MainActor func testNaturalPathOrderKeepsSessionsTogetherAndManualGroupOrderAuthoritative() throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let project = ProjectRecord(name: "Sessions")
        try fixture.store.saveProject(project)
        var ids: [String] = []
        for (sessionIndex, paths) in [["card10/DSC10.ARW", "card2/DSC10.ARW", "card2/DSC2.ARW"], ["DSC1.ARW", "DSC1.arw"]].enumerated() {
            let session = ImportSession(projectID: project.id, projectName: project.name,
                sourcePath: fixture.source.appendingPathComponent("session\(sessionIndex)").path, mode: .reference)
            try fixture.store.saveSession(session)
            for path in paths {
                let asset = try fixture.store.register(AssetRecord(sessionID: session.id, projectID: project.id,
                    sourcePath: fixture.source.appendingPathComponent("session\(sessionIndex)/\(path)").path,
                    relativePath: path, importState: .ready))
                ids.append(asset.id)
            }
        }
        try fixture.store.createGroup(ids: [ids[1], ids[0], ids[2]], name: "Manual order", kind: "其他")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        XCTAssertEqual(model.assets.map(\.relativePath), ["card2/DSC2.ARW", "card2/DSC10.ARW", "card10/DSC10.ARW", "DSC1.ARW", "DSC1.arw"])
        let group = try XCTUnwrap(model.groups.first)
        model.selectScope(.group, id: group.id)
        XCTAssertEqual(model.scopedAssets.map(\.id), [ids[1], ids[0], ids[2]], "Manual sequence order must not be replaced by filename order")
    }
}
