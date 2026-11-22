import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosSharpeningMaskPreviewTests:XCTestCase {
  @MainActor func testTemporaryMaskPreviewTracksEditsWithoutPersistingPreviewFlag()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let original=editing.recipe,history=session.history.entryCount
    editing.setDevelopmentSharpeningMaskPreview(true,context:context)
    for _ in 0..<500 where editing.sharpeningMaskPreviewFrame == nil {try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertTrue(editing.developmentSharpeningMaskPreviewActive);XCTAssertNotNil(editing.sharpeningMaskPreviewFrame)
    XCTAssertEqual(editing.recipe,original);XCTAssertEqual(session.history.entryCount,history)
    let firstFrame=editing.sharpeningMaskPreviewFrame?.id
    let command=try PhotosSharpeningControl.command(.masking,value:70,parameters:session.parameters.sharpen)
    try session.apply(command,event:.init(context:context,control:.init(group:.sharpen,name:"蒙版")))
    XCTAssertEqual(session.parameters.sharpen.masking,0.7);XCTAssertNil(session.parameters.sharpen.visualiseMasking)
    for _ in 0..<500 where editing.sharpeningMaskPreviewFrame?.id == firstFrame {try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertTrue(editing.developmentSharpeningMaskPreviewActive)
    XCTAssertEqual(session.history.entryCount,history+1,"Only the actual masking edit creates history")
    editing.cancelDevelopmentSharpeningMaskPreview()
    XCTAssertFalse(editing.developmentSharpeningMaskPreviewActive);XCTAssertNil(editing.sharpeningMaskPreviewFrame)
    XCTAssertNil(editing.recipe.adjustmentsV3?.sharpen.visualiseMasking)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.sharpen.masking,0.7)
    XCTAssertNil(work.liveRecipe?.adjustmentsV3?.sharpen.visualiseMasking)
  }
}
