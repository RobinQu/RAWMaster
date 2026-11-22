import XCTest
import AppKit
@testable import RAWMaster
@testable import RAWMasterCore
import RAWMasterImaging

final class PhotosCurveTargetedWorkflowTests:XCTestCase {
  @MainActor func testParametricDragUsesPresentedPixelsAndExportsPersistedCurve() async throws {
    let fixture = try EditingWorkflowTests.Fixture()
    defer { fixture.clean() }
    let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
    model.selectScope(.project, id: fixture.assets[0].projectID)
    model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
    let editing = try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil { editing.beginDevelopmentInterface() }
      try await Task.sleep(for: .milliseconds(10))
    }
    let context = try XCTUnwrap(editing.developmentContext), session = editing.developmentSession
    let original = editing.recipe
    func pick() async throws {
      for _ in 0..<1000 where editing.developmentPicker == nil {
        editing.beginDevelopmentPicker(.parametricCurveTargeted, context: context)
        if editing.developmentPicker == nil { try await Task.sleep(for: .milliseconds(10)) }
      }
      let picker = try XCTUnwrap(editing.developmentPicker)
      let frame = try XCTUnwrap(editing.developmentPickerFrame(for: picker))
      editing.pickDevelopmentSource(.init(x: 0.5, y: 0.5), frame: frame)
      XCTAssertTrue(editing.developmentTargetedCurveReady)
    }
    try await pick()
    editing.dragDevelopmentTargetedCurve(.zero, ended: true)
    XCTAssertEqual(editing.recipe, original)
    try await pick()
    editing.dragDevelopmentTargetedCurve(.init(0, 0.1))
    editing.cancelDevelopmentPicker(context: context)
    XCTAssertEqual(editing.recipe, original)
    try await pick()
    editing.dragDevelopmentTargetedCurve(.init(0, 0.1))
    editing.dragDevelopmentTargetedCurve(.init(0.2, 0), ended: true)
    let adjusted = editing.recipe
    let amounts = try XCTUnwrap(adjusted.adjustmentsV3?.curves.parametric)
    XCTAssertEqual([amounts.shadows, amounts.darks, amounts.lights, amounts.highlights].sorted(), [0, 0, 0, 40])
    XCTAssertNil(session.activeGesture)
    try session.undo(context: context); XCTAssertEqual(editing.recipe, original)
    try session.redo(context: context); XCTAssertEqual(editing.recipe, adjusted)
    await editing.shutdown()
    let work = try XCTUnwrap(try fixture.store.loadPhotoWorks(assetID: fixture.assets[0].id).first)
    let saved = try XCTUnwrap(work.liveRecipe)
    XCTAssertEqual(saved, adjusted)
    let export = fixture.root.appendingPathComponent("adjusted.png")
    let baseline = fixture.root.appendingPathComponent("original.png")
    let renderer = DevelopmentService()
    _ = try await renderer.render(source: work.source, recipe: saved, format: .png16, destination: export)
    _ = try await renderer.render(source: work.source, recipe: original, format: .png16, destination: baseline)
    let sample = try XCTUnwrap(DevelopmentDisplayPixel.sample(try XCTUnwrap(NSImage(contentsOf: export)), at: .init(x: 0.5, y: 0.5)))
    let originalSample = try XCTUnwrap(DevelopmentDisplayPixel.sample(try XCTUnwrap(NSImage(contentsOf: baseline)), at: .init(x: 0.5, y: 0.5)))
    XCTAssertGreaterThan(sample.tone, originalSample.tone + 0.01)
  }

  @MainActor func testSampledPointDragSharesOneGestureWithUndoRedoAndPersistence()async throws {
    let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
    let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend(expandedCapabilities:true))
    model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
    let editing=try XCTUnwrap(model.editing)
    for _ in 0..<500 where editing.developmentContext == nil {
      if editing.work != nil{editing.beginDevelopmentInterface()}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let context=try XCTUnwrap(editing.developmentContext),session=editing.developmentSession
    let original=session.parameters.curves
    for _ in 0..<500 where editing.developmentPicker == nil {
      editing.beginDevelopmentPicker(.curveTargeted(.rgb),context:context)
      if editing.developmentPicker == nil{try await Task.sleep(nanoseconds:10_000_000)}
    }
    let picker=try XCTUnwrap(editing.developmentPicker),frame=try XCTUnwrap(editing.developmentPickerFrame(for:picker))
    editing.pickDevelopmentSource(.init(x:0.5,y:0.5),frame:frame)
    for _ in 0..<500 where !editing.developmentTargetedCurveReady{try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertTrue(editing.developmentTargetedCurveReady)
    let gesture=try XCTUnwrap(session.activeGesture),initial=session.parameters.curves
    let index=try XCTUnwrap(initial.rgb.curve.points.firstIndex{abs($0.x-0.5)<1e-6})
    let expected=try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial:initial,channel:.rgb,pointIndex:index,translation:.init(x:0.1,y:0.2))
    editing.dragDevelopmentTargetedCurve(.init(x:0.05,y:0.1))
    let halfway=try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial:initial,channel:.rgb,pointIndex:index,translation:.init(x:0.05,y:0.1))
    XCTAssertEqual(session.parameters.curves,halfway);XCTAssertEqual(session.activeGesture,gesture)
    editing.dragDevelopmentTargetedCurve(.init(x:0.1,y:0.2))
    XCTAssertEqual(session.parameters.curves,expected);XCTAssertEqual(session.activeGesture,gesture)
    editing.dragDevelopmentTargetedCurve(.init(x:0.1,y:0.2),ended:true)
    XCTAssertNil(session.activeGesture);XCTAssertFalse(editing.developmentTargetedCurveReady);XCTAssertNil(editing.developmentPicker)
    try session.undo(context:context);XCTAssertEqual(session.parameters.curves,original)
    try session.redo(context:context);XCTAssertEqual(session.parameters.curves,expected)
    await editing.shutdown()
    let store=try LibraryStore(databaseURL:fixture.library)
    let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
    XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.curves,expected)
  }
}
