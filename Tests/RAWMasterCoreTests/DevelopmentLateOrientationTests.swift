import XCTest
@testable import RAWMasterCore

final class DevelopmentLateOrientationTests: XCTestCase {
  private let size = DevelopmentPixelSize(width:4033,height:3025)
  private func bytes<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
  private struct OldGeometry: Encodable {
    let version: DevelopmentGeometryVersionV3
    let straightenDegrees,verticalPerspective,horizontalPerspective: Double
    let crop: NormalizedCrop
    let clockwiseQuarterTurns: Int
    let flipHorizontal,flipVertical: Bool
    init(_ g: DevelopmentGeometryV3) {
      version = g.version; straightenDegrees = g.straightenDegrees; verticalPerspective = g.verticalPerspective; horizontalPerspective = g.horizontalPerspective
      crop = g.crop; clockwiseQuarterTurns = g.clockwiseQuarterTurns; flipHorizontal = g.flipHorizontal; flipVertical = g.flipVertical
    }
  }
  func testClosedEightCompositionHasR4H2V2AndReflectionParity() {
    XCTAssertEqual(DevelopmentD4OrientationV3.allCases.count,8)
    for e in DevelopmentD4OrientationV3.allCases {
      var r = e; for _ in 0..<4 { r = DevelopmentD4OrientationV3.rotate90.composeAfter(r) }; XCTAssertEqual(r,e)
      XCTAssertEqual(DevelopmentD4OrientationV3.flipHorizontal.composeAfter(.flipHorizontal.composeAfter(e)),e)
      XCTAssertEqual(DevelopmentD4OrientationV3.flipVertical.composeAfter(.flipVertical.composeAfter(e)),e)
      XCTAssertEqual(e.isReflection,[.flipHorizontal,.flipVertical,.transpose,.transverse].contains(e))
    }
    XCTAssertNotEqual(DevelopmentD4OrientationV3.rotate90.composeAfter(.flipHorizontal),.flipHorizontal.composeAfter(.rotate90))
  }
  func testIdentityOmitsNewKeyPreservingOldBytesFingerprintAndMappingBits() throws {
    for version in [DevelopmentGeometryVersionV3.legacyV1,.legacyV2,.adjustV3,.projectiveV3_1] {
      let old = OldGeometry(.init(version:version,straightenDegrees:11.25,crop:.init(x:0.1,y:0.2,width:0.7,height:0.6)))
      let oldBytes = try bytes(old), g = try JSONDecoder().decode(DevelopmentGeometryV3.self,from:oldBytes)
      XCTAssertEqual(try bytes(g),oldBytes); XCTAssertEqual(try EditingFingerprint.of(g),try EditingFingerprint.of(old))
      var explicit = g; explicit.lateOrientation = .init(version:1,orientation:.identity)
      XCTAssertEqual(try bytes(explicit),oldBytes)
      let a = try g.mapping(sourceSize:size), b = try explicit.mapping(sourceSize:size)
      XCTAssertEqual(a.forwardMatrix.map(\.bitPattern),b.forwardMatrix.map(\.bitPattern))
      XCTAssertEqual(try a.inverseMatrix.map(\.bitPattern),try b.inverseMatrix.map(\.bitPattern))
      XCTAssertEqual(a.cropPlane,b.cropPlane)
    }
  }
  func testStrictVersionEnumNullAndLegacyRejection() throws {
    var g = DevelopmentGeometryV3(version:.projectiveV3_1,lateOrientation:.init(orientation:.rotate90))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentGeometryV3.self,from:bytes(g)),g)
    for version in [DevelopmentGeometryVersionV3.legacyV1,.legacyV2,.adjustV3] { g.version = version; XCTAssertThrowsError(try g.validate()) }
    g.version = .projectiveV3_1
    let valid = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes(g)) as? [String:Any])
    for version in [DevelopmentGeometryVersionV3.legacyV1,.legacyV2,.adjustV3] {
      var j = valid; j["version"] = version.rawValue
      XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentGeometryV3.self,from:JSONSerialization.data(withJSONObject:j)))
    }
    let badValues: [Any] = [NSNull(),["version":2,"orientation":"rotate90"] as [String:Any],
      ["version":1,"orientation":"unknown"] as [String:Any],["version":1,"orientation":"identity","extra":0] as [String:Any]]
    for bad in badValues {
      var j = valid; j["lateOrientation"] = bad
      XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentGeometryV3.self,from:JSONSerialization.data(withJSONObject:j)))
    }
  }
  private func logicalCorners(_ g: DevelopmentGeometryV3) throws -> [(Double,Double)] {
    let p = try g.mapping(sourceSize:size).cropPlane, c = g.crop
    return try [(c.x,c.y),(c.x+c.width,c.y),(c.x+c.width,c.y+c.height),(c.x,c.y+c.height)].map {
      try DevelopmentProjectiveDescriptorV3.point(p.inverseMatrix,$0.0*p.rect.width,$0.1*p.rect.height)
    }
  }
  func testLateViewOperationsPreserveLogicalSourceSelectionAndAllPreParameters() throws {
    for oldFlip in [false,true] { for perspective in [0.0,17] {
      let g = DevelopmentGeometryV3(version:perspective == 0 ? .adjustV3:.projectiveV3_1,straightenDegrees:13,
        verticalPerspective:perspective,horizontalPerspective:-perspective/2,crop:.init(x:0.12,y:0.18,width:0.61,height:0.67),clockwiseQuarterTurns:1,flipHorizontal:oldFlip,flipVertical:!oldFlip)
      let before = try logicalCorners(g)
      for (op,indices) in [(DevelopmentLateOperationV3.rotateClockwise,[3,0,1,2]),(.flipHorizontal,[1,0,3,2]),(.flipVertical,[3,2,1,0])] {
        let next = try g.applyingLateOperation(op), after = try logicalCorners(next)
        XCTAssertEqual(next.version,.projectiveV3_1); XCTAssertEqual(next.clockwiseQuarterTurns,g.clockwiseQuarterTurns)
        XCTAssertEqual(next.flipHorizontal,g.flipHorizontal); XCTAssertEqual(next.flipVertical,g.flipVertical)
        XCTAssertEqual(next.straightenDegrees.bitPattern,g.straightenDegrees.bitPattern)
        XCTAssertEqual(next.verticalPerspective.bitPattern,g.verticalPerspective.bitPattern); XCTAssertEqual(next.horizontalPerspective.bitPattern,g.horizontalPerspective.bitPattern)
        for i in 0..<4 { XCTAssertEqual(after[i].0,before[indices[i]].0,accuracy:1e-8); XCTAssertEqual(after[i].1,before[indices[i]].1,accuracy:1e-8) }
      }
    } }
  }
  func testContinuousPlaneRotatesBeforeFreshInwardRoundingAndInverseRoundTrips() throws {
    let g = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:13.7,verticalPerspective:19,horizontalPerspective:-11,
      crop:.init(x:0.11,y:0.14,width:0.68,height:0.71),flipHorizontal:true)
    let a = try g.mapping(sourceSize:size), next = try g.applyingLateOperation(.rotateClockwise), b = try next.mapping(sourceSize:size)
    XCTAssertEqual(b.cropPlane.rect.width,a.cropPlane.rect.height); XCTAssertEqual(b.cropPlane.rect.height,a.cropPlane.rect.width)
    XCTAssertEqual(b.cropPlane.identityRasterRect.y,b.cropPlane.rect.height-floor(b.cropPlane.rect.height),accuracy:1e-12)
    XCTAssertEqual(b.cropPlane.actualRasterRect,try XCTUnwrap(b.projective).finalCrop)
    for point in [DevelopmentSourcePoint(x:0,y:0),.init(x:0.3,y:0.7),.init(x:1,y:1)] {
      let source = try b.sourcePoint(fromOutput:point), output = try XCTUnwrap(b.outputPoint(fromSource:source))
      XCTAssertEqual(output.x,point.x,accuracy:1e-12); XCTAssertEqual(output.y,point.y,accuracy:1e-12)
    }
    XCTAssertNil(try b.outputPoint(fromSource:.init(x:0,y:0)))
    XCTAssertThrowsError(try b.sourcePoint(fromOutput:.init(x:-0.01,y:0.5)))
  }
  func testZeroPerspectiveIdentityStillDelegatesAffineBitsAndLogicalOperationCycles() throws {
    var g = DevelopmentGeometryV3(straightenDegrees:-9.25,crop:.init(x:0.1,y:0.2,width:0.7,height:0.6),clockwiseQuarterTurns:3,flipVertical:true)
    let old = try g.mapping(sourceSize:size); g.version = .projectiveV3_1
    let upgraded = try g.mapping(sourceSize:size)
    XCTAssertNil(upgraded.projective); XCTAssertEqual(old.forwardMatrix.map(\.bitPattern),upgraded.forwardMatrix.map(\.bitPattern))
    var cycled = g; for _ in 0..<4 { cycled = try cycled.applyingLateOperation(.rotateClockwise) }
    XCTAssertEqual(cycled.lateOrientation.orientation,.identity)
    XCTAssertEqual(cycled.crop.x,g.crop.x,accuracy:1e-15); XCTAssertEqual(cycled.crop.y,g.crop.y,accuracy:1e-15)
    XCTAssertEqual(cycled.crop.width,g.crop.width); XCTAssertEqual(cycled.crop.height,g.crop.height)
    for operation in [DevelopmentLateOperationV3.flipHorizontal,.flipVertical] {
      let restored = try g.applyingLateOperation(operation).applyingLateOperation(operation)
      XCTAssertEqual(restored.lateOrientation.orientation,.identity)
      XCTAssertEqual(restored.crop.x,g.crop.x,accuracy:1e-15); XCTAssertEqual(restored.crop.y,g.crop.y,accuracy:1e-15)
      XCTAssertEqual(restored.crop.width,g.crop.width); XCTAssertEqual(restored.crop.height,g.crop.height)
    }
  }
}
