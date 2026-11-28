import CoreImage
import Metal
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

  func testOptInRealRawRetirementAfterOpaqueUploadRevokesTheRequest() throws {
    let environment = ProcessInfo.processInfo.environment
    let os = ProcessInfo.processInfo.operatingSystemVersion
    guard let path = environment["RAWMASTER_PANEL_READBACK_RAW"],
          environment["RAWMASTER_QA_NATIVE_RAW_NOISE_DOMAIN"] == "1",
          FlashRawNativeFiniteCheck.enabled,
          os.majorVersion == 27, os.minorVersion == 0, os.patchVersion == 1,
          let device = MTLCreateSystemDefaultDevice(), device.name == "Apple M4 Max" else {
      throw XCTSkip("Requires a qualified RAW and the explicit runtime proof")
    }
    let url = URL(fileURLWithPath: path)
    let hash = try RenderFiles.hash(url)
    let bytes = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let sourceKey = "opaque-upload-retirement:" + hash
    let capture = try RenderFiles.verifiedPreviewCapture(.init(projectID: "native-noise", assetID: sourceKey,
      contentSHA256: hash, byteCount: Int64(bytes), admissionFingerprint: sourceKey, sourceLocation: url))
    let source = try PreviewNativeSource.openVerifiedRAW(capture, memoryLimit: 512)
    guard [CGSize(width: 9504, height: 6336), CGSize(width: 8640, height: 5760)].contains(source.orientedNativeExtent.size) else {
      throw XCTSkip("Use either qualified native RAW dimension")
    }
    var parameters = DevelopmentAdjustmentsV3()
    parameters.rawDecoder = .flashRaw031
    parameters.noiseReduction = .init(enabled: true, colorNoise: 0.75, colorDetail: 0.5)
    defer { FlashRawCanonicalTexturePool.shared.retire(sourceKey: sourceKey) }
    let pin = try XCTUnwrap(source.pinFlashRawSource(parameters, sourceKey: sourceKey))
    defer { pin.release() }

    let telemetry = ImagePerformanceTelemetry.shared
    telemetry.reset()
    var retiredAfterUpload = false
    XCTAssertThrowsError(try PreviewNativeNoiseDomain.acquire(parameters, pin: pin,
      asShotWhiteBalance: source.asShotWhiteBalance, device: device) {
        try capture.requireCurrent(at: capture.url)
        guard !retiredAfterUpload, telemetry.snapshot().recent.contains(where: {
          $0.operation == "FlashRawNativeFiniteCheck" && $0.outcome == .succeeded
        }) else { return }
        retiredAfterUpload = true
        FlashRawCanonicalTexturePool.shared.retire(sourceKey: sourceKey)
    }) { error in
      XCTAssertEqual(error as? PreviewPresentationError, .allocationProtocol)
    }
    XCTAssertTrue(retiredAfterUpload)
    XCTAssertFalse(pin.isCurrent(for: pin.image))
  }
}
