import Foundation
import AppKit
import CryptoKit
import CoreImage
import ImageIO
import RAWMasterCore
import RAWMasterImaging

@main
struct RAWMasterDiagnostics {
    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func dimensions(_ image: NSImage) -> [Int] {
        let rep = image.representations.first
        return [rep?.pixelsWide ?? 0, rep?.pixelsHigh ?? 0]
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "RAWMasterDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--burst-evidence" { exit(try await BurstEvidenceCLI.run(arguments)) }
            guard let path = arguments.first, !path.hasPrefix("--") else {
                print("Usage: RAWMasterDiagnostics <RAW-file> [--output <directory>] [--smoke]")
                return
            }
            let url = URL(fileURLWithPath: path)
            let outputIndex = arguments.firstIndex(of: "--output")
            let output = outputIndex.flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            let before = try digest(url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                throw ImagePipelineError.unreadable(path)
            }
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let raw = CIRAWFilter(imageURL: url)
            var report: [String: Any] = ["source": path,
                "model": tiff?[kCGImagePropertyTIFFModel] as? String ?? "unknown",
                "metadataDimensions": [properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                       properties[kCGImagePropertyPixelHeight] as? Int ?? 0],
                "orientation": properties[kCGImagePropertyOrientation] as? Int ?? 1,
                "sha256Before": before, "geometry": try geometryChecks()]
            if let raw {
                report["nativeDimensions"] = [Int(raw.nativeSize.width), Int(raw.nativeSize.height)]
                report["decoderVersion"] = raw.decoderVersion.rawValue
            }
            let start = Date()
            async let first = ImagePipeline.shared.preview(at: url, maxPixel: 1600)
            async let second = ImagePipeline.shared.preview(at: url, maxPixel: 1600)
            let (preview, duplicate) = try await (first, second)
            let previewTime = Date().timeIntervalSince(start)
            report["previewDimensions"] = dimensions(preview)
            report["previewSeconds"] = previewTime
            report["coalescedPreview"] = preview === duplicate
            try require(preview === duplicate, "Concurrent preview requests were not coalesced")
            try require(dimensions(preview).max()! <= 1600, "Preview exceeded requested dimensions: \(dimensions(preview))")
            let detailStart = Date()
            let detail = try await ImagePipeline.shared.detail(at: url)
            report["detailDimensions"] = dimensions(detail)
            report["detailSeconds"] = Date().timeIntervalSince(detailStart)
            if let raw {
                let native = [Int(raw.nativeSize.width), Int(raw.nativeSize.height)]
                try require(dimensions(detail).sorted() == native.sorted(), "RAW detail is not native resolution")
            }
            if let output, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("preview.jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
                try require(CGImageDestinationFinalize(destination), "Could not save diagnostic preview")
            }
            if let output, let cg = detail.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("detail.jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                try require(CGImageDestinationFinalize(destination), "Could not save diagnostic RAW detail")
            }
            if arguments.contains("--smoke") {
                report["smoke"] = try await smoke(source: url, root: output)
            }
            let after = try digest(url)
            report["sha256After"] = after
            report["sourceUnchanged"] = before == after
            try require(before == after, "Source hash changed")
            let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if let output { try encoded.write(to: output.appendingPathComponent("report.json"), options: .atomic) }
            print(String(decoding: encoded, as: UTF8.self))
        } catch {
            fputs("Diagnostics failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func geometryChecks() throws -> [String: Any] {
        let pixels = CGSize(width: 8640, height: 5760)
        let viewport = CGSize(width: 960, height: 640)
        var checks: [[String: Any]] = []
        for backing: CGFloat in [1, 2] {
            let magnification = ImageViewportGeometry.actualPixelScale(pixelSize: pixels, viewport: viewport, backingScale: backing)
            let rect = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: viewport,
                transform: ImageTransform(scale: magnification, centerX: 0.54321, centerY: 0.45678), backingScale: backing)
            let backingPixelsPerSourcePixel = rect.width * backing / pixels.width
            try require(abs(backingPixelsPerSourcePixel - 1) < 0.000001, "1:1 geometry is not one source pixel per backing pixel")
            try require(abs(rect.origin.x * backing - (rect.origin.x * backing).rounded()) < 0.000001,
                        "1:1 origin was not aligned to a backing pixel")
            checks.append(["backingScale": Double(backing), "relativeFitScale": Double(magnification),
                           "backingPixelsPerSourcePixel": Double(backingPixelsPerSourcePixel),
                           "backingPixelAligned": true])
        }
        let fitRect = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: viewport,
            transform: ImageTransform(), backingScale: 2)
        try require(fitRect.size == viewport, "Fit geometry did not fill matching aspect ratio viewport")
        let shared = ImageTransform(centerX: 0.61, centerY: 0.42, physicalMagnification: 1)
        let mixed: [(CGSize, CGSize)] = [
            (CGSize(width: 8640, height: 5760), CGSize(width: 960, height: 640)),
            (CGSize(width: 5760, height: 8640), CGSize(width: 620, height: 900)),
            (CGSize(width: 4000, height: 3000), CGSize(width: 1000, height: 800))]
        for (size, pane) in mixed {
            let rect = ImageViewportGeometry.imageRect(pixelSize: size, viewport: pane, transform: shared, backingScale: 2)
            try require(abs(rect.width * 2 / size.width - 1) < 0.000001,
                        "Mixed-size compare did not maintain physical 1:1")
            // Alignment may move the center by at most half of one backing pixel.
            let centerX = (pane.width / 2 - rect.minX) / rect.width
            try require(abs(centerX - shared.centerX) <= 0.5 / (rect.width * 2) + 0.000001,
                        "Mixed-size compare lost normalized center")
        }
        let freeZoom = ImageTransform(physicalMagnification: 1.25)
        try require(abs(ImageViewportGeometry.pointScale(pixelSize: pixels, viewport: viewport,
            transform: freeZoom, backingScale: 2) * 2 - 1.25) < 0.000001,
            "Free zoom did not retain physical magnification")
        return ["actualPixelChecks": checks, "fitCheckPassed": true,
                "mixedSizeCompareCount": mixed.count, "mixedSizePhysicalOneToOnePassed": true,
                "freeZoomPhysicalMagnification": 1.25]
    }
    static func smoke(source: URL, root: URL?) async throws -> [String: Any] {
        let base = (root ?? FileManager.default.temporaryDirectory).appendingPathComponent("smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = try LibraryStore(databaseURL: base.appendingPathComponent("library.sqlite"))
        // Isolate exactly one authorized copy; never scan or modify the supplied source directory.
        let copiedSource = base.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: copiedSource, withIntermediateDirectories: true)
        let sample = copiedSource.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: sample)
        let service = ImportService(store: store)
        let session = try await service.importDirectory(source: copiedSource, destination: base.appendingPathComponent("managed"), projectName: "Real RAW diagnostic", mode: .copy, progress: { _ in })
        var assets = try store.loadAssets(sessionID: session.id)
        try require(assets.count == 1 && assets[0].importState == .ready, "Real RAW copy import did not finish")
        let changes = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 4)
        try store.undoSelection(changes)
        assets = try store.loadAssets(sessionID: session.id)
        try require(assets[0].decision == .undecided && assets[0].rating == 0, "Undo failed")
        _ = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 5)
        try store.createGroup(ids: [assets[0].id], name: "Diagnostic sequence", kind: "sequence")
        let report = try await ExportService(store: store).exportAssets(ids: [assets[0].id], destination: base.appendingPathComponent("export"), manifestIDs: [assets[0].id], progress: { _ in })
        try require(report.copied == 1 && report.failed == 0, "Real RAW export failed")
        let reopened = try LibraryStore(databaseURL: base.appendingPathComponent("library.sqlite"))
        let persisted = try reopened.loadAssets(sessionID: session.id)
        try require(persisted[0].decision == .keep && persisted[0].rating == 5, "Selection did not survive reopen")
        return ["workingDirectory": base.path, "importStatus": session.status, "imported": assets.count,
                "exported": report.copied, "sourceCopyHashMatches": try digest(sample) == digest(source),
                "reopenDecision": persisted[0].decision.rawValue, "reopenRating": persisted[0].rating,
                "manifest": report.manifestPath]
    }
}
