import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosClippingPreviewWorkflowTests:XCTestCase {
  @MainActor func testClippingTogglesRefreshDuringLightGestureAndNeverEnterDraft()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend(expandedCapabilities:true))
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let original=editing.recipe
    for mode in [DevelopmentClippingPreviewV3.shadows,.highlights] {
      editing.previewDevelopmentClipping(mode,context:context)
      for _ in 0..<500 where editing.filterHoverFrame == nil{try await Task.sleep(nanoseconds:10_000_000)}
      XCTAssertNotNil(editing.filterHoverFrame)
    }
    XCTAssertEqual(editing.developmentClippingPreview,.both)
    XCTAssertEqual(editing.recipe,original);XCTAssertNil(editing.recipe.adjustmentsV3?.light.clippingPreview)
    editing.previewDevelopmentClipping(.highlights,context:context)
    XCTAssertEqual(editing.developmentClippingPreview,.shadows)
    let gesture=try session.beginGesture(.init(group:.light,name:"曝光"),context:context)
    var adjusted=session.parameters.light;adjusted.enabled=true;adjusted.exposure=0.2
    try session.apply(.setParameters(.light(adjusted)),event:.init(context:context,control:.init(group:.light,name:"曝光")),gesture:gesture)
    for _ in 0..<500 where editing.filterHoverFrame == nil{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertNotNil(editing.filterHoverFrame);XCTAssertEqual(editing.developmentClippingPreview,.shadows);XCTAssertEqual(session.activeGesture,gesture)
    XCTAssertNil(editing.recipe.adjustmentsV3?.light.clippingPreview)
    try session.endGesture(gesture,.commit);editing.setDevelopmentClippingPreview(nil,context:context)
    XCTAssertNil(editing.filterHoverFrame);XCTAssertNil(editing.developmentClippingPreview)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.light,adjusted)
    XCTAssertNil(work.liveRecipe?.adjustmentsV3?.light.clippingPreview)
  }
}
