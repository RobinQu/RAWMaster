import CryptoKit
import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentScenePreviewV1Tests: XCTestCase {
  func testRejectsDisplaySourceAndCancelledRequestBeforeGPUWork() async throws {
    let service = DevelopmentScenePreviewV1(), graph = try grade(ev: 0)
    let source = makeSource(URL(fileURLWithPath: "/never-read.jpg"), count: 24)
    do {
      _ = try await service.render(source: source, graph: graph, view: .init(), target: .hdr2020, sampling: .fit(maximumEdge: 800))
      XCTFail("display-referred input cannot become a scene")
    } catch DevelopmentScenePreviewV1.Failure.unsupportedSource {}
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.render(source: source, graph: graph, view: .init(), target: .sdr709, sampling: .fit(maximumEdge: 800))
    }
    do { _ = try await task.value; XCTFail("cancelled preview acquired source") } catch is CancellationError {}
    let counts = await service.observations()
    XCTAssertEqual(counts.raw + counts.graph + counts.display, 0)
  }

  func testUnreadableRAWIsNotReportedAsMissingDecoder() throws {
    guard FlashRawSource.isAvailable else { throw XCTSkip("Use the fixed FlashRaw runtime") }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Unreadable-\(UUID()).ARW")
    try Data("not a RAW".utf8).write(to: file, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertThrowsError(try FlashRawSource.open(file)) { error in
      guard case .decode = error as? FlashRawError else { return XCTFail("Expected a source error, got \(error)") }
    }
  }

  func testOptInMissingRuntimeIsReportedSeparatelyFromRAWCalibration() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FLASHRAW_DISABLE"] == "1", let path = environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
      throw XCTSkip("Disable FlashRaw and supply the fixed snow.ARW")
    }
    let url = URL(fileURLWithPath: path)
    let bytes = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let service = DevelopmentScenePreviewV1()
    do {
      _ = try await service.render(source: makeSource(url, count: Int64(bytes)), graph: grade(ev: 0),
        view: .init(), target: .sdr709, sampling: .fit(maximumEdge: 800))
      XCTFail("A scene was created without its decoder")
    } catch DevelopmentScenePreviewV1.Failure.decoderUnavailable {}
    let counts = await service.observations()
    XCTAssertEqual(counts.raw + counts.graph + counts.display, 0)
  }

  func testOptInSnowVisualizeUsesHDRLuminanceOnAnSDRDisplayAndRestoresCachedDerivatives() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Use fixed snow.ARW") }
    let url = URL(fileURLWithPath: path)
    let source = makeSource(url, count: Int64(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)))
    let service = DevelopmentScenePreviewV1(), graph = try grade(ev: 2)
    let sampling = DevelopmentScenePreviewV1.Sampling.fit(maximumEdge: 320)
    func show(_ target: DevelopmentSceneOutputStateV1.Target, visualize: Bool = false) async throws -> DevelopmentScenePreviewFrameV1 {
      try await service.render(source: source, graph: graph, view: .init(), target: target, sampling: sampling, visualizeHDR: visualize)
    }
    let hdr = try await show(.hdr2020), sdr = try await show(.sdr709)
    let diagnostic = try await show(.sdr709, visualize: true)
    XCTAssertEqual(diagnostic.target, .sdr709)
    XCTAssertNotEqual(diagnostic.id, sdr.id)
    let original = try pixels(hdr.texture), mapped = try pixels(diagnostic.texture)
    XCTAssertEqual(original.count, mapped.count)
    var counts = Array(repeating: 0, count: 5)
    for (pixel, sample) in zip(original, mapped) {
      let y = pixel.x * 0.2627 + pixel.y * 0.6780 + pixel.z * 0.0593
      if y <= 1 {
        counts[0] += 1
        XCTAssertEqual(sample.x, sample.y, accuracy: 0.0001)
        XCTAssertEqual(sample.y, sample.z, accuracy: 0.0001)
      } else {
        let band = min(3, Int(log2(y)))
        counts[band + 1] += 1
        XCTAssertEqual(sample, DevelopmentSceneOutputStateV1.HDRBand.visualizationColors[band])
      }
    }
    XCTAssertGreaterThan(counts[0], 0)
    XCTAssertGreaterThan(counts[1...].reduce(0, +), 0)
    let restoredSDR = try await show(.sdr709), restoredHDR = try await show(.hdr2020)
    XCTAssertEqual(restoredSDR.id, sdr.id)
    XCTAssertEqual(restoredHDR.id, hdr.id)
  }

  func testOptInRealARWPreviewReuseAndNativeROI() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Use fixed snow.ARW") }
    let here = FileManager.default.temporaryDirectory.appendingPathComponent("ScenePreview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: here, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: here) }
    let url = here.appendingPathComponent("雪.ARW")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
    let count = try XCTUnwrap((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize)
    let source = makeSource(url, count: Int64(count))
    XCTAssertEqual(try RenderFiles.hash(url), source.contentSHA256)
    let service = DevelopmentScenePreviewV1()
    let graph = try grade(ev: 4)
    let fit = DevelopmentScenePreviewV1.Sampling.fit(maximumEdge: 900)
    func render(_ target: DevelopmentSceneOutputStateV1.Target, _ graph: DevelopmentSceneGraphV1,
                _ sampling: DevelopmentScenePreviewV1.Sampling) async throws -> DevelopmentScenePreviewFrameV1 {
      try await service.render(source: source, graph: graph, view: .init(), target: target, sampling: sampling)
    }
    let hdr = try await render(.hdr2020, graph, fit)
    XCTAssertGreaterThan(try XCTUnwrap(hdr.execution).dispatches, 0)
    XCTAssertEqual(hdr.nativeSize, .init(width: 4000, height: 6000))
    XCTAssertEqual(hdr.texture.width, 600); XCTAssertEqual(hdr.texture.height, 900)
    XCTAssertEqual(hdr.texture.pixelFormat, .rgba32Float)
    XCTAssertGreaterThan(try peak(hdr), 1)
    let sdr = try await render(.sdr709, graph, fit)
    XCTAssertLessThanOrEqual(try peak(sdr), 1)
    let trimmed = try DevelopmentSceneGraphV1(graph: graph.graph, output: .init(sdrTrim: .init(exposureEV: -1, mapping: .balanced, highlightCompression: 0)))
    let trimmedSDR = try await render(.sdr709, trimmed, fit)
    XCTAssertNotEqual(trimmedSDR.id, sdr.id)
    let again = try await render(.hdr2020, trimmed, fit)
    XCTAssertEqual(again.id, hdr.id, "SDR trim and viewing switches reuse both RAW and the immutable HDR suffix")
    var observed = await service.observations()
    XCTAssertEqual([observed.raw, observed.graph, observed.display], [1, 1, 3])
    let roi = try await render(.hdr2020, trimmed, .pixels(window: .init(x: 0.375, y: 0.375, width: 0.125, height: 0.125)))
    XCTAssertEqual(roi.window, .init(x: 0.375, y: 0.375, width: 0.125, height: 0.125))
    XCTAssertEqual(roi.texture.width, 500); XCTAssertEqual(roi.texture.height, 750)
    let rawWindow = try DevelopmentSceneRAWV1(device: roi.texture.device).decode(url, region: MTLRegionMake2D(1500, 2250, 500, 750)).image
    let reference = try DevelopmentSceneGraphRendererV1(device: roi.texture.device).renderPreview(rawWindow,
      geometry: .init(width: 4000, height: 6000), graph: graph, view: .init(), viewing: .init(
        requested: .hdrTarget, currentHeadroom: 2, displayProfileSHA256: String(repeating: "b", count: 64)))
    XCTAssertEqual(try pixels(roi.texture), try pixels(reference.texture), "ROI keeps native sensor pixels and matches reference decode")
    observed = await service.observations()
    XCTAssertEqual([observed.raw, observed.graph, observed.display], [1, 2, 4])
    let native = DevelopmentScenePreviewV1.Sampling.pixels(window: try XCTUnwrap(roi.window))
    let bypass = try await service.render(source: source, graph: trimmed, view: .init(target: .bypass), target: .hdr2020, sampling: native)
    XCTAssertNotEqual(try pixels(bypass.texture), try pixels(roi.texture))
    let returnedFinal = try await render(.hdr2020, trimmed, native)
    XCTAssertEqual(returnedFinal.id, roi.id)
    XCTAssertEqual(returnedFinal.execution, roi.execution)
    XCTAssertEqual(bypass.execution?.backend, .passthrough)
    XCTAssertEqual(bypass.execution?.dispatches, 0)
    let returnedBypass = try await service.render(source: source, graph: trimmed, view: .init(target: .bypass), target: .hdr2020, sampling: native)
    XCTAssertEqual(returnedBypass.id, bypass.id)
    observed = await service.observations()
    XCTAssertEqual([observed.raw, observed.graph, observed.display], [1, 3, 5], "monitor switching reuses correctly tagged suffixes")
    let models = try DevelopmentSceneModelProgramV1(stages: [.denoise(amount: 20)])
    do {
      _ = try await service.render(source: source, graph: trimmed, view: .init(target: .bypass),
        target: .hdr2020, sampling: native, models: models)
      XCTFail("A model that requires the full image must not receive the old cached ROI frame")
    } catch DevelopmentScenePreviewV1.Failure.fullResolutionModelBudget {}
    let withModels = try DevelopmentSceneGraphV1(graph: trimmed.graph, output: trimmed.output, models: models)
    do {
      _ = try await service.render(source: source, graph: withModels, view: .init(), target: .hdr2020, sampling: fit)
      XCTFail("The 24 MP model program cannot run on the FIT proxy to evade the native budget")
    } catch DevelopmentScenePreviewV1.Failure.fullResolutionModelBudget {}
    do {
      _ = try await service.analyze(source: source, graph: withModels, view: .init())
      XCTFail("Scopes must honor the same full-resolution model budget")
    } catch DevelopmentScenePreviewV1.Failure.fullResolutionModelBudget {}
    let replacement = here.appendingPathComponent("other.ARW")
    try Data(count: count).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
    do { _ = try await render(.hdr2020, graph, fit); XCTFail("cache returned content for replaced inode") }
    catch DevelopmentScenePreviewV1.Failure.unavailableSource {}
    await service.releaseSource()
  }

  func testOptInReal60MPPreviewBudgetAndReturnTo24MP() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["RAWMASTER_SCENE_60MP_ARW"], let snow = env["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
      throw XCTSkip("Supply the authorized 60 MP DSC05995 and 24 MP snow ARWs")
    }
    let url = URL(fileURLWithPath: path), snowURL = URL(fileURLWithPath: snow)
    let digest = "7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89"
    let count = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let source = EditingSourceSnapshot(projectID: "037", assetID: "DSC05995", contentSHA256: digest, byteCount: Int64(count),
      admissionFingerprint: String(repeating: "d", count: 64), sourceLocation: url)
    XCTAssertEqual(try RenderFiles.hash(url), digest)
    let service = DevelopmentScenePreviewV1(), graph = try grade(ev: 4)
    let sampling = DevelopmentScenePreviewV1.Sampling.fit(maximumEdge: 960)
    func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
    var start = DispatchTime.now().uptimeNanoseconds
    let hdr = try await service.render(source: source, graph: graph, view: .init(), target: .hdr2020, sampling: sampling)
    let coldMs = elapsed(start)
    XCTAssertEqual(hdr.nativeSize, .init(width: 9504, height: 6336))
    XCTAssertEqual([hdr.texture.width, hdr.texture.height], [960, 640])
    let peakHDR = try peak(hdr)
    XCTAssertGreaterThan(peakHDR, 1)
    let window = CGRect(x: 0.625, y: 0.25, width: 0.125, height: 0.125)
    start = DispatchTime.now().uptimeNanoseconds
    let roi = try await service.render(source: source, graph: graph, view: .init(), target: .hdr2020, sampling: .pixels(window: window))
    let roiMs = elapsed(start)
    XCTAssertEqual(roi.window, window)
    XCTAssertEqual([roi.texture.width, roi.texture.height], [1188, 792])
    let rect = MTLRegionMake2D(5940, 1584, roi.texture.width, roi.texture.height)
    let budget = 440 * 1024 * 1024
    let rawStats = try autoreleasepool { () throws -> [String: Any] in
      let device = roi.texture.device, decoder = try DevelopmentSceneRAWV1(device: device)
      let mosaic = try decoder.prepare(url)
      XCTAssertThrowsError(try decoder.develop(mosaic, sampling: .native(nil), maximumBytes: budget)) {
        XCTAssertEqual($0 as? DevelopmentSceneRAWV1.Failure, .surfaceBudget)
      }
      let crop = try decoder.develop(mosaic, sampling: .native(rect), maximumBytes: budget)
      let full = try decoder.develop(mosaic, sampling: .native(nil))
      let values = try pixels(crop.image.texture)
      XCTAssertEqual(values, try pixels(full.image.texture, region: rect))
      let scene = try DevelopmentSceneGraphRendererV1(device: device).renderPreview(crop.image,
        geometry: .init(width: 9504, height: 6336), graph: graph, view: .init(), viewing: .init(requested: .hdrTarget,
          currentHeadroom: 2, displayProfileSHA256: String(repeating: "a", count: 64)))
      XCTAssertEqual(try pixels(roi.texture), try pixels(scene.texture))
      let fit = try decoder.develop(mosaic, sampling: .fit(width: 960, height: 640), maximumBytes: budget)
      let rawBytes = mosaic.texture.allocatedSize
      let fitBytes = rawBytes + fit.image.texture.allocatedSize + fit.sensorSaturation.allocatedSize
      let roiBytes = rawBytes + crop.image.texture.allocatedSize + crop.sensorSaturation.allocatedSize
      XCTAssertLessThanOrEqual(max(fitBytes, roiBytes), budget)
      let minRGB = values.reduce(Float.infinity) { min($0, $1.x, $1.y, $1.z) }
      let maxRGB = values.reduce(-Float.infinity) { max($0, $1.x, $1.y, $1.z) }
      let fullBytes = full.image.texture.allocatedSize + full.sensorSaturation.allocatedSize
      XCTAssertGreaterThan(fullBytes, budget)
      var minimum = Float.infinity, maximum = -Float.infinity, negative = 0, superwhite = 0
      for y in stride(from: 0, to: 6336, by: 128) {
        let stripe = MTLRegionMake2D(0, y, 9504, min(128, 6336 - y))
        for pixel in try pixels(full.image.texture, region: stripe) {
          let low = min(pixel.x, pixel.y, pixel.z), high = max(pixel.x, pixel.y, pixel.z)
          guard low.isFinite, high.isFinite, pixel.w == 1 else { throw DevelopmentSceneOutputV1.Failure.invalidPixel }
          minimum = min(low, minimum); maximum = max(high, maximum)
          if low < 0 { negative += 1 }
          if high > 1 { superwhite += 1 }
        }
      }
      XCTAssertGreaterThan(negative, 0)
      XCTAssertGreaterThan(superwhite, 0)
      return ["residentMosaicBytes": rawBytes, "mosaicAndFitBytes": fitBytes, "mosaicAndROIBytes": roiBytes,
              "fullAP1AndSaturationBytes": fullBytes, "roiMinAP1": minRGB, "roiMaxAP1": maxRGB,
              "fullMinAP1": minimum, "fullMaxAP1": maximum, "negativePixels": negative, "superwhitePixels": superwhite]
    }
    start = DispatchTime.now().uptimeNanoseconds
    let report = try await service.analyze(source: source, graph: graph, view: .init())
    let firstScopeMs = elapsed(start)
    XCTAssertEqual(report.size, .init(192, 128))
    XCTAssertEqual(report.samples.count, 24_576)
    XCTAssertTrue(report.canMeasureSensor && report.canMeasureTarget)
    XCTAssertGreaterThan(try XCTUnwrap(report.plots[.target]).maximum, 1)
    XCTAssertLessThanOrEqual(try XCTUnwrap(report.plots[.derivative]).maximum, 1)
    let receipt = try XCTUnwrap(report.execution)
    XCTAssertEqual(receipt.backend, .rust)
    XCTAssertEqual(report.forMonitor(nil).execution, receipt)
    var warmScopeMs: [Double] = []
    for i in 0..<35 {
      start = DispatchTime.now().uptimeNanoseconds
      let next = try await service.analyze(source: source, graph: graph, view: i.isMultiple(of: 2) ? .init(target: .bypass) : .init())
      if i >= 5 { warmScopeMs.append(elapsed(start)) }
      XCTAssertEqual(next.execution?.backend, i.isMultiple(of: 2) ? .passthrough : .rust)
    }
    do {
      _ = try await service.render(source: source, graph: graph, view: .init(), target: .hdr2020,
        sampling: .pixels(window: .init(x: 0, y: 0, width: 1, height: 1)))
      XCTFail("An oversized 1:1 window must retain the budget gate")
    } catch DevelopmentScenePreviewV1.Failure.resourceBudget {}
    let snowCount = try XCTUnwrap(snowURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let back = try await service.render(source: makeSource(snowURL, count: Int64(snowCount)), graph: graph, view: .init(),
      target: .hdr2020, sampling: sampling)
    XCTAssertEqual(back.nativeSize, .init(width: 4000, height: 6000))
    let counts = await service.observations()
    XCTAssertEqual([counts.raw, counts.graph, counts.display], [2, 3, 3])
    if let output = env["RAWMASTER_SCENE_60MP_PREVIEW_REPORT"] {
      let sorted = warmScopeMs.sorted()
      let evidence: [String: Any] = ["device": roi.texture.device.name, "sha256": digest, "fileBytes": count,
        "native": [9504, 6336], "fit": [960, 640], "nativeROI": [5940, 1584, 1188, 792], "hdrFitMaximum": peakHDR,
        "developmentBudgetBytes": budget, "metalAllocations": rawStats, "coldFitMs": coldMs, "firstNativeROIMs": roiMs,
        "firstScopesMs": firstScopeMs, "warmScopesMs": warmScopeMs, "warmScopesP95Ms": sorted[28],
        "scopeBackend": receipt.backend.rawValue, "scopeDispatches": receipt.dispatches, "scopeSamples": report.samples.count,
        "sensorMarked": report.count(.sensor, headroom: 1) ?? -1, "return24MP": [4000, 6000], "acquisitions": counts.raw]
      try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }
    await service.releaseSource()
  }

  func testOptInWGSLRealRAWPreviewAndMonitorMatchStrict039() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_SCENE_BACKEND"]?.lowercased() == "wgpu",
          let snow = environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"],
          let large = environment["RAWMASTER_SCENE_60MP_ARW"] else {
      throw XCTSkip("Select strict wgpu and supply the authorized 24 and 60 MP ARW fixtures")
    }
    typealias Graph = DevelopmentSceneGraphV1
    func nodeID(_ suffix: UInt8) -> UUID { UUID(uuid: (4, 3, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, suffix)) }
    let coverage = Graph.Node(id: nodeID(1), name: "Coverage",
      operation: .linearCoverage(start: .init(0.15, 0.10), end: .init(0.85, 0.90)))
    let lift = Graph.Node(id: nodeID(2), name: "Exposure and curve",
      operation: .corrector(image: .input, mask: coverage.id, exposureEV: 1,
        curve: [.init(-6, -5.5), .init(-2, -2.25), .init(0, 0.1), .init(3, 2.75)], strength: 0.85, enabled: true))
    let layer = Graph.Node(id: nodeID(3), name: "Ordered Layer",
      operation: .layer(base: .input, layers: [.init(.node(lift.id), weight: 0.5)], enabled: true))
    let graph = try Graph(graph: .init(nodes: [coverage, lift, layer], output: .node(layer.id)),
      output: .init(sdrTrim: .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
    let views: [(String, Graph.View)] = [("final", .init()), ("monitor", .init(target: .node(lift.id)))]
    let window = CGRect(x: 0.625, y: 0.25, width: 0.125, height: 0.125)
    let fixtures = [
      ("24MP", snow, "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2", 4000, 6000),
      ("60MP", large, "7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89", 9504, 6336),
    ]
    struct Witness {
      let label: String
      let size: [Int]
      let device: String
      let registryID: UInt64
      let execution: DevelopmentSceneExecutionReceiptV1
      let samples: [SIMD4<Float>]
    }
    var evidence: [[String: Any]] = []
    for (label, path, sha, nativeWidth, nativeHeight) in fixtures {
      let url = URL(fileURLWithPath: path)
      XCTAssertEqual(try RenderFiles.hash(url), sha)
      let bytes = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      let source = EditingSourceSnapshot(projectID: "m2-05", assetID: label, contentSHA256: sha,
        byteCount: Int64(bytes), admissionFingerprint: String(repeating: "a", count: 64), sourceLocation: url)
      let fitSize = nativeWidth > nativeHeight ? [960, 640] : [640, 960]
      let samplings: [(String, DevelopmentScenePreviewV1.Sampling, [Int], CGRect?)] = [
        ("fit", .fit(maximumEdge: 960), fitSize, nil),
        ("native", .pixels(window: window), [nativeWidth / 8, nativeHeight / 8], window),
      ]
      func capture(_ service: DevelopmentScenePreviewV1, backend: DevelopmentSceneExecutionReceiptV1.Backend) async throws -> [Witness] {
        do {
          var captures: [Witness] = []
          for (samplingLabel, sampling, expectedSize, expectedWindow) in samplings {
            for (viewLabel, view) in views {
              let frame = try await service.render(source: source, graph: graph, view: view, target: .hdr2020, sampling: sampling)
              let expectedNative = CGSize(width: nativeWidth, height: nativeHeight)
              let execution = try XCTUnwrap(frame.execution)
              XCTAssertEqual(frame.nativeSize, expectedNative)
              XCTAssertEqual(frame.window, expectedWindow)
              XCTAssertEqual(frame.target, .hdr2020)
              XCTAssertEqual(execution.backend, backend)
              XCTAssertNil(execution.fallbackReason)
              if backend == .rust {
                XCTAssertGreaterThan(execution.dispatches + execution.nodeCacheHits, 0)
              } else {
                XCTAssertEqual(execution.dispatches, 1)
              }
              XCTAssertLessThanOrEqual(execution.peakBytes, execution.budgetBytes)
              let texture = frame.texture, size = [texture.width, texture.height]
              XCTAssertEqual(size, expectedSize)
              XCTAssertEqual(texture.pixelFormat, .rgba32Float)
              XCTAssertEqual(texture.storageMode, .private)
              XCTAssertTrue(texture.usage.contains(.shaderRead))
              guard size == expectedSize else { throw DevelopmentScenePreviewV1.Failure.invalidViewport }
              // Small, aligned witnesses at two distinct points avoid full-frame test readbacks.
              let witnesses = [MTLRegionMake2D(texture.width / 4, texture.height / 4, 32, 32),
                               MTLRegionMake2D(texture.width * 3 / 4, texture.height * 3 / 4, 32, 32)]
              let samples = try witnesses.flatMap { try pixels(texture, region: $0) }
              captures.append(.init(label: samplingLabel + "-" + viewLabel, size: size, device: texture.device.name,
                registryID: texture.device.registryID, execution: execution, samples: samples))
            }
          }
          let observed = await service.observations()
          XCTAssertEqual([observed.raw, observed.graph, observed.display], [1, 4, 4])
          XCTAssertEqual(Set(captures.map(\.registryID)).count, 1)
          XCTAssertTrue(captures[0].samples != captures[1].samples, "FIT final and monitor must differ")
          XCTAssertTrue(captures[2].samples != captures[3].samples, "Native final and monitor must differ")
          await service.releaseSource()
          return captures
        } catch {
          await service.releaseSource()
          throw error
        }
      }
      let wgpu = try await capture(DevelopmentScenePreviewV1(), backend: .wgpu)
      let legacy = try await capture(DevelopmentScenePreviewV1(backend: .rust), backend: .rust)
      XCTAssertEqual(wgpu.map(\.label), legacy.map(\.label))
      for (actual, reference) in zip(wgpu, legacy) {
        XCTAssertEqual(actual.registryID, reference.registryID)
        XCTAssertEqual(actual.size, reference.size)
        XCTAssertEqual(actual.samples.count, reference.samples.count)
        var maxScaledRGBError: Float = 0
        var finite = true, alphaMatches = true
        for (a, b) in zip(actual.samples, reference.samples) {
          alphaMatches = alphaMatches && a.w.bitPattern == b.w.bitPattern
          for channel in 0..<3 {
            finite = finite && a[channel].isFinite && b[channel].isFinite
            maxScaledRGBError = max(maxScaledRGBError, abs(a[channel] - b[channel]) / max(1, abs(b[channel])))
          }
        }
        XCTAssertTrue(finite, label + "/" + actual.label)
        XCTAssertTrue(alphaMatches, label + "/" + actual.label)
        XCTAssertLessThanOrEqual(maxScaledRGBError, 0.00002, label + "/" + actual.label)
        if environment["RAWMASTER_SCENE_WGPU_PREVIEW_REPORT"] != nil {
          func digest(_ samples: [SIMD4<Float>]) -> String {
            samples.withUnsafeBytes { SHA256.hash(data: Data($0)) }.map { String(format: "%02x", $0) }.joined()
          }
          evidence.append(["sourceSHA256": sha, "nativeSize": [nativeWidth, nativeHeight], "case": actual.label,
            "pixelSize": actual.size, "device": actual.device, "registryID": String(actual.registryID),
            "sampleCount": actual.samples.count, "wgpuWitnessSHA256": digest(actual.samples),
            "legacy039WitnessSHA256": digest(reference.samples), "maxScaledRGBError": maxScaledRGBError, "alphaBitsMatch": alphaMatches,
            "execution": try JSONSerialization.jsonObject(with: JSONEncoder().encode(actual.execution)),
            "referenceExecution": try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference.execution))])
        }
      }
      XCTAssertEqual(try RenderFiles.hash(url), sha)
    }
    if let path = environment["RAWMASTER_SCENE_WGPU_PREVIEW_REPORT"] {
      let report: [String: Any] = ["scope": "resident display-linear HDR texture before AppKit presentation",
        "recipeSHA256": try EditingFingerprint.of(DevelopmentRecipe(sceneGraph: graph)),
        "nativeWindow": [window.minX, window.minY, window.width, window.height], "cases": evidence]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }
  }

  private func makeSource(_ url: URL, count: Int64) -> EditingSourceSnapshot {
    .init(projectID: "test", assetID: "test", contentSHA256: "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2",
          byteCount: count, admissionFingerprint: String(repeating: "a", count: 64), sourceLocation: url)
  }

  private func grade(ev: Float) throws -> DevelopmentSceneGraphV1 {
    let grade = DevelopmentSceneGraphV1.Node(name: "Grade", operation: .corrector(image: .input, mask: nil,
      exposureEV: ev, curve: [], strength: 1, enabled: true))
    return try .init(graph: .init(nodes: [grade], output: .node(grade.id)),
      output: .init(sdrTrim: .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
  }

  private func peak(_ frame: DevelopmentScenePreviewFrameV1) throws -> Float {
    try pixels(frame.texture).reduce(0) { max($0, $1.x, $1.y, $1.z) }
  }
  private func pixels(_ texture: MTLTexture, region: MTLRegion? = nil) throws -> [SIMD4<Float>] {
    let rect = region ?? MTLRegionMake2D(0, 0, texture.width, texture.height)
    let rowBytes = rect.size.width * 16, count = rowBytes * rect.size.height
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: count, options: .storageModeShared))
    let queue = try XCTUnwrap(texture.device.makeCommandQueue()), command = try XCTUnwrap(queue.makeCommandBuffer())
    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: rect.origin,
      sourceSize: rect.size, to: buffer, destinationOffset: 0,
      destinationBytesPerRow: rowBytes, destinationBytesPerImage: count)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    XCTAssertEqual(command.status, .completed)
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count / 16))
  }
}
