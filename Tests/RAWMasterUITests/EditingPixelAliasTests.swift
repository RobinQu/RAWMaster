import AppKit
import CryptoKit
import XCTest
@testable import RAWMaster
import RAWMasterCore
@testable import RAWMasterImaging

final class EditingPixelAliasTests: XCTestCase {
  @MainActor private func wait(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<1_000 { if await predicate() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
    XCTFail("Pixel alias pane timed out", file: file, line: line)
  }
  @MainActor func testNeutralAliasRetainsEngineFenceAndActualFrameRecipeInputAndLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pane-pixel-alias-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pixels = PaneAliasNative(), service = DevelopmentPreviewService(renderOverride: { try pixels.render($0, $1) })
    defer { pixels.release() }
    let backend = PaneAliasBackend(service), pane = EditingPreviewPane(role: .primary, backend: backend)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    memset(bitmap.bitmapData!, 128, 256)
    let data = bitmap.representation(using: .png, properties: [:])!, file = root.appendingPathComponent("source.png")
    try data.write(to: file)
    let source = EditingSourceSnapshot(projectID: "alias", assetID: "a", contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteCount: Int64(data.count), admissionFingerprint: "admitted", sourceLocation: file)
    let context = EditingDraftPresentation(focusID: UUID(), workID: "a", draftParentID: "original", selectedVersionID: "original", cropOverlay: false, comparing: false)
    func intent(_ recipe: DevelopmentRecipe, _ quality: PreviewQuality = .interactive) throws -> EditingPreviewIntent {
      try .init(source: .raw(source), recipe: recipe, quality: quality, draftPresentation: context, presentationID: "editable-draft")
    }
    var events: [EditingPreviewDiagnosticEvent] = []; pane.diagnosticSink = { events.append($0) }
    pane.submit(try intent(.init()), input: .capture(control: "seed-v1", phase: "change"))
    try await wait { pane.frame != nil && !pane.rendering }
    let seed = try XCTUnwrap(pane.frame), firstRequest = try XCTUnwrap(backend.requests.values.first)
    XCTAssertEqual(pane.frameRecipe, .init())
    pixels.blockNext()
    let lateInput = EditingPreviewInput.capture(control: "old-engine-active", phase: "change")
    pane.submit(try intent(.init(exposureEV: 1)), input: lateInput)
    try await wait { pixels.count == 2 }
    var actual = try DevelopmentRecipe().promotingToV2()
    actual.color!.grading.global.hueDegrees = 233; actual.color!.grading.blending = 19; actual.color!.grading.balance = -24
    actual.color!.curves.blue.points.insert(.init(x: 0.4, y: 0.4), at: 1)
    let currentInput = EditingPreviewInput.capture(control: "neutral-v2-settled", phase: "end")
    pane.submit(try intent(actual, .settled), input: currentInput)
    try await wait { await backend.closing == 1 }
    let whileClosing = await backend.counts
    XCTAssertEqual(whileClosing.opens, 1); XCTAssertEqual(whileClosing.channels, 1)
    XCTAssertFalse(events.contains { $0.operationID == lateInput.id && ($0.outcome == "accepted" || $0.outcome == "progress") })
    pixels.release()
    try await wait { pane.frameRecipe == actual && pane.frame?.quality == .settled && !pane.rendering }
    let frame = try XCTUnwrap(pane.frame), finalRequest = try XCTUnwrap(backend.requests.values.last)
    XCTAssertTrue(frame.image === seed.image, "Only the already resident bitmap is reused")
    XCTAssertNotEqual(frame.id, seed.id); XCTAssertGreaterThan(frame.revision, seed.revision)
    XCTAssertEqual(frame.revision, pane.currentRevision); XCTAssertEqual(frame.leaseID, seed.leaseID); XCTAssertEqual(frame.generation, seed.generation)
    XCTAssertEqual(pane.frameRecipe, actual); XCTAssertEqual(finalRequest.recipe, actual)
    XCTAssertEqual(finalRequest.sessionID, firstRequest.sessionID); XCTAssertEqual(finalRequest.sourceGeneration, firstRequest.sourceGeneration)
    XCTAssertEqual(finalRequest.quality, .settled); XCTAssertEqual(finalRequest.deliveryPolicy, .inFlightProgress)
    XCTAssertEqual(EditingPreviewInput.decodeCorrelation(finalRequest.clientCorrelation, token: UUID()).id, currentInput.id)
    let counts = await backend.counts
    XCTAssertEqual(counts.opens, 1); XCTAssertEqual(counts.channels, 2); XCTAssertEqual(counts.closedChannels, 1); XCTAssertGreaterThanOrEqual(counts.joins, 2)
    XCTAssertEqual(counts.closedLeases, 0)
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 1); XCTAssertEqual(stats.completedRenders, 2); XCTAssertEqual(pixels.count, 2)
    XCTAssertFalse(pane.didDraw(.init(frameID: seed.id, drawBeganUptimeNanoseconds: 1, drawReturnedUptimeNanoseconds: 2, imagePixelWidth: 8, imagePixelHeight: 8)))
    XCTAssertTrue(pane.didDraw(.init(frameID: frame.id, drawBeganUptimeNanoseconds: 3, drawReturnedUptimeNanoseconds: 4, imagePixelWidth: 8, imagePixelHeight: 8)))
    XCTAssertTrue(events.contains { $0.operationID == currentInput.id && $0.outcome == "drawn" })
    XCTAssertFalse(events.contains { $0.operationID == lateInput.id && ($0.outcome == "accepted" || $0.outcome == "progress" || $0.outcome == "drawn") })
    await pane.shutdown(); await service.closeAll()
    XCTAssertEqual(pane.ownedOperationCount, 0)
  }
}

