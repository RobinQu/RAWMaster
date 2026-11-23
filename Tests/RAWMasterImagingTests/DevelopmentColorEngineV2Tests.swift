import XCTest
import CoreImage
import AppKit
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentColorEngineV2Tests: XCTestCase {
  private let linear = DevelopmentColorEngineV2.linearSRGB
  private func image(_ pixels: [SIMD4<Float>]) -> CIImage {
    let data = pixels.withUnsafeBytes { Data($0) }
    return CIImage(bitmapData:data,bytesPerRow:pixels.count*16,size:CGSize(width:pixels.count,height:1),format:.RGBAf,colorSpace:linear)
  }
  private func materialize(_ image: CIImage) -> [Float] {
    var data = [Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
    DevelopmentColorEngineV2.context.render(image,toBitmap:&data,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:linear)
    return data
  }
  private func colorCases() throws -> [DevelopmentColorAdjustments] {
    var cases: [DevelopmentColorAdjustments] = [.init()]
    for path in [\DevelopmentTones.contrast,\.highlights,\.shadows,\.whites,\.blacks,\.vibrance,\.saturation] {
      for value in [-100.0,100] { var color = DevelopmentColorAdjustments(); color.tones[keyPath:path] = value; cases.append(color) }
    }
    let curve = DevelopmentCurve(points:[.init(x:0,y:0),.init(x:0.25,y:0.18),.init(x:0.5,y:0.5),.init(x:0.75,y:0.82),.init(x:1,y:1)])
    for path in [\DevelopmentCurves.rgb,\.red,\.green,\.blue] { var color = DevelopmentColorAdjustments(); color.curves[keyPath:path] = curve; cases.append(color) }
    for curve in [DevelopmentCurve(points:[.init(x:0,y:1),.init(x:1,y:0)]),
      .init(points:[.init(x:0,y:0),.init(x:0.4999,y:0),.init(x:0.5,y:1),.init(x:1,y:1)]),
      .init(points:[.init(x:0,y:0),.init(x:0.2,y:0.9),.init(x:0.4,y:0.1),.init(x:0.6,y:0.9),.init(x:1,y:0.2)])] {
      var color = DevelopmentColorAdjustments(); color.curves.rgb = curve; cases.append(color)
    }
    for path in [\DevelopmentColorGrading.shadows,\.midtones,\.highlights,\.global] {
      var color = DevelopmentColorAdjustments(); color.grading[keyPath:path] = .init(hueDegrees:220,saturation:70,luminance:10); cases.append(color)
    }
    for balance in [-100.0,100] { for blending in [0.0,100] {
      var color = DevelopmentColorAdjustments(); color.grading.shadows = .init(hueDegrees:0,saturation:80)
      color.grading.highlights = .init(hueDegrees:240,saturation:80); color.grading.balance = balance; color.grading.blending = blending; cases.append(color)
    } }
    for value in [-100.0,100] { var color = DevelopmentColorAdjustments(); color.grading.global.luminance = value; cases.append(color) }
    var combo = DevelopmentColorAdjustments(); combo.tones = .init(contrast:20,highlights:-35,shadows:30,whites:10,blacks:-10,vibrance:15,saturation:5)
    combo.curves.rgb = curve; combo.grading.shadows = .init(hueDegrees:220,saturation:15,luminance:5); combo.grading.highlights = .init(hueDegrees:40,saturation:12)
    cases.append(combo)
    var opposed = DevelopmentColorAdjustments(); opposed.tones.shadows = 100; opposed.tones.highlights = -100; cases.append(opposed)
    return cases
  }
  func testToneAllSixteenExtremeCombinationsAreMonotoneIncludingHDRAndContrastEnds() throws {
    for mask in 0..<16 { for contrast in [-100.0,0,100] {
      var color = DevelopmentColorAdjustments()
      color.tones = .init(contrast:contrast,highlights:mask&1 == 0 ? -100:100,shadows:mask&2 == 0 ? -100:100,
        whites:mask&4 == 0 ? -100:100,blacks:mask&8 == 0 ? -100:100)
      let params = try DevelopmentColorEngineV2.Parameters(color)
      var previous = -Double.infinity
      for step in 0...4096 {
        let p = -0.25+1.5*Double(step)/4096
        let value = 0.5+pow(2,contrast/100)*(params.evaluate(p,row:0)-0.5)
        XCTAssertGreaterThanOrEqual(value+1e-12,previous); previous = value
      }
      let zero = params.evaluate(0,row:0), one = params.evaluate(1,row:0)
      XCTAssertEqual(params.evaluate(-1,row:0),zero-1,accuracy:1e-12)
      XCTAssertEqual(params.evaluate(2,row:0),one+1,accuracy:1e-12)
    } }
  }
  func testBalancePositiveFavorsHighlightsAndSaturationMinusHundredIsGray() throws {
    var color = DevelopmentColorAdjustments(); color.grading.shadows = .init(hueDegrees:0,saturation:80)
    color.grading.highlights = .init(hueDegrees:240,saturation:80)
    let gray = DevelopmentColorEngineV2.decode(0.5), pixel = SIMD4(gray,gray,gray,1)
    color.grading.balance = -100; let shadows = try DevelopmentColorEngineV2.reference(pixel,color:color)
    color.grading.balance = 100; let highlights = try DevelopmentColorEngineV2.reference(pixel,color:color)
    XCTAssertGreaterThan(shadows.x,highlights.x); XCTAssertGreaterThan(highlights.z,shadows.z)
    color = .init(); color.tones.saturation = -100
    let result = try DevelopmentColorEngineV2.reference(.init(0.7,0.2,0.01,1),color:color)
    XCTAssertEqual(result.x,result.y,accuracy:1e-12); XCTAssertEqual(result.y,result.z,accuracy:1e-12)
  }
  func testDisabledGradingPreservesWheelsAndChangesOnlyGradingPixels() throws {
    var color = DevelopmentColorAdjustments(tones: .init(contrast: 15),
      grading: .init(global: .init(hueDegrees: 44, saturation: 55, luminance: 10)))
    let photo = image([.init(0.2, 0.3, 0.5, 1), .init(0.1, 0.25, 0.4, 1)])
    let enabled = materialize(try DevelopmentColorEngineV2.apply(color, to: photo))
    let old = try JSONEncoder().encode(color.grading)
    XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("enabled"))
    let legacy = try JSONDecoder().decode(DevelopmentColorGrading.self, from: old)
    XCTAssertTrue(legacy.isEnabled)

    color.grading.enabled = false
    let off = materialize(try DevelopmentColorEngineV2.apply(color, to: photo))
    let tonesOnly = materialize(try DevelopmentColorEngineV2.apply(.init(tones: color.tones), to: photo))
    XCTAssertNotEqual(enabled, off)
    XCTAssertEqual(off, tonesOnly)
    let archived = try JSONEncoder().encode(color)
    var restored = try JSONDecoder().decode(DevelopmentColorAdjustments.self, from: archived)
    XCTAssertEqual(restored, color)
    XCTAssertEqual(restored.grading.global, legacy.global)
    restored.grading.enabled = nil
    XCTAssertEqual(materialize(try DevelopmentColorEngineV2.apply(restored, to: photo)), enabled)
  }

  func testModernMetalKernelCompilesAndAllControlsMatchDoubleReferenceRGBA() throws {
    let samples: [SIMD3<Float>] = [.init(0,0,0),.init(0.003,0.01,0.08),.init(0.18,0.18,0.18),.init(0.8,0.2,0.05),
      .init(1,1,1),.init(4,1.5,0.2),.init(-0.1,0.2,0.8),.init(16,8,2)]
    var pixels: [SIMD4<Float>] = []
    let alphas: [Float] = [0,1e-8,1.0/65535,0.001,0.5,1]
    for alpha in alphas { for p in samples { pixels.append(.init(p.x*alpha,p.y*alpha,p.z*alpha,alpha)) } }
    let source = image(pixels)
    for (caseIndex,color) in try colorCases().enumerated() {
      let output = try DevelopmentColorEngineV2.apply(color,to:source)
      try DevelopmentColorEngineV2.validateFinite(output)
      let actual = materialize(output)
      for (index,pixel) in pixels.enumerated() {
        let expected = try DevelopmentColorEngineV2.reference(.init(Double(pixel.x),Double(pixel.y),Double(pixel.z),Double(pixel.w)),color:color)
        for channel in 0..<4 {
          XCTAssertEqual(Double(actual[index*4+channel]),expected[channel],accuracy:channel == 3 ? 1e-7:max(3e-5,abs(expected[channel])*3e-5),"case\(caseIndex) pixel\(index) ch\(channel)")
          if channel < 3 && pixel.w > 0 {
            let expectedStraight = expected[channel]/Double(pixel.w), actualStraight = Double(actual[index*4+channel])/Double(pixel.w)
            XCTAssertEqual(actualStraight,expectedStraight,accuracy:max(3e-5,abs(expectedStraight)*3e-5),"straight RGB case\(caseIndex) alpha\(pixel.w)")
          }
          if channel < 3 {
            for background in [0.0,1] {
              let alpha = Double(pixel.w)
              let ac = Int((min(1,max(0,DevelopmentColorEngineV2.encode(Double(actual[index*4+channel])+(1-alpha)*background)))*255).rounded())
              let ex = Int((min(1,max(0,DevelopmentColorEngineV2.encode(expected[channel]+(1-alpha)*background)))*255).rounded())
              XCTAssertLessThanOrEqual(abs(ac-ex),2,"separate black/white RGB composite")
            }
          }
        }
      }
    }
    print("V2 kernel sourceSHA=\(DevelopmentColorEngineV2.sourceSHA256) coldCompileNS=\(try DevelopmentColorEngineV2.compileNanoseconds())")
  }
  func testSteepCurvesDenseRampKeepRGBA8GatePerChannel() throws {
    var color = DevelopmentColorAdjustments()
    color.curves.rgb = .init(points:[.init(x:0,y:0),.init(x:0.4999,y:0),.init(x:0.5,y:1),.init(x:1,y:1)])
    let pixels = (0..<2048).map { index -> SIMD4<Float> in
      let v = Float(DevelopmentColorEngineV2.decode(0.49985+Double(index)*0.0002/2047)); return .init(v,v,v,1)
    }
    let actual = materialize(try DevelopmentColorEngineV2.apply(color,to:image(pixels)))
    var errors = [[Int]](repeating:[],count:3)
    for (index,pixel) in pixels.enumerated() {
      let expected = try DevelopmentColorEngineV2.reference(.init(Double(pixel.x),Double(pixel.y),Double(pixel.z),1),color:color)
      for channel in 0..<3 {
        let a = Int((min(1,max(0,DevelopmentColorEngineV2.encode(Double(actual[index*4+channel]))))*255).rounded())
        let b = Int((min(1,max(0,DevelopmentColorEngineV2.encode(expected[channel])))*255).rounded())
        errors[channel].append(abs(a-b))
      }
    }
    for channel in 0..<3 { let sorted = errors[channel].sorted(); XCTAssertLessThanOrEqual(sorted[Int(ceil(Double(sorted.count)*0.99))-1],1); XCTAssertLessThanOrEqual(sorted.max() ?? 0,2) }
  }
  func testNonfiniteMaterializationIsRejectedAndNeutralIsExactBypass() throws {
    let pixels: [SIMD4<Float>] = [.init(0.1,0.2,0.3,1),.init(0,0,0,0)]
    let source = image(pixels)
    XCTAssertTrue(try DevelopmentColorEngineV2.apply(.init(),to:source) === source)
    _ = try DevelopmentColorEngineV2.compileNanoseconds()
    let bad = CIImage(bitmapData:[Float.nan,0,0,1].withUnsafeBytes { Data($0) },bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:nil)
    XCTAssertThrowsError(try DevelopmentColorEngineV2.validateFinite(bad))
  }
  func testNonfiniteTransparentSourceRejectsAfterActualApplyWhileFiniteTransparentRemainsClear() throws {
    var color = DevelopmentColorAdjustments(); color.tones.saturation = 10
    _ = try DevelopmentColorEngineV2.compileNanoseconds()
    for value in [Float.nan,Float.infinity,-Float.infinity] {
      let source = CIImage(bitmapData:[value,0,0,0].withUnsafeBytes { Data($0) },bytesPerRow:16,
        size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:nil)
      let processed = try DevelopmentColorEngineV2.apply(color,to:source)
      XCTAssertThrowsError(try DevelopmentColorEngineV2.validateFinite(processed))
    }
    let finite = CIImage(bitmapData:[Float(0),0,0,0].withUnsafeBytes { Data($0) },bytesPerRow:16,
      size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:nil)
    let processed = try DevelopmentColorEngineV2.apply(color,to:finite)
    XCTAssertNoThrow(try DevelopmentColorEngineV2.validateFinite(processed))
    XCTAssertEqual(materialize(processed),[0,0,0,0])
  }

}
