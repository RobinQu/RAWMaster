import XCTest
import AppKit
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

/// Explicit opt-in, pinned lab copy only. This measures API progress, never AppKit presentation.
final class PreviewProgressBenchmarkTests: XCTestCase {
  func testOptInReal300Event20HzProgress() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RAWMASTER_PREVIEW_PROGRESS_BENCHMARK"] == "1", let rawPath = env["RAWMASTER_PREVIEW_BENCHMARK_RAW"],
      let outputPath = env["RAWMASTER_PREVIEW_BENCHMARK_OUTPUT"] else { throw XCTSkip("Explicit isolated progress benchmark environment required") }
    let output = URL(fileURLWithPath: outputPath), destination = output.appendingPathComponent("progress-burst.json")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw XCTSkip("No evidence overwrite") }
    let source = EditingSourceSnapshot(projectID: "isolated-019-progress", assetID: "DSC05994",
      contentSHA256: "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c", byteCount: 69_488_640,
      admissionFingerprint: "isolated-pinned-sample", sourceLocation: URL(fileURLWithPath: rawPath))
    let service = DevelopmentPreviewService(), cid = PreviewConsumerID(), baselineCID = PreviewConsumerID()
    let lease = try await service.open(source: .raw(source)), comparisonLease = try await service.open(source: .raw(source))
    let channel = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let ledger = ProgressBenchmarkLedger(), sampler = ProgressFootprintSampler()
    let observer = Task { for await snapshot in channel.snapshots { await ledger.receive(snapshot) } }
    sampler.start(); defer { sampler.stop() }
    var events: [UInt64] = [], lateness: [Double] = [], recipes: [DevelopmentRecipe] = []
    var comparison: Task<Void, Error>?
    let begin = DispatchTime.now().uptimeNanoseconds
    for index in 0..<300 {
      let deadline = begin + UInt64(index) * 50_000_000, instant = DispatchTime.now().uptimeNanoseconds
      if deadline > instant { try await Task.sleep(nanoseconds: deadline - instant) }
      let sent = DispatchTime.now().uptimeNanoseconds; events.append(sent); lateness.append(Double(sent - deadline) / 1_000_000)
      let wb: DevelopmentWhiteBalance = index < 150 ? .asShot : .temperatureTint(temperature: 3500 + Double((index-150)%31)*100, tint: -15 + Double((index-150)%31))
      let recipe = DevelopmentRecipe(exposureEV: -2 + 4*Double(index)/299, whiteBalance: wb); recipes.append(recipe)
      var timestamp = sent.littleEndian
      let correlation = withUnsafeBytes(of: &timestamp) { Data($0) }
      _ = try channel.submit(.init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid,
        role: .primary, revision: UInt64(index + 1), recipe: recipe, quality: .interactive,
        deliveryPolicy: .inFlightProgress, clientCorrelation: correlation))
      if index == 150 {
        comparison = Task {
          let frame = try await service.render(.init(sessionID: comparisonLease.id, sourceGeneration: comparisonLease.sourceGeneration,
            consumerID: baselineCID, role: .comparison, revision: 1, recipe: .init(), quality: .settled))
          await ledger.comparison(frame, at: DispatchTime.now().uptimeNanoseconds)
        }
      }
    }
    let stopped = DispatchTime.now().uptimeNanoseconds
    let final = try channel.submit(.init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid,
      role: .primary, revision: 301, recipe: recipes.last!, quality: .settled, deliveryPolicy: .inFlightProgress))
    var finalCompleted = false
    for _ in 0..<4000 {
      if await ledger.finalTerminal(final.work.id) != nil { finalCompleted = true; break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    if !finalCompleted { await service.cancel(consumerID: cid) }
    try await comparison?.value
    let stats = await service.statistics()
    await service.closeProgressChannel(channel.id); await observer.value
    sampler.stop()
    let delivery = await ledger.report(stoppedAt: stopped, final: final.work.id)
    await service.closeAll()
    // Final canonical cross-check is outside producer/native/periodic timing and uses original recipe.
    let actualPixels = try await ledger.finalPixels()
    let canonical = try await DevelopmentService().preview(source: source, recipe: recipes.last!, maxPixel: 2400)
    guard let bitmap = canonical.image.representations.first as? NSBitmapImageRep, let pointer = bitmap.bitmapData else { throw DevelopmentError.unreadable }
    let expected = Data(bytes: pointer, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    var histogram = [Int](repeating: 0, count: 256)
    let matchingCanvas = actualPixels.width == bitmap.pixelsWide && actualPixels.height == bitmap.pixelsHigh && actualPixels.bytes.count == expected.count
    if matchingCanvas {
      actualPixels.bytes.withUnsafeBytes { (a: UnsafeRawBufferPointer) in expected.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
        for index in 0..<a.count { histogram[abs(Int(a[index]) - Int(b[index]))] += 1 }
      } }
    }
    let threshold = Int(ceil(Double(histogram.reduce(0,+))*0.99))
    var accumulated = 0, p99 = 255
    if matchingCanvas { for (error, count) in histogram.enumerated() { accumulated += count; if accumulated >= threshold { p99 = error; break } } }
    let maxError = histogram.lastIndex(where: { $0 > 0 }) ?? 255
    let finalParity: [String: Any] = ["matchingCanvas": matchingCanvas, "width": actualPixels.width, "height": actualPixels.height,
      "p99ChannelError": p99, "maximumChannelError": maxError,
      "actualRGBA8SHA256": SHA256.hash(data: actualPixels.bytes).map { String(format: "%02x", $0) }.joined(),
      "canonicalRGBA8SHA256": SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(),
      "outsideTimingAndPeriodic": true]
    try RenderFiles.verify(source)
    let intervals = zip(events.dropFirst(), events).map { Double($0 - $1) / 1_000_000 }.sorted(), late = lateness.sorted()
    let during = (delivery["duringInputPrimaryDeliveries"] as? Int) ?? 0
    let finalPass = (delivery["finalSettledCompleted"] as? Bool) == true
    let uniqueFrames = (delivery["uniquePrimaryFrames"] as? Int) ?? 0
    let frameCountBound = UInt64(uniqueFrames) <= stats.completedRenders + stats.cacheHits
    let report: [String: Any] = ["mode": "production-G-bounded-progress-channel", "events": 300,
      "decoderVersion": lease.decoderVersion, "inputSHA256": source.contentSHA256, "inputByteCount": source.byteCount,
      "deliveries": delivery, "finalCanonicalParity": finalParity, "submittedAdmittedRequests": stats.submittedRequests, "nativeCompletions": stats.completedRenders,
      "supersededAdmittedRequests": stats.supersededRequests, "activeMaximum": stats.maximumObservedNativeRenders,
      "pendingMaximum": stats.maximumObservedPendingRequests, "fullHashPasses": stats.sourceFullHashPasses,
      "sourceCaptures": stats.sourceCaptures, "hashBytes": stats.sourceHashBytes, "statChecks": stats.sourceStatChecks,
      "cacheHits": stats.cacheHits, "periodic": sampler.report(),
      "eventIntervalsMilliseconds": intervals, "eventLatenessMilliseconds": lateness,
      "eventIntervalMedianMilliseconds": intervals[intervals.count/2], "eventIntervalMaximumMilliseconds": intervals.max() ?? 0,
      "eventLatenessP95Milliseconds": late[Int(ceil(Double(late.count)*0.95))-1],
      "gatePass": during > 2 && finalPass && matchingCanvas && p99 <= 1 && frameCountBound && stats.maximumObservedNativeRenders == 1 && stats.maximumObservedPendingRequests <= 2,
      "caveats": ["Fullscale1 canonical2400 productionG, no RAW quality/context policy change.",
        "One15s300intent20Hz run; actual cadence/lateness reported, no per-input Task or image-bearing result array.",
        "One observer retains primary display and one baseline display; channel holds one sticky image. Terminal ring64 contains metadata only.",
        "API progress only; excludes App publication, AppKit draw, WindowServer/input-to-photon; no66ms or ACR comparison.",
        "Periodic physical footprint is sampled highwater, not exact continuous peak; no OS/Metal cache purge.",
        "Snapshot metadata updates are not frames; unique frameID/token dedup. Conflated snapshots may hide completed images; observed terminal-only completions reported separately.",
        env["RAWMASTER_PREVIEW_EXTERNAL_STATE"] ?? "External screen/host state not supplied."]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .withoutOverwriting)
    XCTAssertGreaterThan(during, 2); XCTAssertTrue(finalPass); XCTAssertTrue(frameCountBound); XCTAssertTrue(matchingCanvas); XCTAssertLessThanOrEqual(p99, 1)
    XCTAssertEqual(stats.maximumObservedNativeRenders, 1); XCTAssertLessThanOrEqual(stats.maximumObservedPendingRequests, 2)
    XCTAssertEqual(stats.sourceFullHashPasses, 1); XCTAssertEqual(stats.sourceCaptures, 1)
    print("PROGRESS native=\(stats.completedRenders) duringInputAPI=\(during) final=\(finalPass) activeMax=\(stats.maximumObservedNativeRenders) pendingMax=\(stats.maximumObservedPendingRequests)")
  }
}
private actor ProgressBenchmarkLedger {
  private var seenFrameIDs = Set<UUID>()
  private var seenFrameTokens = Set<PreviewSubmissionID>()
  private var completedTerminalTokens = Set<PreviewSubmissionID>()
  private var snapshotCount = 0
  private var primaryFrame: DevelopmentPreviewFrame?
  private var comparisonFrame: DevelopmentPreviewFrame?
  private var frames: [[String: Any]] = []
  private var target: PreviewSubmissionTerminal?
  private var maxOverflow: UInt64 = 0
  private var latestRing: [[String: Any]] = []
  private var baselineAt: UInt64?
  func receive(_ snapshot: PreviewDeliverySnapshot) {
    snapshotCount += 1
    for terminal in snapshot.terminals where terminal.outcome == .completed { completedTerminalTokens.insert(terminal.work.id) }
    maxOverflow = max(maxOverflow, snapshot.terminalOverflowCount)
    if let terminal = snapshot.latestTargetTerminal { target = terminal }
    latestRing = snapshot.terminals.map { ["revision": $0.work.request.revision, "token": $0.work.id.rawValue.uuidString, "outcome": $0.outcome.rawValue] }
    guard let completed = snapshot.latestCompleted,
      seenFrameIDs.insert(completed.frame.frameID).inserted,
      seenFrameTokens.insert(completed.work.id).inserted else { return }
    let at = DispatchTime.now().uptimeNanoseconds
    var item: [String: Any] = ["revision": completed.work.request.revision, "quality": completed.work.request.quality.rawValue,
      "frameID": completed.frame.frameID.uuidString, "token": completed.work.id.rawValue.uuidString, "receivedAt": at,
      "width": completed.frame.outputPixelSize.width, "height": completed.frame.outputPixelSize.height,
      "approximate": completed.frame.approximate,
      "latestTargetRevisionAtObservation": snapshot.latestTarget?.request.revision ?? completed.work.request.revision,
      "revisionLagAtObservation": (snapshot.latestTarget?.request.revision ?? completed.work.request.revision) - completed.work.request.revision]
    if let bytes = completed.work.request.clientCorrelation, bytes.count == 8 {
      let sent = bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
      item["inputAt"] = sent; item["inputToAPIMilliseconds"] = Double(at - sent) / 1_000_000
    }
    frames.append(item); primaryFrame = completed.frame
  }
  func comparison(_ frame: DevelopmentPreviewFrame, at: UInt64) { comparisonFrame = frame; baselineAt = at }
  func finalPixels() throws -> (bytes: Data, width: Int, height: Int) {
    guard let frame = primaryFrame, let bitmap = frame.image.representations.first as? NSBitmapImageRep,
      let pointer = bitmap.bitmapData else { throw DevelopmentError.unreadable }
    return (Data(bytes: pointer, count: bitmap.bytesPerRow * bitmap.pixelsHigh), bitmap.pixelsWide, bitmap.pixelsHigh)
  }
  func finalTerminal(_ id: PreviewSubmissionID) -> PreviewSubmissionTerminal? { target?.work.id == id ? target : nil }
  func report(stoppedAt: UInt64, final: PreviewSubmissionID) -> [String: Any] {
    let during = frames.filter { ($0["receivedAt"] as? UInt64 ?? UInt64.max) < stoppedAt }
    let finalFrame = frames.first { ($0["token"] as? String) == final.rawValue.uuidString }
    let feedbackIntervals = zip(during.dropFirst(), during).compactMap { newer, older -> Double? in
      guard let a = newer["receivedAt"] as? UInt64, let b = older["receivedAt"] as? UInt64 else { return nil }
      return Double(a - b)/1_000_000
    }
    let renderedRevisions = during.compactMap { $0["revision"] as? UInt64 }
    let coverageGaps = zip(renderedRevisions.dropFirst(), renderedRevisions).map { $0 - $1 }
    let convergence = finalFrame.flatMap { $0["receivedAt"] as? UInt64 }.map { Double($0 - stoppedAt)/1_000_000 }
    return ["frames": frames, "uniquePrimaryFrames": seenFrameIDs.count, "uniquePrimaryTokens": seenFrameTokens.count,
      "snapshotsConsumed": snapshotCount, "completedTerminalTokensObserved": completedTerminalTokens.count,
      "completedTokensWithoutObservedImage": completedTerminalTokens.subtracting(seenFrameTokens).count,
      "duringInputPrimaryDeliveries": during.count,
      "duringInputUniqueRenderedRevisions": renderedRevisions,
      "duringInputAPIFeedbackIntervalsMilliseconds": feedbackIntervals,
      "maximumDuringInputRenderedRevisionGap": coverageGaps.max() ?? 0,
      "firstDuringInputFrameID": during.first?["frameID"] ?? NSNull(), "firstDuringInputReceivedAt": during.first?["receivedAt"] ?? NSNull(),
      "lastDuringInputFrameID": during.last?["frameID"] ?? NSNull(), "lastDuringInputReceivedAt": during.last?["receivedAt"] ?? NSNull(),
      "firstDuringInputRevision": during.first?["revision"] ?? NSNull(), "lastDuringInputRevision": during.last?["revision"] ?? NSNull(),
      "finalSettledCompleted": target?.work.id == final && target?.outcome == .completed && target?.work.request.quality == .settled,
      "finalStopToAPIMilliseconds": convergence ?? -1, "comparisonDelivered": comparisonFrame != nil,
      "comparisonReceivedAfterStop": baselineAt.map { $0 >= stoppedAt } ?? false,
      "terminalOverflowCount": maxOverflow, "last64Terminals": latestRing,
      "retainedDisplayFrames": (primaryFrame == nil ? 0:1) + (comparisonFrame == nil ? 0:1)]
  }
}
private final class ProgressFootprintSampler: @unchecked Sendable {
  private let lock = NSLock(), queue = DispatchQueue(label: "progress.periodic-memory")
  private var timer: DispatchSourceTimer?, samples: [[String: UInt64]] = []
  func start() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler { [weak self] in self?.sample() }; self.timer = timer; timer.resume()
  }
  func stop() { timer?.cancel(); timer = nil; queue.sync {} }
  private func sample() {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    guard status == KERN_SUCCESS else { return }
    lock.lock(); samples.append(["at": DispatchTime.now().uptimeNanoseconds, "footprint": info.phys_footprint]); lock.unlock()
  }
  func report() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    let intervals = zip(samples.dropFirst(), samples).map { Double($0["at"]! - $1["at"]!)/1_000_000 }.sorted()
    return ["requestedIntervalMilliseconds": 20, "samples": samples, "sampleCount": samples.count,
      "sampledHighWaterBytes": samples.compactMap { $0["footprint"] }.max() ?? 0,
      "achievedIntervalP95Milliseconds": intervals.isEmpty ? 0:intervals[Int(ceil(Double(intervals.count)*0.95))-1],
      "achievedIntervalMaximumMilliseconds": intervals.max() ?? 0]
  }
}
