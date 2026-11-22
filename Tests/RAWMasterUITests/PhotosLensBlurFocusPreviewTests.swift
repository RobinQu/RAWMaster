import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosLensBlurFocusPreviewTests:XCTestCase {
  @MainActor func testPointFocusAndTemporaryDepthPreview()async throws {
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
      editing.beginDevelopmentPicker(.lensBlurFocus,context:context)
      if editing.developmentPicker == nil{try await Task.sleep(nanoseconds:10_000_000)}
    }
    let picker=try XCTUnwrap(editing.developmentPicker),frame=try XCTUnwrap(editing.developmentPickerFrame(for:picker))
    editing.pickDevelopmentSource(.init(x:0.25,y:0.75),frame:frame)
    let selected=try XCTUnwrap(session.parameters.effects?.lensBlur)
    XCTAssertEqual(selected.focusX,0.25,accuracy:1e-6);XCTAssertEqual(selected.focusY,0.75,accuracy:1e-6);XCTAssertTrue(selected.enabled)
    XCTAssertNil(editing.developmentPicker)
    let before=editing.recipe,history=session.history.entryCount
    editing.setDevelopmentLensBlurDepthPreview(true,context:context)
    for _ in 0..<500 where editing.lensBlurDepthPreviewFrame == nil{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertNotNil(editing.lensBlurDepthPreviewFrame);XCTAssertEqual(editing.recipe,before);XCTAssertEqual(session.history.entryCount,history)
    let first=editing.lensBlurDepthPreviewFrame?.id
    var effects=session.parameters.effects ?? .init();effects.lensBlur?.focusRange=0.4
    try session.apply(.setEffects(effects),event:.init(context:context,control:.init(group:nil,name:"焦内范围")))
    for _ in 0..<500 where editing.lensBlurDepthPreviewFrame?.id == first{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertTrue(editing.developmentLensBlurDepthPreviewActive);XCTAssertNil(session.parameters.effects?.lensBlur?.visualiseDepth)
    editing.cancelDevelopmentLensBlurDepthPreview()
    XCTAssertNil(editing.lensBlurDepthPreviewFrame);XCTAssertFalse(editing.developmentLensBlurDepthPreviewActive)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.effects?.lensBlur?.focusX,0.25)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.effects?.lensBlur?.focusRange,0.4)
    XCTAssertNil(work.liveRecipe?.adjustmentsV3?.effects?.lensBlur?.visualiseDepth)
  }
}
