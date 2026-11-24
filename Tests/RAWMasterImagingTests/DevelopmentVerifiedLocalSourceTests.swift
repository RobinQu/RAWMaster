import CoreImage
import Foundation
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentVerifiedLocalSourceTests: XCTestCase {
  private func withRAW(memoryLimit: Int = 32,
                       _ body: (RenderFiles.VerifiedCapture, PreviewNativeSource, DevelopmentLocalEditSourceBinding) throws -> Void) throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["RAWMASTER_PREVIEW_BENCHMARK_RAW"] ?? env["RAWMASTER_FLASHRAW_TEST_RAW"] else {
      throw XCTSkip("Set RAWMASTER_PREVIEW_BENCHMARK_RAW to a qualification RAW.")
    }
    let file = URL(fileURLWithPath: path)
    let snapshot = EditingSourceSnapshot(projectID: "s1", assetID: "raw", contentSHA256: try RenderFiles.hash(file),
      byteCount: try PreviewFileStamp.read(file).size, admissionFingerprint: "actual-raw", sourceLocation: file)
    let capture = try RenderFiles.verifiedPreviewCapture(snapshot)
    defer { try? FileManager.default.removeItem(at: capture.url.deletingLastPathComponent()) }
    let native = try PreviewNativeSource.openVerifiedRAW(capture, memoryLimit: memoryLimit)
    let decoder = try XCTUnwrap(CIRAWFilter(imageURL: capture.url))
    decoder.scaleFactor = 1
    decoder.isDraftModeEnabled = false
    let size = try XCTUnwrap(decoder.outputImage).extent.size
    let stock = DevelopmentLocalEditSourceBinding(sourceContentID: try RenderFiles.hash(capture.url),
      exifOrientation: Int(decoder.orientation.rawValue), orientedWidth: Int(size.width), orientedHeight: Int(size.height))
    try body(capture, native, stock)
  }

  func testConfiguredRAWMatchesStockAndChecksEachSourceBoundAdjustment() throws {
    try withRAW { capture, native, stock in
      let png = try DevelopmentMaskBitmap(width: 2, height: 2, values: [0, 64, 128, 255]).png()
      func mask(_ source: DevelopmentLocalEditSourceBinding) -> DevelopmentMaskLayerV3 {
        let snapshot = DevelopmentSemanticMaskSnapshot(source: source, target: .sky, generator: "S1",
                                                       width: 2, height: 2, png: png)
        return .init(kind: .subject, subjectPNG: png, semanticSnapshot: snapshot)
      }
      func whiteBalance(_ source: DevelopmentLocalEditSourceBinding) throws -> DevelopmentWhiteBalanceV3 {
        let state = try DevelopmentWhiteBalanceEngineV3.initialState(source: source, rawDefault: native.asShotWhiteBalance)
        return .init(enabled: true, resolvedState: state)
      }
      var edit = DevelopmentAdjustmentsV3()
      edit.masks = [mask(stock)]
      edit.localEdits.sourceBinding = stock
      edit.whiteBalance = try whiteBalance(stock)
      let worker = DevelopmentAnalysisCancellation()
      XCTAssertNil(try native.localSourceValidation(for: .init(), cancellation: worker))
      XCTAssertNil(try native.localSourceValidation(for: edit, cancellation: nil))
      let ordinary = try PreviewNativeSource(capture: capture.url, byteCount: capture.stamp.size, artifact: false, memoryLimit: 32)
      XCTAssertNil(try ordinary.localSourceValidation(for: edit, cancellation: worker))
      let proof = try native.localSourceValidation(for: edit, cancellation: worker)
      if ProcessInfo.processInfo.environment["RAWMASTER_VERIFIED_LOCAL_SOURCE_BINDING"] == "0" {
        XCTAssertNil(proof)
      } else {
        XCTAssertEqual(try XCTUnwrap(proof).withBinding(at: capture.url) { $0 }, stock)
      }
      try DevelopmentRendererV3.validateLocalSource(edit, capture: capture.url, isRAW: true)
      try DevelopmentRendererV3.validateLocalSource(edit, capture: capture.url, isRAW: true, verified: proof)

      var other = stock
      other.sourceContentID = String(repeating: stock.sourceContentID.first == "0" ? "1" : "0", count: 64)
      for group in 0..<3 {
        var changed = edit
        switch group {
        case 0: changed.masks = [mask(other)]
        case 1: changed.localEdits.sourceBinding = other
        default:
          var wrongOrientation = stock
          wrongOrientation.exifOrientation = stock.exifOrientation == 1 ? 3 : 1
          changed.whiteBalance = try whiteBalance(wrongOrientation)
        }
        XCTAssertThrowsError(try DevelopmentRendererV3.validateLocalSource(changed, capture: capture.url, isRAW: true, verified: proof))
      }
    }
  }

  func testWorkerRevocationAndIdenticalFileReplacementCannotReuseTheBinding() throws {
    try withRAW { capture, native, stock in
      var edit = DevelopmentAdjustmentsV3()
      edit.localEdits.sourceBinding = stock
      let worker = DevelopmentAnalysisCancellation()
      guard let proof = try native.localSourceValidation(for: edit, cancellation: worker) else {
        XCTAssertEqual(ProcessInfo.processInfo.environment["RAWMASTER_VERIFIED_LOCAL_SOURCE_BINDING"], "0")
        return
      }
      let directory = capture.url.deletingLastPathComponent()
      let clone = directory.appendingPathComponent("same-bytes")
      try FileManager.default.copyItem(at: capture.url, to: clone)
      XCTAssertThrowsError(try proof.withBinding(at: clone) { _ in XCTFail("A different path was accepted") }) {
        XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, capture.id)
      }
      XCTAssertThrowsError(try proof.withBinding(at: capture.url) { _ in worker.cancel(cause: .consumerClosing) }) {
        XCTAssertEqual($0 as? DevelopmentPreviewError, .superseded)
      }
      XCTAssertThrowsError(try native.localSourceValidation(for: edit, cancellation: worker)) {
        XCTAssertEqual($0 as? DevelopmentPreviewError, .superseded)
      }
      let next = try XCTUnwrap(native.localSourceValidation(for: edit, cancellation: DevelopmentAnalysisCancellation()))
      XCTAssertThrowsError(try next.withBinding(at: capture.url) { _ in
        try FileManager.default.moveItem(at: capture.url, to: directory.appendingPathComponent("original-inode"))
        try FileManager.default.moveItem(at: clone, to: capture.url)
      }) { XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, capture.id) }
      XCTAssertThrowsError(try DevelopmentRendererV3.validateLocalSource(edit, capture: capture.url, isRAW: true, verified: next)) {
        XCTAssertEqual(($0 as? PreviewCaptureFault)?.captureID, capture.id)
      }
    }
  }

  func testClearedPointwiseContextIsRetiredAfterRevocationAndItsUseLimit() throws {
    guard ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_CONTEXT_REUSE"] == "1" else {
      throw XCTSkip("Enable the canonical context reuse trial.")
    }
    try withRAW(memoryLimit: 512) { capture, native, _ in
      let sourceKey = capture.id.uuidString
      defer { FlashRawCanonicalTexturePool.shared.retire(sourceKey: sourceKey) }
      enum Revocation: Error { case fixture }
      var revoked = false
      let request = FlashRawNativeFiniteCheck.Request(mayCheckTexture: true, checkAuthority: {
        if revoked { throw Revocation.fixture }
        try native.validateCaptureAuthority()
      })
      var adjustments = DevelopmentAdjustmentsV3()
      adjustments.rawDecoder = .flashRaw031
      adjustments.light = .init(enabled: true, blackPoint: 0.1)
      let recipe = DevelopmentRecipe(adjustmentsV3: adjustments)
      func render() throws {
        let result = try autoreleasepool {
          try native.render(recipe: recipe, maxPixel: 2400, sourceKey: sourceKey, nativeFiniteCheck: request)
        }
        XCTAssertEqual(result.outputSize.width, 2400)
      }
      try render()
      let initial = native.context
      try render()
      XCTAssertTrue(native.context === initial)

      revoked = true
      XCTAssertThrowsError(try render()) { XCTAssertTrue($0 is Revocation) }
      revoked = false
      try render()
      let retried = native.context
      XCTAssertFalse(retried === initial)
      for _ in 0..<7 { try render(); XCTAssertTrue(native.context === retried) }
      try render()
      XCTAssertFalse(native.context === retried)
    }
  }
}
