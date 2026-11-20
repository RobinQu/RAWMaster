import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentVignetteCoordinateTests: XCTestCase {
  private func image(width: Int,height: Int,origin: CGPoint = .zero) -> CIImage {
    let pixels = Array(repeating:SIMD4<Float>(0.1,0.2,0.3,0.4),count:width*height)
    return CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:width*16,
      size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      .transformed(by:.init(translationX:origin.x,y:origin.y))
  }
  private func apply(_ input: CIImage,softness: Double = 0) throws -> CIImage {
    var p = DevelopmentAdjustmentsV3(); p.vignette = .init(enabled:true,strength:0.5,radius:0.5,softness:softness)
    return try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false)
  }
  private func read(_ input: CIImage) -> [Float] {
    var pixels = [Float](repeating:0,count:Int(input.extent.width*input.extent.height)*4)
    DevelopmentColorEngineV3.context.render(input,toBitmap:&pixels,rowBytes:Int(input.extent.width)*16,
      bounds:input.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  func testActualCenterSurvivesAndCornerDarkensWithoutChangingAlpha() throws {
    let width = 80, actual = read(try apply(image(width:width,height:80)))
    func gain(_ x: Int,_ y: Int) -> Float { actual[(y*width+x)*4]/0.1 }
    XCTAssertEqual(gain(40,40),1,accuracy:1e-6)
    XCTAssertLessThan(gain(0,0),0.7); XCTAssertGreaterThan(gain(0,0),0)
    XCTAssertLessThan(gain(0,40),gain(40,40))
    XCTAssertEqual(gain(0,40),gain(79,40),accuracy:1e-6)
    for i in stride(from:0,to:actual.count,by:4) {
      XCTAssertEqual(actual[i+3],0.4,accuracy:1e-7)
      XCTAssertEqual(actual[i+1],2*actual[i],accuracy:1e-7)
      XCTAssertEqual(actual[i+2],3*actual[i],accuracy:1e-7)
    }
  }
  func testTranslatedWorkingExtentRetainsIdenticalRadialPixels() throws {
    let base = read(try apply(image(width:96,height:64),softness:0.8))
    for origin in [CGPoint(x:137,y:-59),CGPoint(x:-71,y:113)] {
      let moved = read(try apply(image(width:96,height:64,origin:origin),softness:0.8))
      XCTAssertEqual(moved.count,base.count)
      for i in base.indices { XCTAssertEqual(moved[i],base[i],accuracy:2e-6,"translated channel \(i)") }
    }
  }
  func testWideAndTallImagesUseCircularPhysicalDistanceInsteadOfAnisotropicEllipse() throws {
    for (width,height) in [(160,80),(80,160)] {
      let actual = read(try apply(image(width:width,height:height),softness:0.8))
      let cx = width/2, cy = height/2
      func value(_ x: Int,_ y: Int) -> Float { actual[(y*width+x)*4] }
      XCTAssertEqual(value(cx+36,cy),value(cx,cy+36),accuracy:1e-6)
      XCTAssertEqual(value(cx-37,cy),value(cx,cy-37),accuracy:1e-6)
      XCTAssertLessThan(value(cx+36,cy),value(cx,cy))
    }
  }
  func testDownsampleKeepsCanonicalWorldSpaceMaskAndOwnedProfile() throws {
    let canonical = try apply(image(width:160,height:80),softness:1)
    let small = canonical.transformed(by:.init(scaleX:0.5,y:0.5)), pixels = read(small)
    for (x,y) in [(40,20),(51,20),(60,20),(10,3)] {
      // Pixel center in the output maps back to canonical working coordinates before vignette.
      let worldX = 2*(Double(x)+0.5), worldY = 2*(Double(y)+0.5)
      let d = hypot(worldX-80,worldY-40)/40
      let shoulder = max(0,d-DevelopmentGlobalEngineV3.vignetteOnset)
      let gain = exp2(-DevelopmentGlobalEngineV3.vignetteFalloffCoefficient*shoulder*shoulder/3)
      let i = (y*80+x)*4
      XCTAssertEqual(Double(pixels[i])/0.1,gain,accuracy:0.004)
      XCTAssertEqual(pixels[i+3],0.4,accuracy:1e-7)
    }
  }
  func testDisabledAndZeroStrengthKeepInputF32BitsExact() throws {
    let input = image(width:64,height:48), expected = read(input).map(\.bitPattern)
    for v in [DevelopmentVignetteV3(enabled:false,strength:1,radius:0,softness:1),
      .init(enabled:true,strength:0,radius:0,softness:1)] {
      var p = DevelopmentAdjustmentsV3(); p.vignette = v
      XCTAssertEqual(read(try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false)).map(\.bitPattern),expected)
    }
  }
  func testUniformSourceScalingPreservesGainAndNegativeStrengthIsReciprocal() throws {
    func sample(_ input: CIImage,_ center: CGPoint) -> Float {
      // The actual tiny destination probe proves fractional render bounds are integralized.
      // Use only integer origins so this tests the profile, not an unsupported sampling premise.
      XCTAssertEqual(center.x-0.5,floor(center.x-0.5)); XCTAssertEqual(center.y-0.5,floor(center.y-0.5))
      var pixel = [Float](repeating:0,count:4)
      DevelopmentColorEngineV3.context.render(input,toBitmap:&pixel,rowBytes:16,
        bounds:.init(x:center.x-0.5,y:center.y-0.5,width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      return pixel[0]/0.1
    }
    // Odd scale maps every n+.5 source center to an exact m+.5 larger-image center.
    let small = try apply(image(width:80,height:40)), large = try apply(image(width:240,height:120))
    var p = DevelopmentAdjustmentsV3(); p.vignette = .init(enabled:true,strength:-0.5)
    let bright = try DevelopmentGlobalEngineV3.apply(p,to:image(width:80,height:40),sourceIsRAW:false)
    for point in [CGPoint(x:40.5,y:20.5),.init(x:3.5,y:5.5),.init(x:70.5,y:33.5)] {
      let dim = sample(small,point)
      XCTAssertEqual(sample(large,.init(x:point.x*3,y:point.y*3)),dim,accuracy:0.003)
      XCTAssertEqual(dim*sample(bright,point),1,accuracy:1e-5)
    }
  }
}
