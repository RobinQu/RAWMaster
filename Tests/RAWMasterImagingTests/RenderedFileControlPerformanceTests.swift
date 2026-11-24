import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Measures the controls whose source is a rendered file rather than a RAW mosaic: the approximate
/// JPEG/TIFF temperature field, photographic denoise strength and Lens Blur driven by real device depth.
/// Every operation alternates two committed recipe states on the normal preview service, as the
/// resident-RAW control benchmark does, and reads the 192 px sRGB witness outside the timed call.
final class RenderedFileControlPerformanceTests: XCTestCase {
    struct Operation {
        let id: String
        let source: String
        let decoder: String
        let states: [DevelopmentRecipe]
    }

    func testChangedControlsOnRenderedFiles() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let imagePath = env["RAWMASTER_RENDERED_CONTROL_IMAGE"],
              let output = env["RAWMASTER_RENDERED_CONTROL_REPORT"] else {
            throw XCTSkip("Rendered-file control benchmarking requires a camera JPEG and a fresh output path")
        }
        #if DEBUG
        throw XCTSkip("Use a release build for timings")
        #endif
        let jpeg = URL(fileURLWithPath: imagePath)
        let destination = URL(fileURLWithPath: output)
        guard FileManager.default.fileExists(atPath: imagePath),
              !FileManager.default.fileExists(atPath: output) else { throw CocoaError(.fileWriteFileExists) }
        let repeats = Int(env["RAWMASTER_CONTROL_SAMPLES"] ?? "") ?? 20
        guard (2...100).contains(repeats) else { throw EditingError.invalidRecipe }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-rendered-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tiff = scratch.appendingPathComponent("rendered-control.tiff")
        try writeTIFF(from: jpeg, to: tiff)
        let heic = scratch.appendingPathComponent("device-depth.heic")
        try writeDepthHEIC(from: jpeg, to: heic)

        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0))
        var rows: [[String: Any]] = []
        var sources: [String: Any] = [:]

        // Rendered-image temperature: the −100…100 approximate offset that the product's image
        // white-balance control stores next to the actual working neutral.
        for (key, url) in [("jpeg", jpeg), ("tiff", tiff)] {
            let binding = try self.binding(for: url)
            let source = try snapshot(url)
            sources[key] = ["sha256": try RenderFiles.hash(url),
                            "pixels": [binding.orientedWidth, binding.orientedHeight],
                            "orientation": binding.exifOrientation,
                            "container": key == "jpeg" ? "public.jpeg" : "public.tiff"]
            let session = try await service.open(source: .raw(source))
            defer { Task { await service.close(session.id) } }
            let facts = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
            guard case .image(_, let initial)? = facts.initialWhiteBalanceState else {
                throw DevelopmentV3Error.invalidGraph
            }
            func temperature(_ offset: Double) throws -> DevelopmentRecipe {
                var state = initial
                state.selectedMode = .temperatureTint
                state.temperatureOffset = offset
                state.temperatureTint = .init(
                    temperature: DevelopmentImageWhiteBalanceStateV3.approximateTemperature(forOffset: offset),
                    tint: initial.temperatureTint.tint)
                try state.validate()
                var payload = DevelopmentAdjustmentsV3()
                payload.whiteBalance = .init(enabled: true, resolvedState: .image(source: binding, state: state))
                return DevelopmentRecipe(adjustmentsV3: payload)
            }
            let operation = Operation(id: key == "jpeg" ? "color-temp-rendered" : "color-temp-rendered-tiff",
                source: key, decoder: "imageio-rendered-\(key)",
                states: [try temperature(-28), try temperature(28)])
            let row = try await measure(operation, session: session, service: service, repeats: repeats)
            rows.append(row)
        }

        // Photographic denoise strength on the actual camera JPEG.
        do {
            let source = try snapshot(jpeg)
            let session = try await service.open(source: .raw(source))
            defer { Task { await service.close(session.id) } }
            let facts = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
            guard let capability = facts.aiDenoiseCapability, capability == .photoVGG7Chroma else {
                throw XCTSkip("Photographic denoise model unavailable")
            }
            let states = [false, true].map { edited -> DevelopmentRecipe in
                var payload = DevelopmentAdjustmentsV3()
                payload.aiDenoise = .init(model: .photoVGG7Chroma, amount: edited ? 100 : 0)
                return DevelopmentRecipe(adjustmentsV3: payload)
            }
            let operation = Operation(id: "detail-denoise-formats", source: "jpeg",
                decoder: capability.rawValue, states: states)
            rows.append(try await measure(operation, session: session, service: service, repeats: repeats))
        }

        // Lens Blur driven by the depth auxiliary actually written into the HEIC.
        do {
            let binding = try self.binding(for: heic)
            let deviceDepth = try ImageEngines.deviceDepth(at: heic)
            sources["heic"] = ["sha256": try RenderFiles.hash(heic),
                               "pixels": [binding.orientedWidth, binding.orientedHeight],
                               "orientation": binding.exifOrientation, "container": "public.heic",
                               "deviceDepth": ["kind": deviceDepth.kind.rawValue, "width": deviceDepth.width,
                                               "height": deviceDepth.height, "derivedFromJPEG": try RenderFiles.hash(jpeg)]]
            let source = try snapshot(heic)
            let session = try await service.open(source: .raw(source))
            defer { Task { await service.close(session.id) } }
            _ = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
            func focus(_ value: Double) -> DevelopmentRecipe {
                var payload = DevelopmentAdjustmentsV3()
                payload.effects = .init(lensBlur: .init(enabled: true, amount: 0.85,
                    focusX: value, focusY: 0.5, focusRange: 0.08, deviceDepth: deviceDepth))
                return DevelopmentRecipe(adjustmentsV3: payload)
            }
            let operation = Operation(id: "blur-device-depth", source: "heic", decoder: "device-depth-heic",
                                      states: [focus(0.25), focus(0.75)])
            rows.append(try await measure(operation, session: session, service: service, repeats: repeats))
        }

        let binary = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        let report: [String: Any] = ["schemaVersion": 1, "protocol": "rawmaster-rendered-control-v1",
            "build": "release", "binarySHA256": try RenderFiles.hash(binary),
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "unknown",
            "requestedPixels": 2400, "repeats": repeats, "sources": sources,
            "boundary": "Committed rendered-file recipe request to interactive frame return; 192 px sRGB witness read outside the timer",
            "operations": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .withoutOverwriting)
    }

    private func measure(_ operation: Operation, session: PreviewSessionInfo,
                         service: DevelopmentPreviewService, repeats: Int) async throws -> [String: Any] {
        let consumer = PreviewConsumerID()
        var samples: [[String: Any]] = []
        var seen = [Set<String>(), Set<String>()]
        var width = 0, height = 0
        var row: [String: Any] = ["id": operation.id, "source": operation.source, "status": "inconclusive",
                                  "decoders": [operation.decoder, operation.decoder]]
        for recipe in operation.states { try recipe.validate() }
        row["recipes"] = try operation.states.map { try EditingFingerprint.of($0) }
        do {
            var revision: UInt64 = 0
            for n in 0..<(repeats + 2) {
                let state = n % 2
                revision += 1
                let request = DevelopmentPreviewRequest(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                    consumerID: consumer, role: .primary, revision: revision, recipe: operation.states[state],
                    quality: .interactive, viewport: .init(maxPixel: 2400))
                let start = DispatchTime.now().uptimeNanoseconds
                let frame = try await service.render(request)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let (digest, w, h) = try witness(frame)
                if width != 0 && (width != w || height != h) { throw DevelopmentError.unreadable }
                width = w; height = h
                seen[state].insert(digest)
                samples.append(["state": state, "phase": n < 2 ? "first" : "warm", "ms": ms,
                                "digest": digest, "approximate": frame.approximate])
            }
            if seen[0].count == 1 && seen[1].count == 1 && seen[0] != seen[1] { row["status"] = "measured" }
            else { row["reason"] = "The two committed states did not yield stable distinct sRGB witnesses" }
        } catch { row["reason"] = String(describing: error) }
        row["samples"] = samples
        row["outputPixels"] = [width, height]
        print("RENDERED CONTROL \(operation.id) \(row["status"]!)")
        return row
    }

    private func snapshot(_ url: URL) throws -> EditingSourceSnapshot {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return EditingSourceSnapshot(projectID: "rendered-controls", assetID: url.lastPathComponent,
            contentSHA256: try RenderFiles.hash(url), byteCount: Int64(try XCTUnwrap(bytes)),
            admissionFingerprint: "rendered-control-benchmark-v1", sourceLocation: url)
    }

    private func binding(for url: URL) throws -> DevelopmentLocalEditSourceBinding {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              image.extent.width.isFinite, image.extent.height.isFinite else { throw DevelopmentError.unreadable }
        return DevelopmentLocalEditSourceBinding(sourceContentID: try RenderFiles.hash(url),
            exifOrientation: (metadata[kCGImagePropertyOrientation] as? Int) ?? 1,
            orientedWidth: Int(image.extent.width), orientedHeight: Int(image.extent.height))
    }

    private func witness(_ frame: DevelopmentPreviewFrame) throws -> (String, Int, Int) {
        let image = try XCTUnwrap(frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let side = 192
        let cg = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: PhotoRenderer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = Data(bytes: try XCTUnwrap(cg.data), count: side * side * 4)
        guard stride(from: 3, to: bytes.count, by: 4).allSatisfy({ bytes[$0] == 255 }) else { throw DevelopmentError.unreadable }
        return (SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), image.width, image.height)
    }

    /// Re-encode the same pixels as a real TIFF so the JPEG/TIFF temperature field is measured on
    /// both containers without depending on an extra external fixture.
    private func writeTIFF(from jpeg: URL, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { throw DevelopmentError.unreadable }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DevelopmentError.unreadable }
    }

    /// Write a real HEIC carrying a Float32 depth auxiliary, derived from the same photograph.
    private func writeDepthHEIC(from jpeg: URL, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DevelopmentError.unreadable }
        let width = 640, height = 480
        let values = (0..<(width * height)).map { index -> Float in
            let x = index % width, y = index / width
            let subject = exp(-pow(Double(x - width / 2) / Double(width) * 4, 2)
                              - pow(Double(y - height / 2) / Double(height) * 4, 2))
            return Float(0.15 + 0.7 * subject)
        }
        let description: [String: Any] = ["Width": width, "Height": height,
            "BytesPerRow": width * 4, "PixelFormat": kCVPixelFormatType_DepthFloat32]
        let info: [String: Any] = [kCGImageAuxiliaryDataInfoData as String: values.withUnsafeBytes { Data($0) },
            kCGImageAuxiliaryDataInfoDataDescription as String: description]
        let depth = try AVDepthData(fromDictionaryRepresentation: info)
        var auxiliaryType: NSString?
        let auxiliary = try XCTUnwrap(depth.dictionaryRepresentation(forAuxiliaryDataType: &auxiliaryType))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw DevelopmentError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddAuxiliaryDataInfo(destination, try XCTUnwrap(auxiliaryType), auxiliary as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DevelopmentError.unreadable }
    }
}
