import XCTest
@testable import RAWMasterImaging

final class ImageEnginePrewarmingTests: XCTestCase {
  func testSynchronousPrewarmIsRepeatableAndDoesNotMutateOperatorSource() {
    let before=DevelopmentColorEngineV3.sourceSHA256
    ImageEnginePrewarming.run();ImageEnginePrewarming.run()
    XCTAssertEqual(DevelopmentColorEngineV3.sourceSHA256,before)
  }
}
