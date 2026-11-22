import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosLensBlurWorkflowTests:XCTestCase {
  @MainActor func testLensBlurPersistsAndUndoRedo()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let blur=DevelopmentLensBlurV3(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25)
    let effects=DevelopmentEffectsV3(lensBlur:blur)
    try session.apply(.setEffects(effects),event:.init(context:context,control:.init(group:nil,name:"Lens Blur")))
    XCTAssertEqual(session.parameters.effects,effects)
    try session.undo(context:context);XCTAssertNil(session.parameters.effects)
    try session.redo(context:context);XCTAssertEqual(session.parameters.effects,effects)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.effects,effects)
  }
}
