import CoreImage
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class FlashRawSourceTests: XCTestCase {
  private func realRAW() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FLASHRAW_LIBRARY"] != nil,
          let path = environment["RAWMASTER_FLASHRAW_TEST_RAW"] else {
      throw XCTSkip("Set RAWMASTER_FLASHRAW_LIBRARY and RAWMASTER_FLASHRAW_TEST_RAW for real decoder tests")
    }
    return path
  }

  func testRealRAWLinearF16AndRegionDecode() throws {
    let source = try FlashRawSource.open(URL(fileURLWithPath: try realRAW()))
    XCTAssertEqual(source.decoderVersion, "0.3.1")
    let frame = try source.decode(output: .linearRGBF16)
    XCTAssertEqual(frame.info.outputFormat, Int(FlashRawOutput.linearRGBF16.rawValue))
    XCTAssertEqual(frame.info.sampleType, 4)
    XCTAssertEqual(frame.info.channels, 3)
    XCTAssertEqual(frame.info.source, 0)
    XCTAssertFalse(frame.info.incomplete)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: 2400, height: 1600, mipmapped: false)
    descriptor.usage = [.shaderWrite, .shaderRead]
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    try FlashRawMetalConverterCache.convert(frame, into: texture, outputSize: CGSize(width: 2400, height: 1600))
    XCTAssertEqual(texture.width, 2400)
    XCTAssertEqual(texture.height, 1600)

    let region = try source.decode(output: .rgba8, region: CGRect(x: 4000, y: 3000, width: 512, height: 512))
    XCTAssertEqual(region.info.width, 512)
    XCTAssertEqual(region.info.height, 512)
    XCTAssertEqual(region.info.channels, 4)
    let display = try region.displayImage()
    XCTAssertEqual(display.extent.size, CGSize(width: 512, height: 512))
  }

  func testNeutralFlashRawProxyIsSharedAcrossExposureAndWhiteBalanceChanges() async throws {
    let path = try realRAW()
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    let source = EditingSourceSnapshot(projectID: "flashraw-cache", assetID: "fixed-raw",
      contentSHA256: try RenderFiles.hash(url), byteCount: Int64(values.fileSize ?? 0),
      admissionFingerprint: "flashraw-cache-v1", sourceLocation: url)
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1))
    let session = try await service.open(source: .raw(source))
    let consumer = PreviewConsumerID()
    do {
      for (index, exposure) in [0.0, 0.25, 0.5, 0.75].enumerated() {
        var parameters = DevelopmentAdjustmentsV3()
        parameters.light.enabled = true
        parameters.light.exposure = exposure
        parameters.whiteBalance.enabled = true
        parameters.whiteBalance.adjustment = .temperatureTint(temperature: 6000 + Double(index) * 100, tint: 5)
        _ = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
          consumerID: consumer, role: .primary, revision: UInt64(index + 1), recipe: DevelopmentRecipe(adjustmentsV3: parameters),
          quality: .interactive, viewport: .init(maxPixel: 2400)))
      }
      let statistics = await service.interactiveProxyStatisticsForTesting()
      XCTAssertEqual(statistics.fills, 1)
      XCTAssertGreaterThanOrEqual(statistics.hits, 3)
    } catch {
      await service.closeAll()
      throw error
    }
    await service.closeAll()
  }
}
