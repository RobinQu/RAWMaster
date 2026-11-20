import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentV3CalibrationTests: XCTestCase {
  private let linear = DevelopmentColorEngineV3.linearSRGB
  private func image(_ pixels: [SIMD4<Float>], width: Int? = nil, height: Int = 1) -> CIImage {
    let w = width ?? pixels.count
    return CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:w*16,
      size:.init(width:w,height:height),format:.RGBAf,colorSpace:linear)
  }
  private func materialize(_ image: CIImage, bounds: CGRect? = nil) -> [Float] {
    let rect = bounds ?? image.extent
    var pixels = [Float](repeating:0,count:Int(rect.width*rect.height)*4)
    DevelopmentColorEngineV3.context.render(image,toBitmap:&pixels,rowBytes:Int(rect.width)*16,
      bounds:rect,format:.RGBAf,colorSpace:linear)
    return pixels
  }
  private func colorReference(_ rgb: SIMD3<Double>, saturation: Double, vibrance: Double, cast: Double = 0) -> SIMD3<Double> {
    var e = SIMD3(DevelopmentColorEngineV2.encode(rgb.x),DevelopmentColorEngineV2.encode(rgb.y),DevelopmentColorEngineV2.encode(rgb.z))
    let l = DevelopmentColorEngineV2.luma(e), top = max(e.x,max(e.y,e.z)), bottom = min(e.x,min(e.y,e.z))
    let sat = min(1,max(0,(top-bottom)/max(abs(top),1e-4)))
    let skin = e.x > e.y && e.y > e.z ? 0.5:1.0
    let warm = e.x > e.z && e.y > e.z ? 1.0:0.0
    let blue = max(0,e.z-max(e.x,e.y))*(1-min(1,max(0,l)))
    e = SIMD3(repeating:l)+(e-SIMD3(repeating:l))*((1+saturation*(1-0.391*warm))*(1+1.35*vibrance*(1-sat)*skin))
    e += blue*(saturation*SIMD3(-2.576,-0.364,0.447)+vibrance*SIMD3(-1.830,-0.494,-0.142))
    let tint = SIMD3(e.x*0.0214143+e.y*0.0479051-e.z*0.0105798-0.0019973,
      0,-e.x*0.0231834-e.y*0.0894344-e.z*0.0299565+0.0047775)
    e += 2*cast*tint
    return SIMD3(DevelopmentColorEngineV2.decode(e.x),DevelopmentColorEngineV2.decode(e.y),DevelopmentColorEngineV2.decode(e.z))
  }
  func testNewColorMetalMatchesDoubleReferenceAcrossAlphaAndExtendedValues() throws {
    let samples: [SIMD3<Float>] = [.init(0,0,0),.init(0.03,0.08,0.2),.init(0.5,0.2,0.04),
      .init(0.1,0.1,0.1),.init(-0.1,0.3,1.2),.init(4,2,0.5)]
    var pixels: [SIMD4<Float>] = []
    let alphas: [Float] = [0,1.0/65535,0.5,1]
    for alpha in alphas { for p in samples {
      pixels.append(.init(p.x*alpha,p.y*alpha,p.z*alpha,alpha))
    } }
    for (sat,vib) in [(0.5,0.0),(0.0,0.5),(-1.0,0.0),(0.0,-1.0),(2.0,2.0)] {
      var p = DevelopmentAdjustmentsV3(); p.color = .init(enabled:true,saturation:sat,vibrance:vib)
      let result = try DevelopmentColorEngineV3.applyPointwise(p,to:image(pixels))
      try DevelopmentColorEngineV3.validateFinite(result)
      let actual = materialize(result)
      for (i,pixel) in pixels.enumerated() {
        XCTAssertEqual(actual[i*4+3],pixel.w,accuracy:1e-7)
        if pixel.w == 0 { XCTAssertEqual(Array(actual[i*4..<i*4+4]),[0,0,0,0]); continue }
        let alpha = Double(pixel.w)
        let expected = colorReference(SIMD3(Double(pixel.x),Double(pixel.y),Double(pixel.z))/alpha,saturation:sat,vibrance:vib)
        for c in 0..<3 { XCTAssertEqual(Double(actual[i*4+c])/alpha,expected[c],accuracy:max(7e-5,abs(expected[c])*7e-5)) }
      }
    }
  }
  func testFixedSkySampleResidualImprovesWithoutCallingItFullQualification() {
    // Rounded fixed16x16 reference sample, encoded RGB. This is a calibration regression only.
    let encoded = SIMD3<Double>(0.2064,0.3186,0.4841)
    let source = SIMD3(DevelopmentColorEngineV2.decode(encoded.x),DevelopmentColorEngineV2.decode(encoded.y),DevelopmentColorEngineV2.decode(encoded.z))
    let l = DevelopmentColorEngineV2.luma(encoded)
    for (s,v,target) in [(0.5,0.0,SIMD3<Double>(0,0.2969,0.6099)),(0.0,0.5,SIMD3<Double>(0.1047,0.3030,0.5185))] {
      let sat = (encoded.z-encoded.x)/encoded.z
      let old = SIMD3(repeating:l)+(encoded-SIMD3(repeating:l))*((1+s)*(1+1.35*v*(1-sat)))
      let output = colorReference(source,saturation:s,vibrance:v)
      let new = SIMD3(DevelopmentColorEngineV2.encode(output.x),DevelopmentColorEngineV2.encode(output.y),DevelopmentColorEngineV2.encode(output.z))
      let oldError = abs(old.x-target.x)+abs(old.y-target.y)+abs(old.z-target.z)
      let newError = abs(new.x-target.x)+abs(new.y-target.y)+abs(new.z-target.z)
      XCTAssertLessThan(newError,oldError*0.6)
    }
  }
  func testCastAndBlackWhiteIsolatedMathRemainUnchanged() throws {
    let source = SIMD4<Float>(0.12,0.24,0.4,1)
    var p = DevelopmentAdjustmentsV3(); p.color = .init(enabled:true,cast:0.5)
    let cast = materialize(try DevelopmentColorEngineV3.applyPointwise(p,to:image([source])))
    let expectedCast = colorReference(.init(Double(source.x),Double(source.y),Double(source.z)),saturation:0,vibrance:0,cast:0.5)
    for c in 0..<3 { XCTAssertEqual(Double(cast[c]),expectedCast[c],accuracy:3e-5) }
    p = .init(); p.blackAndWhite = .init(enabled:true,intensity:0.5)
    let bw = materialize(try DevelopmentColorEngineV3.applyPointwise(p,to:image([source])))
    let e = SIMD3(DevelopmentColorEngineV2.encode(Double(source.x)),DevelopmentColorEngineV2.encode(Double(source.y)),DevelopmentColorEngineV2.encode(Double(source.z)))
    let expectedGray = DevelopmentColorEngineV2.decode(DevelopmentColorEngineV2.luma(e)+0.5*(0.09*(e.y-e.x)+0.392*(e.y-e.z)))
    for c in 0..<3 { XCTAssertEqual(Double(bw[c]),expectedGray,accuracy:3e-5) }
  }
  func testHighlightShoulderStaysNonnegativeAndShadowResponseIsUnchanged() {
    for b in 0...20 { for x in 0...20 {
      let base = Double(b)/20, pixel = Double(x)/20
      let logBase = log2(max(pow(2,-20),DevelopmentColorEngineV2.decode(base)))
      let high = DevelopmentSpatialEngineV3.referenceGainEV(encodedLuminance:pixel,localLogLuminance:logBase,
        logLuminance:logBase,brilliance:0,shadows:0,highlights:-1)
      XCTAssertLessThanOrEqual(high,1e-12)
      let actualBase = DevelopmentColorEngineV2.encode(pow(2,logBase))
      let expected = 0.75*(1-DevelopmentColorEngineV2.smooth(0.15,0.65,actualBase))*(1-DevelopmentColorEngineV2.smooth(0.1,0.7,pixel))
      let shadow = DevelopmentSpatialEngineV3.referenceGainEV(encodedLuminance:pixel,localLogLuminance:logBase,
        logLuminance:logBase,brilliance:0,shadows:0.5,highlights:0)
      XCTAssertEqual(shadow,expected,accuracy:1e-12)
    } }
    let a = DevelopmentSpatialEngineV3.referenceGainEV(encodedLuminance:0.5,localLogLuminance:-5,logLuminance:-2,brilliance:0.5,shadows:0,highlights:0)
    let b = DevelopmentSpatialEngineV3.referenceGainEV(encodedLuminance:0.5,localLogLuminance:-1,logLuminance:-2,brilliance:0.5,shadows:0,highlights:0)
    XCTAssertGreaterThan(abs(a-b),0.1,"Brilliance still depends on the actual neighborhood")
  }
  func testSpatialMetalMatchesUniformNeighborhoodReference() throws {
    let source = SIMD4<Float>(0.18,0.1,0.04,1), pixels = Array(repeating:source,count:32*32)
    let y = DevelopmentColorEngineV2.luma(.init(Double(source.x),Double(source.y),Double(source.z)))
    for (brilliance,shadows,highlights) in [(0.5,0.0,0.0),(0.0,0.5,0.0),(0.0,0.0,-0.5)] {
      let p = DevelopmentLightV3(enabled:true,brilliance:brilliance,highlights:highlights,shadows:shadows)
      let output = try DevelopmentSpatialEngineV3.applyLight(p,to:image(pixels,width:32,height:32))
      try DevelopmentColorEngineV3.validateFinite(output)
      let actual = materialize(output,bounds:.init(x:16,y:16,width:1,height:1))
      let ev = DevelopmentSpatialEngineV3.referenceGainEV(encodedLuminance:DevelopmentColorEngineV2.encode(y),localLogLuminance:log2(y),
        logLuminance:log2(y),brilliance:brilliance,shadows:shadows,highlights:highlights)
      for c in 0..<3 { XCTAssertEqual(Double(actual[c]),Double(source[c])*pow(2,ev),accuracy:3e-5) }
    }
  }
  func testLightSummaryRemainsSourceDependentBoundedAndNeutralAtZero() throws {
    func stats(_ values: [Float]) throws -> DevelopmentAnalysisScalars {
      try DevelopmentAnalysisEngine.statistics(values.flatMap { [$0,$0,$0,1] },width:values.count,height:1)
    }
    let dark = try stats([0.001,0.01,0.05,0.2]), bright = try stats([0.2,0.4,0.7,0.95])
    var results: [DevelopmentLightV3] = []
    for s in [dark,bright] {
      for amount in [-1.0,0,0.5,1] {
        guard case .light(let p) = try DevelopmentAnalysisEngine.resolvedSummary(.light,amount:amount,scalars:s) else { return XCTFail() }
        try p.validate()
        if amount == 0 { XCTAssertEqual([p.brilliance,p.exposure,p.highlights,p.shadows,p.brightness,p.contrast,p.blackPoint],Array(repeating:0,count:7)) }
        if amount == 0.5 { results.append(p) }
      }
    }
    XCTAssertEqual(results.count,2); XCTAssertNotEqual(results[0],results[1])
    XCTAssertNotEqual(results[0].shadows,results[1].shadows)
    XCTAssertNotEqual(results[0].exposure,results[1].exposure)
  }
}
