import XCTest
import AppKit
import CoreImage
import ImageIO
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentBWSummaryResidentV3Tests: XCTestCase {
  private final class Events: @unchecked Sendable {
    let lock = NSLock()
    private var values: [DevelopmentBWSummaryResidentV3.Observation] = []
    func append(_ value: DevelopmentBWSummaryResidentV3.Observation) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshot: [DevelopmentBWSummaryResidentV3.Observation] { lock.lock(); defer { lock.unlock() }; return values }
  }
  private func request(recipe: DevelopmentRecipe? = nil, sampling: DevelopmentAnalysisSampling = .blackAndWhiteSummaryResident32V3,
                       role: PreviewConsumerRole = .primary, operation: DevelopmentAnalysisOperation = .summary(.blackAndWhite,amount:0.5),
                       stage: DevelopmentAnalysisStage = .workingImageBeforeGeometry, roi: NormalizedCrop = .init()) throws -> DevelopmentAnalysisRequest {
    let recipe = try recipe ?? DevelopmentRecipe().promotingToV3()
    let preview = DevelopmentPreviewRequest(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:role,
      revision:1,recipe:recipe,quality:.interactive)
    return .init(preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),stage:stage,roi:roi,
      operation:operation,sampling:sampling)
  }
  private func context() -> CIContext {
    CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,
      .cacheIntermediates:false,.memoryTarget:512])
  }
  /// The small fixture is deliberately TIFF. These tests prove resident ownership and the
  /// shared math only; the separate fixed-B public Service run must qualify real RAW.
  private func fixture() throws -> (URL, PreviewNativeSource, PreviewNativePointwiseBaseDescriptorV1) {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-BWResident-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file = root.appendingPathComponent("owner.tiff"), width = 1025, height = 2
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32))
    for i in 0..<(width*height) {
      bitmap.bitmapData![i*4]=UInt8(i%191);bitmap.bitmapData![i*4+1]=UInt8((i*7)%223)
      bitmap.bitmapData![i*4+2]=80;bitmap.bitmapData![i*4+3]=255
    }
    let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(writer,try XCTUnwrap(bitmap.cgImage),nil)
    XCTAssertTrue(CGImageDestinationFinalize(writer))
    let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber).int64Value
    let native = try PreviewNativeSource(capture:file,byteCount:bytes,artifact:false,memoryLimit:512)
    let descriptor = try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:"bw-test",generation:1,
      verifiedContentID:RenderFiles.hash(file))
    return (root,native,descriptor)
  }
  private func fill(_ pool: PreviewRawBasePool, _ descriptor: PreviewNativePointwiseBaseDescriptorV1,
                    alpha: Float = 1) throws -> UUID {
    let context = context();defer { context.clearCaches() }
    let count = descriptor.width*descriptor.height
    var values = (0..<count).map { SIMD4<Float>(Float($0%71)/80,Float($0%37)/40,0.2,1) }
    values[0] = .init(0,0,0,alpha)
    let graph = CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:descriptor.width*16,
      size:.init(width:descriptor.width,height:descriptor.height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let pin = try pool.acquirePointwise(descriptor) { storage in
      try storage.fill(graph,context:context,pointwiseAuthority:descriptor.fingerprint())
    }
    defer { pin.releaseAfterJoinedPipeline() }
    return try XCTUnwrap(pin.ownerIncarnation)
  }
  func testAdmissionAndVersionKeepOldAlgorithmsIsolated() throws {
    let valid = try request()
    XCTAssertNoThrow(try DevelopmentBWSummaryResidentV3.requireRequest(valid,sourceIsRAW:true))
    XCTAssertTrue(try valid.matchesSamplingVersion(DevelopmentBWSummaryResidentV3.version))
    XCTAssertFalse(try valid.matchesSamplingVersion(DevelopmentAnalysisEngine.blackAndWhiteStripesVersion))
    XCTAssertFalse(try request(sampling:.blackAndWhiteSummaryStripes32V2).matchesSamplingVersion(DevelopmentBWSummaryResidentV3.version))
    XCTAssertFalse(try request(sampling:.legacy).matchesSamplingVersion(DevelopmentBWSummaryResidentV3.version))
    XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.requireRequest(valid,sourceIsRAW:false))
    XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.requireRequest(valid,sourceIsRAW:true,artifact:true))
    var changed = try DevelopmentRecipe().promotingToV3()
    changed.adjustmentsV3!.color.enabled=true;changed.adjustmentsV3!.color.saturation=0.2
    for invalid in [try request(recipe:changed),try request(role:.comparison),
      try request(operation:.summary(.color,amount:0.5)),try request(operation:.summary(.blackAndWhite,amount:.nan)),
      try request(stage:.orientedSourceBeforeGeometry),try request(roi:.init(x:0.1,y:0,width:0.9,height:1)),
      try request(recipe:DevelopmentRecipe().promotingToV2().promotingToV3())] {
      XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.requireRequest(invalid,sourceIsRAW:true))
    }
    // A zero-effect newly-created V3 graph does not inherit legacy-v1 permission.
    var fresh = try DevelopmentRecipe().promotingToV3();fresh.adjustmentsV3 = .init()
    XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.requireRequest(request(recipe:fresh),sourceIsRAW:true))
  }
  func testServiceDefaultOffRejectsBeforeAnyQueueOrWorker() async throws {
    let service = DevelopmentPreviewService(policy:.default)
    do { _ = try await service.analyze(request());XCTFail("Default product-like test initialization must reject V3") }
    catch { guard case DevelopmentV3Error.unsupportedAnalysis = error else { return XCTFail("Unexpected error: \(error)") } }
    let stats = await service.analysisStatistics()
    XCTAssertEqual(stats.submitted,0);XCTAssertEqual(stats.active,0);XCTAssertEqual(stats.completed,0)
    XCTAssertEqual(stats.pendingUser,0);XCTAssertEqual(stats.pendingHistogram,0)
  }
  func testActualResidentPinPreservesOwnerAndOriginalFiniteAndProxyMath() throws {
    let (root,native,d) = try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let pool = PreviewRawBasePool(byteBudget:1_048_576),events = Events()
    try pool.withWorker {
      let owner = try fill(pool,d), before = pool.statistics
      var escaped: DevelopmentBWSummaryResidentV3.Input?
      var checkpoints = 0
      try DevelopmentBWSummaryResidentV3.withVerifiedResident(descriptor:d,pool:pool,check:native.validateCaptureAuthority,
        observer:{events.append($0)}) { input in
        escaped=input
        XCTAssertEqual(input.identity.owner,owner)
        XCTAssertGreaterThan(pool.statistics.pinnedBytes,0)
        try DevelopmentRendererV3.withOwnedAnalysisLegacyValidationContext { context in
          try DevelopmentColorEngineV3.validateFinite(input.image(),context:context,checkCancellation:{checkpoints += 1;try input.requireCurrent()})
        }
        XCTAssertEqual(checkpoints,4,"Two native 1024-wide finite tiles must actually complete")
        let context = context();defer { context.clearCaches() }
        let proxy = try input.image().transformed(by:.init(scaleX:128.0/1025,y:0.5))
        var stripes = [Float](repeating:.nan,count:128*4),whole = stripes
        context.render(proxy,toBitmap:&whole,rowBytes:128*16,bounds:.init(x:0,y:0,width:128,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
        try DevelopmentAnalysisEngine.renderBlackAndWhiteProxyStripes(proxy,width:128,height:1,context:context,pixels:&stripes,check:input.requireCurrent)
        XCTAssertEqual(stripes.map(\.bitPattern),whole.map(\.bitPattern))
        let statistics = try DevelopmentAnalysisEngine.statistics(stripes,width:128,height:1)
        XCTAssertEqual(statistics.histogram.visibleSamples,128)
        try input.willPublish(cacheHit:false)
      }
      XCTAssertThrowsError(try escaped?.image(),"Retaining the capability cannot retain a live pin or image")
      let after = pool.statistics
      XCTAssertEqual(after.fills,before.fills);XCTAssertEqual(after.evictions,before.evictions)
      XCTAssertEqual(after.hits,before.hits+1);XCTAssertEqual(after.pinnedBytes,0)
      XCTAssertEqual(after.residentBytes,before.residentBytes)
      XCTAssertEqual(events.snapshot.map(\.phase),[.acquired,.willPublish,.released])
      XCTAssertEqual(events.snapshot.last?.current.pinnedBytes,0)
      XCTAssertEqual(try pool.drain().residentBytes,0)
    }
  }
  func testMissingRetiredAndRealPartialAlphaRejectWithoutRefill() throws {
    let (root,native,d) = try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let pool = PreviewRawBasePool(byteBudget:1_048_576)
    try pool.withWorker {
      func rejected() {
        XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.withVerifiedResident(descriptor:d,pool:pool,check:native.validateCaptureAuthority) { _ in XCTFail("Unsupported owner entered pipeline") })
        XCTAssertEqual(pool.statistics.pinnedBytes,0)
      }
      rejected();XCTAssertEqual(pool.statistics.fills,0)
      _ = try fill(pool,d,alpha:0.5)
      rejected();XCTAssertEqual(pool.statistics.fills,1)
      pool.retire(sourceKey:d.sourceKey)
      rejected();XCTAssertEqual(pool.statistics.fills,1)
      XCTAssertEqual(try pool.drain().residentBytes,0)
    }
  }
  func testActualOwnerReplacementAndGenerationCannotReplayV3OrV2Cache() throws {
    let (root,native,d) = try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let pool = PreviewRawBasePool(byteBudget:1_048_576)
    try pool.withWorker {
      let owner = try fill(pool,d)
      var identity: DevelopmentBWSummaryResidentV3.Identity?
      try DevelopmentBWSummaryResidentV3.withVerifiedResident(descriptor:d,pool:pool,check:native.validateCaptureAuthority) { identity=$0.identity }
      let actual = try XCTUnwrap(identity),r = try request(),fp = try EditingFingerprint.of(DevelopmentAnalysisEngine.samplingRecipe(r))
      let entry = DevelopmentAnalysisCacheEntry(recipeFingerprint:fp,stage:r.stage,roi:r.roi,
        scalars:try DevelopmentAnalysisEngine.statistics([0,0,0,1],width:1,height:1),filterResourceIdentity:nil,
        samplingVersion:DevelopmentBWSummaryResidentV3.version,residentIdentity:actual)
      XCTAssertTrue(entry.matches(recipeFingerprint:fp,stage:r.stage,roi:r.roi,filterResourceIdentity:nil,
        samplingVersion:DevelopmentBWSummaryResidentV3.version,residentIdentity:actual))
      XCTAssertFalse(entry.matches(recipeFingerprint:fp,stage:r.stage,roi:r.roi,filterResourceIdentity:nil,
        samplingVersion:DevelopmentAnalysisEngine.blackAndWhiteStripesVersion))
      let old = DevelopmentAnalysisCacheEntry(recipeFingerprint:fp,stage:r.stage,roi:r.roi,scalars:entry.scalars,
        filterResourceIdentity:nil,samplingVersion:DevelopmentAnalysisEngine.blackAndWhiteStripesVersion)
      XCTAssertFalse(old.matches(recipeFingerprint:fp,stage:r.stage,roi:r.roi,filterResourceIdentity:nil,
        samplingVersion:DevelopmentBWSummaryResidentV3.version,residentIdentity:actual))
      let next = try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:d.sourceKey,generation:2,verifiedContentID:d.verifiedContentID)
      XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.withVerifiedResident(descriptor:next,pool:pool,check:native.validateCaptureAuthority) {_ in XCTFail("Missing next generation")})
      pool.retire(sourceKey:d.sourceKey)
      let replacement = try fill(pool,d);XCTAssertNotEqual(replacement,owner)
      try DevelopmentBWSummaryResidentV3.withVerifiedResident(descriptor:d,pool:pool,check:native.validateCaptureAuthority) { input in
        XCTAssertFalse(entry.matches(recipeFingerprint:fp,stage:r.stage,roi:r.roi,filterResourceIdentity:nil,
          samplingVersion:DevelopmentBWSummaryResidentV3.version,residentIdentity:input.identity))
      }
      XCTAssertEqual(pool.statistics.fills,2);XCTAssertEqual(pool.statistics.pinnedBytes,0)
      XCTAssertEqual(try pool.drain().residentBytes,0)
    }
  }
  func testCancellationAndAuthorityFailureAfterActualFirstTileReleasePin() throws {
    for cancel in [true,false] {
      let (root,native,d) = try fixture();defer { try? FileManager.default.removeItem(at:root) }
      let pool = PreviewRawBasePool(byteBudget:1_048_576),cancellation = DevelopmentAnalysisCancellation()
      try pool.withWorker {
        _ = try fill(pool,d)
        var authority = true,checks = 0
        weak var contextWitness: CIContext?
        XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.withVerifiedResident(descriptor:d,pool:pool,check:{
          try native.validateCaptureAuthority();try cancellation.check()
          guard authority else { throw DevelopmentPreviewError.sourceInvalidated }
        }) { input in
          try DevelopmentRendererV3.withOwnedAnalysisLegacyValidationContext { context in
            contextWitness=context
            try DevelopmentColorEngineV3.validateFinite(input.image(),context:context,checkCancellation:{
              checks += 1
              if checks == 2 { if cancel { cancellation.cancel() } else { authority=false } }
              try input.requireCurrent()
            })
          }
          XCTFail("First actual tile revocation must stop before proxy/result/cache")
        })
        XCTAssertEqual(checks,2);XCTAssertNil(contextWitness)
        XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(pool.statistics.pinnedBytes,0)
        XCTAssertEqual(try pool.drain().residentBytes,0)
      }
    }
  }
  func testThrowingScalarObserverStillReportsActualReleasedPin() throws {
    let (root,native,d) = try fixture();defer { try? FileManager.default.removeItem(at:root) }
    let pool = PreviewRawBasePool(byteBudget:1_048_576),events = Events()
    try pool.withWorker {
      _ = try fill(pool,d)
      XCTAssertThrowsError(try DevelopmentBWSummaryResidentV3.withVerifiedResident(descriptor:d,pool:pool,
        check:native.validateCaptureAuthority,observer:{ event in
          events.append(event);if event.phase == .willPublish { throw CancellationError() }
        }) { input in try input.willPublish(cacheHit:false);XCTFail("Observer failure must propagate") }) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertEqual(events.snapshot.map(\.phase),[.acquired,.willPublish,.released])
      XCTAssertEqual(events.snapshot.last?.current.pinnedBytes,0)
      XCTAssertEqual(pool.statistics.fills,1);XCTAssertEqual(try pool.drain().residentBytes,0)
    }
  }
}
