import XCTest
@testable import RAWMasterImaging

final class ImageEngineCompositionTests: XCTestCase {
  func testPreviewLifecycleAndDiagnosticsObserveTheEditingOwner() {
    let editing = ImageEngines.editing as AnyObject
    XCTAssertTrue(editing === (ImageEngines.previewLifecycle as AnyObject))
    XCTAssertTrue(editing === (ImageEngines.monitoring as AnyObject))
    XCTAssertTrue((ImageEngines.browsing as AnyObject) === ImagePipeline.shared)
  }

  func testControllersAndBatchesReceiveIndependentReleasableWorkers() {
    func assertIndependent<Worker>(_ make: () -> Worker, line: UInt = #line) {
      weak var released: AnyObject?
      do {
        let first = make() as AnyObject
        let second = make() as AnyObject
        XCTAssertFalse(first === second, line: line)
        released = first
      }
      XCTAssertNil(released, line: line)
    }

    assertIndependent(ImageEngines.makeDevelopmentRenderer)
    assertIndependent(ImageEngines.makeVersionExporter)
    assertIndependent(ImageEngines.makeBatchExporter)
  }
}
