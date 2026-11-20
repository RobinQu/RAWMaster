import AppKit
import CoreImage
import CryptoKit
import Darwin
import Foundation
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Opt-in only. Phase A calls the unchanged production API and a stage-timed copy of that exact path.
/// Run each mode in a separate test process. No application target or user catalogue is involved.
final class PreviewBaselineBenchmarkTests: XCTestCase {
  private static let productionSourceSHA = "0b1fae4162248da33ad6960dbad96f03255286cc96621614fcd2c73b981ddd30"
  private static let rawSHA = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
  private struct Sample: Codable {
    let index: Int
    let phase: String
    let label: String
    let recipe: DevelopmentRecipe
    let maxPixel: Int
    let width: Int
    let height: Int
    let wallMilliseconds: Double
    let stagesMilliseconds: [String: Double]
    let rgba8SHA256: String
    let sampledPhysicalFootprint: UInt64
    let sampledResidentBytes: UInt64
  }
  private struct Report: Codable {
    let mode: String
    let productionSourceSHA256: String
    let probeSourceSHA256: String
    let inputSHA256: String
    let inputBytes: Int64
    let maxPixel: Int
    let coldDefinition: String
    let processID: Int32
    let os: String
    let processorCount: Int
    let physicalMemory: UInt64
    let decoderVersion: String
    let contextCacheIntermediates: Bool
    let rawScaleFactor: Double
    let draft: Bool
    let samples: [Sample]
    let warmMedianMilliseconds: Double
    let warmP95Milliseconds: Double
    let coldMilliseconds: Double
    let stageWarmMediansMilliseconds: [String: Double]
    let caveats: [String]
  }
  private final class Timings: @unchecked Sendable {
    var values: [String: Double] = [:]
    func measure<T>(_ key: String, _ operation: () throws -> T) rethrows -> T {
      let start = DispatchTime.now().uptimeNanoseconds
      defer { values[key] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
      return try operation()
    }
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func memory() -> (UInt64, UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? (info.phys_footprint, info.resident_size) : (0, 0)
  }
  private static var recipes: [(String, DevelopmentRecipe)] {
    var result: [(String, DevelopmentRecipe)] = [("as-shot-cold", .init())]
    for value in [-2.0, -1.5, -1.0, -0.5, 0, 0.5, 1, 1.5, 2] { result.append(("EV=\(value)", .init(exposureEV: value))) }
    result += [
      ("WB3500", .init(whiteBalance: .temperatureTint(temperature: 3500, tint: 0))),
      ("WB4500-tint-25", .init(whiteBalance: .temperatureTint(temperature: 4500, tint: -25))),
      ("WB6500-tint20", .init(whiteBalance: .temperatureTint(temperature: 6500, tint: 20))),
      ("WB9000", .init(whiteBalance: .temperatureTint(temperature: 9000, tint: 0))),
      ("as-shot-after-WB", .init(exposureEV: 0.5)),
      ("straighten-crop", .init(exposureEV: 0.25, straightenDegrees: 1.2, crop: .init(x: 0.04, y: 0.04, width: 0.92, height: 0.92))),
      ("crop", .init(crop: .init(x: 0.2, y: 0.1, width: 0.6, height: 0.8))),
      ("straighten-3", .init(straightenDegrees: -3)),
      ("reset-as-shot-1", .init()),
      ("WB6500", .init(whiteBalance: .temperatureTint(temperature: 6500, tint: 0))),
      ("reset-as-shot-2", .init())
    ]
    return result
  }

  func testOptInLegacy2400ColdAndWarm20() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let mode = env["RAWMASTER_PREVIEW_BENCHMARK_MODE"], ["legacy-api", "legacy-staged"].contains(mode),
      let inputPath = env["RAWMASTER_PREVIEW_BENCHMARK_RAW"], let outputPath = env["RAWMASTER_PREVIEW_BENCHMARK_OUTPUT"],
      let repoPath = env["RAWMASTER_PREVIEW_BENCHMARK_REPOSITORY"] else { throw XCTSkip("Explicit isolated baseline benchmark environment required") }
    let repository = URL(fileURLWithPath: repoPath)
    let sourceFile = repository.appendingPathComponent("Sources/RAWMasterImaging/DevelopmentService.swift")
    XCTAssertEqual(Self.digest(try Data(contentsOf: sourceFile)), Self.productionSourceSHA, "Phase A must use unchanged legacy source")
    let input = URL(fileURLWithPath: inputPath), output = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: output.appendingPathComponent(mode + ".json").path) else { throw XCTSkip("Refuse to overwrite completed benchmark evidence") }
    let inputBytes = (try FileManager.default.attributesOfItem(atPath: input.resolvingSymlinksInPath().path)[.size] as! NSNumber).int64Value
    XCTAssertEqual(inputBytes, 69_488_640)
    let source = EditingSourceSnapshot(projectID: "isolated-019-benchmark", assetID: "DSC05994", contentSHA256: Self.rawSHA,
      byteCount: inputBytes, admissionFingerprint: "isolated-pinned-sample", sourceLocation: input)
    let service = DevelopmentService()
    var samples: [Sample] = []
    for (index, entry) in Self.recipes.enumerated() {
      let start = DispatchTime.now().uptimeNanoseconds
      let frame: DevelopmentPreview
      let timing = Timings()
      if mode == "legacy-api" { frame = try await service.preview(source: source, recipe: entry.1, maxPixel: 2400) }
      else { frame = try await Self.stagedPreview(source: source, recipe: entry.1, timings: timing) }
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      let memory = Self.memory()
      let bitmapHash = try autoreleasepool { () throws -> String in
        guard let bitmap = frame.image.representations.first as? NSBitmapImageRep, let bytes = bitmap.bitmapData else { throw DevelopmentError.unreadable }
        let hash = Self.digest(Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
        // Reference encoding happens after the measured API duration, never included in preview latency.
        if [0, 7, 12, 15, 20].contains(index), let png = bitmap.representation(using: .png, properties: [:]) {
          try png.write(to: output.appendingPathComponent("\(mode)-reference-\(index).png"), options: .withoutOverwriting)
        }
        return hash
      }
      let sample = Sample(index: index, phase: index == 0 ? "process-cold" : "warm", label: entry.0, recipe: entry.1, maxPixel: 2400,
        width: frame.pixelWidth, height: frame.pixelHeight, wallMilliseconds: elapsed, stagesMilliseconds: timing.values,
        rgba8SHA256: bitmapHash, sampledPhysicalFootprint: memory.0, sampledResidentBytes: memory.1)
      samples.append(sample)
      let line = try JSONEncoder().encode(sample)
      let log = output.appendingPathComponent(mode + ".jsonl")
      if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
      let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.write(contentsOf: Data([10])); try handle.close()
    }
    XCTAssertEqual(samples.count, 21)
    XCTAssertEqual(try RenderFiles.hash(input), Self.rawSHA)
    let decoder = CIRAWFilter(imageURL: input)?.decoderVersion.rawValue ?? "unknown"
    let warm = Array(samples.dropFirst()), sorted = warm.map(\.wallMilliseconds).sorted()
    let keys = Set(warm.flatMap { $0.stagesMilliseconds.keys })
    var medians: [String: Double] = [:]
    for key in keys { let values = warm.compactMap { $0.stagesMilliseconds[key] }.sorted(); medians[key] = values[values.count / 2] }
    let report = Report(mode: mode, productionSourceSHA256: Self.productionSourceSHA,
      probeSourceSHA256: Self.digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))), inputSHA256: Self.rawSHA,
      inputBytes: inputBytes, maxPixel: 2400, coldDefinition: "first preview in this test process; OS file/Metal caches were not flushed", processID: ProcessInfo.processInfo.processIdentifier,
      os: ProcessInfo.processInfo.operatingSystemVersionString, processorCount: ProcessInfo.processInfo.processorCount,
      physicalMemory: ProcessInfo.processInfo.physicalMemory, decoderVersion: decoder, contextCacheIntermediates: false, rawScaleFactor: 1, draft: false,
      samples: samples, warmMedianMilliseconds: sorted[sorted.count / 2], warmP95Milliseconds: sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], coldMilliseconds: samples[0].wallMilliseconds,
      stageWarmMediansMilliseconds: medians,
      caveats: ["No screen presentation or controller 150ms debounce included", "One cold observation is reported directly, not as a p95", "Memory is sampled after each render, not a continuous peak", "Native CGImage stage includes lazy RAW processing, GPU/CPU work and readback; not pure GPU kernel time", "Stage probe duplicates legacy RAW branch/geometry but calls real verify/capture/context; frozen source SHA identifies provenance", "PNG references and pixel hashes are produced outside timed interval", "No Triage/user catalogue/Adobe RAW loading"])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output.appendingPathComponent(mode + ".json"), options: .withoutOverwriting)
    XCTAssertEqual(Self.digest(try Data(contentsOf: sourceFile)), Self.productionSourceSHA)
  }

  private static func stagedPreview(source: EditingSourceSnapshot, recipe: DevelopmentRecipe, timings: Timings) async throws -> DevelopmentPreview {
    try await renderingTask {
      try timings.measure("headVerifyHash") { try RenderFiles.verify(source) }
      let captured = try timings.measure("captureCopyHashFsync") { try RenderFiles.capture(source) }
      defer { timings.measure("ownedCaptureCleanup") { try? FileManager.default.removeItem(at: captured.deletingLastPathComponent()) } }
      try recipe.validate()
      guard recipe.engineVersion == "core-image-v1" else { throw DevelopmentError.unsupportedEngine }
      let raw = try timings.measure("rawFilterInit") { () throws -> CIRAWFilter in
        guard let value = CIRAWFilter(imageURL: captured) else { throw DevelopmentError.unreadable }; return value
      }
      var image = try timings.measure("rawParametersAndOutputGraph") { () throws -> CIImage in
        raw.scaleFactor = 1; raw.isDraftModeEnabled = false; raw.exposure = Float(recipe.exposureEV)
        if case let .temperatureTint(temperature, tint) = recipe.whiteBalance { raw.neutralTemperature = Float(temperature); raw.neutralTint = Float(tint) }
        guard let value = raw.outputImage else { throw DevelopmentError.unreadable }; return value
      }
      image = try timings.measure("canonicalGeometryGraph") {
        guard !image.extent.isEmpty, !image.extent.isInfinite else { throw DevelopmentError.unreadable }
        var value = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if recipe.straightenDegrees != 0 {
          let w = value.extent.width, h = value.extent.height
          let angle = recipe.straightenDegrees * .pi / 180
          value = value.transformed(by: CGAffineTransform(translationX: -w/2, y: -h/2)).transformed(by: CGAffineTransform(rotationAngle: angle))
          let size = PhotoRenderer.inscribedSize(width: w, height: h, angle: abs(angle))
          value = value.cropped(to: CGRect(x: -size.width/2, y: -size.height/2, width: size.width, height: size.height))
          value = value.transformed(by: CGAffineTransform(translationX: -value.extent.minX, y: -value.extent.minY))
        }
        let bounds = value.extent, crop = recipe.crop
        let rect = CGRect(x: bounds.width * crop.x, y: bounds.height * (1 - crop.y - crop.height), width: bounds.width * crop.width, height: bounds.height * crop.height)
        let pixels = CGRect(x: ceil(rect.minX), y: ceil(rect.minY), width: floor(rect.maxX) - ceil(rect.minX), height: floor(rect.maxY) - ceil(rect.minY))
        guard pixels.width >= 1, pixels.height >= 1 else { throw DevelopmentError.invalidGeometry }
        return value.cropped(to: pixels).transformed(by: CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
      }
      image = timings.measure("displayDownsampleGraph") {
        let limit = 2400
        let factor = min(1, Double(limit) / max(image.extent.width, image.extent.height))
        return factor < 1 ? image.transformed(by: CGAffineTransform(scaleX: factor, y: factor)) : image
      }
      let cg = try timings.measure("nativeCreateCGImageIncludingLazyRAWAndReadback") {
        guard let value = PhotoRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB) else { throw DevelopmentError.unreadable }; return value
      }
      let display = timings.measure("bitmapAndNSImageBridge") {
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let value = NSImage(size: NSSize(width: cg.width, height: cg.height)); value.addRepresentation(bitmap); return value
      }
      try timings.measure("tailVerifyHash") { try RenderFiles.verify(source) }
      return DevelopmentPreview(image: display, pixelWidth: cg.width, pixelHeight: cg.height)
    }
  }
}
