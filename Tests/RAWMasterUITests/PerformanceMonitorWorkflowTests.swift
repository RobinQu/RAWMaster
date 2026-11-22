import XCTest
@testable import RAWMaster
@testable import RAWMasterImaging

final class PerformanceMonitorWorkflowTests: XCTestCase {
  private final class Probe: ImageEngineMonitoring, Sendable {
    let measurements = ImagePerformanceTelemetry(capacity: 8)
    func performanceSnapshot() async -> ImagePerformanceSnapshot { measurements.snapshot() }
    func clearPerformanceSamples() async { measurements.reset() }
  }

  @MainActor func testMonitorPausesClearsLiveHistoryExportsAndReopens() async throws {
    let engine = Probe(), model = PerformanceMonitorModel(engine: engine)
    engine.measurements.updateQueue("预览", pendingCount: 2)
    let live = engine.measurements.begin(operation:"可取消的预览",queue:"预览")
    engine.measurements.end(engine.measurements.begin(operation:"GPU 渲染",queue:"Metal",boundary:.gpuCompletion),pixelCount:1200)
    model.start()
    for _ in 0..<30 where model.snapshot.generatedAtNanoseconds == 0 {
      try await Task.sleep(for:.milliseconds(20))
    }
    XCTAssertEqual(model.snapshot.completedSampleCount,1)
    model.paused = true
    let before = model.snapshot.generatedAtNanoseconds
    engine.measurements.updateQueue("预览",pendingCount:3)
    try await Task.sleep(for:.milliseconds(275))
    XCTAssertEqual(model.snapshot.generatedAtNanoseconds,before)
    await model.clear()
    XCTAssertEqual(model.snapshot.completedSampleCount,0)
    XCTAssertEqual(model.snapshot.active.map(\.id),[live.id])
    XCTAssertEqual(model.snapshot.queues.first(where:{ $0.name == "预览" })?.pendingCount,3)
    let export = try XCTUnwrap(JSONSerialization.jsonObject(with:model.encodedSnapshot()) as? [String:Any])
    let encoded = try JSONSerialization.data(withJSONObject: XCTUnwrap(export["snapshot"]))
    let snapshot = try JSONDecoder().decode(ImagePerformanceSnapshot.self,from:encoded)
    XCTAssertEqual(snapshot.active.map(\.id),[live.id])
    model.stop()
    engine.measurements.end(live,outcome:.cancelled)
    model.paused = false
    model.start()
    for _ in 0..<30 where model.snapshot.completedSampleCount == 0 {
      try await Task.sleep(for:.milliseconds(20))
    }
    model.stop()
    XCTAssertTrue(model.snapshot.active.isEmpty)
    XCTAssertEqual(model.snapshot.recent.first?.outcome,.cancelled)
  }
}
