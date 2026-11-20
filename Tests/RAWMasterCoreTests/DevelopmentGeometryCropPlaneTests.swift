import XCTest
@testable import RAWMasterCore

final class DevelopmentGeometryCropPlaneTests: XCTestCase {
  private let size = DevelopmentPixelSize(width:4033,height:3025)
  private func point(_ m: [Double],_ x: Double,_ y: Double) -> (Double,Double) {
    let p = DevelopmentRGBMatrixV3.apply(m,[x,y,1]); return (p[0]/p[2],p[1]/p[2])
  }
  func testAffinePlaneRetainsFractionalSizeAndCropIdentityTopOffset() throws {
    let g = DevelopmentGeometryV3(straightenDegrees:13.7)
    let map = try g.mapping(sourceSize:size), p = map.cropPlane
    XCTAssertEqual(p.rect.x,0); XCTAssertEqual(p.rect.y,0)
    XCTAssertNotEqual(p.rect.height,floor(p.rect.height))
    XCTAssertEqual(p.identityRasterRect.y,p.rect.height-floor(p.rect.height),accuracy:1e-12)
    XCTAssertEqual(p.identityRasterRect.width,Double(map.outputSize.width)); XCTAssertEqual(p.identityRasterRect.height,Double(map.outputSize.height))
    XCTAssertEqual(p.identityRasterRect,p.actualRasterRect)
    XCTAssertEqual(p.identityRasterSize,map.outputSize)
  }
  func testChangingUserCropDoesNotChangeContinuousPlaneOrItsMatrices() throws {
    var g = DevelopmentGeometryV3(straightenDegrees:-17,clockwiseQuarterTurns:1,flipHorizontal:true)
    let original = try g.mapping(sourceSize:size).cropPlane
    g.crop = .init(x:0.13,y:0.17,width:0.71,height:0.66)
    let cropped = try g.mapping(sourceSize:size).cropPlane
    XCTAssertEqual(original.rect,cropped.rect)
    XCTAssertEqual(original.forwardMatrix.map(\.bitPattern),cropped.forwardMatrix.map(\.bitPattern))
    XCTAssertEqual(original.inverseMatrix.map(\.bitPattern),cropped.inverseMatrix.map(\.bitPattern))
    XCTAssertEqual(original.identityRasterRect,cropped.identityRasterRect)
    XCTAssertNotEqual(original.actualRasterRect,cropped.actualRasterRect)
  }
  func testActualAndIdentityRasterOffsetsMapToSameContinuousPlane() throws {
    let g = DevelopmentGeometryV3(straightenDegrees:9.4,crop:.init(x:0.1,y:0.2,width:0.7,height:0.6))
    let m = try g.mapping(sourceSize:size), p = m.cropPlane
    for (u,v) in [(0.0,0.0),(0.5,0.5),(1.0,1.0)] {
      let s = try m.sourcePoint(fromOutput:.init(x:u,y:v))
      let plane = point(p.forwardMatrix,s.x*Double(size.width),s.y*Double(size.height))
      XCTAssertEqual(plane.0,p.actualRasterRect.x+u*p.actualRasterRect.width,accuracy:1e-9)
      XCTAssertEqual(plane.1,p.actualRasterRect.y+v*p.actualRasterRect.height,accuracy:1e-9)
      let inverse = point(p.inverseMatrix,plane.0,plane.1)
      XCTAssertEqual(inverse.0,s.x*Double(size.width),accuracy:1e-9); XCTAssertEqual(inverse.1,s.y*Double(size.height),accuracy:1e-9)
    }
  }
  func testProjectivePlanePreservesTrimAndCropIdentityRounding() throws {
    var g = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:8,verticalPerspective:21,horizontalPerspective:-14,clockwiseQuarterTurns:3,flipVertical:true)
    let identity = try g.mapping(sourceSize:size), p = identity.cropPlane
    let descriptor = try XCTUnwrap(identity.projective)
    XCTAssertEqual(p.rect.width,descriptor.perspectiveTrim.width); XCTAssertEqual(p.rect.height,descriptor.perspectiveTrim.height)
    XCTAssertEqual(p.identityRasterRect.y,p.rect.height-floor(p.rect.height),accuracy:1e-12)
    g.crop = .init(x:0.08,y:0.1,width:0.8,height:0.7)
    let actual = try g.mapping(sourceSize:size)
    XCTAssertEqual(actual.cropPlane.rect,p.rect); XCTAssertEqual(actual.cropPlane.forwardMatrix,p.forwardMatrix)
    XCTAssertEqual(actual.cropPlane.actualRasterRect,try XCTUnwrap(actual.projective).finalCrop)
    let s = try actual.sourcePoint(fromOutput:.init(x:0.5,y:0.5))
    let plane = point(p.forwardMatrix,s.x*Double(size.width),s.y*Double(size.height))
    XCTAssertEqual(plane.0,actual.cropPlane.actualRasterRect.x+Double(actual.outputSize.width)/2,accuracy:1e-8)
    XCTAssertEqual(plane.1,actual.cropPlane.actualRasterRect.y+Double(actual.outputSize.height)/2,accuracy:1e-8)
  }
  func testPublicInverseMatrixMatchesNormalizedMappingForAffineAndProjective() throws {
    for g in [DevelopmentGeometryV3(straightenDegrees:11,clockwiseQuarterTurns:2,flipHorizontal:true),
      .init(version:.projectiveV3_1,verticalPerspective:-20,horizontalPerspective:10)] {
      let m = try g.mapping(sourceSize:size), inverse = try m.inverseMatrix
      for (x,y) in [(0.0,0.0),(0.37,0.63),(1.0,1.0)] {
        let p = point(inverse,x*Double(m.outputSize.width),y*Double(m.outputSize.height))
        let expected = try m.sourcePoint(fromOutput:.init(x:x,y:y))
        XCTAssertEqual(p.0/Double(size.width),expected.x,accuracy:1e-12); XCTAssertEqual(p.1/Double(size.height),expected.y,accuracy:1e-12)
      }
    }
  }
}
