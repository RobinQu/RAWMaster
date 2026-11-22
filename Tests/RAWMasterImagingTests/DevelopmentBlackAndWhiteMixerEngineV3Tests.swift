import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentBlackAndWhiteMixerEngineV3Tests: XCTestCase {
  private let colors:[SIMD3<Float>] = [
    .init(1,0,0),.init(1,0.25,0),.init(1,1,0),.init(0,1,0),
    .init(0,1,1),.init(0,0,1),.init(0.5,0,0.75),.init(1,0,1),.init(0.5,0.5,0.5)
  ]
  private var input:CIImage {
    let pixels=colors.enumerated().map { index,color -> SIMD4<Float> in
      let alpha:Float=index==0 ? 0.5:1
      return .init(color.x*alpha,color.y*alpha,color.z*alpha,alpha)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:colors.count*16,
      size:.init(width:colors.count,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.zero,count:Int(image.extent.width*image.extent.height))
    DevelopmentColorEngineV3.context.render(image,toBitmap:&pixels,rowBytes:Int(image.extent.width)*16,
      bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func develop(_ mixer:DevelopmentBlackAndWhiteMixerV3)throws->[SIMD4<Float>] {
    let bw=DevelopmentBlackAndWhiteV3(enabled:true,mixer:mixer)
    var p=DevelopmentAdjustmentsV3();p.blackAndWhite=bw
    let preconditioned=try DevelopmentBlackAndWhiteMixerEngineV3.apply(bw,to:input)
    return read(try DevelopmentColorEngineV3.applyPointwise(p,to:preconditioned))
  }
  func testAllEightBandsChangeTheirOwnGrayAndPreserveNeutralAndAlpha()throws {
    let zero=DevelopmentBlackAndWhiteMixerV3()
    let baseline=try develop(zero)
    for (index,pixel) in baseline.enumerated() {
      XCTAssertEqual(pixel.x,pixel.y,accuracy:1e-5);XCTAssertEqual(pixel.y,pixel.z,accuracy:1e-5)
    }
    for band in 0..<8 {
      var values=[Double](repeating:0,count:8);values[band]=0.85
      let actual=try develop(.init(values:values))
      XCTAssertNotEqual(actual[band].x,baseline[band].x,accuracy:1e-4,"band \(band)")
      XCTAssertEqual(actual[band].w,baseline[band].w,accuracy:1e-6)
      XCTAssertEqual(actual[8].x,baseline[8].x,accuracy:1e-5,"neutral changed by band \(band)")
      XCTAssertEqual(actual[band].x,actual[band].y,accuracy:1e-5)
      XCTAssertEqual(actual[band].y,actual[band].z,accuracy:1e-5)
    }
  }
  func testOptionalRecipeRoundTripAndNativeDomainRejection()throws {
    let legacy=DevelopmentBlackAndWhiteV3(enabled:true)
    let data=try JSONEncoder().encode(legacy)
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:data)as? [String:Any])["mixer"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentBlackAndWhiteV3.self,from:data),legacy)
    let active=DevelopmentBlackAndWhiteV3(enabled:true,mixer:.init(values:[0.5,0,0,0,0,0,0,0]))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentBlackAndWhiteV3.self,from:JSONEncoder().encode(active)),active)
    XCTAssertThrowsError(try DevelopmentBlackAndWhiteMixerV3(values:[0]).validate())
    XCTAssertThrowsError(try DevelopmentBlackAndWhiteMixerV3(values:[2]).validate())
    let recipe=DevelopmentRecipe(adjustmentsV3:.init(blackAndWhite:active))
    XCTAssertEqual(try PreviewNativePointwiseCertificateV2.domainReason(recipe,size:.init(width:9,height:1)),.recipe)
  }
}
