import XCTest
@testable import RAWMasterCore

final class DevelopmentBTypedABITests: XCTestCase {
  private let source = DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:4032,orientedHeight:3024)
  private func roundtrip<T: Codable & Equatable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(T.self,from:data),value)
  }
  private func context(_ capability: DevelopmentNoiseReductionSourceCapability? = .raw) -> DevelopmentAdjustmentCommandContext {
    .init(source:source,sourceGeneration:7,analysisStage:.orientedSourceBeforeGeometry,sourceCapability:capability)
  }
  func testNativeAsShotHasNoTTReplayAndModeBaselinesRemainIndependent() throws {
    let original = DevelopmentNativeWhiteBalanceV3(temperature:5877.014,tint:19.344158)
    let gray = DevelopmentRawWhiteBalancePickV3(baseline:.init(temperature:5200,tint:-0.0),warmth:0)
    let skin = DevelopmentRawWhiteBalancePickV3(baseline:.init(temperature:6800,tint:12),warmth:0.1)
    var s = DevelopmentRawWhiteBalanceStateV3(defaultTTDiagnostic:original,temperatureTint:.init(temperature:6500,tint:0),gray:gray,skin:skin)
    XCTAssertNil(try s.nativeTarget(),"As-shot leaves a fresh decoder neutral untouched")
    s.defaultTTDiagnostic = .init(temperature:7000,tint:15)
    XCTAssertNil(try s.nativeTarget(),"Diagnostic TT is not as-shot authority")
    s.selectedMode = .neutralGray
    XCTAssertEqual(try s.nativeTarget(),gray.baseline)
    XCTAssertEqual(try s.nativeTarget()?.tintBits,Float(-0.0).bitPattern)
    s.selectedMode = .skinTone; XCTAssertEqual(try s.nativeTarget(),try skin.target())
    s.selectedMode = .neutralGray; XCTAssertEqual(try s.nativeTarget(),gray.baseline)
    XCTAssertEqual(s.skin,skin); try roundtrip(s)
  }
  func testRawWarmthDerivesFromBaselineAndRejectsInvalidTargetsVersionsAndMissingPicks() throws {
    let baseline = DevelopmentNativeWhiteBalanceV3(temperature:6000,tint:8)
    let picked = DevelopmentRawWhiteBalancePickV3(baseline:baseline,warmth:0.2)
    let expected = Float(1e6/(1e6/6000-80*0.2))
    XCTAssertEqual(try picked.target().temperatureBits,expected.bitPattern)
    XCTAssertEqual(try picked.target(),try picked.target())
    XCTAssertThrowsError(try DevelopmentRawWhiteBalancePickV3(baseline:baseline,warmth:.nan).validate())
    XCTAssertThrowsError(try DevelopmentRawWhiteBalancePickV3(baseline:baseline,version:2).validate())
    XCTAssertThrowsError(try DevelopmentRawWhiteBalancePickV3(baseline:.init(temperature:50000,tint:0),warmth:0.5).target())
    let missing = DevelopmentRawWhiteBalanceStateV3(selectedMode:.neutralGray,defaultTTDiagnostic:baseline,temperatureTint:baseline)
    XCTAssertThrowsError(try missing.validate())
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentNativeWhiteBalanceV3.self,from:Data(#"{"temperatureBits":2143289344,"tintBits":0}"#.utf8)))
  }
  func testImageGrayBaselineAndWarmthUseRGBXYZDomainAndPreserveSampleY() throws {
    let sample = DevelopmentSampledColorV3(red:0.4,green:0.2,blue:0.1)
    let neutral = try DevelopmentImageWhiteBalancePickV3.neutralGray(sampledLinearRGB:sample)
    XCTAssertEqual(try neutral.matrix().bits,neutral.baseline.bits,"Zero warmth returns the exact stored RGB baseline")
    let gray = try neutral.matrix().applying(to:sample)
    XCTAssertEqual(gray.red,gray.green,accuracy:3e-7); XCTAssertEqual(gray.green,gray.blue,accuracy:3e-7)
    func y(_ p: DevelopmentSampledColorV3) -> Double { 0.2126729*p.red+0.7151522*p.green+0.0721750*p.blue }
    XCTAssertEqual(y(gray),y(sample),accuracy:1e-12)
    for warmth in [-0.5,0.3,0.5] {
      var p = neutral; p.warmth = warmth; try p.validate()
      XCTAssertEqual(y(try p.matrix().applying(to:sample)),y(sample),accuracy:1e-12)
      try roundtrip(p)
    }
    XCTAssertNotEqual(try { var p = neutral; p.warmth = 0.3; return try p.matrix() }(),neutral.baseline)
  }
  func testImageMatrixAndSampleDomainsRejectBeforeReplay() throws {
    XCTAssertThrowsError(try DevelopmentRGBMatrixV3([1,0,0,0,1,0,0,0,1e-10]).validate())
    XCTAssertThrowsError(try DevelopmentRGBMatrixV3([100,0,0,0,1,0,0,0,1]).validate())
    XCTAssertThrowsError(try DevelopmentRGBMatrixV3([1,0,0,0,1,0,0,0,.nan]).validate())
    let ten = "{\"bits\":["+Array(repeating:"0",count:10).joined(separator:",")+"]}"
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentRGBMatrixV3.self,from:Data(ten.utf8)))
    for sample in [DevelopmentSampledColorV3(red:0,green:0,blue:0),.init(red:-0.1,green:0.2,blue:0.3),.init(red:65,green:1,blue:1)] {
      XCTAssertThrowsError(try DevelopmentImageWhiteBalancePickV3.neutralGray(sampledLinearRGB:sample))
    }
  }
  func testResolvedWhiteBalanceIsSourceBoundAndOldDisplayCannotBecomeSecondAuthority() throws {
    let native = DevelopmentNativeWhiteBalanceV3(temperature:6000,tint:10)
    let state = DevelopmentResolvedWhiteBalanceV3.raw(source:source,state:.init(selectedMode:.temperatureTint,defaultTTDiagnostic:native,temperatureTint:native))
    let wb = DevelopmentWhiteBalanceV3(enabled:true,resolvedState:state)
    let recipe = DevelopmentRecipe(adjustmentsV3:.init())
    let applied = try recipe.applying(.setParameters(.whiteBalance(wb)),context:context())
    try roundtrip(applied)
    XCTAssertThrowsError(try recipe.applying(.setParameters(.whiteBalance(wb))))
    XCTAssertThrowsError(try recipe.applying(.setParameters(.whiteBalance(wb)),context:context(.image)))
    var different = source; different.sourceContentID = String(repeating:"b",count:64)
    XCTAssertThrowsError(try state.validate(expectedSource:different))
    var conflicting = wb; conflicting.adjustment = .asShot
    XCTAssertThrowsError(try conflicting.validate())
    let old = DevelopmentWhiteBalanceV3(enabled:false,adjustment:.neutralGray(warmth:0.1))
    let oldJSON = String(data:try JSONEncoder().encode(old),encoding:.utf8)!
    XCTAssertFalse(oldJSON.contains("resolvedState")); try roundtrip(old)
  }
  func testRawNoiseDefaultZeroOffAndSignedEndpointsAreExact() throws {
    let d = DevelopmentRAWNoiseReductionDefaultsV3(luminance:0.3,color:0.6,detail:1.2,luminanceSupported:true,colorSupported:true,detailSupported:true)
    let zero = try d.resolving(.init(enabled:true))
    XCTAssertEqual(zero.luminanceBits,d.luminance.bitPattern); XCTAssertEqual(zero.colorBits,d.color.bitPattern); XCTAssertEqual(zero.detailBits,d.detail.bitPattern)
    let off = try d.resolving(.init(enabled:false,luminanceNoise:1,colorNoise:-1,detail:3))
    XCTAssertEqual(off,zero)
    let ends = try d.resolving(.init(enabled:true,luminanceNoise:-0.1,colorNoise:-1,detail:3))
    XCTAssertEqual(ends.luminance,0); XCTAssertEqual(ends.color,0); XCTAssertEqual(ends.detail,3)
    let high = try d.resolving(.init(enabled:true,luminanceNoise:1,colorNoise:1,detail:3))
    XCTAssertEqual(high.luminance,1); XCTAssertEqual(high.color,1)
    XCTAssertNotEqual(try EditingFingerprint.of(zero),try EditingFingerprint.of(high),"Native key input records actual effective Float bits")
    try roundtrip(ends)
  }
  func testRawNoiseUnsupportedDefaultsAndVersionAreStrict() throws {
    let d = DevelopmentRAWNoiseReductionDefaultsV3(luminance:0.2,color:0.4,detail:0.8,luminanceSupported:false,colorSupported:false,detailSupported:false)
    XCTAssertNoThrow(try d.resolving(.init(enabled:true)))
    XCTAssertThrowsError(try d.resolving(.init(enabled:true,luminanceNoise:0.1)))
    XCTAssertThrowsError(try d.resolving(.init(enabled:true,colorNoise:-0.1)))
    XCTAssertThrowsError(try d.resolving(.init(enabled:true,detail:0.1)))
    XCTAssertThrowsError(try d.resolving(.init(nativeMappingVersion:2)))
    let bad = DevelopmentRAWNoiseReductionDefaultsV3(luminance:.nan,color:0,detail:0,luminanceSupported:true,colorSupported:true,detailSupported:true)
    XCTAssertThrowsError(try bad.resolving(.init()))
    var p = DevelopmentNoiseReductionV3(enabled:true,luminanceNoise:0.5)
    XCTAssertTrue(String(data:try JSONEncoder().encode(p),encoding:.utf8)!.contains("nativeMappingVersion"))
    p.enabled = false; try roundtrip(p)
  }
  func testAdvancedAmountsCommandsAndCompatibility() throws {
    let base = DevelopmentRecipe(adjustmentsV3:.init())
    XCTAssertFalse(String(data:try JSONEncoder().encode(base),encoding:.utf8)!.contains("advancedDetail"))
    for (id,param) in [(DevelopmentAdjustmentID.texture,DevelopmentAdjustmentParametersV3.texture(.init(enabled:true,amount:100))),
      (.clarity,.clarity(.init(enabled:true,amount:-100)))] {
      let on = try base.applying(.setParameters(param))
      XCTAssertTrue(on.adjustmentsV3!.isEnabled(id)); try roundtrip(on)
      let off = try on.applying(.setEnabled(id,false))
      XCTAssertFalse(off.adjustmentsV3!.isEnabled(id)); XCTAssertNotEqual(off.adjustmentsV3!.advancedDetail,DevelopmentAdvancedDetailV3())
      XCTAssertEqual(try off.applying(.reset(id)),base)
    }
    let beforeFingerprint=try EditingFingerprint.of(base)
    XCTAssertThrowsError(try base.applying(.setParameters(.dehaze(.init(enabled:true,amount:40))))) { error in
      XCTAssertEqual(error as? DevelopmentDehazePreparationError,.preparationRequired)
    }
    XCTAssertEqual(try EditingFingerprint.of(base),beforeFingerprint)
    XCTAssertEqual(base,DevelopmentRecipe(adjustmentsV3:.init()))
    let remembered=try base.applying(.setParameters(.dehaze(.init(enabled:false,amount:40))))
    XCTAssertFalse(remembered.adjustmentsV3!.advancedDetail.dehaze.enabled)
    XCTAssertEqual(remembered.adjustmentsV3!.advancedDetail.dehaze.amount,40)
    try roundtrip(remembered)
    XCTAssertEqual(try remembered.applying(.reset(.dehaze)),base)
    XCTAssertThrowsError(try DevelopmentDetailAmountV3(enabled:false,amount:.nan).validate())
    XCTAssertThrowsError(try DevelopmentDetailAmountV3(amount:100.1).validate())
    XCTAssertThrowsError(try DevelopmentAdvancedDetailV3(version:2).validate())
  }
  func testExplicitNewAutoWhitelistDoesNotBroadenGlobalOrAllowWrongPurpose() throws {
    let recipe = DevelopmentRecipe(adjustmentsV3:.init())
    let binding = DevelopmentAnalysisBinding(sourceContentID:source.sourceContentID,sourceGeneration:7,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),stage:.orientedSourceBeforeGeometry)
    let values: [DevelopmentAdjustmentParametersV3] = [.definition(.init(enabled:true,amount:0.4)),
      .noiseReduction(.init(enabled:true,sourceCapability:.raw,luminanceNoise:0.2)),.sharpen(.init(enabled:true,intensity:0.3)),.vignette(.init(enabled:true,strength:0.2))]
    for value in values {
      let command = DevelopmentResolvedAdjustmentCommand(binding:binding,purpose:.automatic(value.id),parameters:[value])
      XCTAssertNoThrow(try recipe.applying(.applyAnalysis(command),context:context()))
      let global = DevelopmentResolvedAdjustmentCommand(binding:binding,purpose:.automatic(nil),parameters:[value])
      XCTAssertThrowsError(try recipe.applying(.applyAnalysis(global),context:context()))
    }
    let nr = DevelopmentResolvedAdjustmentCommand(binding:binding,purpose:.automatic(.noiseReduction),parameters:[values[1]])
    XCTAssertThrowsError(try recipe.applying(.applyAnalysis(nr),context:context(nil)))
    XCTAssertThrowsError(try recipe.applying(.applyAnalysis(nr),context:context(.image)))
    let wrong = DevelopmentResolvedAdjustmentCommand(binding:binding,purpose:.automatic(.definition),parameters:[values[2]])
    XCTAssertThrowsError(try recipe.applying(.applyAnalysis(wrong),context:context()))
    let advanced = DevelopmentResolvedAdjustmentCommand(binding:binding,purpose:.automatic(.texture),parameters:[.texture(.init(enabled:true,amount:10))])
    XCTAssertThrowsError(try recipe.applying(.applyAnalysis(advanced),context:context()))
  }
  func testProjectiveZeroRetainsExistingQuarterFlipStraightenCropExactly() throws {
    for q in 0...3 { for flip in [false,true] {
      let old = DevelopmentGeometryV3(straightenDegrees:12,crop:.init(x:0.1,y:0.12,width:0.8,height:0.72),clockwiseQuarterTurns:q,flipHorizontal:flip,flipVertical:!flip)
      var next = old; next.version = .projectiveV3_1
      let a = try old.mapping(sourceSize:source.sourceSize), b = try next.mapping(sourceSize:source.sourceSize)
      XCTAssertEqual(a.outputSize,b.outputSize); XCTAssertEqual(a.forwardMatrix.map(\.bitPattern),b.forwardMatrix.map(\.bitPattern)); XCTAssertNil(b.projective)
    } }
  }
  func testProjectiveSourceOutputRoundtripAndSharedExtent() throws {
    for angle in [-30.0,12,30] { for q in 0...3 {
      let g = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:5,verticalPerspective:angle,horizontalPerspective:-angle/2,
        crop:.init(x:0.05,y:0.08,width:0.9,height:0.84),clockwiseQuarterTurns:q,flipHorizontal:true)
      let mapping = try g.mapping(sourceSize:source.sourceSize), descriptor = try XCTUnwrap(mapping.projective)
      XCTAssertEqual(descriptor.outputSize,mapping.outputSize)
      for output in [DevelopmentSourcePoint(x:0,y:0),.init(x:0.5,y:0.5),.init(x:1,y:1)] {
        let s = try mapping.sourcePoint(fromOutput:output), round = try XCTUnwrap(mapping.outputPoint(fromSource:s))
        XCTAssertEqual(round.x,output.x,accuracy:1e-10); XCTAssertEqual(round.y,output.y,accuracy:1e-10)
      }
    } }
  }
  func testOldPerspectiveAndNewHorizonRemainFailClosed() throws {
    let old = DevelopmentGeometryV3(verticalPerspective:10)
    XCTAssertThrowsError(try old.mapping(sourceSize:source.sourceSize))
    let horizon = DevelopmentGeometryV3(version:.projectiveV3_1,horizontalPerspective:30)
    XCTAssertThrowsError(try horizon.mapping(sourceSize:.init(width:1_000_000,height:1)))
    let extreme = DevelopmentGeometryV3(version:.projectiveV3_1,verticalPerspective:.nan)
    XCTAssertThrowsError(try extreme.validate())
  }
}
