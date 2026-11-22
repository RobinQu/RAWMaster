import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosSharpeningWorkflowTests:XCTestCase {
  @MainActor func testExplicitDetailControlsPersistAndUndoRedo()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    for (control,value) in [(PhotosSharpeningControl.radius,1.4),(.detail,65.0),(.masking,35.0)] {
      let command=try PhotosSharpeningControl.command(control,value:value,parameters:session.parameters.sharpen)
      try session.apply(command,event:.init(context:context,control:.init(group:.sharpen,name:control.title)))
    }
    let saved=session.parameters.sharpen
    XCTAssertEqual(saved.radius,1.4);XCTAssertEqual(saved.detail,0.65);XCTAssertEqual(saved.masking,0.35);XCTAssertTrue(saved.enabled)
    try session.undo(context:context);try session.undo(context:context);try session.undo(context:context)
    XCTAssertEqual(session.parameters.sharpen,DevelopmentSharpenV3())
    try session.redo(context:context);try session.redo(context:context);try session.redo(context:context)
    XCTAssertEqual(session.parameters.sharpen,saved)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.sharpen,saved)
  }
}
