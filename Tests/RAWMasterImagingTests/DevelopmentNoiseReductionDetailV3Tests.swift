import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentNoiseReductionDetailV3Tests:XCTestCase {
  private let context=DevelopmentColorEngineV3.makeContext()
  private func chart()->CIImage {
    let width=160,height=96
    let pixels=(0..<(width*height)).map{i->SIMD4<Float> in
      let x=i%width,y=i/width,a:Float=y<8 ? 0.5:1
      let edge=x<80 ? SIMD3<Float>(0.12,0.18,0.25):SIMD3<Float>(0.5,0.25,0.12)
      let fine=Float(x%4<2 ? 0.02:-0.02)
      return .init((edge.x+fine)*a,(edge.y-fine)*a,(edge.z+0.5*fine)*a,a)
    }
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>](repeating:.init(),count:Int(image.extent.width*image.extent.height))
    context.render(image,toBitmap:&pixels,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  private func render(_ nr:DevelopmentNoiseReductionV3,to input:CIImage,raw:Bool=false)throws->[SIMD4<Float>] {
    read(try DevelopmentGlobalEngineV3.apply(.init(noiseReduction:nr),to:input,sourceIsRAW:raw))
  }
  func testLuminanceContrastAndColorDetailHaveIndependentGPUResponses()throws {
    let input=chart(),original=read(input)
    let contrast=DevelopmentNoiseReductionV3(enabled:true,sourceCapability:.image,luminanceContrast:0.8)
    let color=DevelopmentNoiseReductionV3(enabled:true,sourceCapability:.image,colorDetail:0.8)
    let a=try render(contrast,to:input),b=try render(color,to:input)
    for actual in [a,b] {
      XCTAssertTrue(zip(actual,original).contains{abs($0.0.x-$0.1.x)>1e-5})
      for (p,q) in zip(actual,original){XCTAssertEqual(p.w.bitPattern,q.w.bitPattern)}
    }
    XCTAssertNotEqual(a.map(\.x.bitPattern),b.map(\.x.bitPattern))
    try DevelopmentColorEngineV3.validateFinite(DevelopmentGlobalEngineV3.apply(.init(noiseReduction:contrast),to:input,sourceIsRAW:false))
  }
  func testRAWDomainUsesTheSameImageStageAndDisabledOrZeroBypassesExactly()throws {
    let input=chart()
    let nr=DevelopmentNoiseReductionV3(enabled:true,sourceCapability:.raw,luminanceContrast:0.4,colorDetail:0.6)
    XCTAssertTrue(zip(try render(nr,to:input,raw:true),read(input)).contains{abs($0.0.x-$0.1.x)>1e-5})
    var disabled=nr;disabled.enabled=false
    XCTAssertTrue(try DevelopmentGlobalEngineV3.apply(.init(noiseReduction:disabled),to:input,sourceIsRAW:true) === input)
    let zero=DevelopmentNoiseReductionV3(enabled:true,sourceCapability:.raw,luminanceContrast:0,colorDetail:0)
    XCTAssertTrue(try DevelopmentGlobalEngineV3.apply(.init(noiseReduction:zero),to:input,sourceIsRAW:true) === input)
    XCTAssertTrue(DevelopmentRendererV3.hasNewEffects(.init(noiseReduction:nr)))
  }
}
