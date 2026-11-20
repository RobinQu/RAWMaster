import XCTest
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentPreviewServiceTests: XCTestCase {
  private func fixture() throws -> (URL, EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-preview-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("fixture.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 320, bitsPerPixel: 32)!
    for y in 0..<60 { for x in 0..<80 {
      let offset = y * bitmap.bytesPerRow + x * 4
      bitmap.bitmapData![offset] = UInt8(x * 255 / 80); bitmap.bitmapData![offset+1] = UInt8(y * 255 / 60)
      bitmap.bitmapData![offset+2] = 102; bitmap.bitmapData![offset+3] = 255
    } }
    let data = bitmap.representation(using: .png, properties: [:])!; try data.write(to: url)
    return (root, EditingSourceSnapshot(projectID: "test", assetID: "asset", contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(data.count), admissionFingerprint: "admitted", sourceLocation: url))
  }
  private func request(_ info: PreviewSessionInfo, consumer: PreviewConsumerID = .init(), revision: UInt64 = 1,
                       ev: Double = 0, role: PreviewConsumerRole = .primary, quality: PreviewQuality = .settled) -> DevelopmentPreviewRequest {
    .init(sessionID: info.id, sourceGeneration: info.sourceGeneration, consumerID: consumer, role: role, revision: revision,
          recipe: .init(exposureEV: ev), quality: quality, viewport: .init(maxPixel: quality == .detail ? 0 : 2400))
  }
  private func wait(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<200 { if await predicate() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    XCTFail("Timed out waiting for deterministic state", file: file, line: line)
  }
  func testIndependentLeasesShareCaptureAndCloseDoesNotAffectOtherPane() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService()
    let first = try await service.open(source: .raw(source)), second = try await service.open(source: .raw(source))
    XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(first.sourceIdentity, second.sourceIdentity)
    await service.close(first.id); await service.close(first.id)
    let frame = try await service.render(request(second))
    XCTAssertEqual(frame.outputPixelSize, CGSize(width: 80, height: 60)); XCTAssertFalse(frame.approximate)
    let stats = await service.statistics(); XCTAssertEqual(stats.sourceCaptures, 1)
    await service.close(second.id)
    let closed = await service.statistics(); XCTAssertEqual(closed.sourceSnapshotDiskBytes, 0)
  }
  func testCachePixelIdentityExcludesRevisionConsumerAndQualityButNotRecipe() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(), consumer = PreviewConsumerID()
    let info = try await service.open(source: .raw(source))
    let first = try await service.render(request(info, consumer: consumer))
    let second = try await service.render(request(info, consumer: consumer, revision: 2, quality: .interactive))
    XCTAssertEqual(first.outputKey, second.outputKey); XCTAssertNotEqual(first.frameID, second.frameID); XCTAssertEqual(second.revision, 2)
    let third = try await service.render(request(info, revision: 3, ev: 1))
    XCTAssertNotEqual(second.outputKey, third.outputKey)
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 1); XCTAssertEqual(stats.sourceFullHashPasses, 1)
    XCTAssertEqual(stats.sourceHashBytes, UInt64(source.byteCount)); XCTAssertGreaterThan(stats.sourceStatChecks, 2)
    await service.closeAll()
  }
  func testLeaseInvalidationIsIndependentAndStrictRelocationRevalidation() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService()
    let first = try await service.open(source: .raw(source)), second = try await service.open(source: .raw(source))
    await service.invalidate(first.id)
    do { _ = try await service.render(request(first)); XCTFail() } catch DevelopmentPreviewError.sourceInvalidated {} catch { XCTFail("\(error)") }
    _ = try await service.render(request(second))
    let moved = root.appendingPathComponent("moved.png"); try FileManager.default.copyItem(at: source.sourceLocation, to: moved)
    var relocated = source; relocated.sourceLocation = moved
    let validated = try await service.revalidate(first.id, source: .raw(relocated))
    XCTAssertEqual(validated.id, first.id); XCTAssertGreaterThan(validated.sourceGeneration, first.sourceGeneration)
    _ = try await service.render(request(validated))
    let stats = await service.statistics(); XCTAssertGreaterThanOrEqual(stats.sourceFullHashPasses, 2)
    await service.closeAll()
  }
  func testPhysicalMutationInvalidatesBothLeasesAndCannotUseCachedPixels() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService()
    let a = try await service.open(source: .raw(source)), b = try await service.open(source: .raw(source))
    _ = try await service.render(request(a))
    try Data("changed".utf8).write(to: source.sourceLocation)
    for info in [a, b] {
      do { _ = try await service.render(request(info)); XCTFail("stale source delivered") } catch DevelopmentPreviewError.sourceInvalidated {} catch { XCTFail("\(error)") }
    }
    await service.closeAll()
  }
  func testMemoryPressureEvictsBitmapsWithoutRehashingLiveSource() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(), info = try await service.open(source: .raw(source))
    _ = try await service.render(request(info)); await service.handleMemoryPressure()
    let pressure = await service.statistics(); XCTAssertEqual(pressure.cachedBitmapBytes, 0)
    _ = try await service.render(request(info, revision: 2))
    let stats = await service.statistics(); XCTAssertEqual(stats.sourceFullHashPasses, 1); XCTAssertEqual(stats.completedRenders, 2)
    await service.closeAll()
  }
  func testDiskBudgetRejectsBeforeCaptureAndSessionLimitCountsSources() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let tiny = DevelopmentPreviewService(policy: .init(sourceSnapshotDiskBytes: 1))
    do { _ = try await tiny.open(source: .raw(source)); XCTFail() } catch DevelopmentPreviewError.memoryBudgetExceeded {}
    let service = DevelopmentPreviewService(policy: .init(maximumSessions: 1))
    let first = try await service.open(source: .raw(source)), second = try await service.open(source: .raw(source))
    var different = source; different.assetID = "different"
    do { _ = try await service.open(source: .raw(different)); XCTFail() } catch DevelopmentPreviewError.capacityExceeded {}
    await service.close(first.id); _ = try await service.render(request(second)); await service.closeAll()
  }
  func testLatestWinsPendingBoundAndCancelDoesNotReleaseNativeBeforeJoin() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = BlockingPreviewBackend()
    let service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let info = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
    let old = Task { try await service.render(self.request(info, consumer: consumer, ev: 1)) }
    await wait { backend.count == 1 }
    let middle = Task { try await service.render(self.request(info, consumer: consumer, revision: 2, ev: 2)) }
    await wait { await service.statistics().pendingRequests == 1 }
    let final = Task { try await service.render(self.request(info, consumer: consumer, revision: 3, ev: 3)) }
    await wait { await service.statistics().supersededRequests >= 2 }
    let comparison = Task { try await service.render(self.request(info, revision: 1, ev: 4, role: .comparison)) }
    await wait { await service.statistics().pendingRequests == 2 }
    XCTAssertEqual(backend.count, 1)
    let running = await service.statistics(); XCTAssertEqual(running.activeNativeRenders, 1); XCTAssertEqual(running.maximumObservedPendingRequests, 2)
    backend.release(); await wait { backend.count == 2 }
    backend.release(); await wait { backend.count == 3 }; backend.release()
    do { _ = try await old.value; XCTFail() } catch DevelopmentPreviewError.superseded {}
    do { _ = try await middle.value; XCTFail() } catch DevelopmentPreviewError.superseded {}
    let frame = try await final.value; XCTAssertEqual(frame.revision, 3); _ = try await comparison.value
    let stats = await service.statistics(); XCTAssertEqual(stats.maximumObservedNativeRenders, 1)
    await service.closeAll()
  }
  func testCloseWaitsForNativeJoinWhileOtherLeaseRemainsUsable() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = BlockingPreviewBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let a = try await service.open(source: .raw(source)), b = try await service.open(source: .raw(source))
    let render = Task { try await service.render(self.request(a)) }; await wait { backend.count == 1 }
    let closed = LockedFlag(); let close = Task { await service.close(a.id); closed.set() }
    try await Task.sleep(nanoseconds: 20_000_000); XCTAssertFalse(closed.value)
    backend.release(); await close.value
    do { _ = try await render.value; XCTFail() } catch DevelopmentPreviewError.closed {}
    let next = Task { try await service.render(self.request(b, ev: 2)) }; await wait { backend.count == 2 }; backend.release(); _ = try await next.value
    await service.closeAll()
  }
  func testCriticalPressureRefusesNewHeavyWorkUntilNormalAndDoesNotRehash() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(), info = try await service.open(source: .raw(source))
    await service.handleMemoryPressure(critical: true)
    do { _ = try await service.render(request(info)); XCTFail() } catch DevelopmentPreviewError.memoryBudgetExceeded {}
    await service.handleMemoryPressure(normal: true)
    _ = try await service.render(request(info, revision: 2))
    let stats = await service.statistics(); XCTAssertEqual(stats.sourceFullHashPasses, 1)
    await service.closeAll()
  }
  func testIdenticalInflightPixelsJoinWithoutSecondNativeRender() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = BlockingPreviewBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let info = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
    let a = Task { try await service.render(self.request(info, consumer: consumer)) }; await wait { backend.count == 1 }
    let b = Task { try await service.render(self.request(info, consumer: consumer, revision: 2)) }
    await wait { await service.statistics().pendingRequests == 1 }; backend.release()
    do { _ = try await a.value; XCTFail() } catch DevelopmentPreviewError.superseded {}
    _ = try await b.value; XCTAssertEqual(backend.count, 1)
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 1)
    await service.closeAll()
  }
  func testFakeClockComparisonGetsSlotAfterPrimaryQuiescence() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let clock = PreviewTestClock(), backend = BlockingPreviewBackend()
    let service = DevelopmentPreviewService(now: { clock.value }, renderOverride: { try backend.render($0, $1) })
    let info = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
    let a = Task { try await service.render(self.request(info, consumer: consumer, ev: 1, quality: .interactive)) }
    await wait { backend.count == 1 }
    let b = Task { try await service.render(self.request(info, consumer: consumer, revision: 2, ev: 2, quality: .interactive)) }
    await wait { await service.statistics().pendingRequests == 1 }
    let c = Task { try await service.render(self.request(info, ev: 3, role: .comparison)) }
    await wait { await service.statistics().pendingRequests == 2 }
    clock.advance(200_000_000); backend.release(); await wait { backend.count == 2 }
    XCTAssertEqual(backend.exposures, [1, 3]); backend.release(); await wait { backend.count == 3 }; backend.release()
    do { _ = try await a.value; XCTFail() } catch DevelopmentPreviewError.superseded {}
    _ = try await b.value; _ = try await c.value; await service.closeAll()
  }
  @MainActor func testAppKitDrawReturnReportsFrameOnceAndNeverReportsNilImage() async throws {
    let canvas = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    let sourceBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    let image = NSImage(size: CGSize(width: 8, height: 8)); image.addRepresentation(sourceBitmap)
    let frameID = UUID(), delivered = expectation(description: "first draw returned")
    delivered.assertForOverFulfill = true
    canvas.frameID = frameID
    canvas.onFrameDrawn = { event in
      XCTAssertEqual(event.frameID, frameID); XCTAssertGreaterThanOrEqual(event.drawReturnedUptimeNanoseconds, event.drawBeganUptimeNanoseconds)
      XCTAssertEqual(event.imagePixelWidth, 8); delivered.fulfill()
    }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    canvas.update(image: image, actualPixels: false, transform: .init()); canvas.draw(canvas.bounds); canvas.draw(canvas.bounds)
    canvas.frameID = UUID(); canvas.update(image: nil, actualPixels: false, transform: .init()); canvas.draw(canvas.bounds)
    NSGraphicsContext.restoreGraphicsState()
    await fulfillment(of: [delivered], timeout: 1)
  }
  func testRevalidationTemporaryLeaseIsReleasedIfOriginalClosesWhileSuspended() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let barrier = PreviewAsyncBarrier()
    let service = DevelopmentPreviewService(policy: .init(maximumSessions: 1), revalidationLeaseOpened: { await barrier.pause() })
    let original = try await service.open(source: .raw(source))
    let revalidation = Task { try await service.revalidate(original.id, source: .raw(source)) }
    await wait { await barrier.waiting }
    await service.close(original.id)
    await barrier.release()
    do { _ = try await revalidation.value; XCTFail() } catch DevelopmentPreviewError.closed {}
    let clean = await service.statistics(); XCTAssertEqual(clean.sourceSnapshotDiskBytes, 0)
    var other = source; other.assetID = "new-source-after-race"
    let next = try await service.open(source: .raw(other)); await service.close(next.id)
  }
  func testConcurrentRepeatedCloseAndCloseAllJoinRemovedLeaseNativeWorker() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = BlockingPreviewBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let info = try await service.open(source: .raw(source))
    let render = Task { try await service.render(self.request(info)) }; await wait { backend.count == 1 }
    let firstDone = LockedFlag(), repeatedDone = LockedFlag(), allDone = LockedFlag()
    let first = Task { await service.close(info.id); firstDone.set() }
    await wait { await service.statistics().supersededRequests == 1 }
    let repeated = Task { await service.close(info.id); repeatedDone.set() }
    let all = Task { await service.closeAll(); allDone.set() }
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertFalse(firstDone.value); XCTAssertFalse(repeatedDone.value); XCTAssertFalse(allDone.value)
    let running = await service.statistics(); XCTAssertEqual(running.activeNativeRenders, 1); XCTAssertGreaterThan(running.sourceSnapshotDiskBytes, 0)
    backend.release(); await first.value; await repeated.value; await all.value
    XCTAssertTrue(firstDone.value); XCTAssertTrue(repeatedDone.value); XCTAssertTrue(allDone.value)
    do { _ = try await render.value; XCTFail() } catch DevelopmentPreviewError.closed {}
    let joined = await service.statistics(); XCTAssertEqual(joined.activeNativeRenders, 0); XCTAssertEqual(joined.sourceSnapshotDiskBytes, 0)
  }
  func testDetailRejectsProxyViewportAndActuallyReturnsNativePixels() async throws {
    let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2501, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 2501*4, bitsPerPixel: 32)!
    let data = bitmap.representation(using: .png, properties: [:])!, url = root.appendingPathComponent("wide.png")
    try data.write(to: url)
    let source = EditingSourceSnapshot(projectID: "test", assetID: "wide", contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(data.count), admissionFingerprint: "admitted", sourceLocation: url)
    let service = DevelopmentPreviewService(), info = try await service.open(source: .raw(source))
    do {
      _ = try await service.render(.init(sessionID: info.id, sourceGeneration: info.sourceGeneration, consumerID: .init(), role: .primary, revision: 1, recipe: .init(), quality: .detail))
      XCTFail("Default2400 must never masquerade as native detail")
    } catch DevelopmentPreviewError.invalidRequest {}
    let detail = try await service.render(request(info, quality: .detail))
    XCTAssertEqual(detail.outputPixelSize, CGSize(width: 2501, height: 1)); XCTAssertEqual(detail.canonicalPixelSize, detail.outputPixelSize)
    XCTAssertFalse(detail.approximate); await service.closeAll()
  }
  func testRevalidationReusesExclusiveSourceSlotAtMaximumSessionsOne() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(policy: .init(maximumSessions: 1))
    let first = try await service.open(source: .raw(source))
    var replacement = source; replacement.assetID = "replacement"
    let second = try await service.revalidate(first.id, source: .raw(replacement))
    XCTAssertEqual(first.id, second.id); XCTAssertNotEqual(first.sourceIdentity, second.sourceIdentity)
    _ = try await service.render(request(second)); await service.closeAll()
    let closed = await service.statistics(); XCTAssertEqual(closed.sourceSnapshotDiskBytes, 0)
  }
  func testThreeHundredEvent20HzBurstBoundsFinalSettledAndComparisonFairness() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let clock = PreviewTestClock(), backend = BlockingPreviewBackend()
    let service = DevelopmentPreviewService(now: { clock.value }, renderOverride: { try backend.render($0, $1) })
    let info = try await service.open(source: .raw(source)), primary = PreviewConsumerID(), comparison = PreviewConsumerID()
    var tasks: [Task<DevelopmentPreviewFrame, Error>] = []
    var submitted: UInt64 = 0
    for index in 0..<300 {
      clock.advance(50_000_000) // 20Hz intent clock, without wall-clock/GPU latency claims.
      let event = request(info, consumer: primary, revision: UInt64(index), ev: Double(index % 19)/10-0.9, quality: .interactive)
      tasks.append(Task { try await service.render(event) }); submitted += 1
      let expected = submitted; await wait { await service.statistics().submittedRequests == expected }
      if index == 0 { await wait { backend.count == 1 } }
      if index == 100 || index == 200 {
        let baseline = request(info, consumer: comparison, revision: UInt64(index), ev: index == 100 ? 2.1 : 2.2, role: .comparison)
        tasks.append(Task { try await service.render(baseline) }); submitted += 1
        let expected = submitted; await wait { await service.statistics().submittedRequests == expected }
      }
    }
    let settled = request(info, consumer: primary, revision: 300, ev: 1.2345, quality: .settled)
    tasks.append(Task { try await service.render(settled) }); submitted += 1
    let expected = submitted; await wait { await service.statistics().submittedRequests == expected }
    let blocked = await service.statistics(); XCTAssertEqual(blocked.activeNativeRenders, 1); XCTAssertEqual(blocked.pendingRequests, 2)
    clock.advance(200_000_000); backend.release(); await wait { backend.count == 2 }
    XCTAssertEqual(backend.exposures.last, 2.2, "latest baseline gets quiet slot")
    backend.release(); await wait { backend.count == 3 }; backend.release()
    var delivered = 0, superseded = 0, settledDelivered = false
    for task in tasks {
      do { let frame = try await task.value; delivered += 1; if frame.consumerID == primary { settledDelivered = frame.revision == 300 && frame.quality == .settled } }
      catch DevelopmentPreviewError.superseded { superseded += 1 }
    }
    XCTAssertEqual(delivered, 2); XCTAssertEqual(superseded, 301); XCTAssertTrue(settledDelivered)
    let final = await service.statistics(); XCTAssertEqual(final.maximumObservedNativeRenders, 1); XCTAssertEqual(final.maximumObservedPendingRequests, 2)
    XCTAssertEqual(final.completedRenders, 3)
    print("BURST fake20Hz sliderEvents300 submitted303 delivered2 superseded301 native3 activeMax1 pendingMax2 finalSettledDelivered=true; superseded intents excluded from any frame-latency distribution")
    await service.closeAll()
  }
  func testOwnedCPUPreviewPreservesAlphaGradientsEdgesAndSRGB() async throws {
    let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let input = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [.alphaNonpremultiplied], bytesPerRow: 320, bitsPerPixel: 32)!
    for y in 0..<60 { for x in 0..<80 {
      let offset = y * input.bytesPerRow + x * 4
      input.bitmapData![offset] = UInt8(x * 255 / 79); input.bitmapData![offset+1] = y % 2 == 0 ? 255 : 0
      input.bitmapData![offset+2] = x % 2 == 0 ? 255 : 0; input.bitmapData![offset+3] = UInt8(y * 255 / 59)
    } }
    input.setProperty(.colorSyncProfileData, withValue: NSColorSpace.sRGB.iccProfileData!)
    let data = input.representation(using: .png, properties: [:])!, url = root.appendingPathComponent("alpha-gradient-edges.png")
    try data.write(to: url)
    let source = EditingSourceSnapshot(projectID: "test", assetID: "alpha", contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(data.count), admissionFingerprint: "alpha", sourceLocation: url)
    let service = DevelopmentPreviewService(), info = try await service.open(source: .raw(source)), old = DevelopmentService()
    for (index, recipe) in [DevelopmentRecipe(), .init(exposureEV: 0.7), .init(whiteBalance: .temperatureTint(temperature: 4500, tint: 20))].enumerated() {
      let frame = try await service.render(.init(sessionID: info.id, sourceGeneration: info.sourceGeneration, consumerID: .init(), role: .primary, revision: UInt64(index), recipe: recipe, quality: .settled))
      let canonical = try await old.preview(source: source, recipe: recipe, maxPixel: 2400)
      let actual = try XCTUnwrap(frame.image.representations.first as? NSBitmapImageRep), expected = try XCTUnwrap(canonical.image.representations.first as? NSBitmapImageRep)
      XCTAssertTrue(actual.hasAlpha); XCTAssertEqual(actual.bitsPerSample, 8); XCTAssertEqual(actual.pixelsWide, 80); XCTAssertEqual(actual.pixelsHigh, 60)
      XCTAssertNotNil(actual.colorSpace.iccProfileData); XCTAssertEqual(actual.bytesPerRow, expected.bytesPerRow)
      let length = actual.bytesPerRow * actual.pixelsHigh
      let a = try XCTUnwrap(actual.bitmapData), b = try XCTUnwrap(expected.bitmapData)
      var maximum = 0
      for offset in 0..<length { maximum = max(maximum, abs(Int(a[offset])-Int(b[offset]))) }
      XCTAssertLessThanOrEqual(maximum, 1, "sRGB/alpha/gradient/edge regression")
    }
    await service.closeAll()
  }
  func testComparisonRunsAfterLatestPrimarySettledBeforeRedundantDetail() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = BlockingPreviewBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let info = try await service.open(source: .raw(source))
    let first = Task { try await service.render(self.request(info, ev: 1)) }; await wait { backend.count == 1 }
    let detail = Task { try await service.render(self.request(info, ev: 2, quality: .detail)) }
    await wait { await service.statistics().pendingRequests == 1 }
    let compare = Task { try await service.render(self.request(info, ev: 3, role: .comparison)) }
    await wait { await service.statistics().pendingRequests == 2 }
    backend.release(); await wait { backend.count == 2 }; XCTAssertEqual(backend.exposures, [1, 3])
    backend.release(); await wait { backend.count == 3 }; backend.release()
    _ = try await first.value; _ = try await detail.value; _ = try await compare.value
    await service.closeAll()
  }
  private func quietHistogramRequest(_ info: PreviewSessionInfo, consumer: PreviewConsumerID,
                                     revision: UInt64 = 1, operation: DevelopmentAnalysisOperation = .displayHistogram) throws -> DevelopmentAnalysisRequest {
    let recipe = try DevelopmentRecipe().promotingToV3()
    let preview = DevelopmentPreviewRequest(sessionID: info.id, sourceGeneration: info.sourceGeneration,
      consumerID: consumer, role: .primary, revision: revision, recipe: recipe, quality: .settled)
    return .init(preview: preview, expectedRecipeFingerprint: try EditingFingerprint.of(recipe),
      stage: .workingImageBeforeGeometry, operation: operation)
  }
  private func expectQuietMockSuperseded(_ task: Task<DevelopmentAnalysisResult, Error>, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await task.value; XCTFail("Mock analysis must terminate with its declared error", file: file, line: line) }
    catch DevelopmentPreviewError.superseded {}
    catch { XCTFail("Unexpected analysis result: \(error)", file: file, line: line) }
  }
  func testBackgroundHistogramFreshQuietWindowAndZeroInterval() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for milliseconds in [150, 0] {
      let clock = PreviewTestClock(), log = HistogramQuietTestBackend()
      let service = DevelopmentPreviewService(policy: .init(comparisonQuiescenceMilliseconds: milliseconds),
        now: { clock.value }, analysisOverride: { try log.analyze($0, $1) }, renderOverride: { try log.render($0, $1) })
      let info = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
      let request = try quietHistogramRequest(info, consumer: consumer)
      let task = Task { try await service.analyze(request) }
      if milliseconds > 0 {
        await wait { await service.analysisStatistics().pendingHistogram == 1 }
        XCTAssertEqual(log.events, [])
        clock.advance(149_000_000)
        // A nonmatching consumer has nothing to cancel: re-evaluate the injected clock using an existing public pump.
        await service.cancelAnalysis(consumerID: PreviewConsumerID())
        XCTAssertEqual(log.events, [])
        let waiting = await service.statistics(); XCTAssertEqual(waiting.activeNativeRenders, 0)
        clock.advance(1_000_000)
        await wait { log.events == ["histogram:1"] } // The scheduled quietWake, not another input, must admit it.
      }
      await expectQuietMockSuperseded(task)
      XCTAssertEqual(log.events, ["histogram:1"])
      await service.closeAll()
      let closed = await service.statistics(); XCTAssertEqual(closed.activeNativeRenders, 0)
      XCTAssertEqual(closed.sourceSnapshotDiskBytes, 0); XCTAssertEqual(closed.maximumObservedNativeRenders, 1)
    }
  }
  func testBackgroundHistogramLatestResetsDeadlineAndClosedWakeCannotRevive() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let clock = PreviewTestClock(), log = HistogramQuietTestBackend()
    let service = DevelopmentPreviewService(now: { clock.value }, analysisOverride: { try log.analyze($0, $1) },
      renderOverride: { try log.render($0, $1) })
    let info = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
    let r1 = try quietHistogramRequest(info, consumer: consumer)
    let first = Task { try await service.analyze(r1) }
    await wait { await service.analysisStatistics().pendingHistogram == 1 }
    clock.advance(100_000_000)
    let r2 = try quietHistogramRequest(info, consumer: consumer, revision: 2)
    let second = Task { try await service.analyze(r2) }
    await wait { await service.analysisStatistics().submitted == 2 }
    await expectQuietMockSuperseded(first)
    clock.advance(50_000_000); await service.cancelAnalysis(consumerID: PreviewConsumerID())
    XCTAssertEqual(log.events, [], "The replaced item's deadline cannot admit the latest item early")
    clock.advance(99_000_000); await service.cancelAnalysis(consumerID: PreviewConsumerID())
    XCTAssertEqual(log.events, [])
    clock.advance(1_000_000); await service.cancelAnalysis(consumerID: PreviewConsumerID())
    await expectQuietMockSuperseded(second); XCTAssertEqual(log.events, ["histogram:2"])
    let r3 = try quietHistogramRequest(info, consumer: consumer, revision: 3)
    let last = Task { try await service.analyze(r3) }
    await wait { await service.analysisStatistics().pendingHistogram == 1 }
    await service.closeAll()
    do { _ = try await last.value; XCTFail("Closed pending histogram cannot complete") }
    catch DevelopmentPreviewError.closed {}
    clock.advance(1_000_000_000); await service.cancelAnalysis(consumerID: PreviewConsumerID())
    XCTAssertEqual(log.events, ["histogram:2"])
    let analysis = await service.analysisStatistics(), closed = await service.statistics()
    XCTAssertEqual(analysis.pendingHistogram, 0); XCTAssertEqual(analysis.active, 0)
    XCTAssertEqual(closed.activeNativeRenders, 0); XCTAssertEqual(closed.sourceSnapshotDiskBytes, 0)
  }
  func testBackgroundHistogramQuietDoesNotDelayPrimaryUserOrOwedComparison() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let clock = PreviewTestClock(), log = HistogramQuietTestBackend(blockRenders: true)
    defer { for _ in 0..<8 { log.release() } }
    let service = DevelopmentPreviewService(now: { clock.value }, analysisOverride: { try log.analyze($0, $1) },
      renderOverride: { try log.render($0, $1) })
    let info = try await service.open(source: .raw(source)), primary = PreviewConsumerID(), histogramConsumer = PreviewConsumerID()
    let firstRequest = request(info, consumer: primary, ev: 1)
    let first = Task { try await service.render(firstRequest) }
    await wait { log.events == ["preview:1"] }
    let histRequest = try quietHistogramRequest(info, consumer: histogramConsumer)
    let histogram = Task { try await service.analyze(histRequest) }
    await wait { await service.analysisStatistics().pendingHistogram == 1 }
    let compareRequest = request(info, ev: 2, role: .comparison)
    let comparison = Task { try await service.render(compareRequest) }
    await wait { await service.statistics().pendingRequests == 1 }
    let userRequest = try quietHistogramRequest(info, consumer: PreviewConsumerID(), operation: .automatic(.light))
    let user = Task { try await service.analyze(userRequest) }
    await wait { await service.analysisStatistics().pendingUser == 1 }
    log.release(); _ = try await first.value
    await wait { log.events == ["preview:1", "preview:2"] }
    log.release(); _ = try await comparison.value
    await expectQuietMockSuperseded(user)
    XCTAssertEqual(log.events, ["preview:1", "preview:2", "user:1"])
    let stillWaiting = await service.analysisStatistics(); XCTAssertEqual(stillWaiting.pendingHistogram, 1)
    clock.advance(150_000_000); await service.cancelAnalysis(consumerID: PreviewConsumerID())
    await expectQuietMockSuperseded(histogram)
    XCTAssertEqual(log.events, ["preview:1", "preview:2", "user:1", "histogram:1"])
    let obsoleteRequest = try quietHistogramRequest(info, consumer: histogramConsumer, revision: 2)
    let obsolete = Task { try await service.analyze(obsoleteRequest) }
    await wait { await service.analysisStatistics().pendingHistogram == 1 }
    let newestRequest = request(info, consumer: histogramConsumer, revision: 3, ev: 3)
    let newest = Task { try await service.render(newestRequest) }
    await wait { log.events.last == "preview:3" }
    await expectQuietMockSuperseded(obsolete)
    XCTAssertEqual(log.events.filter { $0.hasPrefix("histogram:") }, ["histogram:1"])
    log.release(); _ = try await newest.value
    await service.closeAll()
    let closed = await service.statistics(); XCTAssertEqual(closed.maximumObservedNativeRenders, 1)
    XCTAssertEqual(closed.activeNativeRenders, 0); XCTAssertEqual(closed.sourceSnapshotDiskBytes, 0)
  }

}
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock(); private var storage = false
  var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
  func set() { lock.lock(); storage = true; lock.unlock() }
}
private final class BlockingPreviewBackend: @unchecked Sendable {
  private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
  private var values: [Double] = []
  var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
  var exposures: [Double] { lock.lock(); defer { lock.unlock() }; return values }
  func release() { semaphore.signal() }
  func render(_ recipe: DevelopmentRecipe, _ maxPixel: Int) throws -> PreviewPixels {
    lock.lock(); values.append(recipe.exposureEV); lock.unlock(); semaphore.wait()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    let image = NSImage(size: CGSize(width: 8, height: 8)); image.addRepresentation(bitmap)
    return PreviewPixels(image: image, nativeSize: CGSize(width: 8, height: 8), outputSize: CGSize(width: 8, height: 8), bytes: 256)
  }
}

