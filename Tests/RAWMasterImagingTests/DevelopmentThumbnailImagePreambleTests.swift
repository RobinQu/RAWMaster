import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentThumbnailImagePreambleTests:XCTestCase {
  private let context=DevelopmentColorEngineV3.context
  private func input()->CIImage {
    var pixels=[SIMD4<Float>]()
    for y in 0..<24 { for x in 0..<32 {
      let a:Float=x<2 ? 0:(x<4 ? 0.5:1)
      pixels.append(.init((0.15+Float(x)/100)*a,(0.12+Float(y)/100)*a,0.2*a,a))
    }}
    return .init(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32*16,size:.init(width:32,height:24),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)throws->[SIMD4<Float>] {
    var result=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(image,rect:image.extent,context:context){result=Array($0)};return result
  }
  func testActiveImageWBFinitePrefixStaysProxySizedAndMatchesOriginalOrder()throws {
    let base=input()
    var p=DevelopmentAdjustmentsV3(legacyBasis:.init(version:.v1,exposureEV:0.25,whiteBalance:.temperatureTint(temperature:5300,tint:8)))
    p.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:7000,tint:12))
    let actual=try DevelopmentThumbnailEngine.imagePreamble(p,to:base,context:context)
    // Absolute image WB overrides legacyWB; historical EV still precedes it.
    let expected=try DevelopmentWhiteBalanceEngineV3.applyImage(p.whiteBalance,
      to:base.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:0.25]),context:context)
    XCTAssertEqual(actual.extent,base.extent);XCTAssertEqual(actual.extent.size,CGSize(width:32,height:24))
    XCTAssertEqual(try read(actual),try read(expected))
    let expanded=actual.transformed(by:.init(scaleX:9504.0/32,y:6336.0/24))
    XCTAssertEqual(expanded.extent.size,CGSize(width:9504,height:6336))
    XCTAssertTrue(DevelopmentThumbnailEngine.version.contains("prefix-unbaked"))
  }
  func testDisabledWBRetainsRememberedModeAndLegacyWBThenEV()throws {
    let base=input()
    var p=DevelopmentAdjustmentsV3(legacyBasis:.init(version:.v1,exposureEV:0.5,whiteBalance:.temperatureTint(temperature:5300,tint:8)))
    p.whiteBalance = .init(enabled:false,adjustment:.temperatureTint(temperature:9000,tint:20))
    let before=p
    let actual=try DevelopmentThumbnailEngine.imagePreamble(p,to:base,context:context)
    let expected=base.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:5300,y:8),"inputTargetNeutral":CIVector(x:6500,y:0)])
      .applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:0.5])
    XCTAssertEqual(p,before);XCTAssertEqual(try read(actual),try read(expected))
  }
  func testNeutralPrefixExactGraphBypassAndNativeExtentIsRejectedBeforeWB()throws {
    let base=input()
    XCTAssertTrue(try DevelopmentThumbnailEngine.imagePreamble(.init(),to:base,context:context) === base)
    var p=DevelopmentAdjustmentsV3();p.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:7000,tint:12))
    let native=base.transformed(by:.init(scaleX:9504.0/32,y:6336.0/24))
    XCTAssertThrowsError(try DevelopmentThumbnailEngine.imagePreamble(p,to:native,context:context)) {
      if case DevelopmentThumbnailError.invalidEncoding=$0 {} else { XCTFail("Wrong preamble size failure") }
    }
  }
}
