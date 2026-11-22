import AppKit
import CoreImage
import Darwin
import CryptoKit
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentNeuralRaw9Tests: XCTestCase {
    func testPersistedNeuralRecipeRejectsRenderedImage() throws {
        let recipe = try DevelopmentRecipe(adjustmentsV3: .init()).applying(.setAIDenoise(.init(model: .appleRAW9)))
        XCTAssertThrowsError(try DevelopmentRendererV3.validateSupport(recipe, sourceIsRAW: false))
        XCTAssertThrowsError(try PreviewInteractiveProxyV3.support(recipe, sourceIsRAW: false))
        XCTAssertThrowsError(try DevelopmentThumbnailEngine.checkSupport(recipe, sourceIsRAW: false))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func displaySample(_ nsImage: NSImage) throws -> Data {
        let image = try XCTUnwrap(nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 534, bitsPerComponent: 8,
            bytesPerRow: 3200, space: PhotoRenderer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 800, height: 534))
        return Data(bytes: try XCTUnwrap(context.data), count: 3200 * 534)
    }

    private func peakRSS() -> Int64 {
        var usage = rusage()
        return getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : -1
    }

    /// Does a linear-light midpoint of display samples predict the real unseen 50 setting?
    /// The 8-bit sample is a diagnostic, never an alternate processing path.
    private func midpointError(low: Data, middle: Data, high: Data) -> [String: Any] {
        precondition(low.count == middle.count && middle.count == high.count)
        let linear = (0..<256).map { code -> Double in
            let s = Double(code) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        var histogram = Array(repeating: 0, count: 256)
        var sum = 0
        for i in low.indices where i % 4 != 3 {
            let predicted = (linear[Int(low[i])] + linear[Int(high[i])]) * 0.5
            let encoded = predicted <= 0.0031308 ? 12.92 * predicted : 1.055 * pow(predicted, 1 / 2.4) - 0.055
            let difference = abs(Int((255 * encoded).rounded()) - Int(middle[i]))
            histogram[difference] += 1
            sum += difference
        }
        let n = low.count / 4 * 3
        return ["sampleWidth": 800, "sampleHeight": 534, "meanRGB8": Double(sum) / Double(n),
                "maxRGB8": histogram.lastIndex(where: { $0 > 0 }) ?? 0,
                "channelsAboveOneCode": histogram.dropFirst(2).reduce(0, +), "channels": n]
    }

    func testAdmittedMosaicAmountPixelsCacheAndFullTIFF() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAWMASTER_AI_DENOISE_RAW"], let reportPath = env["RAWMASTER_AI_DENOISE_REPORT"] else {
            throw XCTSkip("Requires a real RAW 9 mosaic fixture and an evidence output path.")
        }
        let url = URL(fileURLWithPath: path)
        let originalHash = try RenderFiles.hash(url)
        let byteCount = Int64(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let source = EditingSourceSnapshot(projectID: "neural-raw9", assetID: "real-sensor", contentSHA256: originalHash,
            byteCount: byteCount, admissionFingerprint: "real-sensor", sourceLocation: url)
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1))
        let session = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
        let facts = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
        let model = try XCTUnwrap(facts.aiDenoiseCapability)
        let readyStart = DispatchTime.now().uptimeNanoseconds
        try await DevelopmentNeuralRaw9.prepare(at: url, model: model)
        let prepareMS = Double(DispatchTime.now().uptimeNanoseconds - readyStart) / 1e6
        var base = DevelopmentAdjustmentsV3()
        base.rawDecoder = .flashRaw031
        let original = DevelopmentRecipe(adjustmentsV3: base)
        let low = try original.applying(.setAIDenoise(.init(model: model, amount: 0)))
        let high = try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(low.applying(.setAIDenoise(.init(model: model, amount: 100)))))
        let native = try PreviewNativeSource(capture: url, byteCount: byteCount, artifact: false, memoryLimit: 512)
        let middle = try low.applying(.setAIDenoise(.init(model: model, amount: 50)))
        let recipes = [original, low, high, middle]
        let thumbnailKeys = try recipes.map { try native.thumbnailInputFingerprint(recipe: $0, source: facts.sourceBinding, generation: 1) }
        let descriptors = try recipes.map { try XCTUnwrap(native.interactivePlan(recipe: $0, sourceKey: "source", generation: 1,
            verifiedContentID: originalHash, maxPixel: 2400).descriptor) }
        let baseKeys = try descriptors.map { try $0.fingerprint() }
        XCTAssertEqual(Set(baseKeys).count, 4)
        XCTAssertEqual(Set(thumbnailKeys).count, 4)
        XCTAssertEqual(descriptors[1].decoder, model.rawValue)
        XCTAssertEqual(descriptors[2].nativeContract, high.adjustmentsV3?.aiDenoise?.inputContract)
        let inputs: [(String, DevelopmentRecipe, PreviewQuality)] = [
            ("original", original, .interactive), ("amount0", low, .interactive), ("amount100", high, .interactive),
            ("amount0-replay", low, .interactive), ("amount50-first", middle, .interactive),
            ("amount0-secondReplay", low, .interactive), ("amount50-replay", middle, .interactive),
            ("disabled", try high.applying(.setAIDenoise(nil)), .interactive), ("amount100-settled", high, .settled)]
        var displayRows: [[String: Any]] = [], hashes: [String: String] = [:], endpointSamples: [String: Data] = [:]
        var presented: NSImage?
        var pressureEvidence: [String: Int] = [:]
        for (index, item) in inputs.enumerated() {
            let request = DevelopmentPreviewRequest(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                consumerID: consumer, role: .primary, revision: UInt64(index + 1), recipe: item.1,
                quality: item.2, viewport: .init(maxPixel: 2400))
            let before = await service.interactiveProxyStatisticsForTesting()
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = try await service.render(request)
            let time = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            withExtendedLifetime(presented) {}
            presented = frame.image
            let after = await service.interactiveProxyStatisticsForTesting()
            let sample = try displaySample(frame.image), hash = digest(sample)
            hashes[item.0] = hash
            if ["amount0", "amount100", "amount50-first"].contains(item.0) { endpointSamples[item.0] = sample }
            let filled = after.fills - before.fills, hits = after.hits - before.hits
            if item.0.contains("eplay") { XCTAssertEqual(filled, 0); XCTAssertEqual(hits, 1) }
            if item.0 == "amount50-first" { XCTAssertEqual(filled, 1); XCTAssertEqual(hits, 0) }
            displayRows.append(["input": item.0, "previewMs": time, "sampledSRGBSHA256": hash,
                "neutralBaseFills": filled, "neutralBaseHits": hits, "neutralResidentBytes": after.residentBytes,
                "sharedGPUBytesAfterReturn": after.owned.chargedGPUBytes, "processPeakRSSBytes": peakRSS()])
            if item.0 == "amount50-replay" {
                let otherPane = PreviewPresentationScope()
                let requestBytes = 100_000_000
                let reservation = try otherPane.reserveSharedSurface(bytes: requestBytes)
                let reclaimed = await service.interactiveProxyStatisticsForTesting()
                XCTAssertEqual(reclaimed.residentBytes * 2, after.residentBytes)
                XCTAssertEqual(reclaimed.retiredInputs, after.retiredInputs + 1)
                pressureEvidence = ["requestedBytes": requestBytes, "beforeResidentBytes": after.residentBytes,
                    "afterResidentBytes": reclaimed.residentBytes]
                reservation.releaseAfterStorageReleased()
                otherPane.closeAndRetire()
            }
        }
        presented = nil
        await service.close(session.id)
        let closed = await service.interactiveProxyStatisticsForTesting()
        XCTAssertEqual(closed.residentBytes, 0)
        XCTAssertEqual(Set([hashes["amount0"], hashes["amount50-first"], hashes["amount100"]]).count, 3)
        XCTAssertNotEqual(hashes["original"], hashes["amount0"])
        XCTAssertEqual(hashes["amount0"], hashes["amount0-replay"])
        XCTAssertEqual(hashes["amount0"], hashes["amount0-secondReplay"])
        XCTAssertEqual(hashes["amount50-first"], hashes["amount50-replay"])
        XCTAssertEqual(hashes["original"], hashes["disabled"])
        var record: [String: Any] = ["featureId": "detail-denoise", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "capturedAt": ISO8601DateFormatter().string(from: Date()), "source": url.lastPathComponent,
            "sha256": originalHash, "sourceBytes": byteCount, "model": model.rawValue, "resourcePrepareMs": prepareMS,
            "proxyKeys": baseKeys, "thumbnailKeys": thumbnailKeys, "requests": displayRows, "maxPixel": 2400,
            "midpointLinearLightApproximation": midpointError(low: try XCTUnwrap(endpointSamples["amount0"]),
                middle: try XCTUnwrap(endpointSamples["amount50-first"]), high: try XCTUnwrap(endpointSamples["amount100"])),
            "competingPaneReservation": pressureEvidence, "closedNeutralResidentBytes": closed.residentBytes]
        if env["RAWMASTER_AI_DENOISE_EXPORT"] == "1" {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
            defer { try? FileManager.default.removeItem(at: target) }
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try await DevelopmentService().render(source: source, recipe: high, format: .tiff16, destination: target)
            let time = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            XCTAssertEqual(result.artifact.pixelWidth, facts.sourceBinding.orientedWidth)
            XCTAssertEqual(result.artifact.pixelHeight, facts.sourceBinding.orientedHeight)
            XCTAssertEqual(result.artifact.bitDepth, 16)
            XCTAssertEqual(try RenderFiles.hash(target), result.artifact.sha256)
            record["export"] = ["amount": 100, "elapsedMs": time, "width": result.artifact.pixelWidth,
                "height": result.artifact.pixelHeight, "bitDepth": result.artifact.bitDepth,
                "sha256": result.artifact.sha256, "byteCount": result.artifact.byteCount] as [String: Any]
        }
        let finalSHA = try RenderFiles.hash(url)
        XCTAssertEqual(finalSHA, originalHash)
        record["sourceSHA256After"] = finalSHA
        record["processPeakRSSBytes"] = peakRSS()
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: reportPath), options: .withoutOverwriting)
    }
}
