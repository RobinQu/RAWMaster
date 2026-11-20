import Foundation
import XCTest
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

final class PhotosGrainSamplingCompatibilityTests:XCTestCase {
  private let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:8,orientedWidth:5760,orientedHeight:8640)
  private let version=DevelopmentGrainSamplingVersion.sourceNativeLatticeV1
  @MainActor private final class Draft { var recipe:DevelopmentRecipe;var writes=0;init(_ r:DevelopmentRecipe){recipe=r} }
  private func legacy()->DevelopmentRecipe { .init(adjustmentsV3:.init(blackAndWhite:.init(enabled:true,grain:0.3))) }
  @MainActor private func make(capability:DevelopmentNoiseReductionSourceCapability = .raw)throws->(Draft,EditingDevelopmentSession,EditingInteractionContext) {
    let d=Draft(legacy()),s=EditingDevelopmentSession(readRecipe:{d.recipe},commitRecipe:{r,_ in d.recipe=r;d.writes+=1})
    let c=try s.activate(workID:"work",admissionFingerprint:String(repeating:"b",count:64),source:source,sourceGeneration:1,noiseReduction:capability)
    return(d,s,c)
  }
  private func facts(kind:DevelopmentSourceKind = .raw,generation:UInt64 = 1,binding:DevelopmentLocalEditSourceBinding? = nil,versions:Set<DevelopmentGrainSamplingVersion> = [.sourceNativeLatticeV1])->DevelopmentSourceFacts {
    .init(sourceBinding:binding ?? source,sourceGeneration:generation,sourceKind:kind,decoderVersion:"explicit-unit-fixture",noiseReduction:.init(sourceCapability:kind == .raw ? .raw:.image,raw:nil),asShotWhiteBalance:nil,implementedAdjustments:[.blackAndWhite],supportedGrainSamplingVersions:versions)
  }
  private func field(_ id:String="grain")throws->PhotosScalarField { try XCTUnwrap(PhotosScalarField.fields(for:.blackAndWhite,noiseReduction:.raw).first{$0.id==id}) }
  private func event(_ c:EditingInteractionContext)->EditingCommandEvent { .init(context:c,control:.init(group:.blackAndWhite,name:"颗粒")) }
  @MainActor func testVersionOnlyRawManualEditIsOneUndoAndCodableReopenRetainsIt() throws {
    let(d,s,c)=try make(),actual=facts(),binding=source
    s.currentGrainSamplingVersions={expected in try EditingController.grainSamplingVersions(facts:actual,source:binding,sourceGeneration:expected.sourceGeneration,capability:.raw)}
    let before=d.recipe,admitted=try s.grainSamplingVersions(context:c)
    let command=try PhotosAdjustmentCommands.scalar(field(),group:.blackAndWhite,value:0.3,parameters:s.parameters,noiseReduction:.raw,supportedGrainSamplingVersions:admitted)
    XCTAssertEqual(command,.setBlackAndWhiteGrain(amount:0.3,sampling:version))
    XCTAssertTrue(try s.apply(command,event:event(c)));XCTAssertEqual(d.writes,1);XCTAssertEqual(s.history.entryCount,1)
    XCTAssertEqual(d.recipe.adjustmentsV3!.blackAndWhite.grain,before.adjustmentsV3!.blackAndWhite.grain)
    let saved=d.recipe;XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(saved)),saved)
    try s.undo(context:c);XCTAssertEqual(d.recipe,before)
    try s.redo(context:c);XCTAssertEqual(d.recipe,saved)
  }
  @MainActor func testEveryImageKindKeepsItsExistingLegacyGrainControl() throws {
    for kind in [DevelopmentSourceKind.image,.generatedArtifact] {
      let(d,s,c)=try make(capability:.image),actual=facts(kind:kind),binding=source
      // Even a malformed image fact advertising a RAW-only version cannot select it.
      s.currentGrainSamplingVersions={expected in try EditingController.grainSamplingVersions(facts:actual,source:binding,sourceGeneration:expected.sourceGeneration,capability:.image)}
      let supported=try s.grainSamplingVersions(context:c);XCTAssertTrue(supported.isEmpty)
      let command=try PhotosAdjustmentCommands.scalar(field(),group:.blackAndWhite,value:0.6,parameters:s.parameters,noiseReduction:.image,supportedGrainSamplingVersions:supported)
      XCTAssertEqual(command,.setBlackAndWhiteGrain(amount:0.6,sampling:nil))
      try s.apply(command,event:event(c));XCTAssertEqual(d.recipe.adjustmentsV3!.blackAndWhite.grain,0.6)
      XCTAssertNil(d.recipe.adjustmentsV3!.blackAndWhite.grainSamplingVersion);XCTAssertEqual(d.writes,1)
    }
  }
  @MainActor func testStaleFullBindingGenerationOrMissingFactsCannotAuthorizeVersion() throws {
    var rotated=source;rotated.exifOrientation=1
    var different=source;different.sourceContentID=String(repeating:"c",count:64)
    for bad in [Optional<DevelopmentSourceFacts>.none,facts(generation:2),facts(binding:rotated),facts(binding:different)] {
      XCTAssertThrowsError(try EditingController.grainSamplingVersions(facts:bad,source:source,sourceGeneration:1,capability:.raw))
    }
    XCTAssertThrowsError(try EditingController.grainSamplingVersions(facts:facts(),source:source,sourceGeneration:1,capability:.image))
    let(d,s,c)=try make(),before=d.recipe
    s.currentGrainSamplingVersions={_ in throw EditingDevelopmentSessionError.staleInteraction}
    XCTAssertThrowsError(try s.grainSamplingVersions(context:c))
    XCTAssertThrowsError(try s.apply(.setBlackAndWhiteGrain(amount:0.4,sampling:version),event:event(c)))
    XCTAssertEqual(d.recipe,before);XCTAssertEqual(d.writes,0);XCTAssertEqual(s.history.entryCount,0)
  }
  @MainActor func testCapabilityRevokedAfterSelectionAndMissingProviderRejectBeforePublishing() throws {
    let(d,s,c)=try make(),before=d.recipe
    var admitted:Set<DevelopmentGrainSamplingVersion>=[version]
    s.currentGrainSamplingVersions={_ in admitted}
    let command=try PhotosAdjustmentCommands.scalar(field(),group:.blackAndWhite,value:0.4,parameters:s.parameters,noiseReduction:.raw,supportedGrainSamplingVersions:try s.grainSamplingVersions(context:c))
    admitted=[]
    XCTAssertThrowsError(try s.apply(command,event:event(c)))
    s.currentGrainSamplingVersions=nil
    XCTAssertThrowsError(try s.grainSamplingVersions(context:c))
    XCTAssertThrowsError(try s.apply(command,event:event(c)))
    XCTAssertEqual(d.recipe,before);XCTAssertEqual(d.writes,0);XCTAssertEqual(s.history.entryCount,0)
  }
  @MainActor func testOldBranchAndReentrantFactsHaveZeroWrites() throws {
    let(d,s,old)=try make(),before=d.recipe,binding=source
    let current=try s.activate(workID:"work",admissionFingerprint:String(repeating:"b",count:64),source:binding,sourceGeneration:2,noiseReduction:.raw)
    s.currentGrainSamplingVersions={_ in [.sourceNativeLatticeV1]}
    XCTAssertThrowsError(try s.grainSamplingVersions(context:old))
    XCTAssertThrowsError(try s.apply(.setBlackAndWhiteGrain(amount:0.5,sampling:version),event:event(old)))
    s.currentGrainSamplingVersions={_ in
      _=try s.activate(workID:"work",admissionFingerprint:String(repeating:"b",count:64),source:binding,sourceGeneration:3,noiseReduction:.raw)
      return [.sourceNativeLatticeV1]
    }
    XCTAssertThrowsError(try s.grainSamplingVersions(context:current))
    XCTAssertEqual(d.recipe,before);XCTAssertEqual(d.writes,0)
    s.currentGrainSamplingVersions=nil
  }
  @MainActor func testUnrelatedBlackAndWhiteScalarPreservesMarkerAndZeroReturnsLegacyEncoding() throws {
    let(d,s,c)=try make();s.currentGrainSamplingVersions={_ in [.sourceNativeLatticeV1]}
    try s.apply(.setBlackAndWhiteGrain(amount:0.3,sampling:version),event:event(c))
    let tone=try PhotosAdjustmentCommands.scalar(field("tone"),group:.blackAndWhite,value:0.2,parameters:s.parameters,noiseReduction:.raw)
    try s.apply(tone,event:event(c));XCTAssertEqual(d.recipe.adjustmentsV3!.blackAndWhite.grainSamplingVersion,version)
    let zero=try PhotosAdjustmentCommands.scalar(field(),group:.blackAndWhite,value:-0.0,parameters:s.parameters,noiseReduction:.raw,supportedGrainSamplingVersions:[version])
    try s.apply(zero,event:event(c))
    XCTAssertNil(d.recipe.adjustmentsV3!.blackAndWhite.grainSamplingVersion)
    XCTAssertFalse(String(decoding:try JSONEncoder().encode(d.recipe),as:UTF8.self).contains("grainSamplingVersion"))
  }
}
