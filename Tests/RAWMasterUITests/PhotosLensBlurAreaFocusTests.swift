import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosLensBlurAreaFocusTests:XCTestCase {
  @MainActor func testAreaFocusMapsCenterAndShortSideRadiusWithUndoRedo()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    for _ in 0..<500 where editing.developmentPicker == nil {
      editing.beginDevelopmentPicker(.lensBlurArea,context:context)
      if editing.developmentPicker == nil{try await Task.sleep(nanoseconds:10_000_000)}
    }
    let picker=try XCTUnwrap(editing.developmentPicker),frame=try XCTUnwrap(editing.developmentPickerFrame(for:picker))
    editing.pickDevelopmentArea(.init(x:0.2,y:0.2),end:.init(x:0.4,y:0.5),frame:frame)
    let blur=try XCTUnwrap(session.parameters.effects?.lensBlur)
    XCTAssertEqual(blur.focusX,0.3,accuracy:1e-6);XCTAssertEqual(blur.focusY,0.35,accuracy:1e-6)
    XCTAssertEqual(blur.focusRange,sqrt(24*24+24*24)/80,accuracy:1e-6);XCTAssertTrue(blur.enabled)
    XCTAssertNil(editing.developmentPicker)
    try session.undo(context:context);XCTAssertNil(session.parameters.effects)
    try session.redo(context:context);XCTAssertEqual(session.parameters.effects?.lensBlur,blur)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.effects?.lensBlur,blur)
  }
}
