import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import RAWMasterImaging

final class ImagePipelineTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterImagingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func fixture(_ name: String = "fixture.png", width: Int = 1024, height: Int = 768) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    func testPreviewIsBoundedAndWarmCacheReusesBitmap() async throws {
        let url = try fixture()
        let pipeline = ImagePipeline()
        let first = try await pipeline.preview(at: url, maxPixel: 300)
        let second = try await pipeline.preview(at: url, maxPixel: 300)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first.representations.first?.pixelsWide, 300)
        XCTAssertEqual(first.representations.first?.pixelsHigh, 225)
        let detail = try await pipeline.detail(at: url)
        XCTAssertEqual(detail.representations.first?.pixelsWide, 1024)
        XCTAssertEqual(detail.representations.first?.pixelsHigh, 768)
        XCTAssertFalse(first === detail)
    }
    func testConcurrentIdenticalPreviewRequestsShareResult() async throws {
        let url = try fixture(width: 2048, height: 1536)
        let pipeline = ImagePipeline()
        let results = try await withThrowingTaskGroup(of: NSImage.self) { group in
            for _ in 0..<20 { group.addTask { try await pipeline.preview(at: url, maxPixel: 600) } }
            var results: [NSImage] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 === results[0] })
    }
    func testAlreadyCancelledRequestDoesNotProduceImageAndPipelineRemainsUsable() async throws {
        let url = try fixture()
        let pipeline = ImagePipeline()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.preview(at: url)
        }
        do { _ = try await task.value; XCTFail("Cancelled image request returned an image") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, received \(error)") }
        let image = try await pipeline.preview(at: url, maxPixel: 128)
        XCTAssertEqual(image.representations.first?.pixelsWide, 128)
    }
    func testChangedFileInvalidatesCachedPreview() async throws {
        let url = try fixture()
        let pipeline = ImagePipeline()
        let first = try await pipeline.preview(at: url)
        _ = try fixture(width: 640, height: 480)
        let second = try await pipeline.preview(at: url)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.representations.first?.pixelsWide, 600)
    }
    func testRAWPreviewNeverFallsBackToFullImageDecode() async throws {
        // A PNG renamed .arw has no embedded RAW thumbnail. ImageIO could synthesize
        // one if the ordinary-image fallback were enabled, so this catches that regression.
        let disguised = try fixture("without-embedded-preview.arw")
        do {
            _ = try await ImagePipeline().preview(at: disguised)
            XCTFail("RAW preview unexpectedly synthesized a thumbnail from the primary image")
        } catch ImagePipelineError.noEmbeddedPreview {} // expected embedded-only path
        catch { XCTFail("Expected explicit missing embedded preview, received \(error)") }
    }
    func testCacheClearDoesNotRetainPreviousBitmap() async throws {
        let url = try fixture()
        let pipeline = ImagePipeline()
        let first = try await pipeline.preview(at: url)
        await pipeline.clearCaches()
        let second = try await pipeline.preview(at: url)
        XCTAssertFalse(first === second)
    }
    private func injected(_ probe: ControlledDecoder, previewBudget: Int = 128 * 1024, detailBudget: Int = 128 * 1024) -> ImagePipeline {
        ImagePipeline(previewBudget: previewBudget, detailBudget: detailBudget,
                      decoder: { try probe.decode(url: $0, maxPixel: $1, detail: $2) })
    }
    private func waitFor(_ pipeline: ImagePipeline, _ condition: (ImagePipeline.Snapshot) -> Bool) async throws -> ImagePipeline.Snapshot {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let snapshot = await pipeline.testingSnapshot()
            if condition(snapshot) { return snapshot }
            await Task.yield()
        }
        throw NSError(domain: "ImagePipelineTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for deterministic pipeline state"])
    }
    private func waitFor(_ probe: ControlledDecoder, _ condition: (ControlledDecoder.Snapshot) -> Bool) async throws -> ControlledDecoder.Snapshot {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let snapshot = probe.snapshot
            if condition(snapshot) { return snapshot }
            await Task.yield()
        }
        throw NSError(domain: "ImagePipelineTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for controlled decoder"])
    }
    func testPreviewDecodeConcurrencyIsBoundedAtTwo() async throws {
        let urls = try (0..<12).map { try fixture("preview-\($0).png", width: 64, height: 64) }
        let probe = ControlledDecoder(); defer { probe.releaseAll() }
        let pipeline = injected(probe)
        let tasks = urls.map { url in Task { try await pipeline.preview(at: url) } }
        _ = try await waitFor(pipeline) { $0.inFlightUsers == urls.count }
        let blocked = try await waitFor(probe) { $0.previewStarts == 2 }
        XCTAssertEqual(blocked.activePreview, 2)
        XCTAssertEqual(blocked.maximumPreview, 2)
        probe.releaseAll()
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(probe.snapshot.previewStarts, urls.count)
        XCTAssertEqual(probe.snapshot.maximumPreview, 2)
    }
    func testNativeDetailDecodeConcurrencyIsBoundedAtOne() async throws {
        let urls = try (0..<6).map { try fixture("detail-\($0).png", width: 64, height: 64) }
        let probe = ControlledDecoder(); defer { probe.releaseAll() }
        let pipeline = injected(probe)
        let tasks = urls.map { url in Task { try await pipeline.detail(at: url) } }
        _ = try await waitFor(pipeline) { $0.inFlightUsers == urls.count }
        let blocked = try await waitFor(probe) { $0.detailStarts == 1 }
        XCTAssertEqual(blocked.activeDetail, 1)
        probe.releaseAll()
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(probe.snapshot.detailStarts, urls.count)
        XCTAssertEqual(probe.snapshot.maximumDetail, 1)
    }
    func testOneCancelledCoalescedWaiterDoesNotCancelOtherWaiters() async throws {
        let url = try fixture(width: 64, height: 64)
        let probe = ControlledDecoder(); defer { probe.releaseAll() }
        let pipeline = injected(probe)
        let tasks = (0..<10).map { _ in Task { try await pipeline.preview(at: url) } }
        let shared = try await waitFor(pipeline) { $0.inFlightUsers == 10 }
        XCTAssertEqual(shared.inFlightRequests, 1)
        _ = try await waitFor(probe) { $0.previewStarts == 1 }
        tasks[0].cancel()
        _ = try await waitFor(pipeline) { $0.inFlightUsers == 9 }
        probe.releaseAll()
        do { _ = try await tasks[0].value; XCTFail("Cancelled waiter received a successful image") }
        catch is CancellationError {}
        var results: [NSImage] = []
        for task in tasks.dropFirst() { results.append(try await task.value) }
        XCTAssertEqual(probe.snapshot.previewStarts, 1)
        XCTAssertTrue(results.allSatisfy { $0 === results[0] })
        let snapshot = await pipeline.testingSnapshot()
        XCTAssertEqual(snapshot.previewEntries, 1)
        XCTAssertEqual(snapshot.inFlightUsers, 0)
    }
    func testCancelledQueuedRequestNeverReachesDecoder() async throws {
        let urls = try (0..<8).map { try fixture("queued-\($0).png", width: 64, height: 64) }
        let probe = ControlledDecoder(); defer { probe.releaseAll() }
        let pipeline = injected(probe)
        let tasks = urls.map { url in Task { try await pipeline.preview(at: url) } }
        _ = try await waitFor(pipeline) { $0.inFlightUsers == urls.count }
        let blocked = try await waitFor(probe) { $0.previewStarts == 2 }
        let cancelledIndex = try XCTUnwrap(urls.indices.first { !blocked.filenames.contains(urls[$0].lastPathComponent) })
        tasks[cancelledIndex].cancel()
        _ = try await waitFor(pipeline) { $0.inFlightUsers == urls.count - 1 }
        probe.releaseAll()
        for (index, task) in tasks.enumerated() {
            if index == cancelledIndex {
                do { _ = try await task.value; XCTFail("Queued cancelled request decoded") }
                catch is CancellationError {}
            } else { _ = try await task.value }
        }
        XCTAssertEqual(probe.snapshot.previewStarts, urls.count - 1)
        XCTAssertFalse(probe.snapshot.filenames.contains(urls[cancelledIndex].lastPathComponent))
    }
    func testCancellingAllWaitersDoesNotCacheLateResultOrLeakPermit() async throws {
        let url = try fixture(width: 64, height: 64)
        let probe = ControlledDecoder(); defer { probe.releaseAll() }
        let pipeline = injected(probe)
        let task = Task { try await pipeline.detail(at: url) }
        _ = try await waitFor(probe) { $0.detailStarts == 1 }
        task.cancel()
        _ = try await waitFor(pipeline) { $0.inFlightUsers == 0 }
        probe.releaseAll()
        do { _ = try await task.value; XCTFail("Cancelled full detail request produced an image") }
        catch is CancellationError {}
        let cancelledState = await pipeline.testingSnapshot()
        XCTAssertEqual(cancelledState.detailEntries, 0)
        _ = try await pipeline.detail(at: url)
        XCTAssertEqual(probe.snapshot.detailStarts, 2)
        XCTAssertEqual(probe.snapshot.maximumDetail, 1)
    }
    func testCacheEvictsByByteBudgetAndOversizedFramesAreNotRetained() async throws {
        let urls = try (0..<3).map { try fixture("budget-\($0).png", width: 64, height: 64) }
        let probe = ControlledDecoder(blocked: false)
        let pipeline = injected(probe, previewBudget: 2 * 64 * 64 * 4, detailBudget: 64 * 64 * 4 - 1)
        for url in urls { _ = try await pipeline.preview(at: url) }
        let state = await pipeline.testingSnapshot()
        XCTAssertEqual(state.previewEntries, 2)
        XCTAssertLessThanOrEqual(state.previewBytes, 2 * 64 * 64 * 4)
        _ = try await pipeline.preview(at: urls[0])
        XCTAssertEqual(probe.snapshot.previewStarts, 4, "Least recently used frame should have been evicted")
        _ = try await pipeline.detail(at: urls[0])
        _ = try await pipeline.detail(at: urls[0])
        let detailState = await pipeline.testingSnapshot()
        XCTAssertEqual(detailState.detailEntries, 0)
        XCTAssertEqual(detailState.detailBytes, 0)
        XCTAssertEqual(probe.snapshot.detailStarts, 2, "A frame larger than its cache budget must not be retained")
    }
    func testOrdinaryGridPreviewRequestsNeverStartDetailDecoder() async throws {
        let urls = try (0..<20).map { try fixture("grid-\($0).arw", width: 64, height: 64) }
        let probe = ControlledDecoder(blocked: false)
        let pipeline = injected(probe)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { _ = try await pipeline.preview(at: url, maxPixel: 600) } }
            try await group.waitForAll()
        }
        let state = await pipeline.testingSnapshot()
        XCTAssertEqual(state.previewRequests, 20)
        XCTAssertEqual(state.previewDecodeStarts, 20)
        XCTAssertEqual(state.detailRequests, 0)
        XCTAssertEqual(state.detailDecodeStarts, 0)
        XCTAssertEqual(probe.snapshot.detailStarts, 0)
    }

}