private final class PreviewTestClock: @unchecked Sendable {
  private let lock = NSLock(); private var storage: UInt64 = 1_000_000_000
  var value: UInt64 { lock.lock(); defer { lock.unlock() }; return storage }
  func advance(_ delta: UInt64) { lock.lock(); storage += delta; lock.unlock() }
}

private actor PreviewAsyncBarrier {
  private var continuation: CheckedContinuation<Void, Never>?
  var waiting: Bool { continuation != nil }
  func pause() async { await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}

private final class HistogramQuietTestBackend: @unchecked Sendable {
  private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
  private var stored: [String] = []
  private let blockRenders: Bool
  init(blockRenders: Bool = false) { self.blockRenders = blockRenders }
  var events: [String] { lock.lock(); defer { lock.unlock() }; return stored }
  private func record(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
  func release() { semaphore.signal() }
  func analyze(_ request: DevelopmentAnalysisRequest, _ binding: DevelopmentLocalEditSourceBinding) throws -> DevelopmentAnalysisResult {
    record((request.operation.isHistogram ? "histogram:" : "user:") + String(request.preview.revision))
    throw DevelopmentPreviewError.superseded // Deliberate terminal mock, not a real histogram or pixel computation.
  }
  func render(_ recipe: DevelopmentRecipe, _ maxPixel: Int) throws -> PreviewPixels {
    record("preview:" + String(Int(recipe.exposureEV)))
    if blockRenders { semaphore.wait() }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    let image = NSImage(size: CGSize(width: 8, height: 8)); image.addRepresentation(bitmap)
    return .init(image: image, nativeSize: .init(width: 8, height: 8), outputSize: .init(width: 8, height: 8), bytes: 256)
  }
}
