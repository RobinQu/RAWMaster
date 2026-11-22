import CoreImage
import RAWMasterCore
import XCTest
import Metal
@testable import RAWMasterImaging

final class FlashRawNoiseReductionTests: XCTestCase {
  func testIndependentLuminanceChromaAndNativeDetailPreserveAlphaAndEdges() throws {
    let width = 24, height = 8
    let context = DevelopmentColorEngineV3.makeContext()
    var signal = [SIMD4<Float>]()
    for y in 0..<height {
      for x in 0..<width {
        let level: Float = x < width / 2 ? 0.15 : 0.92
        let noise: Float = (x+y).isMultiple(of:2) ? 0.035 : -0.035
        let alpha: Float = x < 3 ? 0.5 : 1
        signal.append(.init((level+noise*1.5)*alpha,(level+noise)*alpha,(level-noise)*alpha,alpha))
      }
    }
    let source = CIImage(bitmapData: signal.withUnsafeBytes { Data($0) }, bytesPerRow: width*16,
      size: .init(width: width,height: height), format: .RGBAf, colorSpace: DevelopmentColorEngineV3.linearSRGB)
    XCTAssertTrue(try FlashRawNoiseReduction.apply(.init(),to:source,proxyScale:1) === source)
    func rendered(_ nr: DevelopmentNoiseReductionV3) throws -> [SIMD4<Float>] {
      let result = try FlashRawNoiseReduction.apply(nr, to: source, proxyScale: 1)
      var pixels = Array(repeating: SIMD4<Float>.zero, count: width*height)
      context.render(result,toBitmap:&pixels,rowBytes:width*16,bounds:source.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      return pixels
    }
    let luma = try rendered(.init(enabled:true,luminanceNoise:1))
    let chroma = try rendered(.init(enabled:true,colorNoise:1))
    let detail = try rendered(.init(enabled:true,luminanceNoise:1,detail:2))
    func y(_ p: SIMD4<Float>) -> Float { (0.2126*p.x + 0.7152*p.y + 0.0722*p.z)/p.w }
    let i = 4 * width + 6
    XCTAssertLessThan(abs(y(luma[i])-y(luma[i+1])),abs(y(signal[i])-y(signal[i+1])))
    XCTAssertGreaterThan(abs(y(detail[i])-y(detail[i+1])),abs(y(luma[i])-y(luma[i+1])))
    XCTAssertEqual(y(chroma[i]),y(signal[i]),accuracy:0.00003)
    XCTAssertLessThan(abs(chroma[i].x-chroma[i].z),abs(signal[i].x-signal[i].z))
    XCTAssertEqual(luma[i].x-luma[i].z,signal[i].x-signal[i].z,accuracy:0.00003)
    XCTAssertGreaterThan(y(luma[4*width+12])-y(luma[4*width+11]),0.68)
    XCTAssertEqual(luma.map(\.w),signal.map(\.w))
    XCTAssertEqual(chroma.map(\.w),signal.map(\.w))
  }
  func testLumaResponseRetainsFractionalSamplingHDREdgesAndAlpha() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), context = DevelopmentColorEngineV3.makeContext()
    let width=73,height=41
    let data = (0..<width*height).map { i -> SIMD4<Float> in
      let x=i%width, y=i/width, a:Float=x%9==0 ? 0:(x%11==0 ? 0.45:1)
      let grain:Float=(x+y)%3==0 ? 0.013:-0.004
      let level:Float=x<width/2 ? -0.01:1.8
      return .init((level+grain)*a,(level*0.75-grain)*a,(level*0.4+grain)*a,a)
    }
    let source=CIImage(bitmapData:data.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    func read(_ image:CIImage)->[SIMD4<Float>] {
      var pixels=[SIMD4<Float>](repeating:.zero,count:width*height)
      context.render(image,toBitmap:&pixels,rowBytes:width*16,bounds:source.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      return pixels
    }
    for scale in [0.252525,1.0] {
      let response=try FlashRawNoiseReduction.measureLuma(source,radius:1.5*scale)
      let scalar=try DevelopmentSpatialEngineV3.materializeScalar(response,context:context,device:device,check:{})
      for detail in [0.1,0.65,2.0] {
        let controls=DevelopmentNoiseReductionV3(enabled:true,luminanceNoise:0.7,detail:detail)
        let expected=read(try FlashRawNoiseReduction.apply(controls,to:source,proxyScale:scale))
        let actual=read(try FlashRawNoiseReduction.applyLuma(controls,to:source,guide:scalar))
        XCTAssertTrue(zip(expected,actual).allSatisfy { a,b in a.w==b.w && abs(a.x-b.x)<0.00001 && abs(a.y-b.y)<0.00001 && abs(a.z-b.z)<0.00001 })
      }
    }
  }
}
