import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentPostCropVignetteEngineV3Tests: XCTestCase {
  private func fixture() -> CIImage {
    let width = 64, height = 48
    let pixels = (0..<(width*height)).map { index -> SIMD4<Float> in
      let x = index % width, y = index / width, alpha: Float = y == 0 ? 0.5:1
      // Keep bright edge strips above the highlight-recovery threshold, where
      // the vignette has coverage; bright pixels at the center would not test it.
      let bright = (24..<40).contains(x) && !(4..<44).contains(y)
      let color = bright ? SIMD3<Float>(2, 2, 2) : SIMD3<Float>(0.4, 0.5, 0.6)
      return .init(color.x*alpha,color.y*alpha,color.z*alpha,alpha)
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
  private func apply(_ value: DevelopmentPostCropVignetteV3, to input: CIImage) throws -> [Float] {
    let output = try DevelopmentPostCropVignetteEngineV3.apply(.init(postCropVignette:value),to:input)
    try DevelopmentColorEngineV3.validateFinite(output)
    return read(output)
  }
  func testAllStylesAndRefinementsProduceFiniteResponseAndPreserveAlpha() throws {
    let input = fixture(), original = read(input)
    for style in DevelopmentPostCropVignetteStyleV3.allCases {
      let actual = try apply(.init(enabled:true,amount:-55,style:style,midpoint:45,roundness:20,feather:55,highlights:75),to:input)
      XCTAssertTrue(zip(actual,original).contains { abs($0.0-$0.1)>1e-5 },style.rawValue)
      for index in stride(from:3,to:actual.count,by:4) { XCTAssertEqual(actual[index],original[index],accuracy:1e-6,style.rawValue) }
    }
    let base = DevelopmentPostCropVignetteV3(enabled:true,amount:-45)
    let baseline = try apply(base,to:input)
    for changed in [
      DevelopmentPostCropVignetteV3(enabled:true,amount:-45,midpoint:90),
      .init(enabled:true,amount:-45,roundness:90),
      .init(enabled:true,amount:-45,feather:95),
      .init(enabled:true,amount:-45,highlights:95)
    ] { XCTAssertNotEqual(baseline.map(\.bitPattern),try apply(changed,to:input).map(\.bitPattern)) }
  }
  func testHighlightAndColorPriorityDifferWithDefaultHighlightRecovery() throws {
    let input = fixture()
    let highlight = try apply(.init(enabled:true, amount:-60, style:.highlightPriority), to:input)
    let color = try apply(.init(enabled:true, amount:-60, style:.colorPriority), to:input)
    XCTAssertTrue(zip(highlight, color).contains { $0.0 > $0.1 + 0.02 })
  }

  func testInactivePostCropIsExactGraphBypass() throws {
    let input = fixture()
    let output = try DevelopmentPostCropVignetteEngineV3.apply(.init(postCropVignette:.init(enabled:false,amount:50)),to:input)
    XCTAssertTrue(output === input)
  }
}
