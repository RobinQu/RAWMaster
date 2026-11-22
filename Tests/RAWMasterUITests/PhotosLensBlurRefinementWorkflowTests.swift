import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosLensBlurRefinementWorkflowTests:XCTestCase {
  @MainActor func testFocusBlurBrushesResetUndoRedoAndPersistence()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let brush=DevelopmentLensBlurRefinementBrushV3(amount:0.8,size:0.12,feather:0.4,flow:0.3,autoMask:true)
    let initial=DevelopmentEffectsV3(lensBlur:.init(enabled:true,refinementBrush:brush))
    try session.apply(.setEffects(initial),event:.init(context:context,control:.init(group:nil,name:"测试笔刷设置")))

    func begin(_ kind:EditingDevelopmentPicker.Kind)async throws->EditingDevelopmentPickerFrame {
      for _ in 0..<500 {
        editing.beginDevelopmentPicker(kind,context:context)
        if let picker=editing.developmentPicker,let frame=editing.developmentPickerFrame(for:picker){return frame}
        try await Task.sleep(nanoseconds:10_000_000)
      }
      return try XCTUnwrap(editing.developmentPickerFrame(for:XCTUnwrap(editing.developmentPicker)))
    }
    let focusFrame=try await begin(.lensBlurRefineFocus)
    editing.pickDevelopmentLensBlurRefinement([.init(position:.init(x:0.2,y:0.5)),.init(position:.init(x:0.3,y:0.5),pressure:0.6)],frame:focusFrame)
    var strokes=try XCTUnwrap(session.parameters.effects?.lensBlur?.refinementStrokes)
    XCTAssertEqual(strokes.count,1);XCTAssertEqual(strokes[0].mode,.focus)
    XCTAssertEqual(strokes[0].stroke.radiusInShortEdge,0.12,accuracy:1e-6)
    XCTAssertEqual(strokes[0].stroke.strength,0.8,accuracy:1e-6)
    XCTAssertEqual(strokes[0].feather,0.4,accuracy:1e-6);XCTAssertEqual(strokes[0].flow,0.3,accuracy:1e-6)
    XCTAssertEqual(strokes[0].autoMask,true)
    XCTAssertEqual(strokes[0].stroke.points[0].position,.init(x:0.2,y:0.5))
    try session.undo(context:context);XCTAssertEqual(session.parameters.effects?.lensBlur?.refinementStrokes,nil)
    try session.redo(context:context);XCTAssertEqual(session.parameters.effects?.lensBlur?.refinementStrokes,strokes)

    let blurFrame=try await begin(.lensBlurRefineBlur)
    editing.pickDevelopmentLensBlurRefinement([.init(position:.init(x:0.7,y:0.5))],frame:blurFrame)
    strokes=try XCTUnwrap(session.parameters.effects?.lensBlur?.refinementStrokes)
    XCTAssertEqual(strokes.count,2);XCTAssertEqual(strokes[1].mode,.blur)
    editing.resetDevelopmentLensBlurRefinements(context:context)
    XCTAssertEqual(session.parameters.effects?.lensBlur?.refinementStrokes,[])
    try session.undo(context:context);XCTAssertEqual(session.parameters.effects?.lensBlur?.refinementStrokes,strokes)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.effects?.lensBlur?.refinementStrokes,strokes)
  }
}
