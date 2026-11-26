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

  private func detailRequest(_ lease: PreviewSessionInfo, _ consumer: PreviewConsumerID,
                             _ revision: UInt64, window: CGRect?) -> DevelopmentPreviewRequest {
    .init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: consumer,
      role: .primary, revision: revision, recipe: .init(adjustmentsV3: .init()),
      quality: .detail, viewport: .init(maxPixel: 0, window: window))
  }

  /// Fixed output-tile path: the whole and window frames both consume the same materialized
  /// tile textures, so the window is byte-identical to the whole crop.
  func testAdvancedDetailTiledWindowIsByteExact() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RAWMASTER_QA_ADVANCED_FACTOR_WINDOW"] == "1",
                      "Explicit tiled-window QA switch required")
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0,
      rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let consumer = PreviewConsumerID()
    let lease = try await service.open(source: .raw(source))
    var adjustments = DevelopmentAdjustmentsV3()
    adjustments.advancedDetail.texture = .init(enabled: true, amount: 25)
    let recipe = DevelopmentRecipe(adjustmentsV3: adjustments)
    func request(_ revision: UInt64, window: CGRect?) -> DevelopmentPreviewRequest {
      .init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: consumer,
        role: .primary, revision: revision, recipe: recipe, quality: .detail,
        viewport: .init(maxPixel: 0, window: window))
    }
    let wholeStart = DispatchTime.now().uptimeNanoseconds
    let whole = try await service.render(request(1, window: nil))
    let wholeMs = Double(DispatchTime.now().uptimeNanoseconds - wholeStart) / 1_000_000
    let window = CGRect(x: 0.21, y: 0.17, width: 0.37, height: 0.41)
    let windowStart = DispatchTime.now().uptimeNanoseconds
    let scoped = try await service.render(request(2, window: window))
    let windowMs = Double(DispatchTime.now().uptimeNanoseconds - windowStart) / 1_000_000
    print("STRICT-FACTOR whole=\(wholeMs)ms window=\(windowMs)ms")
    let canvas = CGRect(origin: .zero, size: whole.canonicalPixelSize)
    let expected = try V3PreviewMaterializer.visibleRect(window, of: canvas)
    guard let wholeImage = whole.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return XCTFail("whole frame has no raster")
    }
    let flipped = CGRect(x: expected.minX, y: canvas.height - expected.maxY,
                         width: expected.width, height: expected.height)
    guard let crop = wholeImage.cropping(to: flipped) else { return XCTFail("crop failed") }
    let wholeBytes = try bytes(NSImage(cgImage: crop, size: .zero))
    let scopedBytes = try bytes(scoped.image)
    var maxDiff = 0, differing = 0
    for i in 0..<min(wholeBytes.count, scopedBytes.count) {
      let d = abs(Int(wholeBytes[i]) - Int(scopedBytes[i]))
      if d > 0 { differing += 1; maxDiff = max(maxDiff, d) }
    }
    print("STRICT-FACTOR diff max", maxDiff, "differing", differing, "of", wholeBytes.count)
    XCTAssertEqual(wholeBytes, scopedBytes,
      "The tiled window must be byte-identical to the whole-frame crop")
    await service.closeAll()
  }

  /// A windowed 1:1 frame must be exactly the corresponding crop of the whole 1:1 frame, and it
  /// must keep reporting the whole canvas so overlays, crop and pickers keep their coordinates.
  func testDetailWindowIsExactlyTheCropOfTheWholeNativeFrame() async throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 64 * 1024 * 1024,
      rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let consumer = PreviewConsumerID()
    let lease = try await service.open(source: .raw(source))
    let whole = try await service.render(detailRequest(lease, consumer, 1, window: nil))
    XCTAssertNil(whole.window)
    XCTAssertEqual(whole.outputPixelSize, whole.canonicalPixelSize)

    let window = CGRect(x: 0.21, y: 0.17, width: 0.37, height: 0.41)
    let scoped = try await service.render(detailRequest(lease, consumer, 2, window: window))
    XCTAssertEqual(scoped.window, window)
    XCTAssertEqual(scoped.canonicalPixelSize, whole.canonicalPixelSize,
      "The canvas identity must stay whole-frame")
    XCTAssertNotEqual(scoped.outputKey, whole.outputKey, "A window cannot reuse the whole-frame key")

    let canvas = CGRect(origin: .zero, size: whole.canonicalPixelSize)
    let expected = try V3PreviewMaterializer.visibleRect(window, of: canvas)
    XCTAssertEqual(scoped.outputPixelSize, expected.size)
    XCTAssertGreaterThan(scoped.outputPixelSize.width, 100)
    XCTAssertLessThan(scoped.outputPixelSize.width, whole.outputPixelSize.width)

    // Crop the whole native frame at the same rect and compare RGBA bytes.
    guard let wholeImage = whole.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return XCTFail("whole frame has no raster")
    }
    // The materialized canvas uses a top-left origin; the crop rect from `visibleRect` is in
    // Core Graphics coordinates, so flip it for CGImage cropping.
    let flipped = CGRect(x: expected.minX, y: canvas.height - expected.maxY,
                         width: expected.width, height: expected.height)
    guard let crop = wholeImage.cropping(to: flipped) else { return XCTFail("crop failed") }
    XCTAssertEqual(try bytes(NSImage(cgImage: crop, size: .zero)), try bytes(scoped.image),
      "The windowed frame must be byte-identical to the crop of the whole frame")

    // The same recipe must still replay the cached whole-frame result.
    let replay = try await service.render(detailRequest(lease, consumer, 3, window: nil))
    XCTAssertEqual(replay.outputKey, whole.outputKey)
    await service.closeAll()
  }

  func testFreeZoomSamplesTheCanonicalImageAtTheRequestedDensity() async throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let lease = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
    let window = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
    func render(_ revision: UInt64, scale: CGFloat, window: CGRect?) async throws -> DevelopmentPreviewFrame {
      try await service.render(.init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: consumer,
        role: .primary, revision: revision, recipe: .init(adjustmentsV3: .init()), quality: .detail,
        viewport: .init(maxPixel: 0, window: window, detailScale: scale)))
    }
    let full = try await render(1, scale: 0.5, window: nil)
    let crop = try await render(2, scale: 0.5, window: window)
    let closer = try await render(3, scale: 0.8, window: window)
    XCTAssertEqual(full.canonicalPixelSize, CGSize(width: 3000, height: 2000))
    XCTAssertEqual(full.outputPixelSize, CGSize(width: 1500, height: 1000))
    XCTAssertEqual(crop.outputPixelSize, CGSize(width: 750, height: 600))
    XCTAssertEqual(closer.outputPixelSize, CGSize(width: 1200, height: 960))
    XCTAssertNil(crop.approximation)
    XCTAssertNil(closer.approximation)
    XCTAssertNotEqual(crop.outputKey, closer.outputKey)
    let fullImage = try XCTUnwrap(full.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let expected = try XCTUnwrap(fullImage.cropping(to: CGRect(x: 300, y: 100, width: 750, height: 600)))
    XCTAssertEqual(try bytes(crop.image), try bytes(NSImage(cgImage: expected, size: .zero)))
    await service.closeAll()
  }

  func testOptInSensorRAWZoomSamplesTheRequestedDensity() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_PRESENTED_CANVAS_SOURCE"] else {
      throw XCTSkip("Set RAWMASTER_PRESENTED_CANVAS_SOURCE to a RAW fixture")
    }
    let file = URL(fileURLWithPath: path)
    let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
    let source = EditingSourceSnapshot(projectID: "zoom", assetID: "sensor-raw",
      contentSHA256: try RenderFiles.hash(file), byteCount: size.int64Value,
      admissionFingerprint: "zoom", sourceLocation: file)
    XCTAssertTrue(PhotoRenderer.rawExtensions.contains(file.pathExtension.lowercased()))
    let service = DevelopmentPreviewService(policy: .init(interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let lease = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
    let window = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    do {
      let detail = try await service.render(.init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration,
        consumerID: consumer, role: .primary, revision: 1, recipe: .init(adjustmentsV3: .init()), quality: .detail,
        viewport: .init(maxPixel: 0, window: window, detailScale: 0.65)))
      XCTAssertEqual(detail.canonicalPixelSize, lease.orientedNativeSize)
      XCTAssertFalse(detail.approximate)
      let placement = try XCTUnwrap(detail.window)
      XCTAssertEqual(detail.outputPixelSize.width, detail.canonicalPixelSize.width * 0.65 * placement.width, accuracy: 1)
      XCTAssertEqual(detail.outputPixelSize.height, detail.canonicalPixelSize.height * 0.65 * placement.height, accuracy: 1)
      XCTAssertGreaterThan(Set(try bytes(detail.image)).count, 32)
      print("Sensor RAW zoom: \(detail.canonicalPixelSize) → \(detail.outputPixelSize) visible at 65%")
      await service.closeAll()
    } catch { await service.closeAll(); throw error }
  }

  func testNonDetailRequestsRejectAWindow() async throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0,
      interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let consumer = PreviewConsumerID()
    let lease = try await service.open(source: .raw(source))
    let window = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    for quality in [PreviewQuality.interactive, .settled] {
      var request = self.request(lease, consumer, .init(adjustmentsV3: .init()), 1, quality: quality)
      request = .init(sessionID: request.sessionID, sourceGeneration: request.sourceGeneration,
        consumerID: request.consumerID, role: request.role, revision: request.revision,
        recipe: request.recipe, quality: request.quality,
        viewport: .init(maxPixel: 2400, window: window))
      do {
        _ = try await service.render(request)
        XCTFail("\(quality) must reject a window")
      } catch DevelopmentPreviewError.invalidRequest {}
    }
    // Out-of-bounds and degenerate windows are rejected too.
    for bad in [CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5), .init(x: 0, y: 0, width: 0, height: 0.5),
                .init(x: 0.8, y: 0.8, width: 0.5, height: 0.5), .init(x: 0, y: 0, width: .nan, height: 0.5)] {
      do {
        _ = try await service.render(detailRequest(lease, consumer, 2, window: bad))
        XCTFail("window \(bad) must be rejected")
      } catch DevelopmentPreviewError.invalidRequest {}
    }
    await service.closeAll()
  }
}
