import Foundation
import AppKit
import XCTest
import CoreImage
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentCropAutoV1ImagingTests: XCTestCase {
  private func request(geometry:DevelopmentGeometryV3 = .init(),stage:DevelopmentAnalysisStage = .orientedSourceBeforeGeometry,includeInput:Bool = true) throws -> DevelopmentAnalysisRequest {
    var recipe=try DevelopmentRecipe().promotingToV3();recipe.adjustmentsV3!.geometry=geometry
    let fp=try EditingFingerprint.of(recipe)
    return .init(preview:.init(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,revision:1,recipe:recipe,quality:.settled,viewport:.init()),expectedRecipeFingerprint:fp,
      stage:stage,operation:.cropAutomatic,presentedRecipeFingerprint:String(repeating:"d",count:64),cropAutoInputV1:includeInput ? try DevelopmentCropAutoInputV1(geometry:geometry,aspectRatio:nil):nil)
  }
  func testOperationRequiresExactInputAndStageWithoutConflatingVisibleDraftFingerprint() throws {
    let good=try request(geometry:.init(crop:.init(x:0.1,y:0.1,width:0.8,height:0.8)))
    XCTAssertNotEqual(good.presentedRecipeFingerprint,good.expectedRecipeFingerprint)
    XCTAssertNoThrow(try good.validate())
    XCTAssertThrowsError(try request(stage:.workingImageBeforeGeometry).validate())
    XCTAssertThrowsError(try request(includeInput:false).validate())
  }
  func testSamplingRecipeIsNeutralAndDoesNotModifyAnalysisRecipeOrUserGeometry() throws {
    let r=try request(geometry:.init(straightenDegrees:7,clockwiseQuarterTurns:1,flipHorizontal:true))
    let before=try EditingFingerprint.of(r.preview.recipe)
    let neutral=try DevelopmentAnalysisEngine.samplingRecipe(r)
    XCTAssertEqual(neutral.adjustmentsV3,DevelopmentAdjustmentsV3())
    XCTAssertEqual(try EditingFingerprint.of(r.preview.recipe),before)
    XCTAssertEqual(r.preview.recipe.adjustmentsV3!.geometry.straightenDegrees,7)
    XCTAssertEqual(try DevelopmentAnalysisEngine.validatedSamplingVersion(r),DevelopmentCropAutoV1.version)
    XCTAssertEqual(try DevelopmentAnalysisEngine.samplingSupportRecipe(r),neutral)
  }
  func testControlledRollVerificationUsesFixedActualPairAndRejectsMissingOrUntrustedObservations() throws {
    var calls=[Double]()
    let pair=try DevelopmentCropAutoV1.verifyControlledRoll(observe:{ roll in
      calls.append(roll);return .init(degrees:-roll,confidence:0.9)
    },checkCancellation:{})
    XCTAssertEqual(calls,[3,-3]);XCTAssertEqual(pair.residualDegrees,0);XCTAssertEqual(pair.confidence,0.9)
    for missing in [3.0,-3] {
      calls=[]
      XCTAssertThrowsError(try DevelopmentCropAutoV1.verifyControlledRoll(observe:{ roll in
        calls.append(roll);return roll == missing ? nil:.init(degrees:-roll,confidence:1)
      },checkCancellation:{})) { error in
        guard let rejection=error as? DevelopmentCropAutoV1.Rejection,case .noResult(.noHorizon)=rejection else { return XCTFail("Missing observation must remain noHorizon") }
      }
      XCTAssertEqual(calls,missing == 3 ? [3]:[3,-3],"No fallback or third observation")
    }
    for (positive,negative,confidence) in [(-3.0,3,0.79),(-2.49,3,1),(-2.6,2.6,1),(3,-3,1),(Double.nan,3,1)] {
      XCTAssertThrowsError(try DevelopmentCropAutoV1.verifyControlledRoll(observe:{ roll in
        .init(degrees:roll == 3 ? positive:negative,confidence:confidence)
      },checkCancellation:{}))
    }
  }
  func testControlledRollVerificationCancellationAtEveryBoundaryCannotPublishAPair() throws {
    for cancelledAt in 1...5 {
      var checks=0,calls=[Double]()
      XCTAssertThrowsError(try DevelopmentCropAutoV1.verifyControlledRoll(observe:{ roll in
        calls.append(roll);return .init(degrees:-roll,confidence:1)
      },checkCancellation:{ checks += 1;if checks == cancelledAt { throw CancellationError() } })) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertEqual(calls.count,[0,1,1,2,2][cancelledAt-1])
    }
    var checks=0
    XCTAssertThrowsError(try DevelopmentCropAutoV1.verifyControlledRoll(observe:{ _ in nil },checkCancellation:{
      checks += 1;if checks == 2 { throw CancellationError() }
    })) { XCTAssertTrue($0 is CancellationError,"Revoked nil result must not bypass post-perform cancellation") }
  }
  func testControlledRollTransformMatchesExistingCoreSignCenterAndInscribedTrimWithoutRounding() throws {
    for (w,h) in [(1001,667),(667,1001),(4000,256)] { for degrees in [3.0,-3] {
      let actual=try DevelopmentCropAutoV1.controlledRollTransform(width:Double(w),height:Double(h),knownRollDegrees:degrees)
      let map=try DevelopmentGeometryV3(straightenDegrees:degrees).mapping(sourceSize:.init(width:w,height:h)),p=map.cropPlane,m=p.forwardMatrix,H=p.rect.height
      let expected=CGAffineTransform(a:m[0],b:-m[3],c:-m[1],d:m[4],tx:m[1]*Double(h)+m[2],ty:H-m[4]*Double(h)-m[5])
      XCTAssertEqual(actual.rect.width,p.rect.width,accuracy:1e-9);XCTAssertEqual(actual.rect.height,p.rect.height,accuracy:1e-9)
      for (a,b) in zip([actual.transform.a,actual.transform.b,actual.transform.c,actual.transform.d,actual.transform.tx,actual.transform.ty],[expected.a,expected.b,expected.c,expected.d,expected.tx,expected.ty]) { XCTAssertEqual(a,b,accuracy:1e-9) }
      let center=CGPoint(x:Double(w)/2,y:Double(h)/2).applying(actual.transform)
      XCTAssertEqual(center.x,actual.rect.width/2,accuracy:1e-9);XCTAssertEqual(center.y,actual.rect.height/2,accuracy:1e-9)
    } }
    let fractional=try DevelopmentCropAutoV1.controlledRollTransform(width:2211.75,height:1272.25,knownRollDegrees:3)
    let center=CGPoint(x:2211.75/2,y:1272.25/2).applying(fractional.transform)
    XCTAssertEqual(center.x,fractional.rect.width/2,accuracy:1e-9);XCTAssertEqual(center.y,fractional.rect.height/2,accuracy:1e-9)
    XCTAssertNotEqual(fractional.rect.width,floor(fractional.rect.width))
    XCTAssertThrowsError(try DevelopmentCropAutoV1.controlledRollTransform(width:1001,height:667,knownRollDegrees:2))
  }
  func testCancellationRevokesDeliveryButKeepsUniqueWorkerUntilJoined() async throws {
    final class Gate: @unchecked Sendable {
      let entered=XCTestExpectation(description:"native analysis entered")
      let release=DispatchSemaphore(value:0)
      private let lock=NSLock()
      private var returned=false
      func markJoinReturned() { lock.lock();returned=true;lock.unlock() }
      var joinReturned:Bool { lock.lock();defer { lock.unlock() };return returned }
    }
    let oldOperationID=UUID()
    let gate=Gate(),root=FileManager.default.temporaryDirectory.appendingPathComponent("crop-auto-join-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { gate.release.signal();try? FileManager.default.removeItem(at:root) }
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:512,pixelsHigh:512,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    memset(bitmap.bitmapData!,255,bitmap.bytesPerRow*bitmap.pixelsHigh)
    let bytes=try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),file=root.appendingPathComponent("input.png")
    try bytes.write(to:file)
    let snapshot=EditingSourceSnapshot(projectID:"test",assetID:"asset",contentSHA256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),byteCount:Int64(bytes.count),admissionFingerprint:String(repeating:"b",count:64),sourceLocation:file)
    let service=DevelopmentPreviewService(analysisOverride:{request,source in
      if request.operationID == oldOperationID { gate.entered.fulfill();gate.release.wait() }
      let binding=DevelopmentAnalysisBinding(sourceContentID:source.sourceContentID,sourceGeneration:request.preview.sourceGeneration,expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:request.stage)
      let input=try XCTUnwrap(request.cropAutoInputV1)
      let resolved=DevelopmentResolvedGeometryV1(binding:binding,source:source,presentedRecipeFingerprint:request.presentedRecipeFingerprint,input:input,resolution:.noResult(.noHorizon))
      return .init(operationID:request.operationID,sessionID:request.preview.sessionID,consumerID:request.preview.consumerID,revision:request.preview.revision,role:request.preview.role,quality:request.preview.quality,actualRecipe:request.preview.recipe,clientCorrelation:request.preview.clientCorrelation,binding:binding,sourceBinding:source,presentedRecipeFingerprint:request.presentedRecipeFingerprint,roi:request.roi,samplingRecipeFingerprint:try EditingFingerprint.of(DevelopmentAnalysisEngine.samplingRecipe(request)),samplingVersion:try DevelopmentAnalysisEngine.validatedSamplingVersion(request),geometryMapping:try request.preview.recipe.adjustmentsV3!.geometry.mapping(sourceSize:source.sourceSize),value:.geometry(resolved))
    },renderOverride:{_,_ in
      PreviewPixels(image:NSImage(size:.init(width:8,height:8)),nativeSize:.init(width:512,height:512),outputSize:.init(width:8,height:8),bytes:256)
    })
    let session=try await service.open(source:.raw(snapshot)),consumer=PreviewConsumerID(),template=try request()
    let r=DevelopmentAnalysisRequest(operationID:oldOperationID,preview:.init(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:consumer,role:.primary,revision:1,recipe:template.preview.recipe,quality:.settled),expectedRecipeFingerprint:template.expectedRecipeFingerprint,stage:.orientedSourceBeforeGeometry,operation:.cropAutomatic,cropAutoInputV1:template.cropAutoInputV1)
    let running=Task { try await service.analyze(r) }
    await fulfillment(of:[gate.entered],timeout:5)
    await service.cancelAnalysis(consumerID:consumer)
    let whileRevoked=await service.statistics()
    XCTAssertEqual(whileRevoked.activeNativeRenders,1,"Cancel delivered to UI is not native join")
    switch await running.result { case .success:XCTFail("Revoked result delivered");case .failure:break }
    // Newer work uses the SAME consumer: a consumer-wide cancel/join would wrongly remove it.
    let nextPreview=DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:consumer,role:.primary,revision:2,recipe:template.preview.recipe,quality:.settled)
    let nextRequest=DevelopmentAnalysisRequest(preview:nextPreview,expectedRecipeFingerprint:template.expectedRecipeFingerprint,stage:.orientedSourceBeforeGeometry,operation:.cropAutomatic,cropAutoInputV1:template.cropAutoInputV1)
    let nextAnalysis=Task { try await service.analyze(nextRequest) }
    let preview=Task { try await service.render(nextPreview) }
    var newerQueued=false
    for _ in 0..<2000 {
      let a=await service.analysisStatistics(),s=await service.statistics()
      if a.pendingUser == 1 && s.pendingRequests == 1 { newerQueued=true;break }
      await Task.yield()
    }
    XCTAssertTrue(newerQueued,"New analysis and preview must be admitted while old native body is blocked")
    let joinStarted=XCTestExpectation(description:"old exact join called")
    let joinCompleted=XCTestExpectation(description:"old exact native join completed")
    let joining=Task { joinStarted.fulfill();await service.cancelAnalysisAndJoin(r);gate.markJoinReturned();joinCompleted.fulfill() }
    await fulfillment(of:[joinStarted],timeout:5)
    try await Task.sleep(nanoseconds:50_000_000) // Same observation window; native release remains semaphore-controlled.
    XCTAssertFalse(gate.joinReturned,"Early analyze failure must not complete native join")
    let stillOwned=await service.statistics(),stillQueued=await service.analysisStatistics()
    XCTAssertEqual(stillOwned.activeNativeRenders,1);XCTAssertEqual(stillOwned.pendingRequests,1);XCTAssertEqual(stillQueued.pendingUser,1)
    gate.release.signal();await fulfillment(of:[joinCompleted],timeout:5);await joining.value
    XCTAssertTrue(gate.joinReturned)
    let newerResult=try await nextAnalysis.value,newerFrame=try await preview.value
    XCTAssertEqual(newerResult.operationID,nextRequest.operationID);XCTAssertEqual(newerFrame.revision,2)
    await service.closeAll()
    let joined=await service.statistics(),analysis=await service.analysisStatistics()
    XCTAssertEqual(joined.activeNativeRenders,0);XCTAssertEqual(analysis.maximumActive,1);XCTAssertEqual(analysis.completed,2)
  }
  /// Root must explicitly grant this test's native/GPU work. Synthetic lines are NOT a substitute.
  func testActualNaturalPositiveNegativeAndCancellationQualification() throws {
    guard let path=ProcessInfo.processInfo.environment["RAWMASTER_CROP_AUTO_NATURAL_FIXTURES"] else { throw XCTSkip("Root explicit native grant and fixed natural photograph fixtures required") }
    let root=URL(fileURLWithPath:path),context=CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV3.linearSRGB])
    defer { context.clearCaches() }
    var receipts=[[String:Any]](),naturalAngles=[String:Double]()
    for name in ["natural-rotate--5.png","natural-rotate-+5.png","no-horizon-flat.png","transparent-natural.png"] {
      let url=root.appendingPathComponent(name),data=try Data(contentsOf:url),image=try XCTUnwrap(CIImage(contentsOf:url,options:[.applyOrientationProperty:true]))
      let source=DevelopmentLocalEditSourceBinding(sourceContentID:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),exifOrientation:1,orientedWidth:Int(image.extent.width),orientedHeight:Int(image.extent.height))
      let r=try request(),input=try XCTUnwrap(r.cropAutoInputV1)
      let value=try DevelopmentCropAutoV1.resolve(image:image,request:r,source:source,input:input,context:context,checkCancellation:{})
      switch value.resolution {
      case .candidate(let geometry,let evidence):
        XCTAssertTrue(name.hasPrefix("natural-"),"Negative returned a geometry")
        XCTAssertGreaterThan(abs(geometry.straightenDegrees),0.05)
        naturalAngles[name]=geometry.straightenDegrees
        let verification=[evidence.verificationPair.positiveRoll,evidence.verificationPair.negativeRoll].map { observation in
          ["knownRollDegrees":observation.knownRollDegrees,"correctionDegrees":observation.correctionDegrees,"confidence":observation.confidence,"residualDegrees":observation.residualDegrees]
        }
        receipts.append(["file":name,"outcome":"candidate","degrees":geometry.straightenDegrees,"residual":evidence.residualDegrees,"confidence":evidence.firstConfidence,"verificationMinimumConfidence":evidence.verificationConfidence,"verificationPair":verification,"firstDegrees":evidence.firstDegrees,"secondDegrees":evidence.secondDegrees,"secondConfidence":evidence.secondConfidence,"detectorRevision":evidence.detectorRevision,"sourceSHA256":source.sourceContentID])
      case .noResult(let reason):
        XCTAssertFalse(name.hasPrefix("natural-"),"Real positive failed: \(reason)")
        receipts.append(["file":name,"outcome":"noResult","reason":reason.rawValue,"sourceSHA256":source.sourceContentID])
      }
      XCTAssertThrowsError(try DevelopmentCropAutoV1.resolve(image:image,request:r,source:source,input:input,context:context,checkCancellation:{throw CancellationError()}))
    }
    if let minus=naturalAngles["natural-rotate--5.png"],let plus=naturalAngles["natural-rotate-+5.png"] {
      // Pillow fixture rotations and CI/Core straighten are both positive CCW in displayed image space.
      // Unknown natural baseline cancels: the +5 fixture must need 10deg less correction than the -5 fixture.
      XCTAssertEqual(plus-minus,-10,accuracy:1.5,"Known natural-image rotation must be corrected with the right sign")
    } else { XCTFail("Both fixed natural photograph positives must actually succeed") }
    if let out=ProcessInfo.processInfo.environment["RAWMASTER_CROP_AUTO_REPORT"] {
      try JSONSerialization.data(withJSONObject:["algorithm":DevelopmentCropAutoV1.version,"cases":receipts],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:out),options:.atomic)
    }
  }
}
