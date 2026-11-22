import XCTest
@testable import RAWMasterImaging

final class ImagePerformanceTelemetryTests: XCTestCase {
  func testBeginEndProducesQueueAggregateAndThroughput() {
    let telemetry = ImagePerformanceTelemetry(capacity: 16)
    telemetry.updateQueue("RAW", pendingCount: 3)
    let token = telemetry.begin(operation: "FlashRaw.decode", stage: "linear-f16", queue: "RAW", boundary: .decode)
    let active = telemetry.snapshot()
    XCTAssertEqual(active.active.count, 1)
    XCTAssertEqual(active.queues.first?.pendingCount, 3)
    XCTAssertEqual(active.queues.first?.activeCount, 1)
    telemetry.end(token, pixelCount: 4_000_000, byteCount: 24_000_000)
    let snapshot = telemetry.snapshot()
    XCTAssertTrue(snapshot.active.isEmpty)
    XCTAssertEqual(snapshot.completedSampleCount, 1)
    XCTAssertEqual(snapshot.recent.first?.operation, "FlashRaw.decode")
    XCTAssertEqual(snapshot.recent.first?.pixelCount, 4_000_000)
    XCTAssertEqual(snapshot.aggregates.first?.sampleCount, 1)
    XCTAssertEqual(snapshot.aggregates.first?.failureCount, 0)
    XCTAssertEqual(snapshot.aggregates.first?.recentTiming?.count, 1)
    XCTAssertEqual(snapshot.aggregates.first?.recentTiming?.p95Milliseconds, snapshot.recent.first?.durationMilliseconds)
    XCTAssertEqual(snapshot.queues.first?.activeCount, 0)
    if let duration = snapshot.recent.first?.durationMilliseconds, duration > 0 {
      XCTAssertNotNil(snapshot.recent.first?.megapixelsPerSecond)
    }
  }

  func testRingBufferAndFailedOutcomeRemainBounded() {
    let telemetry = ImagePerformanceTelemetry(capacity: 16)
    for index in 0..<20 {
      let token = telemetry.begin(operation: "op-\(index % 2)", stage: "test", queue: "GPU", boundary: .gpuCompletion)
      telemetry.end(token, outcome: index == 0 ? .failed : .succeeded)
    }
    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.recent.count, 16)
    XCTAssertEqual(snapshot.completedSampleCount, 20)
    XCTAssertEqual(snapshot.recent.first?.operation, "op-1")
    XCTAssertEqual(snapshot.recent.last?.operation, "op-0")
    XCTAssertEqual(snapshot.aggregates.count, 2)
    XCTAssertEqual(snapshot.aggregates.reduce(0) { $0 + $1.failureCount }, 1)
  }

  func testClearPreservesRunningJobsAndIdleQueuesPreserveLastSpeed() throws {
    let telemetry = ImagePerformanceTelemetry()
    let running = telemetry.begin(operation: "preview", queue: "preview")
    telemetry.updateQueue("preview", pendingCount: 2)
    telemetry.reset()
    XCTAssertEqual(telemetry.snapshot().active.first?.id, running.id)
    XCTAssertEqual(telemetry.snapshot().queues.first?.pendingCount, 2)
    telemetry.end(running, pixelCount: 24_000)
    let idle = telemetry.snapshot(pending: ["thumbnail": 0])
    XCTAssertEqual(idle.queues.map(\.name), ["preview", "thumbnail"])
    XCTAssertNotNil(idle.queues.first?.lastMegapixelsPerSecond)
    let encoded = try JSONEncoder().encode(idle)
    let exported = try JSONDecoder().decode(ImagePerformanceSnapshot.self, from: encoded)
    XCTAssertEqual(exported.queues.first?.lastMegapixelsPerSecond, idle.queues.first?.lastMegapixelsPerSecond)
    let graph = telemetry.begin(operation: "blur", queue: "graph", boundary: .graphBuild)
    telemetry.end(graph, pixelCount: 24_000)
    XCTAssertNil(telemetry.snapshot().recent.first?.megapixelsPerSecond)
  }

  func testResetAndDoubleEndAreSafe() {
    let telemetry = ImagePerformanceTelemetry(capacity: 16)
    let token = telemetry.begin(operation: "render")
    telemetry.end(token)
    telemetry.end(token)
    XCTAssertEqual(telemetry.snapshot().completedSampleCount, 1)
    telemetry.reset()
    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.completedSampleCount, 0)
    XCTAssertTrue(snapshot.recent.isEmpty)
    XCTAssertTrue(snapshot.aggregates.isEmpty)
  }
}
