import CoreImage
import CryptoKit
import Darwin
import Foundation
import Metal
import RAWMasterCore

/// Isolated render/publication component. The caller owns catalogue admission, version and volume tickets.
package enum DevelopmentSceneDeliveryServiceV1 {
  package enum Failure: Error, Equatable { case unsupportedSource, invalidDestination, incompatibleRenditions }

  package struct Receipt: Equatable, Sendable {
    package let versionID: UUID
    package let sourceSHA256: String
    package let workflowSHA256: String
    package let target: DevelopmentSceneOutputStateV1.Target
    package let format: DevelopmentSceneDeliveryV1.Format
    package let artifact: RenderArtifact
    package let matrix: Int?
    package let execution: DevelopmentSceneExecutionReceiptV1?
  }

  package struct Rendition: Sendable {
    package let delivery: DevelopmentSceneDeliveryV1
    package let destination: URL
    package let preparePublication: RenderPublicationPreparation?

    package init(_ delivery: DevelopmentSceneDeliveryV1, to destination: URL,
                 preparePublication: RenderPublicationPreparation? = nil) {
      self.delivery = delivery
      self.destination = destination
      self.preparePublication = preparePublication
    }
  }

  package static func export(_ delivery: DevelopmentSceneDeliveryV1, to destination: URL,
                             protectedURLs: [URL] = [], preparePublication: RenderPublicationPreparation? = nil) async throws -> Receipt {
    let result = try await exportTogether([.init(delivery, to: destination, preparePublication: preparePublication)],
      protectedURLs: protectedURLs)
    return try result[0].get()
  }

  /// Shares the immutable source and calibrated mosaic. Large graph outputs render bounded regions per target.
  /// Source admission and scene preparation failures affect every rendition and are returned as a thrown error.
  package static func exportTogether(_ renditions: [Rendition], protectedURLs: [URL] = []) async throws -> [Result<Receipt, Error>] {
    guard let frozen = renditions.first?.delivery, renditions.count <= DevelopmentSceneDeliveryV1.Format.allCases.count,
          Set(renditions.map(\.delivery.format)).count == renditions.count,
          renditions.allSatisfy({ $0.delivery.source == frozen.source && $0.delivery.versionID == frozen.versionID && $0.delivery.program == frozen.program }) else {
      throw Failure.incompatibleRenditions
    }
    let source = frozen.source
    guard source.sourceLocation.pathExtension.lowercased() == "arw" else { throw Failure.unsupportedSource }
    let protected = protectedURLs + [source.sourceLocation]
    let fingerprint = try frozen.program.fingerprint()
    return try await renderingTask(lane: .export) {
      let canonicalPaths = renditions.filter { $0.destination.isFileURL }.map { RenderFiles.canonical($0.destination).path }
      guard Set(canonicalPaths).count == canonicalPaths.count else { throw Failure.incompatibleRenditions }
      let preflight: [Error?] = renditions.map { item in
        do {
          guard item.destination.isFileURL, item.destination.pathExtension.lowercased() == item.delivery.format.filenameExtension else {
            throw Failure.invalidDestination
          }
          try RenderFiles.check(item.destination, protected: protected)
          return nil
        } catch { return error }
      }
      let failures = preflight.compactMap { $0 }
      if failures.count == renditions.count { return failures.map { .failure($0) } }
      let capture = try RenderFiles.verifiedPreviewCapture(source)
      defer { try? FileManager.default.removeItem(at: capture.url.deletingLastPathComponent()) }
      let prepared = try autoreleasepool {
        try capture.withCurrent(at: capture.url) { try prepare(capture.url, program: frozen.program) }
      }
      return zip(renditions, preflight).map { item, failure in
        if let failure { return .failure(failure) }
        return Result {
          try autoreleasepool {
            // Keep the requested path: resolving it once would hide a subsequent symlink/volume replacement.
            let target = item.destination.standardizedFileURL
            let delivery = item.delivery
            let (display, execution) = try prepared.render(delivery.target)
            let artifact: RenderArtifact, matrix: Int?
            let beforePublish = { try RenderFiles.verify(source) }
            switch delivery.format {
            case .avif10:
              let encoded = try DevelopmentSceneAVIFV1(device: display.texture.device).encode(display)
              artifact = try publishHDR(encoded, to: target, protected: protected, beforePublish: beforePublish, preparePublication: item.preparePublication)
              matrix = encoded.signal.matrix
            case .jpeg8, .png16:
              let format: PhotoRenderFormat = delivery.format == .jpeg8 ? .jpeg8 : .png16
              artifact = try writeSDR(display, format: format, to: target, protected: protected,
                preparePublication: item.preparePublication, beforePublish: beforePublish).artifact
              matrix = nil
            }
            return Receipt(versionID: delivery.versionID, sourceSHA256: capture.contentSHA256, workflowSHA256: fingerprint,
              target: delivery.target, format: delivery.format, artifact: artifact, matrix: matrix, execution: execution)
          }
        }
      }
    }
  }

  private enum Prepared {
    case serial(DevelopmentSceneWorkflowRendererV1, DevelopmentSceneWorkflowRendererV1.Master)
    case graph(DevelopmentSceneGraphRendererV1, DevelopmentSceneGraphRendererV1.Master)
    case tiled(DevelopmentSceneTiledDeliveryV1)

    func render(_ target: DevelopmentSceneOutputStateV1.Target) throws -> (display: DevelopmentSceneOutputV1.DisplayImage, execution: DevelopmentSceneExecutionReceiptV1?) {
      switch self {
      case let .serial(renderer, master): return (try renderer.renderDelivery(master, target: target), nil)
      case let .graph(renderer, master): return (try renderer.renderDelivery(master, target: target), renderer.lastReceipt)
      case let .tiled(renderer): return try renderer.render(target)
      }
    }
  }

  static func encodeHDR(_ capturedARW: URL, workflow: DevelopmentSceneWorkflowV1) throws -> DevelopmentSceneAVIFV1.Encoded {
    let display = try prepare(capturedARW, program: .serial(workflow)).render(.hdr2020).display
    return try DevelopmentSceneAVIFV1(device: display.texture.device).encode(display)
  }

  private static func prepare(_ capturedARW: URL, program: DevelopmentSceneDeliveryV1.Program) throws -> Prepared {
    try Task.checkCancellation()
    guard let device = MTLCreateSystemDefaultDevice() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    let decoder = try DevelopmentSceneRAWV1(device: device)
    let mosaic = try decoder.prepare(capturedARW)
    switch program {
    case .serial(let workflow):
      let raw = try decoder.develop(mosaic, sampling: .native(nil)).image
      let renderer = DevelopmentSceneWorkflowRendererV1(device: device)
      return .serial(renderer, try renderer.prepareFinal(raw, workflow: workflow))
    case .graph(let graph):
      if DevelopmentSceneTiledDeliveryV1.requiresTiling(mosaic) {
        return .tiled(try DevelopmentSceneTiledDeliveryV1(decoder: decoder, mosaic: mosaic, graph: graph, models: graph.models))
      }
      let raw = try decoder.develop(mosaic, sampling: .native(nil)).image
      let renderer = try DevelopmentSceneGraphRendererV1(device: device)
      let geometry = DevelopmentSceneGraphRendererV1.Geometry(width: raw.texture.width, height: raw.texture.height)
      let provider = try graph.models.map { _ in try DevelopmentSceneProductionModelProvider(device: device) }
      return .graph(renderer, try renderer.prepareFinal(raw, geometry: geometry, graph: graph, models: graph.models, provider: provider))
    }
  }

  /// Produces a verified file inside the private *batch-owned* stage directory. The existing
  /// 032 queue (not this encoder) owns the only final pathname and publication transaction.
  @discardableResult static func encodePQForBatch(_ ticket: DevelopmentSceneDeliveryV1, to stage: URL) throws -> DevelopmentSceneExecutionReceiptV1? {
    guard ticket.format == .avif10, ticket.target == .hdr2020, stage.pathExtension == "avif" else {
      throw Failure.invalidDestination
    }
    let capture = try RenderFiles.verifiedPreviewCapture(ticket.source)
    defer { try? FileManager.default.removeItem(at: capture.url.deletingLastPathComponent()) }
    let (encoded, execution) = try capture.withCurrent(at: capture.url) {
      let (display, execution) = try autoreleasepool { try prepare(capture.url, program: ticket.program).render(.hdr2020) }
      return (try DevelopmentSceneAVIFV1(device: display.texture.device).encode(display), execution)
    }
    try Task.checkCancellation()
    // Preserve CICP/bit depth and compressed image data; do not publish invented picture levels.
    try DevelopmentSceneAVIFV1.leavingLightLevelsUnspecified(encoded.bytes).write(to: stage, options: .withoutOverwriting)
    return execution
  }

  static func renderSDRForComposition(capture: URL, graph: DevelopmentSceneGraphV1) throws -> (image: CIImage, execution: DevelopmentSceneExecutionReceiptV1?) {
    let (display, execution) = try prepare(capture, program: .graph(graph)).render(.sdr709)
    return (try linearSDRImage(display.texture), execution)
  }

  static func linearSDRImage(_ texture: MTLTexture) throws -> CIImage {
    guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB),
          let image = CIImage(mtlTexture: texture, options: [.colorSpace: linear]) else {
      throw DevelopmentError.invalidEncoding
    }
    return image.oriented(.downMirrored) // top-left scene scanlines to Core Image coordinates
  }

  static func writeSDR(_ display: DevelopmentSceneOutputV1.DisplayImage, format: PhotoRenderFormat, to target: URL,
                       protected: [URL], preparePublication: RenderPublicationPreparation? = nil,
                       beforePublish: () throws -> Void = {}) throws -> RenderedPhoto {
    guard display.target == .sdr709, format == .jpeg8 || format == .png16,
          let linear = CGColorSpace(name: CGColorSpace.linearSRGB) else {
      throw DevelopmentError.invalidEncoding
    }
    // Scene textures are scanline/top-left; CI's bitmap coordinates are bottom-left.
    // Only apply the orientation bridge and sRGB encoding here, not a second tone mapping.
    let image = try linearSDRImage(display.texture)
    let context = CIContext(mtlDevice: display.texture.device, options: [.workingColorSpace: linear,
      .workingFormat: CIFormat.RGBAf.rawValue, .outputPremultiplied: false, .cacheIntermediates: false])
    let artifact = try withPublicationStage(to: target, protected: protected, beforePublish: beforePublish, preparePublication: preparePublication) { stage in
      try PhotoBatchRenderExporter.encodeSceneSDRPixels(image, format: format, to: stage, context: context)
      do {
        var inspected = try PhotoRenderer.inspect(stage)
        guard inspected.bitDepth == (format == .jpeg8 ? 8 : 16), inspected.iccProfileSHA256 != nil else { throw DevelopmentError.invalidEncoding }
        inspected.alphaPolicy = format == .jpeg8 ? .compositedWhite : .straight
        return inspected
      } catch {
        try? FileManager.default.removeItem(at: stage)
        throw error
      }
    }
    return RenderedPhoto(fileURL: target, artifact: artifact)
  }

  private static func publishHDR(_ encoded: DevelopmentSceneAVIFV1.Encoded, to target: URL, protected: [URL],
                                 beforePublish: () throws -> Void, preparePublication: RenderPublicationPreparation?) throws -> RenderArtifact {
    let artifact = RenderArtifact(sha256: SHA256.hash(data: encoded.bytes).map { String(format: "%02x", $0) }.joined(),
      byteCount: Int64(encoded.bytes.count), pixelWidth: encoded.width, pixelHeight: encoded.height,
      encoding: "public.avif", bitDepth: encoded.signal.bitDepth,
      colorSpace: "Rec.2020 PQ (CICP 9/16/\(encoded.signal.matrix), full range)", alphaPolicy: .opaque)
    return try withPublicationStage(to: target, protected: protected, beforePublish: beforePublish, preparePublication: preparePublication) { stage in
      let fd = Darwin.open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: encoded.bytes)
        try handle.close()
        return artifact
      } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: stage)
        throw error
      }
    }
  }

  private static func withPublicationStage(to target: URL, protected: [URL], beforePublish: () throws -> Void,
                                          preparePublication: RenderPublicationPreparation?,
                                          encode: (URL) throws -> RenderArtifact) throws -> RenderArtifact {
    try Task.checkCancellation()
    try RenderFiles.check(target, protected: protected)
    let stage = target.deletingLastPathComponent().appendingPathComponent(".rawmaster-render-\(UUID().uuidString).\(target.pathExtension.lowercased())")
    try RenderFiles.check(stage, protected: protected)
    // Both encoders create this file exclusively and clean up their own errors.
    let artifact = try encode(stage)
    var preservePreparedStage = false
    defer { if !preservePreparedStage { try? FileManager.default.removeItem(at: stage) } }
    try artifact.validate()
    try Task.checkCancellation()
    let handle = try FileHandle(forWritingTo: stage)
    defer { try? handle.close() }
    try handle.synchronize()
    try handle.close()
    try beforePublish()
    try Task.checkCancellation()
    try RenderFiles.check(target, protected: protected)
    if let preparePublication {
      // The callback can have committed the intent before reporting failure. The caller owns reconciliation.
      preservePreparedStage = true
      try preparePublication(stage, target, artifact)
    }
    guard renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
      let code = errno
      if code == EEXIST { throw DevelopmentError.outputExists }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return artifact
  }
}
