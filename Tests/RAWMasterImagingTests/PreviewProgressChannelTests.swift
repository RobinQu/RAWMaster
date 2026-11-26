import XCTest
import AppKit
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewProgressChannelTests: XCTestCase {
  private func fixture() throws -> (URL, EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-progress-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    memset(bitmap.bitmapData!, 128, 256)
    let data = bitmap.representation(using: .png, properties: [:])!, file = root.appendingPathComponent("source.png")
    try data.write(to: file)
    return (root, .init(projectID: "progress", assetID: "a", contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteCount: Int64(data.count), admissionFingerprint: "test", sourceLocation: file))
  }
  private func request(_ lease: PreviewSessionInfo, _ cid: PreviewConsumerID, _ revision: UInt64,
                       ev: Double = 0, quality: PreviewQuality = .interactive) -> DevelopmentPreviewRequest {
    .init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid, role: .primary,
      revision: revision, recipe: .init(exposureEV: ev), quality: quality,
      deliveryPolicy: .inFlightProgress, clientCorrelation: Data("input-\(revision)".utf8))
  }
  private func wait(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<400 { if await predicate() { return }; try await Task.sleep(nanoseconds: 2_500_000) }
    XCTFail("deterministic state timeout", file: file, line: line)
    throw ProgressFailure.failed("deterministic state timeout at \(file):\(line)")
  }
  func testProgressPreservesActiveAndOnlySupersedesPendingWithOwnCorrelation() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let observed = ProgressObserved(), observer = Task { for await snapshot in channel.snapshots { observed.set(snapshot) } }
    let a = try channel.submit(request(lease, cid, 1, ev: 1)); try await wait { native.count == 1 }
    let b = try channel.submit(request(lease, cid, 2, ev: 2)); try await wait { await service.statistics().pendingRequests == 1 }
    let c = try channel.submit(request(lease, cid, 3, ev: 3, quality: .settled))
    try await wait { observed.value?.pending?.id == c.work.id }
    XCTAssertEqual(observed.value?.active?.id, a.work.id)
    native.release(); try await wait { native.count == 2 }
    try await wait { observed.value?.latestCompleted?.work.id == a.work.id }
    XCTAssertEqual(observed.value?.latestCompleted?.work.request.clientCorrelation, Data("input-1".utf8))
    XCTAssertNil(observed.value?.latestTargetTerminal)
    native.release(); try await wait { observed.value?.latestTargetTerminal?.outcome == .completed }
    XCTAssertEqual(observed.value?.latestCompleted?.frame.revision, 3)
    XCTAssertTrue(observed.value?.terminals.contains(where: { $0.work.id == b.work.id && $0.outcome == .superseded }) == true)
    XCTAssertEqual(native.exposures, [1, 3])
    let stats = await service.statistics(); XCTAssertEqual(stats.maximumObservedNativeRenders, 1); XCTAssertLessThanOrEqual(stats.maximumObservedPendingRequests, 2)
    await service.closeProgressChannel(channel.id); await observer.value; await service.closeAll()
  }
  func testCacheAheadIsStickyAfterOlderActiveAndMetadataFlood() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let observed = ProgressObserved(), observer = Task { for await snapshot in channel.snapshots { observed.set(snapshot) } }
    _ = try channel.submit(request(lease, cid, 1, ev: 0)); try await wait { native.count == 1 }; native.release()
    try await wait { observed.value?.latestTargetTerminal?.outcome == .completed }
    let active = try channel.submit(request(lease, cid, 2, ev: 1)); try await wait { native.count == 2 }
    let exact = try channel.submit(request(lease, cid, 10, ev: 0, quality: .settled))
    try await wait { observed.value?.latestTargetTerminal?.work.id == exact.work.id }
    let exactFrame = observed.value?.latestCompleted?.frame.frameID
    native.release(); try await wait { observed.value?.active == nil }
    XCTAssertEqual(observed.value?.latestCompleted?.work.id, exact.work.id)
    XCTAssertEqual(observed.value?.latestCompleted?.frame.frameID, exactFrame)
    XCTAssertTrue(observed.value?.terminals.contains(where: { $0.work.id == active.work.id && $0.outcome == .completed }) == true)
    for revision in 11...110 { _ = try channel.submit(request(lease, cid, UInt64(revision), ev: 0, quality: .settled)) }
    try await wait { observed.value?.latestTargetTerminal?.work.request.revision == 110 }
    XCTAssertEqual(observed.value?.latestCompleted?.work.request.revision, 110)
    XCTAssertEqual(observed.value?.terminals.count, 64); XCTAssertGreaterThan(observed.value?.terminalOverflowCount ?? 0, 0)
    await service.closeProgressChannel(channel.id); await observer.value; await service.closeAll()
  }
  func testCloseAndDuplicateCloseJoinBeforeRebindAndOldActivityCannotPulseNewChannel() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let a = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    _ = try a.submit(request(lease, cid, 1)); try await wait { native.count == 1 }
    do { _ = try await service.render(request(lease, cid, 2)); XCTFail() } catch DevelopmentPreviewError.invalidRequest {}
    let done = ProgressCounter()
    let close1 = Task { await service.closeProgressChannel(a.id); done.increment() }
    let close2 = Task { await service.closeProgressChannel(a.id); done.increment() }
    try await Task.sleep(nanoseconds: 15_000_000); XCTAssertEqual(done.value, 0)
    do { _ = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid); XCTFail() } catch DevelopmentPreviewError.invalidRequest {}
    native.release(); await close1.value; await close2.value
    let b = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    a.noteActivity(); await service.closeProgressChannel(a.id)
    let work = try b.submit(request(lease, cid, 1, ev: 2)); XCTAssertEqual(work.work.request.revision, 1)
    try await wait { native.count == 2 }; native.release(); try await wait { await service.statistics().completedRenders == 2 }
    await service.closeProgressChannel(b.id); await service.closeAll()
  }
  func testLegacyPromptCancellationNeedsActualJoinBeforeProgressFactory() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let old = Task { try await service.render(self.request(lease, cid, 1)) }; try await wait { native.count == 1 }
    old.cancel(); do { _ = try await old.value; XCTFail() } catch DevelopmentPreviewError.superseded {} catch is CancellationError {}
    do { _ = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid); XCTFail() } catch DevelopmentPreviewError.invalidRequest {}
    let done = ProgressCounter(), join1 = Task { await service.cancelAndJoin(consumerID: cid) }
    let join2 = Task { await service.cancelAndJoin(consumerID: cid); done.increment() }
    try await Task.sleep(nanoseconds: 10_000_000); XCTAssertEqual(done.value, 0)
    native.release(); await join1.value; await join2.value
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    await service.closeProgressChannel(channel.id); await service.closeAll()
  }
  func testStickyFailureAndInvalidationAreIndependentOfRingAndOldActive() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { recipe, size in
      if recipe.exposureEV == 3 { throw ProgressFailure.failed(String(repeating: "界", count: 3000)) }
      return try native.render(recipe, size)
    })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let observed = ProgressObserved(), observer = Task { for await snapshot in channel.snapshots { observed.set(snapshot) } }
    _ = try channel.submit(request(lease, cid, 1, ev: 3)); try await wait { observed.value?.latestTargetTerminal?.outcome == .failed }
    XCTAssertLessThanOrEqual(observed.value?.latestTargetTerminal?.message?.utf8.count ?? Int.max, 1024)
    let active = try channel.submit(request(lease, cid, 2, ev: 1)); try await wait { native.count == 1 }
    XCTAssertNil(observed.value?.latestTargetTerminal)
    await service.cancel(consumerID: cid); try await wait { observed.value?.latestTargetTerminal?.outcome == .cancelled }
    XCTAssertEqual(observed.value?.active?.id, active.work.id)
    let invalidation=Task { await service.invalidate(lease.id) }
    try await wait { observed.value?.state == .sourceInvalidated }
    XCTAssertNil(observed.value?.latestCompleted); XCTAssertNil(observed.value?.latestTarget)
    native.release(); await invalidation.value; await service.closeAll()
    let closedStats=await service.statistics()
    XCTAssertEqual(closedStats.activeNativeRenders,0)
    XCTAssertEqual(native.waiting,0,"closeAll must not return with a blocked native render")
    await observer.value
  }
  func testMailboxLatestOnlyBoundedHistoryAndMalformedRequestsDoNotAdvanceTarget() async throws {
    let lease = PreviewSessionInfo(id: .init(), sourceIdentity: "test", sourceGeneration: 1, decoderVersion: "fake", orientedNativeSize: .init(width: 8, height: 8)), cid = PreviewConsumerID()
    let wakes = ProgressCounter()
    let mailbox = PreviewProgressMailbox(sessionID: lease.id, generation: 1, consumerID: cid, now: { 1 }, wake: { _ in wakes.increment() }, terminate: { _ in })
    let channel = PreviewProgressChannel(mailbox: mailbox)
    for rev in 1...300 { _ = try channel.submit(request(lease, cid, UInt64(rev))) }
    XCTAssertEqual(wakes.value, 1); XCTAssertEqual(mailbox.peek()?.request.revision, 300)
    let excessive = DevelopmentPreviewRequest(sessionID: lease.id, sourceGeneration: 1, consumerID: cid, role: .primary,
      revision: 301, recipe: .init(), quality: .settled, deliveryPolicy: .inFlightProgress, clientCorrelation: Data(count: 4097))
    XCTAssertThrowsError(try channel.submit(excessive))
    var iterator = channel.snapshots.makeAsyncIterator()
    let snapshot = await iterator.next()
    XCTAssertEqual(snapshot?.latestTarget?.request.revision, 300); XCTAssertEqual(snapshot?.terminals.count, 64)
    XCTAssertEqual(snapshot?.terminalOverflowCount, 235)
    channel.noteActivity(); XCTAssertEqual(mailbox.latestRevision, 300)
    mailbox.revoke(.closed); channel.noteActivity(); XCTAssertEqual(wakes.value, 1)
    let closed = await iterator.next(); XCTAssertEqual(closed?.state, .closed); XCTAssertNil(closed?.latestTarget)
  }
  func testLegacyOptInActiveReturnsOwnResultAndTokenCancelDoesNotCancelNewPending() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let a = Task { try await service.render(self.request(lease, cid, 1, ev: 1)) }
    try await wait { native.count == 1 }
    let b = Task { try await service.render(self.request(lease, cid, 2, ev: 2)) }
    try await wait { await service.statistics().pendingRequests == 1 }
    native.release(); let frameA = try await a.value
    XCTAssertEqual(frameA.revision, 1)
    try await wait { native.count == 2 }
    let c = Task { try await service.render(self.request(lease, cid, 3, ev: 3)) }
    try await wait { await service.statistics().pendingRequests == 1 }
    b.cancel(); do { _ = try await b.value; XCTFail() } catch DevelopmentPreviewError.superseded {} catch is CancellationError {}
    XCTAssertEqual(native.count, 2)
    native.release(); try await wait { native.count == 3 }; native.release()
    let frameC = try await c.value; XCTAssertEqual(frameC.revision, 3)
    await service.closeAll()
  }
  func testCacheAndActivityOnlyDeferComparisonUntilQuietWithoutAnotherInput() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(policy: .init(comparisonQuiescenceMilliseconds: 1000), renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let observed = ProgressObserved(), observer = Task { for await snapshot in channel.snapshots { observed.set(snapshot) } }
    _ = try channel.submit(request(lease, cid, 1)); try await wait { native.count == 1 }; native.release()
    try await wait { observed.value?.latestTargetTerminal?.outcome == .completed }
    _ = try channel.submit(request(lease, cid, 2, ev: 0, quality: .settled))
    try await wait { observed.value?.latestTargetTerminal?.work.request.revision == 2 }
    // A new activity pulse must invalidate an old owed settled priority even without new pixels.
    try await Task.sleep(nanoseconds: 2_000_000); channel.noteActivity()
    let comparison = Task { try await service.render(DevelopmentPreviewRequest(sessionID: lease.id,
      sourceGeneration: lease.sourceGeneration, consumerID: .init(), role: .comparison, revision: 1,
      recipe: .init(exposureEV: 2), quality: .settled)) }
    try await wait { await service.statistics().pendingRequests == 1 }
    for _ in 0..<5 {
      try await Task.sleep(nanoseconds: 20_000_000)
      _ = try channel.submit(request(lease, cid, UInt64(3 + Int(observed.value?.latestTarget?.request.revision ?? 0)), ev: 0))
      channel.noteActivity()
      XCTAssertEqual(native.count, 1)
    }
    try await wait { native.count == 2 }; native.release(); _ = try await comparison.value
    await service.closeProgressChannel(channel.id); await observer.value; await service.closeAll()
  }
  func testCloseAllJoinsRevokedChannelWorkerAndClosedSnapshotClearsBufferedImage() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    _ = try channel.submit(request(lease, cid, 1)); try await wait { native.count == 1 }; native.release()
    try await wait { await service.statistics().completedRenders == 1 }
    _ = try channel.submit(request(lease, cid, 2, ev: 2)); try await wait { native.count == 2 }
    let done = ProgressCounter(), close = Task { await service.closeProgressChannel(channel.id); done.increment() }
    let all = Task { await service.closeAll(); done.increment() }
    try await Task.sleep(nanoseconds: 15_000_000); XCTAssertEqual(done.value, 0)
    native.release(); await close.value; await all.value
    var iterator = channel.snapshots.makeAsyncIterator()
    let last = await iterator.next()
    XCTAssertEqual(last?.state, .closed); XCTAssertNil(last?.latestCompleted); XCTAssertNil(last?.latestTarget)
    let stats = await service.statistics(); XCTAssertEqual(stats.sourceSnapshotDiskBytes, 0)
  }
  func testStickyLatestFailureSurvivesOverflowAndNewTargetClearsOnlyItsOutcome() async throws {
    let lease = PreviewSessionInfo(id: .init(), sourceIdentity: "test", sourceGeneration: 1, decoderVersion: "fake", orientedNativeSize: .init(width: 8, height: 8)), cid = PreviewConsumerID()
    let mailbox = PreviewProgressMailbox(sessionID: lease.id, generation: 1, consumerID: cid, now: { 1 }, wake: { _ in }, terminate: { _ in })
    let channel = PreviewProgressChannel(mailbox: mailbox)
    let target = try channel.submit(request(lease, cid, 1000)).work
    XCTAssertTrue(mailbox.take(target.id))
    mailbox.complete(target, result: .failure(ProgressFailure.failed("latest failure")))
    for rev in 1...100 {
      let old = PreviewSubmittedWork(id: .init(rawValue: UUID()), request: request(lease, cid, UInt64(rev)))
      mailbox.complete(old, result: .failure(DevelopmentPreviewError.superseded))
    }
    var iterator = channel.snapshots.makeAsyncIterator()
    let failed = await iterator.next()
    XCTAssertEqual(failed?.latestTargetTerminal?.work.id, target.id)
    XCTAssertEqual(failed?.latestTargetTerminal?.outcome, .failed)
    XCTAssertEqual(failed?.terminalOverflowCount, 37)
    _ = try channel.submit(request(lease, cid, 1001))
    let newest = await iterator.next(); XCTAssertNil(newest?.latestTargetTerminal)
    XCTAssertEqual(newest?.latestTarget?.request.revision, 1001)
    mailbox.revoke(.closed)
  }
  func testCancelledFactoryDoesNotReserveConsumerAndChannelPolicyRejectsDetailAndOversizedSidecar() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let cancelled = Task { () throws -> PreviewProgressChannel in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    }
    do { _ = try await cancelled.value; XCTFail() } catch is CancellationError {}
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let detail = DevelopmentPreviewRequest(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid, role: .primary,
      revision: 1, recipe: .init(), quality: .detail, viewport: .init(maxPixel: 0), deliveryPolicy: .inFlightProgress)
    XCTAssertThrowsError(try channel.submit(detail))
    await service.closeProgressChannel(channel.id); await service.closeAll()
  }
  func testPendingFinalSettledCacheHitImmediatelyOwesComparisonDespiteRecentInput() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    // A frozen clock keeps input recent; only the exact final settled owed rule can start baseline.
    let service = DevelopmentPreviewService(policy: .init(comparisonQuiescenceMilliseconds: 10_000), now: { 1_000_000_000 }, renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let observed = ProgressObserved(), observer = Task { for await snapshot in channel.snapshots { observed.set(snapshot) } }
    _ = try channel.submit(request(lease, cid, 1, ev: 1)); try await wait { native.count == 1 }
    let final = try channel.submit(request(lease, cid, 2, ev: 1, quality: .settled))
    try await wait { await service.statistics().pendingRequests == 1 }
    let baseline = Task { try await service.render(DevelopmentPreviewRequest(sessionID: lease.id,
      sourceGeneration: lease.sourceGeneration, consumerID: .init(), role: .comparison, revision: 1,
      recipe: .init(exposureEV: 3), quality: .settled)) }
    try await wait { await service.statistics().pendingRequests == 2 }
    native.release(); try await wait { native.count == 2 }
    try await wait { observed.value?.latestTargetTerminal?.work.id == final.work.id }
    XCTAssertEqual(observed.value?.latestTargetTerminal?.outcome, .completed)
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 1)
    native.release(); _ = try await baseline.value
    await service.closeProgressChannel(channel.id); await observer.value; await service.closeAll()
  }
  func testLeaseCloseRevokesAdmissionForEveryConsumerBeforeAwaitingNativeJoin() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let native = ProgressBlockedNative(); defer { native.release(20) }
    let service = DevelopmentPreviewService(renderOverride: { try native.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), shared = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    _ = try channel.submit(request(lease, cid, 1)); try await wait { native.count == 1 }
    let done = ProgressCounter(), close1 = Task { await service.close(lease.id); done.increment() }
    // Wait for the close to revoke the old channel, without cancelling its observer as a shortcut.
    var iterator = channel.snapshots.makeAsyncIterator()
    for _ in 0..<10 { if await iterator.next()?.state == .closing { break } }
    let close2 = Task { await service.close(lease.id); done.increment() }
    do { _ = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: .init()); XCTFail() } catch DevelopmentPreviewError.closed {}
    let foreign = PreviewConsumerID()
    do { _ = try await service.render(request(lease, foreign, 1)); XCTFail() } catch DevelopmentPreviewError.closed {}
    XCTAssertEqual(done.value, 0)
    native.release(); await close1.value; await close2.value
    let next = Task { try await service.render(self.request(shared, foreign, 1, ev: 2)) }
    try await wait { native.count == 2 }; native.release(); _ = try await next.value
    await service.closeAll()
    let stats = await service.statistics(); XCTAssertEqual(stats.sourceSnapshotDiskBytes, 0)
  }
  func testPublicActualRAWEligibilityAndDetailStayStrict() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(), lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    do { _ = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid); XCTFail() } catch DevelopmentPreviewError.invalidRequest {}
    do { _ = try await service.render(request(lease, cid, 1)); XCTFail() } catch DevelopmentPreviewError.invalidRequest {}
    await service.closeAll()
  }
}
private enum ProgressFailure: Error { case failed(String) }
private final class ProgressObserved: @unchecked Sendable {
  private let lock = NSLock(); private var snapshot: PreviewDeliverySnapshot?
  var value: PreviewDeliverySnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
  func set(_ value: PreviewDeliverySnapshot) { lock.lock(); snapshot = value; lock.unlock() }
}
private final class ProgressCounter: @unchecked Sendable {
  private let lock = NSLock(); private var count = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  func increment() { lock.lock(); count += 1; lock.unlock() }
}
private final class ProgressBlockedNative: @unchecked Sendable {
  private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0); private var values: [Double] = []; private var waits = 0
  var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
  var waiting: Int { lock.lock(); defer { lock.unlock() }; return waits }
  var exposures: [Double] { lock.lock(); defer { lock.unlock() }; return values }
  func release(_ count: Int = 1) { for _ in 0..<count { semaphore.signal() } }
  func render(_ recipe: DevelopmentRecipe, _ maxPixel: Int) throws -> PreviewPixels {
    lock.lock(); values.append(recipe.exposureEV); waits += 1; lock.unlock()
    semaphore.wait()
    lock.lock(); waits -= 1; lock.unlock()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    let image = NSImage(size: .init(width: 8, height: 8)); image.addRepresentation(bitmap)
    return .init(image: image, nativeSize: .init(width: 8, height: 8), outputSize: .init(width: 8, height: 8), bytes: 256)
  }
}
