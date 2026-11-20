import XCTest
import CoreImage
import AppKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentV3NeutralTests: XCTestCase {
  private func fixture() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-v3-neutral-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:20,pixelsHigh:12,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:80,bitsPerPixel:32)!
    for y in 0..<12 { for x in 0..<20 {
      let i = y*80+x*4
      let a: UInt8 = x%3 == 0 ? 0:(x%3 == 1 ? 128:255)
      bitmap.bitmapData![i] = UInt8(x*5*Int(a)/255)
      bitmap.bitmapData![i+1] = UInt8(y*7*Int(a)/255)
      bitmap.bitmapData![i+2] = a/4; bitmap.bitmapData![i+3] = a
    } }
    let url = root.appendingPathComponent("source.png")
    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url)
    return (root,url)
  }
  private func materialize(_ image: CIImage, context: CIContext) -> [Float] {
    var pixels = [Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
    context.render(image,toBitmap:&pixels,rowBytes:Int(image.extent.width)*16,bounds:image.extent,
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  func testOnlyFreshAdjustNeutralChoosesOwnF32Context() throws {
    let fresh = DevelopmentRecipe(adjustmentsV3:.init())
    XCTAssertEqual(fresh.adjustmentsV3!.geometry.version,.adjustV3)
    XCTAssertNil(try DevelopmentRendererV3.legacyEquivalent(fresh))
    XCTAssertTrue(PhotoRenderer.renderingContext(fresh) === DevelopmentColorEngineV3.context)
    for old in [DevelopmentRecipe(),try DevelopmentRecipe().promotingToV2()] {
      let promoted = try old.promotingToV3()
      XCTAssertNil(promoted.adjustmentsV3!.legacyBasis)
      XCTAssertNotEqual(promoted.adjustmentsV3!.geometry.version,.adjustV3)
      XCTAssertNotNil(try DevelopmentRendererV3.legacyEquivalent(promoted))
      XCTAssertTrue(PhotoRenderer.renderingContext(promoted) === PhotoRenderer.renderingContext(old))
    }
  }
  func testPromotedOldV1V2ActualPixelsAndContextsRemainExact() throws {
    let (root,url) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let v1 = DevelopmentRecipe(exposureEV:0.3,whiteBalance:.temperatureTint(temperature:5200,tint:7),
      straightenDegrees:2,crop:.init(x:0.1,y:0.1,width:0.8,height:0.8))
    var v2 = try v1.promotingToV2()
    v2.color!.tones = .init(contrast:15,highlights:-20,shadows:10,whites:7,blacks:-8,vibrance:9,saturation:4)
    v2.color!.grading.shadows = .init(hueDegrees:220,saturation:13,luminance:2)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for old in [DevelopmentRecipe(),try DevelopmentRecipe().promotingToV2(),v1,v2] {
      let before = try encoder.encode(old), promoted = try old.promotingToV3()
      let legacyGraph = try PhotoRenderer.develop(url,old)
      let graph = try DevelopmentRendererV3.develop(url,recipe:promoted)
      XCTAssertTrue(graph.graphDescriptor.hasSuffix("/exact-legacy"))
      XCTAssertEqual(graph.canonicalSize,legacyGraph.0.extent.size)
      let expected = materialize(legacyGraph.0,context:PhotoRenderer.renderingContext(old))
      let actual = materialize(graph.image,context:PhotoRenderer.renderingContext(promoted))
      XCTAssertEqual(actual.map(\.bitPattern),expected.map(\.bitPattern))
      XCTAssertEqual(try encoder.encode(old),before)
    }
  }
  func testFreshNeutralActuallyDevelopsThroughOwnGraph() throws {
    let (root,url) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let fresh = DevelopmentRecipe(adjustmentsV3:.init())
    let graph = try DevelopmentRendererV3.develop(url,recipe:fresh)
    XCTAssertFalse(graph.graphDescriptor.hasSuffix("/exact-legacy"))
    XCTAssertTrue(graph.graphDescriptor.hasPrefix("rawmaster-v3.2/fresh-adjust-neutral-F32/"))
    XCTAssertEqual(graph.sourceSize,CGSize(width:20,height:12)); XCTAssertEqual(graph.canonicalSize,graph.sourceSize)
    let pixels = materialize(graph.image,context:PhotoRenderer.renderingContext(fresh))
    XCTAssertTrue(pixels.allSatisfy(\.isFinite))
    XCTAssertTrue(stride(from:3,to:pixels.count,by:4).contains { pixels[$0] > 0 && pixels[$0] < 1 })
    XCTAssertTrue(stride(from:3,to:pixels.count,by:4).contains { pixels[$0] == 0 })
  }
  func testNeutralF32KeepsAlphaExtendedValuesAndPrecision() throws {
    let samples: [SIMD4<Float>] = [
      .init(1.2345679,0.12345679,4.2345676,1), .init(-0.12345679,0.25,2.3456788,1),
      .init(0.12345679,0.012345679,0.5,0.5), .init(0,0,0,0),
      .init(0.000012345679,0.0000023456789,0.0000012345679,1.0/65535)
    ]
    let data = samples.withUnsafeBytes { Data($0) }
    let image = CIImage(bitmapData:data,bytesPerRow:samples.count*16,size:.init(width:samples.count,height:1),
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let p = DevelopmentAdjustmentsV3()
    let processed = try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:
      DevelopmentColorEngineV3.applyPointwise(p,to:DevelopmentSpatialEngineV3.applyLight(p.light,to:image)))
    try DevelopmentColorEngineV3.validateFinite(processed)
    let pixels = materialize(processed,context:DevelopmentColorEngineV3.context)
    for (i,pixel) in samples.enumerated() { for c in 0..<4 {
      XCTAssertEqual(pixels[i*4+c],pixel[c],accuracy:max(1e-8,abs(pixel[c])*1e-7))
    } }
    XCTAssertGreaterThan(pixels[2],4); XCTAssertLessThan(pixels[4],0)
  }
  func testFiniteGateRejectsTransparentNaNAndExtendedInfinity() throws {
    let invalid: [SIMD4<Float>] = [.init(.nan,0,0,0),.init(0,.infinity,0,1)]
    for pixel in invalid {
      let data = withUnsafeBytes(of:pixel) { Data($0) }
      let image = CIImage(bitmapData:data,bytesPerRow:16,size:.init(width:1,height:1),format:.RGBAf,
        colorSpace:DevelopmentColorEngineV3.linearSRGB)
      XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(image))
    }
  }
}
