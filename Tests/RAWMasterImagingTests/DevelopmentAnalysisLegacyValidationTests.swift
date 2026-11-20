import Foundation
import XCTest
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentAnalysisLegacyValidationTests: XCTestCase {
  private func image(invalid: Bool = false) -> CIImage {
    let width = 1025, height = 2
    var pixels = Array(repeating: SIMD4<Float>(2, -0.25, 4, 1), count: width * height)
    pixels[0] = .init(0, 0, 0, 0)
    pixels[1] = .init(0.1, 0.2, 0.3, 0.5)
    // Same actual NaN/alpha-zero fixture contract as DevelopmentCheckedMaximumV3Tests.
    if invalid { pixels[pixels.count - 1] = .init(.nan, 0, 0, 0) }
    return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
      size: .init(width: width, height: height), format: .RGBAf, colorSpace: DevelopmentColorEngineV3.linearSRGB)
  }

  func testOwnedLegacyValidationRetiresAfterActualFiniteAndJoinedCancellation() throws {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let graph = image()
    weak var owner: CIContext?
    try DevelopmentRendererV3.withOwnedAnalysisLegacyValidationContext { context in
      owner = context
      try DevelopmentColorEngineV3.validateFinite(graph, context: context)
      XCTAssertNotNil(owner)
    }
    XCTAssertNil(owner, "Validation context must retire before source metadata and proxy work")

    var checks = 0
    XCTAssertThrowsError(try DevelopmentRendererV3.withOwnedAnalysisLegacyValidationContext { context in
      owner = context
      try DevelopmentColorEngineV3.validateFinite(graph, context: context, checkCancellation: {
        checks += 1
        if checks == 2 { throw CancellationError() }
      })
    }) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(checks, 2, "Cancellation follows the first actual joined tile and prevents another tile")
    XCTAssertNil(owner, "Cancellation must not keep the validation owner alive")
  }

  func testOwnedLegacyValidationPreservesActualNonfiniteRejectionAndRetiresOnError() throws {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let graph = image(invalid: true)
    XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(graph, context: PhotoRenderer.context)) { error in
      guard case DevelopmentError.invalidEncoding = error else { return XCTFail("Expected original finite rejection: \(error)") }
    }
    weak var owner: CIContext?
    XCTAssertThrowsError(try DevelopmentRendererV3.withOwnedAnalysisLegacyValidationContext { context in
      owner = context
      try DevelopmentColorEngineV3.validateFinite(graph, context: context)
    }) { error in
      guard case DevelopmentError.invalidEncoding = error else { return XCTFail("Expected unchanged finite rejection: \(error)") }
    }
    XCTAssertNil(owner, "Finite-check failure must release the owned context")
  }

  func testOwnedLegacyValidationAdmissionRequiresBWRequestAndRAWLegacyV1Analysis() throws {
    for amount in [-1.0, 0, 0.5, 1] {
      XCTAssertTrue(DevelopmentAnalysisEngine.requestsOwnedLegacyValidationContext(.summary(.blackAndWhite, amount: amount)))
      XCTAssertFalse(DevelopmentAnalysisEngine.requestsRAWNoiseDefaults(.summary(.blackAndWhite, amount: amount)))
    }
    let otherOperations: [DevelopmentAnalysisOperation] = [
      .histogram, .displayHistogram, .automatic(nil), .automatic(.blackAndWhite), .automatic(.noiseReduction),
      .summary(.light, amount: 0.5), .summary(.color, amount: 0.5)
    ]
    for operation in otherOperations {
      XCTAssertFalse(DevelopmentAnalysisEngine.requestsOwnedLegacyValidationContext(operation))
      XCTAssertTrue(DevelopmentAnalysisEngine.requestsRAWNoiseDefaults(operation))
    }

    let recipe = try DevelopmentRecipe().promotingToV3()
    let parameters = try XCTUnwrap(recipe.adjustmentsV3)
    let legacy = try DevelopmentRendererV3.legacyRecipe(parameters)
    func admitted(_ p: DevelopmentAdjustmentsV3, _ old: DevelopmentRecipe,
                  requested: Bool = true, raw: Bool = true, geometry: Bool = false) -> Bool {
      DevelopmentRendererV3.ownsAnalysisLegacyValidationContext(requested: requested, sourceIsRAW: raw,
        applyGeometry: geometry, parameters: p, legacy: old)
    }
    XCTAssertTrue(admitted(parameters, legacy))
    XCTAssertFalse(admitted(parameters, legacy, requested: false), "Default exporter selection is unchanged")
    XCTAssertFalse(admitted(parameters, legacy, raw: false))
    XCTAssertFalse(admitted(parameters, legacy, geometry: true))
    let v2 = try DevelopmentRecipe().promotingToV2().promotingToV3()
    XCTAssertFalse(admitted(try XCTUnwrap(v2.adjustmentsV3), legacy))
    XCTAssertFalse(admitted(DevelopmentAdjustmentsV3(), legacy))
    XCTAssertFalse(admitted(parameters, try legacy.promotingToV2()))
    var active = parameters
    active.color.enabled = true
    active.color.saturation = 0.2
    XCTAssertFalse(admitted(active, legacy))
  }

  func testBWSummaryV2AdmissionAndScalarCacheVersionIsolation() throws {
    let recipe = try DevelopmentRecipe().promotingToV3()
    let fp = try EditingFingerprint.of(recipe)
    let preview = DevelopmentPreviewRequest(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,
      revision:1,recipe:recipe,quality:.settled)
    let summary = DevelopmentAnalysisOperation.summary(.blackAndWhite,amount:0.5)
    func request(_ operation: DevelopmentAnalysisOperation, stage: DevelopmentAnalysisStage = .workingImageBeforeGeometry,
                 roi: NormalizedCrop = .init()) -> DevelopmentAnalysisRequest {
      .init(preview:preview,expectedRecipeFingerprint:fp,stage:stage,roi:roi,operation:operation,sampling:.blackAndWhiteSummaryStripes32V2)
    }
    let legacy = DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:fp,stage:.workingImageBeforeGeometry,operation:summary)
    let v2 = request(summary)
    XCTAssertEqual(legacy.sampling,.legacy)
    XCTAssertNoThrow(try v2.validate())
    let legacyVersion = DevelopmentAnalysisEngine.samplingVersion
    let version = DevelopmentAnalysisEngine.blackAndWhiteStripesVersion
    XCTAssertTrue(try legacy.matchesSamplingVersion(legacyVersion))
    XCTAssertTrue(try v2.matchesSamplingVersion(version))
    XCTAssertFalse(try legacy.matchesSamplingVersion(version))
    XCTAssertFalse(try v2.matchesSamplingVersion(legacyVersion))
    for invalid in [request(.automatic(.blackAndWhite)),request(.summary(.light,amount:0.5)),
                    request(summary,stage:.orientedSourceBeforeGeometry),
                    request(summary,roi:.init(x:0.25,y:0,width:0.75,height:1))] {
      XCTAssertThrowsError(try invalid.validate())
      XCTAssertThrowsError(try invalid.matchesSamplingVersion(version))
    }
    let sampling = try DevelopmentAnalysisEngine.samplingRecipe(v2)
    XCTAssertEqual(sampling,try DevelopmentAnalysisEngine.samplingRecipe(legacy))
    let samplingFP = try EditingFingerprint.of(sampling)
    let scalars = try DevelopmentAnalysisEngine.statistics([0,0,0,1],width:1,height:1)
    var cache: DevelopmentAnalysisCacheEntry? = .init(recipeFingerprint:samplingFP,stage:v2.stage,roi:v2.roi,
      scalars:scalars,filterResourceIdentity:nil,samplingVersion:version)
    let entry = try XCTUnwrap(cache)
    XCTAssertTrue(entry.matches(recipeFingerprint:samplingFP,stage:v2.stage,roi:v2.roi,filterResourceIdentity:nil,samplingVersion:version))
    XCTAssertFalse(entry.matches(recipeFingerprint:samplingFP,stage:v2.stage,roi:v2.roi,filterResourceIdentity:nil,
      samplingVersion:legacyVersion))
    let source = DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),
      exifOrientation:1,orientedWidth:1,orientedHeight:1)
    let unused = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
    XCTAssertThrowsError(try DevelopmentAnalysisEngine.run(capture:unused,request:v2,sourceBinding:source,memoryHint:512,cache:&cache)) {
      if case DevelopmentPreviewError.invalidRequest = $0 {} else { XCTFail("Expected non-RAW admission rejection: \($0)") }
    }
    XCTAssertEqual(cache?.samplingVersion,version)
    let revoked = DevelopmentAnalysisCancellation()
    revoked.cancel(cause:.frameSuperseded)
    XCTAssertThrowsError(try revoked.withInputPublication(allowFrameSuperseded:false) { XCTFail("Cancelled analysis cannot publish") })
  }

  func testActualBWSummaryV2ProxyWritesGlobalTopRowsAndTailBeforeCancellation() throws {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let width = 21, height = 67
    var source = [Float]()
    for y in 0..<height {
      for x in 0..<width {
        source += x == 0 ? [0,0,0,0]:[Float(y)/128,Float(x)/32,0.125,1]
      }
    }
    let proxy = CIImage(bitmapData:source.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer { context.clearCaches() }
    var whole = [Float](repeating:.nan,count:source.count)
    context.render(proxy,toBitmap:&whole,rowBytes:width*16,bounds:proxy.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    XCTAssertTrue(whole.allSatisfy(\.isFinite))
    XCTAssertNotEqual(whole[4],whole[(height-1)*width*4+4],"fixture must distinguish physical top and bottom")
    var strips = [Float](repeating:.nan,count:source.count), checks = 0
    try DevelopmentAnalysisEngine.renderBlackAndWhiteProxyStripes(proxy,width:width,height:height,context:context,pixels:&strips) { checks += 1 }
    XCTAssertEqual(checks,6,"two joined checkpoints for each of 32, 32, and 3 rows")
    XCTAssertEqual(strips.map(\.bitPattern),whole.map(\.bitPattern))
    strips = [Float](repeating:.nan,count:source.count)
    checks = 0
    XCTAssertThrowsError(try DevelopmentAnalysisEngine.renderBlackAndWhiteProxyStripes(proxy,width:width,height:height,context:context,pixels:&strips) {
      checks += 1
      if checks == 2 { throw CancellationError() }
    }) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(checks,2)
    let untouched = (height-32)*width*4
    XCTAssertTrue(strips.prefix(untouched).allSatisfy(\.isNaN))
    XCTAssertEqual(strips.suffix(from:untouched).map(\.bitPattern),whole.suffix(from:untouched).map(\.bitPattern))
  }
}