private final class PaneAliasRequests: @unchecked Sendable {
  private let lock = NSLock(); private var storage: [DevelopmentPreviewRequest] = []
  var values: [DevelopmentPreviewRequest] { lock.lock(); defer { lock.unlock() }; return storage }
  func append(_ request: DevelopmentPreviewRequest) { lock.lock(); storage.append(request); lock.unlock() }
}
private actor PaneAliasBackend: EditingPreviewBackend {
  let service: DevelopmentPreviewService
  nonisolated let requests = PaneAliasRequests()
  private var opens = 0, channels = 0, closedChannels = 0, closedLeases = 0, joins = 0
  private(set) var closing = 0
  var counts: (opens: Int, channels: Int, closedChannels: Int, closedLeases: Int, joins: Int) { (opens, channels, closedChannels, closedLeases, joins) }
  init(_ service: DevelopmentPreviewService) { self.service = service }
  func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { opens += 1; return .init(try await service.open(source: source)) }
  func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap { .init(try await service.render(request)) }
  func cancel(_ consumer: PreviewConsumerID) async { await service.cancel(consumerID: consumer) }
  func cancelAndJoin(_ consumer: PreviewConsumerID) async { joins += 1; await service.cancelAndJoin(consumerID: consumer) }
  func close(_ lease: DevelopmentPreviewSessionID) async { closedLeases += 1; await service.close(lease) }
  func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { .init(try await service.revalidate(lease, source: source)) }
  func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel {
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.generation, consumerID: consumer)
    channels += 1
    let requests = requests
    return .init(id: channel.id, snapshots: channel.snapshots, submit: { requests.append($0); return try channel.submit($0) }, noteActivity: { channel.noteActivity() })
  }
  func closeProgressChannel(_ id: PreviewProgressChannelID) async { closing += 1; await service.closeProgressChannel(id); closedChannels += 1; closing -= 1 }
}
private final class PaneAliasNative: @unchecked Sendable {
  private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
  private var rendered = 0, blocks = false
  var count: Int { lock.lock(); defer { lock.unlock() }; return rendered }
  func blockNext() { lock.lock(); blocks = true; lock.unlock() }
  func release() { semaphore.signal() }
  func render(_ recipe: DevelopmentRecipe, _ maxPixel: Int) throws -> PreviewPixels {
    lock.lock(); rendered += 1; let block = blocks; blocks = false; lock.unlock()
    if block { semaphore.wait() }
    let image = NSImage(size: .init(width: 8, height: 8))
    return .init(image: image, nativeSize: .init(width: 8, height: 8), outputSize: .init(width: 8, height: 8), bytes: 256)
  }
}
