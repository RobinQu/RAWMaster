import XCTest
import Foundation
@testable import RAWMasterCore

final class DevelopmentAdjustmentsV3Tests: XCTestCase {
  private func encoded(_ value: DevelopmentRecipe) throws -> Data {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]; return try e.encode(value)
  }
  private func object(_ recipe: DevelopmentRecipe = .init(adjustmentsV3:.init())) throws -> [String:Any] {
    try JSONSerialization.jsonObject(with:encoded(recipe)) as! [String:Any]
  }
  private func decode(_ object: [String:Any]) throws -> DevelopmentRecipe {
    try DevelopmentRecipe.decodeJSON(JSONSerialization.data(withJSONObject:object,options:.sortedKeys))
  }
  func testLegacyV1GoldenBytesAndFingerprintRemainUnchanged() throws {
    let golden = #"{"crop":{"height":1,"width":1,"x":0,"y":0},"engineVersion":"core-image-v1","exposureEV":0,"schemaVersion":1,"straightenDegrees":0,"whiteBalance":{"asShot":{}}}"#
    XCTAssertEqual(String(decoding:try encoded(.init()),as:UTF8.self),golden)
    XCTAssertEqual(try EditingFingerprint.of(DevelopmentRecipe()),"81491478172785c23a3a28b851aa76ba2c5138d4bd7e0b9d67dbdcf7c295167b")
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(Data(golden.utf8)),DevelopmentRecipe())
  }
  func testLegacyV2GoldenIsStillExactlyTheLegacyKeySet() throws {
    let v2 = try DevelopmentRecipe().promotingToV2(), data = try encoded(v2), json = try object(v2)
    XCTAssertEqual(Set(json.keys),["schemaVersion","engineVersion","exposureEV","whiteBalance","straightenDegrees","crop","color"])
    let golden = #"{"color":{"curves":{"blue":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"green":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"red":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"rgb":{"points":[{"x":0,"y":0},{"x":1,"y":1}]}},"grading":{"balance":0,"blending":50,"global":{"hueDegrees":0,"luminance":0,"saturation":0},"highlights":{"hueDegrees":0,"luminance":0,"saturation":0},"midtones":{"hueDegrees":0,"luminance":0,"saturation":0},"shadows":{"hueDegrees":0,"luminance":0,"saturation":0}},"tones":{"blacks":0,"contrast":0,"highlights":0,"saturation":0,"shadows":0,"vibrance":0,"whites":0}},"crop":{"height":1,"width":1,"x":0,"y":0},"engineVersion":"rawmaster-color-v2","exposureEV":0,"schemaVersion":2,"straightenDegrees":0,"whiteBalance":{"asShot":{}}}"#
    XCTAssertEqual(String(decoding:data,as:UTF8.self),golden)
    XCTAssertEqual(try EditingFingerprint.of(v2),"4bffe99f68d5dd5224753d9a51c4879bf25f4b501d24762b297b88ccea2ffd1d")
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(data),v2)
    // Re-encoding an old JSON object must not add a nil V3 key.
    XCTAssertEqual(try encoded(DevelopmentRecipe.decodeJSON(data)),data)
    XCTAssertNil(v2.adjustmentsV3)
  }
  func testV3HasOnePayloadAndRejectsMixedFacadeAndEngine() throws {
    var recipe = DevelopmentRecipe(adjustmentsV3:.init()); let json = try object(recipe)
    XCTAssertEqual(Set(json.keys),["schemaVersion","engineVersion","adjustmentsV3"])
    XCTAssertEqual(try decode(json),recipe)
    recipe.exposureEV = 1; XCTAssertThrowsError(try recipe.validate()); XCTAssertThrowsError(try encoded(recipe))
    recipe.exposureEV = 0; recipe.crop.x = 0.1; XCTAssertThrowsError(try recipe.validate())
    recipe.crop = .init(); recipe.engineVersion = "core-image-v1"; XCTAssertThrowsError(try recipe.validate())
    recipe.engineVersion = "rawmaster-adjust-v3"; recipe.color = .init(); XCTAssertThrowsError(try recipe.validate())
    var mixed = json; mixed["exposureEV"] = 0; XCTAssertThrowsError(try decode(mixed))
    var legacy = DevelopmentRecipe(); legacy.adjustmentsV3 = .init(); XCTAssertThrowsError(try legacy.validate())
  }
  func testPromotionPreservesLegacyMathParametersAndGeometryWithoutRecursion() throws {
    var old = try DevelopmentRecipe(exposureEV:0.75,whiteBalance:.temperatureTint(temperature:45000,tint:19),straightenDegrees:12,crop:.init(x:0.1,y:0.2,width:0.7,height:0.6)).promotingToV2()
    old.color!.tones.whites = 42; old.color!.grading.global = .init(hueDegrees:37,saturation:12,luminance:-9)
    let v3 = try old.promotingToV3(), payload = try XCTUnwrap(v3.adjustmentsV3), basis = try XCTUnwrap(payload.legacyBasis)
    XCTAssertEqual(basis.version,.v2); XCTAssertEqual(basis.exposureEV,old.exposureEV); XCTAssertEqual(basis.whiteBalance,old.whiteBalance); XCTAssertEqual(basis.color,old.color)
    XCTAssertEqual(payload.geometry.version,.legacyV2); XCTAssertEqual(payload.geometry.straightenDegrees,12); XCTAssertEqual(payload.geometry.crop,old.crop)
    XCTAssertEqual(try v3.promotingToV3(),v3); XCTAssertThrowsError(try v3.promotingToV2())
    XCTAssertNil(try DevelopmentRecipe().promotingToV3().adjustmentsV3?.legacyBasis)
    XCTAssertNil(try DevelopmentRecipe().promotingToV2().promotingToV3().adjustmentsV3?.legacyBasis)
    var j = try object(v3), p = j["adjustmentsV3"] as! [String:Any], b = p["legacyBasis"] as! [String:Any]
    b["adjustmentsV3"] = [:]; p["legacyBasis"] = b; j["adjustmentsV3"] = p; XCTAssertThrowsError(try decode(j))
    var invalidBasis = DevelopmentLegacyBasis(version:.v1,color:.init()); XCTAssertThrowsError(try invalidBasis.validate())
    invalidBasis = .init(version:.v2); XCTAssertThrowsError(try invalidBasis.validate())
  }
  func testEveryModuleRoundTripsIncludingDisabledRememberedValuesAndMeasuredBounds() throws {
    var p = DevelopmentAdjustmentsV3()
    p.light = .init(brilliance:-2,exposure:2,highlights:-1,shadows:1,brightness:-2,contrast:2,blackPoint:2)
    p.color = .init(saturation:2,vibrance:-1,cast:-1); p.blackAndWhite = .init(intensity:0.75,neutrals:-1,tone:1,grain:1)
    p.whiteBalance = .init(adjustment:.skinTone(warmth:-0.5)); p.curves.red.curve = .init(points:[.init(x:0,y:0.1),.init(x:1,y:0.8)])
    p.curves.blue.inputBlack = 0.1; p.levels.luminance = .manual(.init(black:0,shadows:0,midtones:0.5,highlights:1,white:1,outputBlack:0.1,outputWhite:0.9))
    p.definition.amount = 2; p.selectiveColor.colors[0] = .init(slot:.red,sampledColor:.init(red:2,green:-0.2,blue:0.3),hue:-60,saturation:100,luminance:-70,range:2)
    p.noiseReduction = .init(luminanceNoise:-0.1,colorNoise:-1,detail:3); p.sharpen = .init(intensity:1,edges:0,falloff:1)
    p.vignette = .init(strength:-1,radius:0,softness:1); p.filter = .init(selection:.vividWarm,intensity:100)
    let recipe = DevelopmentRecipe(adjustmentsV3:p)
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(encoded(recipe)),recipe)
    for id in DevelopmentAdjustmentID.allCases { XCTAssertFalse(p.isEnabled(id)) }
    XCTAssertEqual(p.filter.normalizedIntensity,1)
  }
  func testAllUnknownModuleFieldsAndUnknownCasesReject() throws {
    let base = try object(), payload = base["adjustmentsV3"] as! [String:Any]
    for key in ["light","color","blackAndWhite","whiteBalance","curves","levels","definition","selectiveColor","noiseReduction","sharpen","vignette","filter","geometry","localEdits"] {
      var j = base, p = payload, group = p[key] as! [String:Any]; group["future"] = true; p[key] = group; j["adjustmentsV3"] = p
      XCTAssertThrowsError(try decode(j),key)
    }
    for key in ["filter","whiteBalance","geometry"] {
      var j = base, p = payload, group = p[key] as! [String:Any]
      if key == "filter" { group["selection"] = "future" }
      if key == "geometry" { group["version"] = "future" }
      if key == "whiteBalance" { group["adjustment"] = ["mode":"future"] }
      p[key] = group; j["adjustmentsV3"] = p; XCTAssertThrowsError(try decode(j))
    }
    var j = base, p = payload; p["future"] = 1; j["adjustmentsV3"] = p; XCTAssertThrowsError(try decode(j))
  }
  func testDisabledNonfiniteAndOutOfRangeParametersStillReject() throws {
    let mutations: [(inout DevelopmentAdjustmentsV3,Double)->Void] = [
      { $0.light.exposure = $1 }, { $0.color.cast = $1 }, { $0.blackAndWhite.intensity = $1 },
      { $0.definition.amount = $1 }, { $0.noiseReduction.detail = $1 }, { $0.sharpen.edges = $1 },
      { $0.vignette.radius = $1 }, { $0.filter.intensity = $1 }, { $0.curves.red.inputWhite = $1 },
      { $0.selectiveColor.colors[0].range = $1 }, { $0.geometry.verticalPerspective = $1 }
    ]
    for bad in [Double.nan,.infinity,-.infinity,Double.greatestFiniteMagnitude] {
      for mutate in mutations {
        var p = DevelopmentAdjustmentsV3(); mutate(&p,bad)
        XCTAssertThrowsError(try p.validate()); XCTAssertThrowsError(try encoded(.init(adjustmentsV3:p)))
      }
    }
    var p = DevelopmentAdjustmentsV3(); p.light.exposure = 2.000001; XCTAssertThrowsError(try p.validate())
    p = .init(); p.noiseReduction.luminanceNoise = -0.100001; XCTAssertThrowsError(try p.validate())
    p = .init(); p.selectiveColor.colors[0].luminance = 70.01; XCTAssertThrowsError(try p.validate())
    p = .init(); p.selectiveColor.colors[1].slot = .red; XCTAssertThrowsError(try p.validate())
  }
  func testWhiteBalanceModesRoundTripWithoutInventingAsShotNumbers() throws {
    for value: DevelopmentWhiteBalanceAdjustmentV3 in [.asShot,.neutralGray(warmth:0.5),.skinTone(warmth:-0.5),.temperatureTint(temperature:5877.014059134482,tint:19.34415752762252)] {
      var p = DevelopmentAdjustmentsV3(); p.whiteBalance = .init(enabled:true,adjustment:value)
      let r = DevelopmentRecipe(adjustmentsV3:p); XCTAssertEqual(try DevelopmentRecipe.decodeJSON(encoded(r)),r)
    }
    for bad: DevelopmentWhiteBalanceAdjustmentV3 in [.neutralGray(warmth:0.5001),.skinTone(warmth:Double.nan),.temperatureTint(temperature:50000.1,tint:0),.temperatureTint(temperature:6000,tint:150.1)] { XCTAssertThrowsError(try bad.validate()) }
    XCTAssertNoThrow(try DevelopmentWhiteBalanceAdjustmentV3.temperatureTint(temperature:50000,tint:0).validate())
    let data = try JSONEncoder().encode(DevelopmentWhiteBalanceAdjustmentV3.asShot)
    XCTAssertEqual(try JSONSerialization.jsonObject(with:data) as? [String:String],["mode":"asShot"])
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentWhiteBalanceAdjustmentV3.self,from:Data(#"{"mode":"asShot","temperature":6500}"#.utf8)))
  }
  func testImageWhiteBalanceUsesOptionalApproximateOffsetAndKeepsLegacyBytes() throws {
    var state = DevelopmentImageWhiteBalanceStateV3(selectedMode:.temperatureTint,temperatureTint:.init(temperature:5000,tint:0))
    let legacy = try JSONEncoder().encode(state)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with:legacy) as? [String:Any])
    XCTAssertNil(object["temperatureOffset"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentImageWhiteBalanceStateV3.self,from:legacy),state)
    for offset in [-100.0,-50.0,0.0,50.0,100.0] {
      state.temperatureOffset = offset
      state.temperatureTint = .init(temperature:DevelopmentImageWhiteBalanceStateV3.approximateTemperature(forOffset:offset),tint:0)
      try state.validate()
      XCTAssertEqual(try JSONDecoder().decode(DevelopmentImageWhiteBalanceStateV3.self,from:JSONEncoder().encode(state)),state)
    }
    for invalid in [-100.01,100.01,Double.nan,Double.infinity] {
      state.temperatureOffset = invalid
      XCTAssertThrowsError(try state.validate())
    }
  }
  func testSelectiveColorKeepsLegacySixAndSupportsCurrentEightSlots() throws {
    let current = DevelopmentSelectiveColorV3()
    XCTAssertEqual(current.colors.map(\.slot),DevelopmentSelectiveColorSlotV3.allCases)
    XCTAssertEqual(current.colors.count,8)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSelectiveColorV3.self,from:JSONEncoder().encode(current)),current)
    let legacy = DevelopmentSelectiveColorV3(enabled:true,colors:DevelopmentSelectiveColorV3.legacySlots.map { .init(slot:$0) })
    XCTAssertEqual(legacy.colors.count,6)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(legacy)
    let decoded = try JSONDecoder().decode(DevelopmentSelectiveColorV3.self,from:data)
    XCTAssertEqual(decoded,legacy)
    XCTAssertEqual(try encoder.encode(decoded),data)
    let incomplete = DevelopmentSelectiveColorV3(colors:[.init(slot:.red)])
    XCTAssertThrowsError(try incomplete.validate())
  }
  func testEffectsGrainSizeAndRoughnessAreOptionalAndBounded() throws {
    let legacy = DevelopmentEffectsV3(enabled:true,grain:0.4)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let legacyData = try encoder.encode(legacy)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with:legacyData) as? [String:Any])
    XCTAssertNil(object["grainSize"]); XCTAssertNil(object["grainRoughness"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentEffectsV3.self,from:legacyData),legacy)
    for value in [DevelopmentEffectsV3(enabled:true,grain:0.4,grainSize:0,grainRoughness:1),
                  .init(enabled:false,grain:0,grainSize:1,grainRoughness:0)] {
      let data = try encoder.encode(value)
      XCTAssertEqual(try JSONDecoder().decode(DevelopmentEffectsV3.self,from:data),value)
    }
    for invalid in [DevelopmentEffectsV3(grainSize:-0.01),DevelopmentEffectsV3(grainSize:1.01),
                    .init(grainRoughness:-0.01),.init(grainRoughness:1.01)] {
      XCTAssertThrowsError(try invalid.validate())
    }
  }
  func testParametricCurveIsOptionalValidatedAndRoundTrips() throws {
    let curves = DevelopmentCurvesV3()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let legacy = try encoder.encode(curves)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentCurvesV3.self,from:legacy),curves)
    let value = DevelopmentParametricCurveV3(highlights:35,lights:20,darks:-15,shadows:25,split1:0.2,split2:0.55,split3:0.8)
    XCTAssertTrue(value.isActive)
    let points = try value.pointCurve()
    XCTAssertEqual(points.points.count,16)
    XCTAssertGreaterThan(abs(try points.value(at:0.8)-0.8),1e-9)
    var edited = curves; edited.enabled = true; edited.parametric = value
    let data = try encoder.encode(edited)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentCurvesV3.self,from:data),edited)
    for invalid in [DevelopmentParametricCurveV3(highlights:100.01),
                    .init(split1:0.5,split2:0.4), .init(split2:0.8,split3:0.7)] {
      XCTAssertThrowsError(try invalid.validate())
    }
  }
  func testGlowStylesAndParametersAreOptionalValidatedAndRoundTrip() throws {
    let legacy = DevelopmentEffectsV3(enabled:true,grain:0.2)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let legacyData = try encoder.encode(legacy)
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:legacyData) as? [String:Any])["glow"])
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentEffectsV3.self,from:legacyData),legacy)
    for style in DevelopmentGlowStyleV3.allCases {
      let glow = DevelopmentGlowV3(enabled:true,amount:50,style:style,range:60,spread:40,warmth:-20,direction:45,softness:70)
      let effects = DevelopmentEffectsV3(glow:glow)
      try effects.validate()
      let data = try encoder.encode(effects)
      XCTAssertEqual(try JSONDecoder().decode(DevelopmentEffectsV3.self,from:data),effects)
    }
    for invalid in [DevelopmentGlowV3(amount:100.01),DevelopmentGlowV3(warmth:-100.01),DevelopmentGlowV3(direction:360.01)] {
      XCTAssertThrowsError(try invalid.validate())
    }
  }
  func testPostCropVignetteStylesAreOptionalValidatedAndRoundTrip() throws {
    let legacy = DevelopmentEffectsV3(enabled:true,grain:0.2)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with:encoder.encode(legacy)) as? [String:Any])["postCropVignette"])
    for style in DevelopmentPostCropVignetteStyleV3.allCases {
      let value = DevelopmentPostCropVignetteV3(enabled:true,amount:-40,style:style,midpoint:60,roundness:-20,feather:70,highlights:80)
      let effects = DevelopmentEffectsV3(postCropVignette:value)
      try effects.validate()
      let data = try encoder.encode(effects)
      XCTAssertEqual(try JSONDecoder().decode(DevelopmentEffectsV3.self,from:data),effects)
    }
    for invalid in [DevelopmentPostCropVignetteV3(amount:-100.01),DevelopmentPostCropVignetteV3(roundness:100.01),DevelopmentPostCropVignetteV3(feather:100.01)] {
      XCTAssertThrowsError(try invalid.validate())
    }
  }
  func testStandaloneJSONByteLimitRunsBeforeParsing() {
    let data = Data(repeating:0x20,count:DevelopmentLocalEditLimits.maximumRecipeJSONBytes+1)
    XCTAssertThrowsError(try DevelopmentRecipe.decodeJSON(data)) { error in guard case EditingError.invalidRecipe = error else { return XCTFail("Unexpected \(error)") } }
  }
  func testRenderedImageNoiseReductionHasIndependentMeasuredAmountAndRoundTrip() throws {
    for amount in [0.0,2.5,5] {
      var p = DevelopmentAdjustmentsV3()
      p.noiseReduction = .init(enabled:true,sourceCapability:.image,luminanceNoise:0.4,colorNoise:-0.2,detail:2,nonRawAmount:amount)
      let recipe = DevelopmentRecipe(adjustmentsV3:p)
      XCTAssertEqual(try DevelopmentRecipe.decodeJSON(encoded(recipe)),recipe)
      XCTAssertEqual(recipe.adjustmentsV3!.noiseReduction.nonRawAmount,amount)
      XCTAssertNoThrow(try p.noiseReduction.validate(for:.image))
      XCTAssertThrowsError(try p.noiseReduction.validate(for:.raw))
    }
    var raw = DevelopmentNoiseReductionV3(enabled:true,luminanceNoise:-0.1,colorNoise:-1,detail:3)
    XCTAssertNoThrow(try raw.validate(for:.raw)); XCTAssertThrowsError(try raw.validate(for:.image))
    raw.enabled = false; XCTAssertNoThrow(try raw.validate(for:.image))
    raw.nonRawAmount = .nan; XCTAssertThrowsError(try raw.validate(for:.image))
  }
  func testImageNoiseAmountBoundsAndUnknownSourceCapabilityReject() throws {
    for bad in [-0.0001,5.0001,Double.nan,Double.infinity,-Double.infinity] {
      let nr = DevelopmentNoiseReductionV3(enabled:false,sourceCapability:.image,nonRawAmount:bad)
      XCTAssertThrowsError(try nr.validate()); XCTAssertThrowsError(try JSONEncoder().encode(nr))
    }
    var j = try object(), p = j["adjustmentsV3"] as! [String:Any], nr = p["noiseReduction"] as! [String:Any]
    nr["sourceCapability"] = "unknown"; p["noiseReduction"] = nr; j["adjustmentsV3"] = p
    XCTAssertThrowsError(try decode(j))
    nr["sourceCapability"] = "image"; nr.removeValue(forKey:"nonRawAmount"); p["noiseReduction"] = nr; j["adjustmentsV3"] = p
    XCTAssertThrowsError(try decode(j))
  }

}
