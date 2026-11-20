import XCTest
import AppKit
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

/// Opt-in on isolated authorized RAW copies only; no application store and no automatic benchmark in CI.
final class PreviewSessionBenchmarkTests: XCTestCase {
  private struct Baseline: Decodable { let samples: [Entry] }
  private struct Entry: Codable { let index: Int; let label: String; let recipe: DevelopmentRecipe; let rgba8SHA256: String }
  private struct Measurement: Codable {
    let index: Int; let label: String; let milliseconds: Double; let width: Int; let height: Int
    let rgba8SHA256: String; let physicalFootprint: UInt64
  }
  private struct Quality: Codable {
    let index: Int; let label: String; let width: Int; let height: Int
    let maximumChannelError: Int; let p99ChannelError: Int; let exactMatch: Bool
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func bytes(_ image: NSImage) throws -> (Data, Int, Int) {
    guard let bitmap = image.representations.first as? NSBitmapImageRep, let pointer = bitmap.bitmapData else { throw DevelopmentError.unreadable }
    return (Data(bytes: pointer, count: bitmap.bytesPerRow * bitmap.pixelsHigh), bitmap.pixelsWide, bitmap.pixelsHigh)
  }
  private static func footprint() -> UInt64 {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }
  func testOptInSame2400SessionPerformanceAndCanonicalParity() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RAWMASTER_PREVIEW_P1_BENCHMARK"] == "1", let rawPath = env["RAWMASTER_PREVIEW_BENCHMARK_RAW"],
      let outputPath = env["RAWMASTER_PREVIEW_BENCHMARK_OUTPUT"], let repoPath = env["RAWMASTER_PREVIEW_BENCHMARK_REPOSITORY"] else { throw XCTSkip("Explicit isolated P1 benchmark environment required") }
    let repo = URL(fileURLWithPath: repoPath), output = URL(fileURLWithPath: outputPath), raw = URL(fileURLWithPath: rawPath)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("p1-session.json").path) else { throw XCTSkip("Refuse to overwrite benchmark evidence") }
    let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: repo.appendingPathComponent("output/validation/019-preview-ux/baseline-performance/legacy-api.json")))
    let source = EditingSourceSnapshot(projectID: "isolated-019-benchmark", assetID: "DSC05994",
      contentSHA256: "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c", byteCount: 69_488_640,
      admissionFingerprint: "isolated-pinned-sample", sourceLocation: raw)
    let service = DevelopmentPreviewService(), consumer = PreviewConsumerID()
    let openedAt = DispatchTime.now().uptimeNanoseconds
    let info = try await service.open(source: .raw(source))
    let openMilliseconds = Double(DispatchTime.now().uptimeNanoseconds-openedAt)/1_000_000
    var samples: [Measurement] = []
    for entry in baseline.samples {
      let started = DispatchTime.now().uptimeNanoseconds
      let result = try await service.render(.init(sessionID: info.id, sourceGeneration: info.sourceGeneration, consumerID: consumer,
        role: .primary, revision: UInt64(entry.index), recipe: entry.recipe, quality: .settled, viewport: .init(maxPixel: 2400)))
      let duration = Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000
      let memory = Self.footprint(), pixels = try Self.bytes(result.image)
      samples.append(.init(index: entry.index, label: entry.label, milliseconds: duration, width: pixels.1, height: pixels.2,
        rgba8SHA256: Self.hash(pixels.0), physicalFootprint: memory))
    }
    let measuredStats = await service.statistics()
    XCTAssertEqual(measuredStats.sourceFullHashPasses, 1); XCTAssertEqual(measuredStats.sourceCaptures, 1)
    XCTAssertEqual(measuredStats.maximumObservedNativeRenders, 1)
    let old = DevelopmentService()
    var quality: [Quality] = []
    // Canonical cross-check is outside ALL performance intervals. Re-render both paths at identical geometry.
    for entry in baseline.samples {
      let expected = try await old.preview(source: source, recipe: entry.recipe, maxPixel: 2400)
      let actual = try await service.render(.init(sessionID: info.id, sourceGeneration: info.sourceGeneration, consumerID: consumer,
        role: .primary, revision: UInt64(entry.index+100), recipe: entry.recipe, quality: .settled))
      let a = try Self.bytes(actual.image), b = try Self.bytes(expected.image)
      XCTAssertEqual(a.1, b.1); XCTAssertEqual(a.2, b.2); XCTAssertEqual(a.0.count, b.0.count)
      var histogram = [Int](repeating: 0, count: 256)
      a.0.withUnsafeBytes { (ap: UnsafeRawBufferPointer) in b.0.withUnsafeBytes { (bp: UnsafeRawBufferPointer) in
        for index in 0..<min(ap.count, bp.count) { histogram[abs(Int(ap[index])-Int(bp[index]))] += 1 }
      } }
      let total = histogram.reduce(0,+), threshold = Int(ceil(Double(total)*0.99))
      var count = 0, p99 = 0
      for (error, n) in histogram.enumerated() { count += n; if count >= threshold { p99 = error; break } }
      let maximum = histogram.lastIndex(where: { $0 > 0 }) ?? 0
      quality.append(.init(index: entry.index, label: entry.label, width: a.1, height: a.2, maximumChannelError: maximum,
        p99ChannelError: p99, exactMatch: a.0 == b.0))
      XCTAssertLessThanOrEqual(p99, 1, "canonical2400 quality gate \(entry.label)")
    }
    try RenderFiles.verify(source)
    await service.closeAll()
    let warm = samples.dropFirst().map(\.milliseconds).sorted()
    let median = (warm[9] + warm[10])/2, p95 = warm[Int(ceil(Double(warm.count)*0.95))-1]
    let sourceNames = ["DevelopmentPreviewModels.swift", "DevelopmentPreviewService.swift", "PreviewNativeSource.swift", "DevelopmentService.swift", "ZoomableImageView.swift"]
    var hashes: [String: String] = [:]
    for name in sourceNames { hashes[name] = Self.hash(try Data(contentsOf: repo.appendingPathComponent("Sources/RAWMasterImaging/"+name))) }
    func dictionary<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    let report: [String: Any] = ["mode": "p1-canonical2400-session", "decoderVersion": info.decoderVersion,
      "inputSHA256": source.contentSHA256, "inputBytes": source.byteCount, "sourceSHA256": hashes,
      "openMilliseconds": openMilliseconds, "firstRenderMilliseconds": samples[0].milliseconds,
      "coldOpenAndFirstRenderMilliseconds": openMilliseconds + samples[0].milliseconds,
      "warmMedianMilliseconds": median, "warmP95Milliseconds": p95, "samples": try dictionary(samples),
      "quality": try dictionary(quality), "measuredStatistics": ["renders": measuredStats.completedRenders, "cacheHits": measuredStats.cacheHits,
        "captures": measuredStats.sourceCaptures, "fullHashPasses": measuredStats.sourceFullHashPasses, "hashBytes": measuredStats.sourceHashBytes,
        "statChecks": measuredStats.sourceStatChecks, "bitmapBytes": measuredStats.cachedBitmapBytes],
      "caveats": ["Same2400/no RAW scale adaptation/no decoder opt-in.", "First open includes verified capture/hash/filter/context creation; cold is first process use, not OS cache purge.",
        "Warm sequence includes honest repeated-recipe cache hits; per-sample times identify them. Canonical parity runs only after timing.",
        "API timings exclude UI debounce, AppKit draw return and WindowServer presentation. Physical footprint sampled after frame only, not continuous peak."]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("p1-session.json"), options: .withoutOverwriting)
    print("P1 canonical2400 open=\(openMilliseconds) cold+first=\(openMilliseconds+samples[0].milliseconds) warmMedian=\(median) p95=\(p95) quality=\(quality.map(\.p99ChannelError))")
  }
}
