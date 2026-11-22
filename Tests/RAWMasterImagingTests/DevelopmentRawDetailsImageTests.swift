import AppKit
import CoreImage
import CryptoKit
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentRawDetailsImageTests: XCTestCase {
  private func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  func testNonRAWRejectsPersistedRawDetails() throws {
    var p = DevelopmentAdjustmentsV3()
    p.rawDetails = .bayerAHD
    XCTAssertThrowsError(try DevelopmentRendererV3.validateSupport(.init(adjustmentsV3: p), sourceIsRAW: false))
  }

  func testRealBayerAndXTransMetadataDispatchPreviewAndExport() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let bayer = env["RAWMASTER_RAW_DETAILS_BAYER"], let xtrans = env["RAWMASTER_RAW_DETAILS_XTRANS"],
          let result = env["RAWMASTER_RAW_DETAILS_OUTPUT"] else { throw XCTSkip("Provide a Bayer RAW, X-Trans RAF and unused report filename") }
    let reportURL = URL(fileURLWithPath: result)
    guard !FileManager.default.fileExists(atPath: result) else { return XCTFail("Report exists") }
    var rows: [[String: Any]] = []
    for (path, mode) in [(bayer, DevelopmentRawDetails.bayerAHD), (xtrans, .xTransEdgeAware)] {
      let url = URL(fileURLWithPath: path)
      let flash = try FlashRawSource.open(url), native = flash.geometry
      XCTAssertEqual(flash.rawDetails, mode)
      let other: DevelopmentRawDetails = mode == .bayerAHD ? .xTransEdgeAware : .bayerAHD
      XCTAssertThrowsError(try flash.demosaic(for: other))
      let rotated = (5...8).contains(native.orientation)
      let width = rotated ? native.height : native.width, height = rotated ? native.width : native.height
      let sourceHash = try RenderFiles.hash(url)
      let snapshot = EditingSourceSnapshot(projectID: "raw-details", assetID: mode.rawValue, contentSHA256: sourceHash,
        byteCount: Int64(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)), admissionFingerprint: "real-sensor", sourceLocation: url)
      let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1))
      let session = try await service.open(source: .raw(snapshot)), consumer = PreviewConsumerID()
      let facts = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
      XCTAssertEqual(facts.rawDetailsCapability, mode)
      XCTAssertEqual(facts.sourceBinding.orientedWidth, width)
      XCTAssertEqual(facts.sourceBinding.orientedHeight, height)

      var base = DevelopmentAdjustmentsV3()
      base.rawDecoder = .flashRaw031
      let original = DevelopmentRecipe(adjustmentsV3: base)
      let enhanced = try original.applying(.setRawDetails(mode))
      let reopened = try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(enhanced))
      var previews: [String] = [], previewMs: [Double] = []
      for (i, recipe) in [original, reopened, original].enumerated() {
        let req = DevelopmentPreviewRequest(sessionID: session.id, sourceGeneration: session.sourceGeneration, consumerID: consumer,
          role: .primary, revision: UInt64(i + 1), recipe: recipe, quality: .interactive, viewport: .init(maxPixel: 2400))
        let start = DispatchTime.now().uptimeNanoseconds
        let frame = try await service.render(req)
        previewMs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        let cg = try XCTUnwrap(frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 160, bitsPerComponent: 8, bytesPerRow: 256*4, space: PhotoRenderer.sRGB,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 256, height: 160))
        previews.append(digest(Data(bytes: try XCTUnwrap(context.data), count: 256*160*4)))
      }
      await service.close(session.id)
      XCTAssertNotEqual(previews[0], previews[1])
      XCTAssertEqual(previews[0], previews[2])
      let sample = CGRect(x: native.width / 2 - 96, y: native.height / 2 - 96, width: 192, height: 192)
      func rawWitness(_ demosaic: FlashRawDemosaic) throws -> [String: Any] {
        let frame = try flash.decode(output: .linearRGBF16, backend: .gpu, demosaic: demosaic, region: sample)
        XCTAssertEqual(frame.info.width, 192); XCTAssertEqual(frame.info.height, 192)
        let data = try frame.data(), stats = try XCTUnwrap(frame.statistics)
        return ["sha256": digest(data), "bytes": data.count, "nativeMs": stats.nativeWallMilliseconds,
                "decodeBackend": stats.decoderBackend, "postprocessBackend": stats.postprocessBackend ?? "unreported"]
      }
      let reference = try rawWitness(.bilinear), quality = try rawWitness(flash.demosaic(for: mode))
      XCTAssertNotEqual(reference["sha256"] as? String, quality["sha256"] as? String)
      var row: [String: Any] = ["source": url.lastPathComponent, "sha256": sourceHash, "mode": mode.rawValue,
        "centre192x192LinearF16": ["bilinear": reference, mode.rawValue: quality],
        "width": width, "height": height, "release": flash.decoderVersion, "previewFingerprint": previews,
        "previewMs": previewMs, "previewTarget": 2400, "previewSequence": ["bilinear", mode.rawValue, "bilinear"]]
      if env["RAWMASTER_RAW_DETAILS_EXPORT"] == "1" {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: target) }
        let start = DispatchTime.now().uptimeNanoseconds
        let export = try await DevelopmentService().render(source: snapshot, recipe: reopened, format: .tiff16, destination: target)
        row["exportMs"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertEqual(export.artifact.pixelWidth, width)
        XCTAssertEqual(export.artifact.pixelHeight, height)
        XCTAssertEqual(export.artifact.bitDepth, 16)
        XCTAssertEqual(try RenderFiles.hash(target), export.artifact.sha256)
        row["export"] = ["width": export.artifact.pixelWidth, "height": export.artifact.pixelHeight,
                         "bits": export.artifact.bitDepth, "bytes": export.artifact.byteCount, "sha256": export.artifact.sha256] as [String: Any]
      }
      XCTAssertEqual(try RenderFiles.hash(url), sourceHash)
      rows.append(row)
    }
    let info: [String: Any] = ["featureId": "detail-raw-details", "mode": "Release", "sourceEngine": "FlashRaw 0.3.1",
      "sourceCommit": "2994e8c550bec70ab78a938ab28a74d7762124f4", "timestamp": ISO8601DateFormatter().string(from: Date()),
      "metric": "one interactive request per stated condition, readback after return; optional full 16-bit export including file verification",
      "rows": rows]
    try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .prettyPrinted]).write(to: reportURL, options: .withoutOverwriting)
  }
}
