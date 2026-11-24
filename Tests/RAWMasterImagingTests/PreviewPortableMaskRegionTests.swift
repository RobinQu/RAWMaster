import CoreImage
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class PreviewPortableMaskRegionTests: XCTestCase {
  func testExteriorRequiresCompletedDisplaySameCaptureOriginalAndGeometry() throws {
    guard #available(macOS 27, *), PreviewPortableMaskRegion.enabled,
          let device = MTLCreateSystemDefaultDevice(),
          let path = ProcessInfo.processInfo.environment["RAWMASTER_PREVIEW_BENCHMARK_RAW"] else {
      throw XCTSkip("Requires the regional mask trial and original RAW fixture")
    }
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let digest = try RenderFiles.hash(file)
    let count = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let snapshot = EditingSourceSnapshot(projectID: "035", assetID: "region", contentSHA256: digest,
      byteCount: Int64(count), admissionFingerprint: "region", sourceLocation: file)
    let capture = try RenderFiles.verifiedPreviewCapture(snapshot)
    let second = try RenderFiles.verifiedPreviewCapture(snapshot)
    defer {
      PreviewPortableMaskRegion.retire(captureID: capture.id)
      PreviewPortableMaskRegion.retire(captureID: second.id)
      for owner in [capture, second] { try? FileManager.default.removeItem(at: owner.url.deletingLastPathComponent()) }
    }
    let native = try FlashRawImageFactory.nativePreviewImage(capture: capture.url, rawDetails: nil, retainNativeTexture: true)
    guard PreviewPortableHalfFIT.supports(native.image.extent.size, device: device) else { throw XCTSkip("Unsupported image or device") }
    let pool = FlashRawCanonicalTexturePool()
    let key = FlashRawCanonicalTextureKey(sourceKey: digest, captureStamp: capture.stamp, contract: "region",
      width: Int(native.image.extent.width), height: Int(native.image.extent.height))
    let pin = try pool.acquireNative(key) { native }
    defer { pin.release() }
    XCTAssertTrue(try pin.checkOpaqueUpload(pin.image, cancellation: { try capture.requireCurrent(at: capture.url) }))
    XCTAssertTrue(pin.hasCheckedOpaqueUpload(for:pin.image))
    let programs = PreviewPortableMetalPrograms()
    let telemetry = ImagePerformanceTelemetry.shared
    var recipe = DevelopmentAdjustmentsV3()
    recipe.rawDecoder = .flashRaw031
    recipe.masks = [.init(kind: .radial, center: .init(x: 0.5, y: 0.5), radiusX: 0.25, radiusY: 0.2,
      feather: 0, adjustments: .init(exposure: 0.2))]
    var revoked = false
    func request(_ owner: RenderFiles.VerifiedCapture) throws -> PreviewPortableHalfFIT {
      let tone = try XCTUnwrap(PreviewPortableMaskTone(recipe))
      return PreviewPortableHalfFIT(pin: pin, parameters: recipe, device: device,
        request: .init(programs: programs, revision: 19, checkAuthority: {
          try owner.requireCurrent(at: owner.url)
          if revoked { throw CancellationError() }
        }), maskTone: tone, captureID: owner.id)
    }
    func complete(_ owner: RenderFiles.VerifiedCapture, warm: Bool) throws {
      try autoreleasepool {
        let renderer = try request(owner)
        telemetry.reset()
        _ = try XCTUnwrap(renderer.makeHalf())
        XCTAssertEqual(telemetry.snapshot().recent.first { $0.operation.hasPrefix("PreviewPortableMaskRegion") }?.operation,
          warm ? "PreviewPortableMaskRegionPatch" : "PreviewPortableMaskRegionFull")
        try renderer.finishMaskRegion()
      }
    }
    let cancelled = try request(capture)
    try autoreleasepool { _ = try XCTUnwrap(cancelled.makeHalf()) }
    revoked = true
    XCTAssertThrowsError(try cancelled.finishMaskRegion()) { XCTAssertTrue($0 is CancellationError) }
    revoked = false
    try complete(capture, warm: false)
    recipe.masks[0].adjustments = .init(hue: -0.35)
    try complete(capture, warm: true)
    recipe.masks[0].center.x = 0.23
    try complete(capture, warm: false)
    try complete(capture, warm: true)
    // The optical object and all bytes are identical. The independent verified-capture
    // identity still prevents reusing the exterior acquired by the first owner.
    try complete(second, warm: false)
    let missing = second.url.appendingPathExtension("moved")
    try FileManager.default.moveItem(at: second.url, to: missing)
    XCTAssertThrowsError(try request(second).makeHalf())
    try FileManager.default.moveItem(at: missing, to: second.url)
    // A rename can change ctime, so a restored pathname cannot reauthorize this capture.
    XCTAssertFalse(PreviewPortableMaskRegion.reclaim())
  }
}
