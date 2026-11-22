import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosTargetedColorWorkflowTests:XCTestCase {
  @MainActor func testSampleAndDragShareOneGestureWithUndoRedoAndPersistence()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend(expandedCapabilities:true))
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let original=session.parameters.selectiveColor
    for _ in 0..<500 where editing.developmentPicker == nil {
      editing.beginDevelopmentPicker(.selectiveColorTargeted(.red,.saturation),context:context)
      if editing.developmentPicker == nil{try await Task.sleep(nanoseconds:10_000_000)}
    }
    let picker=try XCTUnwrap(editing.developmentPicker),frame=try XCTUnwrap(editing.developmentPickerFrame(for:picker))
    editing.pickDevelopmentSource(.init(x:0.2,y:0.5),frame:frame)
    for _ in 0..<500 where !editing.developmentTargetedColorReady{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertTrue(editing.developmentTargetedColorReady)
    let gesture=try XCTUnwrap(session.activeGesture)
    let sampled=try XCTUnwrap(session.parameters.selectiveColor.colors.first{$0.slot == .red}?.sampledColor)
    let initial=session.parameters.selectiveColor
    let expected=try DevelopmentTargetedColorAdjustmentV3.apply(initial:initial,sample:sampled,mode:.saturation,drag:0.5)
    editing.dragDevelopmentTargetedColor(0.25)
    let halfway=try DevelopmentTargetedColorAdjustmentV3.apply(initial:initial,sample:sampled,mode:.saturation,drag:0.25)
    XCTAssertEqual(session.parameters.selectiveColor,halfway);XCTAssertEqual(session.activeGesture,gesture)
    editing.dragDevelopmentTargetedColor(0.5)
    XCTAssertEqual(session.parameters.selectiveColor,expected);XCTAssertEqual(session.activeGesture,gesture)
    editing.dragDevelopmentTargetedColor(0.5,ended:true)
    XCTAssertNil(session.activeGesture);XCTAssertFalse(editing.developmentTargetedColorReady);XCTAssertNil(editing.developmentPicker)
    try session.undo(context:context);XCTAssertEqual(session.parameters.selectiveColor,original)
    try session.redo(context:context);XCTAssertEqual(session.parameters.selectiveColor,expected)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.selectiveColor,expected)
  }
}
