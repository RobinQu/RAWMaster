import CoreImage
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class PreviewNativeNoiseDomainTests: XCTestCase {
  func testOnlyDomainStrengthSharesTheSameCameraInputs() {
    var recipe = DevelopmentAdjustmentsV3()
    recipe.rawDecoder = .flashRaw031
    recipe.noiseReduction = .init(enabled: true, colorNoise: 0.7, colorDetail: 0.1)
    let first = PreviewNativeNoiseDomain.camera(for: recipe)
    XCTAssertNotNil(first)
    recipe.noiseReduction.colorDetail = 0.7
    XCTAssertEqual(PreviewNativeNoiseDomain.camera(for: recipe), first)
    recipe.noiseReduction.colorNoise = 0.5
    XCTAssertNotEqual(PreviewNativeNoiseDomain.camera(for: recipe), first)
    recipe.noiseReduction = .init(enabled: true, luminanceNoise: 0.7, detail: 0.5, luminanceContrast: 1)
    let other = PreviewNativeNoiseDomain.camera(for: recipe)
    XCTAssertNotNil(other)
    XCTAssertNotEqual(other, first)
    recipe.noiseReduction.luminanceContrast = 0.1
    XCTAssertEqual(PreviewNativeNoiseDomain.camera(for: recipe), other)
    recipe.light.exposure = 0.125
    XCTAssertNil(PreviewNativeNoiseDomain.camera(for: recipe))
    recipe.light.exposure = 0
    recipe.noiseReduction.colorDetail = 1
    XCTAssertNil(PreviewNativeNoiseDomain.camera(for: recipe))
    recipe.noiseReduction.colorDetail = nil
    recipe.rawDecoder = nil
    XCTAssertNil(PreviewNativeNoiseDomain.camera(for: recipe))
  }

  func testOutOfRangeCanUseTheOriginalScanOnlyAfterEveryGroupFinishes() throws {
    func checked(_ codes: [UInt8]) throws -> Bool {
      try codes.withUnsafeBufferPointer(DevelopmentCanonicalFiniteGPU.checkedPredicateCodes)
    }
    XCTAssertTrue(try checked([0xa0, 0xa0, 0xa0]))
    XCTAssertFalse(try checked([0xa1, 0xa0, 0xa1]))
    for missingOrInvalid: UInt8 in [0, 0x40, 0xa2, 0xa3] {
      XCTAssertThrowsError(try checked([0xa1, 0xa0, missingOrInvalid]))
      XCTAssertThrowsError(try checked([missingOrInvalid, 0xa0, 0xa1]))
    }
  }

  func testChangingTheLinkedLumaOrNoiseProgramInvalidatesTheBound() {
    let source = DevelopmentGlobalEngineV3.metalSource
    XCTAssertTrue(PreviewNativeNoiseDomain.programIsKnown)
    XCTAssertFalse(PreviewNativeNoiseDomain.matchesProgram(source.replacingOccurrences(of: ".7152,.0722", with: ".7152,1.0")))
    XCTAssertFalse(PreviewNativeNoiseDomain.matchesProgram(source.replacingOccurrences(of: "outY=y+.35", with: "outY=y+35000.0")))
  }
}
