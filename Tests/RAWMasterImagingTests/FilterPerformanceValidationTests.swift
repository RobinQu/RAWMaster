import AppKit
import CoreImage
import ImageIO
import Metal
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Opt-in controlled prototype. Production routing is not changed by this experiment.
/// Canonical and proxy candidates render through the same CIContext and RGBA8 destination.
final class FilterPerformanceValidationTests: XCTestCase {
  private struct Metric: Codable {
    let samplesMs: [Double]
    let medianMs: Double
    let p95Ms: Double
    let maxMs: Double
  }
  private struct RouteReport: Codable {
    let canonical: Metric
    let proxyNeutralSuffix: Metric
    let proxyFilterWithoutFiniteValidation: Metric
    let proxyRetainedLUT: Metric
    let proxyTrimmedLUT: Metric
    let coldProxyBaseMs: Double
    let p99ChannelError8Bit: Int
    let maximumChannelError8Bit: Int
  }
  private struct LUTReport: Codable {
    let coldPairAfterTrim: Metric
    let warmPairWithoutTrim: Metric
    let warmValidateOnly: Metric
  }
  private struct ThumbnailReport: Codable {
    let settledMainMs: Double
    let currentTenCandidateSetMs: Double
    let proxyPreparationMs: Double
    let proxyPreparationCold: Bool
    let tileCount: Int
    let proxyWidth: Int
    let proxyHeight: Int
  }
  private struct DirectThumbnailReport: Codable {
    let sourceSHA256: String
    let proxyPreparationMs: Double
    let candidateMs: [Double]
    let totalCandidatesMs: Double
    let warmSetMs: [Double]
    let completedCandidates: Int
    let proxyWidth: Int
    let proxyHeight: Int
    let error: String?
    let diagnosticStages: [String]
  }
  private struct ProductionServiceReport: Codable {
    let sourceSHA256: String
    let proxyVersion: String
    let interactive: Metric
    let allApproximate: Bool
    let outputWidth: Int
    let outputHeight: Int
    let proxyFills: Int
    let proxyHits: Int
    let canonicalFallbacks: UInt64
  }
  private struct CanonicalFilterEntry: Codable {
    let look: String
    let milliseconds: Double
    let width: Int
    let height: Int
    let approximate: Bool?
    let error: String?
  }
  private struct CanonicalFilterReport: Codable {
    let sourceSHA256: String
    let settled: [CanonicalFilterEntry]
    let exportMilliseconds: Double?
    let exportWidth: Int?
    let exportHeight: Int?
    let exportBytes: Int64?
    let exportError: String?
    let sourceSHA256After: String
    let resourceUnionAfterClose: Int
  }
  private struct Report: Codable {
    let protocolVersion: String
    let sourceSHA256: String
    let decoderVersion: String
    let device: String
    let nativeWidth: Int
    let nativeHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let route: RouteReport
    let lut: LUTReport
    let thumbnails: ThumbnailReport?
    let thumbnailError: String?
    let caveats: [String]
  }

