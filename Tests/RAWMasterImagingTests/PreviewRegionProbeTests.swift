import XCTest
import AppKit
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

/// Opt-in probe for scoping a 1:1 frame to the visible window.
///
/// It builds the shipped canonical graph once, then measures the two costs a region-scoped
/// `detail` frame would remove: the full-frame finite scan and the full-frame materialization.
/// Nothing here changes production code; it only answers whether a ROI transport is worth it.
final class PreviewRegionProbeTests: XCTestCase {
  private func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let started = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
  }

  private func context() -> CIContext {
    CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: 512])
  }

  func testOptInScopedDetailSavings() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_REGION_PROBE"] == "1",
          let path = environment["RAWMASTER_REGION_PROBE_SOURCE"] else {
      throw XCTSkip("Explicit source is required")
    }
    #if DEBUG
    throw XCTSkip("Release measurements required")
    #endif
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true, "Needs unified memory")
    let url = URL(fileURLWithPath: path)
    let native = try FlashRawImageFactory.linearImage(capture: url)
    XCTAssertGreaterThan(native.extent.width, 2400)
    let scale = 2400.0 / Double(max(native.extent.width, native.extent.height))
    let window = CGRect(x: 0.31, y: 0.27, width: scale, height: scale) // normalized, away from the origin
    let windowPixels = CGRect(x: (window.minX * native.extent.width).rounded(.down),
                              y: (window.minY * native.extent.height).rounded(.down),
                              width: (window.width * native.extent.width).rounded(),
                              height: (window.height * native.extent.height).rounded())
    var report: [[String: Any]] = []

    var adjustments = DevelopmentAdjustmentsV3()
    adjustments.rawDecoder = .flashRaw031
    let variants: [(String, (inout DevelopmentAdjustmentsV3) -> Void)] = [
      ("neutral", { _ in }),
      ("texture", { $0.advancedDetail.texture = .init(enabled: true, amount: 25) }),
    ]
    for (label, mutate) in variants {
      var p = adjustments
      mutate(&p)
      let recipe = DevelopmentRecipe(adjustmentsV3: p)
      let build = try measure {
        try DevelopmentRendererV3.develop(url, recipe: recipe, context: context())
      }
      let graph = build.0
      let extent = graph.image.extent
      print("REGION-PROBE \(label) graph-build+full-scan \(build.1) extent \(Int(extent.width))x\(Int(extent.height))")

      let fullScan = try measure {
        let c = context(); defer { c.clearCaches() }
        try DevelopmentColorEngineV3.validateFinite(graph.image, context: c)
      }
      print("REGION-PROBE \(label) finite-scan full \(fullScan.1)")

      let roiScan = try measure {
        let c = context(); defer { c.clearCaches() }
        try DevelopmentColorEngineV3.validateFinite(graph.image, context: c, region: windowPixels)
      }
      print("REGION-PROBE \(label) finite-scan roi \(roiScan.1)")

      let fullWrite = try measure {
        let c = context(); defer { c.clearCaches() }
        guard c.createCGImage(graph.image, from: extent, format: .RGBA8,
                              colorSpace: PhotoRenderer.sRGB, deferred: false) != nil
        else { throw DevelopmentError.unreadable }
      }
      print("REGION-PROBE \(label) materialize full \(fullWrite.1)")

      let roiWrite = try measure {
        let c = context(); defer { c.clearCaches() }
        guard c.createCGImage(graph.image, from: windowPixels, format: .RGBA8,
                              colorSpace: PhotoRenderer.sRGB, deferred: false) != nil
        else { throw DevelopmentError.unreadable }
      }
      print("REGION-PROBE \(label) materialize roi \(roiWrite.1)")
      report.append(["label": label,
        "nativeWidth": Int(extent.width), "nativeHeight": Int(extent.height),
        "windowWidth": Int(windowPixels.width), "windowHeight": Int(windowPixels.height),
        "buildPlusShippedScanMs": build.1,
        "finiteScanFullMs": fullScan.1, "finiteScanRoiMs": roiScan.1,
        "materializeFullMs": fullWrite.1, "materializeRoiMs": roiWrite.1])
    }
    if let output = environment["RAWMASTER_REGION_PROBE_OUTPUT"] {
      let payload: [String: Any] = [
        "schemaVersion": 1,
        "build": "release",
        "sourceSHA256": try RenderFiles.hash(url),
        "scope": "ROI probe: unmodified graph, region-scoped scan and materialize only",
        "windowFractionOfNativePixels": Double(windowPixels.width * windowPixels.height)
          / Double(native.extent.width * native.extent.height),
        "rows": report,
        "caveats": [
          "develop() here rebuilds the FlashRaw base per call, so buildMs is not the shipped detail path",
          "finiteScanFullMs measures the legacy full-frame reduction, not the banded native transport now shipped",
        ],
      ]
      try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }
  }
}
