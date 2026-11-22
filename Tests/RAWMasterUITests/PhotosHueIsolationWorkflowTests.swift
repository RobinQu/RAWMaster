import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosHueIsolationWorkflowTests:XCTestCase {
  @MainActor func testIsolationRefreshesDuringGestureWithoutEnteringDraft()async throws {
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
    editing.previewDevelopmentHueIsolation(.red,context:context)
    for _ in 0..<500 where editing.filterHoverFrame == nil{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertNotNil(editing.filterHoverFrame);XCTAssertEqual(editing.isolatedDevelopmentSlot,.red)
    XCTAssertEqual(editing.recipe,original);XCTAssertNil(editing.recipe.adjustmentsV3?.selectiveColor.visualiseIsolation)
    let gesture=try session.beginGesture(.init(group:.selectiveColor,name:"饱和度"),context:context)
    var adjusted=session.parameters.selectiveColor;adjusted.enabled=true;adjusted.colors[0].saturation=20
    try session.apply(.setParameters(.selectiveColor(adjusted)),event:.init(context:context,control:.init(group:.selectiveColor,name:"饱和度")),gesture:gesture)
    for _ in 0..<500 where editing.filterHoverFrame == nil{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertNotNil(editing.filterHoverFrame);XCTAssertEqual(editing.isolatedDevelopmentSlot,.red);XCTAssertEqual(session.activeGesture,gesture)
    XCTAssertNil(editing.recipe.adjustmentsV3?.selectiveColor.visualiseIsolation)
    try session.endGesture(gesture,.commit);editing.cancelDevelopmentFilterHover()
    XCTAssertNil(editing.filterHoverFrame);XCTAssertNil(editing.isolatedDevelopmentSlot)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.selectiveColor,adjusted)
    XCTAssertNil(work.liveRecipe?.adjustmentsV3?.selectiveColor.visualiseIsolation)
  }
}
