import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosLensProfileDefaultsTests:XCTestCase {
  func testStoreIsPerProfilePersistentAndResettable()throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let store=DevelopmentLensProfileDefaultsStore(defaults:fixture.defaults)
    let wide=try XCTUnwrap(DevelopmentLensProfileCatalogV3.profile(id:"generic-wide"))
    let standard=try XCTUnwrap(DevelopmentLensProfileCatalogV3.profile(id:"generic-standard"))
    let custom=DevelopmentLensProfileDefaultsV1(enabled:false,distortion:0.8,vignetting:0.7)
    try store.save(custom,for:wide)
    XCTAssertEqual(store.value(for:wide),custom);XCTAssertEqual(store.value(for:standard),.standard)
    let reopened=DevelopmentLensProfileDefaultsStore(defaults:fixture.defaults)
    XCTAssertEqual(reopened.value(for:wide),custom)
    try reopened.reset(for:wide);XCTAssertEqual(reopened.value(for:wide),.standard)
    XCTAssertEqual(DevelopmentLensProfileDefaultsStore(defaults:fixture.defaults).value(for:wide),.standard)
    for invalid in [DevelopmentLensProfileDefaultsV1(enabled:true,distortion:-0.01,vignetting:1),
                    .init(enabled:true,distortion:1,vignetting:2.01),.init(enabled:true,distortion:.nan,vignetting:1)] {
      XCTAssertThrowsError(try reopened.save(invalid,for:wide))
    }
  }
  @MainActor func testSelectionUsesSavedDefaultsAndRecipeUndoRedo()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let profile=try XCTUnwrap(DevelopmentLensProfileCatalogV3.profile(id:"generic-wide"))
    let custom=DevelopmentLensProfileDefaultsV1(enabled:true,distortion:0.8,vignetting:0.7)
    try editing.developmentLensProfileDefaults.save(custom,for:profile)
    let selected=PhotosOpticsProfileSelection.applying(profile,to:session.parameters.optics ?? .init(),defaults:editing.developmentLensProfileDefaults)
    try selected.validate()
    try session.apply(.setParameters(.optics(selected)),event:.init(context:context,control:.init(group:.optics,name:"选择镜头配置")))
    XCTAssertEqual(session.parameters.optics?.lensProfile,profile);XCTAssertEqual(session.parameters.optics?.profileDistortionAmount,0.8);XCTAssertEqual(session.parameters.optics?.profileVignettingAmount,0.7)
    try session.undo(context:context);XCTAssertNil(session.parameters.optics)
    try session.redo(context:context);XCTAssertEqual(session.parameters.optics,selected)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.optics,selected)
    XCTAssertEqual(DevelopmentLensProfileDefaultsStore(defaults:fixture.defaults).value(for:profile),custom)
  }
}
