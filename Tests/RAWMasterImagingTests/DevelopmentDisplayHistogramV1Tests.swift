import XCTest
import AppKit
import CoreImage
import ImageIO
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentDisplayHistogramV1Tests:XCTestCase {
  private func image(_ width:Int,_ height:Int)->CIImage {
    var data=[Float](repeating:0,count:width*height*4)
    for y in 0..<height {for x in 0..<width {
      let a:Float=(x+3*y)%17==0 ? 0:((3*x+y)%13==0 ? 0.25:1),n=(y*width+x)*4
      data[n]=Float((x*7+y*3)%97)/64*a;data[n+1]=Float((x*5+y*11)%89)/73*a
      data[n+2]=(x==0 || y==height-1 ? 1.25:Float((x*19+y)%67)/79)*a;data[n+3]=a
    }}
    return CIImage(bitmapData:data.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func context()->CIContext {CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])}
  private func exactFixture(_ image:CIImage,roi:NormalizedCrop = .init())throws {
    let e=image.extent,rect=CGRect(x:e.minX+e.width*roi.x,y:e.minY+e.height*(1-roi.y-roi.height),width:e.width*roi.width,height:e.height*roi.height)
    let factor=min(1,Double(128)/max(rect.width,rect.height))
    let width=max(1,Int(floor(rect.width*factor))),height=max(1,Int(floor(rect.height*factor)))
    let proxy=image.cropped(to:rect).transformed(by:.init(translationX:-rect.minX,y:-rect.minY)).transformed(by:.init(scaleX:Double(width)/rect.width,y:Double(height)/rect.height))
    let original=autoreleasepool {()->[Float] in
      let c=context();defer{c.clearCaches()};var p=[Float](repeating:0,count:width*height*4)
      c.render(proxy,toBitmap:&p,rowBytes:width*16,bounds:.init(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB);return p
    }
    let actual=try autoreleasepool {try DevelopmentDisplayHistogramEngineV1.renderProxy(image,roi:roi,context:context())}
    XCTAssertEqual(actual.width,width);XCTAssertEqual(actual.height,height)
    XCTAssertEqual(actual.rgba.map(\.bitPattern),original.map(\.bitPattern))
    let reference=try DevelopmentAnalysisEngine.statistics(original,width:width,height:height).histogram
    let histogram=try DevelopmentDisplayHistogramEngineV1.histogram(actual)
    XCTAssertEqual(histogram.luminance,reference.luminance);XCTAssertEqual(histogram.visibleSamples,reference.visibleSamples)
    XCTAssertEqual(histogram.transparentSamples,reference.transparentSamples);XCTAssertEqual(histogram.sampledSize,reference.sampledSize)
  }
  func testIdentityAlphaAndRemaindersPreserveFixtureBits()throws {try exactFixture(image(37,53))}
  func testDownscaleAsymmetricEdgesPreserveFixtureBits()throws {try exactFixture(image(385,257))}
  func testLeftOrientationPreservesFixtureBits()throws {try exactFixture(image(385,257).oriented(.left))}
  func testFractionalROIAndNonzeroOriginPreserveFixtureBits()throws {try exactFixture(image(385,257).transformed(by:.init(translationX:3.25,y:-7.5)),roi:.init(x:0.13,y:0.07,width:0.73,height:0.83))}
  func testSingleRowRemainderPreservesFixtureBits()throws {try exactFixture(image(17,1))}
  func testDisplayDTORejectsInvalidPopulationAndNonfinitePixels()throws {
    XCTAssertThrowsError(try DevelopmentDisplayHistogramV1(luminance:[0],visibleSamples:1,transparentSamples:0,sampledSize:.init(width:1,height:1)).validate())
    XCTAssertThrowsError(try DevelopmentDisplayHistogramV1(luminance:Array(repeating:UInt64.max,count:256),visibleSamples:1,transparentSamples:0,sampledSize:.init(width:1,height:1)).validate())
    XCTAssertThrowsError(try DevelopmentDisplayHistogramEngineV1.histogram(.init(rgba:[.nan,0,0,0],width:1,height:1)))
    // A partially written display buffer retains the same poison used by renderProxy.
    let unwritten=Float(bitPattern:0x7fc00000)
    XCTAssertThrowsError(try DevelopmentDisplayHistogramEngineV1.histogram(.init(rgba:[0,0,0,1,unwritten,unwritten,unwritten,unwritten],width:2,height:1)))
    var bins=Array(repeating:UInt64(0),count:256);bins[0]=1
    XCTAssertNoThrow(try DevelopmentDisplayHistogramV1(luminance:bins,visibleSamples:1,transparentSamples:0,sampledSize:.init(width:1,height:1)).validate())
  }
  private func fixture()throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("display-histogram-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);let url=root.appendingPathComponent("source.tiff")
    try context().writeTIFFRepresentation(of:image(37,53),to:url,format:.RGBA16,colorSpace:DevelopmentColorEngineV3.linearSRGB,options:[:])
    let bytes=try Data(contentsOf:url)
    return(root,.init(projectID:"test",assetID:"owned",contentSHA256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),byteCount:Int64(bytes.count),admissionFingerprint:"admitted",sourceLocation:url))
  }
  private func request(_ operation:DevelopmentAnalysisOperation,recipe:DevelopmentRecipe?=nil,session:DevelopmentPreviewSessionID = .init(),consumer:PreviewConsumerID = .init(),generation:UInt64=1,revision:UInt64=1)throws->DevelopmentAnalysisRequest {
    let r=try recipe ?? DevelopmentRecipe().promotingToV3()
    return .init(preview:.init(sessionID:session,sourceGeneration:generation,consumerID:consumer,role:.primary,revision:revision,recipe:r,quality:.settled,viewport:.init(maxPixel:2400)),expectedRecipeFingerprint:try EditingFingerprint.of(r),stage:.workingImageBeforeGeometry,operation:operation)
  }
  private func binding(_ source:EditingSourceSnapshot)->DevelopmentLocalEditSourceBinding {.init(sourceContentID:source.contentSHA256,exifOrientation:1,orientedWidth:37,orientedHeight:53)}
  func testSelectedMasksUseLayerInputAndFinalColorsAndPartitionTheScopedCache() throws {
    let size = CGRect(x: 0, y: 0, width: 16, height: 8), left = CGRect(x: 0, y: 0, width: 8, height: 8)
    func split(_ leftColor: CIColor, _ rightColor: CIColor) -> CIImage {
      CIImage(color: leftColor).cropped(to: left).composited(over: CIImage(color: rightColor).cropped(to: size))
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
    defer { try? FileManager.default.removeItem(at: url) }
    let ci = context(), space = DevelopmentColorEngineV3.linearSRGB
    try ci.writeTIFFRepresentation(of: split(.red, .green), to: url, format: .RGBA16, colorSpace: space, options: [:])
    let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    let source = DevelopmentLocalEditSourceBinding(sourceContentID: hash, exifOrientation: 1, orientedWidth: 16, orientedHeight: 8)
    let subjectPNG = try XCTUnwrap(ci.pngRepresentation(of: split(.white, .black), format: .RGBA8, colorSpace: space))
    let range = DevelopmentMaskLayerV3(name: "red before its exposure edit", kind: .range, feather: 0,
      rangeLower: 0.18, rangeUpper: 0.24, adjustments: .init(exposure: -1))
    let right = DevelopmentMaskLayerV3(name: "right", kind: .linear,
      start: .init(x: 0.5, y: 0.5), end: .init(x: 0.9, y: 0.5), feather: 0)
    let radial = DevelopmentMaskLayerV3(name: "green center", kind: .radial,
      center: .init(x: 0.75, y: 0.5), radiusX: 0.17, radiusY: 0.3, feather: 0)
    let subject = DevelopmentMaskLayerV3(name: "left", kind: .subject, subjectPNG: subjectPNG)
    let inverted = DevelopmentMaskLayerV3(name: "outside subject", kind: .subject, inverted: true, subjectPNG: subjectPNG)
    let direct = DevelopmentMaskEngineV3.ScopeSelection(range)
    try direct.capture(split(.red, .green))
    let directMask = try XCTUnwrap(direct.coverage)
    let alpha = try DevelopmentDisplayHistogramEngineV1.renderProxy(directMask, roi: .init(), context: ci)
    XCTAssertEqual(stride(from: 3, to: alpha.rgba.count, by: 4).filter { alpha.rgba[$0] > 0 }.count, 64,
                   "The range kernel should select the red half before local exposure")
    let recipe = DevelopmentRecipe(adjustmentsV3: .init(masks: [range, right, radial, subject, inverted]))
    var cache: [DevelopmentDisplayHistogramEngineV1.CacheEntry] = []
    func read(_ id: UUID?) throws -> DevelopmentDisplayHistogramV1 {
      let r = try request(id.map(DevelopmentAnalysisOperation.displayMaskHistogram) ?? .displayHistogram, recipe: recipe)
      let result = try DevelopmentDisplayHistogramEngineV1.run(capture: url, request: r, sourceBinding: source,
        memoryHint: 512, cache: &cache, sourceAuthority: {})
      guard case let .displayHistogram(histogram) = result.value else { throw DevelopmentPreviewError.invalidRequest }
      XCTAssertTrue(try r.matchesSamplingVersion(result.samplingVersion))
      return histogram
    }
    XCTAssertEqual(try read(nil).visibleSamples, 128)
    let red = try read(range.id), first = cache.first?.key
    XCTAssertEqual(red.visibleSamples, 64)
    XCTAssertEqual(red.green[0], 64)
    XCTAssertEqual(red.red[255], 0, "Selected original red pixels must be measured after the exposure edit")
    let green = try read(right.id)
    XCTAssertNotEqual(first, cache.first?.key)
    XCTAssertEqual(green.visibleSamples, 64)
    XCTAssertEqual(green.red[0], 64)
    let center = try read(radial.id)
    XCTAssertGreaterThan(center.visibleSamples, 0); XCTAssertLessThan(center.visibleSamples, 64)
    XCTAssertEqual(center.red[0], UInt64(center.visibleSamples))
    XCTAssertEqual(try read(subject.id), red)
    XCTAssertEqual(try read(inverted.id), green)
    XCTAssertThrowsError(try read(UUID()))
  }
  func testDisplayHasVersionedSeparateCacheAndCannotEnterExactEngine()throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let display=try request(.displayHistogram),b=binding(source)
    var cache: [DevelopmentDisplayHistogramEngineV1.CacheEntry] = []
    var exactCache: DevelopmentAnalysisCacheEntry?
    XCTAssertThrowsError(try DevelopmentAnalysisEngine.run(capture:source.sourceLocation,request:display,sourceBinding:b,memoryHint:512,cache:&exactCache))
    XCTAssertNil(exactCache)
    var nativePasses = 0
    func run(_ request: DevelopmentAnalysisRequest) throws -> DevelopmentAnalysisResult {
      try DevelopmentDisplayHistogramEngineV1.run(capture:source.sourceLocation,request:request,sourceBinding:b,
        memoryHint:512,cache:&cache,prepareNativeWork:{nativePasses += 1},sourceAuthority:{})
    }
    let first = try run(display)
    XCTAssertEqual(first.samplingVersion,DevelopmentDisplayHistogramV1.samplingVersion);guard case .displayHistogram=first.value else{return XCTFail("Display-only DTO required")}
    let saved = try XCTUnwrap(cache.first)
    let next=try request(.displayHistogram,recipe:display.preview.recipe,generation:2)
    _ = try run(next)
    XCTAssertEqual(cache.first?.key.generation,2)
    XCTAssertNotEqual(cache.first?.key,saved.key)
    XCTAssertEqual(try run(display),first)
    XCTAssertEqual(cache.first,saved)
    XCTAssertEqual(nativePasses,2,"A rebound histogram must not start new native work")
    let third = try request(.displayHistogram,recipe:display.preview.recipe,generation:3)
    _ = try run(third)
    XCTAssertEqual(cache.map(\.key.generation),[3,1])
  }
  func testDisplayThenAutomaticAndExactHistogramPreserveOriginalResults()throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let actual=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    let control=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    _=try actual.analyze(request(.displayHistogram),sourceContentID:source.contentSHA256)
    for op in [DevelopmentAnalysisOperation.automatic(.light),.histogram,.summary(.color,amount:0.5)] {
      let r=try request(op),expected=try control.analyze(r,sourceContentID:source.contentSHA256)
      let result=try actual.analyze(r,sourceContentID:source.contentSHA256)
      XCTAssertEqual(result,expected);XCTAssertNotEqual(result.samplingVersion,DevelopmentDisplayHistogramV1.samplingVersion)
    }
  }
  func testCancellationAfterFirstJoinedTileAndBeforeCachePublishReturnsNoPartialResult()throws {
    var checks=0
    XCTAssertThrowsError(try DevelopmentDisplayHistogramEngineV1.renderProxy(image(37,53),roi:.init(),context:context(),checkCancellation:{checks+=1;if checks==2{throw DevelopmentPreviewError.superseded}}))
    XCTAssertEqual(checks,2,"No second tile starts after the first joined tile is revoked")
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    var cache: [DevelopmentDisplayHistogramEngineV1.CacheEntry] = []
    let cancellation=DevelopmentAnalysisCancellation();var authorityChecks=0
    XCTAssertThrowsError(try DevelopmentDisplayHistogramEngineV1.run(capture:source.sourceLocation,request:request(.displayHistogram),sourceBinding:binding(source),memoryHint:512,cache:&cache,cancellation:cancellation,sourceAuthority:{authorityChecks+=1;if authorityChecks==2{cancellation.cancel()}}))
    XCTAssertEqual(authorityChecks,2);XCTAssertTrue(cache.isEmpty)
  }
  func testServiceRejectsWrongDisplayValueVersionAndPopulation()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    for mode in 0..<3 {
      let service=DevelopmentPreviewService(analysisOverride:{request,binding in
        let bins=Array(repeating:UInt64(1),count:256)
        let value:DevelopmentAnalysisValue = mode==0 ? .histogram(.init(red:bins,green:bins,blue:bins,luminance:bins,visibleSamples:256,transparentSamples:0,sampledSize:.init(width:16,height:16))):
          .displayHistogram(.init(luminance:bins,visibleSamples:mode==2 ? 255:256,transparentSamples:0,sampledSize:.init(width:16,height:16)))
        return .init(operationID:request.operationID,sessionID:request.preview.sessionID,consumerID:request.preview.consumerID,revision:request.preview.revision,role:request.preview.role,quality:request.preview.quality,actualRecipe:request.preview.recipe,clientCorrelation:request.preview.clientCorrelation,
          binding:.init(sourceContentID:binding.sourceContentID,sourceGeneration:request.preview.sourceGeneration,expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:request.stage),sourceBinding:binding,presentedRecipeFingerprint:request.presentedRecipeFingerprint,roi:request.roi,
          samplingRecipeFingerprint:try EditingFingerprint.of(DevelopmentAnalysisEngine.samplingRecipe(request)),samplingVersion:mode==1 ? "old-analysis-version":DevelopmentDisplayHistogramV1.samplingVersion,
          geometryMapping:try request.preview.recipe.promotingToV3().adjustmentsV3!.geometry.mapping(sourceSize:binding.sourceSize),value:value)
      })
      let info=try await service.open(source:.raw(source))
      do { _=try await service.analyze(request(.displayHistogram,session:info.id,generation:info.sourceGeneration));XCTFail("Incorrect display contract must be rejected") }
      catch DevelopmentPreviewError.invalidRequest {}
      await service.closeAll()
    }
  }
  private func wait(_ predicate:()async->Bool)async {
    for _ in 0..<200 {if await predicate(){return};try? await Task.sleep(nanoseconds:5_000_000)}
    XCTFail("Timed out waiting for bounded worker state")
  }
  func testDisplayCancellationKeepsNativeSlotUntilActualJoin()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let gate=DisplayAnalysisJoinGate();defer{gate.release()}
    let service=DevelopmentPreviewService(analysisOverride:{request,_ in
      guard request.operation.isDisplayHistogram else{throw DevelopmentPreviewError.invalidRequest}
      gate.enterAndWait();throw DevelopmentPreviewError.superseded
    },renderOverride:{_,_ in gate.rendered();return PreviewPixels(image:NSImage(size:.init(width:8,height:8)),nativeSize:.init(width:8,height:8),outputSize:.init(width:8,height:8),bytes:256)})
    let session=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
    let r=try request(.displayHistogram,session:session.id,consumer:consumer,generation:session.sourceGeneration)
    let old=Task{try await service.analyze(r)}
    await wait{gate.entered}
    let next=DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:consumer,role:.primary,revision:2,recipe:.init(exposureEV:0.2),quality:.interactive,viewport:.init(maxPixel:2400))
    let preview=Task{try await service.render(next)}
    await wait{await service.statistics().pendingRequests==1}
    do{_=try await old.value;XCTFail("Stale display should be revoked")}catch DevelopmentPreviewError.superseded{}
    XCTAssertEqual(gate.renderCount,0)
    let busy=await service.statistics();XCTAssertEqual(busy.activeNativeRenders,1)
    gate.release();_=try await preview.value
    XCTAssertEqual(gate.renderCount,1)
    await service.closeAll();let closed=await service.statistics()
    XCTAssertEqual(closed.activeNativeRenders,0);XCTAssertEqual(closed.sourceSnapshotDiskBytes,0);XCTAssertEqual(closed.maximumObservedNativeRenders,1)
  }
}
private final class DisplayAnalysisJoinGate:@unchecked Sendable {
  private let lock=NSLock(),semaphore=DispatchSemaphore(value:0)
  private var hasEntered=false,renders=0
  var entered:Bool{lock.lock();defer{lock.unlock()};return hasEntered}
  var renderCount:Int{lock.lock();defer{lock.unlock()};return renders}
  func enterAndWait(){lock.lock();hasEntered=true;lock.unlock();semaphore.wait()}
  func rendered(){lock.lock();renders+=1;lock.unlock()}
  func release(){semaphore.signal()}
}
