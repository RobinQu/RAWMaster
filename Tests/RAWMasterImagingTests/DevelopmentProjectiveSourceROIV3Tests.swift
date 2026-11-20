import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentProjectiveSourceROIV3Tests: XCTestCase {
  private func roi(_ geometry: DevelopmentGeometryV3, width: Int = 96, height: Int = 72) throws -> DevelopmentProjectiveSourceROIV3 {
    let mapping = try geometry.mapping(sourceSize:.init(width:width,height:height))
    return try .init(mapping:mapping,sourceExtent:.init(x:0,y:0,width:width,height:height),
      outputExtent:.init(x:0,y:0,width:mapping.outputSize.width,height:mapping.outputSize.height))
  }
  // Evaluate actual Float operations, both separately rounded and with fused multiply-add.
  // This is independent of the Double rational corner path used by the ROI helper.
  private func sample(_ r: DevelopmentProjectiveSourceROIV3, x: Double, y: Double, fused: Bool) -> CGPoint {
    let m = r.uploadedInverse.map(Float.init), fx = Float(x), fy = Float(r.uploadedOutputHeight)-Float(y)
    func dot(_ i: Int) -> Float {
      if fused { return m[i+2].addingProduct(m[i],fx).addingProduct(m[i+1],fy) }
      return (m[i]*fx+m[i+1]*fy)+m[i+2]
    }
    let z = dot(6)
    return .init(x:Double(dot(0)/z),y:Double(Float(r.uploadedSourceHeight)-dot(3)/z))
  }
  private func assertFootprint(_ r: DevelopmentProjectiveSourceROIV3, tile: CGRect, file: StaticString = #filePath, line: UInt = #line) {
    let bounded = tile.intersection(r.outputExtent), source = r.sourceRect(for:tile)
    for iy in 0...8 { for ix in 0...8 { for fused in [false,true] {
      let p = sample(r,x:bounded.minX+bounded.width*Double(ix)/8,
        y:bounded.minY+bounded.height*Double(iy)/8,fused:fused)
      // Shader returns transparent for genuine source no-hits. Inside/near the original edge,
      // include every clamped bilinear pixel *center*, including the last source pixel.
      guard p.x >= -0.001, p.y >= -0.001, p.x <= r.sourceExtent.width+0.001,
        p.y <= r.sourceExtent.height+0.001 else { continue }
      for dx in [0.0,1.0] { for dy in [0.0,1.0] {
        let x = min(r.sourceExtent.width-1,max(0,floor(p.x-0.5)+dx))+0.5
        let y = min(r.sourceExtent.height-1,max(0,floor(p.y-0.5)+dy))+0.5
        XCTAssertTrue(source.contains(.init(x:x,y:y)),"missing \(x),\(y) in \(source)",file:file,line:line)
      } }
    } } }
  }
  func testFloatFootprintsAcrossPerspectiveLateD4AndNoncentralCrop() throws {
    for v in [-30.0,5,30] { for h in [-30.0,0,30] { for late in DevelopmentD4OrientationV3.allCases {
      let g = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:7,verticalPerspective:v,horizontalPerspective:h,
        crop:.init(x:0.07,y:0.13,width:0.81,height:0.72),clockwiseQuarterTurns:1,flipHorizontal:true,
        lateOrientation:.init(orientation:late))
      let r = try roi(g), e = r.outputExtent
      for y in [0.0,e.height*0.43,max(0,e.height-3)] { for x in [0.0,e.width*0.37,max(0,e.width-3)] {
        assertFootprint(r,tile:CGRect(x:x,y:y,width:3.125,height:2.75).intersection(e))
      } }
    } } }
  }
  func testEmptyOutsideAndInfiniteRequestsAndFiniteSourceEdges() throws {
    let r = try DevelopmentProjectiveSourceROIV3(inverseMatrix:[1,0,0,0,1,0,0,0,1],
      sourceExtent:.init(x:0,y:0,width:96,height:72),outputExtent:.init(x:0,y:0,width:96,height:72))
    XCTAssertTrue(r.sourceRect(for:.null).isNull)
    XCTAssertTrue(r.sourceRect(for:.zero).isNull)
    XCTAssertTrue(r.sourceRect(for:.init(x:200,y:200,width:3,height:4)).isNull)
    XCTAssertEqual(r.sourceRect(for:.infinite),r.sourceExtent)
    for tile in [CGRect(x:0,y:0,width:1,height:1),CGRect(x:95,y:71,width:1,height:1)] {
      assertFootprint(r,tile:tile)
      XCTAssertTrue(r.sourceExtent.contains(r.sourceRect(for:tile)))
    }
  }
  func testUnsafeUploadedDenominatorAndNonfiniteGraphsRejectAtConstruction() throws {
    let e = CGRect(x:0,y:0,width:96,height:72)
    for m in [[1.0,0,0,0,1,0,0,0,0.0000999999999],
              [1,0,0,0,1,0,-0.02,0,1], [1,0,0,0,1,0,0,0,Double.nan],
              [Double.greatestFiniteMagnitude,0,0,0,1,0,0,0,1]] {
      XCTAssertThrowsError(try DevelopmentProjectiveSourceROIV3(inverseMatrix:m,sourceExtent:e,outputExtent:e))
    }
    XCTAssertThrowsError(try DevelopmentProjectiveSourceROIV3(inverseMatrix:[1,0,0,0,1,0,0,0,1],
      sourceExtent:e.offsetBy(dx:1,dy:0),outputExtent:e))
  }
  func testNativeSmallTileIsLocalAndUsesActualUploadedFloatCoefficients() throws {
    let g = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:7,verticalPerspective:5)
    let r = try roi(g,width:5760,height:8640)
    let mapping = try g.mapping(sourceSize:.init(width:5760,height:8640))
    XCTAssertEqual(r.uploadedInverse,try mapping.inverseMatrix.map { Double(Float($0)) })
    XCTAssertGreaterThan(r.sourceCoordinateError,0); XCTAssertLessThan(r.halo,16)
    let tile = CGRect(x:r.outputExtent.midX,y:r.outputExtent.midY,width:14,height:12)
    assertFootprint(r,tile:tile)
    let area = r.sourceRect(for:tile).width*r.sourceRect(for:tile).height
    XCTAssertLessThan(area,4096) // old callback requested 49,766,400 source pixels for every tile
    XCTAssertLessThan(area*16,512*1024*1024)
  }
  func testWholeOutputCornersBoundInteriorUnderStrongPositivePerspective() throws {
    let e = CGRect(x:0,y:0,width:96,height:72)
    let r = try DevelopmentProjectiveSourceROIV3(inverseMatrix:[0.7,0.04,2,0.02,0.6,3,0.002,0.001,0.5],
      sourceExtent:e,outputExtent:e)
    assertFootprint(r,tile:e)
    assertFootprint(r,tile:.init(x:11.25,y:5.125,width:14.5,height:12.75))
  }

  private func input() -> CIImage {
    var p = [SIMD4<Float>]()
    for y in 0..<72 { for x in 0..<96 {
      let a = Float(1+(x+3*y)%7)/8
      p.append(.init(Float(x%11)/11*a,Float(y%13)/13*a,Float((x+y)%17)/17*a,a))
    } }
    return CIImage(bitmapData:p.withUnsafeBytes { Data($0) },bytesPerRow:96*16,size:.init(width:96,height:72),
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func pixels(_ image: CIImage, bounds: CGRect) -> [Float] {
    var p = [Float](repeating:Float.nan,count:Int(bounds.width*bounds.height)*4)
    DevelopmentColorEngineV3.context.render(image,toBitmap:&p,rowBytes:Int(bounds.width)*16,bounds:bounds,
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return p
  }
  private func assertTiled(_ image: CIImage, file: StaticString = #filePath, line: UInt = #line) {
    let e = image.extent, whole = pixels(image,bounds:e), width = Int(e.width), height = Int(e.height)
    XCTAssertTrue(whole.allSatisfy(\.isFinite),file:file,line:line)
    XCTAssertGreaterThan(whole.enumerated().filter { $0.offset%4 == 3 }.map(\.element).max() ?? 0,0,file:file,line:line)
    for y in stride(from:0,to:height,by:9) { for x in stride(from:0,to:width,by:11) {
      let tile = CGRect(x:x,y:y,width:min(11,width-x),height:min(9,height-y)), p = pixels(image,bounds:tile)
      for row in 0..<Int(tile.height) { for column in 0..<Int(tile.width) { for c in 0..<4 {
        let reference = ((height-y-Int(tile.height)+row)*width+x+column)*4+c
        let actual = (row*Int(tile.width)+column)*4+c
        XCTAssertEqual(p[actual],whole[reference],accuracy:2e-7,"tile \(tile), RGBA\(c)",file:file,line:line)
      } } }
    } }
  }
  func testWholeVersusTiledProjectiveRGBASeamsAndTranslatedInput() throws {
    let g = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:7,verticalPerspective:5,horizontalPerspective:-12,
      crop:.init(x:0.08,y:0.11,width:0.8,height:0.76),lateOrientation:.init(orientation:.transverse))
    let output = try DevelopmentGeometryEngineV3.apply(g,to:input())
    assertTiled(output)
    let translated = try DevelopmentGeometryEngineV3.apply(g,to:input().transformed(by:.init(translationX:19,y:-23)))
    XCTAssertEqual(pixels(output,bounds:output.extent),pixels(translated,bounds:translated.extent))
  }
  func testLazyDownsampleKeepsFractionalSourceRequestsAndAlphaSeamless() throws {
    let g = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:7,verticalPerspective:5,
      lateOrientation:.init(orientation:.rotate90))
    let output = try DevelopmentGeometryEngineV3.apply(g,to:input())
    let scale = 0.613, scaled = output.transformed(by:.init(scaleX:scale,y:scale))
    let e = CGRect(x:0,y:0,width:floor(scaled.extent.width),height:floor(scaled.extent.height))
    assertTiled(scaled.cropped(to:e))
  }
}
