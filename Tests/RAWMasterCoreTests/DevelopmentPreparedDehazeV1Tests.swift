import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentPreparedDehazeV1Tests:XCTestCase {
  private let sourceHash=String(repeating:"a",count:64),decoderHash=String(repeating:"d",count:64)
  private var source:DevelopmentLocalEditSourceBinding { .init(sourceContentID:sourceHash,exifOrientation:8,orientedWidth:100,orientedHeight:120) }
  private func actual(_ generation:UInt64=7,decoder:String?=nil)->DevelopmentDehazeContextV1 {
    .init(source:source,sourceGeneration:generation,decoderContractFingerprint:decoder ?? decoderHash)
  }
  private func context(_ c:DevelopmentDehazeContextV1?=nil,local:DevelopmentLocalInputV1?=nil)->DevelopmentAdjustmentCommandContext {
    let c=c ?? actual()
    return .init(source:c.source,sourceGeneration:c.sourceGeneration,analysisStage:.workingImageBeforeGeometry,localInputV1:local,dehazeContextV1:c)
  }
  private func resolved(_ recipe:DevelopmentRecipe,context c:DevelopmentDehazeContextV1?=nil,noResult:Bool=false)throws->DevelopmentResolvedDehazeV1 {
    let p=try recipe.prospectiveDehazeInputV1(context:c ?? actual())
    let a=DevelopmentDehazeAirlightV1(red:0.5,green:0.75,blue:1)
    let prepared=DevelopmentPreparedDehazeV1(sourceBinding:p.input.context.source,inputFingerprint:p.input.inputFingerprint,airlight:a)
    return .init(binding:.init(sourceContentID:p.input.context.source.sourceContentID,sourceGeneration:p.input.context.sourceGeneration,
      expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),presentedRecipeFingerprint:p.presentedRecipeFingerprint,
      input:p.input,resolution:noResult ? .noResult(.insufficientVisibleSamples):.prepared(prepared))
  }
  private func active()throws->DevelopmentRecipe {
    let r=DevelopmentRecipe(adjustmentsV3:.init())
    return try r.applying(.applyPreparedDehaze(resolved(r),wantedAmount:40),context:context())
  }
  private func bytes<T:Encodable>(_ value:T)throws->Data {
    let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)
  }
  func testAbsentPreparedRetainsOldAdvancedWireBytes()throws {
    let golden=#"{"clarity":{"amount":0,"enabled":false},"dehaze":{"amount":0,"enabled":false},"texture":{"amount":0,"enabled":false},"version":1}"#
    XCTAssertEqual(String(decoding:try bytes(DevelopmentAdvancedDetailV3()),as:UTF8.self),golden)
    let r=DevelopmentRecipe(adjustmentsV3:.init())
    XCTAssertFalse(String(decoding:try bytes(r),as:UTF8.self).contains("preparedDehaze"))
    let old=DevelopmentRecipe(exposureEV:0.25)
    XCTAssertEqual(try bytes(old),try bytes(JSONDecoder().decode(DevelopmentRecipe.self,from:bytes(old))))
    XCTAssertEqual(try bytes(old.promotingToV2()),try bytes(JSONDecoder().decode(DevelopmentRecipe.self,from:bytes(old.promotingToV2()))))
  }
  func testStrictPreparedWireAndF32Domain()throws {
    let r=try active(),data=try bytes(r)
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(data),r)
    let old=#"{"clarity":{"amount":0,"enabled":false},"dehaze":{"amount":0,"enabled":false},"texture":{"amount":0,"enabled":false},"version":1,"preparedDehaze":null}"#
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentAdvancedDetailV3.self,from:Data(old.utf8)))
    let p=r.adjustmentsV3!.advancedDetail.preparedDehaze!
    var object=try JSONSerialization.jsonObject(with:bytes(p)) as! [String:Any]
    object["future"]=1
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentPreparedDehazeV1.self,from:JSONSerialization.data(withJSONObject:object)))
    object.removeValue(forKey:"future");object["algorithmVersion"]=3
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentPreparedDehazeV1.self,from:JSONSerialization.data(withJSONObject:object)))
    for bad in [Double.nan,Double.infinity,0,17,0.1] {
      XCTAssertThrowsError(try DevelopmentDehazeAirlightV1(red:bad,green:1,blue:1).validate())
    }
    XCTAssertNoThrow(try DevelopmentDehazeAirlightV1(red:Double(Float(0.1)),green:1,blue:16).validate())
  }
  func testExplicitV2UsesExistingWireKeysAndSeparateInputFingerprint() throws {
    let before=DevelopmentRecipe(adjustmentsV3:.init()),c=actual()
    let original=try before.prospectiveDehazeInputV1(context:c)
    let v2=try before.prospectiveDehazeInputV1(context:c,algorithm:.positiveColorGuideV2)
    XCTAssertEqual(original.input.algorithm,.v1)
    XCTAssertEqual(original.samplingRecipe,v2.samplingRecipe)
    XCTAssertEqual(original.input.dependencyRecipeFingerprint,v2.input.dependencyRecipeFingerprint)
    struct FrozenV1Identity: Encodable {
      let sourceBinding: DevelopmentLocalEditSourceBinding
      let inputStageVersion: Int
      let decoderContractFingerprint: String
      let dependencyRecipeFingerprint: String
      let algorithmVersion: Int
    }
    XCTAssertEqual(original.input.inputFingerprint,try EditingFingerprint.of(FrozenV1Identity(sourceBinding:c.source,inputStageVersion:1,
      decoderContractFingerprint:c.decoderContractFingerprint,dependencyRecipeFingerprint:original.input.dependencyRecipeFingerprint,algorithmVersion:1)))
    XCTAssertNotEqual(original.input.inputFingerprint,v2.input.inputFingerprint)

    let legacy=try active(),air=DevelopmentDehazeAirlightV1(red:0.5,green:0.75,blue:1)
    func resolvedV2(_ algorithmVersion:Int) -> DevelopmentResolvedDehazeV1 {
      .init(binding:.init(sourceContentID:c.source.sourceContentID,sourceGeneration:c.sourceGeneration,
        expectedRecipeFingerprint:v2.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),
        presentedRecipeFingerprint:v2.presentedRecipeFingerprint,input:v2.input,
        resolution:.prepared(.init(sourceBinding:c.source,inputFingerprint:v2.input.inputFingerprint,
                                   airlight:air,algorithmVersion:algorithmVersion)))
    }
    let applied=try before.applying(.applyPreparedDehaze(resolvedV2(2),wantedAmount:40),context:context())
    let prepared=try XCTUnwrap(applied.adjustmentsV3?.advancedDetail.preparedDehaze)
    XCTAssertEqual(prepared.algorithmVersion,2)
    XCTAssertEqual(prepared.inputFingerprint,v2.input.inputFingerprint)
    XCTAssertEqual(try applied.dehazePreparationStatusV1(context:actual(8)),.ready)
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(bytes(applied)),applied)
    let legacyWire=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes(legacy.adjustmentsV3!.advancedDetail.preparedDehaze!)) as? [String:Any])
    let newWire=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes(prepared)) as? [String:Any])
    XCTAssertEqual(Set(legacyWire.keys),Set(newWire.keys))
    XCTAssertNotEqual(legacyWire["inputFingerprint"] as? String,newWire["inputFingerprint"] as? String)
    XCTAssertThrowsError(try before.applying(.applyPreparedDehaze(resolvedV2(1),wantedAmount:40),context:context()))
    XCTAssertThrowsError(try before.applying(.applyPreparedDehaze(resolvedV2(2),wantedAmount:40),context:context(actual(8))))
    XCTAssertEqual(try before.applying(.applyPreparedDehaze(resolvedV2(2),wantedAmount:0),context:context()),before)
    let negative=try applied.applying(.setParameters(.dehaze(.init(enabled:true,amount:-20))),context:context())
    XCTAssertEqual(negative.adjustmentsV3!.advancedDetail.preparedDehaze,prepared)
    XCTAssertEqual(try negative.dehazePreparationStatusV1(context:c),.ready)
  }
  func testProjectionExcludesOnlyDownstreamAndGeneration()throws {
    let r=try active(),p=try r.prospectiveDehazeInputV1(context:actual())
    var changed=r;changed.adjustmentsV3!.geometry.straightenDegrees=7
    changed.adjustmentsV3!.advancedDetail.dehaze.amount = -70
    changed.adjustmentsV3!.advancedDetail.dehaze.enabled=false
    changed.adjustmentsV3!.localEdits.redEyeEnabled=true
    let q=try changed.prospectiveDehazeInputV1(context:actual(8))
    XCTAssertEqual(p.input.inputFingerprint,q.input.inputFingerprint)
    XCTAssertNotEqual(p.input.context,q.input.context)
    XCTAssertEqual(q.samplingRecipe.adjustmentsV3!.geometry.version,.adjustV3)
    XCTAssertNil(q.samplingRecipe.adjustmentsV3!.advancedDetail.preparedDehaze)
    XCTAssertEqual(q.samplingRecipe.adjustmentsV3!.localEdits,.init())
    XCTAssertEqual(try r.dehazePreparationStatusV1(context:actual(8)),.ready)
    XCTAssertEqual(try r.dehazePreparationStatusV1(context:actual(8,decoder:String(repeating:"e",count:64))),.stale)
    changed.adjustmentsV3!.advancedDetail.texture.amount=20 // remembered off parameters are dependencies too.
    XCTAssertNotEqual(p.input.inputFingerprint,try changed.prospectiveDehazeInputV1(context:actual()).input.inputFingerprint)
  }
  func testCompoundPromotionNoResultAndZeroAreSingleUnchangedValues()throws {
    for original in [DevelopmentRecipe(exposureEV:0.25),try DevelopmentRecipe().promotingToV2(),DevelopmentRecipe(adjustmentsV3:.init())] {
      let before=try bytes(original)
      let none=try original.applying(.applyPreparedDehaze(resolved(original,noResult:true),wantedAmount:35),context:context())
      let zero=try original.applying(.applyPreparedDehaze(resolved(original),wantedAmount:0),context:context())
      XCTAssertEqual(try bytes(none),before);XCTAssertEqual(try bytes(zero),before)
      let success=try original.applying(.applyPreparedDehaze(resolved(original),wantedAmount:-35),context:context())
      XCTAssertEqual(success.schemaVersion,3);XCTAssertEqual(success.adjustmentsV3!.advancedDetail.dehaze,.init(enabled:true,amount:-35))
      XCTAssertEqual(try success.dehazePreparationStatusV1(context:actual()),.ready)
    }
  }
  func testCurrentContextCannotBeReconstructedFromResultAndFullDraftFencesHold()throws {
    let original=DevelopmentRecipe(adjustmentsV3:.init()),result=try resolved(original)
    XCTAssertThrowsError(try original.applying(.applyPreparedDehaze(result,wantedAmount:30)))
    XCTAssertThrowsError(try original.applying(.applyPreparedDehaze(result,wantedAmount:30),context:context(actual(8))))
    XCTAssertThrowsError(try original.applying(.applyPreparedDehaze(result,wantedAmount:30),context:context(actual(decoder:String(repeating:"e",count:64)))))
    var geometry=original;geometry.adjustmentsV3!.geometry.straightenDegrees=1
    XCTAssertThrowsError(try geometry.applying(.applyPreparedDehaze(result,wantedAmount:30),context:context()))
    var upstream=original;upstream.adjustmentsV3!.light.exposure=1
    XCTAssertThrowsError(try upstream.applying(.applyPreparedDehaze(result,wantedAmount:30),context:context()))
  }
  func testEveryUpstreamMutationPausesAndPreservesAmountWithoutContext()throws {
    let r=try active()
    let commands:[DevelopmentAdjustmentCommand] = [
      .setParameters(.light(.init(enabled:true,contrast:0.2))),.setEnabled(.color,true),.reset(.light),
      .setParameters(.texture(.init(enabled:true,amount:15))),.setParameters(.clarity(.init(enabled:true,amount:-15))),
      .setLegacyBasis(.init(version:.v1,exposureEV:0.5,whiteBalance:.asShot)),
      .setParameters(.whiteBalance(.init(enabled:true,adjustment:.temperatureTint(temperature:6000,tint:0))))
    ]
    for command in commands {
      // Reset must actually change a dependency, rather than being a no-op.
      var input=r;if case .reset(.light)=command { input.adjustmentsV3!.light.contrast=0.2 }
      let changed=try input.applying(command)
      XCTAssertNil(changed.adjustmentsV3!.advancedDetail.preparedDehaze,"\(command)")
      XCTAssertFalse(changed.adjustmentsV3!.advancedDetail.dehaze.enabled)
      XCTAssertEqual(changed.adjustmentsV3!.advancedDetail.dehaze.amount,40)
    }
    XCTAssertEqual(r.adjustmentsV3!.advancedDetail.dehaze.amount,40) // prior undo value intact.
  }
  func testGeometryAndLocalEarlyReturnRetainOnlyCurrentlyValidPreparation()throws {
    let r=try active(),geometry=DevelopmentGeometryV3(straightenDegrees:2)
    let changed=try r.applying(.setGeometry(geometry),context:context())
    XCTAssertEqual(changed.adjustmentsV3!.advancedDetail,r.adjustmentsV3!.advancedDetail)
    XCTAssertThrowsError(try r.applying(.setGeometry(geometry)))
    let stale=try r.applying(.setGeometry(geometry),context:context(actual(decoder:String(repeating:"e",count:64))))
    XCTAssertNil(stale.adjustmentsV3!.advancedDetail.preparedDehaze);XCTAssertFalse(stale.adjustmentsV3!.advancedDetail.dehaze.enabled)
    let local=try r.prospectiveLocalInputV1(source:source,sourceGeneration:7,decoderContractFingerprint:decoderHash,targetTool:.redEye)
    let eye=DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.redEye,stroke:.init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:0.02))
    let batch=DevelopmentResolvedLocalBatch(binding:.init(sourceContentID:sourceHash,sourceGeneration:7,expectedRecipeFingerprint:local.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),presentedRecipeFingerprint:local.presentedRecipeFingerprint,input:local.input,resolution:.append([eye]))
    let appended=try r.applying(.appendResolvedLocalBatch(batch),context:context(local:local.input))
    XCTAssertEqual(appended.adjustmentsV3!.advancedDetail,r.adjustmentsV3!.advancedDetail)
    let paused=try r.applying(.appendResolvedLocalBatch(batch),context:context(actual(decoder:String(repeating:"e",count:64)),local:local.input))
    XCTAssertNil(paused.adjustmentsV3!.advancedDetail.preparedDehaze);XCTAssertFalse(paused.adjustmentsV3!.advancedDetail.dehaze.enabled)
  }
  func testAnalysisAndPromotionUseTheSameFinalizer()throws {
    let r=try active()
    let binding=DevelopmentAnalysisBinding(sourceContentID:sourceHash,sourceGeneration:7,
      expectedRecipeFingerprint:try EditingFingerprint.of(r),stage:.workingImageBeforeGeometry)
    let analysis=DevelopmentResolvedAdjustmentCommand(binding:binding,purpose:.summary(.color,amount:0.5),
      parameters:[.color(.init(enabled:true,saturation:0.25))])
    let changed=try r.applying(.applyAnalysis(analysis),context:context())
    XCTAssertNil(changed.adjustmentsV3!.advancedDetail.preparedDehaze)
    XCTAssertFalse(changed.adjustmentsV3!.advancedDetail.dehaze.enabled)
    XCTAssertEqual(changed.adjustmentsV3!.advancedDetail.dehaze.amount,40)
    let legacy=DevelopmentRecipe(exposureEV:0.25)
    XCTAssertEqual(try legacy.applying(.promoteToV3),try legacy.promotingToV3())
    XCTAssertEqual(try r.applying(.promoteToV3),r) // identical command is not a mutation.
  }
  func testSourceChangesAreStaleButReopenedGenerationIsReady()throws {
    let r=try active()
    let differentSource=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"b",count:64),exifOrientation:8,orientedWidth:100,orientedHeight:120)
    let c=DevelopmentDehazeContextV1(source:differentSource,sourceGeneration:8,decoderContractFingerprint:decoderHash)
    XCTAssertEqual(try r.dehazePreparationStatusV1(context:c),.stale)
    XCTAssertEqual(try r.dehazePreparationStatusV1(context:actual(99)),.ready)
    let p=try r.prospectiveDehazeInputV1(context:actual())
    XCTAssertNotEqual(p.input.inputFingerprint,try r.prospectiveDehazeInputV1(context:c).input.inputFingerprint)
    XCTAssertThrowsError(try r.prospectiveDehazeInputV1(context:actual(0)))
    XCTAssertThrowsError(try r.prospectiveDehazeInputV1(context:actual(decoder:"not-a-sha")))
    XCTAssertThrowsError(try r.applying(.applyPreparedDehaze(resolved(r),wantedAmount:.nan),context:context()))
  }
  func testDirectActivationRequiresFreshPreparationAndResetClearsIt()throws {
    let blank=DevelopmentRecipe(adjustmentsV3:.init())
    XCTAssertThrowsError(try blank.applying(.setParameters(.dehaze(.init(enabled:true,amount:20))),context:context()))
    let r=try active()
    XCTAssertThrowsError(try r.applying(.setParameters(.dehaze(.init(enabled:true,amount:30)))))
    XCTAssertThrowsError(try r.applying(.setParameters(.dehaze(.init(enabled:true,amount:30))),context:context(actual(decoder:String(repeating:"e",count:64)))))
    XCTAssertEqual(try r.applying(.setParameters(.dehaze(.init(enabled:true,amount:30))),context:context()).adjustmentsV3!.advancedDetail.dehaze.amount,30)
    let reset=try r.applying(.reset(.dehaze))
    XCTAssertEqual(reset.adjustmentsV3!.advancedDetail.dehaze,.init());XCTAssertNil(reset.adjustmentsV3!.advancedDetail.preparedDehaze)
    XCTAssertEqual(try r.applying(.resetAll),blank)
  }
  private func resolvedVersion(_ recipe:DevelopmentRecipe,_ algorithm:DevelopmentDehazeAlgorithm,
                               context c:DevelopmentDehazeContextV1?=nil)throws->DevelopmentResolvedDehazeV1 {
    let p=try recipe.prospectiveDehazeInputV1(context:c ?? actual(),algorithm:algorithm)
    return .init(binding:.init(sourceContentID:p.input.context.source.sourceContentID,sourceGeneration:p.input.context.sourceGeneration,
      expectedRecipeFingerprint:p.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),presentedRecipeFingerprint:p.presentedRecipeFingerprint,
      input:p.input,resolution:.prepared(.init(sourceBinding:p.input.context.source,inputFingerprint:p.input.inputFingerprint,
        airlight:.init(red:0.5,green:0.75,blue:1),algorithmVersion:algorithm.rawValue)))
  }
  func testDehazeSelectionWireIsOptionalStrictAndPreparedTakesPriority()throws {
    let old=try active(),encoded=try bytes(old)
    XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("dehazeAlgorithmVersion"))
    XCTAssertEqual(try bytes(DevelopmentRecipe.decodeJSON(encoded)),encoded)
    var detail=old.adjustmentsV3!.advancedDetail
    detail.dehazeAlgorithmVersion=2
    XCTAssertEqual(detail.selectedDehazeAlgorithm,.v1,"Actual existing preparation is authoritative")
    detail.preparedDehaze=nil
    XCTAssertEqual(detail.selectedDehazeAlgorithm,.positiveColorGuideV2)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentAdvancedDetailV3.self,from:bytes(detail)),detail)
    var object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes(detail)) as? [String:Any])
    let invalidValues:[Any]=[NSNull(),0,3,"2"]
    for invalid in invalidValues {
      object["dehazeAlgorithmVersion"]=invalid
      XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentAdvancedDetailV3.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    XCTAssertEqual(DevelopmentAdvancedDetailV3(dehaze:.init(enabled:false,amount:-25)).selectedDehazeAlgorithm,.v1)
    XCTAssertNil(DevelopmentAdvancedDetailV3().selectedDehazeAlgorithm)
  }
  func testPausedDehazeSelectionSurvivesReopenWithoutImplicitVersionUpgrade()throws {
    for algorithm in [DevelopmentDehazeAlgorithm.v1,.positiveColorGuideV2] {
      let base=DevelopmentRecipe(adjustmentsV3:.init())
      let active=try base.applying(.applyPreparedDehaze(resolvedVersion(base,algorithm),wantedAmount:25),context:context())
      let paused=try active.applying(.setParameters(.light(.init(enabled:true,contrast:0.1))),context:context())
      XCTAssertNil(paused.adjustmentsV3!.advancedDetail.preparedDehaze)
      XCTAssertEqual(paused.adjustmentsV3!.advancedDetail.dehazeAlgorithmVersion,algorithm.rawValue)
      XCTAssertEqual(paused.adjustmentsV3!.advancedDetail.dehaze,.init(enabled:false,amount:25))
      let reopened=try DevelopmentRecipe.decodeJSON(bytes(paused))
      let again=try reopened.applying(.applyPreparedDehaze(resolvedVersion(reopened,algorithm),wantedAmount:-25),context:context())
      XCTAssertEqual(again.adjustmentsV3!.advancedDetail.preparedDehaze?.algorithmVersion,algorithm.rawValue)
      let other:DevelopmentDehazeAlgorithm=algorithm == .v1 ? .positiveColorGuideV2:.v1
      XCTAssertThrowsError(try reopened.applying(.applyPreparedDehaze(resolvedVersion(reopened,other),wantedAmount:25),context:context()))
      let staleContext=actual(8,decoder:String(repeating:"e",count:64))
      let sourcePaused=try active.applying(.setGeometry(.init(straightenDegrees:2)),context:context(staleContext))
      XCTAssertNil(sourcePaused.adjustmentsV3!.advancedDetail.preparedDehaze)
      XCTAssertEqual(sourcePaused.adjustmentsV3!.advancedDetail.selectedDehazeAlgorithm,algorithm)
      let regenerated=try sourcePaused.applying(.applyPreparedDehaze(resolvedVersion(sourcePaused,algorithm,context:staleContext),wantedAmount:25),context:context(staleContext))
      XCTAssertEqual(try regenerated.dehazePreparationStatusV1(context:staleContext),.ready)
    }
  }
  func testDehazeSelectionDoesNotPolluteSamplingAndResetAllowsNewVersion()throws {
    let base=DevelopmentRecipe(adjustmentsV3:.init())
    var selected=base;selected.adjustmentsV3!.advancedDetail.dehazeAlgorithmVersion=2
    let a=try base.prospectiveDehazeInputV1(context:actual(),algorithm:.positiveColorGuideV2)
    let b=try selected.prospectiveDehazeInputV1(context:actual(),algorithm:.positiveColorGuideV2)
    XCTAssertEqual(a.samplingRecipe,b.samplingRecipe);XCTAssertEqual(a.input,b.input)
    XCTAssertNotEqual(a.presentedRecipeFingerprint,b.presentedRecipeFingerprint,"Full draft authority still includes intent")
    let old=try active()
    let paused=try old.applying(.setParameters(.color(.init(enabled:true,saturation:0.1))),context:context())
    let reset=try paused.applying(.reset(.dehaze),context:context())
    XCTAssertNil(reset.adjustmentsV3!.advancedDetail.dehazeAlgorithmVersion)
    XCTAssertNil(reset.adjustmentsV3!.advancedDetail.preparedDehaze)
    XCTAssertNil(reset.adjustmentsV3!.advancedDetail.selectedDehazeAlgorithm)
    let upgraded=try reset.applying(.applyPreparedDehaze(resolvedVersion(reset,.positiveColorGuideV2),wantedAmount:25),context:context())
    XCTAssertEqual(upgraded.adjustmentsV3!.advancedDetail.preparedDehaze?.algorithmVersion,2)
    var oldMissing=base;oldMissing.adjustmentsV3!.advancedDetail.dehaze = .init(enabled:false,amount:25)
    XCTAssertThrowsError(try oldMissing.applying(.applyPreparedDehaze(resolvedVersion(oldMissing,.positiveColorGuideV2),wantedAmount:25),context:context()))
    XCTAssertNoThrow(try oldMissing.applying(.applyPreparedDehaze(resolvedVersion(oldMissing,.v1),wantedAmount:25),context:context()))
  }

}
