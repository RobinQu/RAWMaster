import XCTest
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentRedEyeAutomaticV3Tests:XCTestCase {
  private func context()throws->CIContext {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Actual Metal device unavailable") }
    return .init(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
  }
  private func image(_ pixels:[SIMD4<Float>],_ w:Int,_ h:Int)->CIImage {
    .init(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:w*16,size:.init(width:w,height:h),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func fixture(_ centers:[SIMD2<Double>],w:Int=256,h:Int=128,iris:Bool=true)->[SIMD4<Float>] {
    var pixels=Array(repeating:SIMD4<Float>(0.5,0.35,0.25,1),count:w*h)
    for center in centers {
      let x0=max(0,Int(floor(center.x-8))),x1=min(w-1,Int(ceil(center.x+8)))
      let y0=max(0,Int(floor(center.y-8))),y1=min(h-1,Int(ceil(center.y+8)))
      if x0>x1 || y0>y1 { continue }
      for y in y0...y1 { for x in x0...x1 {
        let distance=hypot(Double(x)+0.5-center.x,Double(y)+0.5-center.y)
        if iris && distance<=7 { pixels[y*w+x] = .init(0.01,0.01,0.01,1) }
        if distance<=4 { pixels[y*w+x] = .init(0.7,0.015,0.015,1) }
        if distance<0.7 { pixels[y*w+x] = .init(0.9,0.9,0.9,1) }
      } }
    };return pixels
  }
  private func detect(_ input:CIImage,context:CIContext,remaining:Int=128,cancellation:DevelopmentAnalysisCancellation?=nil)throws->DevelopmentRedEyeAutomaticV3.Detection {
    let sampler=try DevelopmentLocalAnalysisV3.Sampler(image:input,context:context,cancellation:cancellation,trackAllocations:true)
    return try DevelopmentRedEyeAutomaticV3.detect(sampler:sampler,remainingOperations:remaining,cancellation:cancellation)
  }
  // Test-only stage diagnostics retain the original1024 fixtures and strict error expectation.
  // A failed sampler is explicitly separate from a detector cardinality rejection.
  private func countLimitStage(_ label:String,_ stage:String,sampler:DevelopmentLocalAnalysisV3.Sampler?=nil,error:Error?=nil) {
    let charge=DevelopmentLocalChargeV3.snapshot()
    let dimensions=sampler.map { "native=\($0.width)x\($0.height) proxy=\($0.pw)x\($0.ph) proxyBytes=\($0.proxy.bytes) peakAnalysis=\($0.peakAnalysisBytes) peakMetadata=\($0.peakMetadataBytes)" } ?? "dimensions=notConstructed"
    print("B5B_COUNT_STAGE label=\(label) stage=\(stage) metadata=\(charge.metadata) analysis=\(charge.analysis) \(dimensions) error=\(error.map{String(describing:$0)} ?? "nil")")
  }
  private func detectCountLimit(_ input:CIImage,context:CIContext,label:String)throws->DevelopmentRedEyeAutomaticV3.Detection {
    countLimitStage(label,"sampler-before")
    let sampler:DevelopmentLocalAnalysisV3.Sampler
    do {
      sampler=try DevelopmentLocalAnalysisV3.Sampler(image:input,context:context,trackAllocations:true,testStage:{ stage in
        let rect=stage.rect.map { "x=\($0.origin.x),y=\($0.origin.y),w=\($0.width),h=\($0.height)" } ?? "nil"
        print("B5B_SAMPLER_STAGE label=\(label) stage=\(stage.name) native=\(stage.width)x\(stage.height) proxy=\(stage.proxyWidth)x\(stage.proxyHeight) requestedBytes=\(stage.requestedBytes) reservedBytes=\(stage.reservedBytes.map{String($0)} ?? "nil") actualMallocBytes=\(stage.actualMallocBytes.map{String($0)} ?? "nil") rect=\(rect) metadata=\(stage.metadataBytes) analysis=\(stage.analysisBytes) error=\(stage.error.map{String(describing:$0)} ?? "nil")")
      })
      countLimitStage(label,"sampler-returned",sampler:sampler)
    } catch { countLimitStage(label,"sampler-threw",error:error);throw error }
    countLimitStage(label,"detect-before",sampler:sampler)
    do {
      let result=try DevelopmentRedEyeAutomaticV3.detect(sampler:sampler,remainingOperations:128,cancellation:nil)
      countLimitStage(label,"detect-returned",sampler:sampler);return result
    } catch { countLimitStage(label,"detect-threw",sampler:sampler,error:error);throw error }
  }
  private func decode(_ x:Float)->Float { x<=0.04045 ? x/12.92:powf((x+0.055)/1.055,2.4) }
  func testEncodedMaskVisibilityCatchlightHDRAndInvalidInput()throws {
    XCTAssertTrue(DevelopmentRedEyeAutomaticV3.red(.init(0.9,0.1,0.1)))
    XCTAssertFalse(DevelopmentRedEyeAutomaticV3.red(.init(0.95,0.95,0.95)))
    XCTAssertFalse(DevelopmentRedEyeAutomaticV3.red(.init(0.85,0.05,0.9)))
    XCTAssertNil(try DevelopmentRedEyeAutomaticV3.encoded(.init(2,-1,4,0)))
    XCTAssertNotNil(try DevelopmentRedEyeAutomaticV3.encoded(.init(2,-1,4,1)))
    for p in [SIMD4<Float>(.nan,0,0,0),.init(.infinity,0,0,0),.init(0,0,0,-0.1),.init(0,0,0,1.1)] { XCTAssertThrowsError(try DevelopmentRedEyeAutomaticV3.encoded(p)) }
  }
  func testActualXYScalesMapCentersAreaRadiusWithoutUniformAssumption()throws {
    let value=try DevelopmentRedEyeAutomaticV3.sourceGeometry(cx:321.5,cy:420.5,area:49,proxyWidth:1536,proxyHeight:1155,width:1919,height:1444)
    let sx=1536.0/1919,sy=1155.0/1444
    XCTAssertNotEqual(sx,sy)
    XCTAssertEqual(value.center.x,321.5/sx,accuracy:1e-12);XCTAssertEqual(value.center.y,420.5/sy,accuracy:1e-12)
    XCTAssertEqual(value.radius,1.4*sqrt(49/(Double.pi*sx*sy)),accuracy:1e-12)
  }
  func testPositiveManualWeightAndZeroBoundaryCannotCountAsSupport()throws {
    let center=SIMD2<Double>(10.5,10.5),red=SIMD4<Float>(0.7,0.015,0.015,1)
    XCTAssertTrue(try DevelopmentRedEyeAutomaticV3.effectiveSupport(red,point:center,center:center,radius:4))
    XCTAssertFalse(try DevelopmentRedEyeAutomaticV3.effectiveSupport(red,point:.init(14.5,10.5),center:center,radius:4))
    XCTAssertFalse(try DevelopmentRedEyeAutomaticV3.effectiveSupport(.init(0.9,0.9,0.9,1),point:center,center:center,radius:4))
    for rgb in [SIMD3<Float>(0.65,0.5,0.2),.init(0.25,0.05,0.05),.init(0.75,0.25,0.24)] {
      let p=SIMD4(decode(rgb.x),decode(rgb.y),decode(rgb.z),Float(1))
      XCTAssertFalse(try DevelopmentRedEyeAutomaticV3.effectiveSupport(p,point:center,center:center,radius:4),"Zero boundary or representably unchanged mix cannot count: \(rgb)")
    }
  }
  func testPairRequiresBothNativeQualifiedAndEachPointSix() {
    var a=DevelopmentRedEyeAutomaticV3.Candidate(x:10,y:10,radius:5,score:0.60,component:0,qualified:true)
    var b=DevelopmentRedEyeAutomaticV3.Candidate(x:40,y:12,radius:5,score:0.60,component:1,qualified:true)
    XCTAssertTrue(DevelopmentRedEyeAutomaticV3.pair(a,b))
    b.score=0.599999;XCTAssertFalse(DevelopmentRedEyeAutomaticV3.pair(a,b))
    b.score=0.8;b.qualified=false;XCTAssertFalse(DevelopmentRedEyeAutomaticV3.pair(a,b))
    b.qualified=true;a.score=0.599999;XCTAssertFalse(DevelopmentRedEyeAutomaticV3.pair(a,b))
    a.score=0.8;b.y=80;XCTAssertFalse(DevelopmentRedEyeAutomaticV3.pair(a,b))
  }
  func testStableOperationIDsDifferByComponentAndOriginalRequest() {
    let id=UUID();XCTAssertEqual(DevelopmentRedEyeAutomaticV3.operationID(id,component:7),DevelopmentRedEyeAutomaticV3.operationID(id,component:7))
    XCTAssertNotEqual(DevelopmentRedEyeAutomaticV3.operationID(id,component:7),DevelopmentRedEyeAutomaticV3.operationID(id,component:8))
    XCTAssertNotEqual(DevelopmentRedEyeAutomaticV3.operationID(id,component:7),DevelopmentRedEyeAutomaticV3.operationID(UUID(),component:7))
  }
  func testCancelledFlagRejectsBeforeProxyScanAndNoResultOwnedBytesReturn()throws {
    let c=try context();defer { c.clearCaches() }
    let before=DevelopmentLocalChargeV3.snapshot(),flag=DevelopmentAnalysisCancellation();flag.cancel()
    XCTAssertThrowsError(try autoreleasepool { try detect(image(fixture([]),256,128),context:c,cancellation:flag) })
    let after=DevelopmentLocalChargeV3.snapshot();XCTAssertEqual(after.analysis,before.analysis);XCTAssertEqual(after.metadata,before.metadata)
  }
  func testActualTwoAndSingleEyeNativeQualificationAndBudgetRelease()throws {
    let c=try context();defer { c.clearCaches() }
    let before=DevelopmentLocalChargeV3.snapshot()
    for centers in [[SIMD2<Double>(70.5,64.5),.init(186.5,64.5)],[SIMD2<Double>(70.5,64.5)]] {
      try autoreleasepool {
        guard case .circles(let result)=try detect(image(fixture(centers),256,128),context:c) else { return XCTFail("Actual positive synthetic eyes must be detected") }
        XCTAssertEqual(result.count,centers.count)
        XCTAssertGreaterThan(result.statistics.nativeQualified,0)
        XCTAssertLessThanOrEqual(result.statistics.peakAnalysisBytes,DevelopmentLocalWorkEstimatorV1.analysisUnionBytes)
        XCTAssertLessThanOrEqual(result.statistics.peakMetadataBytes,DevelopmentLocalWorkEstimatorV1.metadataUnionBytes)
        for i in 0..<result.count { XCTAssertTrue(result[i].qualified);XCTAssertGreaterThanOrEqual(result[i].score,0.60);XCTAssertGreaterThan(result[i].radius,0) }
        if result.count==2 { XCTAssertLessThan(result[0].x,result[1].x) }
      }
    }
    let after=DevelopmentLocalChargeV3.snapshot();XCTAssertEqual(after.analysis,before.analysis);XCTAssertEqual(after.metadata,before.metadata)
  }
  func testActualNoEyeAndRedNonEyeReturnTypedNoResult()throws {
    let c=try context();defer { c.clearCaches() }
    for (pixels,reason) in [(fixture([]),DevelopmentLocalNoResult.noRedPixels),(fixture([.init(70.5,64.5)],iris:false),.noConfidentEyes)] {
      guard case .noResult(let actual)=try detect(image(pixels,256,128),context:c) else { return XCTFail("Red non-eye is not a valid eye") }
      XCTAssertEqual(actual,reason)
    }
  }
  func testActualMoreThan64AndInsufficientRemainingRejectWholeDetection()throws {
    let c=try context();defer { c.clearCaches() }
    let two=image(fixture([.init(70.5,64.5),.init(186.5,64.5)]),256,128)
    XCTAssertThrowsError(try detect(two,context:c,remaining:1)) { if case DevelopmentLocalPreparationError.localWorkBudgetExceeded=$0 {}else{XCTFail("Wrong aggregate limit \($0)")} }
    let centers=(0..<65).map { SIMD2<Double>(20.5+Double($0%9)*110,20.5+Double($0/9)*130) }
    let many=image(fixture(centers,w:1024,h:1024),1024,1024)
    XCTAssertThrowsError(try detectCountLimit(many,context:c,label:"65-eyes-original1024")) { if case DevelopmentLocalPreparationError.localWorkBudgetExceeded=$0 {}else{XCTFail("No partial64 \($0)")} }
  }
  func testActualMoreThan256GeometricCandidatesRejectWithoutTruncating()throws {
    let c=try context();defer { c.clearCaches() }
    let centers=(0..<257).map { SIMD2<Double>(20.5+Double($0%17)*58,20.5+Double($0/17)*60) }
    XCTAssertThrowsError(try detectCountLimit(image(fixture(centers,w:1024,h:1024),1024,1024),context:c,label:"257-components-original1024")) { if case DevelopmentLocalPreparationError.localWorkBudgetExceeded=$0 {}else{XCTFail("No truncated candidate search \($0)")} }
  }
  func testActualCirclesUseManualReplayEachPupilChangesAndCatchlightOutsideProtected()throws {
    let c=try context();defer { c.clearCaches() }
    let w=256,h=128,input=image(fixture([.init(70.5,64.5),.init(186.5,64.5)]),w,h)
    guard case .circles(let circles)=try detect(input,context:c) else { return XCTFail("Expected two actual eyes") }
    var output=input
    for i in 0..<circles.count {
      let eye=circles[i],p=DevelopmentSourcePoint(x:eye.x/Double(w),y:eye.y/Double(h))
      let operation=DevelopmentLocalEdit(sourceContentID:String(repeating:"a",count:64),tool:.redEye,
        stroke:.init(points:[.init(position:p)],radiusInShortEdge:eye.radius/Double(h),strength:1))
      output=try DevelopmentLocalEngineV3.apply(operation,to:output,size:.init(width:w,height:h))
    }
    var before=[SIMD4<Float>](),after=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(input,rect:input.extent,context:c) { before=Array($0) }
    try DevelopmentLocalEngineV3.read(output,rect:output.extent,context:c) { after=Array($0) }
    var changed=[Bool](repeating:false,count:circles.count)
    for y in 0..<h { for x in 0..<w {
      let i=y*w+x;XCTAssertEqual(after[i].w.bitPattern,before[i].w.bitPattern)
      // Compare in observed native-read coordinates; vertical mirror of the horizontal eye row is equivalent.
      var covered=false
      for j in 0..<circles.count { let eye=circles[j],d=hypot(Double(x)+0.5-eye.x,Double(y)+0.5-eye.y);if d<eye.radius { covered=true;if after[i].x<before[i].x { changed[j]=true } } }
      if !covered { XCTAssertEqual(after[i],before[i]) }
      if before[i].x>0.85 && before[i].y>0.85 && before[i].z>0.85 { XCTAssertEqual(after[i],before[i]) }
    } }
    XCTAssertTrue(changed.allSatisfy{$0},"Each accepted pupil must actually decrease red")
  }
  func testSpecialOperationValidationAndSamplingVersionAreNotGenericAutomatic()throws {
    XCTAssertEqual(DevelopmentAnalysisOperation.redEyeAutomatic.localTool,.redEye)
    let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:256,orientedHeight:128)
    let p=try DevelopmentRecipe().prospectiveLocalInputV1(source:source,sourceGeneration:1,decoderContractFingerprint:String(repeating:"b",count:64),targetTool:.redEye)
    let request=DevelopmentAnalysisRequest(preview:.init(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,revision:1,recipe:p.analysisRecipe,quality:.settled),expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,operation:.redEyeAutomatic,presentedRecipeFingerprint:p.presentedRecipeFingerprint,localInputV1:p.input)
    XCTAssertNoThrow(try request.validate());XCTAssertEqual(DevelopmentAnalysisEngine.resultSamplingVersion(request),DevelopmentRedEyeAutomaticV3.version)
    let invalid=DevelopmentAnalysisRequest(preview:request.preview,expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,roi:.init(x:0.1,y:0,width:0.9,height:1),operation:.redEyeAutomatic,localInputV1:p.input)
    XCTAssertThrowsError(try invalid.validate())
  }
  func testDetectedBatchUsesProspectiveEnabledPrefixAndCoreCommitsAllEyesAtomically() throws {
    let c=try context();defer { c.clearCaches() }
    let w=256,h=128,binding=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:w,orientedHeight:h)
    let old=DevelopmentLocalEdit(sourceContentID:binding.sourceContentID,tool:.redEye,stroke:.init(points:[.init(position:.init(x:0.5,y:0.2))],radiusInShortEdge:0.02,strength:1))
    var p=DevelopmentAdjustmentsV3();p.localEdits = .init(sourceBinding:binding,redEyeEnabled:false,operations:[old])
    let original=DevelopmentRecipe(adjustmentsV3:p),projection=try original.prospectiveLocalInputV1(source:binding,sourceGeneration:1,decoderContractFingerprint:String(repeating:"b",count:64),targetTool:.redEye)
    XCTAssertTrue(projection.recipe.adjustmentsV3!.localEdits.redEyeEnabled);XCTAssertFalse(original.adjustmentsV3!.localEdits.redEyeEnabled)
    let input=image(fixture([.init(70.5,64.5),.init(186.5,64.5)]),w,h)
    let prefix=try DevelopmentLocalEngineV3.apply(old,to:input,size:binding.sourceSize)
    guard case .circles(let detected)=try detect(prefix,context:c) else { return XCTFail("Actual two-eye prefix") }
    var operations=[DevelopmentLocalEdit]();let requestID=UUID()
    for i in 0..<detected.count {
      let eye=detected[i]
      operations.append(.init(id:DevelopmentRedEyeAutomaticV3.operationID(requestID,component:eye.component),sourceContentID:binding.sourceContentID,tool:.redEye,
        stroke:.init(points:[.init(position:.init(x:eye.x/Double(w),y:eye.y/Double(h)))],radiusInShortEdge:eye.radius/Double(h),strength:1)))
    }
    let batch=DevelopmentResolvedLocalBatch(binding:.init(sourceContentID:binding.sourceContentID,sourceGeneration:1,expectedRecipeFingerprint:projection.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),presentedRecipeFingerprint:projection.presentedRecipeFingerprint,input:projection.input,resolution:.append(operations))
    let committed=try original.applying(.appendResolvedLocalBatch(batch),context:.init(source:binding,sourceGeneration:1,analysisStage:.workingImageBeforeGeometry,localInputV1:projection.input))
    XCTAssertEqual(operations.count,2);XCTAssertEqual(committed.adjustmentsV3!.localEdits.operations.count,3)
    XCTAssertTrue(committed.adjustmentsV3!.localEdits.redEyeEnabled);XCTAssertEqual(committed.adjustmentsV3!.localEdits.operations.first,old)
    XCTAssertEqual(original.adjustmentsV3!.localEdits.operations,[old])
    var replay=input
    for op in committed.adjustmentsV3!.localEdits.operations { replay=try DevelopmentLocalEngineV3.apply(op,to:replay,size:binding.sourceSize) }
    XCTAssertEqual(replay.extent,input.extent) // replay consumes only savedcircles, never detector
  }

}
