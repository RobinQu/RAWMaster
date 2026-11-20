import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentLocalResolvedV3Tests:XCTestCase {
  private let sourceHash=String(repeating:"a",count:64),decoder=String(repeating:"d",count:64)
  private var source:DevelopmentLocalEditSourceBinding { .init(sourceContentID:sourceHash,exifOrientation:1,orientedWidth:100,orientedHeight:100) }
  private func retouch(id:UUID=UUID(),point:DevelopmentSourcePoint = .init(x:0.3,y:0.3),donor:DevelopmentSourcePoint = .init(x:0.7,y:0.7))->DevelopmentLocalEdit {
    .init(id:id,sourceContentID:sourceHash,tool:.retouch,stroke:.init(points:[.init(position:point)],radiusInShortEdge:0.02),sourceSample:donor)
  }
  private func eye(id:UUID=UUID())->DevelopmentLocalEdit {
    .init(id:id,sourceContentID:sourceHash,tool:.redEye,stroke:.init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:0.02))
  }
  private func projection(_ recipe:DevelopmentRecipe,tool:DevelopmentLocalTool = .retouch)throws->DevelopmentLocalProjectionV1 {
    try recipe.prospectiveLocalInputV1(source:source,sourceGeneration:7,decoderContractFingerprint:decoder,targetTool:tool)
  }
  private func batch(_ p:DevelopmentLocalProjectionV1,_ result:DevelopmentLocalResolution)->DevelopmentResolvedLocalBatch {
    .init(binding:.init(sourceContentID:sourceHash,sourceGeneration:7,expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),
      presentedRecipeFingerprint:p.presentedRecipeFingerprint,input:p.input,resolution:result)
  }
  private func context(_ p:DevelopmentLocalProjectionV1)->DevelopmentAdjustmentCommandContext {
    .init(source:source,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry,localInputV1:p.input)
  }
  func testProspectiveEnableReplaysDisabledOldTargetAndPreservesOtherTool()throws {
    let old=retouch(),other=eye()
    let recipe=DevelopmentRecipe(adjustmentsV3:.init(localEdits:.init(sourceBinding:source,retouchEnabled:false,redEyeEnabled:true,operations:[old,other])))
    let before=try EditingFingerprint.of(recipe),p=try projection(recipe)
    XCTAssertFalse(recipe.adjustmentsV3!.localEdits.retouchEnabled)
    XCTAssertTrue(p.recipe.adjustmentsV3!.localEdits.retouchEnabled)
    XCTAssertTrue(p.recipe.adjustmentsV3!.localEdits.redEyeEnabled)
    XCTAssertEqual(p.input.prefixCount,2);XCTAssertEqual(p.analysisRecipe,recipe)
    XCTAssertEqual(p.expectedRecipeFingerprint,before);XCTAssertEqual(p.presentedRecipeFingerprint,before)
    let added=retouch(),result=try recipe.applying(.appendResolvedLocalBatch(batch(p,.append([added]))),context:context(p))
    XCTAssertEqual(result.adjustmentsV3!.localEdits.operations,[old,other,added])
    XCTAssertEqual(Array(result.adjustmentsV3!.localEdits.operations.prefix(2)),p.recipe.adjustmentsV3!.localEdits.operations)
    XCTAssertTrue(result.adjustmentsV3!.localEdits.retouchEnabled)
    XCTAssertTrue(result.adjustmentsV3!.localEdits.redEyeEnabled)
    XCTAssertEqual(try EditingFingerprint.of(recipe),before)
  }
  func testNoResultLeavesDisabledGroupAndLegacyBytesUntouched()throws {
    for original in [DevelopmentRecipe(exposureEV:0.25),DevelopmentRecipe(adjustmentsV3:.init())] {
      let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
      let bytes=try encoder.encode(original),p=try projection(original)
      let result=try original.applying(.appendResolvedLocalBatch(batch(p,.noResult(.noUsableDonor))),context:context(p))
      XCTAssertEqual(result,original);XCTAssertEqual(try encoder.encode(result),bytes)
      XCTAssertNil(result.adjustmentsV3?.localEdits.sourceBinding)
      XCTAssertEqual(p.expectedRecipeFingerprint,try EditingFingerprint.of(p.analysisRecipe))
      XCTAssertEqual(p.presentedRecipeFingerprint,try EditingFingerprint.of(original))
    }
  }
  func testSuccessfulLegacyPromotionAndWholeBatchAreOneValueTransaction()throws {
    let original=DevelopmentRecipe(exposureEV:0.5),p=try projection(original,tool:.redEye),a=eye(),b=eye()
    let result=try original.applying(.appendResolvedLocalBatch(batch(p,.append([a,b]))),context:context(p))
    XCTAssertEqual(original.schemaVersion,1);XCTAssertEqual(result.schemaVersion,3)
    XCTAssertEqual(result.adjustmentsV3!.legacyBasis?.exposureEV,0.5)
    XCTAssertEqual(result.adjustmentsV3!.localEdits.operations,[a,b])
    XCTAssertTrue(result.adjustmentsV3!.localEdits.redEyeEnabled)
  }
  func testGeometryDoesNotChangeStagePixelsButFullExpectedFingerprintStillFences()throws {
    let original=DevelopmentRecipe(adjustmentsV3:.init()),p=try projection(original),prepared=batch(p,.append([retouch()]))
    var changed=original;changed.adjustmentsV3!.geometry.straightenDegrees=1
    let q=try projection(changed)
    XCTAssertEqual(p.input.stageRecipeFingerprint,q.input.stageRecipeFingerprint)
    XCTAssertEqual(p.input.orderedPrefixFingerprint,q.input.orderedPrefixFingerprint)
    XCTAssertNotEqual(p.expectedRecipeFingerprint,q.expectedRecipeFingerprint)
    XCTAssertThrowsError(try changed.applying(.appendResolvedLocalBatch(prepared),context:context(q)))
    var color=original;color.adjustmentsV3!.color = .init(enabled:true,saturation:0.1)
    XCTAssertNotEqual(p.input.stageRecipeFingerprint,try projection(color).input.stageRecipeFingerprint)
  }
  func testSourceGenerationDecoderContextAndPrefixMismatchCannotCommit()throws {
    let original=DevelopmentRecipe(adjustmentsV3:.init()),p=try projection(original),prepared=batch(p,.append([retouch()]))
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(prepared)))
    let noInput=DevelopmentAdjustmentCommandContext(source:source,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry)
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(prepared),context:noInput))
    let wrongGeneration=DevelopmentAdjustmentCommandContext(source:source,sourceGeneration:8,analysisStage:.workingImageBeforeGeometry,localInputV1:p.input)
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(prepared),context:wrongGeneration))
    let q=try original.prospectiveLocalInputV1(source:source,sourceGeneration:7,decoderContractFingerprint:String(repeating:"e",count:64),targetTool:.retouch)
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(prepared),context:context(q)))
    var changed=original;changed.adjustmentsV3!.localEdits = .init(sourceBinding:source,operations:[retouch()])
    XCTAssertThrowsError(try changed.applying(.appendResolvedLocalBatch(prepared),context:context(try projection(changed))))
    var otherSource=source;otherSource.sourceContentID=String(repeating:"b",count:64)
    let wrongSource=DevelopmentAdjustmentCommandContext(source:otherSource,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry,localInputV1:p.input)
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(prepared),context:wrongSource))
  }
  func testDuplicateMixedToolUnresolvedPatchAndEmptyBatchAreAtomicFailures()throws {
    let original=DevelopmentRecipe(adjustmentsV3:.init()),p=try projection(original),a=retouch()
    for ops in [[],[a,a],[a,eye()]] {
      XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(batch(p,.append(ops))),context:context(p)))
      XCTAssertTrue(original.adjustmentsV3!.localEdits.operations.isEmpty)
    }
    var unresolved=a;unresolved.sourceSample=nil
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(batch(p,.append([unresolved]))),context:context(p)))
    var patch=a;patch.patch = .init(sha256:sourceHash,byteCount:4,sourceContentID:sourceHash)
    XCTAssertThrowsError(try original.applying(.appendResolvedLocalBatch(batch(p,.append([patch]))),context:context(p)))
    let existing=DevelopmentRecipe(adjustmentsV3:.init(localEdits:.init(sourceBinding:source,retouchEnabled:true,operations:[a])))
    let ep=try projection(existing)
    XCTAssertThrowsError(try existing.applying(.appendResolvedLocalBatch(batch(ep,.append([a]))),context:context(ep)))
    XCTAssertEqual(existing.adjustmentsV3!.localEdits.operations,[a])
  }
  func testClosedInputVersionHashAndFiniteStrokeFailures()throws {
    let p=try projection(DevelopmentRecipe(adjustmentsV3:.init()))
    let wrong=DevelopmentLocalInputV1(source:source,sourceGeneration:7,stageVersion:2,decoderContractFingerprint:decoder,
      stageRecipeFingerprint:p.input.stageRecipeFingerprint,targetTool:.retouch,prefixCount:0,orderedPrefixFingerprint:p.input.orderedPrefixFingerprint)
    XCTAssertThrowsError(try wrong.validate())
    XCTAssertThrowsError(try DevelopmentRecipe().prospectiveLocalInputV1(source:source,sourceGeneration:7,decoderContractFingerprint:"notSHA",targetTool:.retouch))
    var operation=retouch();operation.stroke.points[0].pressure = .nan
    XCTAssertThrowsError(try batch(p,.append([operation])).validate())
    operation=retouch();operation.stroke.radiusInShortEdge = .infinity
    XCTAssertThrowsError(try batch(p,.append([operation])).validate())
    operation=retouch();operation.stroke.strength=0
    XCTAssertThrowsError(try batch(p,.append([operation])).validate())
    operation=retouch(point:.init(x:0.5,y:0.5));operation.stroke.radiusInShortEdge=DevelopmentLocalEditLimits.minimumRadiusInShortEdge
    XCTAssertThrowsError(try batch(p,.append([operation])).validate()) // Support covers no source pixel center.
  }
  func testCheckedCostExactBoundaryClippedBoxesAndLargeSourceFailClosed()throws {
    let big=DevelopmentLocalEditSourceBinding(sourceContentID:sourceHash,exifOrientation:1,orientedWidth:8192,orientedHeight:8192)
    func wholeEye()->DevelopmentLocalEdit { .init(sourceContentID:sourceHash,tool:.redEye,stroke:.init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:1)) }
    let pair=DevelopmentLocalEditsV3(sourceBinding:big,redEyeEnabled:true,operations:[wholeEye(),wholeEye()])
    XCTAssertEqual(try DevelopmentLocalWorkEstimatorV1.estimate(pair),DevelopmentLocalWorkEstimatorV1.maximumWorkUnits)
    var tooMuch=pair;tooMuch.operations.append(wholeEye())
    XCTAssertThrowsError(try DevelopmentLocalWorkEstimatorV1.estimate(tooMuch)) { XCTAssertEqual($0 as? DevelopmentLocalPreparationError,.localWorkBudgetExceeded) }
    let small=DevelopmentLocalEditSourceBinding(sourceContentID:sourceHash,exifOrientation:1,orientedWidth:10,orientedHeight:10)
    let corner=DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.redEye,stroke:.init(points:[.init(position:.init(x:0,y:0))],radiusInShortEdge:0.1))
    XCTAssertEqual(try DevelopmentLocalWorkEstimatorV1.estimate(.init(sourceBinding:small,redEyeEnabled:true,operations:[corner])),2)
    let giant=DevelopmentLocalEditSourceBinding(sourceContentID:sourceHash,exifOrientation:1,orientedWidth:1_000_000,orientedHeight:1_000_000)
    XCTAssertThrowsError(try DevelopmentLocalWorkEstimatorV1.estimate(.init(sourceBinding:giant,redEyeEnabled:true,operations:[wholeEye()])))
    XCTAssertThrowsError(try DevelopmentLocalWorkEstimatorV1.checkedAdd(Int64.max,1))
    XCTAssertThrowsError(try DevelopmentLocalWorkEstimatorV1.checkedMultiply(Int64.max,2))
    XCTAssertThrowsError(try DevelopmentLocalWorkEstimatorV1.checkedAdd(-1,0))
    XCTAssertEqual(DevelopmentLocalWorkEstimatorV1.combinedUnionBytes,192*1024*1024)
  }
  func testManualBilinearWorkConstantsMixedPrefixExactLimitAndOnePixelOverflow() throws {
    XCTAssertEqual(DevelopmentLocalWorkEstimatorV1.retouchWorkUnitsPerPixel,212)
    XCTAssertEqual(DevelopmentLocalWorkEstimatorV1.redEyeWorkUnitsPerPixel,2)
    XCTAssertEqual(DevelopmentLocalWorkEstimatorV1.workContractVersion,"local-work-v2/source-bilinear4/retouch212/redEye2")
    XCTAssertEqual(DevelopmentLocalWorkEstimatorV1.maximumWorkUnits,256*1024*1024)
    let b=DevelopmentLocalEditSourceBinding(sourceContentID:sourceHash,exifOrientation:1,orientedWidth:1024,orientedHeight:1024)
    let full=DevelopmentStroke(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:1)
    let retouch=DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.retouch,stroke:full,sourceSample:.init(x:0.5,y:0.5))
    // (212 +22*2)*1024^2 =256Mi. No union-area discount for the repeated full boxes.
    var prefix=DevelopmentLocalEditsV3(sourceBinding:b,retouchEnabled:true,redEyeEnabled:true,
      operations:[retouch]+(0..<22).map { _ in DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.redEye,stroke:full) })
    XCTAssertEqual(try DevelopmentLocalWorkEstimatorV1.estimate(prefix),DevelopmentLocalWorkEstimatorV1.maximumWorkUnits)
    let corner=DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.redEye,
      stroke:.init(points:[.init(position:.init(x:0,y:0))],radiusInShortEdge:1.0/1024))
    prefix.operations.append(corner)
    XCTAssertThrowsError(try DevelopmentLocalWorkEstimatorV1.estimate(prefix)) {
      XCTAssertEqual($0 as? DevelopmentLocalPreparationError,.localWorkBudgetExceeded)
    }
    var disabled=prefix;disabled.retouchEnabled=false
    XCTAssertEqual(try DevelopmentLocalWorkEstimatorV1.estimate(disabled),22*2*1024*1024+2)
    var zero=retouch;zero.stroke.strength=0
    XCTAssertEqual(try DevelopmentLocalWorkEstimatorV1.estimate(.init(sourceBinding:b,retouchEnabled:true,operations:[zero])),0)
  }
  func testDonorSupportDoesNotWrapOrClampAndProjectionChecksReenabledWork()throws {
    let invalid=retouch(point:.init(x:0.5,y:0.5),donor:.init(x:0,y:0))
    XCTAssertThrowsError(try DevelopmentLocalWorkEstimatorV1.estimate(.init(sourceBinding:source,retouchEnabled:true,operations:[invalid]))) {
      XCTAssertEqual($0 as? DevelopmentLocalPreparationError,.donorOutOfBounds)
    }
    let legacyUnresolved=DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.retouch,stroke:.init(points:[.init(position:.init(x:0.3,y:0.3))],radiusInShortEdge:0.02))
    let disabled=DevelopmentRecipe(adjustmentsV3:.init(localEdits:.init(sourceBinding:source,operations:[legacyUnresolved])))
    try disabled.validate() // Old wire/metadata validation is unchanged.
    XCTAssertThrowsError(try projection(disabled)) { XCTAssertEqual($0 as? DevelopmentLocalPreparationError,.unresolvedOperation) }
    XCTAssertFalse(disabled.adjustmentsV3!.localEdits.retouchEnabled)
  }
  func testAggregateCapacityFailureCannotEnableOrAppendAnyOperation()throws {
    let old=(0..<DevelopmentLocalEditLimits.maximumOperations).map{_ in eye()}
    let recipe=DevelopmentRecipe(adjustmentsV3:.init(localEdits:.init(sourceBinding:source,redEyeEnabled:false,operations:old)))
    let p=try projection(recipe,tool:.redEye)
    XCTAssertThrowsError(try recipe.applying(.appendResolvedLocalBatch(batch(p,.append([eye()]))),context:context(p)))
    XCTAssertEqual(recipe.adjustmentsV3!.localEdits.operations,old)
    XCTAssertFalse(recipe.adjustmentsV3!.localEdits.redEyeEnabled)
  }
}
