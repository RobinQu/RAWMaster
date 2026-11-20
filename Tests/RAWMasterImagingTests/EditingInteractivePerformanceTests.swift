import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Opt-in real-source measurement for the production proxy/canonical split.
/// This is deliberately not a Camera Raw benchmark: no Adobe presentation timing is inferred.
final class EditingInteractivePerformanceTests: XCTestCase {
    private struct Measurement: Codable {
        let label: String
        let interactiveMilliseconds: [Double]
        let interactiveMedianMilliseconds: Double
        let settledMilliseconds: Double
        let approximate: Bool
        let width: Int
        let height: Int
        let p99ChannelError: Int
        let maximumChannelError: Int
    }

    private func pixels(_ image: NSImage) throws -> (data: Data, width: Int, height: Int, stride: Int) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: PhotoRenderer.sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data else { throw DevelopmentError.unreadable }
        // Canonical output and interactive IOSurface output use different native channel orders.
        // Normalize both to RGBA before computing error; never compare BGRA bytes as RGB.
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (Data(bytes: bytes, count: cg.width * cg.height * 4), cg.width, cg.height, cg.width * 4)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }

    func testOptInRealRAWInteractivePerformanceAndSettledError() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RAWMASTER_INTERACTIVE_PERF"] == "1",
              let sourcePath = environment["RAWMASTER_INTERACTIVE_PERF_SOURCE"],
              let outputPath = environment["RAWMASTER_INTERACTIVE_PERF_OUTPUT"] else {
            throw XCTSkip("Explicit isolated source and output are required")
        }
        #if DEBUG
        throw XCTSkip("Release measurements required")
        #endif
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reportURL = output.appendingPathComponent("interactive-performance.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "Refuse to overwrite performance evidence")
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let source = EditingSourceSnapshot(projectID: "interactive-performance", assetID: "fixed-raw",
            contentSHA256: try RenderFiles.hash(sourceURL), byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
            admissionFingerprint: "interactive-performance-v1", sourceLocation: sourceURL)
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1))
        let consumer = PreviewConsumerID()
        let session = try await service.open(source: .raw(source))
        let dehazeContext = try DevelopmentDehazeContextFactoryV1.fromCapture(sourceURL, generation: session.sourceGeneration)
        let neutralRecipe = DevelopmentRecipe(adjustmentsV3: .init())
        var revision: UInt64 = 0

        func recipe(_ label: String, dehazeAlgorithm: DevelopmentDehazeAlgorithm? = nil,
                    mutate: (inout DevelopmentAdjustmentsV3) -> Void) throws -> (String, DevelopmentRecipe) {
            var parameters = DevelopmentAdjustmentsV3()
            mutate(&parameters)
            if let dehazeAlgorithm {
                let projection = try neutralRecipe.prospectiveDehazeInputV1(context: dehazeContext, algorithm: dehazeAlgorithm)
                parameters.advancedDetail.preparedDehaze = .init(sourceBinding: dehazeContext.source,
                    inputFingerprint: projection.input.inputFingerprint, airlight: .init(red: 0.5, green: 0.75, blue: 1),
                    algorithmVersion: dehazeAlgorithm.rawValue)
            }
            return (label, DevelopmentRecipe(adjustmentsV3: parameters))
        }
        let recipes = [
            try recipe("neutral") { _ in },
            try recipe("exposure-color") { value in
                value.light.enabled = true; value.light.exposure = 0.35
                value.color.enabled = true; value.color.saturation = 0.3; value.color.vibrance = 0.15
            },
            try recipe("adaptive-brilliance") { value in
                value.light = .init(enabled: true, brilliance: 0.35, brillianceVersion: .adaptiveLocalV1)
            },
            try recipe("texture") { value in value.advancedDetail.texture = .init(enabled: true, amount: 25) },
            try recipe("clarity") { value in value.advancedDetail.clarity = .init(enabled: true, amount: 25) },
            try recipe("dehaze-v1", dehazeAlgorithm: .v1) { value in
                value.advancedDetail.dehaze = .init(enabled: true, amount: 25)
            },
            try recipe("dehaze-v2", dehazeAlgorithm: .positiveColorGuideV2) { value in
                value.advancedDetail.dehaze = .init(enabled: true, amount: 25)
            },
            try recipe("geometry") { value in
                value.geometry.straightenDegrees = 2
                value.geometry.crop = .init(x: 0.08, y: 0.06, width: 0.84, height: 0.88)
            }
        ]
        var measurements: [Measurement] = []
        do {
            for (label, recipe) in recipes {
                print("INTERACTIVE-CASE \(label)")
                var interactiveTimes: [Double] = []
                var interactive: DevelopmentPreviewFrame?
                for iteration in 0..<3 {
                    revision += 1
                    let started = DispatchTime.now().uptimeNanoseconds
                    interactive = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                        consumerID: consumer, role: .primary, revision: revision, recipe: recipe,
                        quality: .interactive, viewport: .init(maxPixel: 2400)))
                    interactiveTimes.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    print("INTERACTIVE-FRAME \(label) \(iteration) \(interactiveTimes.last ?? 0)")
                }
                let interactiveFrame = try XCTUnwrap(interactive)
                revision += 1
                print("SETTLED-CASE \(label)")
                let settledStarted = DispatchTime.now().uptimeNanoseconds
                let settled = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                    consumerID: consumer, role: .primary, revision: revision, recipe: recipe,
                    quality: .settled, viewport: .init(maxPixel: 2400)))
                let settledTime = Double(DispatchTime.now().uptimeNanoseconds - settledStarted) / 1_000_000
                let a = try pixels(interactiveFrame.image), b = try pixels(settled.image)
                var p99 = -1, maximum = -1
                if a.width == b.width && a.height == b.height {
                    var histogram = [Int](repeating: 0, count: 256)
                    a.data.withUnsafeBytes { ap in b.data.withUnsafeBytes { bp in
                        for index in 0..<min(ap.count, bp.count) { histogram[abs(Int(ap[index]) - Int(bp[index]))] += 1 }
                    } }
                    let total = histogram.reduce(0, +), threshold = Int(ceil(Double(total) * 0.99))
                    var count = 0
                    p99 = 0
                    for (error, frequency) in histogram.enumerated() {
                        count += frequency
                        if count >= threshold { p99 = error; break }
                    }
                    maximum = histogram.lastIndex(where: { $0 > 0 }) ?? 0
                }
                measurements.append(.init(label: label, interactiveMilliseconds: interactiveTimes,
                    interactiveMedianMilliseconds: median(interactiveTimes), settledMilliseconds: settledTime,
                    approximate: interactiveFrame.approximate, width: a.width, height: a.height,
                    p99ChannelError: p99, maximumChannelError: maximum))
            }
            await service.closeAll()
        } catch {
            await service.closeAll()
            throw error
        }
        let report: [String: Any] = [
            "sourceSHA256": source.contentSHA256,
            "decoderVersion": session.decoderVersion,
            "proxyVersion": PreviewInteractiveProxyV3.version,
            "policy": "proxyV1 interactive; canonical settled; bitmapCache=0; rawBaseCache=0",
            "measurements": try JSONSerialization.jsonObject(with: JSONEncoder().encode(measurements)),
            "caveats": [
                "API return timing only; no WindowServer presentation or Adobe Camera Raw timing",
                "Interactive proxy is bounded to 2400px and settled/save/export remain canonical",
                "Cold process and OS caches are not purged; three consecutive samples per operation"
            ]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: .withoutOverwriting)
        print("INTERACTIVE-PERFORMANCE \(measurements.map { [$0.label, $0.interactiveMedianMilliseconds, $0.settledMilliseconds, $0.p99ChannelError] })")
    }
}
