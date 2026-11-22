import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class PhotosLensBlurSubjectFocusTests:XCTestCase {
  @MainActor func testSubjectFocusAppliesEstimatedValuesWithUndoRedoAndPersistence()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    editing.developmentSubjectFocusProvider={_ in .init(focusX:0.3,focusY:0.6,focusRange:0.25,weightedPixelCount:100)}
    editing.focusDevelopmentLensBlurSubject(context:context)
    for _ in 0..<500 where session.parameters.effects?.lensBlur == nil{try await Task.sleep(nanoseconds:10_000_000)}
    let blur=try XCTUnwrap(session.parameters.effects?.lensBlur)
    XCTAssertEqual(blur.focusX,0.3);XCTAssertEqual(blur.focusY,0.6);XCTAssertEqual(blur.focusRange,0.25);XCTAssertTrue(blur.enabled)
    try session.undo(context:context);XCTAssertNil(session.parameters.effects)
    try session.redo(context:context);XCTAssertEqual(session.parameters.effects?.lensBlur,blur)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.effects?.lensBlur,blur)
  }
}