  private func metric(_ values: [Double]) -> Metric {
    let sorted = values.sorted()
    precondition(!sorted.isEmpty)
    let median = sorted.count % 2 == 0
      ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
      : sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    return .init(samplesMs: values, medianMs: median, p95Ms: p95, maxMs: sorted.last!)
  }
  private func milliseconds(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
  private func recipe(_ look: DevelopmentPhotoFilterV3, _ intensity: Double) -> DevelopmentRecipe {
    var p = DevelopmentAdjustmentsV3()
    p.filter = .init(enabled: look != .original, selection: look, intensity: intensity)
    return .init(adjustmentsV3: p)
  }
  private func render(_ image: CIImage, to texture: MTLTexture, context: CIContext,
                      colorSpace: CGColorSpace, clamped: Bool) throws {
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
    destination.colorSpace = colorSpace
    destination.alphaMode = .premultiplied
    destination.isFlipped = clamped // F32 intermediate stays in CI coordinates; final RGBA8 is top-row-first.
    destination.isClamped = clamped
    destination.isDithered = false
    let task = try context.startTask(toRender: image, to: destination)
    _ = try task.waitUntilCompleted()
  }
  private func texture(_ device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
  }
  private func fitted(_ image: CIImage, width: Int, height: Int) -> CIImage {
    let normalized = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
    let scaled = normalized.samplingLinear().transformed(by: .init(
      scaleX: Double(width) / normalized.extent.width, y: Double(height) / normalized.extent.height))
    return PreviewInteractiveProxyV3.canvas(scaled, width: width, height: height)
  }
  private func canonicalGraph(_ source: URL, _ recipe: DevelopmentRecipe, rawBase: CIImage,
                              _ context: CIContext, width: Int, height: Int) throws -> CIImage {
    let graph = try DevelopmentRendererV3.develop(source, recipe: recipe, suppliedRawBase: rawBase, context: context)
    return fitted(graph.image, width: width, height: height)
  }
  private func bytes(_ texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&result, bytesPerRow: width * 4,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return result
  }
  private func error(_ a: [UInt8], _ b: [UInt8]) -> (p99: Int, maximum: Int) {
    precondition(a.count == b.count)
    var histogram = [Int](repeating: 0, count: 256)
    for i in a.indices { histogram[abs(Int(a[i]) - Int(b[i]))] += 1 }
    let threshold = Int(ceil(Double(a.count) * 0.99))
    var count = 0, p99 = 0
    for (value, frequency) in histogram.enumerated() {
      count += frequency
      if count >= threshold { p99 = value; break }
    }
    return (p99, histogram.lastIndex(where: { $0 > 0 }) ?? 0)
  }

  func testOptInControlledFilterProxyAndCachePerformance() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FILTER_PERF"] == "1",
          let sourcePath = environment["RAWMASTER_FILTER_PERF_SOURCE"],
          let outputPath = environment["RAWMASTER_FILTER_PERF_OUTPUT"] else {
      throw XCTSkip("Explicit real RAW and non-existing output directory are required")
    }
    #if DEBUG
    throw XCTSkip("Release measurement required")
    #endif
    let sourceURL = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let reportURL = output.appendingPathComponent("filter-performance-validation.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "Refuse to overwrite evidence")
    let sourceSHA = try RenderFiles.hash(sourceURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let snapshot = EditingSourceSnapshot(projectID: "filter-performance", assetID: "fixed-raw",
      contentSHA256: sourceSHA, byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
      admissionFingerprint: "filter-performance-v1", sourceLocation: sourceURL)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let context = CIContext(mtlDevice: device, options: [
      .workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue,
      .cacheIntermediates: false,
      .memoryTarget: 512
    ])
    let native = try PreviewNativeSource(capture: sourceURL, byteCount: snapshot.byteCount,
      artifact: false, memoryLimit: 512)
    let nativeSize = native.nativeSize
    let outputWidth = 2400, outputHeight = Int((Double(outputWidth) * nativeSize.height / nativeSize.width).rounded())
    XCTAssertEqual(nativeSize.width / nativeSize.height, Double(outputWidth) / Double(outputHeight), accuracy: 0.001)
    let baseTexture = try texture(device, width: outputWidth, height: outputHeight, format: .rgba32Float)
    let suffixTexture = try texture(device, width: outputWidth, height: outputHeight, format: .rgba32Float)
    let outputTexture = try texture(device, width: outputWidth, height: outputHeight, format: .rgba8Unorm)
    let validationScope = PreviewPresentationScope()
    defer { validationScope.closeAndRetire() }
    let validationLayout = try PreviewInteractiveLayout.make(width: 1, height: 1, float: true)
    let validationTickets = try validationScope.reserveSharedOperation(bytes: [validationLayout.bytes])
    let validationScratch = try PreviewInteractiveProxyStorage(layout: validationLayout,
      ticket: validationTickets[0], device: device)
    let alphaKernel = try XCTUnwrap(CIKernel.kernels(withMetalString: #"""
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    [[stitchable]] float4 filterPerfTransportAlpha(sampler src, destination dest) {
      float4 p = src.sample(src.transform(dest.coord()));
      return float4(p.rgb, clamp(p.a, 0.0, 1.0));
    }
    } }
    """#).first(where: { $0.name == "filterPerfTransportAlpha" }))
    let raw = try XCTUnwrap(CIRAWFilter(imageURL: sourceURL))
    let rawImage = try XCTUnwrap(raw.outputImage)
    let normalizedRaw = try XCTUnwrap(alphaKernel.apply(extent: rawImage.extent,
      roiCallback: { _, rect in rect }, arguments: [rawImage.samplingNearest()]))
    let baseStarted = DispatchTime.now().uptimeNanoseconds
    try render(fitted(normalizedRaw, width: outputWidth, height: outputHeight), to: baseTexture,
      context: context, colorSpace: DevelopmentColorEngineV3.linearSRGB, clamped: false)
    let coldProxyBaseMs = milliseconds(baseStarted)
    let base = try XCTUnwrap(CIImage(mtlTexture: baseTexture, options: [
      .colorSpace: DevelopmentColorEngineV3.linearSRGB
    ]))
    let scale = Double(outputWidth) / nativeSize.width

    func canonical(_ value: DevelopmentRecipe) throws {
      let graph = try canonicalGraph(sourceURL, value, rawBase: normalizedRaw, context,
        width: outputWidth, height: outputHeight)
      try render(graph, to: outputTexture, context: context, colorSpace: PhotoRenderer.sRGB, clamped: true)
    }
    func proxy(_ value: DevelopmentRecipe, validating: Bool = true) throws {
      let p = try XCTUnwrap(value.adjustmentsV3)
      // Match production: materialize the suffix exactly once before finite validation and output.
      let graph = try PreviewInteractiveProxyV3.suffix(p, source: base, sourceIsRAW: true,
        nativeSize: nativeSize, scale: scale, context: context, check: {})
      try render(graph, to: suffixTexture, context: context,
        colorSpace: DevelopmentColorEngineV3.linearSRGB, clamped: false)
      let joined = try XCTUnwrap(CIImage(mtlTexture: suffixTexture, options: [
        .colorSpace: DevelopmentColorEngineV3.linearSRGB
      ]))
      if validating {
        try PreviewInteractiveProxyV3.validate(joined, using: validationScratch, context: context, check: {})
      }
      try render(joined, to: outputTexture, context: context, colorSpace: PhotoRenderer.sRGB, clamped: true)
    }

    let values = [25, 37, 50, 62, 75, 100].map { recipe(.vivid, $0) }
    // Compile kernels and populate both interpolation planes before steady-state samples.
    try autoreleasepool { try canonical(recipe(.vivid, 37)) }
    try autoreleasepool { try proxy(recipe(.vivid, 37)) }
    try autoreleasepool { try proxy(recipe(.vivid, 62)) }
    var canonicalTimes: [Double] = [], neutralTimes: [Double] = [], noFiniteTimes: [Double] = []
    var proxyTimes: [Double] = [], trimmedTimes: [Double] = []
    for value in values {
      var start = DispatchTime.now().uptimeNanoseconds
      try autoreleasepool { try proxy(recipe(.original, 0)) }
      neutralTimes.append(milliseconds(start))
      start = DispatchTime.now().uptimeNanoseconds
      try autoreleasepool { try proxy(value, validating: false) }
      noFiniteTimes.append(milliseconds(start))
      start = DispatchTime.now().uptimeNanoseconds
      try autoreleasepool { try canonical(value) }
      canonicalTimes.append(milliseconds(start))
      start = DispatchTime.now().uptimeNanoseconds
      try autoreleasepool { try proxy(value) }
      proxyTimes.append(milliseconds(start))
    }
    // Match the current per-tile resource retirement behavior at the full-preview size.
    for value in values.prefix(3) {
      context.clearCaches()
      DevelopmentPhotoFilterResourceStore.shared.trimReady()
      autoreleasepool {}
      let start = DispatchTime.now().uptimeNanoseconds
      try autoreleasepool { try proxy(value) }
      trimmedTimes.append(milliseconds(start))
    }
    DevelopmentPhotoFilterResourceStore.shared.trimReady()
    context.clearCaches()
    autoreleasepool {}

    // Pixel comparison is outside timed sections and uses the exact same output texture contract.
    try autoreleasepool { try canonical(recipe(.vivid, 37)) }
    let canonicalPixels = bytes(outputTexture, width: outputWidth, height: outputHeight)
    try autoreleasepool { try proxy(recipe(.vivid, 37)) }
    let proxyPixels = bytes(outputTexture, width: outputWidth, height: outputHeight)
    let difference = error(canonicalPixels, proxyPixels)

    var coldPairs: [Double] = [], warmPairs: [Double] = [], validateOnly: [Double] = []
    for look in DevelopmentThumbnailEngine.filterOrder where look != .original {
      context.clearCaches()
      DevelopmentPhotoFilterResourceStore.shared.trimReady()
      autoreleasepool {}
      try autoreleasepool {
        var start = DispatchTime.now().uptimeNanoseconds
        let pair = try DevelopmentPhotoFilterResourceStore.shared.pair(
          .init(enabled: true, selection: look, intensity: 100))
        coldPairs.append(milliseconds(start))
        start = DispatchTime.now().uptimeNanoseconds
        let warm = try DevelopmentPhotoFilterResourceStore.shared.pair(.init(enabled: true, selection: look, intensity: 100))
        warmPairs.append(milliseconds(start))
        start = DispatchTime.now().uptimeNanoseconds
        try DevelopmentPhotoFilterResourceStore.shared.validate(.init(enabled: true, selection: look, intensity: 100))
        validateOnly.append(milliseconds(start))
        withExtendedLifetime(pair) {}
        withExtendedLifetime(warm) {}
      }
      DevelopmentPhotoFilterResourceStore.shared.trimReady()
      autoreleasepool {}
    }

    // Measure the actual current Service thumbnail contract separately from the controlled route.
    // Any functional failure is preserved as data and is never converted into a passing timing sample.
    var thumbnailReport: ThumbnailReport?, thumbnailError: String?
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0,
      interactiveEvaluation: .proxyV1))
    do {
      let consumer = PreviewConsumerID()
      let lease = try await service.open(source: .raw(snapshot))
      let neutral = DevelopmentRecipe(adjustmentsV3: .init())
      let settledStarted = DispatchTime.now().uptimeNanoseconds
      let preview = DevelopmentPreviewRequest(sessionID: lease.id, sourceGeneration: lease.sourceGeneration,
        consumerID: consumer, role: .primary, revision: 1, recipe: neutral, quality: .settled,
        viewport: .init(maxPixel: 2400))
      _ = try await service.render(preview)
      let settledMainMs = milliseconds(settledStarted)
      let facts = try await service.sourceFacts(sessionID: lease.id, sourceGeneration: lease.sourceGeneration)
      let thumbnailRequest = DevelopmentThumbnailRequest(registration: .init(visibleGeneration: 1),
        preview: preview, expectedRecipeFingerprint: try EditingFingerprint.of(neutral), kind: .filters,
        target: .filters192, presentationMode: .managedImage,
        expectedPhotoFilterResourceVersion: facts.photoFilterResourceVersion)
      let thumbnailStarted = DispatchTime.now().uptimeNanoseconds
      let ready = try await service.thumbnails(thumbnailRequest, progress: { _ in })
      let currentTenCandidateSetMs = milliseconds(thumbnailStarted)
      let presentation = try await service.adoptThumbnailPresentation(ready, registration: thumbnailRequest.registration)
      for tile in presentation.tiles { _ = try presentation.cgImage(tile: tile.index) }
      let descriptor = ready.descriptor
      await service.releaseThumbnailPresentation(presentation, registration: thumbnailRequest.registration)
      thumbnailReport = .init(settledMainMs: settledMainMs, currentTenCandidateSetMs: currentTenCandidateSetMs,
        proxyPreparationMs: Double(descriptor.preparationNanoseconds) / 1_000_000,
        proxyPreparationCold: descriptor.preparationCold, tileCount: descriptor.tiles.count,
        proxyWidth: descriptor.proxyWidth, proxyHeight: descriptor.proxyHeight)
    } catch {
      thumbnailError = String(reflecting: error)
    }
    await service.closeAll()
    DevelopmentPhotoFilterResourceStore.shared.trimReady()
    context.clearCaches()
    autoreleasepool {}
    XCTAssertEqual(try RenderFiles.hash(sourceURL), sourceSHA)

    let report = Report(protocolVersion: "controlled-filter-proxy-prototype-v1", sourceSHA256: sourceSHA,
      decoderVersion: native.decoder, device: device.name,
      nativeWidth: Int(nativeSize.width), nativeHeight: Int(nativeSize.height),
      outputWidth: outputWidth, outputHeight: outputHeight,
      route: .init(canonical: metric(canonicalTimes), proxyNeutralSuffix: metric(neutralTimes),
        proxyFilterWithoutFiniteValidation: metric(noFiniteTimes), proxyRetainedLUT: metric(proxyTimes),
        proxyTrimmedLUT: metric(trimmedTimes), coldProxyBaseMs: coldProxyBaseMs,
        p99ChannelError8Bit: difference.p99, maximumChannelError8Bit: difference.maximum),
      lut: .init(coldPairAfterTrim: metric(coldPairs), warmPairWithoutTrim: metric(warmPairs),
        warmValidateOnly: metric(validateOnly)),
      thumbnails: thumbnailReport, thumbnailError: thumbnailError,
      caveats: [
        "Controlled API-to-GPU-completion experiment; no AppKit draw, WindowServer presentation, or physical input",
        "Proxy prototype covers filter-only recipes and a materialized Core Image 2400px F32 base; production FlashRaw-base integration remains to be measured",
        "Canonical and proxy use the same normalized RAW input, CIContext and output texture, but this is not the production managed IOSurface transport",
        "Trimmed-LUT samples follow warm samples and are not independent cold-process launches",
        "Thumbnail errors are explicit in thumbnailError; a successful route report does not qualify a failed thumbnail run",
        "Current thumbnail set includes its actual settled-gated Service path; the independent-settled correctness evidence is covered by DevelopmentThumbnailTests"
      ])
    try JSONEncoder().encode(report).write(to: reportURL, options: .withoutOverwriting)
    print("FILTER-PERFORMANCE-VALIDATION \(reportURL.path)")
  }

  func testOptInDirectRealRAWFilterThumbnailsWithoutSettledGate() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FILTER_THUMBNAIL_PERF"] == "1",
          let sourcePath = environment["RAWMASTER_FILTER_THUMBNAIL_PERF_SOURCE"],
          let outputPath = environment["RAWMASTER_FILTER_THUMBNAIL_PERF_OUTPUT"] else {
      throw XCTSkip("Explicit real RAW and non-existing output directory are required")
    }
    #if DEBUG
    throw XCTSkip("Release measurement required")
    #endif
    let sourceURL = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let reportURL = output.appendingPathComponent("filter-thumbnail-direct-validation.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "Refuse to overwrite evidence")
    let sourceSHA = try RenderFiles.hash(sourceURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let snapshot = EditingSourceSnapshot(projectID: "filter-thumbnail-performance", assetID: "fixed-raw",
      contentSHA256: sourceSHA, byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
      admissionFingerprint: "filter-thumbnail-performance-v1", sourceLocation: sourceURL)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let native = try PreviewNativeSource(capture: sourceURL, byteCount: snapshot.byteCount,
      artifact: false, memoryLimit: 512)
    let binding = DevelopmentLocalEditSourceBinding(sourceContentID: sourceSHA,
      exifOrientation: native.originalEXIFOrientation, orientedWidth: Int(native.nativeSize.width),
      orientedHeight: Int(native.nativeSize.height))
    let neutral = DevelopmentRecipe(adjustmentsV3: .init())
    let preview = DevelopmentPreviewRequest(sessionID: .init(), sourceGeneration: 1, consumerID: .init(),
      role: .primary, revision: 1, recipe: neutral, quality: .settled, viewport: .init(maxPixel: 2400))
    let request = DevelopmentThumbnailRequest(registration: .init(visibleGeneration: 1), preview: preview,
      expectedRecipeFingerprint: try EditingFingerprint.of(neutral), kind: .filters, target: .filters192,
      presentationMode: .managedImage,
      expectedPhotoFilterResourceVersion: DevelopmentPhotoFilterEngineV3.capabilities().resourceVersion)
    let ledger = ThumbnailLedger(), contextOwner = ThumbnailWorkerContextV1()
    var proxy: ThumbnailProxy?
    var proxyPreparationMs = 0.0, totalCandidatesMs = 0.0
    var candidateTimes: [Double] = [], warmSetTimes: [Double] = [], failure: String?, diagnosticStages: [String] = []
    let candidatesStarted = DispatchTime.now().uptimeNanoseconds
    do {
      let proxyStarted = DispatchTime.now().uptimeNanoseconds
      proxy = try native.prepareThumbnailProxy(recipe: neutral, source: binding, generation: 1,
        ledger: ledger, device: device, contextOwner: contextOwner)
      proxyPreparationMs = milliseconds(proxyStarted)
      for index in DevelopmentThumbnailEngine.filterOrder.indices {
        let started = DispatchTime.now().uptimeNanoseconds
        try autoreleasepool {
          let value = try DevelopmentThumbnailEngine.managedTile(request, index: index, scalars: nil,
            proxy: try XCTUnwrap(proxy), ledger: ledger, device: device, contextOwner: contextOwner)
          defer { value.0.detach() }
          _ = try value.0.getImage()
        }
        candidateTimes.append(milliseconds(started))
      }
      totalCandidatesMs = milliseconds(candidatesStarted)
      for _ in 0..<8 {
        let setStarted = DispatchTime.now().uptimeNanoseconds
        for index in DevelopmentThumbnailEngine.filterOrder.indices {
          try autoreleasepool {
            let value = try DevelopmentThumbnailEngine.managedTile(request, index: index, scalars: nil,
              proxy: try XCTUnwrap(proxy), ledger: ledger, device: device, contextOwner: contextOwner)
            defer { value.0.detach() }
            _ = try value.0.getImage()
          }
        }
        warmSetTimes.append(milliseconds(setStarted))
      }
    } catch {
      totalCandidatesMs = milliseconds(candidatesStarted)
      failure = String(reflecting: error)
      if let proxy {
        do {
          let candidate = neutral // Index 0 is Original; no analysis scalars are involved.
          try DevelopmentThumbnailEngine.withContext(ledger: ledger, device: device, contextOwner: contextOwner) { context in
            try DevelopmentThumbnailEngine.withSuffix(candidate, proxy: proxy, context: context, geometry: true,
              ledger: ledger, expectedResourceVersion: request.expectedPhotoFilterResourceVersion,
              maximumPixel: request.target.maximumPixel,
              diagnostic: { record in
                diagnosticStages.append(record.stage + (record.errorCase.map { ":" + $0 } ?? ""))
              }) { image in
                diagnosticStages.append("body.extent:\(image.extent)")
                guard image.extent.minX == 0, image.extent.minY == 0,
                      image.extent == image.extent.integral,
                      max(image.extent.width, image.extent.height) <= Double(request.target.maximumPixel) else {
                  diagnosticStages.append("body.layoutGuard.failed")
                  throw DevelopmentThumbnailError.invalidEncoding
                }
                try DevelopmentColorEngineV3.validateFinite(image, context: context)
                diagnosticStages.append("body.finalFinite.passed")
                let owner = try ThumbnailSurface(width: Int(image.extent.width), height: Int(image.extent.height),
                  float: false, kind: .filters, ledger: ledger, device: device)
                do {
                  try owner.fill(image, context: context)
                  owner.finishProducer()
                  let backing = try ThumbnailImageBacking(copying: owner, tile: .init(index: 0,
                    summaryAmount: nil, filter: .original, actualRecipe: candidate,
                    actualRecipeFingerprint: try EditingFingerprint.of(candidate), width: owner.width,
                    height: owner.height, allocation: owner.allocation, storageFormat: "rgba8Unorm/top-row-first",
                    destinationColorSpace: "sRGB", destinationICCProfileSHA256: String(repeating: "0", count: 64),
                    alphaPolicy: "premultiplied"), ledger: ledger, kind: .filters)
                  _ = try backing.getImage()
                  backing.detach()
                  owner.retire()
                  diagnosticStages.append("body.surfaceAndCopy.passed")
                } catch {
                  owner.finishProducer(); owner.retire(); throw error
                }
              }
          }
          diagnosticStages.append("probe.passed")
        } catch {
          diagnosticStages.append("probe.threw:" + String(reflecting: error))
        }
      }
    }
    proxy?.surface.retire()
    DevelopmentPhotoFilterResourceStore.shared.trimReady()
    native.context.clearCaches()
    XCTAssertTrue(contextOwner.retire())
    autoreleasepool {}
    let report = DirectThumbnailReport(sourceSHA256: sourceSHA, proxyPreparationMs: proxyPreparationMs,
      candidateMs: candidateTimes, totalCandidatesMs: totalCandidatesMs, warmSetMs: warmSetTimes,
      completedCandidates: candidateTimes.count, proxyWidth: proxy?.surface.width ?? 0,
      proxyHeight: proxy?.surface.height ?? 0, error: failure, diagnosticStages: diagnosticStages)
    try JSONEncoder().encode(report).write(to: reportURL, options: .withoutOverwriting)
    print("FILTER-THUMBNAIL-DIRECT-VALIDATION \(reportURL.path)")
    XCTAssertNil(failure)
    XCTAssertEqual(candidateTimes.count, 10)
    XCTAssertEqual(ledger.snapshot().unionBytes, 0)
  }

  func testOptInProductionServiceFilterInteractivePerformance() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FILTER_SERVICE_PERF"] == "1",
          let sourcePath = environment["RAWMASTER_FILTER_SERVICE_PERF_SOURCE"],
          let outputPath = environment["RAWMASTER_FILTER_SERVICE_PERF_OUTPUT"] else {
      throw XCTSkip("Explicit real RAW and non-existing output directory are required")
    }
    #if DEBUG
    throw XCTSkip("Release measurement required")
    #endif
    let sourceURL = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let reportURL = output.appendingPathComponent("production-filter-interactive.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "Refuse to overwrite evidence")
    let sourceSHA = try RenderFiles.hash(sourceURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let snapshot = EditingSourceSnapshot(projectID: "production-filter-performance", assetID: "fixed-raw",
      contentSHA256: sourceSHA, byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
      admissionFingerprint: "production-filter-performance-v1", sourceLocation: sourceURL)
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0,
      interactiveEvaluation: .proxyV1))
    let consumer = PreviewConsumerID(), lease = try await service.open(source: .raw(snapshot))
    var revision: UInt64 = 0
    func render(_ intensity: Double) async throws -> DevelopmentPreviewFrame {
      revision += 1
      return try await service.render(.init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration,
        consumerID: consumer, role: .primary, revision: revision, recipe: recipe(.vivid, intensity),
        quality: .interactive, viewport: .init(maxPixel: 2400)))
    }
    var times: [Double] = [], approximate: [Bool] = []
    var outputWidth = 0, outputHeight = 0
    do {
      _ = try await render(37)
      _ = try await render(62)
      for intensity in [25.0, 37, 50, 62, 75, 100] {
        let started = DispatchTime.now().uptimeNanoseconds
        let frame = try await render(intensity)
        times.append(milliseconds(started)); approximate.append(frame.approximate)
        outputWidth = Int(frame.outputPixelSize.width); outputHeight = Int(frame.outputPixelSize.height)
      }
    } catch {
      await service.closeAll(); throw error
    }
    let stats = await service.statistics()
    let pool = await service.interactiveProxyStatisticsForTesting()
    await service.closeAll()
    DevelopmentPhotoFilterResourceStore.shared.trimReady()
    XCTAssertEqual(try RenderFiles.hash(sourceURL), sourceSHA)
    XCTAssertTrue(approximate.allSatisfy { $0 })
    XCTAssertEqual(stats.interactiveProxyCanonicalFallbacks, 0)
    XCTAssertEqual(pool.fills, 1); XCTAssertGreaterThanOrEqual(pool.hits, 6)
    let report = ProductionServiceReport(sourceSHA256: sourceSHA, proxyVersion: PreviewInteractiveProxyV3.version,
      interactive: metric(times), allApproximate: approximate.allSatisfy { $0 },
      outputWidth: outputWidth, outputHeight: outputHeight, proxyFills: pool.fills, proxyHits: pool.hits,
      canonicalFallbacks: stats.interactiveProxyCanonicalFallbacks)
    try JSONEncoder().encode(report).write(to: reportURL, options: .withoutOverwriting)
    print("PRODUCTION-FILTER-INTERACTIVE \(reportURL.path)")
  }

  func testOptInRealRAWFilterSettledAndExportValidation() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FILTER_CANONICAL_VALIDATION"] == "1",
          let sourcePath = environment["RAWMASTER_FILTER_CANONICAL_SOURCE"],
          let outputPath = environment["RAWMASTER_FILTER_CANONICAL_OUTPUT"] else {
      throw XCTSkip("Explicit real RAW and non-existing output directory are required")
    }
    #if DEBUG
    throw XCTSkip("Release validation required")
    #endif
    let sourceURL = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let reportURL = output.appendingPathComponent("real-raw-filter-canonical.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "Refuse to overwrite evidence")
    let sourceSHA = try RenderFiles.hash(sourceURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let snapshot = EditingSourceSnapshot(projectID: "filter-canonical-validation", assetID: "fixed-raw",
      contentSHA256: sourceSHA, byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
      admissionFingerprint: "filter-canonical-validation-v1", sourceLocation: sourceURL)
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0,
      interactiveEvaluation: .proxyV1))
    let consumer = PreviewConsumerID(), lease = try await service.open(source: .raw(snapshot))
    var entries: [CanonicalFilterEntry] = []
    for (offset, look) in DevelopmentThumbnailEngine.filterOrder.enumerated() {
      let started = DispatchTime.now().uptimeNanoseconds
      do {
        let frame = try await service.render(.init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration,
          consumerID: consumer, role: .primary, revision: UInt64(offset + 1), recipe: recipe(look, 37),
          quality: .settled, viewport: .init(maxPixel: 2400)))
        if let bitmap = frame.image.representations.first as? NSBitmapImageRep { _ = bitmap.bitmapData }
        entries.append(.init(look: look.rawValue, milliseconds: milliseconds(started),
          width: Int(frame.outputPixelSize.width), height: Int(frame.outputPixelSize.height),
          approximate: frame.approximate, error: nil))
      } catch {
        entries.append(.init(look: look.rawValue, milliseconds: milliseconds(started),
          width: 0, height: 0, approximate: nil, error: String(reflecting: error)))
      }
    }
    await service.closeAll()
    var exportMs: Double?, exportWidth: Int?, exportHeight: Int?, exportBytes: Int64?, exportError: String?
    let exportStarted = DispatchTime.now().uptimeNanoseconds
    do {
      let exported = try await DevelopmentService().render(source: snapshot, recipe: recipe(.vivid, 37),
        format: .png16, destination: output.appendingPathComponent("filter-vivid-37.png"))
      exportMs = milliseconds(exportStarted)
      exportWidth = exported.artifact.pixelWidth; exportHeight = exported.artifact.pixelHeight
      exportBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: exported.fileURL.path)[.size] as? NSNumber).int64Value
      let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(exported.fileURL as CFURL, nil))
      let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [String: Any])
      XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, exported.artifact.pixelWidth)
      XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, exported.artifact.pixelHeight)
    } catch {
      exportMs = milliseconds(exportStarted); exportError = String(reflecting: error)
    }
    PhotoRenderer.renderingContext(recipe(.vivid, 37)).clearCaches()
    DevelopmentPhotoFilterResourceStore.shared.trimReady()
    autoreleasepool {}
    let charge = DevelopmentPhotoFilterCharge.snapshot()
    let report = CanonicalFilterReport(sourceSHA256: sourceSHA, settled: entries,
      exportMilliseconds: exportMs, exportWidth: exportWidth, exportHeight: exportHeight,
      exportBytes: exportBytes, exportError: exportError,
      sourceSHA256After: try RenderFiles.hash(sourceURL), resourceUnionAfterClose: charge.union)
    try JSONEncoder().encode(report).write(to: reportURL, options: .withoutOverwriting)
    print("REAL-RAW-FILTER-CANONICAL \(reportURL.path)")
    XCTAssertTrue(entries.allSatisfy { $0.error == nil && $0.approximate == false })
    XCTAssertNil(exportError); XCTAssertNotNil(exportBytes); XCTAssertEqual(report.sourceSHA256After, sourceSHA)
    XCTAssertEqual(charge.union, 0, "loading=\(charge.loading), ready=\(charge.ready), active=\(charge.active), retiring=\(charge.retiring)")
  }
}
