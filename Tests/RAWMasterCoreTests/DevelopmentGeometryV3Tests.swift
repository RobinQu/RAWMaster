import XCTest
import Foundation
@testable import RAWMasterCore

final class DevelopmentGeometryV3Tests: XCTestCase {
  func testLegacyInwardCropMapsBothDirectionsAndRejectsClippedPoints() throws {
    let geometry = DevelopmentGeometryV3(version:.legacyV2,crop:.init(x:0.125,y:0.25,width:0.5,height:0.5))
    let map = try geometry.mapping(sourceSize:.init(width:160,height:96))
    XCTAssertEqual(map.outputSize,.init(width:80,height:48))
    XCTAssertEqual(try map.sourcePoint(fromOutput:.init(x:0,y:0)),.init(x:0.125,y:0.25))
    XCTAssertEqual(try map.sourcePoint(fromOutput:.init(x:1,y:1)),.init(x:0.625,y:0.75))
    XCTAssertNil(try map.outputPoint(fromSource:.init(x:0,y:0)))
    let middle = try XCTUnwrap(map.outputPoint(fromSource:.init(x:0.375,y:0.5))); XCTAssertEqual(middle,.init(x:0.5,y:0.5))
  }
  func testClockwiseQuarterTurnsAndFlipsHaveExplicitTopLeftSemantics() throws {
    let point = DevelopmentSourcePoint(x:0.2,y:0.3)
    let expected = [point,.init(x:0.7,y:0.2),.init(x:0.8,y:0.7),.init(x:0.3,y:0.8)]
    for turns in 0...3 {
      let map = try DevelopmentGeometryV3(clockwiseQuarterTurns:turns).mapping(sourceSize:.init(width:200,height:100))
      XCTAssertEqual(map.outputSize,turns%2 == 0 ? .init(width:200,height:100) : .init(width:100,height:200))
      let actual = try XCTUnwrap(map.outputPoint(fromSource:point)); XCTAssertEqual(actual.x,expected[turns].x,accuracy:1e-12); XCTAssertEqual(actual.y,expected[turns].y,accuracy:1e-12)
      let restored = try map.sourcePoint(fromOutput:actual); XCTAssertEqual(restored.x,point.x,accuracy:1e-12); XCTAssertEqual(restored.y,point.y,accuracy:1e-12)
    }
    let map = try DevelopmentGeometryV3(clockwiseQuarterTurns:1,flipHorizontal:true,flipVertical:true).mapping(sourceSize:.init(width:200,height:100))
    let actual = try XCTUnwrap(map.outputPoint(fromSource:point)); XCTAssertEqual(actual.x,0.3,accuracy:1e-12); XCTAssertEqual(actual.y,0.8,accuracy:1e-12)
  }
  func testLegacyStraightenTrimRoundTripsDisplayedPointsWithoutProjectingPerspective() throws {
    for version in [DevelopmentGeometryVersionV3.legacyV1,.legacyV2] {
      for degrees in [-45.0,-13,0,13,45] {
        let map = try DevelopmentGeometryV3(version:version,straightenDegrees:degrees,crop:.init(x:0.1,y:0.125,width:0.8,height:0.75)).mapping(sourceSize:.init(width:9504,height:6336))
        for point in [DevelopmentSourcePoint(x:0,y:0),.init(x:0.25,y:0.75),.init(x:0.5,y:0.5),.init(x:1,y:1)] {
          let source = try map.sourcePoint(fromOutput:point), output = try XCTUnwrap(map.outputPoint(fromSource:source))
          XCTAssertEqual(output.x,point.x,accuracy:1e-10); XCTAssertEqual(output.y,point.y,accuracy:1e-10)
        }
      }
    }
  }
  func testMeasuredPerspectiveIsRepresentableButMappingFailsExplicitly() throws {
    let perspective = DevelopmentGeometryV3(straightenDegrees:45,verticalPerspective:-30,horizontalPerspective:30)
    XCTAssertNoThrow(try perspective.validate())
    XCTAssertThrowsError(try perspective.mapping(sourceSize:.init(width:100,height:100))) { error in
      XCTAssertEqual(error as? DevelopmentGeometryMappingError,.unsupportedPerspectiveMapping)
    }
    XCTAssertThrowsError(try DevelopmentGeometryV3(verticalPerspective:30.01).validate())
    XCTAssertThrowsError(try DevelopmentGeometryV3(version:.legacyV1,flipHorizontal:true).validate())
    XCTAssertThrowsError(try DevelopmentGeometryV3(version:.legacyV2,horizontalPerspective:1).validate())
    XCTAssertThrowsError(try DevelopmentGeometryV3(crop:.init(width:0.000001,height:1)).mapping(sourceSize:.init(width:10,height:10)))
  }
  func testAllEXIFPointTransformsAreInvertibleAndDoNotDependOnViewport() throws {
    let point = DevelopmentSourcePoint(x:0.2,y:0.3)
    let expected: [DevelopmentSourcePoint] = [point,.init(x:0.8,y:0.3),.init(x:0.8,y:0.7),.init(x:0.2,y:0.7),.init(x:0.3,y:0.2),.init(x:0.7,y:0.2),.init(x:0.7,y:0.8),.init(x:0.3,y:0.8)]
    for orientation in 1...8 {
      let oriented = try point.applyingEXIFOrientation(orientation), raw = try oriented.removingEXIFOrientation(orientation)
      XCTAssertEqual(oriented.x,expected[orientation-1].x,accuracy:1e-12); XCTAssertEqual(oriented.y,expected[orientation-1].y,accuracy:1e-12)
      XCTAssertEqual(raw.x,point.x,accuracy:1e-12); XCTAssertEqual(raw.y,point.y,accuracy:1e-12)
    }
    XCTAssertThrowsError(try point.applyingEXIFOrientation(0)); XCTAssertThrowsError(try point.applyingEXIFOrientation(9))
  }
}
