import CryptoKit
import Foundation
import Metal
import RAWMasterCore

/// Isolated PoC diagnostic for the 040/041 backbone. It reuses the production Swift/Rust scene
/// executor and ACES 2 delivery, but is not shipped or wired into the application.
package enum DevelopmentScenePOCDiagnostics {
  package enum Failure: LocalizedError {
    case invalidRequest, deviceUnavailable, writeFailed
    case sourceChanged

    package var errorDescription: String? {
      switch self {
      case .invalidRequest: return "scene PoC requires an ARW, two scene JSON files, a new output directory, and a positive tile edge"
      case .deviceUnavailable: return "Metal is unavailable"
      case .writeFailed: return "Could not write the scene PoC artifact"
      case .sourceChanged: return "The source changed while the scene PoC was running"
      }
    }
  }

  private struct Timed<Value> {
    let value: Value
    let milliseconds: Double
  }

  private static func timed<Value>(_ body: () throws -> Value) rethrows -> Timed<Value> {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    return .init(value: value,
      milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func digest(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let block = try file.read(upToCount: 1_048_576), !block.isEmpty {
      hash.update(data: block)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func receipt(_ value: DevelopmentSceneExecutionReceiptV1?) -> [String: Any] {
    guard let value else { return ["backend": "missing"] }
    return [
      "backend": value.backend.rawValue,
      "tiles": value.tiles,
      "nodes": value.nodes,
      "dispatches": value.dispatches,
      "coverageCacheHits": value.coverageCacheHits,
      "nodeCacheHits": value.nodeCacheHits,
      "peakBytes": value.peakBytes,
      "budgetBytes": value.budgetBytes,
      "cpuMilliseconds": value.cpuMilliseconds,
      "fallbackReason": value.fallbackReason ?? NSNull(),
    ]
  }

  private static func writeTexture(_ texture: any MTLTexture, to url: URL) throws -> String {
    guard texture.textureType == .type2D, texture.pixelFormat == .rgba32Float,
          !texture.isFramebufferOnly, texture.width > 0, texture.height > 0 else {
      throw Failure.invalidRequest
    }
    let rowBytes = texture.width * 16
    let length = rowBytes * texture.height
    guard let buffer = texture.device.makeBuffer(length: length, options: .storageModeShared),
          let command = texture.device.makeCommandQueue()?.makeCommandBuffer(),
          let blit = command.makeBlitCommandEncoder() else { throw Failure.deviceUnavailable }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
      sourceOrigin: .init(x: 0, y: 0, z: 0),
      sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
      to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
      destinationBytesPerImage: length)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw Failure.writeFailed }
    let data = Data(bytesNoCopy: buffer.contents(), count: length,
      deallocator: .custom { [buffer] _, _ in _ = buffer })
    guard (try? data.write(to: url, options: [.withoutOverwriting])) != nil else {
      throw Failure.writeFailed
    }
    return digest(data)
  }

  /// Renders the same fixed graph on the production Rust/Metal executor, exports the AP1 input and
  /// output plus both ACES 2 display-linear branches, and writes the existing HDR AVIF encoder's
  /// result. Every artifact and receipt is written to a new directory.
  package static func export(source: URL, graphV1URL: URL, graphV2URL: URL, destination: URL,
                             tileEdge: Int, surfaceBudget: Int, sourceRevision: UInt64) throws -> [String: Any] {
    guard source.isFileURL, source.pathExtension.lowercased() == "arw",
          graphV1URL.isFileURL, graphV2URL.isFileURL, destination.isFileURL,
          tileEdge >= 64, surfaceBudget >= 256 * 1024 * 1024,
          sourceRevision > 0 else { throw Failure.invalidRequest }
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
      let contents = try fileManager.contentsOfDirectory(atPath: destination.path)
      guard contents.isEmpty else { throw Failure.invalidRequest }
    } else {
      try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.deviceUnavailable }
    let graphV1Data = try Data(contentsOf: graphV1URL)
    let graphV2Data = try Data(contentsOf: graphV2URL)
    let decoder = JSONDecoder()
    let graphV1 = try decoder.decode(DevelopmentSceneGraphV1.self, from: graphV1Data)
    let graphV2 = try decoder.decode(DevelopmentSceneGraphV1.self, from: graphV2Data)

    let sourceBefore = try digest(source)
    let raw = try DevelopmentSceneRAWV1(device: device).decode(source).image
    guard raw.texture.width > 0, raw.texture.height > 0 else { throw Failure.invalidRequest }
    let geometry = DevelopmentSceneGraphRendererV1.Geometry(
      width: raw.texture.width, height: raw.texture.height)
    let inputSHA = try writeTexture(raw.texture, to: destination.appendingPathComponent("scene-input.f32"))

    let previous = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]
    setenv("RAWMASTER_SCENE_BACKEND", "rust", 1)
    defer {
      if let previous { setenv("RAWMASTER_SCENE_BACKEND", previous, 1) }
      else { unsetenv("RAWMASTER_SCENE_BACKEND") }
    }
    let renderer = try DevelopmentSceneGraphRendererV1(device: device, surfaceBudget: surfaceBudget)

    let cold = try timed {
      try renderer.prepareFinal(raw, geometry: geometry, graph: graphV1,
        sourceRevision: sourceRevision, tileEdge: tileEdge)
    }
    let coldReceipt = renderer.lastReceipt
    let outputSHA = try writeTexture(cold.value.image.texture,
      to: destination.appendingPathComponent("scene-output.f32"))

    let warm = try timed {
      try renderer.prepareFinal(raw, geometry: geometry, graph: graphV1,
        sourceRevision: sourceRevision, tileEdge: tileEdge)
    }
    let warmReceipt = renderer.lastReceipt

    let edited = try timed {
      try renderer.prepareFinal(raw, geometry: geometry, graph: graphV2,
        sourceRevision: sourceRevision, tileEdge: tileEdge)
    }
    let editedReceipt = renderer.lastReceipt

    let newSource = try timed {
      try renderer.prepareFinal(raw, geometry: geometry, graph: graphV2,
        sourceRevision: sourceRevision + 1, tileEdge: tileEdge)
    }
    let newSourceReceipt = renderer.lastReceipt

    let sdr = try timed { try renderer.renderDelivery(cold.value, target: .sdr709) }
    let sdrSHA = try writeTexture(sdr.value.texture,
      to: destination.appendingPathComponent("display-sdr.f32"))
    let hdr = try timed { try renderer.renderDelivery(cold.value, target: .hdr2020) }
    let hdrSHA = try writeTexture(hdr.value.texture,
      to: destination.appendingPathComponent("display-hdr.f32"))

    let avifURL = destination.appendingPathComponent("scene-macos.avif")
    let avif = try timed {
      let encoded = try DevelopmentSceneAVIFV1(device: device).encode(hdr.value)
      guard (try? encoded.bytes.write(to: avifURL, options: [.withoutOverwriting])) != nil else {
        throw Failure.writeFailed
      }
      return encoded
    }
    let avifSHA = digest(avif.value.bytes)
    let sourceAfter = try digest(source)
    guard sourceAfter == sourceBefore else { throw Failure.sourceChanged }

    var result: [String: Any] = [
      "schema": "rawmaster-server-poc-macos-v1",
      "source": source.path,
      "sourceSHA256": sourceBefore,
      "sourceUnchanged": true,
      "graphV1SHA256": digest(graphV1Data),
      "graphV2SHA256": digest(graphV2Data),
      "resolution": [raw.texture.width, raw.texture.height],
      "tileEdge": tileEdge,
      "surfaceBudgetBytes": surfaceBudget,
      "sourceRevision": sourceRevision,
      "inputAP1SHA256": inputSHA,
      "outputAP1SHA256": outputSHA,
      "displaySDRSHA256": sdrSHA,
      "displayHDRSHA256": hdrSHA,
      "graphColdMs": cold.milliseconds,
      "graphWarmMs": warm.milliseconds,
      "graphEditedMs": edited.milliseconds,
      "graphNewSourceMs": newSource.milliseconds,
      "deliverySDRMs": sdr.milliseconds,
      "deliveryHDRMs": hdr.milliseconds,
      "cold": receipt(coldReceipt),
      "warm": receipt(warmReceipt),
      "edited": receipt(editedReceipt),
      "newSource": receipt(newSourceReceipt),
      "avif": [
        "milliseconds": avif.milliseconds,
        "bytes": avif.value.bytes.count,
        "sha256": avifSHA,
        "width": avif.value.width,
        "height": avif.value.height,
        "signal": [
          "primaries": avif.value.signal.primaries,
          "transfer": avif.value.signal.transfer,
          "matrix": avif.value.signal.matrix,
          "bitDepth": avif.value.signal.bitDepth,
          "fullRange": avif.value.signal.fullRange,
        ],
        "referenceWhiteNits": avif.value.referenceWhiteNits,
        "peakNits": avif.value.peakNits,
      ],
    ]
    result["artifacts"] = [
      "input": "scene-input.f32",
      "output": "scene-output.f32",
      "sdr": "display-sdr.f32",
      "hdr": "display-hdr.f32",
      "avif": "scene-macos.avif",
    ]
    let receiptData = try JSONSerialization.data(withJSONObject: result,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try receiptData.write(to: destination.appendingPathComponent("receipt.json"),
      options: [.withoutOverwriting])
    return result
  }
}
