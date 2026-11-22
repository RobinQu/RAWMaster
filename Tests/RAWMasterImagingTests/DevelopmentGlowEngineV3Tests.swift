import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentGlowEngineV3Tests: XCTestCase {
  private func fixture() -> CIImage {
    let width = 64, height = 48
    let pixels = (0..<(width*height)).map { index -> SIMD4<Float> in
      let x = index % width, y = index / width
      let bright = (24..<40).contains(x) && (18..<30).contains(y)
      let alpha: Float = y == 0 ? 0.5:1
      let value: Float = bright ? 2.5:0.08
      return .init(value*alpha,value*0.8*alpha,value*0.6*alpha,alpha)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:width*16,
      size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image: CIImage) -> [Float] {
    var values = [Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
    DevelopmentColorEngineV3.context.render(image,toBitmap:&values,rowBytes:Int(image.extent.width)*16,
      bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return values
  }
  func testEveryGlowStyleProducesFiniteGPUResponseAndPreservesAlpha() throws {
    let input = fixture(), original = read(input)
    for style in DevelopmentGlowStyleV3.allCases {
      let glow = DevelopmentGlowV3(enabled:true,amount:55,style:style,range:55,spread:45,warmth:25,direction:35,softness:65)
      let output = try DevelopmentGlowEngineV3.apply(.init(glow:glow),to:input)
      try DevelopmentColorEngineV3.validateFinite(output)
      let actual = read(output)
      XCTAssertTrue(zip(actual,original).contains { abs($0.0-$0.1)>1e-5 },style.rawValue)
      for index in stride(from:3,to:actual.count,by:4) { XCTAssertEqual(actual[index],original[index],accuracy:1e-6,style.rawValue) }
    }
  }
  func testGlowAcceptsUpstreamKernelOutputWithoutChangingUnmaskedPixels() throws {
    let input = fixture()
    let upstream = input.applyingFilter("CIColorMatrix")
    let glow = DevelopmentGlowV3(enabled:true,amount:55,style:.halation,range:55,spread:45,warmth:25)
    let direct = read(try DevelopmentGlowEngineV3.apply(glow,to:input))
    let chained = read(try DevelopmentGlowEngineV3.apply(glow,to:upstream))
    XCTAssertEqual(direct.count,chained.count)
    for index in direct.indices { XCTAssertEqual(direct[index],chained[index],accuracy:2e-5,"channel \(index)") }
  }
  func testDisabledGlowIsExactGraphBypass() throws {
    let input = fixture()
    let output = try DevelopmentGlowEngineV3.apply(.init(glow:.init(enabled:false,amount:80)),to:input)
    XCTAssertTrue(output === input)
    let absent = try DevelopmentGlowEngineV3.apply(nil,to:input)
    XCTAssertTrue(absent === input)
  }
}
