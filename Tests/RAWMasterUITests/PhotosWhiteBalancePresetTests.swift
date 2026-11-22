import XCTest
import RAWMasterCore
import RAWMasterImaging
import AppKit
@testable import RAWMaster

final class PhotosWhiteBalancePresetTests: XCTestCase {
  @MainActor func testAutomaticTemperatureTintCanBeUndoneReopenedAndExported() async throws {
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
    let context = try XCTUnwrap(editing.developmentContext), before = editing.recipe
    editing.requestDevelopmentWhiteBalanceAutomatic(.temperatureTint, context: context)
    for _ in 0..<800 where editing.recipe == before { try await Task.sleep(for: .milliseconds(10)) }
    let after = editing.recipe
    guard case .image(_, let state) = after.adjustmentsV3?.whiteBalance.resolvedState else {
      await editing.shutdown(); return XCTFail("Automatic white balance did not return a resolved temperature and tint")
    }
    XCTAssertEqual(state.selectedMode, .temperatureTint)
    XCTAssertEqual(DevelopmentImageWhiteBalanceStateV3.approximateTemperature(forOffset: state.temperatureOffset), state.temperatureTint.temperature)
    try editing.developmentSession.undo(context: context); XCTAssertEqual(editing.recipe, before)
    try editing.developmentSession.redo(context: context); XCTAssertEqual(editing.recipe, after)
    await editing.shutdown()
    let work = try XCTUnwrap(try fixture.store.loadPhotoWorks(assetID: fixture.assets[0].id).first)
    let saved = try XCTUnwrap(work.liveRecipe)
    XCTAssertEqual(saved, after)
    let renderer = DevelopmentService()
    func sample(_ name: String, recipe: DevelopmentRecipe) async throws -> DevelopmentDisplayPixel {
      let url = fixture.root.appendingPathComponent(name + ".png")
      _ = try await renderer.render(source: work.source, recipe: recipe, format: .png16, destination: url)
      return try XCTUnwrap(DevelopmentDisplayPixel.sample(try XCTUnwrap(NSImage(contentsOf: url)), at: .init(x: 0.5, y: 0.5)))
    }
    let a = try await sample("auto", recipe: saved), b = try await sample("original", recipe: before)
    XCTAssertNotEqual(a.rgb, b.rgb)
  }
  private let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:640,orientedHeight:480)
  private var raw:DevelopmentResolvedWhiteBalanceV3 {
    let tt=DevelopmentNativeWhiteBalanceV3(temperature:5200,tint:5)
    return .raw(source:source,state:.init(defaultTTDiagnostic:tt,temperatureTint:tt))
  }
  func testAllSixPresetsWriteValidatedRawTempTintCommands()throws {
    let expected:[PhotosWhiteBalancePreset:(Float,Float)] = [
      .daylight:(5500,10),.cloudy:(6500,10),.shade:(7500,10),
      .tungsten:(2850,0),.fluorescent:(4000,20),.flash:(6000,0)
    ]
    XCTAssertEqual(Set(PhotosWhiteBalancePreset.allCases),Set(expected.keys))
    for preset in PhotosWhiteBalancePreset.allCases {
      let command=try PhotosWhiteBalanceStateEditing.command(state:raw,preset:preset)
      guard case .setParameters(.whiteBalance(let value))=command,
        case .raw(let actualSource,let state)=value.resolvedState else{return XCTFail("Unexpected command")}
      XCTAssertTrue(value.enabled);XCTAssertEqual(actualSource,source)
      XCTAssertEqual(state.selectedMode,.temperatureTint)
      XCTAssertEqual(state.temperatureTint.temperature,expected[preset]!.0)
      XCTAssertEqual(state.temperatureTint.tint,expected[preset]!.1)
      try value.validate()
    }
  }
  func testNonRAWDoesNotAdmitCameraPresets()throws {
    let image=DevelopmentResolvedWhiteBalanceV3.image(source:source,state:.init())
    XCTAssertThrowsError(try PhotosWhiteBalanceStateEditing.command(state:image,preset:.daylight))
  }
}
