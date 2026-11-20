import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentGrainSamplingCompatibilityTests: XCTestCase {
  private let version=DevelopmentGrainSamplingVersion.sourceNativeLatticeV1
  private let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:8,orientedWidth:5760,orientedHeight:8640)
  private func context(capability:DevelopmentNoiseReductionSourceCapability = .raw,versions:Set<DevelopmentGrainSamplingVersion> = [.sourceNativeLatticeV1],generation:UInt64 = 7)->DevelopmentAdjustmentCommandContext {
    .init(source:source,sourceGeneration:generation,analysisStage:.workingImageBeforeGeometry,sourceCapability:capability,supportedGrainSamplingVersions:versions)
  }
  private func legacy()->DevelopmentRecipe { .init(adjustmentsV3:.init(blackAndWhite:.init(enabled:true,intensity:0.7,neutrals:0.1,tone:0.2,grain:0.3))) }
  private func bytes<T:Encodable>(_ value:T)throws->Data { let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value) }
  func testMissingVersionRetainsExactOldWireAndFrozenWholeRecipeFingerprint() throws {
    let golden=#"{"enabled":true,"grain":0.3,"intensity":0.5,"neutrals":0,"tone":0}"#
    let decoded=try JSONDecoder().decode(DevelopmentBlackAndWhiteV3.self,from:Data(golden.utf8))
    XCTAssertNil(decoded.grainSamplingVersion);XCTAssertTrue(decoded.requiresLegacyGrainCanonicalInput)
    XCTAssertEqual(String(decoding:try bytes(decoded),as:UTF8.self),golden)
    let whole=Data(Self.oldWholeRecipe.utf8),r=try DevelopmentRecipe.decodeJSON(whole)
    XCTAssertEqual(try EditingFingerprint.of(r),"313bda732b33059bce25137ff8a11c2e3ca819d5b74cf8f96f4586a5192938b7")
    XCTAssertFalse(String(decoding:try bytes(r),as:UTF8.self).contains("grainSamplingVersion"))
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(bytes(r)),r)
  }
  func testVersionedWireIsExplicitStrictAndNeverEncodesZeroMarker() throws {
    let good=DevelopmentBlackAndWhiteV3(enabled:true,grain:0.3,grainSamplingVersion:version)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentBlackAndWhiteV3.self,from:bytes(good)),good)
    XCTAssertTrue(String(decoding:try bytes(good),as:UTF8.self).contains("source-native-lattice-v1"))
    var object=try JSONSerialization.jsonObject(with:bytes(good))as![String:Any]
    let invalidValues:[Any]=[NSNull(),"future-lattice-v2",7]
    for invalid in invalidValues {
      object["grainSamplingVersion"]=invalid
      XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentBlackAndWhiteV3.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    object["grainSamplingVersion"]=version.rawValue;object["unexpected"]=true
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentBlackAndWhiteV3.self,from:JSONSerialization.data(withJSONObject:object)))
    for zero in [0.0,-0.0] { XCTAssertThrowsError(try DevelopmentBlackAndWhiteV3(grain:zero,grainSamplingVersion:version).validate()) }
  }
  func testExplicitVersionOnlyEditRequiresAdmittedCurrentRawCapabilitySet() throws {
    let old=legacy(),command=DevelopmentAdjustmentCommand.setBlackAndWhiteGrain(amount:0.3,sampling:version)
    XCTAssertThrowsError(try old.applying(command))
    XCTAssertThrowsError(try old.applying(command,context:context(versions:[])))
    XCTAssertThrowsError(try old.applying(command,context:context(capability:.image)))
    XCTAssertThrowsError(try old.applying(command,context:context(generation:0)))
    for amount in [-0.1,1.1,Double.nan] {
      XCTAssertThrowsError(try old.applying(.setBlackAndWhiteGrain(amount:amount,sampling:version),context:context()))
    }
    var oversized=source;oversized.orientedWidth=50001
    let large=DevelopmentAdjustmentCommandContext(source:oversized,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry,sourceCapability:.raw,supportedGrainSamplingVersions:[version])
    XCTAssertThrowsError(try old.applying(command,context:large))
    let defaults=DevelopmentAdjustmentCommandContext(source:source,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry,sourceCapability:.raw)
    XCTAssertTrue(defaults.supportedGrainSamplingVersions.isEmpty)
    XCTAssertThrowsError(try old.applying(command,context:defaults))
    let new=try old.applying(command,context:context())
    XCTAssertEqual(new.adjustmentsV3!.blackAndWhite.grain,old.adjustmentsV3!.blackAndWhite.grain)
    XCTAssertEqual(new.adjustmentsV3!.blackAndWhite.grainSamplingVersion,version)
    XCTAssertNotEqual(new,old);XCTAssertNotEqual(try EditingFingerprint.of(new),try EditingFingerprint.of(old))
    XCTAssertNil(old.adjustmentsV3!.blackAndWhite.grainSamplingVersion)
  }
  func testImageAndArtifactLegacyEditStaysUsableAndManualEditStillEnablesGroup() throws {
    let original=DevelopmentRecipe(adjustmentsV3:.init())
    let changed=try original.applying(.setBlackAndWhiteGrain(amount:0.4,sampling:nil),context:context(capability:.image,versions:[]))
    XCTAssertTrue(changed.adjustmentsV3!.blackAndWhite.enabled);XCTAssertEqual(changed.adjustmentsV3!.blackAndWhite.grain,0.4)
    XCTAssertNil(changed.adjustmentsV3!.blackAndWhite.grainSamplingVersion)
    XCTAssertTrue(changed.adjustmentsV3!.blackAndWhite.requiresLegacyGrainCanonicalInput)
  }
  func testSignedZeroRemovesMarkerAndPreservesOldEqualityFingerprintAndStoredPredicate() throws {
    let new=try legacy().applying(.setBlackAndWhiteGrain(amount:0.3,sampling:version),context:context())
    for zero in [0.0,-0.0] {
      let cleared=try new.applying(.setBlackAndWhiteGrain(amount:zero,sampling:version),context:context())
      var old=legacy();old.adjustmentsV3!.blackAndWhite.grain=zero
      XCTAssertNil(cleared.adjustmentsV3!.blackAndWhite.grainSamplingVersion)
      XCTAssertEqual(cleared.adjustmentsV3!.blackAndWhite.grain.bitPattern,zero.bitPattern)
      XCTAssertFalse(cleared.adjustmentsV3!.blackAndWhite.requiresLegacyGrainCanonicalInput)
      XCTAssertEqual(cleared,old);XCTAssertEqual(try bytes(cleared),try bytes(old))
      XCTAssertEqual(try EditingFingerprint.of(cleared),try EditingFingerprint.of(old))
      XCTAssertFalse(String(decoding:try bytes(cleared),as:UTF8.self).contains("grainSamplingVersion"))
    }
    for enabled in [false,true] {
      XCTAssertTrue(DevelopmentBlackAndWhiteV3(enabled:enabled,grain:Double.leastNonzeroMagnitude).requiresLegacyGrainCanonicalInput)
      XCTAssertFalse(DevelopmentBlackAndWhiteV3(enabled:enabled,grain:Double.leastNonzeroMagnitude,grainSamplingVersion:version).requiresLegacyGrainCanonicalInput)
    }
    XCTAssertEqual(DevelopmentBlackAndWhiteV3(),try JSONDecoder().decode(DevelopmentBlackAndWhiteV3.self,from:bytes(DevelopmentBlackAndWhiteV3())))
  }
  func testLoadPromoteToggleAndOtherParametersNeverMigrateGrain() throws {
    for recipe in [legacy(),try legacy().applying(.setBlackAndWhiteGrain(amount:0.3,sampling:version),context:context())] {
      XCTAssertEqual(try recipe.promotingToV3(),recipe)
      let off=try recipe.applying(.setEnabled(.blackAndWhite,false)),on=try off.applying(.setEnabled(.blackAndWhite,true))
      XCTAssertEqual(on,recipe)
      var bw=recipe.adjustmentsV3!.blackAndWhite;bw.tone=0.4
      let changed=try recipe.applying(.setParameters(.blackAndWhite(bw)))
      XCTAssertEqual(changed.adjustmentsV3!.blackAndWhite.grainSamplingVersion,recipe.adjustmentsV3!.blackAndWhite.grainSamplingVersion)
      let reset=try recipe.applying(.reset(.blackAndWhite))
      XCTAssertEqual(reset.adjustmentsV3!.blackAndWhite,DevelopmentBlackAndWhiteV3())
    }
  }
  func testVersionOnlyChangeRunsExistingDehazeDependencyInvalidationFinalizer() throws {
    let d=DevelopmentDehazeContextV1(source:source,sourceGeneration:7,decoderContractFingerprint:String(repeating:"d",count:64))
    let c=DevelopmentAdjustmentCommandContext(source:source,sourceGeneration:7,analysisStage:.workingImageBeforeGeometry,sourceCapability:.raw,dehazeContextV1:d,supportedGrainSamplingVersions:[version])
    let old=legacy(),projection=try old.prospectiveDehazeInputV1(context:d)
    let prepared=DevelopmentPreparedDehazeV1(sourceBinding:source,inputFingerprint:projection.input.inputFingerprint,airlight:.init(red:0.5,green:0.75,blue:1))
    let resolved=DevelopmentResolvedDehazeV1(binding:.init(sourceContentID:source.sourceContentID,sourceGeneration:7,expectedRecipeFingerprint:projection.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry),presentedRecipeFingerprint:projection.presentedRecipeFingerprint,input:projection.input,resolution:.prepared(prepared))
    let active=try old.applying(.applyPreparedDehaze(resolved,wantedAmount:40),context:c)
    let changed=try active.applying(.setBlackAndWhiteGrain(amount:0.3,sampling:version),context:c)
    XCTAssertEqual(changed.adjustmentsV3!.blackAndWhite.grain,active.adjustmentsV3!.blackAndWhite.grain)
    XCTAssertNil(changed.adjustmentsV3!.advancedDetail.preparedDehaze);XCTAssertFalse(changed.adjustmentsV3!.advancedDetail.dehaze.enabled)
    XCTAssertEqual(changed.adjustmentsV3!.advancedDetail.dehaze.amount,40)
    XCTAssertNotNil(active.adjustmentsV3!.advancedDetail.preparedDehaze)
  }
  private static let oldWholeRecipe = #"""
{"adjustmentsV3":{"blackAndWhite":{"enabled":true,"grain":0.3,"intensity":0.6805179074967314,"neutrals":0.08823529411764704,"tone":0.328921568627451},"color":{"cast":0,"enabled":false,"saturation":0,"vibrance":0},"curves":{"blue":{"curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1},"enabled":false,"green":{"curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1},"red":{"curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1},"rgb":{"curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1}},"definition":{"amount":0,"enabled":false},"filter":{"enabled":false,"intensity":100,"selection":"original"},"geometry":{"clockwiseQuarterTurns":0,"crop":{"height":1,"width":1,"x":0,"y":0},"flipHorizontal":false,"flipVertical":false,"horizontalPerspective":0,"straightenDegrees":0,"version":"legacyV1","verticalPerspective":0},"legacyBasis":null,"levels":{"blue":{"kind":"identity"},"enabled":false,"green":{"kind":"identity"},"luminance":{"kind":"identity"},"red":{"kind":"identity"},"rgb":{"kind":"identity"}},"light":{"blackPoint":0,"brightness":0,"brilliance":0,"contrast":0,"enabled":false,"exposure":0,"highlights":0,"shadows":0},"localEdits":{"operations":[],"redEyeEnabled":false,"retouchEnabled":false,"sourceBinding":null},"noiseReduction":{"colorNoise":0,"detail":0,"enabled":false,"luminanceNoise":0,"nonRawAmount":0,"sourceCapability":"raw"},"selectiveColor":{"colors":[{"hue":0,"luminance":0,"range":1,"sampledColor":null,"saturation":0,"slot":"red"},{"hue":0,"luminance":0,"range":1,"sampledColor":null,"saturation":0,"slot":"yellow"},{"hue":0,"luminance":0,"range":1,"sampledColor":null,"saturation":0,"slot":"green"},{"hue":0,"luminance":0,"range":1,"sampledColor":null,"saturation":0,"slot":"cyan"},{"hue":0,"luminance":0,"range":1,"sampledColor":null,"saturation":0,"slot":"blue"},{"hue":0,"luminance":0,"range":1,"sampledColor":null,"saturation":0,"slot":"magenta"}],"enabled":false},"sharpen":{"edges":0.22,"enabled":false,"falloff":0.69,"intensity":0},"vignette":{"enabled":false,"radius":0.5,"softness":0,"strength":0},"whiteBalance":{"adjustment":{"mode":"asShot"},"enabled":false}},"engineVersion":"rawmaster-adjust-v3","schemaVersion":3}
"""#
}
