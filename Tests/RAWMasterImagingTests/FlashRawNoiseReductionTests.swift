import CoreImage
import RAWMasterCore
import XCTest
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
}
