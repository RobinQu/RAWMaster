import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosNoiseReductionDetailWorkflowTests:XCTestCase {
  @MainActor func testContrastAndColorDetailPersistAndUndoRedo()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    for (control,value) in [(PhotosNoiseReductionDetailControl.luminanceContrast,40.0),(.colorDetail,60.0)] {
      let command=try PhotosNoiseReductionDetailControl.command(control,value:value,parameters:session.parameters.noiseReduction,capability:session.noiseReductionCapability)
      try session.apply(command,event:.init(context:context,control:.init(group:.noiseReduction,name:control.title)))
    }
    let saved=session.parameters.noiseReduction
    XCTAssertEqual(saved.luminanceContrast,0.4);XCTAssertEqual(saved.colorDetail,0.6);XCTAssertTrue(saved.enabled)
    try session.undo(context:context);try session.undo(context:context)
    XCTAssertEqual(session.parameters.noiseReduction,DevelopmentNoiseReductionV3())
    try session.redo(context:context);try session.redo(context:context)
    XCTAssertEqual(session.parameters.noiseReduction,saved)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.noiseReduction,saved)
  }
}
