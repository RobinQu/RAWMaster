import XCTest
import AppKit
import CoreImage
import ImageIO
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

/// The settled canvas frame follows `PreviewResourcePolicy.settledTransport`.
///
/// `canonical` keeps the historical native-resolution evaluation. `viewport` evaluates the
/// same operator sequence at the requested canvas size, reports those pixels as the proxy
/// approximation, and falls back to the native renderer for operators it cannot scale.
/// 1:1 (`detail`) and export never consult this policy.
final class PreviewSettledTransportTests: XCTestCase {
  private func fixture() throws -> (URL, EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-S1-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let file = root.appendingPathComponent("source.tiff")
    // Larger than the 2400px canvas so the viewport transport really scales.
    let width = 3000, height = 2000, stride = width * 4
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: stride, bitsPerPixel: 32))
    for y in 0..<height { for x in 0..<width {
      let i = y * stride + x * 4
      bitmap.bitmapData![i] = UInt8((x * 3 + 8) % 240)
      bitmap.bitmapData![i + 1] = UInt8((y * 6 + 12) % 240)
      bitmap.bitmapData![i + 2] = UInt8((x * 3 + y * 5) % 170 + 20)
      bitmap.bitmapData![i + 3] = 255
    } }
    let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.tiff" as CFString, 1, nil))
    CGImageDestinationAddImage(writer, try XCTUnwrap(bitmap.cgImage), nil)
    XCTAssertTrue(CGImageDestinationFinalize(writer))
    let bytes = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
    let source = EditingSourceSnapshot(projectID: "S1", assetID: "settled-transport",
      contentSHA256: try RenderFiles.hash(file), byteCount: try XCTUnwrap(bytes).int64Value,
      admissionFingerprint: "settled-transport", sourceLocation: file)
    return (root, source)
  }

  private func request(_ lease: PreviewSessionInfo, _ consumer: PreviewConsumerID,
                       _ recipe: DevelopmentRecipe, _ revision: UInt64,
                       quality: PreviewQuality) -> DevelopmentPreviewRequest {
    .init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: consumer,
      role: .primary, revision: revision, recipe: recipe, quality: quality,
      viewport: .init(maxPixel: quality == .detail ? 0 : 2400))
  }

  private func bytes(_ image: NSImage) throws -> [UInt8] {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: PhotoRenderer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw DevelopmentError.unreadable }
    context.setBlendMode(.copy); context.interpolationQuality = .none
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
      count: cg.width * cg.height * 4))
  }

  func testDefaultPolicyKeepsTheNativeSettledRender() {
    XCTAssertEqual(PreviewResourcePolicy.default.settledTransport, .canonical)
    XCTAssertEqual(PreviewSettledTransport.viewport.rawValue, "viewport")
  }

  /// A device with unified memory is what every proxy route already requires.
  private var proxyCapable: Bool {
    MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true
  }

  func testViewportTransportSettlesAtTheCanvasAndReplaysTheGestureFrame() async throws {
    try XCTSkipUnless(proxyCapable, "The viewport transport needs a unified-memory Metal device")
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 32 * 1024 * 1024,
      rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let consumer = PreviewConsumerID()
    let lease = try await service.open(source: .raw(source))
    let recipe = DevelopmentRecipe(adjustmentsV3: .init())

    let interactive = try await service.render(request(lease, consumer, recipe, 1, quality: .interactive))
    XCTAssertNotNil(interactive.approximation, "The gesture frame must report its proxy scale")
    let interactivePixels = try bytes(interactive.image)

    let settled = try await service.render(request(lease, consumer, recipe, 2, quality: .settled))
    XCTAssertEqual(settled.outputPixelSize, interactive.outputPixelSize)
    XCTAssertEqual(settled.canonicalPixelSize, interactive.canonicalPixelSize)
    XCTAssertEqual(settled.approximation?.version, interactive.approximation?.version,
      "A settled canvas frame is the same viewport evaluation as the gesture frame")
    XCTAssertEqual(try bytes(settled.image), interactivePixels,
      "Releasing the control must not change pixels that are already final for this viewport")

    let detail = try await service.render(request(lease, consumer, recipe, 3, quality: .detail))
    XCTAssertNil(detail.approximation, "1:1 always stays native")
    XCTAssertGreaterThan(detail.outputPixelSize.width, settled.outputPixelSize.width)
    await service.closeAll()
  }

  func testViewportTransportKeepsNativeSettledForUnscalableOperators() async throws {
    try XCTSkipUnless(proxyCapable, "The canonical fallback needs a Metal device")
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 32 * 1024 * 1024,
      rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let consumer = PreviewConsumerID()
    let lease = try await service.open(source: .raw(source))
    var adjustments = DevelopmentAdjustmentsV3()
    adjustments.definition = .init(enabled: true, amount: 0.5)
    let recipe = DevelopmentRecipe(adjustmentsV3: adjustments)
    XCTAssertEqual(try PreviewInteractiveProxyV3.support(recipe, sourceIsRAW: false, allowAdvancedDetail: true),
      .canonical(.definition))

    let settled = try await service.render(request(lease, consumer, recipe, 1, quality: .settled))
    XCTAssertNil(settled.approximation, "An operator the viewport graph cannot scale keeps the native render")
    XCTAssertEqual(settled.outputPixelSize, CGSize(width: 2400, height: 1600),
      "The fallback fits the native graph into the requested canvas")
    XCTAssertEqual(settled.canonicalPixelSize, CGSize(width: 3000, height: 2000),
      "The fallback reports native canvas identity, not the proxy layout")
    await service.closeAll()
  }

  func testCanonicalTransportIsUnchangedByTheNewPolicyField() async throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0,
      interactiveEvaluation: .proxyV1, settledTransport: .canonical))
    let consumer = PreviewConsumerID()
    let lease = try await service.open(source: .raw(source))
    let settled = try await service.render(request(lease, consumer, .init(adjustmentsV3: .init()), 1, quality: .settled))
    XCTAssertNil(settled.approximation)
    await service.closeAll()
  }
}
