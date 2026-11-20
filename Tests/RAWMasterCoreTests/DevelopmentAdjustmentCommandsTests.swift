import XCTest
import Foundation
@testable import RAWMasterCore

final class DevelopmentAdjustmentCommandsTests: XCTestCase {
  private let sourceHash = String(repeating:"a",count:64)
  private var source: DevelopmentLocalEditSourceBinding { .init(sourceContentID:sourceHash,exifOrientation:1,orientedWidth:100,orientedHeight:80) }
  private var context: DevelopmentAdjustmentCommandContext { .init(source:source,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry) }
  private func result(_ recipe: DevelopmentRecipe, generation: UInt64 = 7, stage: DevelopmentAnalysisStage = .workingImageBeforeGeometry,
                      sourceID: String? = nil, purpose: DevelopmentAnalysisPurpose = .automatic(.light),
                      parameters: [DevelopmentAdjustmentParametersV3] = [.light(.init(enabled:true,exposure:0.5))]) throws -> DevelopmentResolvedAdjustmentCommand {
    .init(binding:.init(sourceContentID:sourceID ?? sourceHash,sourceGeneration:generation,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),stage:stage),purpose:purpose,parameters:parameters)
  }
  private func edit(tool: DevelopmentLocalTool = .retouch) -> DevelopmentLocalEdit {
    .init(sourceContentID:sourceHash,tool:tool,stroke:.init(points:[.init(position:.init(x:0.4,y:0.5))],radiusInShortEdge:0.05))
  }
  func testNewCommandsRequireExplicitPromotionAndPromotionIsIdempotent() throws {
    let old = DevelopmentRecipe()
    XCTAssertThrowsError(try old.applying(.setEnabled(.light,true)))
    let v3 = try old.applying(.promoteToV3); XCTAssertEqual(v3.schemaVersion,3); XCTAssertEqual(try v3.applying(.promoteToV3),v3)
    XCTAssertEqual(old.schemaVersion,1); XCTAssertNil(old.adjustmentsV3)
  }
  func testEnableRetainsParametersAndResetUsesTypedDefaults() throws {
    var p = DevelopmentAdjustmentsV3(); p.blackAndWhite = .init(enabled:true,intensity:0.8,neutrals:0.3,tone:0.2,grain:0.4)
    p.sharpen = .init(enabled:true,intensity:0.6,edges:0.8,falloff:0.3); p.vignette = .init(enabled:true,strength:0.5,radius:0.9,softness:0.7)
    p.selectiveColor.colors[0].range = 2
    let original = DevelopmentRecipe(adjustmentsV3:p), off = try original.applying(.setEnabled(.blackAndWhite,false))
    XCTAssertFalse(off.adjustmentsV3!.blackAndWhite.enabled); XCTAssertEqual(off.adjustmentsV3!.blackAndWhite.intensity,0.8)
    XCTAssertEqual(try off.applying(.setEnabled(.blackAndWhite,true)),original)
    let bw = try off.applying(.reset(.blackAndWhite)); XCTAssertEqual(bw.adjustmentsV3!.blackAndWhite,DevelopmentBlackAndWhiteV3())
    XCTAssertEqual(bw.adjustmentsV3!.blackAndWhite.intensity,0.5); XCTAssertFalse(bw.adjustmentsV3!.blackAndWhite.enabled)
    let sharpen = try original.applying(.reset(.sharpen)); XCTAssertEqual(sharpen.adjustmentsV3!.sharpen.edges,0.22); XCTAssertEqual(sharpen.adjustmentsV3!.sharpen.falloff,0.69)
    XCTAssertEqual(try original.applying(.reset(.vignette)).adjustmentsV3!.vignette.radius,0.5)
    XCTAssertEqual(try original.applying(.reset(.selectiveColor)).adjustmentsV3!.selectiveColor.colors[0].range,1)
  }
  func testEveryGroupEnableAndResetDoesNotTouchOtherGroupsOrLegacyBasis() throws {
    let basis = DevelopmentLegacyBasis(version:.v1,exposureEV:1)
    var p = DevelopmentAdjustmentsV3(legacyBasis:basis); p.light.contrast = 1.4
    let original = DevelopmentRecipe(adjustmentsV3:p)
    for id in DevelopmentAdjustmentID.allCases {
      let on = try original.applying(.setEnabled(id,true)); XCTAssertTrue(on.adjustmentsV3!.isEnabled(id))
      let reset = try on.applying(.reset(id)); XCTAssertFalse(reset.adjustmentsV3!.isEnabled(id)); XCTAssertEqual(reset.adjustmentsV3!.legacyBasis,basis)
      if id != .light { XCTAssertEqual(reset.adjustmentsV3!.light.contrast,1.4) }
    }
    XCTAssertEqual(try original.applying(.resetAll),DevelopmentRecipe(adjustmentsV3:.init()))
  }
  func testSetParametersValidatesEvenDisabledAndFailureLeavesOriginalValue() throws {
    let original = DevelopmentRecipe(adjustmentsV3:.init())
    XCTAssertThrowsError(try original.applying(.setParameters(.light(.init(enabled:false,exposure:Double.nan)))))
    XCTAssertEqual(original.adjustmentsV3!.light.exposure,0)
    let changed = try original.applying(.setParameters(.filter(.init(enabled:true,selection:.noir,intensity:37))))
    XCTAssertEqual(changed.adjustmentsV3!.filter.intensity,37); XCTAssertEqual(changed.adjustmentsV3!.filter.selection,.noir)
  }
  func testAnalysisRequiresCurrentGenerationSourceActualFingerprintAndStage() throws {
    let recipe = DevelopmentRecipe(adjustmentsV3:.init()), good = try result(recipe)
    let changed = try recipe.applying(.applyAnalysis(good),context:context); XCTAssertEqual(changed.adjustmentsV3!.light.exposure,0.5)
    XCTAssertThrowsError(try recipe.applying(.applyAnalysis(good)))
    for bad in [try result(recipe,generation:6),try result(recipe,stage:.orientedSourceBeforeGeometry),try result(recipe,sourceID:String(repeating:"b",count:64))] {
      XCTAssertThrowsError(try recipe.applying(.applyAnalysis(bad),context:context))
    }
    // Even a disabled remembered-value edit changes the ACTUAL fingerprint; it must stale the result.
    let newer = try recipe.applying(.setParameters(.color(.init(enabled:false,cast:0.1))))
    XCTAssertThrowsError(try newer.applying(.applyAnalysis(good),context:context))
    let laterEpoch = DevelopmentAdjustmentCommandContext(source:source,sourceGeneration:8,analysisStage:context.analysisStage)
    XCTAssertThrowsError(try recipe.applying(.applyAnalysis(good),context:laterEpoch))
  }
  func testAnalysisPurposeRestrictsGroupsAndGlobalTransactionIsAtomic() throws {
    let recipe = DevelopmentRecipe(adjustmentsV3:.init())
    let cases = [try result(recipe,purpose:.curvesPicker),
                 try result(recipe,purpose:.automatic(.color)),
                 try result(recipe,purpose:.automatic(nil),parameters:[.definition(.init(enabled:true,amount:1))]),
                 try result(recipe,purpose:.automatic(nil),parameters:[.light(.init()),.light(.init())]),
                 try result(recipe,parameters:[])]
    for bad in cases { XCTAssertThrowsError(try recipe.applying(.applyAnalysis(bad),context:context)) }
    let global = try result(recipe,purpose:.automatic(nil),parameters:[.light(.init(enabled:true,exposure:0.5)),.color(.init(enabled:true,vibrance:0.4))])
    let changed = try recipe.applying(.applyAnalysis(global),context:context)
    XCTAssertEqual(changed.adjustmentsV3!.light.exposure,0.5); XCTAssertEqual(changed.adjustmentsV3!.color.vibrance,0.4)
    let invalid = try result(recipe,purpose:.automatic(nil),parameters:[.light(.init(enabled:true,exposure:1)),.whiteBalance(.init(enabled:false,adjustment:.temperatureTint(temperature:20001,tint:0)))])
    XCTAssertThrowsError(try recipe.applying(.applyAnalysis(invalid),context:context)); XCTAssertEqual(recipe.adjustmentsV3!.light.exposure,0)
  }
  func testAppendRemoveAndToolResetBindToCurrentSourceAndKeepOrder() throws {
    let recipe = DevelopmentRecipe(adjustmentsV3:.init()), a = edit(), b = edit(tool:.redEye)
    XCTAssertThrowsError(try recipe.applying(.appendLocal(a)))
    var wrong = a; wrong.sourceContentID = String(repeating:"b",count:64)
    XCTAssertThrowsError(try recipe.applying(.appendLocal(wrong),context:context))
    let first = try recipe.applying(.appendLocal(a),context:context), both = try first.applying(.appendLocal(b),context:context)
    XCTAssertEqual(both.adjustmentsV3!.localEdits.operations.map(\.id),[a.id,b.id])
    XCTAssertThrowsError(try both.applying(.appendLocal(a),context:context))
    XCTAssertThrowsError(try both.applying(.removeLocal(UUID()),context:context))
    let noRetouch = try both.applying(.reset(.retouch),context:context)
    XCTAssertEqual(noRetouch.adjustmentsV3!.localEdits.operations.map(\.id),[b.id]); XCTAssertFalse(noRetouch.adjustmentsV3!.localEdits.retouchEnabled)
    XCTAssertTrue(noRetouch.adjustmentsV3!.localEdits.redEyeEnabled); XCTAssertEqual(noRetouch.adjustmentsV3!.localEdits.sourceBinding,source)
    let empty = try noRetouch.applying(.removeLocal(b.id),context:context); XCTAssertTrue(empty.adjustmentsV3!.localEdits.operations.isEmpty); XCTAssertNil(empty.adjustmentsV3!.localEdits.sourceBinding)
    let other = DevelopmentAdjustmentCommandContext(source:.init(sourceContentID:sourceHash,exifOrientation:6,orientedWidth:80,orientedHeight:100),sourceGeneration:context.sourceGeneration,analysisStage:context.analysisStage)
    XCTAssertThrowsError(try both.applying(.setEnabled(.retouch,false),context:other))
  }
  func testSummaryPurposeRequiresExactGroupFiniteAmountAndCurrentFence() throws {
    let recipe = DevelopmentRecipe(adjustmentsV3:.init())
    let summary = try result(recipe,purpose:.summary(.light,amount:0.5))
    XCTAssertEqual(try recipe.applying(.applyAnalysis(summary),context:context).adjustmentsV3!.light.exposure,0.5)
    for bad in [try result(recipe,purpose:.summary(.color,amount:0.5)),
                try result(recipe,purpose:.summary(.definition,amount:0.5)),
                try result(recipe,purpose:.summary(.light,amount:Double.nan)),
                try result(recipe,purpose:.summary(.light,amount:1.00001)),
                try result(recipe,generation:6,purpose:.summary(.light,amount:0.5))] {
      XCTAssertThrowsError(try recipe.applying(.applyAnalysis(bad),context:context))
    }
  }

}
