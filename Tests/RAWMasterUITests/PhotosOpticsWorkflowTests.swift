import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosOpticsWorkflowTests:XCTestCase{
  @MainActor func testRemoveCAAndDistortionPersistAndUndo()async throws{
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil{
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext)
    var optics=DevelopmentOpticsV3(removeChromaticAberration:true,distortion:0.2)
    optics.lensProfile=try XCTUnwrap(DevelopmentLensProfileCatalogV3.profile(id:"generic-wide"));optics.lensProfileEnabled=true
    optics.profileDistortionAmount=0.8;optics.profileVignettingAmount=0.7
    optics.lensVignettingAmount=0.4;optics.lensVignettingMidpoint=0.6
    try editing.developmentSession.apply(.setParameters(.optics(optics)),event:.init(context:context,control:.init(group:.optics,name:"移除色差与畸变")))
    XCTAssertEqual(editing.recipe.adjustmentsV3?.optics,optics)
    editing.undoDevelopment(context:context);XCTAssertNil(editing.recipe.adjustmentsV3?.optics)
    editing.undoDevelopment(context:context,redo:true);XCTAssertEqual(editing.recipe.adjustmentsV3?.optics,optics)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.optics,optics)
  }
}
