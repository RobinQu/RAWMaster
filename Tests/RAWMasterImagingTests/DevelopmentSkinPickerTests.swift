import XCTest
import AppKit
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentSkinPickerTests: XCTestCase {
  private func fixture(_ rgb: [UInt8]) throws -> (URL,EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-skin-picker-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,
      hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32)!
    for i in 0..<256 { for c in 0..<3 { bitmap.bitmapData![i*4+c] = rgb[c] }; bitmap.bitmapData![i*4+3] = 255 }
    let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:])), url = root.appendingPathComponent("source.png")
    try data.write(to:url)
    let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    return (root,.init(projectID:"skin",assetID:"sample",contentSHA256:hash,byteCount:Int64(data.count),admissionFingerprint:"admitted",sourceLocation:url))
  }
  private func request(_ info: PreviewSessionInfo,_ recipe: DevelopmentRecipe,automatic: Bool = false) throws -> DevelopmentAnalysisRequest {
    let preview = DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:.init(),role:.primary,revision:1,recipe:recipe,quality:.settled)
    return .init(preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),stage:.orientedSourceBeforeGeometry,
      operation:automatic ? .whiteBalanceAutomatic(mode:.skinTone):.whiteBalancePicker(sourcePoint:.init(x:0.5,y:0.5),mode:.skinTone(warmth:0)))
  }
  func testActualGrayAndBlueManualAndAutomaticSkinHaveNoResult() async throws {
    let colors: [[UInt8]] = [[160,160,160],[80,140,220]]
    for rgb in colors {
      let (root,source) = try fixture(rgb); defer { try? FileManager.default.removeItem(at:root) }
      let service = DevelopmentPreviewService()
      do {
        let info = try await service.open(source:.raw(source)), recipe = DevelopmentRecipe(adjustmentsV3:.init())
        for automatic in [false,true] {
          do { _ = try await service.analyze(request(info,recipe,automatic:automatic)); XCTFail("Non-skin source returned a skin target") }
          catch DevelopmentAnalysisError.noVisibleSamples {}
        }
      } catch { await service.closeAll(); throw error }
      await service.closeAll()
    }
  }
  func testActualSkinUsesPreWBSourceAndReturnsBoundedPersistedTransform() async throws {
    let (root,source) = try fixture([200,145,110]); defer { try? FileManager.default.removeItem(at:root) }
    let service = DevelopmentPreviewService()
    do {
      let info = try await service.open(source:.raw(source)), facts = try await service.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
      var p = DevelopmentAdjustmentsV3(legacyBasis:.init(version:.v1,exposureEV:1,whiteBalance:.temperatureTint(temperature:4200,tint:20)))
      p.light = .init(enabled:true,exposure:0.5); p.color = .init(enabled:true,saturation:1)
      let recipe = DevelopmentRecipe(adjustmentsV3:p)
      let result = try await service.analyze(request(info,recipe))
      XCTAssertEqual(result.samplingRecipeFingerprint,try EditingFingerprint.of(DevelopmentRecipe(adjustmentsV3:.init())))
      XCTAssertTrue(result.samplingVersion.contains("skin-locus-v1")); XCTAssertEqual(result.sourceBinding,facts.sourceBinding)
      guard case .resolved(let command) = result.value else { XCTFail(); throw DevelopmentV3Error.invalidGraph }
      let applied = try recipe.applying(.applyAnalysis(command),context:.init(source:facts.sourceBinding,sourceGeneration:info.sourceGeneration,
        analysisStage:.orientedSourceBeforeGeometry,sourceCapability:.image))
      guard let resolved = applied.adjustmentsV3!.whiteBalance.resolvedState, case .image(_,let wb) = resolved else { XCTFail(); throw DevelopmentV3Error.invalidGraph }
      XCTAssertEqual(wb.selectedMode,.skinTone); XCTAssertNotNil(wb.skin); XCTAssertEqual(wb.skin?.version,1)
      try applied.validate()
    } catch { await service.closeAll(); throw error }
    await service.closeAll()
  }
}
