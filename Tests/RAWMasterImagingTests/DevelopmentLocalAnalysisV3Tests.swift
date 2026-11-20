import XCTest
import AppKit
import CoreImage
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentLocalAnalysisV3Tests: XCTestCase {
  private struct Fixture {
    let root:URL,native:PreviewNativeSource,binding:DevelopmentLocalEditSourceBinding
  }
  private func fixture(mark: Bool = true) throws -> Fixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-local-analysis-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let b=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:96,bitsPerSample:8,samplesPerPixel:4,
      hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:512,bitsPerPixel:32))
    for y in 0..<96 { for x in 0..<128 {
      let i=y*512+x*4,red=mark && (x-64)*(x-64)+(y-48)*(y-48)<5
      b.bitmapData![i]=red ? 230:100;b.bitmapData![i+1]=red ? 25:100;b.bitmapData![i+2]=red ? 20:100;b.bitmapData![i+3]=255
    } }
    let data=try XCTUnwrap(b.representation(using:.png,properties:[:])),url=root.appendingPathComponent("source.png");try data.write(to:url)
    let hash=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    return .init(root:root,native:try .init(capture:url,byteCount:Int64(data.count),artifact:false,memoryLimit:512),
      binding:.init(sourceContentID:hash,exifOrientation:1,orientedWidth:128,orientedHeight:96))
  }
  private func request(_ fixture:Fixture,recipe:DevelopmentRecipe = .init(adjustmentsV3:.init()),operation:DevelopmentAnalysisOperation) throws -> DevelopmentAnalysisRequest {
    let tool:DevelopmentLocalTool
    switch operation { case .retouchSource:tool = .retouch;case .redEyeAt,.redEyeAutomatic:tool = .redEye;default:throw DevelopmentPreviewError.invalidRequest }
    let p=try recipe.prospectiveLocalInputV1(source:fixture.binding,sourceGeneration:3,
      decoderContractFingerprint:fixture.native.localDecoderContractFingerprint,targetTool:tool)
    return .init(preview:.init(sessionID:.init(),sourceGeneration:3,consumerID:.init(),role:.primary,revision:7,recipe:p.analysisRecipe,quality:.detail),
      expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,operation:operation,
      presentedRecipeFingerprint:p.presentedRecipeFingerprint,localInputV1:p.input)
  }
  private var stroke:DevelopmentStroke { .init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:0.05) }
  func testExplicitDonorActuallyChangesPixelsAndCoreCommitsOneProspectiveBatch() throws {
    let f=try fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let original=DevelopmentRecipe(),r=try request(f,recipe:original,operation:.retouchSource(stroke:stroke,explicitDonor:.init(x:0.7,y:0.5)))
    let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
    try DevelopmentLocalAnalysisV3.validateResult(request:r,result:result,sourceBinding:f.binding,decoderContractFingerprint:f.native.localDecoderContractFingerprint)
    let receipt=try XCTUnwrap(result.localPixelAttestation);XCTAssertGreaterThan(receipt.maximumRGBDifference,0);XCTAssertEqual(receipt.maximumAlphaDifference,0)
    guard case .local(let batch)=result.value else { return XCTFail() }
    let committed=try original.applying(.appendResolvedLocalBatch(batch),context:.init(source:f.binding,sourceGeneration:3,analysisStage:.workingImageBeforeGeometry,localInputV1:r.localInputV1))
    XCTAssertEqual(committed.schemaVersion,3);XCTAssertEqual(committed.adjustmentsV3?.localEdits.operations.count,1)
    XCTAssertEqual(committed.adjustmentsV3?.localEdits.retouchEnabled,true)
    let replay=try DevelopmentRendererV3.develop(f.native.capture,recipe:committed,applyGeometry:false)
    XCTAssertEqual(replay.sourceSize,CGSize(width:128,height:96))
  }
  func testAutomaticDonorUsesFixed96CandidateOrderAndSavesResolvedPoint() throws {
    let f=try fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let r=try request(f,operation:.retouchSource(stroke:stroke,explicitDonor:nil))
    let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
    guard case .local(let batch)=result.value,case .append(let operations)=batch.resolution else { return XCTFail("No actual donor/effect") }
    let donor=try XCTUnwrap(operations.first?.sourceSample)
    XCTAssertEqual(operations.count,1);XCTAssertNil(operations[0].patch)
    XCTAssertNotEqual(donor,stroke.points[0].position)
    XCTAssertGreaterThan(try XCTUnwrap(result.localPixelAttestation).maximumRGBDifference,0)
  }
  func testUniformAutoAndExplicitZeroOffsetDoNotPromoteOrEnable() throws {
    let f=try fixture(mark:false);defer { try? FileManager.default.removeItem(at:f.root) }
    let original=DevelopmentRecipe()
    for donor in [DevelopmentSourcePoint?.none,.some(.init(x:0.5,y:0.5))] {
      let r=try request(f,recipe:original,operation:.retouchSource(stroke:stroke,explicitDonor:donor))
      let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
      guard case .local(let batch)=result.value,case .noResult=batch.resolution else { return XCTFail() }
      let after=try original.applying(.appendResolvedLocalBatch(batch),context:.init(source:f.binding,sourceGeneration:3,analysisStage:.workingImageBeforeGeometry,localInputV1:r.localInputV1))
      XCTAssertEqual(after,original);XCTAssertEqual(try EditingFingerprint.of(after),try EditingFingerprint.of(original))
    }
  }
  func testManualRedEyeActualEffectAndOrdinaryNoRedNoResult() throws {
    for mark in [true,false] {
      let f=try fixture(mark:mark);defer { try? FileManager.default.removeItem(at:f.root) }
      let r=try request(f,operation:.redEyeAt(sourcePoint:.init(x:0.5,y:0.5),radiusInShortEdge:0.05,strength:1))
      let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
      guard case .local(let batch)=result.value else { return XCTFail() }
      if mark { guard case .append(let ops)=batch.resolution else { return XCTFail() };XCTAssertEqual(ops.first?.tool,.redEye) }
      else { XCTAssertEqual(batch.resolution,.noResult(.noRedPixels)) }
    }
  }
  func testWrongActualDecoderAndStalePrefixRejectBeforeResultAcceptance() throws {
    let f=try fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let r=try request(f,operation:.redEyeAt(sourcePoint:.init(x:0.5,y:0.5),radiusInShortEdge:0.05,strength:1))
    let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
    XCTAssertThrowsError(try DevelopmentLocalAnalysisV3.validateResult(request:r,result:result,sourceBinding:f.binding,decoderContractFingerprint:String(repeating:"0",count:64)))
    var changed=r.preview.recipe;changed.adjustmentsV3!.light.enabled=true;changed.adjustmentsV3!.light.brightness=0.1
    let stale=DevelopmentAnalysisRequest(preview:.init(sessionID:r.preview.sessionID,sourceGeneration:3,consumerID:r.preview.consumerID,role:.primary,revision:7,recipe:changed,quality:.detail),
      expectedRecipeFingerprint:try EditingFingerprint.of(changed),stage:.workingImageBeforeGeometry,operation:r.operation,localInputV1:r.localInputV1)
    XCTAssertThrowsError(try DevelopmentLocalAnalysisV3.projection(stale))
  }
  func testProspectiveReenabledPrefixMatchesSingleAtomicAppendAndNoGeometrySampling() throws {
    let f=try fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    var p=DevelopmentAdjustmentsV3()
    p.geometry = .init(version:.projectiveV3_1,straightenDegrees:7,verticalPerspective:5,crop:.init(x:0.1,y:0.1,width:0.8,height:0.8))
    p.localEdits = .init(sourceBinding:f.binding,retouchEnabled:false,operations:[.init(sourceContentID:f.binding.sourceContentID,tool:.retouch,
      stroke:.init(points:[.init(position:.init(x:0.3,y:0.4))],radiusInShortEdge:0.03),sourceSample:.init(x:0.4,y:0.4))])
    let original=DevelopmentRecipe(adjustmentsV3:p),r=try request(f,recipe:original,operation:.redEyeAt(sourcePoint:.init(x:0.5,y:0.5),radiusInShortEdge:0.05,strength:1))
    let projection=try DevelopmentLocalAnalysisV3.projection(r)
    XCTAssertFalse(projection.recipe.adjustmentsV3!.localEdits.retouchEnabled)
    XCTAssertTrue(projection.recipe.adjustmentsV3!.localEdits.redEyeEnabled)
    XCTAssertEqual(projection.recipe.adjustmentsV3!.geometry,p.geometry)
    let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
    guard case .local(let batch)=result.value else { return XCTFail() }
    let after=try original.applying(.appendResolvedLocalBatch(batch),context:.init(source:f.binding,sourceGeneration:3,analysisStage:.workingImageBeforeGeometry,localInputV1:r.localInputV1))
    XCTAssertEqual(after.adjustmentsV3?.localEdits.operations.count,2);XCTAssertFalse(after.adjustmentsV3!.localEdits.retouchEnabled)
    XCTAssertEqual(after.adjustmentsV3?.geometry,p.geometry)
  }
  func testFirstPromotedLegacyPreparationUsesFutureCanonicalI0AndOrdinaryDelegateRemainsExact() throws {
    let f=try fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let original=DevelopmentRecipe(exposureEV:0.3),r=try request(f,recipe:original,operation:.retouchSource(stroke:stroke,explicitDonor:.init(x:0.7,y:0.5)))
    let p=try DevelopmentLocalAnalysisV3.projection(r)
    let ordinary=try DevelopmentRendererV3.develop(f.native.capture,recipe:p.analysisRecipe,applyGeometry:false)
    XCTAssertTrue(ordinary.graphDescriptor.hasSuffix("/exact-legacy"))
    let prepared=try DevelopmentRendererV3.develop(f.native.capture,recipe:p.recipe,applyGeometry:false,
      localDecoderContractFingerprint:f.native.localDecoderContractFingerprint,preparingLocal:true)
    XCTAssertFalse(prepared.graphDescriptor.hasSuffix("/exact-legacy"))
    let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
    XCTAssertEqual(result.localPixelAttestation?.preparedGraphDescriptor,prepared.graphDescriptor)
    XCTAssertEqual(result.localPixelAttestation?.preparationBranchVersion,"canonical-local-I0-v1/no-exact-legacy-delegate")
    guard case .local(let batch)=result.value else { return XCTFail() }
    let after=try original.applying(.appendResolvedLocalBatch(batch),context:.init(source:f.binding,sourceGeneration:3,analysisStage:.workingImageBeforeGeometry,localInputV1:r.localInputV1))
    let appended=try DevelopmentRendererV3.develop(f.native.capture,recipe:after,applyGeometry:false)
    var a=[SIMD4<Float>](),b=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(prepared.image,rect:prepared.image.extent,context:DevelopmentColorEngineV3.context) { a=Array($0) }
    try DevelopmentLocalEngineV3.read(appended.image,rect:appended.image.extent,context:DevelopmentColorEngineV3.context) { b=Array($0) }
    // Far outside the target feather, final append must evaluate precisely the prepared I0.
    for y in 0..<96 { for x in 0..<128 where x<55 || x>73 || y<39 || y>57 { XCTAssertEqual(a[y*128+x],b[y*128+x]) } }
    XCTAssertNotEqual(a,b)
    XCTAssertEqual(try EditingFingerprint.of(original),r.presentedRecipeFingerprint)
  }

  func testCancellationRevokesPreparationWithoutProducingBatchOrMutatingRecipe() throws {
    let f=try fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let original=DevelopmentRecipe(),r=try request(f,recipe:original,operation:.retouchSource(stroke:stroke,explicitDonor:nil))
    let cancellation=DevelopmentAnalysisCancellation();cancellation.cancel()
    XCTAssertThrowsError(try f.native.analyze(r,sourceContentID:f.binding.sourceContentID,cancellation:cancellation)) { error in
      guard case DevelopmentPreviewError.superseded=error else { return XCTFail("Wrong cancellation error") }
    }
    XCTAssertEqual(original.schemaVersion,1)
  }

  func testWholeRedEyeAutomaticNoResultKeepsDisabledOriginalBytesAndDedicatedAttestation() throws {
    let f=try fixture(mark:false);defer { try? FileManager.default.removeItem(at:f.root) }
    let original=DevelopmentRecipe(),r=try request(f,recipe:original,operation:.redEyeAutomatic)
    let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
    try DevelopmentLocalAnalysisV3.validateResult(request:r,result:result,sourceBinding:f.binding,decoderContractFingerprint:f.native.localDecoderContractFingerprint)
    XCTAssertEqual(result.localPixelAttestation?.operatorVersion,DevelopmentRedEyeAutomaticV3.version)
    XCTAssertEqual(result.samplingVersion,DevelopmentRedEyeAutomaticV3.version)
    guard case .local(let batch)=result.value,case .noResult = batch.resolution else { return XCTFail("No invented corrected eyes in neutral fixture") }
    let after=try original.applying(.appendResolvedLocalBatch(batch),context:.init(source:f.binding,sourceGeneration:3,analysisStage:.workingImageBeforeGeometry,localInputV1:r.localInputV1))
    XCTAssertEqual(after,original);XCTAssertEqual(try EditingFingerprint.of(after),try EditingFingerprint.of(original))
    XCTAssertFalse(after.adjustmentsV3?.localEdits.redEyeEnabled ?? false)
  }
  func testWholeRedEyeAutomaticOldSourceGenerationAndCancelledFlagRejectWithoutCommit() throws {
    let f=try fixture(mark:false);defer { try? FileManager.default.removeItem(at:f.root) }
    let original=DevelopmentRecipe(),r=try request(f,recipe:original,operation:.redEyeAutomatic)
    let result=try f.native.analyze(r,sourceContentID:f.binding.sourceContentID)
    guard case .local(let batch)=result.value else { return XCTFail() }
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(batch),context:.init(source:f.binding,sourceGeneration:4,analysisStage:.workingImageBeforeGeometry,localInputV1:r.localInputV1)))
    let cancellation=DevelopmentAnalysisCancellation();cancellation.cancel()
    XCTAssertThrowsError(try f.native.analyze(r,sourceContentID:f.binding.sourceContentID,cancellation:cancellation))
    XCTAssertEqual(try EditingFingerprint.of(original),r.presentedRecipeFingerprint)
    let generic=try request(f,recipe:original,operation:.redEyeAutomatic)
    let wrong=DevelopmentAnalysisRequest(preview:generic.preview,expectedRecipeFingerprint:generic.expectedRecipeFingerprint,
      stage:.workingImageBeforeGeometry,operation:.automatic(.redEye))
    XCTAssertThrowsError(try f.native.analyze(wrong,sourceContentID:f.binding.sourceContentID))
  }

}
