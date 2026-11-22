import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
import RAWMasterImaging

final class PhotosDeviceDepthWorkflowTests:XCTestCase {
  private struct SceneEstimator: ImageSceneDepthEstimating {
    let isAvailable = true
    let delay: Duration
    func estimate(_ source: EditingSourceSnapshot) async throws -> DevelopmentSceneDepthV1 {
      try await Task.sleep(for: delay)
      return try .init(sourceSHA256: source.contentSHA256,
                       map: .init(kind: .disparity, width: 2, height: 2, values: [0, 0.4, 0.7, 1]))
    }
  }

  @MainActor func testEnableSceneDepthCanCancelAndUndoInOneStep() async throws {
    let fixture = try EditingWorkflowTests.Fixture()
    defer { fixture.clean() }
    let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
    let asset = fixture.assets[0]
    app.selectScope(.project, id: asset.projectID)
    app.select(asset)
    app.setMode(.single)
    app.openNativeEditing()
    let editing = try XCTUnwrap(app.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil { editing.beginDevelopmentInterface() }
      try await Task.sleep(for: .milliseconds(10))
    }
    let context = try XCTUnwrap(editing.developmentContext)
    let session = editing.developmentSession
    editing.sceneDepthEngine = SceneEstimator(delay: .seconds(5))
    editing.useDevelopmentSceneDepth(context: context, enabling: true)
    XCTAssertEqual(editing.enablingSceneDepth, context)
    XCTAssertNil(session.parameters.effects)
    editing.cancelEnablingSceneDepth(context: context)
    XCTAssertNil(editing.enablingSceneDepth)
    editing.sceneDepthEngine = SceneEstimator(delay: .milliseconds(1))
    editing.useDevelopmentSceneDepth(context: context, enabling: true)
    for _ in 0..<500 where editing.developmentDeviceDepthInProgress { try await Task.sleep(for: .milliseconds(10)) }
    let committed = try XCTUnwrap(session.parameters.effects?.lensBlur)
    XCTAssertTrue(committed.enabled)
    XCTAssertEqual(committed.sceneDepth?.sourceSHA256, editing.work?.source.contentSHA256)
    XCTAssertEqual(committed.renderDepth?.width, 2)
    try session.undo(context: context)
    XCTAssertNil(session.parameters.effects)
    try session.redo(context: context)
    XCTAssertEqual(session.parameters.effects?.lensBlur, committed)
    await editing.shutdown()
    let store = try LibraryStore(databaseURL: fixture.library)
    XCTAssertEqual(try store.loadPhotoWorks(assetID: asset.id).first?.liveRecipe?.adjustmentsV3?.effects?.lensBlur, committed)
  }

  @MainActor func testUseAndRemoveDeviceDepthPersistWithUndoRedo()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let payload=try DevelopmentLensBlurDepthPayloadV1(kind:.depth,width:4,height:2,values:[0.1,0.3,0.7,0.9,0.2,0.4,0.8,1])
    editing.developmentDeviceDepthProvider={_ in payload}
    editing.useDevelopmentDeviceDepth(context:context)
    for _ in 0..<500 where session.parameters.effects?.lensBlur?.deviceDepth == nil{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertEqual(session.parameters.effects?.lensBlur?.deviceDepth,payload)
    try session.undo(context:context);XCTAssertNil(session.parameters.effects)
    try session.redo(context:context);XCTAssertEqual(session.parameters.effects?.lensBlur?.deviceDepth,payload)
    editing.clearDevelopmentDeviceDepth(context:context)
    XCTAssertNil(session.parameters.effects?.lensBlur?.deviceDepth)
    try session.undo(context:context);XCTAssertEqual(session.parameters.effects?.lensBlur?.deviceDepth,payload)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.effects?.lensBlur?.deviceDepth,payload)
  }
}
