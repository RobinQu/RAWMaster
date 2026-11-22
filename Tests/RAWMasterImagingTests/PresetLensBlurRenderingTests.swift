import AppKit
import CryptoKit
import ImageIO
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class PresetLensBlurRenderingTests: XCTestCase {
    func testFrozenCirclePresetsOnRealPortraitWithDepthAndFocus() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAWMASTER_PRESET_DEPTH_RAW"], let output = env["RAWMASTER_PRESET_DEPTH_EVIDENCE"] else {
            throw XCTSkip("Set a real portrait RAW, compiled depth model and fresh evidence directory")
        }
        let url = URL(fileURLWithPath: path), folder = URL(fileURLWithPath: output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sha = try RenderFiles.hash(url)
        let fileBytes = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let source = EditingSourceSnapshot(projectID: "031", assetID: "portrait", contentSHA256: sha,
            byteCount: Int64(fileBytes), admissionFingerprint: "preset-depth", sourceLocation: url)
        XCTAssertTrue(DevelopmentSceneDepth.available)
        let depth = try await ImageEngines.sceneDepth.estimate(source)
        let focus = try await ImageEngines.subjectAnalysis.focus(for: source)
        XCTAssertGreaterThan(focus.weightedPixelCount, 1)
        XCTAssertEqual(depth.sourceSHA256, sha)
        let values = try depth.map.values().sorted()
        XCTAssertGreaterThan(values[values.count * 9 / 10] - values[values.count / 10], 0.1)
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/031-preset-browser/contracts/migration-manifest-v1.json")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("preset-optics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let stage = try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: manifest, catalog: .init(root: temp))
        XCTAssertTrue(stage.frozenMigrationReady)
        let engine = DevelopmentService()
        var parameters = DevelopmentAdjustmentsV3()
        parameters.rawDecoder = try DevelopmentRAWSourcePolicy.decoderForNewWork(at: url)
        let baseline = DevelopmentRecipe(adjustmentsV3: parameters)
        let original = try await engine.preview(source: source, recipe: baseline, maxPixel: 480)
        let reference = try pixels(original.image, writing: folder.appendingPathComponent("base.png"))
        var rows = [[String: Any]](), imageHashes = Set<String>()
        var export: [String: Any] = [:]
        for record in stage.records where record.metadata["analysis"] == "perPhotoDepth" {
            guard case .approximate(let plan) = try stage.lensBlurAssessment(for: record) else { continue }
            let candidate = try plan.prepare(record: record, baseline: baseline, sourceID: sha, scene: depth,
                focus: .init(x: focus.focusX, y: focus.focusY), focusRange: focus.focusRange)
            let recipe = try XCTUnwrap(candidate.patch.fullRecipe)
            let reopened = try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(recipe))
            XCTAssertEqual(reopened, recipe)
            let stem = URL(fileURLWithPath: try XCTUnwrap(record.metadata["relativePath"])).deletingPathExtension().lastPathComponent
            let rendered = try await engine.preview(source: source, recipe: reopened, maxPixel: 480)
            let rgba = try pixels(rendered.image, writing: folder.appendingPathComponent(stem + ".png"))
            XCTAssertEqual(rgba.count, reference.count)
            let changed = stride(from: 0, to: min(rgba.count, reference.count), by: 4).filter { i in
                (0..<3).contains { abs(Int(rgba[i + $0]) - Int(reference[i + $0])) >= 2 }
            }.count
            XCTAssertGreaterThan(changed, reference.count / 4000)
            let hash = digest(Data(rgba))
            imageHashes.insert(hash)
            rows.append(["name": stem, "sourceXMPSHA256": plan.presetSHA256, "reopenedRecipe": true,
                         "previewRGBPixelsChangedByAtLeast2": changed, "previewPixelCount": rgba.count / 4, "previewRGBA8SHA256": hash])
            if stem == "Circle" {
                let dest = folder.appendingPathComponent("circle.tiff")
                let result = try await engine.render(source: source, recipe: reopened, format: .tiff16, destination: dest, protectedURLs: [url])
                let file = try XCTUnwrap(CGImageSourceCreateWithURL(dest as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file, 0, nil))
                XCTAssertEqual(image.bitsPerComponent, 16)
                XCTAssertEqual(image.width, result.artifact.pixelWidth)
                XCTAssertEqual(image.height, result.artifact.pixelHeight)
                XCTAssertGreaterThan(image.width, 2000)
                export = ["preset": stem, "width": image.width, "height": image.height, "bitDepth": image.bitsPerComponent,
                          "sha256": result.artifact.sha256]
            }
        }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(imageHashes.count, 4)
        XCTAssertFalse(export.isEmpty)
        let finalSHA = try RenderFiles.hash(url)
        XCTAssertEqual(finalSHA, sha)
        let report: [String: Any] = ["sourceSHA256Before": sha, "sourceSHA256After": finalSHA, "sourceBytes": fileBytes,
            "model": depth.model, "depthMapSHA256": digest(depth.map.data), "depthDimensions": [depth.map.width, depth.map.height],
            "focus": [focus.focusX, focus.focusY, focus.focusRange], "sourceManifestSHA256": DevelopmentPresetExchange.frozenMigrationV1SHA256,
            "previews": rows, "tiff": export, "boundary": "Same portrait, native subject focus, actual Core ML depth, stored per-photo recipe and local optics. No Adobe pixel-equivalence assertion."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("report.json"), options: .withoutOverwriting)
    }

    private func pixels(_ image: NSImage, writing target: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        try png.write(to: target, options: .withoutOverwriting)
        let width = source.width, height = source.height
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(bitmap.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
