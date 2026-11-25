import XCTest
import AppKit
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

/// Where does a 1:1 frame's time actually go, and what survives a repeat?
///
/// The 50-recipe matrix reports one 1:1 sample per recipe, so its median mixes first-use cost
/// with steady state. This probe renders the same windowed 1:1 request four times and reports the
/// per-render telemetry, so an optimisation targets the cost that is actually there.
final class DetailStageProfileProbe: XCTestCase {
  private func source() throws -> (URL, EditingSourceSnapshot) {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["RAWMASTER_REGION_PROBE_SOURCE"] else {
      throw XCTSkip("Explicit source is required")
    }
    let url = URL(fileURLWithPath: path)
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    return (url, EditingSourceSnapshot(projectID: "profile", assetID: "profile",
      contentSHA256: try RenderFiles.hash(url), byteCount: try XCTUnwrap(size).int64Value,
      admissionFingerprint: "profile", sourceLocation: url))
  }

  private func stages(_ telemetry: ImagePerformanceSnapshot) -> [(String, Double)] {
    telemetry.recent.map { ("\($0.operation) · \($0.stage)", $0.durationMilliseconds) }
  }

  func testOptInDetailStageProfile() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_DETAIL_PROFILE"] == "1" else {
      throw XCTSkip("Explicit probe opt-in is required")
    }
    let (url, snapshot) = try source()
    PreviewPerformancePreferences.mode = environment["RAWMASTER_DETAIL_PROFILE_TURBO"] == "1" ? .turbo : .balanced
    defer { PreviewPerformancePreferences.mode = .balanced }
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0,
      rawBaseCacheBytes: 1_073_741_824, interactiveEvaluation: .proxyV1, settledTransport: .viewport))
    let consumer = PreviewConsumerID()
    let session = try await service.open(source: .raw(snapshot))
    var adjustments = DevelopmentAdjustmentsV3()
    adjustments.rawDecoder = try DevelopmentRAWSourcePolicy.decoderForNewWork(at: url)
    let recipe = DevelopmentRecipe(adjustmentsV3: adjustments)
    let window = CGRect(x: 0.2475, y: 0.1875, width: 0.505, height: 0.505)

    // Settle first, then idle long enough for the warm-up step to run, then time the first 1:1
    // frame. That is the sequence a user actually performs.
    var revision: UInt64 = 0
    revision += 1
    _ = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
      consumerID: consumer, role: .primary, revision: revision, recipe: recipe, quality: .settled,
      viewport: .init(maxPixel: 2400)))
    try await Task.sleep(nanoseconds: 1_200_000_000)
    print("DETAIL-PROFILE prewarmed=\(DevelopmentPreviewService.detailPrewarmEnabled)")

    // A real adjustment sequence: the same kind of edit released five times with a different
    // value each time, so no bitmap cache entry can serve the next render.
    let heavy = environment["RAWMASTER_DETAIL_PROFILE_HEAVY"]
    for attempt in 0..<5 {
      revision += 1
      var varied = recipe
      switch heavy {
      case "texture": varied.adjustmentsV3?.advancedDetail.texture = .init(enabled: true, amount: 20 + Double(attempt) * 5)
      case "clarity": varied.adjustmentsV3?.advancedDetail.clarity = .init(enabled: true, amount: 20 + Double(attempt) * 5)
      case "brilliance": varied.adjustmentsV3?.light = .init(enabled: true, brilliance: 0.3 + Double(attempt) * 0.02, brillianceVersion: .adaptiveLocalV1)
      default: varied.adjustmentsV3?.light = .init(enabled: true, exposure: 0.1 + Double(attempt) * 0.02)
      }
      ImagePerformanceTelemetry.shared.reset()
      let started = DispatchTime.now().uptimeNanoseconds
      let frame = try await service.render(.init(sessionID: session.id,
        sourceGeneration: session.sourceGeneration, consumerID: consumer, role: .primary,
        revision: revision, recipe: varied, quality: .detail,
        viewport: .init(maxPixel: 0, window: window)))
      let total = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      print("DETAIL-PROFILE heavy=\(heavy ?? "exposure") attempt=\(attempt) total=\(String(format: "%.1f", total))ms out=\(Int(frame.outputPixelSize.width))x\(Int(frame.outputPixelSize.height))")
      for (name, ms) in stages(ImagePerformanceTelemetry.shared.snapshot()) {
        print("    \(String(format: "%8.2f", ms))  \(name)")
      }
    }
    await service.closeAll()
  }
}
