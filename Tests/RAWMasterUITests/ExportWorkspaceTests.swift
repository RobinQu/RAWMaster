import XCTest
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

final class ExportWorkspaceTests:XCTestCase{
    @MainActor func testMultiSelectionUsesWorkspaceAndExportsEveryCurrentPhoto()async throws{
        let fixture=try AppModelTests.Fixture();defer{fixture.clean()}
        _=try await fixture.populate(count:2)
        let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
        let ids=model.assets.map(\.id);XCTAssertEqual(ids.count,2)
        model.workbenchExportContext = .selection(ids:ids);model.activateWorkflow(.export)
        XCTAssertTrue(model.exportWorkspacePresented);XCTAssertFalse(model.showExport)
        let destination=fixture.root.appendingPathComponent("exports",isDirectory:true)
        let files=try await model.exportWorkbenchPhotos(directory:destination,namingTemplate:"{name}-{index}",configuration:.init(format:.jpeg8,maximumLongEdge:64,jpegQuality:0.8)){_,_,_ in}
        XCTAssertEqual(files.count,2)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)),["0000-0001.jpg","0001-0002.jpg"])
        XCTAssertTrue(files.allSatisfy{FileManager.default.fileExists(atPath:$0.path)})
        model.activateWorkflow(.library);XCTAssertFalse(model.exportWorkspacePresented)
        await model.editing?.shutdown()
    }
}
