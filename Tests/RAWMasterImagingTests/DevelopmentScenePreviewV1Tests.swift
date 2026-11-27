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
    } catch DevelopmentSceneGraphRendererV1.Failure.invalidImage {}
    let replacement = here.appendingPathComponent("other.ARW")
    try Data(count: count).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
    do { _ = try await render(.hdr2020, graph, fit); XCTFail("cache returned content for replaced inode") }
    catch DevelopmentScenePreviewV1.Failure.unavailableSource {}
    await service.releaseSource()
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
  private func pixels(_ texture: MTLTexture) throws -> [SIMD4<Float>] {
    let rowBytes = texture.width * 16, count = rowBytes * texture.height
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: count, options: .storageModeShared))
    let queue = try XCTUnwrap(texture.device.makeCommandQueue()), command = try XCTUnwrap(queue.makeCommandBuffer())
    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
      sourceSize: .init(width: texture.width, height: texture.height, depth: 1), to: buffer, destinationOffset: 0,
      destinationBytesPerRow: rowBytes, destinationBytesPerImage: count)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    XCTAssertEqual(command.status, .completed)
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count / 16))
  }
}
